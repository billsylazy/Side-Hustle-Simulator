--!nonstrict
-- MapBuilder: constructs the entire Side Hustle Simulator map from primitives
-- (Blocks / Balls / Cylinders / Wedges only — no meshes, no Toolbox) plus Lighting.
--
-- Contract (ARCHITECTURE.md "Map contract"):
--   Workspace.SideHustleMap (Folder)
--     Ground (Model), Plaza (Model with SpawnLocation + ring road)
--     Zones (Folder) > <ZoneId> (Model, attribute ZoneId)
--       HustleStation (Model) > PromptPart > ProximityPrompt "HustlePrompt"
--       Gate (Model, only UnlockCost > 0) > GateWall / SignPart / PromptPart > "UnlockPrompt"
--
-- Visual direction: docs/art-feel-guide.md — bright, chunky, cartoony,
-- SmoothPlastic + Neon, one signature color per zone, oversized props.
--
-- MapBuilder.build() is idempotent: it returns early if the map already exists,
-- and every Lighting effect is guarded with FindFirstChild.

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local FormatNumber = require(ReplicatedStorage.Shared.FormatNumber)

local MapBuilder = {}

----------------------------------------------------------------------
-- Layout constants (ground top is world Y = 0)
----------------------------------------------------------------------

local GROUND_SIZE = 700
local ROAD_RADIUS = 120 -- ring road disc; plaza sits on top, pads touch its edge
local PLAZA_RADIUS = 55
local ZONE_RADIUS = 150 -- distance of each zone center from origin
local PAD_SIZE = 64
local PAD_TOP = 1.5 -- top of plaza disc and of every zone pad

local RAD_90 = math.rad(90)

-- Shared palette
local NAVY = Color3.fromRGB(4, 4, 53)
local WHITE = Color3.fromRGB(248, 248, 244)
local CREAM = Color3.fromRGB(247, 238, 214)
local WOOD = Color3.fromRGB(133, 94, 62)
local DARK_WOOD = Color3.fromRGB(96, 66, 42)
local GRASS_GREEN = Color3.fromRGB(106, 192, 86)
local ROAD_GRAY = Color3.fromRGB(94, 90, 100)
local STONE = Color3.fromRGB(225, 214, 188)
local WHEEL_DARK = Color3.fromRGB(38, 38, 42)
local LEAF_GREEN = Color3.fromRGB(76, 160, 66)

----------------------------------------------------------------------
-- Primitive helpers
----------------------------------------------------------------------

type PartProps = {
	name: string?,
	parent: Instance,
	size: Vector3?,
	cframe: CFrame,
	color: Color3,
	material: Enum.Material?,
	transparency: number?,
	canCollide: boolean?,
	diameter: number?,
	height: number?,
	axis: string?, -- cylinders: "Y" (default), "X", "Z"
}

local function applyCommon(part: BasePart, props: PartProps)
	part.Name = props.name or "Part"
	part.Color = props.color
	part.Material = props.material or Enum.Material.SmoothPlastic
	part.Transparency = props.transparency or 0
	part.CanCollide = if props.canCollide ~= nil then props.canCollide else true
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
end

local function makeBlock(props: PartProps): Part
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Block
	part.Size = props.size :: Vector3
	part.CFrame = props.cframe
	applyCommon(part, props)
	part.Parent = props.parent
	return part
end

local function makeBall(props: PartProps): Part
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Ball
	part.Size = props.size :: Vector3
	part.CFrame = props.cframe
	applyCommon(part, props)
	part.Parent = props.parent
	return part
end

-- Cylinder whose length axis is vertical ("Y", default), or along "X"/"Z".
local function makeCylinder(props: PartProps): Part
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Cylinder
	local diameter = props.diameter or 1
	local height = props.height or 1
	part.Size = Vector3.new(height, diameter, diameter)
	local axis = props.axis or "Y"
	if axis == "Y" then
		part.CFrame = props.cframe * CFrame.Angles(0, 0, RAD_90)
	elseif axis == "Z" then
		part.CFrame = props.cframe * CFrame.Angles(0, RAD_90, 0)
	else -- "X": native cylinder axis
		part.CFrame = props.cframe
	end
	applyCommon(part, props)
	part.Parent = props.parent
	return part
end

-- WedgePart: full height at local +Z (back face vertical), sloping down to -Z.
local function makeWedge(props: PartProps): WedgePart
	local part = Instance.new("WedgePart")
	part.Size = props.size :: Vector3
	part.CFrame = props.cframe
	applyCommon(part, props)
	part.Parent = props.parent
	return part
end

local function makeModel(name: string, parent: Instance): Model
	local model = Instance.new("Model")
	model.Name = name
	model.Parent = parent
	return model
end

-- Invisible anchored part that carries a ProximityPrompt.
local function makePromptPart(parent: Instance, cf: CFrame): Part
	local part = Instance.new("Part")
	part.Name = "PromptPart"
	part.Size = Vector3.new(2, 2, 2)
	part.CFrame = cf
	part.Transparency = 1
	part.CanCollide = false
	part.CanTouch = false
	part.Anchored = true
	part.Parent = parent
	return part
end

local function makePrompt(
	parent: BasePart,
	name: string,
	actionText: string,
	objectText: string,
	holdDuration: number,
	maxDistance: number
): ProximityPrompt
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = name
	prompt.ActionText = actionText
	prompt.ObjectText = objectText
	prompt.HoldDuration = holdDuration
	prompt.MaxActivationDistance = maxDistance
	prompt.RequiresLineOfSight = false
	prompt.Parent = parent
	return prompt
end

local function makeTextLabel(
	parent: Instance,
	text: string,
	font: Enum.Font,
	textColor: Color3,
	position: UDim2,
	size: UDim2
): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Position = position
	label.Size = size
	label.Font = font
	label.Text = text
	label.TextColor3 = textColor
	label.TextScaled = true
	label.TextStrokeColor3 = NAVY
	label.TextStrokeTransparency = 0
	label.Parent = parent
	return label
end

-- Chunky sign board with SurfaceGui text on its front face.
local function addSignBoard(
	parent: Instance,
	cf: CFrame,
	width: number,
	height: number,
	text: string,
	boardColor: Color3,
	textColor: Color3
): Part
	local board = makeBlock({
		name = "NameBoard",
		parent = parent,
		size = Vector3.new(width, height, 0.5),
		cframe = cf,
		color = boardColor,
	})
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 30
	gui.LightInfluence = 0
	gui.Parent = board
	makeTextLabel(gui, text, Enum.Font.FredokaOne, textColor, UDim2.fromScale(0.03, 0.05), UDim2.fromScale(0.94, 0.9))
	return board
end

-- CFrame at a zone's center on the ground plane, front (-Z) facing the plaza.
local function zoneGroundCF(order: number): CFrame
	local angle = math.rad((order - 1) * 45)
	local pos = Vector3.new(math.cos(angle) * ZONE_RADIUS, 0, math.sin(angle) * ZONE_RADIUS)
	return CFrame.lookAt(pos, Vector3.new(0, 0, 0))
end

----------------------------------------------------------------------
-- Ground
----------------------------------------------------------------------

local function buildGround(map: Folder): Model
	local ground = makeModel("Ground", map)
	makeBlock({
		name = "GroundSlab",
		parent = ground,
		size = Vector3.new(GROUND_SIZE, 8, GROUND_SIZE),
		cframe = CFrame.new(0, -4, 0),
		color = GRASS_GREEN,
	})
	return ground
end

----------------------------------------------------------------------
-- Plaza: ring road, plaza disc, spawn, coin statue, lamps, benches, billboard
----------------------------------------------------------------------

local function buildLampPost(parent: Instance, cf: CFrame)
	makeCylinder({
		name = "LampBase", parent = parent, diameter = 2, height = 0.5,
		cframe = cf * CFrame.new(0, 0.25, 0), color = Color3.fromRGB(70, 70, 80),
	})
	makeCylinder({
		name = "LampPole", parent = parent, diameter = 0.7, height = 8,
		cframe = cf * CFrame.new(0, 4.25, 0), color = Color3.fromRGB(70, 70, 80),
	})
	makeBall({
		name = "LampBulb", parent = parent, size = Vector3.new(2.4, 2.4, 2.4),
		cframe = cf * CFrame.new(0, 8.9, 0), color = Color3.fromRGB(255, 232, 170),
		material = Enum.Material.Neon, canCollide = false,
	})
end

local function buildBench(parent: Instance, cf: CFrame)
	makeBlock({
		name = "BenchSeat", parent = parent, size = Vector3.new(5.5, 0.55, 1.8),
		cframe = cf * CFrame.new(0, 1.35, 0), color = WOOD,
	})
	for _, xOff in { -2.2, 2.2 } do
		makeBlock({
			name = "BenchLeg", parent = parent, size = Vector3.new(0.5, 1.1, 1.6),
			cframe = cf * CFrame.new(xOff, 0.55, 0), color = DARK_WOOD,
		})
	end
	makeBlock({
		name = "BenchBack", parent = parent, size = Vector3.new(5.5, 1.6, 0.45),
		cframe = cf * CFrame.new(0, 2.3, 0.8) * CFrame.Angles(math.rad(-8), 0, 0), color = WOOD,
	})
end

local function buildCoinStatue(parent: Instance)
	local gold = Color3.fromRGB(235, 184, 52)
	local brightGold = Color3.fromRGB(255, 215, 95)
	local bronze = Color3.fromRGB(110, 78, 28)
	makeCylinder({
		name = "StatuePedestal", parent = parent, diameter = 10, height = 2,
		cframe = CFrame.new(0, PAD_TOP + 1, 0), color = Color3.fromRGB(205, 198, 182),
	})
	makeCylinder({
		name = "StatuePedestalTop", parent = parent, diameter = 7.5, height = 1.5,
		cframe = CFrame.new(0, PAD_TOP + 2.75, 0), color = Color3.fromRGB(190, 182, 165),
	})
	-- Giant gold coin standing on its edge (cylinder axis along X)
	local coinY = PAD_TOP + 8
	makeCylinder({
		name = "StatueCoin", parent = parent, diameter = 9, height = 1.4, axis = "X",
		cframe = CFrame.new(0, coinY, 0), color = gold,
	})
	makeCylinder({
		name = "StatueCoinCore", parent = parent, diameter = 6, height = 1.5, axis = "X",
		cframe = CFrame.new(0, coinY, 0), color = brightGold,
		material = Enum.Material.Neon, canCollide = false,
	})
	-- Dollar-sign-ish bar + serifs across the coin face
	makeBlock({
		name = "StatueDollarBar", parent = parent, size = Vector3.new(1.7, 7.5, 1),
		cframe = CFrame.new(0, coinY, 0), color = bronze, canCollide = false,
	})
	makeBlock({
		name = "StatueDollarTop", parent = parent, size = Vector3.new(1.8, 0.8, 2.4),
		cframe = CFrame.new(0, coinY + 3.1, -0.6), color = bronze, canCollide = false,
	})
	makeBlock({
		name = "StatueDollarBottom", parent = parent, size = Vector3.new(1.8, 0.8, 2.4),
		cframe = CFrame.new(0, coinY - 3.1, 0.6), color = bronze, canCollide = false,
	})
end

local function buildTitleBillboard(parent: Instance)
	local angle = math.rad(157.5)
	local pos = Vector3.new(math.cos(angle) * 47, 0, math.sin(angle) * 47)
	local baseCF = CFrame.lookAt(pos, Vector3.new(0, 0, 0))
	local postColor = Color3.fromRGB(60, 62, 110)
	for _, xOff in { -9, 9 } do
		makeBlock({
			name = "BillboardPost", parent = parent, size = Vector3.new(1.2, 9, 1.2),
			cframe = baseCF * CFrame.new(xOff, PAD_TOP + 4.5, 0), color = postColor,
		})
	end
	local board = makeBlock({
		name = "BillboardBoard", parent = parent, size = Vector3.new(24, 7, 1),
		cframe = baseCF * CFrame.new(0, PAD_TOP + 11.5, 0), color = Color3.fromRGB(24, 26, 64),
	})
	-- Neon trim around the board
	local trim = Color3.fromRGB(255, 212, 31)
	for _, yOff in { -3.8, 3.8 } do
		makeBlock({
			name = "BillboardTrim", parent = parent, size = Vector3.new(25.2, 0.6, 1.2),
			cframe = baseCF * CFrame.new(0, PAD_TOP + 11.5 + yOff, 0), color = trim,
			material = Enum.Material.Neon, canCollide = false,
		})
	end
	for _, xOff in { -12.3, 12.3 } do
		makeBlock({
			name = "BillboardTrim", parent = parent, size = Vector3.new(0.6, 8.2, 1.2),
			cframe = baseCF * CFrame.new(xOff, PAD_TOP + 11.5, 0), color = trim,
			material = Enum.Material.Neon, canCollide = false,
		})
	end
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 30
	gui.LightInfluence = 0
	gui.Parent = board
	makeTextLabel(
		gui,
		"SIDE HUSTLE\nSIMULATOR",
		Enum.Font.LuckiestGuy,
		Color3.fromRGB(255, 212, 31),
		UDim2.fromScale(0.03, 0.05),
		UDim2.fromScale(0.94, 0.9)
	)
end

local function buildPlaza(map: Folder)
	local plaza = makeModel("Plaza", map)

	-- Ring road (flattened disc; the plaza disc sits on top of it)
	makeCylinder({
		name = "RingRoad", parent = plaza, diameter = ROAD_RADIUS * 2, height = 0.5,
		cframe = CFrame.new(0, 0.25, 0), color = ROAD_GRAY,
	})
	-- Plaza disc
	makeCylinder({
		name = "PlazaFloor", parent = plaza, diameter = PLAZA_RADIUS * 2, height = 1,
		cframe = CFrame.new(0, 1, 0), color = STONE,
	})
	-- Decorative inner ring around the statue
	makeCylinder({
		name = "PlazaRing", parent = plaza, diameter = 28, height = 0.18,
		cframe = CFrame.new(0, PAD_TOP + 0.05, 0), color = Color3.fromRGB(240, 226, 180),
	})

	-- Spawn (Neutral, plain — no decal clutter), facing the statue
	local spawnLocation = Instance.new("SpawnLocation")
	spawnLocation.Name = "SpawnLocation"
	spawnLocation.Size = Vector3.new(12, 1, 12)
	spawnLocation.CFrame = CFrame.lookAt(Vector3.new(-20, PAD_TOP + 0.5, 0), Vector3.new(0, PAD_TOP + 0.5, 0))
	spawnLocation.Color = Color3.fromRGB(236, 228, 205)
	spawnLocation.Material = Enum.Material.SmoothPlastic
	spawnLocation.Anchored = true
	spawnLocation.TopSurface = Enum.SurfaceType.Smooth
	spawnLocation.BottomSurface = Enum.SurfaceType.Smooth
	spawnLocation.Neutral = true
	spawnLocation.Duration = 0
	spawnLocation.Parent = plaza

	buildCoinStatue(plaza)

	-- Lamp posts around the plaza
	for i = 0, 5 do
		local angle = math.rad(10 + i * 60)
		local cf = CFrame.new(math.cos(angle) * 44, PAD_TOP, math.sin(angle) * 44)
		buildLampPost(plaza, cf)
	end

	-- Benches facing the statue
	for _, deg in { 55, 185, 300 } do
		local angle = math.rad(deg)
		local pos = Vector3.new(math.cos(angle) * 30, PAD_TOP, math.sin(angle) * 30)
		buildBench(plaza, CFrame.lookAt(pos, Vector3.new(0, PAD_TOP, 0)))
	end

	buildTitleBillboard(plaza)
end

----------------------------------------------------------------------
-- Shared zone pieces: hustle station + unlock gate
----------------------------------------------------------------------

local function buildHustleStation(
	zoneModel: Model,
	zoneCF: CFrame,
	zone,
	localPos: Vector3,
	withCounter: boolean
)
	local station = makeModel("HustleStation", zoneModel)
	local baseCF = zoneCF * CFrame.new(localPos)
	if withCounter then
		makeBlock({
			name = "CounterBase", parent = station, size = Vector3.new(7, 3, 2.6),
			cframe = baseCF * CFrame.new(0, 1.5, 0), color = zone.SignColor,
		})
		makeBlock({
			name = "CounterTop", parent = station, size = Vector3.new(8, 0.5, 3.2),
			cframe = baseCF * CFrame.new(0, 3.25, 0), color = CREAM,
		})
		makeBlock({
			name = "CounterTrim", parent = station, size = Vector3.new(7.2, 0.6, 0.2),
			cframe = baseCF * CFrame.new(0, 1.9, -1.4), color = zone.AccentColor,
			material = Enum.Material.Neon, canCollide = false,
		})
	end
	local promptPart = makePromptPart(station, baseCF * CFrame.new(0, 3, -2.4))
	makePrompt(promptPart, "HustlePrompt", zone.HustleVerb .. "!", zone.Name, 0, 12)
end

local function buildGate(zoneModel: Model, zoneCF: CFrame, zone)
	local gate = makeModel("Gate", zoneModel)
	local costText = "$" .. FormatNumber.commas(zone.UnlockCost)

	makeBlock({
		name = "GateWall", parent = gate, size = Vector3.new(26, 11, 1.2),
		cframe = zoneCF * CFrame.new(0, 5.5, -30.5), color = zone.SignColor,
		transparency = 0.45, canCollide = true,
	})
	for _, xOff in { -13.4, 13.4 } do
		makeBlock({
			name = "GatePost", parent = gate, size = Vector3.new(1.5, 12.5, 1.5),
			cframe = zoneCF * CFrame.new(xOff, 6.25, -30.5), color = zone.SignColor,
			material = Enum.Material.Neon,
		})
	end
	makeBlock({
		name = "GateTopBar", parent = gate, size = Vector3.new(28.5, 1, 1),
		cframe = zoneCF * CFrame.new(0, 12.2, -30.5), color = zone.SignColor,
		material = Enum.Material.Neon, canCollide = false,
	})
	-- Low hedges flanking the gate along the pad's front edge
	for _, xOff in { -21.5, 21.5 } do
		makeBlock({
			name = "GateHedge", parent = gate, size = Vector3.new(15, 2.6, 1.8),
			cframe = zoneCF * CFrame.new(xOff, 1.3, -30.5), color = LEAF_GREEN,
		})
	end

	-- Price sign (billboard readable from across the map)
	local signPart = makeBlock({
		name = "SignPart", parent = gate, size = Vector3.new(11, 2.6, 0.9),
		cframe = zoneCF * CFrame.new(0, 14.2, -30.5), color = zone.SignColor,
		material = Enum.Material.Neon, canCollide = false,
	})
	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromScale(2.4, 3.2) -- scales with SignPart: ~26 x 8 studs
	billboard.StudsOffset = Vector3.new(0, 1.2, 0)
	billboard.MaxDistance = 400
	billboard.LightInfluence = 0
	billboard.AlwaysOnTop = false
	billboard.Parent = signPart
	makeTextLabel(
		billboard, zone.Name, Enum.Font.FredokaOne, WHITE,
		UDim2.fromScale(0, 0), UDim2.fromScale(1, 0.55)
	)
	makeTextLabel(
		billboard, costText .. " to unlock", Enum.Font.FredokaOne, WHITE,
		UDim2.fromScale(0, 0.55), UDim2.fromScale(1, 0.45)
	)

	local promptPart = makePromptPart(gate, zoneCF * CFrame.new(0, 3.5, -28.5))
	makePrompt(promptPart, "UnlockPrompt", "Unlock", costText, 0.5, 10)
end

----------------------------------------------------------------------
-- Zone 1: Lemonade Stand — wooden stand, striped canopy, giant lemon
----------------------------------------------------------------------

local function buildLemonadeStand(zoneModel: Model, zoneCF: CFrame, zone)
	local yellow = zone.SignColor
	makeBlock({
		name = "StandBase", parent = zoneModel, size = Vector3.new(10, 3.2, 2.6),
		cframe = zoneCF * CFrame.new(0, 1.6, 9), color = WOOD,
	})
	makeBlock({
		name = "StandTop", parent = zoneModel, size = Vector3.new(11, 0.5, 3.2),
		cframe = zoneCF * CFrame.new(0, 3.45, 9), color = CREAM,
	})
	-- Striped front skirt
	for i = 0, 4 do
		makeBlock({
			name = "StandStripe", parent = zoneModel, size = Vector3.new(1.9, 2.9, 0.2),
			cframe = zoneCF * CFrame.new(-3.8 + i * 1.9, 1.65, 7.65),
			color = if i % 2 == 0 then yellow else WHITE, canCollide = false,
		})
	end
	-- Canopy posts + striped canopy
	for _, xOff in { -4.6, 4.6 } do
		makeBlock({
			name = "CanopyPost", parent = zoneModel, size = Vector3.new(0.8, 8.4, 0.8),
			cframe = zoneCF * CFrame.new(xOff, 4.2, 10.2), color = DARK_WOOD,
		})
	end
	for i = 0, 4 do
		makeBlock({
			name = "CanopyStripe", parent = zoneModel, size = Vector3.new(2.3, 0.4, 6.5),
			cframe = zoneCF * CFrame.new(-4.6 + i * 2.3, 8.6, 9.1),
			color = if i % 2 == 0 then yellow else WHITE,
		})
	end
	-- GIANT lemon on the roof (squashed ball, slightly tilted)
	local lemonCF = zoneCF * CFrame.new(0, 12.2, 9.1) * CFrame.Angles(0, 0, math.rad(10))
	makeBall({
		name = "GiantLemon", parent = zoneModel, size = Vector3.new(9, 6.8, 6.8),
		cframe = lemonCF, color = yellow, canCollide = false,
	})
	for _, xOff in { -4.2, 4.2 } do
		makeBall({
			name = "LemonTip", parent = zoneModel, size = Vector3.new(1.6, 1.6, 1.6),
			cframe = lemonCF * CFrame.new(xOff, 0, 0), color = Color3.fromRGB(235, 190, 28),
			canCollide = false,
		})
	end
	-- Pitcher + cups on the counter
	makeCylinder({
		name = "Pitcher", parent = zoneModel, diameter = 1.5, height = 2.3,
		cframe = zoneCF * CFrame.new(2.6, 4.85, 9), color = CREAM, canCollide = false,
	})
	makeBlock({
		name = "PitcherHandle", parent = zoneModel, size = Vector3.new(0.35, 1.3, 0.9),
		cframe = zoneCF * CFrame.new(3.5, 4.85, 9), color = CREAM, canCollide = false,
	})
	for _, xOff in { -2.2, -3.1 } do
		makeCylinder({
			name = "LemonadeCup", parent = zoneModel, diameter = 0.8, height = 1,
			cframe = zoneCF * CFrame.new(xOff, 4.2, 8.8), color = yellow, canCollide = false,
		})
	end
	addSignBoard(zoneModel, zoneCF * CFrame.new(0, 7.6, 6.1), 9, 2, zone.Name, NAVY, yellow)
end

----------------------------------------------------------------------
-- Zone 2: Dog Walking — park, fence, dog house, giant bone, blocky dogs
----------------------------------------------------------------------

local function buildDog(parent: Instance, cf: CFrame, color: Color3)
	local darker = color:Lerp(Color3.new(0, 0, 0), 0.3)
	makeBlock({
		name = "DogBody", parent = parent, size = Vector3.new(1.5, 1.6, 2.8),
		cframe = cf * CFrame.new(0, 1.6, 0), color = color,
	})
	for _, offset in { Vector3.new(-0.45, 0.4, -0.95), Vector3.new(0.45, 0.4, -0.95), Vector3.new(-0.45, 0.4, 0.95), Vector3.new(0.45, 0.4, 0.95) } do
		makeBlock({
			name = "DogLeg", parent = parent, size = Vector3.new(0.45, 0.8, 0.45),
			cframe = cf * CFrame.new(offset), color = color, canCollide = false,
		})
	end
	makeBlock({
		name = "DogHead", parent = parent, size = Vector3.new(1.3, 1.2, 1.1),
		cframe = cf * CFrame.new(0, 2.7, -1.5), color = color,
	})
	makeBlock({
		name = "DogSnout", parent = parent, size = Vector3.new(0.7, 0.5, 0.6),
		cframe = cf * CFrame.new(0, 2.45, -2.3), color = darker, canCollide = false,
	})
	makeBall({
		name = "DogNose", parent = parent, size = Vector3.new(0.35, 0.35, 0.35),
		cframe = cf * CFrame.new(0, 2.5, -2.65), color = Color3.fromRGB(25, 22, 22), canCollide = false,
	})
	for _, xOff in { -0.4, 0.4 } do
		makeBlock({
			name = "DogEar", parent = parent, size = Vector3.new(0.35, 0.6, 0.2),
			cframe = cf * CFrame.new(xOff, 3.4, -1.4), color = darker, canCollide = false,
		})
	end
	makeBlock({
		name = "DogTail", parent = parent, size = Vector3.new(0.3, 1.1, 0.3),
		cframe = cf * CFrame.new(0, 2.5, 1.5) * CFrame.Angles(math.rad(30), 0, 0),
		color = darker, canCollide = false,
	})
end

local function buildDogWalking(zoneModel: Model, zoneCF: CFrame, zone)
	local fenceWhite = Color3.fromRGB(242, 240, 234)
	-- White fence along both sides of the park
	for _, xOff in { -28, 28 } do
		for z = -20, 20, 10 do
			makeBlock({
				name = "FencePost", parent = zoneModel, size = Vector3.new(0.7, 2.8, 0.7),
				cframe = zoneCF * CFrame.new(xOff, 1.4, z), color = fenceWhite,
			})
		end
		for _, yOff in { 1, 2 } do
			makeBlock({
				name = "FenceRail", parent = zoneModel, size = Vector3.new(0.4, 0.35, 42),
				cframe = zoneCF * CFrame.new(xOff, yOff, 0), color = fenceWhite, canCollide = false,
			})
		end
	end
	-- Red dog house with gabled roof
	local houseRed = Color3.fromRGB(196, 60, 54)
	local roofRed = Color3.fromRGB(140, 40, 36)
	makeBlock({
		name = "DogHouse", parent = zoneModel, size = Vector3.new(8, 6, 7),
		cframe = zoneCF * CFrame.new(10, 3, 14), color = houseRed,
	})
	makeWedge({
		name = "DogHouseRoof", parent = zoneModel, size = Vector3.new(7.5, 2, 4.5),
		cframe = zoneCF * CFrame.new(7.75, 7, 14) * CFrame.Angles(0, RAD_90, 0), color = roofRed,
	})
	makeWedge({
		name = "DogHouseRoof", parent = zoneModel, size = Vector3.new(7.5, 2, 4.5),
		cframe = zoneCF * CFrame.new(12.25, 7, 14) * CFrame.Angles(0, -RAD_90, 0), color = roofRed,
	})
	makeBlock({
		name = "DogHouseDoor", parent = zoneModel, size = Vector3.new(2.6, 3.4, 0.4),
		cframe = zoneCF * CFrame.new(10, 1.9, 10.4), color = Color3.fromRGB(30, 24, 22), canCollide = false,
	})
	-- Giant white bone (cylinder + two balls at each end)
	local boneWhite = Color3.fromRGB(250, 248, 240)
	makeCylinder({
		name = "BoneShaft", parent = zoneModel, diameter = 2, height = 7, axis = "X",
		cframe = zoneCF * CFrame.new(-8, 1.5, 2) * CFrame.Angles(0, math.rad(25), 0), color = boneWhite,
	})
	local boneCF = zoneCF * CFrame.new(-8, 1.5, 2) * CFrame.Angles(0, math.rad(25), 0)
	for _, xOff in { -3.5, 3.5 } do
		for _, zOff in { -0.9, 0.9 } do
			makeBall({
				name = "BoneKnob", parent = zoneModel, size = Vector3.new(3, 3, 3),
				cframe = boneCF * CFrame.new(xOff, 0, zOff), color = boneWhite,
			})
		end
	end
	-- Two tiny blocky dogs
	buildDog(zoneModel, zoneCF * CFrame.new(-14, 0, 12) * CFrame.Angles(0, math.rad(140), 0), Color3.fromRGB(150, 103, 60))
	buildDog(zoneModel, zoneCF * CFrame.new(4, 0, -4) * CFrame.Angles(0, math.rad(-35), 0), Color3.fromRGB(240, 238, 230))
	addSignBoard(zoneModel, zoneCF * CFrame.new(10, 9.3, 14), 10, 2.2, zone.Name, NAVY, zone.SignColor)
end

----------------------------------------------------------------------
-- Zone 3: Sneaker Street — purple storefront, giant sneaker on a pedestal
----------------------------------------------------------------------

local function buildSneakerFlipping(zoneModel: Model, zoneCF: CFrame, zone)
	local wallPurple = Color3.fromRGB(74, 64, 120)
	-- Storefront
	makeBlock({
		name = "StoreBody", parent = zoneModel, size = Vector3.new(22, 14, 12),
		cframe = zoneCF * CFrame.new(0, 7, 16), color = wallPurple,
	})
	makeBlock({
		name = "StoreRoof", parent = zoneModel, size = Vector3.new(23, 0.8, 13),
		cframe = zoneCF * CFrame.new(0, 14.4, 16), color = Color3.fromRGB(50, 42, 84),
	})
	makeBlock({
		name = "StoreWindow", parent = zoneModel, size = Vector3.new(12, 5.5, 0.5),
		cframe = zoneCF * CFrame.new(-2, 5.2, 9.8), color = Color3.fromRGB(25, 22, 48),
		transparency = 0.35, canCollide = false,
	})
	makeBlock({
		name = "StoreDoor", parent = zoneModel, size = Vector3.new(4, 7.5, 0.5),
		cframe = zoneCF * CFrame.new(7.5, 3.75, 9.8), color = NAVY, canCollide = false,
	})
	-- Neon purple trim
	makeBlock({
		name = "StoreTrim", parent = zoneModel, size = Vector3.new(22.8, 0.7, 0.7),
		cframe = zoneCF * CFrame.new(0, 14, 9.9), color = zone.SignColor,
		material = Enum.Material.Neon, canCollide = false,
	})
	for _, yOff in { 2.2, 8.2 } do
		makeBlock({
			name = "WindowTrim", parent = zoneModel, size = Vector3.new(12.6, 0.4, 0.3),
			cframe = zoneCF * CFrame.new(-2, yOff, 10), color = zone.SignColor,
			material = Enum.Material.Neon, canCollide = false,
		})
	end
	-- Giant sneaker on a display pedestal
	makeCylinder({
		name = "SneakerPedestal", parent = zoneModel, diameter = 7, height = 2.4,
		cframe = zoneCF * CFrame.new(-12, 1.2, -2), color = WHITE,
	})
	local shoeCF = zoneCF * CFrame.new(-12, 0, -2)
	makeBlock({
		name = "SneakerSole", parent = zoneModel, size = Vector3.new(7.5, 0.9, 3),
		cframe = shoeCF * CFrame.new(0, 2.85, 0), color = WHITE,
	})
	makeBlock({
		name = "SneakerHeel", parent = zoneModel, size = Vector3.new(2.4, 1.6, 2.9),
		cframe = shoeCF * CFrame.new(-2.3, 4.1, 0), color = zone.SignColor,
	})
	makeBlock({
		name = "SneakerBody", parent = zoneModel, size = Vector3.new(4.5, 2.1, 2.9),
		cframe = shoeCF * CFrame.new(-0.4, 4.35, 0), color = zone.SignColor,
	})
	makeWedge({
		name = "SneakerToe", parent = zoneModel, size = Vector3.new(2.9, 1.9, 2.4),
		cframe = shoeCF * CFrame.new(2.6, 4.25, 0) * CFrame.Angles(0, -RAD_90, 0), color = zone.SignColor,
	})
	makeBlock({
		name = "SneakerSwoosh", parent = zoneModel, size = Vector3.new(2.8, 0.5, 0.2),
		cframe = shoeCF * CFrame.new(0, 4.4, -1.55) * CFrame.Angles(0, 0, math.rad(-14)),
		color = zone.AccentColor, material = Enum.Material.Neon, canCollide = false,
	})
	addSignBoard(zoneModel, zoneCF * CFrame.new(0, 11.8, 9.85), 14, 2.6, zone.Name, NAVY, zone.AccentColor)
end

----------------------------------------------------------------------
-- Zone 4: Car Wash — aqua tunnel, roller brushes, blocky car with foam
----------------------------------------------------------------------

local function buildCarWash(zoneModel: Model, zoneCF: CFrame, zone)
	local aqua = zone.SignColor
	-- Tunnel: low front wall (so the inside is visible), full back wall, roof, columns
	makeBlock({
		name = "TunnelFrontWall", parent = zoneModel, size = Vector3.new(22, 4.5, 1.2),
		cframe = zoneCF * CFrame.new(0, 2.25, 2), color = aqua,
	})
	makeBlock({
		name = "TunnelBackWall", parent = zoneModel, size = Vector3.new(22, 9, 1.2),
		cframe = zoneCF * CFrame.new(0, 4.5, 14), color = aqua,
	})
	for _, xOff in { -10.5, 10.5 } do
		makeBlock({
			name = "TunnelColumn", parent = zoneModel, size = Vector3.new(1.6, 9, 1.6),
			cframe = zoneCF * CFrame.new(xOff, 4.5, 2), color = aqua,
		})
	end
	makeBlock({
		name = "TunnelRoof", parent = zoneModel, size = Vector3.new(23, 1.2, 14),
		cframe = zoneCF * CFrame.new(0, 9.6, 8), color = Color3.fromRGB(44, 150, 170),
	})
	makeBlock({
		name = "TunnelTrim", parent = zoneModel, size = Vector3.new(23, 0.8, 0.8),
		cframe = zoneCF * CFrame.new(0, 10.3, 1.4), color = zone.AccentColor,
		material = Enum.Material.Neon, canCollide = false,
	})
	-- Big roller brushes
	for _, offset in { Vector3.new(-6, 0, 5.4), Vector3.new(0, 0, 10.6), Vector3.new(6, 0, 5.4) } do
		makeCylinder({
			name = "RollerBrush", parent = zoneModel, diameter = 3, height = 7.5,
			cframe = zoneCF * CFrame.new(offset.X, 3.75, offset.Z), color = Color3.fromRGB(30, 70, 115),
		})
	end
	-- Chunky blocky car
	makeBlock({
		name = "CarBody", parent = zoneModel, size = Vector3.new(8, 2.2, 4.2),
		cframe = zoneCF * CFrame.new(1, 2.1, 8), color = Color3.fromRGB(224, 82, 72),
	})
	makeBlock({
		name = "CarCabin", parent = zoneModel, size = Vector3.new(4, 1.8, 3.8),
		cframe = zoneCF * CFrame.new(0.6, 4.1, 8), color = Color3.fromRGB(50, 70, 95), transparency = 0.25,
	})
	for _, xOff in { -2.8, 2.8 } do
		for _, zOff in { -2.3, 2.3 } do
			makeCylinder({
				name = "CarWheel", parent = zoneModel, diameter = 2, height = 0.8, axis = "Z",
				cframe = zoneCF * CFrame.new(1 + xOff, 1, 8 + zOff), color = WHEEL_DARK,
			})
		end
	end
	-- Foam bubbles on the car
	local bubbles = {
		{ Vector3.new(0, 3.6, 7), 1.8 },
		{ Vector3.new(2.4, 3.5, 9), 1.4 },
		{ Vector3.new(-1.5, 3.4, 8.8), 1.2 },
		{ Vector3.new(0.8, 5.3, 8.2), 1.6 },
		{ Vector3.new(3.2, 3.3, 6.6), 1.1 },
		{ Vector3.new(-2.6, 3.4, 7.4), 1.3 },
	}
	for _, bubble in bubbles do
		local offset, d = bubble[1], bubble[2]
		makeBall({
			name = "FoamBubble", parent = zoneModel, size = Vector3.new(d, d, d),
			cframe = zoneCF * CFrame.new(offset), color = Color3.fromRGB(250, 250, 255),
			transparency = 0.2, canCollide = false,
		})
	end
	addSignBoard(zoneModel, zoneCF * CFrame.new(0, 11.6, 2), 14, 2.4, zone.Name, NAVY, zone.AccentColor)
end

----------------------------------------------------------------------
-- Zone 5: Food Truck — orange truck with a HUGE burger on the roof
----------------------------------------------------------------------

local function buildFoodTruck(zoneModel: Model, zoneCF: CFrame, zone)
	local orange = zone.SignColor
	local truckCF = zoneCF * CFrame.new(0, 0, 8)
	makeBlock({
		name = "TruckBody", parent = zoneModel, size = Vector3.new(15, 5, 6),
		cframe = truckCF * CFrame.new(0, 3.9, 0), color = orange,
	})
	makeBlock({
		name = "TruckCab", parent = zoneModel, size = Vector3.new(4, 3.6, 5.6),
		cframe = truckCF * CFrame.new(-9.5, 3.2, 0), color = orange,
	})
	makeBlock({
		name = "TruckWindshield", parent = zoneModel, size = Vector3.new(0.5, 1.8, 4.4),
		cframe = truckCF * CFrame.new(-11.3, 4.2, 0), color = Color3.fromRGB(50, 70, 95),
		transparency = 0.3, canCollide = false,
	})
	for _, xOff in { -9, 5 } do
		for _, zOff in { -3.4, 3.4 } do
			makeCylinder({
				name = "TruckWheel", parent = zoneModel, diameter = 2.4, height = 0.9, axis = "Z",
				cframe = truckCF * CFrame.new(xOff, 1.2, zOff), color = WHEEL_DARK,
			})
		end
	end
	-- Serving window + counter lip + awning (front side, facing the plaza)
	makeBlock({
		name = "ServingWindow", parent = zoneModel, size = Vector3.new(6, 2.4, 0.4),
		cframe = truckCF * CFrame.new(0.5, 4.4, -3.05), color = Color3.fromRGB(40, 36, 36),
		transparency = 0.25, canCollide = false,
	})
	makeBlock({
		name = "WindowCounter", parent = zoneModel, size = Vector3.new(6.6, 0.4, 1),
		cframe = truckCF * CFrame.new(0.5, 3.1, -3.5), color = CREAM,
	})
	makeBlock({
		name = "Awning", parent = zoneModel, size = Vector3.new(7, 0.4, 2.4),
		cframe = truckCF * CFrame.new(0.5, 5.9, -3.8) * CFrame.Angles(math.rad(-20), 0, 0),
		color = zone.AccentColor, canCollide = false,
	})
	-- HUGE burger on the roof: bun / patty / cheese / lettuce / top bun
	makeCylinder({
		name = "BurgerBunBottom", parent = zoneModel, diameter = 7, height = 1.4,
		cframe = truckCF * CFrame.new(0, 7.1, 0), color = Color3.fromRGB(233, 170, 92), canCollide = false,
	})
	makeCylinder({
		name = "BurgerPatty", parent = zoneModel, diameter = 7.7, height = 1,
		cframe = truckCF * CFrame.new(0, 8.3, 0), color = Color3.fromRGB(118, 70, 36), canCollide = false,
	})
	makeBlock({
		name = "BurgerCheese", parent = zoneModel, size = Vector3.new(6.9, 0.35, 6.9),
		cframe = truckCF * CFrame.new(0, 8.95, 0) * CFrame.Angles(0, math.rad(20), 0),
		color = Color3.fromRGB(255, 196, 40), canCollide = false,
	})
	makeCylinder({
		name = "BurgerLettuce", parent = zoneModel, diameter = 8.1, height = 0.6,
		cframe = truckCF * CFrame.new(0, 9.4, 0), color = Color3.fromRGB(120, 212, 80), canCollide = false,
	})
	makeBall({
		name = "BurgerBunTop", parent = zoneModel, size = Vector3.new(7.2, 3.6, 7.2),
		cframe = truckCF * CFrame.new(0, 10.6, 0), color = Color3.fromRGB(233, 170, 92), canCollide = false,
	})
	for _, offset in { Vector3.new(-1.4, 12.1, 0.8), Vector3.new(1.2, 12.2, -0.6), Vector3.new(0.2, 12.3, 1.4) } do
		makeBall({
			name = "SesameSeed", parent = zoneModel, size = Vector3.new(0.5, 0.35, 0.5),
			cframe = truckCF * CFrame.new(offset), color = CREAM, canCollide = false,
		})
	end
	-- Menu board beside the truck
	addSignBoard(zoneModel, zoneCF * CFrame.new(10.5, 4, 2), 4.2, 3, "MENU", NAVY, CREAM)
	makeBlock({
		name = "MenuPost", parent = zoneModel, size = Vector3.new(0.4, 3.2, 0.4),
		cframe = zoneCF * CFrame.new(10.5, 1.6, 2), color = DARK_WOOD,
	})
	addSignBoard(zoneModel, truckCF * CFrame.new(-0.5, 2.1, -3.5), 8, 1.4, zone.Name, NAVY, CREAM)
end

----------------------------------------------------------------------
-- Zone 6: Creator Studio — pink neon, giant ring light, tripod, play button
----------------------------------------------------------------------

local function buildContentCreator(zoneModel: Model, zoneCF: CFrame, zone)
	local pink = zone.SignColor
	-- Studio building
	makeBlock({
		name = "StudioBody", parent = zoneModel, size = Vector3.new(20, 12, 12),
		cframe = zoneCF * CFrame.new(0, 6, 16), color = Color3.fromRGB(58, 48, 70),
	})
	makeBlock({
		name = "StudioRoof", parent = zoneModel, size = Vector3.new(21, 0.8, 13),
		cframe = zoneCF * CFrame.new(0, 12.4, 16), color = Color3.fromRGB(44, 36, 54),
	})
	makeBlock({
		name = "StudioWindow", parent = zoneModel, size = Vector3.new(9, 4.5, 0.5),
		cframe = zoneCF * CFrame.new(0, 6, 9.8), color = Color3.fromRGB(28, 22, 40),
		transparency = 0.3, canCollide = false,
	})
	makeBlock({
		name = "StudioTrim", parent = zoneModel, size = Vector3.new(20.6, 0.7, 0.7),
		cframe = zoneCF * CFrame.new(0, 12.1, 10), color = pink,
		material = Enum.Material.Neon, canCollide = false,
	})
	for _, xOff in { -10.1, 10.1 } do
		makeBlock({
			name = "StudioCornerTrim", parent = zoneModel, size = Vector3.new(0.7, 12.4, 0.7),
			cframe = zoneCF * CFrame.new(xOff, 6.2, 10), color = pink,
			material = Enum.Material.Neon, canCollide = false,
		})
	end
	-- Giant ring light on a stand
	makeCylinder({
		name = "RingLightBase", parent = zoneModel, diameter = 3, height = 0.5,
		cframe = zoneCF * CFrame.new(-9, 0.25, -2), color = Color3.fromRGB(40, 38, 45),
	})
	makeCylinder({
		name = "RingLightPole", parent = zoneModel, diameter = 0.7, height = 5.5,
		cframe = zoneCF * CFrame.new(-9, 3.25, -2), color = Color3.fromRGB(40, 38, 45),
	})
	makeCylinder({
		name = "RingLight", parent = zoneModel, diameter = 9, height = 0.8, axis = "Z",
		cframe = zoneCF * CFrame.new(-9, 7, -2), color = pink,
		material = Enum.Material.Neon, canCollide = false,
	})
	makeCylinder({
		name = "RingLightInner", parent = zoneModel, diameter = 6.8, height = 0.7, axis = "Z",
		cframe = zoneCF * CFrame.new(-9, 7, -2.15), color = Color3.fromRGB(40, 38, 45), canCollide = false,
	})
	-- Phone on a tripod, filming the ring light
	local tripodCF = zoneCF * CFrame.new(-9, 0, -8.5)
	for i = 0, 2 do
		makeBlock({
			name = "TripodLeg", parent = zoneModel, size = Vector3.new(0.35, 4.4, 0.35),
			cframe = tripodCF * CFrame.Angles(0, math.rad(i * 120), 0) * CFrame.new(0, 2.1, -1) * CFrame.Angles(math.rad(14), 0, 0),
			color = Color3.fromRGB(40, 38, 45),
		})
	end
	makeBlock({
		name = "TripodHead", parent = zoneModel, size = Vector3.new(0.8, 0.8, 0.8),
		cframe = tripodCF * CFrame.new(0, 4.3, 0), color = Color3.fromRGB(40, 38, 45), canCollide = false,
	})
	makeBlock({
		name = "Phone", parent = zoneModel, size = Vector3.new(1.9, 3.4, 0.4),
		cframe = tripodCF * CFrame.new(0, 6.1, 0), color = Color3.fromRGB(20, 20, 24), canCollide = false,
	})
	makeBlock({
		name = "PhoneScreen", parent = zoneModel, size = Vector3.new(1.6, 3, 0.12),
		cframe = tripodCF * CFrame.new(0, 6.1, 0.23), color = Color3.fromRGB(255, 160, 220),
		material = Enum.Material.Neon, canCollide = false,
	})
	-- Big play-button prop: white triangle (two mirrored wedges) on a pink cube
	makeBlock({
		name = "PlayButtonBase", parent = zoneModel, size = Vector3.new(7, 0.7, 7),
		cframe = zoneCF * CFrame.new(9, 0.35, -1), color = WHITE,
	})
	makeBlock({
		name = "PlayButtonCube", parent = zoneModel, size = Vector3.new(5.5, 5.5, 5.5),
		cframe = zoneCF * CFrame.new(9, 3.45, -1), color = pink,
	})
	makeWedge({
		name = "PlayTriangleTop", parent = zoneModel, size = Vector3.new(0.8, 1.4, 2.8),
		cframe = zoneCF * CFrame.new(9, 4.15, -4.15) * CFrame.Angles(0, -RAD_90, 0),
		color = WHITE, canCollide = false,
	})
	makeWedge({
		name = "PlayTriangleBottom", parent = zoneModel, size = Vector3.new(0.8, 1.4, 2.8),
		cframe = zoneCF * CFrame.new(9, 2.75, -4.15) * CFrame.Angles(0, -RAD_90, 0) * CFrame.Angles(0, 0, math.rad(180)),
		color = WHITE, canCollide = false,
	})
	addSignBoard(zoneModel, zoneCF * CFrame.new(0, 10.4, 9.85), 14, 2.5, zone.Name, NAVY, zone.AccentColor)
end

----------------------------------------------------------------------
-- Zone 7: Stock Desk — dark office, neon ticker screens, big up arrow
----------------------------------------------------------------------

local function buildStockDesk(zoneModel: Model, zoneCF: CFrame, zone)
	local neonGreen = Color3.fromRGB(70, 255, 130)
	local screenBlack = Color3.fromRGB(12, 12, 14)
	makeBlock({
		name = "OfficeBody", parent = zoneModel, size = Vector3.new(18, 12, 12),
		cframe = zoneCF * CFrame.new(0, 6, 14), color = Color3.fromRGB(30, 32, 36),
	})
	makeBlock({
		name = "OfficeRoof", parent = zoneModel, size = Vector3.new(19, 0.8, 13),
		cframe = zoneCF * CFrame.new(0, 12.4, 14), color = Color3.fromRGB(22, 24, 28),
	})
	makeBlock({
		name = "OfficeDoor", parent = zoneModel, size = Vector3.new(3.5, 6, 0.5),
		cframe = zoneCF * CFrame.new(0, 3, 7.8), color = screenBlack, canCollide = false,
	})
	makeBlock({
		name = "OfficeTrim", parent = zoneModel, size = Vector3.new(18.6, 0.6, 0.6),
		cframe = zoneCF * CFrame.new(0, 12.1, 8), color = zone.SignColor,
		material = Enum.Material.Neon, canCollide = false,
	})
	-- Green-on-black ticker screens on the front wall
	for _, xOff in { -4.5, 4.5 } do
		makeBlock({
			name = "TickerScreen", parent = zoneModel, size = Vector3.new(6.5, 3, 0.5),
			cframe = zoneCF * CFrame.new(xOff, 6.8, 7.8), color = screenBlack, canCollide = false,
		})
		makeBlock({
			name = "TickerLine", parent = zoneModel, size = Vector3.new(5.6, 0.4, 0.15),
			cframe = zoneCF * CFrame.new(xOff, 7.5, 7.5), color = neonGreen,
			material = Enum.Material.Neon, canCollide = false,
		})
		makeBlock({
			name = "TickerLine", parent = zoneModel, size = Vector3.new(4.2, 0.4, 0.15),
			cframe = zoneCF * CFrame.new(xOff - 0.6, 6.4, 7.5), color = neonGreen,
			material = Enum.Material.Neon, canCollide = false,
		})
	end
	-- Big green up arrow on the roof (block shaft + wedge head)
	makeBlock({
		name = "ArrowShaft", parent = zoneModel, size = Vector3.new(1.6, 6, 1.2),
		cframe = zoneCF * CFrame.new(0, 15.8, 14), color = zone.SignColor,
		material = Enum.Material.Neon, canCollide = false,
	})
	makeWedge({
		name = "ArrowHeadLeft", parent = zoneModel, size = Vector3.new(1.2, 2.8, 2.2),
		cframe = zoneCF * CFrame.new(-1.1, 20.2, 14) * CFrame.Angles(0, RAD_90, 0),
		color = zone.SignColor, material = Enum.Material.Neon, canCollide = false,
	})
	makeWedge({
		name = "ArrowHeadRight", parent = zoneModel, size = Vector3.new(1.2, 2.8, 2.2),
		cframe = zoneCF * CFrame.new(1.1, 20.2, 14) * CFrame.Angles(0, -RAD_90, 0),
		color = zone.SignColor, material = Enum.Material.Neon, canCollide = false,
	})
	addSignBoard(zoneModel, zoneCF * CFrame.new(0, 10.6, 7.85), 13, 2.5, zone.Name, screenBlack, zone.SignColor)
end

----------------------------------------------------------------------
-- Zone 8: Startup HQ — sleek tower with glass bands, logo cube, rocket
----------------------------------------------------------------------

local function buildStartupHQ(zoneModel: Model, zoneCF: CFrame, zone)
	local glassBlue = Color3.fromRGB(90, 150, 255)
	local towerCF = zoneCF * CFrame.new(0, 0, 18)
	local tiers = {
		{ size = Vector3.new(16, 5, 16), y = 2.5, color = WHITE, transparency = 0 },
		{ size = Vector3.new(16.4, 1.8, 16.4), y = 6.4, color = glassBlue, transparency = 0.4 },
		{ size = Vector3.new(14, 5, 14), y = 9.8, color = WHITE, transparency = 0 },
		{ size = Vector3.new(14.4, 1.8, 14.4), y = 13.2, color = glassBlue, transparency = 0.4 },
		{ size = Vector3.new(12, 5, 12), y = 16.6, color = WHITE, transparency = 0 },
		{ size = Vector3.new(10, 2, 10), y = 20.1, color = WHITE, transparency = 0 },
	}
	for _, tier in tiers do
		makeBlock({
			name = "TowerTier", parent = zoneModel, size = tier.size,
			cframe = towerCF * CFrame.new(0, tier.y, 0), color = tier.color,
			transparency = tier.transparency,
		})
	end
	makeBlock({
		name = "TowerDoor", parent = zoneModel, size = Vector3.new(3.5, 5.5, 0.6),
		cframe = towerCF * CFrame.new(0, 2.75, -8.1), color = Color3.fromRGB(40, 60, 100), canCollide = false,
	})
	-- Blue neon logo cube on a small pole, tilted like a diamond
	makeBlock({
		name = "LogoPole", parent = zoneModel, size = Vector3.new(0.4, 1.6, 0.4),
		cframe = towerCF * CFrame.new(0, 21.9, 0), color = WHITE, canCollide = false,
	})
	makeBlock({
		name = "LogoCube", parent = zoneModel, size = Vector3.new(2.8, 2.8, 2.8),
		cframe = towerCF * CFrame.new(0, 23.2, 0) * CFrame.Angles(math.rad(35), math.rad(45), 0),
		color = zone.AccentColor, material = Enum.Material.Neon, canCollide = false,
	})
	-- Small rocket statue: cylinder body, crossed-wedge nose cone, wedge fins
	local rocketCF = zoneCF * CFrame.new(-12, 0, -4)
	makeCylinder({
		name = "RocketPedestal", parent = zoneModel, diameter = 5.5, height = 1.2,
		cframe = rocketCF * CFrame.new(0, 0.6, 0), color = Color3.fromRGB(205, 198, 182),
	})
	makeCylinder({
		name = "RocketBody", parent = zoneModel, diameter = 3, height = 7,
		cframe = rocketCF * CFrame.new(0, 4.7, 0), color = Color3.fromRGB(244, 244, 248),
	})
	makeBall({
		name = "RocketWindow", parent = zoneModel, size = Vector3.new(1.3, 1.3, 1.3),
		cframe = rocketCF * CFrame.new(0, 5.6, -1.4), color = zone.AccentColor,
		material = Enum.Material.Neon, canCollide = false,
	})
	-- Nose cone: two crossed wedge pairs
	local noseY = 9.6
	makeWedge({
		name = "RocketNose", parent = zoneModel, size = Vector3.new(2.4, 2.8, 1.5),
		cframe = rocketCF * CFrame.new(-0.75, noseY, 0) * CFrame.Angles(0, RAD_90, 0),
		color = zone.AccentColor, canCollide = false,
	})
	makeWedge({
		name = "RocketNose", parent = zoneModel, size = Vector3.new(2.4, 2.8, 1.5),
		cframe = rocketCF * CFrame.new(0.75, noseY, 0) * CFrame.Angles(0, -RAD_90, 0),
		color = zone.AccentColor, canCollide = false,
	})
	makeWedge({
		name = "RocketNose", parent = zoneModel, size = Vector3.new(2.4, 2.8, 1.5),
		cframe = rocketCF * CFrame.new(0, noseY, -0.75),
		color = zone.AccentColor, canCollide = false,
	})
	makeWedge({
		name = "RocketNose", parent = zoneModel, size = Vector3.new(2.4, 2.8, 1.5),
		cframe = rocketCF * CFrame.new(0, noseY, 0.75) * CFrame.Angles(0, math.rad(180), 0),
		color = zone.AccentColor, canCollide = false,
	})
	-- Fins (vertical face against the body, sloping down and out)
	local finSpecs = {
		{ offset = Vector3.new(2.2, 2.6, 0), yaw = -RAD_90 },
		{ offset = Vector3.new(-2.2, 2.6, 0), yaw = RAD_90 },
		{ offset = Vector3.new(0, 2.6, 2.2), yaw = math.rad(180) },
		{ offset = Vector3.new(0, 2.6, -2.2), yaw = 0 },
	}
	for _, fin in finSpecs do
		makeWedge({
			name = "RocketFin", parent = zoneModel, size = Vector3.new(0.5, 2.8, 1.9),
			cframe = rocketCF * CFrame.new(fin.offset) * CFrame.Angles(0, fin.yaw, 0),
			color = zone.AccentColor, canCollide = false,
		})
	end
	addSignBoard(zoneModel, towerCF * CFrame.new(0, 8.5, -8.1), 12, 2.2, zone.Name, NAVY, zone.AccentColor)
end

----------------------------------------------------------------------
-- Generic fallback for any future zone id without a bespoke builder
----------------------------------------------------------------------

local function buildGenericZone(zoneModel: Model, zoneCF: CFrame, zone)
	makeBlock({
		name = "Building", parent = zoneModel, size = Vector3.new(20, 12, 12),
		cframe = zoneCF * CFrame.new(0, 6, 16), color = zone.SignColor,
	})
	addSignBoard(zoneModel, zoneCF * CFrame.new(0, 10, 9.8), 14, 2.5, zone.Name, NAVY, zone.AccentColor)
end

local ZONE_BUILDERS: { [string]: (Model, CFrame, any) -> () } = {
	LemonadeStand = buildLemonadeStand,
	DogWalking = buildDogWalking,
	SneakerFlipping = buildSneakerFlipping,
	CarWash = buildCarWash,
	FoodTruck = buildFoodTruck,
	ContentCreator = buildContentCreator,
	StockDesk = buildStockDesk,
	StartupHQ = buildStartupHQ,
}

-- Station counter position per zone (local to the zone, on the pad top)
local STATION_POS: { [string]: Vector3 } = {
	LemonadeStand = Vector3.new(0, 0, 7),
	DogWalking = Vector3.new(0, 0, -12),
	SneakerFlipping = Vector3.new(6, 0, -8),
	CarWash = Vector3.new(0, 0, -12),
	FoodTruck = Vector3.new(0, 0, -2),
	ContentCreator = Vector3.new(0, 0, -8),
	StockDesk = Vector3.new(0, 0, -8),
	StartupHQ = Vector3.new(6, 0, -8),
}

local function buildZone(zonesFolder: Folder, zone)
	local groundCF = zoneGroundCF(zone.Order)

	local zoneModel = Instance.new("Model")
	zoneModel.Name = zone.Id
	zoneModel:SetAttribute("ZoneId", zone.Id)
	zoneModel.Parent = zonesFolder

	-- Colored floor pad (signature color, desaturated enough to walk on)
	local padColor = zone.SignColor:Lerp(Color3.fromRGB(152, 148, 144), 0.6)
	-- 1.5 thick so the pad bottom meets the ground top (Y=0): no floating seam.
	makeBlock({
		name = "ZonePad", parent = zoneModel, size = Vector3.new(PAD_SIZE, 1.5, PAD_SIZE),
		cframe = groundCF * CFrame.new(0, 0.75, 0), color = padColor,
	})

	local zoneCF = groundCF * CFrame.new(0, PAD_TOP, 0)
	local builder = ZONE_BUILDERS[zone.Id] or buildGenericZone
	builder(zoneModel, zoneCF, zone)

	local stationPos = STATION_POS[zone.Id] or Vector3.new(0, 0, -10)
	buildHustleStation(zoneModel, zoneCF, zone, stationPos, zone.Id ~= "LemonadeStand")

	if zone.UnlockCost > 0 then
		buildGate(zoneModel, zoneCF, zone)
	end
end

----------------------------------------------------------------------
-- Decor: simple trees and bushes scattered between zones
----------------------------------------------------------------------

local function buildTree(parent: Instance, position: Vector3, scale: number)
	local cf = CFrame.new(position)
	makeCylinder({
		name = "TreeTrunk", parent = parent, diameter = 1.6 * scale, height = 6 * scale,
		cframe = cf * CFrame.new(0, 3 * scale, 0), color = DARK_WOOD,
	})
	makeBall({
		name = "TreeLeaves", parent = parent,
		size = Vector3.new(6, 6, 6) * scale,
		cframe = cf * CFrame.new(0, 6.5 * scale, 0), color = LEAF_GREEN, canCollide = false,
	})
	makeBall({
		name = "TreeLeaves", parent = parent,
		size = Vector3.new(4.6, 4.6, 4.6) * scale,
		cframe = cf * CFrame.new(1.2 * scale, 8 * scale, 0.8 * scale), color = Color3.fromRGB(88, 176, 74), canCollide = false,
	})
	makeBall({
		name = "TreeLeaves", parent = parent,
		size = Vector3.new(4, 4, 4) * scale,
		cframe = cf * CFrame.new(-1.4 * scale, 7.4 * scale, -0.6 * scale), color = Color3.fromRGB(96, 188, 80), canCollide = false,
	})
end

local function buildBush(parent: Instance, position: Vector3, scale: number)
	makeBall({
		name = "Bush", parent = parent,
		size = Vector3.new(3.6, 2.6, 3.6) * scale,
		cframe = CFrame.new(position + Vector3.new(0, 1 * scale, 0)), color = LEAF_GREEN, canCollide = false,
	})
end

local function buildDecor(parent: Instance)
	for i = 0, 7 do
		-- Trees between neighboring zones
		local betweenAngle = math.rad(i * 45 + 22.5)
		buildTree(parent, Vector3.new(math.cos(betweenAngle) * 152, 0, math.sin(betweenAngle) * 152), if i % 2 == 0 then 1 else 1.25)
		-- Outer tree ring
		local outerA = math.rad(i * 45 + 8)
		buildTree(parent, Vector3.new(math.cos(outerA) * 225, 0, math.sin(outerA) * 225), 1.4)
		local outerB = math.rad(i * 45 + 37)
		buildTree(parent, Vector3.new(math.cos(outerB) * 230, 0, math.sin(outerB) * 230), 1.1)
		-- Bushes along the road edge and further out
		local bushA = math.rad(i * 45 + 22.5)
		buildBush(parent, Vector3.new(math.cos(bushA) * 128, 0, math.sin(bushA) * 128), 1.1)
		local bushB = math.rad(i * 45 - 12)
		buildBush(parent, Vector3.new(math.cos(bushB) * 195, 0, math.sin(bushB) * 195), 1.3)
	end
end

----------------------------------------------------------------------
-- Lighting: bright cheerful day + gentle color pop + bloom for the neon
----------------------------------------------------------------------

local function setupLighting()
	Lighting.ClockTime = 12
	Lighting.Brightness = 3
	Lighting.GlobalShadows = true
	Lighting.ShadowSoftness = 1
	Lighting.Ambient = Color3.fromRGB(126, 118, 104)
	Lighting.OutdoorAmbient = Color3.fromRGB(166, 156, 136)

	if not Lighting:FindFirstChild("SideHustleColorCorrection") then
		local colorCorrection = Instance.new("ColorCorrectionEffect")
		colorCorrection.Name = "SideHustleColorCorrection"
		colorCorrection.Saturation = 0.15
		colorCorrection.Contrast = 0.05
		colorCorrection.Brightness = 0.02
		colorCorrection.Parent = Lighting
	end
	if not Lighting:FindFirstChild("SideHustleBloom") then
		local bloom = Instance.new("BloomEffect")
		bloom.Name = "SideHustleBloom"
		bloom.Intensity = 0.45
		bloom.Size = 24
		bloom.Threshold = 1.1
		bloom.Parent = Lighting
	end
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

function MapBuilder.build(): ()
	if Workspace:FindFirstChild("SideHustleMap") then
		return
	end

	local map = Instance.new("Folder")
	map.Name = "SideHustleMap"

	local ground = buildGround(map)
	buildPlaza(map)

	local zonesFolder = Instance.new("Folder")
	zonesFolder.Name = "Zones"
	zonesFolder.Parent = map

	for _, zone in GameConfig.Zones do
		buildZone(zonesFolder, zone)
	end

	buildDecor(ground)
	setupLighting()

	map.Parent = Workspace
end

return MapBuilder
