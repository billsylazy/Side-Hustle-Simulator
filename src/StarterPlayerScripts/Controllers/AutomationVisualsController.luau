-- AutomationVisualsController: one stationed chibi rig per zone where the
-- local player owns the zone's automation upgrade (Auto level > 0). Rigs are
-- built by ChibiRig, stand on HustleStation.AutoAnchor facing the PromptPart
-- and loop a per-mechanic "hustle" motion (Tap punches, Hold leans, Timing
-- watches the ticker, Charge hops then jumps). Auto HustleResults pop a
-- "+$X" world popup at the station's FeedbackPart.
--
-- Pure view layer, client-only: rigs live in a local Workspace Folder
-- ("AutomationRigs") and are driven by CFrame math on one Heartbeat.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(sharedFolder:WaitForChild("GameConfig"))
local FormatNumber = require(sharedFolder:WaitForChild("FormatNumber"))
local ChibiRig = require(sharedFolder:WaitForChild("ChibiRig"))
local ClientEffects = require(sharedFolder:WaitForChild("ClientEffects"))

local RIG_FOLDER_NAME = "AutomationRigs"
local HIDDEN_CFRAME = CFrame.new(0, -500, 0)
local POP_DURATION = 0.35 -- little hop when an auto payout lands

type StationRefs = {
	anchor: BasePart,
	prompt: BasePart?,
	feedback: BasePart?,
}

type StationRig = {
	zoneId: string,
	model: Model,
	level: number,
	baseCF: CFrame, -- feet on the anchor, facing the prompt
	mechanic: string,
	phase: number, -- animation clock (seconds, randomized start)
	popT: number, -- remaining seconds of the payout hop
}

local stationRefs: { [string]: StationRefs } = {}
local resolving: { [string]: boolean } = {}
local warnedZones: { [string]: boolean } = {}
local rigs: { [string]: StationRig } = {}
local desiredLevels: { [string]: number } = {}
local hasSnapshot = false
local started = false

local AutomationVisualsController = {}

----------------------------------------------------------------------
-- Station lookup (WaitForChild with timeouts; zones may stream in late)
----------------------------------------------------------------------

local function getRigFolder(): Folder
	local existing = workspace:FindFirstChild(RIG_FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = RIG_FOLDER_NAME
	folder.Parent = workspace
	return folder
end

local function warnOnce(zoneId: string, message: string)
	if warnedZones[zoneId] then
		return
	end
	warnedZones[zoneId] = true
	warn(("[AutomationVisualsController] %s: %s"):format(zoneId, message))
end

-- Resolves Workspace.SideHustleMap.Zones.<zoneId>.HustleStation.{AutoAnchor,
-- PromptPart, FeedbackPart}. Yields; nil when the station never appears.
local function resolveStation(zoneId: string): StationRefs?
	local cached = stationRefs[zoneId]
	if cached and cached.anchor:IsDescendantOf(workspace) then
		return cached
	end

	local map = workspace:WaitForChild("SideHustleMap", 60)
	if not map then
		warnOnce(zoneId, "Workspace.SideHustleMap never appeared")
		return nil
	end
	local zonesFolder = map:WaitForChild("Zones", 30)
	if not zonesFolder then
		warnOnce(zoneId, "SideHustleMap.Zones never appeared")
		return nil
	end
	local zoneModel = zonesFolder:WaitForChild(zoneId, 30)
	if not zoneModel then
		return nil -- not streamed in yet; ChildAdded retries
	end
	local station = zoneModel:WaitForChild("HustleStation", 20)
	if not station then
		warnOnce(zoneId, "zone has no HustleStation")
		return nil
	end
	local anchor = station:WaitForChild("AutoAnchor", 20)
	if not anchor or not anchor:IsA("BasePart") then
		warnOnce(zoneId, "HustleStation has no AutoAnchor part")
		return nil
	end
	local prompt = station:WaitForChild("PromptPart", 5)
	local feedback = station:WaitForChild("FeedbackPart", 5)

	local refs: StationRefs = {
		anchor = anchor,
		prompt = if prompt and prompt:IsA("BasePart") then prompt else nil,
		feedback = if feedback and feedback:IsA("BasePart") then feedback else nil,
	}
	stationRefs[zoneId] = refs
	return refs
end

-- Feet position for a rig standing on the anchor: the ground straight below
-- the anchor's center when a raycast finds it, else the anchor's bottom face.
local function findFeetPosition(anchor: BasePart): Vector3
	-- Only the world counts as ground: any player (not just the local one)
	-- standing on the anchor when the rig spawns must not become its floor.
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	local include: { Instance } = { workspace.Terrain }
	local map = workspace:FindFirstChild("SideHustleMap")
	if map then
		table.insert(include, map)
	end
	params.FilterDescendantsInstances = include

	local origin = anchor.Position + Vector3.new(0, 2, 0)
	local result = workspace:Raycast(origin, Vector3.new(0, -12, 0), params)
	if result then
		return result.Position
	end
	return anchor.Position - Vector3.new(0, anchor.Size.Y * 0.5, 0)
end

-- Rig base: feet on the anchor, facing the PromptPart (fallback: the plaza).
local function computeBaseCFrame(refs: StationRefs): CFrame
	local feet = findFeetPosition(refs.anchor)
	local lookTarget: Vector3
	if refs.prompt and refs.prompt.Parent ~= nil then
		lookTarget = Vector3.new(refs.prompt.Position.X, feet.Y, refs.prompt.Position.Z)
	else
		lookTarget = Vector3.new(0, feet.Y, 0)
	end
	if (lookTarget - feet).Magnitude < 0.05 then
		lookTarget = feet + Vector3.new(0, 0, -1)
	end
	return CFrame.lookAt(feet, lookTarget)
end

----------------------------------------------------------------------
-- Rig lifecycle
----------------------------------------------------------------------

local function destroyRig(zoneId: string)
	local rig = rigs[zoneId]
	if rig then
		rigs[zoneId] = nil
		rig.model:Destroy()
	end
end

local function buildRig(zoneId: string, refs: StationRefs, level: number)
	local zone = GameConfig.getZone(zoneId)
	local autoDef = GameConfig.getZoneUpgradeByEffect(zoneId, "Auto")
	if not zone or not autoDef then
		return
	end

	local model = ChibiRig.build({
		Name = autoDef.Name, -- e.g. "Auto-Squeezer"
		Prop = "None",
		BodyColor = zone.SignColor,
		Label = "Lv " .. tostring(level),
	})
	model.Name = "AutoRig_" .. zoneId

	local baseCF = computeBaseCFrame(refs)
	ChibiRig.setPose(model, baseCF)
	model.Parent = getRigFolder()

	rigs[zoneId] = {
		zoneId = zoneId,
		model = model,
		level = level,
		baseCF = baseCF,
		mechanic = zone.Mechanic,
		phase = math.random() * 10,
		popT = 0,
	}
end

-- Kicks off (at most one) station lookup for the zone, then builds the rig
-- if the player still owns automation there once the station is found.
local function ensureRig(zoneId: string)
	if rigs[zoneId] or resolving[zoneId] then
		return
	end
	resolving[zoneId] = true
	task.spawn(function()
		local refs = resolveStation(zoneId)
		resolving[zoneId] = nil
		if not refs then
			return
		end
		local level = desiredLevels[zoneId] or 0
		if level <= 0 or rigs[zoneId] then
			return -- changed while we were waiting (rebirth, duplicate)
		end
		buildRig(zoneId, refs, level)
	end)
end

----------------------------------------------------------------------
-- DataSync: which zones are automated, and at what level
----------------------------------------------------------------------

local function applySnapshot(snapshot: any)
	if type(snapshot) ~= "table" then
		return
	end
	hasSnapshot = true
	local upgrades = snapshot.Upgrades

	for _, zone in GameConfig.Zones do
		local zoneId = zone.Id
		local level = GameConfig.getZoneEffectLevel(upgrades, zoneId, "Auto")
		desiredLevels[zoneId] = level

		local rig = rigs[zoneId]
		if level > 0 then
			if rig and rig.model.Parent == nil then
				destroyRig(zoneId) -- wiped externally; rebuild below
				rig = nil
			end
			if rig then
				if rig.level ~= level then
					rig.level = level
					ChibiRig.setLabel(rig.model, "Lv " .. tostring(level))
				end
			else
				ensureRig(zoneId)
			end
		elseif rig then
			destroyRig(zoneId) -- automation gone (rebirth)
		end
	end
end

----------------------------------------------------------------------
-- Auto payouts -> "+$X" world popup at the FeedbackPart + a little hop
----------------------------------------------------------------------

local function onHustleResult(zoneId: any, result: any)
	if type(zoneId) ~= "string" or type(result) ~= "table" or result.Kind ~= "Auto" then
		return
	end
	local amount = result.Amount
	if type(amount) ~= "number" or amount <= 0 then
		return
	end
	local zone = GameConfig.getZone(zoneId)
	if not zone then
		return
	end

	local rig = rigs[zoneId]
	if rig then
		rig.popT = POP_DURATION
	end

	local refs = stationRefs[zoneId]
	local position: Vector3? = nil
	if refs and refs.feedback and refs.feedback.Parent ~= nil then
		position = refs.feedback.Position
	elseif rig then
		position = rig.baseCF.Position + Vector3.new(0, ChibiRig.HEIGHT + 1, 0)
	end
	if position then
		ClientEffects.worldPopup(position, "+" .. FormatNumber.money(amount), zone.SignColor)
	end
end

----------------------------------------------------------------------
-- Heartbeat: per-mechanic hustle loops (a few CFrame ops per rig)
----------------------------------------------------------------------

local function animateRig(rig: StationRig, dt: number)
	local model = rig.model
	if model.Parent == nil then
		return
	end
	rig.phase += dt
	local t = rig.phase
	local base = rig.baseCF

	-- Payout hop layered on top of whatever the loop is doing.
	local popY = 0
	if rig.popT > 0 then
		rig.popT = math.max(rig.popT - dt, 0)
		popY = math.sin((1 - rig.popT / POP_DURATION) * math.pi) * 0.5
	end

	local mechanic = rig.mechanic
	if mechanic == "Tap" then
		-- Quick bob + alternating arm punches in rhythm.
		local beat = t * 7.5
		local s = math.sin(beat)
		local bob = math.abs(s) * 0.12
		local left = math.max(0, s)
		local right = math.max(0, -s)
		ChibiRig.setPose(model, base * CFrame.new(0, bob + popY, 0), {
			LeftArm = CFrame.new(0, 0.15 * left, -0.3 * left) * CFrame.Angles(math.rad(80) * left, 0, 0),
			RightArm = CFrame.new(0, 0.15 * right, -0.3 * right) * CFrame.Angles(math.rad(80) * right, 0, 0),
		})
	elseif mechanic == "Hold" then
		-- Slow lean back and forth about the feet, arms out front (holding on).
		local lean = math.sin(t * 1.6) * math.rad(9)
		local armPitch = math.rad(40) + math.sin(t * 1.6) * math.rad(6)
		ChibiRig.setPose(model, base * CFrame.new(0, popY, 0) * CFrame.Angles(lean, 0, 0), {
			LeftArm = CFrame.Angles(armPitch, 0, 0),
			RightArm = CFrame.Angles(armPitch, 0, 0),
		})
	elseif mechanic == "Timing" then
		-- Head turns left/right like watching a ticker; body follows a little.
		local yaw = math.sin(t * 2.2) * math.rad(38)
		local tilt = math.sin(t * 4.4) * math.rad(3)
		ChibiRig.setPose(model, base * CFrame.new(0, popY, 0) * CFrame.Angles(0, yaw * 0.15, 0), {
			Head = CFrame.Angles(0, yaw, tilt),
		})
	elseif mechanic == "Charge" then
		-- 3.2s cycle: four hops building height, then one big jump, then rest.
		local c = t % 3.2
		local y = 0
		local overrides: { [string]: CFrame }? = nil
		if c < 2.2 then
			local hopP = c / 0.55
			local hopIndex = math.floor(hopP)
			local f = hopP - hopIndex
			y = math.sin(f * math.pi) * (0.12 + hopIndex * 0.1)
		elseif c < 2.9 then
			local f = (c - 2.2) / 0.7
			y = math.sin(f * math.pi) * 2.2
			local up = math.rad(160) * math.sin(f * math.pi)
			overrides = {
				LeftArm = CFrame.Angles(up, 0, 0),
				RightArm = CFrame.Angles(up, 0, 0),
			}
		end
		ChibiRig.setPose(model, base * CFrame.new(0, y + popY, 0), overrides)
	else
		ChibiRig.setPose(model, base * CFrame.new(0, popY, 0))
	end
end

local function onHeartbeat(dt: number)
	if dt <= 0 then
		return
	end
	for _, rig in rigs do
		animateRig(rig, dt)
	end
end

----------------------------------------------------------------------
-- Entry point
----------------------------------------------------------------------

function AutomationVisualsController.start(): ()
	if started then
		return
	end
	started = true

	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("Remotes")
		local dataSync = remotes:WaitForChild("DataSync")
		dataSync.OnClientEvent:Connect(applySnapshot)
		local hustleResult = remotes:WaitForChild("HustleResult")
		hustleResult.OnClientEvent:Connect(onHustleResult)
	end)

	-- Zones that stream in (or get rebuilt) later: re-run the lookup for any
	-- automated zone that has no rig yet.
	task.spawn(function()
		local map = workspace:WaitForChild("SideHustleMap", 60)
		if not map then
			return -- resolveStation already warns
		end
		local zonesFolder = map:WaitForChild("Zones", 30)
		if not zonesFolder then
			return
		end
		zonesFolder.ChildAdded:Connect(function(child)
			local zoneId = child.Name
			if not hasSnapshot or (desiredLevels[zoneId] or 0) <= 0 then
				return
			end
			-- Drop a stale cache/rig for a zone model that was replaced.
			local cached = stationRefs[zoneId]
			if cached and not cached.anchor:IsDescendantOf(workspace) then
				stationRefs[zoneId] = nil
				destroyRig(zoneId)
			end
			ensureRig(zoneId)
		end)
	end)

	RunService.Heartbeat:Connect(onHeartbeat)
end

return AutomationVisualsController
