-- WorkerVisualsController: renders the LOCAL player's equipped workers as cute
-- chibi rigs that waddle along behind the character (art & feel guide: "workers
-- waddling around doing the hustle animation in the background").
--
-- Pure view layer, client-only: rigs are built by ChibiRig (primitives), live in
-- a local-only Workspace folder ("WorkerRigs") and are driven purely by CFrame
-- math on a single RunService.Heartbeat connection - no physics, no server
-- instances. Equipped workers come from the DataSync snapshot (fires >=1/s)
-- and are diffed by Uid so rigs persist across syncs.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(sharedFolder:WaitForChild("GameConfig"))
local FormatNumber = require(sharedFolder:WaitForChild("FormatNumber"))
local ChibiRig = require(sharedFolder:WaitForChild("ChibiRig"))

local RIG_FOLDER_NAME = "WorkerRigs"
local MAX_RIGS = GameConfig.Workers.BaseEquipSlots + GameConfig.Perks.WorkerSlots.MaxLevel -- 3 + 3

-- Slot fan behind/beside the player: angle in degrees (0 = directly behind,
-- negative = player's left) and radius in studs (contract: 5-7).
local SLOTS = {
	{ angle = 0, radius = 5 },
	{ angle = -38, radius = 5.6 },
	{ angle = 38, radius = 5.6 },
	{ angle = -72, radius = 6.4 },
	{ angle = 72, radius = 6.4 },
	{ angle = 0, radius = 7 },
}

-- Movement tuning
local FOLLOW_RATE = 4.5 -- exponential position smoothing per second
local TURN_RATE = 10 -- yaw smoothing per second
local WADDLE_SWAY = math.rad(8) -- +-8 degrees RotZ while moving
local WADDLE_BOB = 0.2 -- studs of up/down bob while moving
local ARM_SWING = math.rad(28) -- arm pitch swing while moving
local MOVE_THRESHOLD = 0.75 -- studs/s before a rig counts as moving
local HIDDEN_CFRAME = CFrame.new(0, -500, 0) -- parking spot before first placement

type RigState = {
	uid: string,
	model: Model,
	slotIndex: number,
	pos: Vector3?, -- nil until first placed (then snapped to its slot)
	yaw: number,
	phase: number, -- waddle sine phase
	sway: number, -- current RotZ
	bob: number, -- current bob height
	idleClock: number,
	idleWait: number,
	action: string?, -- "hop" | "spin"
	actionT: number,
	actionDur: number,
}

local rigs: { [string]: RigState } = {}

-- Local character tracking
local currentHrp: BasePart? = nil
local groundOffset = 3 -- HRP center -> feet distance; refined per character
local charToken = 0 -- invalidates stale WaitForChild setups on respawn
local charConnections: { RBXScriptConnection } = {}

local started = false

local WorkerVisualsController = {}

----------------------------------------------------------------------
-- Rig building (ChibiRig primitives; everything anchored + non-colliding)
----------------------------------------------------------------------

local function getRigFolder(): Folder
	local existing = workspace:FindFirstChild(RIG_FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end
	-- Client-side creation is local-only; that is fine for a pure view layer.
	local folder = Instance.new("Folder")
	folder.Name = RIG_FOLDER_NAME
	folder.Parent = workspace
	return folder
end

-- Builds one chibi rig for a worker entry, then parks it underground until
-- the follow loop places it.
local function buildRigModel(entry: { [string]: any }): Model
	local rarity = GameConfig.getRarity(entry.Rarity)
	local income = GameConfig.getWorkerIncome(entry.Rarity, entry.Crate)
	local model = ChibiRig.build({
		Name = tostring(entry.Name),
		Rarity = entry.Rarity,
		Label = FormatNumber.money(income) .. "/s",
		LabelColor = if rarity then rarity.Color else nil,
	})
	model.Name = "WorkerRig_" .. tostring(entry.Name)
	ChibiRig.setPose(model, HIDDEN_CFRAME)
	model.Parent = getRigFolder()
	return model
end

local function createRig(entry: { [string]: any }, slotIndex: number): RigState
	local rig: RigState = {
		uid = entry.Uid,
		model = buildRigModel(entry),
		slotIndex = slotIndex,
		pos = nil,
		yaw = 0,
		phase = math.random() * math.pi * 2, -- desync waddles between rigs
		sway = 0,
		bob = 0,
		idleClock = 0,
		idleWait = 2 + math.random() * 3,
		action = nil,
		actionT = 0,
		actionDur = 1,
	}
	rigs[entry.Uid] = rig
	return rig
end

local function destroyRig(uid: string)
	local rig = rigs[uid]
	if rig then
		rigs[uid] = nil
		rig.model:Destroy()
	end
end

----------------------------------------------------------------------
-- DataSync diffing (by Uid; rigs persist across the ~1/s snapshots)
----------------------------------------------------------------------

local function applySnapshot(snapshot: any)
	if type(snapshot) ~= "table" or type(snapshot.Workers) ~= "table" then
		return
	end

	-- Equipped workers in snapshot order, capped at the rig limit.
	local desired: { { [string]: any } } = {}
	local desiredIndexByUid: { [string]: number } = {}
	for _, entry in snapshot.Workers do
		if #desired >= MAX_RIGS then
			break
		end
		if
			type(entry) == "table"
			and entry.Equipped == true
			and type(entry.Uid) == "string"
			and type(entry.Rarity) == "string"
			and type(entry.Crate) == "string"
			and type(entry.Name) == "string"
			and desiredIndexByUid[entry.Uid] == nil
		then
			table.insert(desired, entry)
			desiredIndexByUid[entry.Uid] = #desired
		end
	end

	-- Destroy rigs that were unequipped, plus any whose model got wiped
	-- externally (those rebuild below).
	local toRemove: { string } = {}
	for uid, rig in rigs do
		if desiredIndexByUid[uid] == nil or rig.model.Parent == nil then
			table.insert(toRemove, uid)
		end
	end
	for _, uid in toRemove do
		destroyRig(uid)
	end

	-- Create missing rigs; refresh slot assignments for survivors.
	for index, entry in desired do
		local rig = rigs[entry.Uid]
		if rig == nil then
			createRig(entry, index)
		else
			rig.slotIndex = index
		end
	end
end

----------------------------------------------------------------------
-- Follow + waddle loop (one Heartbeat connection, CFrame only)
----------------------------------------------------------------------

local function updateRig(rig: RigState, dt: number, hrpPos: Vector3?, playerYawCF: CFrame?, groundY: number)
	local model = rig.model
	if model.PrimaryPart == nil or model.Parent == nil then
		return
	end

	local moving = false
	local speed = 0

	if hrpPos and playerYawCF then
		local slot = SLOTS[math.clamp(rig.slotIndex, 1, #SLOTS)]
		local a = math.rad(slot.angle)
		-- 0 degrees = directly behind the player (+Z in player-local space).
		local worldDir = playerYawCF:VectorToWorldSpace(Vector3.new(math.sin(a), 0, math.cos(a)))
		local target = Vector3.new(hrpPos.X + worldDir.X * slot.radius, groundY, hrpPos.Z + worldDir.Z * slot.radius)

		local pos = rig.pos
		if pos == nil then
			-- First placement (or respawn re-anchor): snap straight to the slot.
			rig.pos = target
			rig.yaw = math.atan2(-worldDir.X, -worldDir.Z)
		else
			local alpha = 1 - math.exp(-dt * FOLLOW_RATE)
			local newPos = pos:Lerp(target, alpha)
			local vel = (newPos - pos) / dt
			speed = math.sqrt(vel.X * vel.X + vel.Z * vel.Z)
			moving = speed > MOVE_THRESHOLD
			rig.pos = newPos

			if moving then
				-- Face travel direction (shortest-arc yaw smoothing).
				local desiredYaw = math.atan2(-vel.X, -vel.Z)
				local delta = (desiredYaw - rig.yaw + math.pi) % (math.pi * 2) - math.pi
				rig.yaw += delta * math.min(dt * TURN_RATE, 1)
			end
		end
	end

	if rig.pos == nil then
		return -- never placed and no character yet; stay parked underground
	end

	-- WADDLE while moving; wind the sway/bob down when stopped.
	local hopY = 0
	local spinYaw = 0
	if moving then
		rig.action = nil
		rig.idleClock = 0
		rig.phase += dt * math.min(speed, 20) * 0.55
		rig.sway = math.sin(rig.phase) * WADDLE_SWAY
		rig.bob = math.abs(math.sin(rig.phase)) * WADDLE_BOB
	else
		local settle = math.min(dt * 6, 1)
		rig.sway += (0 - rig.sway) * settle
		rig.bob += (0 - rig.bob) * settle

		-- Idle "hustle" loop: tiny hops / a slow spin every few seconds.
		if rig.action then
			rig.actionT += dt
			local p = math.min(rig.actionT / rig.actionDur, 1)
			if rig.action == "hop" then
				hopY = math.abs(math.sin(p * math.pi * 2)) * 0.35 -- two tiny hops
			else
				local s = p * p * (3 - 2 * p) -- smoothstep: one eased full turn
				spinYaw = s * math.pi * 2
			end
			if p >= 1 then
				rig.action = nil
				rig.idleClock = 0
				rig.idleWait = 2 + math.random() * 3
			end
		else
			rig.idleClock += dt
			if rig.idleClock >= rig.idleWait then
				rig.actionT = 0
				if math.random() < 0.65 then
					rig.action = "hop"
					rig.actionDur = 0.7
				else
					rig.action = "spin"
					rig.actionDur = 1.3
				end
			end
		end
	end

	local pos = rig.pos :: Vector3
	local rootCF = CFrame.new(pos.X, pos.Y + rig.bob + hopY, pos.Z)
		* CFrame.Angles(0, rig.yaw + spinYaw, 0)
		* CFrame.Angles(0, 0, rig.sway)

	if moving then
		-- Arms swing opposite each other while waddling (2 extra CFrame ops).
		local swing = math.sin(rig.phase) * ARM_SWING
		ChibiRig.setPose(model, rootCF, {
			LeftArm = CFrame.Angles(swing, 0, 0),
			RightArm = CFrame.Angles(-swing, 0, 0),
		})
	else
		ChibiRig.setPose(model, rootCF)
	end
end

local function onHeartbeat(dt: number)
	if dt <= 0 then
		return
	end

	-- Shared per-frame data, computed once for all rigs.
	local hrp = currentHrp
	local hrpPos: Vector3? = nil
	local playerYawCF: CFrame? = nil
	local groundY = 0
	if hrp and hrp.Parent ~= nil then
		hrpPos = hrp.Position
		local look = hrp.CFrame.LookVector
		playerYawCF = CFrame.Angles(0, math.atan2(-look.X, -look.Z), 0)
		groundY = hrpPos.Y - groundOffset
	end

	for _, rig in rigs do
		updateRig(rig, dt, hrpPos, playerYawCF, groundY)
	end
end

----------------------------------------------------------------------
-- Character lifecycle (respawn re-anchors rigs; death pauses the follow)
----------------------------------------------------------------------

local function clearCharConnections()
	for _, connection in charConnections do
		connection:Disconnect()
	end
	table.clear(charConnections)
end

local function onCharacterAdded(character: Model)
	clearCharConnections()
	currentHrp = nil
	charToken += 1
	local token = charToken

	task.spawn(function()
		local hrp = character:WaitForChild("HumanoidRootPart", 30)
		local humanoid = character:WaitForChild("Humanoid", 30)
		if token ~= charToken or character.Parent == nil then
			return -- a newer character took over while we waited
		end
		if not (hrp and hrp:IsA("BasePart")) then
			return
		end

		groundOffset = 3
		if humanoid and humanoid:IsA("Humanoid") and humanoid.HipHeight > 0 then
			groundOffset = humanoid.HipHeight + hrp.Size.Y * 0.5
		end

		-- Re-anchor every rig to the new HumanoidRootPart: forget old
		-- positions so the next Heartbeat snaps them into their slots.
		for _, rig in rigs do
			rig.pos = nil
		end
		currentHrp = hrp

		if humanoid and humanoid:IsA("Humanoid") then
			table.insert(charConnections, humanoid.Died:Connect(function()
				if token == charToken then
					currentHrp = nil -- rigs idle in place until respawn
				end
			end))
		end
	end)
end

----------------------------------------------------------------------
-- Entry point
----------------------------------------------------------------------

function WorkerVisualsController.start(): ()
	if started then
		return
	end
	started = true

	local player = Players.LocalPlayer

	player.CharacterAdded:Connect(onCharacterAdded)
	player.CharacterRemoving:Connect(function()
		charToken += 1
		clearCharConnections()
		currentHrp = nil
	end)
	if player.Character then
		onCharacterAdded(player.Character)
	end

	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("Remotes")
		local dataSync = remotes:WaitForChild("DataSync")
		dataSync.OnClientEvent:Connect(applySnapshot)
	end)

	RunService.Heartbeat:Connect(onHeartbeat)
end

return WorkerVisualsController
