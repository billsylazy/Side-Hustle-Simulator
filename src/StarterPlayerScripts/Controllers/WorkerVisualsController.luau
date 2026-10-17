-- WorkerVisualsController: renders the LOCAL player's equipped workers as cute
-- chibi rigs that waddle along behind the character (art & feel guide: "workers
-- waddling around doing the hustle animation in the background").
--
-- Pure view layer, client-only: rigs are built from primitives, live in a
-- local-only Workspace folder ("WorkerRigs") and are driven purely by CFrame
-- math on a single RunService.Heartbeat connection - no physics, no server
-- instances. Equipped workers come from the DataSync snapshot (fires >=1/s)
-- and are diffed by Uid so rigs persist across syncs.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(sharedFolder:WaitForChild("GameConfig"))
local FormatNumber = require(sharedFolder:WaitForChild("FormatNumber"))

local RIG_FOLDER_NAME = "WorkerRigs"
local MAX_RIGS = 6 -- equip cap: BaseEquipSlots (3) + WorkerSlots max level (3)

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
local MOVE_THRESHOLD = 0.75 -- studs/s before a rig counts as moving
local HIDDEN_CFRAME = CFrame.new(0, -500, 0) -- parking spot before first placement

-- Palette
local COLOR_SKIN = Color3.fromRGB(255, 220, 177)
local COLOR_PANTS = Color3.fromRGB(52, 52, 72)
local COLOR_BLACK = Color3.fromRGB(18, 18, 24)
local COLOR_NAVY = Color3.fromRGB(4, 4, 53) -- #040435 stroke (UI contract)
local COLOR_WHITE = Color3.fromRGB(245, 245, 245)
local COLOR_BOARD = Color3.fromRGB(134, 87, 45)
local COLOR_FALLBACK = Color3.fromRGB(170, 170, 180)

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
-- Rig building (primitives only; everything anchored + non-colliding)
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

local function addPart(model: Model, name: string, size: Vector3, cf: CFrame, color: Color3, shape: Enum.PartType?): Part
	local part = Instance.new("Part")
	part.Name = name
	if shape then
		part.Shape = shape
	end
	part.Size = size
	part.CFrame = cf
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = model
	return part
end

local function addTagLabel(tag: BillboardGui, text: string, color: Color3, yScale: number, heightScale: number)
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, heightScale)
	label.Position = UDim2.fromScale(0, yScale)
	label.Font = Enum.Font.FredokaOne
	label.Text = text
	label.TextColor3 = color
	label.TextScaled = true

	local stroke = Instance.new("UIStroke")
	stroke.Color = COLOR_NAVY
	stroke.Thickness = 2.5
	stroke.Parent = label

	label.Parent = tag
end

local function buildNameTag(head: BasePart, workerName: string, incomePerSec: number, rarityColor: Color3)
	local tag = Instance.new("BillboardGui")
	tag.Name = "NameTag"
	tag.Adornee = head
	tag.Size = UDim2.fromScale(7, 2.4)
	tag.ExtentsOffset = Vector3.new(0, 1.3, 0) -- float above the head
	tag.MaxDistance = 80
	tag.LightInfluence = 0
	tag.AlwaysOnTop = false

	addTagLabel(tag, workerName, COLOR_WHITE, 0, 0.58)
	addTagLabel(tag, FormatNumber.money(incomePerSec) .. "/s", rarityColor, 0.58, 0.42)

	tag.Parent = head
end

-- Builds one chibi rig at the world origin (feet at y=0, facing -Z), then
-- parks it underground until the follow loop places it.
local function buildRigModel(entry: { [string]: any }): Model
	local rarity = GameConfig.getRarity(entry.Rarity)
	local shirtColor = if rarity then rarity.Color else COLOR_FALLBACK
	local prop = if rarity then rarity.Prop else "None"

	local model = Instance.new("Model")
	model.Name = "WorkerRig_" .. tostring(entry.Name)

	-- Invisible root at the feet: the pivot every PivotTo moves.
	local root = addPart(model, "RootPart", Vector3.new(0.2, 0.2, 0.2), CFrame.new(0, 0, 0), COLOR_BLACK)
	root.Transparency = 1
	model.PrimaryPart = root

	-- Stubby legs
	addPart(model, "LeftLeg", Vector3.new(0.45, 0.5, 0.45), CFrame.new(-0.38, 0.25, 0), COLOR_PANTS)
	addPart(model, "RightLeg", Vector3.new(0.45, 0.5, 0.45), CFrame.new(0.38, 0.25, 0), COLOR_PANTS)

	-- Small body block (~1.6 wide); rarity color tints the shirt
	-- (CEO's "GoldSuit" look falls out of its gold rarity color).
	addPart(model, "Body", Vector3.new(1.6, 1.4, 0.9), CFrame.new(0, 1.2, 0), shirtColor)

	-- Stubby arms (sleeves match the shirt)
	addPart(model, "LeftArm", Vector3.new(0.35, 0.85, 0.35), CFrame.new(-0.98, 1.25, 0), shirtColor)
	addPart(model, "RightArm", Vector3.new(0.35, 0.85, 0.35), CFrame.new(0.98, 1.25, 0), shirtColor)

	-- Big round head (ball ~2.2 studs), slightly sunk into the body
	local headCF = CFrame.new(0, 2.85, 0)
	local head = addPart(model, "Head", Vector3.new(2.2, 2.2, 2.2), headCF, COLOR_SKIN, Enum.PartType.Ball)

	-- Two flat black cylinder eyes (cylinder axis is X; yaw 90 points it forward)
	local eyeTurn = CFrame.Angles(0, math.rad(90), 0)
	addPart(model, "LeftEye", Vector3.new(0.1, 0.34, 0.34), headCF * CFrame.new(-0.42, 0.18, -0.97) * eyeTurn, COLOR_BLACK, Enum.PartType.Cylinder)
	addPart(model, "RightEye", Vector3.new(0.1, 0.34, 0.34), headCF * CFrame.new(0.42, 0.18, -0.97) * eyeTurn, COLOR_BLACK, Enum.PartType.Cylinder)

	-- Tiny smile
	addPart(model, "Smile", Vector3.new(0.55, 0.09, 0.1), headCF * CFrame.new(0, -0.42, -0.93), COLOR_BLACK)

	-- Rarity props (GameConfig RarityDef.Prop)
	if prop == "CoffeeCup" then
		-- White coffee cup held at the side (upright cylinder + tiny handle)
		local cupCF = CFrame.new(1.05, 0.95, -0.1)
		addPart(model, "CoffeeCup", Vector3.new(0.5, 0.36, 0.36), cupCF * CFrame.Angles(0, 0, math.rad(90)), COLOR_WHITE, Enum.PartType.Cylinder)
		addPart(model, "CupHandle", Vector3.new(0.26, 0.1, 0.1), cupCF * CFrame.new(0.26, 0, 0), COLOR_WHITE)
	elseif prop == "Clipboard" then
		-- Brown clipboard with a white paper, held in front
		local boardCF = CFrame.new(0, 1.25, -0.72) * CFrame.Angles(math.rad(-18), 0, 0)
		addPart(model, "Clipboard", Vector3.new(0.9, 1.05, 0.08), boardCF, COLOR_BOARD)
		addPart(model, "ClipboardPaper", Vector3.new(0.72, 0.85, 0.04), boardCF * CFrame.new(0, -0.03, -0.055), COLOR_WHITE)
	elseif prop == "GoldSuit" then
		-- Gold body comes from the rarity color; add the sunglasses bar
		addPart(model, "Sunglasses", Vector3.new(1.35, 0.32, 0.12), headCF * CFrame.new(0, 0.18, -1.0), COLOR_BLACK)
	end

	local income = GameConfig.getWorkerIncome(entry.Rarity, entry.Crate)
	buildNameTag(head, tostring(entry.Name), income, shirtColor)

	model:PivotTo(HIDDEN_CFRAME)
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
			rig.yaw = math.atan(-worldDir.X, -worldDir.Z)
		else
			local alpha = 1 - math.exp(-dt * FOLLOW_RATE)
			local newPos = pos:Lerp(target, alpha)
			local vel = (newPos - pos) / dt
			speed = math.sqrt(vel.X * vel.X + vel.Z * vel.Z)
			moving = speed > MOVE_THRESHOLD
			rig.pos = newPos

			if moving then
				-- Face travel direction (shortest-arc yaw smoothing).
				local desiredYaw = math.atan(-vel.X, -vel.Z)
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
	model:PivotTo(
		CFrame.new(pos.X, pos.Y + rig.bob + hopY, pos.Z)
			* CFrame.Angles(0, rig.yaw + spinYaw, 0)
			* CFrame.Angles(0, 0, rig.sway)
	)
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
		playerYawCF = CFrame.Angles(0, math.atan(-look.X, -look.Z), 0)
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
