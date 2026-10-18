-- ChibiRig: builds a cute chibi character Model from primitives (big round
-- head, stubby body/arms/legs, flat eyes, a smile, an optional rarity prop and
-- a BillboardGui name tag). Pure view-layer helper used on the client by
-- WorkerVisualsController (companions) and AutomationVisualsController
-- (stationed automation rigs). Every part is Anchored, non-colliding,
-- non-queryable and casts no shadow, so rigs are driven purely by CFrame math.
--
-- API
--   ChibiRig.build(spec) -> Model        (UNPARENTED; feet at y=0, facing -Z)
--   ChibiRig.setPose(model, cframe, overrides?)
--       places the rig (PivotTo) and optionally poses named parts with a
--       local CFrame offset about their rest center, e.g.
--       { Head = CFrame.Angles(0, yaw, 0), LeftArm = CFrame.Angles(pitch, 0, 0) }.
--       Eyes/smile/sunglasses follow the Head; the coffee cup follows RightArm.
--       Parts posed last frame but not this frame snap back to rest.
--   ChibiRig.setLabel(model, text, color?) -> boolean   (second name-tag line)

local GameConfig = require(script.Parent:WaitForChild("GameConfig"))

local ChibiRig = {}

export type RigSpec = {
	Name: string,
	Rarity: string?, -- "Intern" | "Employee" | "Manager" | "CEO" (defaults BodyColor/Prop)
	Prop: string?, -- "CoffeeCup" | "Clipboard" | "GoldSuit" | "None" (overrides rarity)
	BodyColor: Color3?, -- overrides the rarity color
	Label: string?, -- second tag line ("$6/s", "Lv 3"); omitted -> name only
	LabelColor: Color3?, -- defaults to the body color
}

-- Palette
local COLOR_SKIN = Color3.fromRGB(255, 220, 177)
local COLOR_PANTS = Color3.fromRGB(52, 52, 72)
local COLOR_BLACK = Color3.fromRGB(18, 18, 24)
local COLOR_NAVY = Color3.fromRGB(4, 4, 53) -- #040435 stroke (UI contract)
local COLOR_WHITE = Color3.fromRGB(245, 245, 245)
local COLOR_BOARD = Color3.fromRGB(134, 87, 45)
local COLOR_FALLBACK = Color3.fromRGB(170, 170, 180)

-- Rig dimensions (studs), handy for callers placing effects around a rig.
ChibiRig.HEIGHT = 3.95 -- feet to the top of the head
ChibiRig.HEAD_CENTER_Y = 2.85

-- Parts that ride along when a pivot part is posed via setPose overrides.
local POSE_GROUPS: { [string]: { string } } = {
	Head = { "LeftEye", "RightEye", "Smile", "Sunglasses" },
	RightArm = { "CoffeeCup", "CupHandle" },
	LeftArm = {},
	Body = { "Clipboard", "ClipboardPaper" },
}

local IDENTITY = CFrame.new()

type RigRecord = {
	rest: { [string]: CFrame }, -- part name -> CFrame relative to the root (feet)
	parts: { [string]: BasePart },
	posed: { [string]: boolean }, -- parts currently holding a non-rest override
	nameLabel: TextLabel?,
	label: TextLabel?,
}

-- Weak-keyed so destroyed models drop their records automatically.
local records: { [Model]: RigRecord } = setmetatable({}, { __mode = "k" }) :: any

----------------------------------------------------------------------
-- Builders
----------------------------------------------------------------------

local function addPart(
	model: Model,
	record: RigRecord,
	name: string,
	size: Vector3,
	cf: CFrame,
	color: Color3,
	shape: Enum.PartType?
): Part
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
	record.rest[name] = cf
	record.parts[name] = part
	return part
end

local function addTagLabel(tag: BillboardGui, name: string, text: string, color: Color3, yScale: number, heightScale: number): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
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
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Parent = label

	label.Parent = tag
	return label
end

-- Builds one chibi rig at the world origin (feet at y=0, facing -Z). The
-- returned Model is unparented; the caller parents it (and usually parks it
-- out of sight with setPose until its first real placement).
function ChibiRig.build(spec: RigSpec): Model
	local rarity = if type(spec.Rarity) == "string" then GameConfig.getRarity(spec.Rarity) else nil
	local bodyColor: Color3 = spec.BodyColor or (if rarity then rarity.Color else COLOR_FALLBACK)
	local prop: string = spec.Prop or (if rarity then rarity.Prop else "None")
	local displayName = tostring(spec.Name)

	local model = Instance.new("Model")
	model.Name = "ChibiRig_" .. displayName
	local record: RigRecord = { rest = {}, parts = {}, posed = {}, nameLabel = nil, label = nil }

	-- Invisible root at the feet: the pivot every setPose moves.
	local root = addPart(model, record, "RootPart", Vector3.new(0.2, 0.2, 0.2), CFrame.new(0, 0, 0), COLOR_BLACK)
	root.Transparency = 1
	model.PrimaryPart = root

	-- Stubby legs
	addPart(model, record, "LeftLeg", Vector3.new(0.45, 0.5, 0.45), CFrame.new(-0.38, 0.25, 0), COLOR_PANTS)
	addPart(model, record, "RightLeg", Vector3.new(0.45, 0.5, 0.45), CFrame.new(0.38, 0.25, 0), COLOR_PANTS)

	-- Small body block (~1.6 wide); the body color tints the shirt
	-- (CEO's "GoldSuit" look falls out of its gold rarity color).
	addPart(model, record, "Body", Vector3.new(1.6, 1.4, 0.9), CFrame.new(0, 1.2, 0), bodyColor)

	-- Stubby arms (sleeves match the shirt)
	addPart(model, record, "LeftArm", Vector3.new(0.35, 0.85, 0.35), CFrame.new(-0.98, 1.25, 0), bodyColor)
	addPart(model, record, "RightArm", Vector3.new(0.35, 0.85, 0.35), CFrame.new(0.98, 1.25, 0), bodyColor)

	-- Big round head (ball ~2.2 studs), slightly sunk into the body
	local headCF = CFrame.new(0, ChibiRig.HEAD_CENTER_Y, 0)
	local head = addPart(model, record, "Head", Vector3.new(2.2, 2.2, 2.2), headCF, COLOR_SKIN, Enum.PartType.Ball)

	-- Two flat black cylinder eyes (cylinder axis is X; yaw 90 points it forward)
	local eyeTurn = CFrame.Angles(0, math.rad(90), 0)
	addPart(model, record, "LeftEye", Vector3.new(0.1, 0.34, 0.34), headCF * CFrame.new(-0.42, 0.18, -0.97) * eyeTurn, COLOR_BLACK, Enum.PartType.Cylinder)
	addPart(model, record, "RightEye", Vector3.new(0.1, 0.34, 0.34), headCF * CFrame.new(0.42, 0.18, -0.97) * eyeTurn, COLOR_BLACK, Enum.PartType.Cylinder)

	-- Tiny smile
	addPart(model, record, "Smile", Vector3.new(0.55, 0.09, 0.1), headCF * CFrame.new(0, -0.42, -0.93), COLOR_BLACK)

	-- Props (GameConfig RarityDef.Prop names)
	if prop == "CoffeeCup" then
		-- White coffee cup held at the right side (upright cylinder + tiny handle)
		local cupCF = CFrame.new(1.05, 0.95, -0.1)
		addPart(model, record, "CoffeeCup", Vector3.new(0.5, 0.36, 0.36), cupCF * CFrame.Angles(0, 0, math.rad(90)), COLOR_WHITE, Enum.PartType.Cylinder)
		addPart(model, record, "CupHandle", Vector3.new(0.26, 0.1, 0.1), cupCF * CFrame.new(0.26, 0, 0), COLOR_WHITE)
	elseif prop == "Clipboard" then
		-- Brown clipboard with a white paper, held in front
		local boardCF = CFrame.new(0, 1.25, -0.72) * CFrame.Angles(math.rad(-18), 0, 0)
		addPart(model, record, "Clipboard", Vector3.new(0.9, 1.05, 0.08), boardCF, COLOR_BOARD)
		addPart(model, record, "ClipboardPaper", Vector3.new(0.72, 0.85, 0.04), boardCF * CFrame.new(0, -0.03, -0.055), COLOR_WHITE)
	elseif prop == "GoldSuit" then
		-- Gold body comes from the color; add the sunglasses bar
		addPart(model, record, "Sunglasses", Vector3.new(1.35, 0.32, 0.12), headCF * CFrame.new(0, 0.18, -1.0), COLOR_BLACK)
	end

	-- Name tag floating above the head
	local hasLabel = type(spec.Label) == "string" and spec.Label ~= ""
	local tag = Instance.new("BillboardGui")
	tag.Name = "NameTag"
	tag.Adornee = head
	tag.Size = if hasLabel then UDim2.fromScale(7, 2.4) else UDim2.fromScale(7, 1.4)
	tag.ExtentsOffset = Vector3.new(0, 1.3, 0)
	tag.MaxDistance = 80
	tag.LightInfluence = 0
	tag.AlwaysOnTop = false
	if hasLabel then
		record.nameLabel = addTagLabel(tag, "Name", displayName, COLOR_WHITE, 0, 0.58)
		record.label = addTagLabel(tag, "Label", spec.Label :: string, spec.LabelColor or bodyColor, 0.58, 0.42)
	else
		record.nameLabel = addTagLabel(tag, "Name", displayName, COLOR_WHITE, 0, 1)
	end
	tag.Parent = head

	records[model] = record
	return model
end

----------------------------------------------------------------------
-- Posing
----------------------------------------------------------------------

-- Applies `offset` to a named part about its rest center (and drags its
-- pose group along). Returns true when the part exists.
local function applyOverride(record: RigRecord, rootCF: CFrame, partName: string, offset: CFrame): boolean
	local pivotRest = record.rest[partName]
	local part = record.parts[partName]
	if pivotRest == nil or part == nil or part.Parent == nil then
		return false
	end
	local pivotCF = rootCF * pivotRest * offset
	part.CFrame = pivotCF

	local group = POSE_GROUPS[partName]
	if group then
		-- new child = root * pivotRest * offset * pivotRest^-1 * childRest
		local relative = pivotCF * pivotRest:Inverse()
		for _, childName in group do
			local childRest = record.rest[childName]
			local child = record.parts[childName]
			if childRest and child and child.Parent ~= nil then
				child.CFrame = relative * childRest
			end
		end
	end
	return true
end

-- Places the rig with its feet at `cframe` (facing -Z of the frame). Optional
-- `overrides` pose named parts with a local CFrame about their rest center.
function ChibiRig.setPose(model: Model, cframe: CFrame, overrides: { [string]: CFrame }?)
	model:PivotTo(cframe)

	local record = records[model]
	if record == nil then
		return -- not built by ChibiRig: PivotTo is all we can do
	end

	-- Parts posed last call but not this one snap back to rest.
	local posed = record.posed
	if next(posed) ~= nil then
		for partName in posed do
			if overrides == nil or overrides[partName] == nil then
				applyOverride(record, cframe, partName, IDENTITY)
				posed[partName] = nil
			end
		end
	end

	if overrides then
		for partName, offset in overrides do
			if typeof(offset) == "CFrame" and applyOverride(record, cframe, partName, offset) then
				posed[partName] = true
			end
		end
	end
end

-- Updates the second name-tag line (e.g. "Lv 3"). Returns false when the rig
-- was built without a Label.
function ChibiRig.setLabel(model: Model, text: string, color: Color3?): boolean
	local record = records[model]
	if record == nil or record.label == nil then
		return false
	end
	local label = record.label :: TextLabel
	if label.Parent == nil then
		return false
	end
	label.Text = tostring(text)
	if typeof(color) == "Color3" then
		label.TextColor3 = color
	end
	return true
end

-- Rest-relative CFrame of a named part (nil if unknown). Useful for placing
-- effects at, say, the head.
function ChibiRig.getRestOffset(model: Model, partName: string): CFrame?
	local record = records[model]
	return if record then record.rest[partName] else nil
end

return ChibiRig
