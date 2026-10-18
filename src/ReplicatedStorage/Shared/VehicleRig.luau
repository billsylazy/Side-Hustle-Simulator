--!nonstrict
-- VehicleRig: chunky cartoon vehicles built from primitives (the ChibiRig of
-- cars). PURE builder: it only creates Instances (no services, no state, no
-- motion), so the client city life (CityLifeController via Shared/CityLifeSim)
-- and the offline render preview (tools/render/preview_life.luau) build the
-- exact same vehicles.
--
-- API
--   VehicleRig.KINDS[kind] -> { length, width, height, speed, maxPitch? }  (studs, studs/s)
--       kinds: "Car" | "Taxi" | "Bus" | "IceCreamVan" | "Truck" (delivery box truck) |
--       "Police" (white car, blue hood + doors with "POLICE" painted on both doors,
--       roof lightbar whose Neon halves are named "LightbarRed" / "LightbarBlue":
--       CityLifeSim flashes them by Transparency)
--   VehicleRig.build(kind, color?) -> Model
--       UNPARENTED; tire bottoms at y = 0, centered on X/Z, nose toward -Z
--       (+X = the vehicle's right side). Parts named "Wheel" / "Hubcap" stay
--       on the road; every other part rides the suspension (CityLifeSim bobs and
--       pitches it). Every part is Anchored, CanCollide / CanQuery / CanTouch
--       false; only the chassis (bus: its body; truck: cab + cargo box) casts a shadow.
--   VehicleRig.buildBlimp() -> Model
--       UNPARENTED "SIDE HUSTLE CITY" blimp centered on the origin, nose toward -Z
--       (54 long, 14 thick, banner boards on both sides).
--   VehicleRig.buildBalloon(color) -> Model
--       UNPARENTED hot-air balloon (5 parts) centered on its 14-dia envelope:
--       white equator band, wooden basket 5 studs below the envelope bottom
--       (basket bottom VehicleRig.BALLOON_DROP = 14.4 below the center), 2 ropes.
--   VehicleRig.isWheel(part) -> boolean

local VehicleRig = {}

local RAD_90 = math.pi / 2

local WHITE = Color3.fromRGB(248, 248, 244)
local NAVY = Color3.fromRGB(4, 4, 53)
local GLASS = Color3.fromRGB(170, 225, 255)
local TIRE = Color3.fromRGB(38, 38, 42)
local HUBCAP = Color3.fromRGB(235, 235, 240)
local BUMPER = Color3.fromRGB(230, 230, 236)
local HEADLIGHT = Color3.fromRGB(255, 248, 210)
local TAILLIGHT = Color3.fromRGB(255, 60, 60)
local TAXI_YELLOW = Color3.fromRGB(255, 206, 40)
local BUS_ORANGE = Color3.fromRGB(255, 150, 40)
local VAN_PINK = Color3.fromRGB(255, 180, 220)

VehicleRig.TAXI_YELLOW = TAXI_YELLOW
VehicleRig.BUS_ORANGE = BUS_ORANGE
VehicleRig.VAN_PINK = VAN_PINK

-- length / width include bumpers and wheels; speed is the cruise speed;
-- maxPitch (radians, optional) caps the brake / accelerate pitch.
VehicleRig.KINDS = {
	Car = { length = 12, width = 7.3, height = 5.4, speed = 20 },
	Taxi = { length = 12, width = 7.3, height = 6.3, speed = 20 },
	IceCreamVan = { length = 12, width = 7.3, height = 13, speed = 18 },
	Bus = { length = 23, width = 8, height = 7.7, speed = 14 },
	-- tall box: a gentle pitch keeps its roof under the signal heads (bottom Y 10.2)
	Truck = { length = 19.6, width = 8, height = 9.0, speed = 13, maxPitch = 0.02 },
	-- the Car's dimensions + a 1.05-tall roof lightbar
	Police = { length = 12, width = 7.3, height = 6.45, speed = 20 },
}
VehicleRig.POLICE_RED = Color3.fromRGB(255, 60, 60)
VehicleRig.POLICE_BLUE = Color3.fromRGB(60, 120, 255)

----------------------------------------------------------------------
-- Part helpers
----------------------------------------------------------------------

local function addPart(
	model: Model,
	name: string,
	shape: Enum.PartType,
	size: Vector3,
	cf: CFrame,
	color: Color3,
	material: Enum.Material?,
	castShadow: boolean?
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Shape = shape
	part.Size = size
	part.CFrame = cf
	part.Color = color
	part.Material = material or Enum.Material.SmoothPlastic
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = castShadow == true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = model
	return part
end

local function block(model: Model, name: string, size: Vector3, pos: Vector3, color: Color3, material: Enum.Material?, castShadow: boolean?): Part
	return addPart(model, name, Enum.PartType.Block, size, CFrame.new(pos), color, material, castShadow)
end

local function ball(model: Model, name: string, diameter: number, pos: Vector3, color: Color3, material: Enum.Material?): Part
	return addPart(model, name, Enum.PartType.Ball, Vector3.new(diameter, diameter, diameter), CFrame.new(pos), color, material)
end

-- Cylinder along X (native axis): `length` x `diameter`.
local function cylinderX(model: Model, name: string, length: number, diameter: number, pos: Vector3, color: Color3): Part
	return addPart(model, name, Enum.PartType.Cylinder, Vector3.new(length, diameter, diameter), CFrame.new(pos), color)
end

-- Upright cylinder (axis rolled onto Y).
local function cylinderY(model: Model, name: string, height: number, diameter: number, pos: Vector3, color: Color3): Part
	return addPart(
		model,
		name,
		Enum.PartType.Cylinder,
		Vector3.new(height, diameter, diameter),
		CFrame.new(pos) * CFrame.Angles(0, 0, RAD_90),
		color
	)
end

local function wedge(model: Model, name: string, size: Vector3, cf: CFrame, color: Color3): WedgePart
	local part = Instance.new("WedgePart")
	part.Name = name
	part.Size = size
	part.CFrame = cf
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = model
	return part
end

local function surfaceText(part: BasePart, face: Enum.NormalId, text: string, color: Color3, font: Enum.Font?, pixelsPerStud: number?)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Text" .. face.Name
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = pixelsPerStud or 40
	gui.LightInfluence = 0
	gui.Parent = part
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Position = UDim2.fromScale(0.04, 0.06)
	label.Size = UDim2.fromScale(0.92, 0.88)
	label.Font = font or Enum.Font.FredokaOne
	label.Text = text
	label.TextColor3 = color
	label.TextScaled = true
	label.TextStrokeColor3 = NAVY
	label.TextStrokeTransparency = 0
	label.Parent = gui
end

local function wheels(model: Model, x: number, y: number, zs: { number })
	for _, z in zs do
		for _, side in { -1, 1 } do
			cylinderX(model, "Wheel", 1.2, 2.6, Vector3.new(side * x, y, z), TIRE)
			cylinderX(model, "Hubcap", 0.12, 1.2, Vector3.new(side * (x + 0.62), y, z), HUBCAP)
		end
	end
end

local function lights(model: Model, x: number, y: number, zFront: number, zBack: number, size: Vector3)
	for _, side in { -1, 1 } do
		block(model, "Headlight", size, Vector3.new(side * x, y, zFront), HEADLIGHT, Enum.Material.Neon)
		block(model, "Taillight", size, Vector3.new(side * x, y, zBack), TAILLIGHT, Enum.Material.Neon)
	end
end

local function bumpers(model: Model, width: number, y: number, z: number)
	for _, side in { -1, 1 } do
		block(model, "Bumper", Vector3.new(width, 0.8, 0.6), Vector3.new(0, y, side * z), BUMPER)
	end
end

----------------------------------------------------------------------
-- Vehicles
----------------------------------------------------------------------

-- Car recipe (~20 parts): chunky chassis, cabin set back toward the rear,
-- glass-blue windows, oversized wheels with white hubcaps, neon lights.
local function buildCarBody(model: Model, color: Color3)
	block(model, "Chassis", Vector3.new(6, 2.2, 11), Vector3.new(0, 1.9, 0), color, nil, true)
	block(model, "Cabin", Vector3.new(5.2, 2.4, 6), Vector3.new(0, 4.2, 0.5), VehicleRig.cabinColor(color))
	block(model, "Windshield", Vector3.new(4.6, 1.7, 0.2), Vector3.new(0, 4.3, -2.55), GLASS)
	block(model, "RearWindow", Vector3.new(4.6, 1.5, 0.2), Vector3.new(0, 4.35, 3.55), GLASS)
	for _, side in { -1, 1 } do
		block(model, "SideWindow", Vector3.new(0.2, 1.5, 4.8), Vector3.new(side * 2.65, 4.35, 0.5), GLASS)
	end
	wheels(model, 3.0, 1.3, { -3.6, 3.6 })
	lights(model, 2.0, 2.3, -5.6, 5.6, Vector3.new(1, 0.7, 0.3))
	bumpers(model, 6.2, 1.1, 5.7)
end

local function buildTaxi(model: Model, color: Color3)
	buildCarBody(model, color)
	local sign = block(model, "TaxiSign", Vector3.new(2.4, 0.9, 1.1), Vector3.new(0, 5.85, 0.5), Color3.fromRGB(255, 250, 230))
	surfaceText(sign, Enum.NormalId.Front, "TAXI", Color3.fromRGB(30, 30, 40), Enum.Font.LuckiestGuy, 50)
	surfaceText(sign, Enum.NormalId.Back, "TAXI", Color3.fromRGB(30, 30, 40), Enum.Font.LuckiestGuy, 50)
	for _, side in { -1, 1 } do
		block(model, "CheckerStripe", Vector3.new(0.1, 0.45, 9.6), Vector3.new(side * 3.02, 2.55, 0), Color3.fromRGB(30, 30, 36))
	end
end

-- Bus (~26 parts): 7 x 6.2 x 22 orange body, white window band with blue
-- window strips, door on the right (curb) side, destination sign, 6 wheels.
local function buildBus(model: Model, color: Color3)
	block(model, "BusBody", Vector3.new(7, 6.2, 22), Vector3.new(0, 4.1, 0), color, nil, true)
	block(model, "WindowBand", Vector3.new(7.1, 2.2, 22.1), Vector3.new(0, 5.4, 0), WHITE)
	for _, side in { -1, 1 } do
		block(model, "BusWindows", Vector3.new(0.15, 1.6, 17.2), Vector3.new(side * 3.58, 5.4, 1.9), GLASS)
	end
	block(model, "BusDoor", Vector3.new(0.15, 4.6, 2.4), Vector3.new(3.58, 3.6, -8.4), Color3.fromRGB(60, 64, 96))
	block(model, "Windshield", Vector3.new(6.2, 2.6, 0.15), Vector3.new(0, 5.1, -11.05), GLASS)
	block(model, "RearWindow", Vector3.new(5.6, 1.6, 0.15), Vector3.new(0, 5.5, 11.05), GLASS)
	block(model, "BusRoof", Vector3.new(6.4, 0.5, 20), Vector3.new(0, 7.45, 0), color:Lerp(WHITE, 0.35))
	local sign = block(model, "BusSign", Vector3.new(4.6, 0.9, 0.2), Vector3.new(0, 6.95, -11.12), NAVY)
	surfaceText(sign, Enum.NormalId.Front, "CITY BUS", BUS_ORANGE, Enum.Font.LuckiestGuy, 40)
	wheels(model, 3.4, 1.3, { -7.4, 5.0, 7.9 })
	lights(model, 2.5, 2.4, -11.1, 11.1, Vector3.new(1.2, 0.8, 0.3))
	bumpers(model, 7.2, 1.2, 11.25)
end

-- Ice-cream van (~26 parts): short cab + tall box with a serving window and
-- a giant cone (cylinder + ball scoop + cherry) on the roof.
local function buildIceCreamVan(model: Model, color: Color3)
	block(model, "Chassis", Vector3.new(6, 2.2, 11), Vector3.new(0, 1.9, 0), color, nil, true)
	block(model, "VanBox", Vector3.new(5.8, 4.2, 7), Vector3.new(0, 5.1, 1.7), color:Lerp(WHITE, 0.3))
	block(model, "VanStripe", Vector3.new(5.9, 0.6, 7.1), Vector3.new(0, 6.6, 1.7), Color3.fromRGB(255, 110, 180))
	block(model, "Cab", Vector3.new(5.4, 2.4, 3.6), Vector3.new(0, 4.2, -3.4), color)
	block(model, "Windshield", Vector3.new(4.8, 1.7, 0.2), Vector3.new(0, 4.3, -5.25), GLASS)
	for _, side in { -1, 1 } do
		block(model, "SideWindow", Vector3.new(0.2, 1.4, 2.4), Vector3.new(side * 2.75, 4.35, -3.4), GLASS)
		block(model, "ServingWindow", Vector3.new(0.15, 1.8, 3.8), Vector3.new(side * 2.95, 5.2, 1.7), GLASS)
	end
	cylinderY(model, "Cone", 3, 1.6, Vector3.new(0, 8.7, 1.7), Color3.fromRGB(230, 180, 110))
	ball(model, "Scoop", 3, Vector3.new(0, 10.9, 1.7), Color3.fromRGB(255, 240, 200))
	ball(model, "Cherry", 0.9, Vector3.new(0, 12.6, 1.7), Color3.fromRGB(235, 40, 60))
	wheels(model, 3.0, 1.3, { -3.6, 3.6 })
	lights(model, 2.0, 2.3, -5.6, 5.6, Vector3.new(1, 0.7, 0.3))
	bumpers(model, 6.2, 1.1, 5.7)
end

-- Delivery box truck (~28 parts): orange 7 x 5 x 5 cab up front, a WHITE
-- 7 x 7.5 x 13 cargo box with an orange side stripe (and a "SPEEDY
-- DELIVERY" label on both flanks), 6 wheels. The box sits low (bottom 1.5,
-- top 9.0) so the roof clears the ring-road signal heads with margin.
local function buildTruck(model: Model, color: Color3)
	local boxWhite = Color3.fromRGB(248, 248, 244)
	block(model, "TruckFrame", Vector3.new(5.6, 1.0, 18.6), Vector3.new(0, 1.6, 0), Color3.fromRGB(70, 74, 96))
	-- cab (front, -Z): z -9.25..-4.25
	block(model, "Cab", Vector3.new(7, 5, 5), Vector3.new(0, 4.1, -6.75), color, nil, true)
	block(model, "CabRoof", Vector3.new(6.4, 0.4, 4.4), Vector3.new(0, 6.8, -6.75), color:Lerp(boxWhite, 0.35))
	block(model, "Windshield", Vector3.new(6, 2, 0.15), Vector3.new(0, 4.9, -9.3), GLASS)
	for _, side in { -1, 1 } do
		block(model, "SideWindow", Vector3.new(0.15, 1.8, 2.6), Vector3.new(side * 3.53, 4.9, -7.1), GLASS)
	end
	-- cargo box (rear): z -4.0..9.0
	block(model, "CargoBox", Vector3.new(7, 7.5, 13), Vector3.new(0, 5.25, 2.5), boxWhite, nil, true)
	for _, side in { -1, 1 } do
		local stripe = block(model, "CargoStripe", Vector3.new(0.12, 1.6, 13.05), Vector3.new(side * 3.55, 4.3, 2.5), color)
		surfaceText(stripe, if side > 0 then Enum.NormalId.Right else Enum.NormalId.Left, "SPEEDY DELIVERY", Color3.fromRGB(255, 255, 255), Enum.Font.LuckiestGuy, 30)
	end
	block(model, "CargoDoor", Vector3.new(6.2, 6.6, 0.12), Vector3.new(0, 5.25, 9.05), boxWhite:Lerp(color, 0.15))
	wheels(model, 3.4, 1.3, { -6.6, 4.6, 7.4 })
	lights(model, 2.6, 2.4, -9.35, 9.15, Vector3.new(1.1, 0.8, 0.3))
	bumpers(model, 7.2, 1.2, 9.5)
end

-- Police car (~24 parts): the Car recipe in WHITE with a blue hood, blue
-- doors painted on the chassis flanks with "POLICE" in white (SurfaceGui
-- frames: 0 parts) and a roof lightbar (dark base + red / blue Neon halves,
-- flashed by CityLifeSim through Transparency).
local POLICE_NAVY = Color3.fromRGB(40, 70, 170)
local function paintDoor(part: BasePart, face: Enum.NormalId, x0: number, x1: number)
	-- x0..x1: the door's span as a fraction of the face width, left to right
	-- as seen from outside (Right face: +Z -> -Z; Left face: -Z -> +Z)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Door" .. face.Name
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 30
	gui.LightInfluence = 0.6
	gui.Parent = part
	local door = Instance.new("Frame")
	door.Name = "Door"
	door.BorderSizePixel = 0
	door.BackgroundColor3 = POLICE_NAVY
	door.Position = UDim2.fromScale(x0, 0.08)
	door.Size = UDim2.fromScale(x1 - x0, 0.84)
	door.Parent = gui
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Position = UDim2.fromScale(0.06, 0.12)
	label.Size = UDim2.fromScale(0.88, 0.76)
	label.Font = Enum.Font.LuckiestGuy
	label.Text = "POLICE"
	label.TextColor3 = WHITE
	label.TextScaled = true
	label.TextStrokeColor3 = NAVY
	label.TextStrokeTransparency = 0
	label.Parent = door
end

local function buildPolice(model: Model, color: Color3)
	buildCarBody(model, color)
	block(model, "Hood", Vector3.new(5.8, 0.12, 2.9), Vector3.new(0, 3.06, -4.0), POLICE_NAVY)
	local chassis = model:FindFirstChild("Chassis") :: BasePart
	-- the cabin spans z -2.5..3.5 over the 11-long chassis (z -5.5..5.5)
	paintDoor(chassis, Enum.NormalId.Right, (5.5 - 3.5) / 11, (5.5 + 2.5) / 11)
	paintDoor(chassis, Enum.NormalId.Left, (-2.5 + 5.5) / 11, (3.5 + 5.5) / 11)
	block(model, "LightbarBase", Vector3.new(4.4, 0.6, 1.2), Vector3.new(0, 5.7, 0.5), Color3.fromRGB(60, 60, 80))
	block(model, "LightbarRed", Vector3.new(2.0, 0.45, 1.0), Vector3.new(-1.1, 6.225, 0.5), VehicleRig.POLICE_RED, Enum.Material.Neon)
	block(model, "LightbarBlue", Vector3.new(2.0, 0.45, 1.0), Vector3.new(1.1, 6.225, 0.5), VehicleRig.POLICE_BLUE, Enum.Material.Neon)
end

local BUILDERS = {
	Car = buildCarBody,
	Taxi = buildTaxi,
	Bus = buildBus,
	IceCreamVan = buildIceCreamVan,
	Truck = buildTruck,
	Police = buildPolice,
}

local DEFAULT_COLORS = {
	Car = Color3.fromRGB(255, 90, 90),
	Taxi = TAXI_YELLOW,
	Bus = BUS_ORANGE,
	IceCreamVan = VAN_PINK,
	Truck = BUS_ORANGE,
	Police = WHITE,
}

function VehicleRig.build(kind: string, color: Color3?): Model
	local builder = BUILDERS[kind] or buildCarBody
	local model = Instance.new("Model")
	model.Name = kind
	builder(model, color or DEFAULT_COLORS[kind] or DEFAULT_COLORS.Car)
	return model
end

function VehicleRig.isWheel(part: BasePart): boolean
	return part.Name == "Wheel" or part.Name == "Hubcap"
end

-- Cabin color of a body color (the Car recipe: 15% toward white), so a sim
-- can repaint a car (car-wash passes) without rebuilding it.
function VehicleRig.cabinColor(color: Color3): Color3
	return color:Lerp(WHITE, 0.15)
end

----------------------------------------------------------------------
-- Blimp
----------------------------------------------------------------------

function VehicleRig.buildBlimp(): Model
	local model = Instance.new("Model")
	model.Name = "Blimp"
	local body = WHITE
	local red = Color3.fromRGB(255, 90, 90)
	-- 40-long envelope along Z (native cylinder axis X yawed 90 degrees) + round caps
	addPart(model, "Envelope", Enum.PartType.Cylinder, Vector3.new(40, 14, 14), CFrame.Angles(0, RAD_90, 0), body)
	ball(model, "EnvelopeCap", 14, Vector3.new(0, 0, -20), body)
	ball(model, "EnvelopeCap", 14, Vector3.new(0, 0, 20), body)
	-- Four tail fins: wedges are tall at +Z (the tail) and slope toward the nose
	local fin = Vector3.new(0.8, 6, 9)
	wedge(model, "Fin", fin, CFrame.new(0, 9, 22), red)
	wedge(model, "Fin", fin, CFrame.new(0, -9, 22) * CFrame.Angles(0, 0, math.pi), red)
	wedge(model, "Fin", fin, CFrame.new(9, 0, 22) * CFrame.Angles(0, 0, -RAD_90), red)
	wedge(model, "Fin", fin, CFrame.new(-9, 0, 22) * CFrame.Angles(0, 0, RAD_90), red)
	-- Gondola with a window band
	block(model, "Gondola", Vector3.new(5, 2.6, 9), Vector3.new(0, -8.1, -2), Color3.fromRGB(64, 70, 120))
	block(model, "GondolaWindows", Vector3.new(5.1, 0.9, 7), Vector3.new(0, -7.9, -2), GLASS)
	-- Banner boards on both flanks + neon trims
	local yellow = Color3.fromRGB(255, 212, 31)
	local pink = Color3.fromRGB(255, 110, 190)
	for _, side in { -1, 1 } do
		local board = block(model, "Banner", Vector3.new(0.4, 4.6, 24), Vector3.new(side * 7.05, 0.4, -1), NAVY)
		surfaceText(board, if side > 0 then Enum.NormalId.Right else Enum.NormalId.Left, "SIDE HUSTLE CITY", yellow, Enum.Font.FredokaOne, 12)
		for _, dy in { -2.55, 2.55 } do
			block(model, "BannerTrim", Vector3.new(0.5, 0.45, 24.6), Vector3.new(side * 7.1, 0.4 + dy, -1), pink, Enum.Material.Neon)
		end
	end
	return model
end

----------------------------------------------------------------------
-- Hot-air balloon
----------------------------------------------------------------------

local BALLOON_WOOD = Color3.fromRGB(133, 94, 62)
VehicleRig.BALLOON_BASKET_GAP = 5 -- studs between the envelope bottom and the basket top
VehicleRig.BALLOON_DROP = 7 + 5 + 2.4 -- envelope center to basket bottom

-- 5 parts: a 14-dia envelope ball in `color`, a WHITE equator band (vertical-
-- axis cylinder 14.4 dia x 1.4), a 3 x 2.4 x 3 wooden basket hanging 5 studs
-- below the envelope bottom, and 2 thin ropes from opposite basket corners up
-- to the envelope. Centered on the envelope center (basket at -Z / +Z free).
function VehicleRig.buildBalloon(color: Color3): Model
	local model = Instance.new("Model")
	model.Name = "HotAirBalloon"
	ball(model, "BalloonEnvelope", 14, Vector3.new(0, 0, 0), color)
	cylinderY(model, "BalloonBand", 1.4, 14.4, Vector3.new(0, 0, 0), WHITE)
	local basketTop = -VehicleRig.BALLOON_BASKET_GAP - 7
	block(model, "BalloonBasket", Vector3.new(3, 2.4, 3), Vector3.new(0, basketTop - 1.2, 0), BALLOON_WOOD)
	for _, side in { -1, 1 } do
		-- from the basket's top corner up to the envelope surface (~5.6 long)
		local from = Vector3.new(side * 1.35, basketTop, side * 1.35)
		local to = Vector3.new(side * 2, -math.sqrt(49 - 8), side * 2)
		local length = (to - from).Magnitude
		local mid = (from + to) / 2
		local up = (to - from).Unit
		local right = up:Cross(Vector3.new(side, 0, -side)).Unit
		local back = right:Cross(up)
		addPart(
			model,
			"BalloonRope",
			Enum.PartType.Block,
			Vector3.new(0.15, length, 0.15),
			CFrame.fromMatrix(mid, right, up, back),
			Color3.fromRGB(110, 84, 60)
		)
	end
	return model
end

return VehicleRig
