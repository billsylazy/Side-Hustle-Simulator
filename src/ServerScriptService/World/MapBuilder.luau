--!nonstrict
-- MapBuilder (v3 "downtown"): constructs the entire Side Hustle Simulator world
-- from primitives (Blocks / Balls / Cylinders / Wedges only — no meshes, no
-- Toolbox, no asset ids) plus Terrain, Lighting, PointLights and ParticleEmitters.
--
-- Contract (ARCHITECTURE.md "Map contract" + "Graphics"):
--   Workspace.SideHustleMap (Folder)
--     Ground (Model: terrain-backed island; road-side signposts)
--     Plaza (Model with SpawnLocation on a gold medallion + a painted START mat
--       (SpawnWelcomeMat deck), ground/street discs incl. the Back Avenue, coin fountain
--       with the spinning "SpinCoin" model (CitySpin), cobalt lamps with pennant bunting)
--     Zones (Folder) > <ZoneId> (Model, attribute ZoneId)
--       HustleStation (Model)
--         PromptPart (Part) > ProximityPrompt "HustlePrompt"
--           (ActionText zone.HustleVerb.."!", ObjectText zone.Name,
--            HoldDuration = zone.HoldDuration, MaxActivationDistance 12, no LoS)
--         FeedbackPart (Part, invisible, ~6 studs above the counter; client billboard)
--         AutoAnchor (Part, invisible, beside the counter, facing it; client rig)
--       MechanicProp (Model) — static dressing that tells the mechanic from afar
--       Dressing (Model) — themed clutter on the pad (World/ZoneDressing)
--       EntranceLamp (Model) x2 — lamp posts at zone-local (+-16, -35) in the zone's colors
--       Gate (Model, only UnlockLevel > 1) > GateWall / GatePost / SignPart (BillboardGui)
--     City (Model) — the downtown (World/CityBuilder, laid out by Shared/CityLayout):
--       Street (painted lane dashes on MarkingDeck decks, curbs, crosswalks, yellow-head
--       traffic lights on cobalt masts), Skyline (48 buildings incl. 6
--       landmark hero towers + 24 rowhouses), Shops (16 storefronts), Anchors (a landmark
--       behind every zone, spinning rooftop icon), Furniture, GapBlocks (cafés on checkered
--       terrace rugs, street trees), Parks, BackPockets (trees + lamps), PlazaBuzz
--   Every zone is placed with Mechanics.zoneGroundCFrame(zone.Order) so the
--   client's nearest-zone lookup matches the world exactly. No UnlockPrompt.
--
-- Graphics: Lighting (Technology = Future is set by the Rojo project) with
-- Atmosphere, SunRays, Bloom, ColorCorrection and the built-in Sky; a Terrain
-- island (warm cream Pavement city ground, a thin Grass belt at the rim, Sand
-- beach, a shallow Water ring over a sand seabed; terrain material colors are
-- set here); per-zone materials; ParticleEmitters that keep the default sparkle
-- texture; warm PointLights in lamps and behind neon signs. Bright and cartoony.
--
-- Heights: the terrain top is world Y = 0. The ground is stacked discs
-- (Shared/CityLayout.Street): Back Avenue edges 0.08 / asphalt 0.12 / edge 0.16,
-- city-block ground 0.2, white trim 0.3, outer sidewalk top ROAD_TOP (0.5),
-- asphalt 0.6, inner sidewalk 0.75, plaza rim 1.3, plaza floor and every zone
-- pad PAD_TOP.
--
-- MapBuilder.build() is idempotent: it returns early if the map already exists
-- and every Lighting child is found by name/class before one is created.
-- Terrain runs once per server start (inside build) and is a handful of big
-- fills (well under 1s). Part count is ~4,340 incl. invisible markers
-- (round-5 envelope: <= 4,400 map parts; <= 7,000 with the client-life
-- preview). Far faces carry painted SurfaceGui windows (MapKit.paintBands)
-- instead of part bands, and every lane dash is painted (MapKit.makeGroundDeck).

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local Mechanics = require(ReplicatedStorage.Shared.Mechanics)
local CityLayout = require(ReplicatedStorage.Shared.CityLayout)
local MapKit = require(script.Parent.MapKit)
local CityBuilder = require(script.Parent.CityBuilder)
local ZoneDressing = require(script.Parent.ZoneDressing)

local makeBlock = MapKit.makeBlock
local makeBall = MapKit.makeBall
local makeCylinder = MapKit.makeCylinder
local makeWedge = MapKit.makeWedge
local makeModel = MapKit.makeModel
local makeMarker = MapKit.makeMarker
local makeTextLabel = MapKit.makeTextLabel
local addSurfaceText = MapKit.addSurfaceText
local addPointLight = MapKit.addPointLight
local ringPos = MapKit.ringPos

local MapBuilder = {}

----------------------------------------------------------------------
-- Layout constants (terrain top / ground is world Y = 0)
----------------------------------------------------------------------

local STREET = CityLayout.Street
local PAD_SIZE = 64
local PAD_TOP = 1.5 -- top of plaza disc and of every zone pad
local ROAD_TOP = STREET.OuterSidewalkTop -- 0.5: outer sidewalk (entrance lamps, signposts)
-- Outer sidewalk disc: reaches 2 studs under the front edge of every pad
-- (pad front = ZoneRadius - PAD_SIZE / 2 = 118 with the default config).
local ROAD_RADIUS = STREET.OuterSidewalkRadius
local PLAZA_RADIUS = STREET.PlazaRadius
local LAMP_RADIUS = 44 -- plaza lamp ring (string lights run between them)

-- Island rings (laid out for the default ZoneRadius 150: pads cover radius
-- 118 .. 185 around each zone axis, the skyline reaches r 307).
local CITY_GROUND_RADIUS = 314 -- Pavement city ground (terrain top Y = 0)
local ISLAND_RADIUS = 330 -- thin Grass belt between the city and the beach
local BEACH_RADIUS = 360 -- sand rim (terrain top Y = 0)
local WATER_HALF = 700 -- half-size of the water square
local WATER_TOP = -2 -- water surface sits a little below the beach
local SEABED_TOP = -10 -- sand floor under the water

local RAD_90 = MapKit.RAD_90

-- Shared palette
local NAVY = MapKit.NAVY -- text outlines, tires, the gate lock panel and darkened tints only
local WHITE = MapKit.WHITE
local NEON_WHITE = MapKit.NEON_WHITE
local zoneSignFace = MapKit.zoneSignFace
local CREAM = MapKit.CREAM
local WOOD = MapKit.WOOD
local DARK_WOOD = MapKit.DARK_WOOD
local PAVEMENT_CREAM = Color3.fromRGB(226, 216, 200)
local SIDEWALK = Color3.fromRGB(236, 226, 208)
local CURB_WHITE = Color3.fromRGB(250, 248, 240)
local STONE = Color3.fromRGB(225, 214, 188)
local STONE_LIGHT = Color3.fromRGB(242, 236, 222)
local METAL_DARK = MapKit.METAL_DARK
local WHEEL_DARK = MapKit.WHEEL_DARK
local LEAF_GREEN = MapKit.LEAF_GREEN

local FLOWER_COLORS = MapKit.FLOWER_COLORS
-- Stock Desk "screen" / body color (a local override of its near-black
-- AccentColor; ZoneDressing's ticker pillars use MapKit.STOCK_DEEP_GREEN too)
local STOCK_DEEP_GREEN = MapKit.STOCK_DEEP_GREEN

----------------------------------------------------------------------
-- Primitive helpers
----------------------------------------------------------------------

-- Invisible anchored part that carries a ProximityPrompt (keeps CanQuery so
-- the prompt behaves like any other prompt part).
local function makePromptPart(parent: Instance, cf: CFrame): Part
	local part = Instance.new("Part")
	part.Name = "PromptPart"
	part.Size = Vector3.new(2, 2, 2)
	part.CFrame = cf
	part.Transparency = 1
	part.CanCollide = false
	part.CanTouch = false
	part.CastShadow = false
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

type ParticleProps = {
	color: ColorSequence,
	size: NumberSequence,
	transparency: NumberSequence?,
	rate: number,
	lifetime: NumberRange,
	speed: NumberRange,
	spread: Vector2?,
	acceleration: Vector3?,
	lightEmission: number?,
	drag: number?,
	rotSpeed: NumberRange?,
}

-- The face of a part that currently points closest to world up. Cylinders
-- built upright are rotated 90 degrees about Z, so their "Top" points along
-- world X; emitters use this so smoke / sparkle always rises.
local FACE_NORMALS: { { face: Enum.NormalId, normal: Vector3 } } = {
	{ face = Enum.NormalId.Top, normal = Vector3.new(0, 1, 0) },
	{ face = Enum.NormalId.Bottom, normal = Vector3.new(0, -1, 0) },
	{ face = Enum.NormalId.Right, normal = Vector3.new(1, 0, 0) },
	{ face = Enum.NormalId.Left, normal = Vector3.new(-1, 0, 0) },
	{ face = Enum.NormalId.Back, normal = Vector3.new(0, 0, 1) },
	{ face = Enum.NormalId.Front, normal = Vector3.new(0, 0, -1) },
}

local function upwardFace(part: BasePart): Enum.NormalId
	local best = Enum.NormalId.Top
	local bestY = -math.huge
	for _, entry in FACE_NORMALS do
		local worldY = part.CFrame:VectorToWorldSpace(entry.normal).Y
		if worldY > bestY then
			best = entry.face
			bestY = worldY
		end
	end
	return best
end

-- ParticleEmitter that keeps the engine default (sparkle) texture.
local function addParticles(parent: BasePart, name: string, props: ParticleProps): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = name
	emitter.Color = props.color
	emitter.Size = props.size
	emitter.Transparency = props.transparency or NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(0.7, 0.4),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Rate = props.rate
	emitter.Lifetime = props.lifetime
	emitter.Speed = props.speed
	emitter.SpreadAngle = props.spread or Vector2.new(25, 25)
	emitter.Acceleration = props.acceleration or Vector3.new(0, 1.5, 0)
	emitter.LightEmission = if props.lightEmission ~= nil then props.lightEmission else 0.8
	emitter.LightInfluence = 0.2
	emitter.Drag = props.drag or 0.5
	emitter.RotSpeed = props.rotSpeed or NumberRange.new(-40, 40)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.EmissionDirection = upwardFace(parent)
	emitter.Parent = parent
	return emitter
end

-- Gentle two-color sparkle preset (motes drifting up).
local function addSparkle(parent: BasePart, name: string, colorA: Color3, colorB: Color3, rate: number, sizeMin: number, sizeMax: number)
	addParticles(parent, name, {
		color = ColorSequence.new(colorA, colorB),
		size = NumberSequence.new(sizeMin, sizeMax),
		rate = rate,
		lifetime = NumberRange.new(1.2, 2.0),
		speed = NumberRange.new(0.6, 1.6),
		lightEmission = 1,
	})
end

-- Chunky sign board with SurfaceGui text (navy-outlined, see MapKit), a neon
-- underline (`glowColor`, default white) and a glow light in the board color.
-- Zone name boards: signature-colored face (MapKit.zoneSignFace) + WHITE text.
local function addSignBoard(
	parent: Instance,
	cf: CFrame,
	width: number,
	height: number,
	text: string,
	boardColor: Color3,
	textColor: Color3,
	glowColor: Color3?
): Part
	local board = makeBlock({
		name = "NameBoard",
		parent = parent,
		size = Vector3.new(width, height, 0.5),
		cframe = cf,
		color = boardColor,
	})
	addSurfaceText(board, text, Enum.Font.FredokaOne, textColor, Enum.NormalId.Front, nil, boardColor)
	makeBlock({
		name = "NameBoardGlow", parent = parent, size = Vector3.new(width + 0.4, 0.3, 0.6),
		cframe = cf * CFrame.new(0, -height / 2 - 0.15, 0), color = glowColor or NEON_WHITE,
		material = Enum.Material.Neon, canCollide = false,
	})
	addPointLight(board, boardColor, 12, 0.6)
	return board
end

----------------------------------------------------------------------
-- Lighting: bright cheerful day, soft blue haze, gentle bloom for the neon
----------------------------------------------------------------------

-- Returns the Lighting child with this name (and class), else any existing
-- instance of that class (so a place that already has e.g. a Bloom never ends
-- up with two stacked), else a new one. Properties are (re)applied by the
-- caller so repeat runs converge.
local function ensureLightingChild(className: string, name: string): Instance
	local existing = Lighting:FindFirstChild(name)
	if existing and existing.ClassName == className then
		return existing
	end
	local byClass = Lighting:FindFirstChildOfClass(className)
	if byClass then
		return byClass
	end
	local child = Instance.new(className)
	child.Name = name
	child.Parent = Lighting
	return child
end

local function setupLighting()
	-- Technology = Future comes from default.project.json (not scriptable).
	Lighting.ClockTime = 13
	Lighting.Brightness = 2.6
	Lighting.GlobalShadows = true
	Lighting.ShadowSoftness = 0.6
	Lighting.EnvironmentDiffuseScale = 0.85
	Lighting.EnvironmentSpecularScale = 0.6
	-- Warm, bright fill so shaded facades stay sunny pastel instead of going
	-- khaki / maroon (the sun is nearly overhead at ClockTime 13).
	Lighting.Ambient = Color3.fromRGB(162, 154, 146)
	Lighting.OutdoorAmbient = Color3.fromRGB(206, 198, 188)
	Lighting.ExposureCompensation = 0.15

	local atmosphere = ensureLightingChild("Atmosphere", "SideHustleAtmosphere") :: Atmosphere
	-- Light, crisp air: the far half of the downtown ring keeps its candy
	-- colors against a blue sky instead of bleaching into haze.
	atmosphere.Density = 0.2
	atmosphere.Offset = 0.2
	atmosphere.Color = Color3.fromRGB(199, 222, 255)
	atmosphere.Decay = Color3.fromRGB(255, 214, 170)
	atmosphere.Glare = 0.15
	atmosphere.Haze = 0.2

	local sunRays = ensureLightingChild("SunRaysEffect", "SideHustleSunRays") :: SunRaysEffect
	sunRays.Intensity = 0.08
	sunRays.Spread = 0.6

	-- Subtle: only the neon accents bloom, not the sunlit plastic.
	local bloom = ensureLightingChild("BloomEffect", "SideHustleBloom") :: BloomEffect
	bloom.Intensity = 0.35
	bloom.Size = 24
	bloom.Threshold = 1.5

	local colorCorrection = ensureLightingChild("ColorCorrectionEffect", "SideHustleColorCorrection") :: ColorCorrectionEffect
	colorCorrection.Saturation = 0.3
	colorCorrection.Contrast = 0.08
	colorCorrection.Brightness = 0.02
	colorCorrection.TintColor = Color3.fromRGB(255, 255, 255)

	local sky = ensureLightingChild("Sky", "SideHustleSky") :: Sky
	sky.SkyboxBk = "rbxasset://textures/sky/sky512_bk.tex"
	sky.SkyboxDn = "rbxasset://textures/sky/sky512_dn.tex"
	sky.SkyboxFt = "rbxasset://textures/sky/sky512_ft.tex"
	sky.SkyboxLf = "rbxasset://textures/sky/sky512_lf.tex"
	sky.SkyboxRt = "rbxasset://textures/sky/sky512_rt.tex"
	sky.SkyboxUp = "rbxasset://textures/sky/sky512_up.tex"
	sky.SunAngularSize = 18
	sky.MoonAngularSize = 8
	sky.StarCount = 0
	sky.CelestialBodiesShown = true
end

----------------------------------------------------------------------
-- Terrain: Pavement city island, thin grass belt, sand rim, water beyond
----------------------------------------------------------------------

local ISLAND_BOTTOM = -12

local function buildTerrain()
	local terrain = Workspace.Terrain
	terrain:Clear()

	local waterSize = WATER_HALF * 2
	-- Sand seabed, then shallow water above it (surface at WATER_TOP).
	terrain:FillBlock(
		CFrame.new(0, SEABED_TOP - 2, 0),
		Vector3.new(waterSize, 4, waterSize),
		Enum.Material.Sand
	)
	terrain:FillBlock(
		CFrame.new(0, (SEABED_TOP + WATER_TOP) / 2, 0),
		Vector3.new(waterSize, WATER_TOP - SEABED_TOP, waterSize),
		Enum.Material.Water
	)

	-- The island: Sand beach disc, a Grass belt, then the Pavement city
	-- ground on top. All span ISLAND_BOTTOM .. 0 so the terrain top is exactly
	-- world Y = 0. Pavement has no animated blades, so nothing can poke up
	-- through the street discs, pads or buildings.
	-- FillCylinder(cframe, height, radius, material); axis = cframe Y.
	local islandHeight = -ISLAND_BOTTOM
	local islandCF = CFrame.new(0, ISLAND_BOTTOM / 2, 0)
	terrain:FillCylinder(islandCF, islandHeight, BEACH_RADIUS, Enum.Material.Sand)
	terrain:FillCylinder(islandCF, islandHeight, ISLAND_RADIUS, Enum.Material.Grass)
	terrain:FillCylinder(islandCF, islandHeight, CITY_GROUND_RADIUS, Enum.Material.Pavement)
end

-- Terrain styling: warm cream pavement tiles, golden sand, bright grass and a
-- cartoon lagoon (bright turquoise, clear, small lazy waves). Kept out of
-- buildTerrain so a styling error can never trigger the ground fallback.
-- (Animated grass, Terrain.Decoration, is not scriptable: the Rojo project
-- sets it on the place.)
local function styleTerrain()
	local terrain = Workspace.Terrain
	terrain:SetMaterialColor(Enum.Material.Pavement, PAVEMENT_CREAM)
	terrain:SetMaterialColor(Enum.Material.Sand, Color3.fromRGB(250, 224, 156))
	terrain:SetMaterialColor(Enum.Material.Grass, Color3.fromRGB(108, 200, 76))
	terrain.WaterColor = Color3.fromRGB(52, 182, 230)
	terrain.WaterTransparency = 0.55
	terrain.WaterWaveSize = 0.18
	terrain.WaterWaveSpeed = 14
	terrain.WaterReflectance = 0.35
end

----------------------------------------------------------------------
-- Ground: the terrain island is the visible ground; this model holds the
-- beach / road-side decor (and a flat slab only if terrain generation failed)
----------------------------------------------------------------------

local function buildGround(map: Folder, terrainOk: boolean): Model
	local ground = makeModel("Ground", map)
	if not terrainOk then
		-- Fallback only: a flat pavement slab (top at Y = 0) so players never
		-- fall into the void if the terrain fills errored.
		makeCylinder({
			name = "FallbackGround", parent = ground, diameter = ISLAND_RADIUS * 2, height = 2,
			cframe = CFrame.new(0, -1, 0), color = PAVEMENT_CREAM,
		})
	end
	return ground
end

----------------------------------------------------------------------
-- Plaza pieces: lamp posts, benches, coin fountain, billboard, string lights
----------------------------------------------------------------------

local buildLampPost = MapKit.buildLampPost

local function buildBench(parent: Instance, cf: CFrame)
	makeBlock({
		name = "BenchSeat", parent = parent, size = Vector3.new(5.5, 0.55, 1.8),
		cframe = cf * CFrame.new(0, 1.35, 0), color = WOOD, material = Enum.Material.WoodPlanks,
	})
	for _, xOff in { -2.2, 2.2 } do
		makeBlock({
			name = "BenchLeg", parent = parent, size = Vector3.new(0.5, 1.1, 1.6),
			cframe = cf * CFrame.new(xOff, 0.55, 0), color = DARK_WOOD, material = Enum.Material.Wood,
		})
	end
	makeBlock({
		name = "BenchBack", parent = parent, size = Vector3.new(5.5, 1.6, 0.45),
		cframe = cf * CFrame.new(0, 2.3, 0.8) * CFrame.Angles(math.rad(-8), 0, 0), color = WOOD,
		material = Enum.Material.WoodPlanks,
	})
end

-- Giant spinning gold coin on a banded white column rising out of a marble
-- fountain (plaza centerpiece, coin center 21.5 studs up).
local function buildCoinFountain(parent: Instance)
	local gold = Color3.fromRGB(235, 184, 52)
	local brightGold = Color3.fromRGB(255, 215, 95)
	local bronze = Color3.fromRGB(110, 78, 28)
	local marble = Color3.fromRGB(226, 220, 206)
	local waterColor = Color3.fromRGB(110, 205, 235)

	-- Basin floor + translucent water disc
	makeCylinder({
		name = "FountainFloor", parent = parent, diameter = 22, height = 0.6,
		cframe = CFrame.new(0, PAD_TOP + 0.3, 0), color = marble, material = Enum.Material.Marble,
	})
	makeCylinder({
		name = "FountainWater", parent = parent, diameter = 20.4, height = 0.8,
		cframe = CFrame.new(0, PAD_TOP + 1.0, 0), color = waterColor,
		material = Enum.Material.Glass, transparency = 0.35, reflectance = 0.2, canCollide = false,
	})
	-- Rim: 12 chunky marble blocks in a ring (local X radial, Z tangential)
	for i = 0, 11 do
		local angle = math.rad(i * 30)
		local pos = Vector3.new(math.cos(angle) * 10.6, PAD_TOP + 0.75, math.sin(angle) * 10.6)
		makeBlock({
			name = "FountainRim", parent = parent, size = Vector3.new(1.3, 1.5, 5.8),
			cframe = CFrame.new(pos) * CFrame.Angles(0, -angle, 0), color = marble,
			material = Enum.Material.Marble,
		})
	end
	-- Four water jets (rising spray that falls back into the basin)
	for i = 0, 3 do
		local angle = math.rad(45 + i * 90)
		local jet = makeMarker(
			parent, "FountainJet",
			CFrame.new(math.cos(angle) * 6.8, PAD_TOP + 1.4, math.sin(angle) * 6.8),
			Vector3.new(0.6, 0.4, 0.6)
		)
		addParticles(jet, "Spray", {
			color = ColorSequence.new(Color3.fromRGB(190, 235, 255), Color3.fromRGB(255, 255, 255)),
			size = NumberSequence.new(0.5, 0.9),
			transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.25),
				NumberSequenceKeypoint.new(0.8, 0.5),
				NumberSequenceKeypoint.new(1, 1),
			}),
			rate = 7,
			lifetime = NumberRange.new(1.1, 1.4),
			speed = NumberRange.new(12, 15),
			spread = Vector2.new(6, 6),
			acceleration = Vector3.new(0, -22, 0),
			lightEmission = 0.4,
			drag = 0,
		})
	end

	-- Pedestal rising out of the water
	makeCylinder({
		name = "StatuePedestal", parent = parent, diameter = 10, height = 2,
		cframe = CFrame.new(0, PAD_TOP + 1, 0), color = Color3.fromRGB(205, 198, 182),
		material = Enum.Material.Marble,
	})
	makeCylinder({
		name = "StatuePedestalTop", parent = parent, diameter = 7.5, height = 1.5,
		cframe = CFrame.new(0, PAD_TOP + 2.75, 0), color = Color3.fromRGB(190, 182, 165),
		material = Enum.Material.Marble,
	})
	-- White column with gold bands lifting the coin 12 studs higher, so the
	-- hub's landmark reads over the traffic from every zone gate.
	local columnBottom, columnHeight = PAD_TOP + 2.75, 12
	makeCylinder({
		name = "StatueColumn", parent = parent, diameter = 4, height = columnHeight,
		cframe = CFrame.new(0, columnBottom + columnHeight / 2, 0), color = WHITE,
	})
	for _, f in { 0.25, 0.5, 0.75 } do
		makeCylinder({
			name = "StatueColumnBand", parent = parent, diameter = 4.6, height = 0.8,
			cframe = CFrame.new(0, columnBottom + columnHeight * f, 0), color = brightGold, canCollide = false,
		})
	end
	-- Giant gold coin standing on its edge (cylinder axis along X), scaled
	-- x1.4, grouped as Model "SpinCoin" (pivot = coin center) that the client
	-- city-life sim turns about world Y at CitySpin degrees/s.
	local scale = 1.4
	local coinY = PAD_TOP + 8 + 12
	local spin = makeModel("SpinCoin", parent)
	makeCylinder({
		name = "StatueCoin", parent = spin, diameter = 9 * scale, height = 1.4 * scale, axis = "X",
		cframe = CFrame.new(0, coinY, 0), color = gold, canCollide = false,
	})
	local coinCore = makeCylinder({
		name = "StatueCoinCore", parent = spin, diameter = 6 * scale, height = 1.5 * scale, axis = "X",
		cframe = CFrame.new(0, coinY, 0), color = brightGold,
		material = Enum.Material.Neon, canCollide = false,
	})
	addPointLight(coinCore, brightGold, 20, 0.7)
	-- Dollar-sign-ish bar + serifs across the coin face
	makeBlock({
		name = "StatueDollarBar", parent = spin, size = Vector3.new(1.7, 7.5, 1) * scale,
		cframe = CFrame.new(0, coinY, 0), color = bronze, canCollide = false,
	})
	makeBlock({
		name = "StatueDollarTop", parent = spin, size = Vector3.new(1.8, 0.8, 2.4) * scale,
		cframe = CFrame.new(0, coinY + 3.1 * scale, -0.6 * scale), color = bronze, canCollide = false,
	})
	makeBlock({
		name = "StatueDollarBottom", parent = spin, size = Vector3.new(1.8, 0.8, 2.4) * scale,
		cframe = CFrame.new(0, coinY - 3.1 * scale, 0.6 * scale), color = bronze, canCollide = false,
	})
	spin.WorldPivot = CFrame.new(0, coinY, 0)
	spin:SetAttribute("CitySpin", 40)
	-- Gentle gold sparkle above the coin
	local sparkle = makeMarker(parent, "CoinSparkle", CFrame.new(0, coinY + 5.6 * scale, 0), Vector3.new(7, 1.5, 3) * scale)
	addSparkle(sparkle, "GoldSparkle", brightGold, WHITE, 4, 0.4, 0.8)
end

local function buildTitleBillboard(parent: Instance)
	local baseCF = CFrame.lookAt(ringPos(47, 157.5), Vector3.new(0, 0, 0))
	local postColor = Color3.fromRGB(60, 62, 110)
	for _, xOff in { -9, 9 } do
		makeBlock({ -- 1.12 deep: 0.04 inside the 1.2-deep marquee bar it passes through
			name = "BillboardPost", parent = parent, size = Vector3.new(1.2, 9, 1.12),
			cframe = baseCF * CFrame.new(xOff, PAD_TOP + 4.5, 0), color = postColor,
			material = Enum.Material.Metal,
		})
	end
	local gold = Color3.fromRGB(255, 206, 40)
	local board = makeBlock({
		name = "BillboardBoard", parent = parent, size = Vector3.new(24, 7, 1),
		cframe = baseCF * CFrame.new(0, PAD_TOP + 11.5, 0), color = gold,
	})
	-- White neon marquee around the gold board
	local trim = NEON_WHITE
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
	addSurfaceText(board, "SIDE HUSTLE\nSIMULATOR", Enum.Font.LuckiestGuy, WHITE, Enum.NormalId.Front, nil, gold, MapKit.GUI_RANGE.Landmark)
	addPointLight(board, gold, 16, 0.7)
end

-- Festive bunting: a sagging white wire between each pair of plaza lamp
-- posts (two straight segments per span) hung with point-down pennant flags
-- in cycling candy colors (one WedgePart each, top edge on the wire).
local PENNANT_COLORS = {
	Color3.fromRGB(255, 90, 90),
	Color3.fromRGB(255, 212, 31),
	Color3.fromRGB(60, 200, 255),
	Color3.fromRGB(120, 220, 90),
	Color3.fromRGB(255, 110, 190),
}
local function buildStringLights(parent: Instance)
	-- Wire on the lamp poles just under the bulbs with a shallow sag: the
	-- lowest flag tip stays ~5.8 above the plaza floor (over players' heads).
	local wireY = PAD_TOP + 8.3
	local sagY = PAD_TOP + 7.5
	local flagIndex = 0
	for i = 0, 5 do
		local p0 = ringPos(LAMP_RADIUS, 10 + i * 60, wireY)
		local p1 = ringPos(LAMP_RADIUS, 10 + (i + 1) * 60, wireY)
		local mid = (p0 + p1) / 2
		mid = Vector3.new(mid.X, sagY, mid.Z)
		for _, segment in { { p0, mid }, { mid, p1 } } do
			local from, to = segment[1], segment[2]
			local length = (to - from).Magnitude
			makeBlock({
				name = "StringWire", parent = parent, size = Vector3.new(0.18, 0.18, length),
				cframe = CFrame.lookAt((from + to) / 2, to), color = WHITE,
				canCollide = false, castShadow = false,
			})
			for k = 1, 5 do
				local pos = from:Lerp(to, k / 6)
				flagIndex += 1
				-- Wire frame (local Z along the wire, Y up), flag hung 0.95 below
				-- it and rolled 180 degrees so the wedge's long edge is on top.
				makeWedge({
					name = "Pennant", parent = parent, size = Vector3.new(0.12, 1.8, 1.4),
					cframe = CFrame.lookAt(pos, pos + (to - from)) * CFrame.new(0, -0.95, 0) * CFrame.Angles(0, 0, math.pi),
					color = PENNANT_COLORS[(flagIndex - 1) % #PENNANT_COLORS + 1],
					canCollide = false, castShadow = false,
				})
			end
		end
	end
end

-- Low green mound with a few tiny neon flowers on top.
local function buildFlowerCluster(parent: Instance, position: Vector3, seed: number)
	makeBall({
		name = "FlowerBed", parent = parent, diameter = 2.4,
		cframe = CFrame.new(position + Vector3.new(0, 0.5, 0)), color = LEAF_GREEN, canCollide = false,
	})
	local offsets = {
		Vector3.new(0.5, 1.35, 0.3),
		Vector3.new(-0.6, 1.3, 0.4),
		Vector3.new(0.1, 1.5, -0.6),
		Vector3.new(-0.3, 1.2, -0.1),
	}
	for i, offset in offsets do
		makeBall({
			name = "Flower", parent = parent, diameter = 0.55,
			cframe = CFrame.new(position + offset),
			color = FLOWER_COLORS[(seed + i - 1) % #FLOWER_COLORS + 1],
			material = Enum.Material.Neon, canCollide = false,
		})
	end
end

-- Painted START mat on the spawn slab (the very first thing a new player
-- sees): a sky-blue rounded mat with a white stroke, "START" in the half
-- nearer the fountain and a white chevron in the far half, both pointing at
-- the Lemonade Stand. Painted on an invisible ground deck lying on the slab
-- (MapKit.makeGroundDeck: the gui's up = the slab's -Z = its LookVector =
-- toward the starting zone, independent of Roblox's Top-face convention), so
-- the text reads upright from the default camera behind the player. The
-- deck is CanCollide / CanQuery / CanTouch false: the spawn stays clear.
local function buildWelcomeMat(parent: Instance, spawnLocation: BasePart)
	local size = spawnLocation.Size
	local deckCF = spawnLocation.CFrame * CFrame.new(0, size.Y / 2 + 0.03, 0)
	local _, gui = MapKit.makeGroundDeck(parent, "SpawnWelcomeMat", deckCF, size.X, size.Z, 40, "WelcomeMat", 0.4, 1.2)
	local mat = MapKit.makeGuiFrame({
		name = "Mat", parent = gui, anchor = Vector2.new(0.5, 0.5),
		position = UDim2.fromScale(0.5, 0.5), size = UDim2.fromScale(0.84, 0.84),
		color = Color3.fromRGB(100, 190, 255), corner = 0.12,
	})
	local matStroke = Instance.new("UIStroke")
	matStroke.Color = WHITE
	matStroke.Thickness = 8
	matStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	matStroke.LineJoinMode = Enum.LineJoinMode.Round
	matStroke.Parent = mat
	local label = MapKit.makeTextLabel(mat, "START", Enum.Font.LuckiestGuy, WHITE, UDim2.fromScale(0.07, 0.55), UDim2.fromScale(0.86, 0.34))
	label.ZIndex = 3
	local labelStroke = label:FindFirstChildOfClass("UIStroke")
	if labelStroke then
		labelStroke.Thickness = 6
	end
	-- chevron "^" (tip toward the gui top = the Lemonade Stand): two bars
	-- rotated -45 / +45 degrees whose inner ends overlap at the tip
	local barLength, barWidth = 0.34, 0.09
	local tipX, tipY = 0.5, 0.12
	local reach = (barLength / 2 - barWidth / 2) * math.sqrt(0.5)
	for _, side in { -1, 1 } do
		MapKit.makeGuiFrame({
			name = "Chevron", parent = mat, anchor = Vector2.new(0.5, 0.5),
			position = UDim2.fromScale(tipX + side * reach, tipY + barWidth * 0.5 + reach),
			size = UDim2.fromScale(barLength, barWidth), rotation = side * 45,
			color = WHITE, zIndex = 3,
		})
	end
end

local function buildPlaza(map: Folder)
	local plaza = makeModel("Plaza", map)

	-- Street: stacked SmoothPlastic discs (CityLayout.Street). From the
	-- outside in: the Back Avenue between the skyline rings (white edge ring
	-- r 270..270.6 top 0.08, asphalt r 250.6..270 top 0.12, white edge ring
	-- r 250..250.6 top 0.16), the city-block ground (r 122.5..250, top 0.2),
	-- white curb trim (top 0.3), outer sidewalk "RingRoad" (r 104..120, top
	-- ROAD_TOP 0.5), cartoon blue asphalt (r 66..104, top 0.6), inner sidewalk
	-- (r 58..66, top 0.75), then the plaza rim + floor. Every disc is 1 thick
	-- (or more) so tops stay >= 0.04 apart and never z-fight. Markings, curbs,
	-- crosswalks and traffic lights live in the City model.
	local backEdge = STREET.BackEdgeWidth
	for _, disc in {
		{ name = "BackEdgeOuter", radius = STREET.BackAsphaltOuter + backEdge, top = STREET.BackEdgeOuterTop, color = CURB_WHITE },
		{ name = "BackAsphalt", radius = STREET.BackAsphaltOuter, top = STREET.BackAsphaltTop, color = Color3.fromRGB(68, 72, 94) },
		{ name = "BackEdgeInner", radius = STREET.BackAsphaltInner + backEdge, top = STREET.BackEdgeInnerTop, color = CURB_WHITE },
		{ name = "BlockGround", radius = STREET.BlockGroundRadius, top = STREET.BlockGroundTop, color = SIDEWALK },
	} do
		makeCylinder({
			name = disc.name, parent = plaza, diameter = disc.radius * 2, height = 1,
			cframe = CFrame.new(0, disc.top - 0.5, 0), color = disc.color,
		})
	end
	makeCylinder({
		name = "RoadTrim", parent = plaza, diameter = STREET.OuterCurbRadius * 2, height = 1.8,
		cframe = CFrame.new(0, STREET.OuterCurbTop - 0.9, 0), color = CURB_WHITE,
	})
	makeCylinder({
		name = "RingRoad", parent = plaza, diameter = ROAD_RADIUS * 2, height = 2,
		cframe = CFrame.new(0, ROAD_TOP - 1, 0), color = SIDEWALK,
	})
	makeCylinder({
		name = "Asphalt", parent = plaza, diameter = STREET.AsphaltOuter * 2, height = 1,
		cframe = CFrame.new(0, STREET.AsphaltTop - 0.5, 0), color = Color3.fromRGB(68, 72, 94),
	})
	makeCylinder({
		name = "InnerSidewalk", parent = plaza, diameter = STREET.InnerSidewalkRadius * 2, height = 1,
		cframe = CFrame.new(0, STREET.InnerSidewalkTop - 0.5, 0), color = SIDEWALK,
	})
	-- Plaza disc (smooth cartoon stone) with a lighter step ring
	makeCylinder({
		name = "PlazaTrim", parent = plaza, diameter = (PLAZA_RADIUS + 3) * 2, height = 1.2,
		cframe = CFrame.new(0, 0.7, 0), color = STONE_LIGHT,
	})
	makeCylinder({
		name = "PlazaFloor", parent = plaza, diameter = PLAZA_RADIUS * 2, height = 1,
		cframe = CFrame.new(0, 1, 0), color = STONE,
	})

	-- Spawn (Neutral, plain — no decal clutter): on the plaza floor between
	-- the fountain and the starting zone, facing that zone so a new player's
	-- first view is their first hustle (the coin statue stays behind them).
	-- 12x1x12 slab resting on the floor top (Y PAD_TOP .. PAD_TOP + 1), its
	-- near edge 2.4 studs clear of the fountain rim (radius ~11.6).
	local startZone = GameConfig.getZone(GameConfig.StartingZoneId) or GameConfig.Zones[1]
	local startCenter = Mechanics.zoneCenter(startZone.Order)
	local spawnDir = Vector3.new(startCenter.X, 0, startCenter.Z).Unit
	local spawnPos = spawnDir * 20 + Vector3.new(0, PAD_TOP + 0.5, 0)
	local spawnLocation = Instance.new("SpawnLocation")
	spawnLocation.Name = "SpawnLocation"
	spawnLocation.Size = Vector3.new(12, 1, 12)
	spawnLocation.CFrame = CFrame.lookAt(spawnPos, spawnPos + spawnDir)
	spawnLocation.Color = Color3.fromRGB(236, 228, 205)
	spawnLocation.Material = Enum.Material.SmoothPlastic
	spawnLocation.Anchored = true
	spawnLocation.TopSurface = Enum.SurfaceType.Smooth
	spawnLocation.BottomSurface = Enum.SurfaceType.Smooth
	spawnLocation.Neutral = true
	spawnLocation.Duration = 0
	spawnLocation.Parent = plaza
	-- Gold spawn medallion: a flat disc under the slab (top 1.66, just over
	-- the r 24 plaza inlay at 1.62) + four neon strips on the slab's top
	-- edges. Flat, non-colliding, no shadows: the spawn stays unobstructed.
	local medallionGold = Color3.fromRGB(255, 206, 40)
	makeCylinder({
		name = "SpawnMedallion", parent = plaza, diameter = 17, height = 0.1,
		cframe = CFrame.new(spawnPos.X, PAD_TOP + 0.11, spawnPos.Z), color = medallionGold,
		canCollide = false, castShadow = false,
	})
	local slabTop = spawnLocation.CFrame * CFrame.new(0, 0.5 + 0.06, 0)
	for _, edge in { { 0, 5.825, 0 }, { 0, -5.825, 0 }, { 5.825, 0, 90 }, { -5.825, 0, 90 } } do
		makeBlock({
			name = "SpawnEdgeNeon", parent = plaza, size = Vector3.new(12.2, 0.12, 0.35),
			cframe = slabTop * CFrame.new(edge[1], 0, edge[2]) * CFrame.Angles(0, math.rad(edge[3]), 0),
			color = Color3.fromRGB(255, 236, 150), material = Enum.Material.Neon,
			canCollide = false, castShadow = false,
		})
	end
	buildWelcomeMat(plaza, spawnLocation)

	buildCoinFountain(plaza)

	-- Lamp posts around the plaza + string lights between them
	for i = 0, 5 do
		buildLampPost(plaza, CFrame.new(ringPos(LAMP_RADIUS, 10 + i * 60, PAD_TOP)))
	end
	buildStringLights(plaza)

	-- Benches facing the fountain
	for _, deg in { 55, 185, 300 } do
		local pos = ringPos(30, deg, PAD_TOP)
		buildBench(plaza, CFrame.lookAt(pos, Vector3.new(0, PAD_TOP, 0)))
	end

	-- Flower beds dotted around the plaza
	for i, deg in { 40, 100, 220, 280 } do
		buildFlowerCluster(plaza, ringPos(40, deg, PAD_TOP), i)
	end

	buildTitleBillboard(plaza)
end

----------------------------------------------------------------------
-- Shared zone pieces: hustle station + level gate
----------------------------------------------------------------------

type StationSpec = {
	pos: Vector3, -- counter center (zone-local, on the pad top)
	counter: boolean, -- build the generic counter (false when the zone prop is the counter)
	material: Enum.Material?,
	baseColor: Color3?,
	feedback: Vector3?, -- zone-local override for FeedbackPart
	anchor: Vector3?, -- zone-local override for AutoAnchor
	anchorLook: Vector3?, -- zone-local point the AutoAnchor faces
}

-- Neon accent for a zone: AccentColor, unless it is too dark to glow (Stock
-- Desk's accent is near-black), then the SignColor.
local function neonAccent(zone: GameConfig.ZoneDef): Color3
	local c = zone.AccentColor
	local luminance = 0.299 * c.R + 0.587 * c.G + 0.114 * c.B
	return if luminance < 0.25 then zone.SignColor else c
end

-- Default station layout around the counter center (zone-local offsets):
--   counter    7 wide base / 8 wide top, 3.5 tall, front face at -1.3 / -1.6
--   PromptPart 2.4 in front of the counter center at counter-top height
--   FeedbackPart 9.5 up = 6 studs above the counter top
--   AutoAnchor 8 to the side = 4.5 studs clear of the counter base, its
--     center 0.5 above the pad so its bottom rests on the pad (clients
--     raycast down from it and stand the rig on whatever they hit)
local DEFAULT_FEEDBACK_OFFSET = Vector3.new(0, 9.5, 0)
local DEFAULT_ANCHOR_OFFSET = Vector3.new(8, 0.5, 0)

local function buildHustleStation(zoneModel: Model, zoneCF: CFrame, zone: GameConfig.ZoneDef, spec: StationSpec)
	local station = makeModel("HustleStation", zoneModel)
	local baseCF = zoneCF * CFrame.new(spec.pos)
	if spec.counter then
		local material = spec.material or Enum.Material.SmoothPlastic
		makeBlock({
			name = "CounterBase", parent = station, size = Vector3.new(7, 3, 2.6),
			cframe = baseCF * CFrame.new(0, 1.5, 0), color = spec.baseColor or zone.SignColor,
			material = material,
		})
		makeBlock({
			name = "CounterTop", parent = station, size = Vector3.new(8, 0.5, 3.2),
			cframe = baseCF * CFrame.new(0, 3.25, 0), color = CREAM,
			material = if material == Enum.Material.WoodPlanks then material else Enum.Material.SmoothPlastic,
		})
		makeBlock({
			name = "CounterTrim", parent = station, size = Vector3.new(7.2, 0.6, 0.2),
			cframe = baseCF * CFrame.new(0, 1.5, -1.4), color = neonAccent(zone),
			material = Enum.Material.Neon, canCollide = false,
		})
		-- Verb plaque on the counter front ("WALK!", "TRADE!" ...)
		local plaque = makeBlock({
			name = "CounterPlaque", parent = station, size = Vector3.new(4.4, 1.0, 0.2),
			cframe = baseCF * CFrame.new(0, 2.5, -1.4), color = zoneSignFace(zone), canCollide = false,
		})
		addSurfaceText(plaque, string.upper(zone.HustleVerb) .. "!", Enum.Font.FredokaOne, WHITE, Enum.NormalId.Front, nil, plaque.Color)
	end

	-- The prompt (server connects HustlePrompt.Triggered)
	local promptPart = makePromptPart(station, baseCF * CFrame.new(0, 3, -2.4))
	makePrompt(promptPart, "HustlePrompt", zone.HustleVerb .. "!", zone.Name, zone.HoldDuration or 0, 12)

	-- FeedbackPart: ~6 studs above the counter top; the client parents its
	-- market needle / charge bar / combo BillboardGui here.
	local feedbackLocal = spec.feedback or (spec.pos + DEFAULT_FEEDBACK_OFFSET)
	makeMarker(station, "FeedbackPart", zoneCF * CFrame.new(feedbackLocal))

	-- AutoAnchor: at ground level beside the counter, on open pad (nothing
	-- overhead), facing it; the client stands the automation rig here.
	local anchorLocal = spec.anchor or (spec.pos + DEFAULT_ANCHOR_OFFSET)
	local lookLocal = spec.anchorLook or (spec.pos + Vector3.new(0, 0.5, 0))
	local anchorWorld = zoneCF:PointToWorldSpace(anchorLocal)
	local lookWorld = zoneCF:PointToWorldSpace(lookLocal)
	makeMarker(station, "AutoAnchor", CFrame.lookAt(anchorWorld, lookWorld))
end

local function buildGate(zoneModel: Model, zoneCF: CFrame, zone: GameConfig.ZoneDef)
	local gate = makeModel("Gate", zoneModel)
	-- Gate color: the signature color, except a near-white one (Startup HQ)
	-- whose white neon posts + bar + crest would blow out into a glare blob:
	-- then the AccentColor (MapKit.zoneSignFace).
	local gateColor = zoneSignFace(zone)

	-- Translucent zone-colored energy wall (client opens it per player)
	makeBlock({
		name = "GateWall", parent = gate, size = Vector3.new(26, 11, 1.2),
		cframe = zoneCF * CFrame.new(0, 5.5, -30.5), color = gateColor,
		material = Enum.Material.ForceField, transparency = 0.45, canCollide = true,
	})
	for _, xOff in { -13.4, 13.4 } do
		local post = makeBlock({
			name = "GatePost", parent = gate, size = Vector3.new(1.5, 12.5, 1.5),
			cframe = zoneCF * CFrame.new(xOff, 6.25, -30.5), color = gateColor,
			material = Enum.Material.Neon,
		})
		addPointLight(post, gateColor, 10, 0.5)
	end
	makeBlock({
		name = "GateTopBar", parent = gate, size = Vector3.new(28.5, 1, 1),
		cframe = zoneCF * CFrame.new(0, 12.2, -30.5), color = gateColor,
		material = Enum.Material.Neon, canCollide = false,
	})
	-- Grassy hedges sealing the pad's front edge out to its corners (x 14 ..
	-- 31.92: the outer end stays 0.08 inside the pad curbs' end faces at the
	-- pad edge, x 32, never in their plane)
	for _, xOff in { -22.96, 22.96 } do
		makeBlock({
			name = "GateHedge", parent = gate, size = Vector3.new(17.92, 2.6, 1.8),
			cframe = zoneCF * CFrame.new(xOff, 1.3, -30.5), color = LEAF_GREEN,
			material = Enum.Material.Grass,
		})
	end

	-- Level sign: a neon crest on the arch (SignPart, Y 12.9..15.5 above the
	-- pad) carrying a BillboardGui that floats just above it, readable from
	-- across the map. ZoneGateController hides the billboard once unlocked.
	local signPart = makeBlock({
		name = "SignPart", parent = gate, size = Vector3.new(11, 2.6, 0.9),
		cframe = zoneCF * CFrame.new(0, 14.2, -30.5), color = gateColor,
		material = Enum.Material.Neon, canCollide = false,
	})
	addPointLight(signPart, gateColor, 14, 0.6)
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "GateSign"
	-- BillboardGui Size scale is in studs: an 18 x 5.6 stud sign whose bottom
	-- edge (offset 4.3 - 2.8 = 1.5 above the part center) clears the crest.
	billboard.Size = UDim2.fromScale(18, 5.6)
	billboard.StudsOffset = Vector3.new(0, 4.3, 0)
	billboard.MaxDistance = 400
	billboard.LightInfluence = 0
	billboard.AlwaysOnTop = false
	billboard.Parent = signPart

	-- A bright signature-colored badge (a near-black panel reads as a dead
	-- screen over the bright city). Near-white signatures (Startup HQ) use
	-- their accent so the white, navy-outlined text still reads.
	local sign = zone.SignColor
	local badgeColor = if 0.299 * sign.R + 0.587 * sign.G + 0.114 * sign.B > 0.8 then zone.AccentColor else sign
	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.Size = UDim2.fromScale(1, 1)
	panel.BackgroundColor3 = badgeColor
	panel.BackgroundTransparency = 0
	panel.BorderSizePixel = 0
	panel.Parent = billboard
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.22, 0)
	corner.Parent = panel
	local border = Instance.new("UIStroke")
	border.Color = NAVY
	border.Thickness = 4
	border.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	border.Parent = panel
	local stripe = Instance.new("Frame")
	stripe.Name = "Stripe"
	stripe.AnchorPoint = Vector2.new(0.5, 0)
	stripe.Position = UDim2.fromScale(0.5, 0.56)
	stripe.Size = UDim2.fromScale(0.86, 0.04)
	stripe.BackgroundColor3 = WHITE
	stripe.BorderSizePixel = 0
	stripe.Parent = panel

	makeTextLabel(
		panel, zone.Name, Enum.Font.FredokaOne, WHITE,
		UDim2.fromScale(0.05, 0.06), UDim2.fromScale(0.9, 0.48)
	)
	makeTextLabel(
		panel, "\u{1F512} Reach Level " .. tostring(zone.UnlockLevel), Enum.Font.FredokaOne, WHITE,
		UDim2.fromScale(0.08, 0.62), UDim2.fromScale(0.84, 0.32)
	)
end

----------------------------------------------------------------------
-- Mechanic props: static dressing so each hustle reads from afar
-- (the live feedback is a client BillboardGui on FeedbackPart)
----------------------------------------------------------------------

-- Tap: big chunky neon button on the counter top ("SQUEEZE!" / "GRILL!").
-- cf = counter-top center (top surface), -Z toward the player; the counter
-- top is 3.2 deep, so its front lip is 1.6 in front of cf. `withLabel` adds a
-- verb plaque on that lip (stations with a generic counter already have one).
local function buildTapButton(parent: Instance, cf: CFrame, zone: GameConfig.ZoneDef, withLabel: boolean)
	local domeColor = if zone.Id == "FoodTruck" then zone.AccentColor else zone.SignColor
	makeCylinder({
		name = "TapButtonBase", parent = parent, diameter = 3.2, height = 0.7,
		cframe = cf * CFrame.new(0, 0.35, 0), color = METAL_DARK, material = Enum.Material.Metal,
	})
	makeCylinder({
		name = "TapButtonRim", parent = parent, diameter = 3.0, height = 0.2,
		cframe = cf * CFrame.new(0, 0.8, 0), color = WHITE, material = Enum.Material.Neon, canCollide = false,
	})
	local dome = makeBall({
		name = "TapButtonDome", parent = parent, diameter = 2.8,
		cframe = cf * CFrame.new(0, 1.0, 0), color = domeColor,
		material = Enum.Material.Neon, canCollide = false,
	})
	addPointLight(dome, domeColor, 9, 0.7)
	if withLabel then
		-- Flush against the front face of the counter-top lip, facing the player.
		local plate = makeBlock({
			name = "TapButtonLabel", parent = parent, size = Vector3.new(3.8, 1.1, 0.3),
			cframe = cf * CFrame.new(0, -0.25, -1.75), color = WHITE, canCollide = false,
		})
		addSurfaceText(plate, string.upper(zone.HustleVerb) .. "!", Enum.Font.LuckiestGuy, domeColor, Enum.NormalId.Front, nil, plate.Color)
	end
end

-- Hold (Dog Walking): a long sandy walking path with paw prints and
-- start/finish flags, running along X in front of the counter.
local function buildPawPath(parent: Instance, cf: CFrame, zone: GameConfig.ZoneDef)
	makeBlock({
		name = "WalkPath", parent = parent, size = Vector3.new(32, 0.3, 3.2),
		cframe = cf * CFrame.new(0, 0.35, 0), color = Color3.fromRGB(226, 208, 160),
		material = Enum.Material.Sand,
	})
	local pawColor = Color3.fromRGB(96, 66, 42)
	for i = 0, 6 do
		local pawCF = cf * CFrame.new(-12 + i * 4, 0.58, if i % 2 == 0 then -0.6 else 0.6)
		makeCylinder({
			name = "PawPad", parent = parent, diameter = 1.0, height = 0.16,
			cframe = pawCF, color = pawColor, canCollide = false,
		})
		for _, toe in { Vector3.new(-0.45, 0, -0.65), Vector3.new(0, 0, -0.8), Vector3.new(0.45, 0, -0.65) } do
			makeCylinder({
				name = "PawToe", parent = parent, diameter = 0.36, height = 0.14,
				cframe = pawCF * CFrame.new(toe), color = pawColor, canCollide = false,
			})
		end
	end
	for _, flag in { { x = -17, color = zone.SignColor }, { x = 17, color = WHITE } } do
		makeBlock({
			name = "FlagPost", parent = parent, size = Vector3.new(0.4, 3.4, 0.4),
			cframe = cf * CFrame.new(flag.x, 1.7, 0), color = DARK_WOOD, material = Enum.Material.Wood,
		})
		makeBlock({ -- top 0.04 under the post's top
			name = "Flag", parent = parent, size = Vector3.new(0.15, 1.1, 1.8),
			cframe = cf * CFrame.new(flag.x + 0.2, 2.81, 0.9), color = flag.color,
			material = Enum.Material.Neon, canCollide = false,
		})
	end
end

-- Hold (Car Wash): roller conveyor track running along X through the tunnel.
local function buildConveyor(parent: Instance, cf: CFrame, zone: GameConfig.ZoneDef)
	makeBlock({
		name = "ConveyorBase", parent = parent, size = Vector3.new(34, 0.5, 5),
		cframe = cf * CFrame.new(0, 0.25, 0), color = Color3.fromRGB(70, 72, 82),
		material = Enum.Material.DiamondPlate,
	})
	for i = 0, 8 do
		makeCylinder({
			name = "ConveyorRoller", parent = parent, diameter = 0.9, height = 4.6, axis = "Z",
			cframe = cf * CFrame.new(-16 + i * 4, 0.8, 0), color = Color3.fromRGB(120, 124, 136),
			material = Enum.Material.Metal,
		})
	end
	for _, zOff in { -2.7, 2.7 } do
		makeBlock({
			name = "ConveyorRail", parent = parent, size = Vector3.new(34, 0.3, 0.3),
			cframe = cf * CFrame.new(0, 0.65, zOff), color = zone.AccentColor,
			material = Enum.Material.Neon, canCollide = false,
		})
	end
	for _, xOff in { -17.3, 17.3 } do
		makeBlock({
			name = "ConveyorEnd", parent = parent, size = Vector3.new(1.2, 1.4, 5.4),
			cframe = cf * CFrame.new(xOff, 0.7, 0), color = Color3.fromRGB(50, 52, 60),
			material = Enum.Material.Metal,
		})
	end
end

-- Timing: tall black ticker/hype board with a climbing neon zig-zag and a
-- big arrow tip. cf = board base center on the pad top, front (-Z) to the plaza.
local function buildHypeBoard(parent: Instance, cf: CFrame, neon: Color3, title: string, boardColor: Color3?)
	local frame = Color3.fromRGB(48, 48, 58)
	for _, xOff in { -2.7, 2.7 } do
		makeBlock({
			name = "HypeBoardPost", parent = parent, size = Vector3.new(0.6, 9.4, 0.6),
			cframe = cf * CFrame.new(xOff, 4.7, 0), color = frame, material = Enum.Material.Metal,
		})
	end
	local board = makeBlock({
		name = "HypeBoard", parent = parent, size = Vector3.new(6.6, 6, 0.5),
		cframe = cf * CFrame.new(0, 7, 0), color = boardColor or Color3.fromRGB(14, 14, 18),
	})
	addPointLight(board, neon, 14, 0.8)
	-- Zig-zag line climbing left to right across the front face
	local points = {
		Vector3.new(-2.6, 4.9, 0),
		Vector3.new(-1.4, 6.1, 0),
		Vector3.new(-0.4, 5.4, 0),
		Vector3.new(0.8, 7.2, 0),
		Vector3.new(1.8, 6.6, 0),
		Vector3.new(2.6, 8.7, 0),
	}
	for i = 1, #points - 1 do
		local a, b = points[i], points[i + 1]
		local mid = (a + b) / 2
		local delta = b - a
		makeBlock({
			name = "TickerStrip", parent = parent, size = Vector3.new(delta.Magnitude, 0.28, 0.2),
			cframe = cf * CFrame.new(mid.X, mid.Y, -0.35) * CFrame.Angles(0, 0, math.atan2(delta.Y, delta.X)),
			color = neon, material = Enum.Material.Neon, canCollide = false,
		})
	end
	-- Arrow tip (diamond) at the end of the line
	makeBlock({
		name = "HypeArrowTip", parent = parent, size = Vector3.new(1.1, 1.1, 0.2),
		cframe = cf * CFrame.new(2.6, 8.9, -0.35) * CFrame.Angles(0, 0, math.rad(45)),
		color = neon, material = Enum.Material.Neon, canCollide = false,
	})
	local plate = makeBlock({
		name = "HypeBoardTitle", parent = parent, size = Vector3.new(6.6, 1.2, 0.4),
		cframe = cf * CFrame.new(0, 10.6, 0), color = WHITE,
	})
	addSurfaceText(plate, title, Enum.Font.LuckiestGuy, neon, Enum.NormalId.Front, nil, plate.Color)
end

-- Charge: hype meter column — 5 stacked neon segments on a dark core with a
-- glowing cap. cf = column base center on the pad top, front (-Z) to the plaza.
local function buildHypeColumn(parent: Instance, cf: CFrame, segColor: Color3, capColor: Color3, title: string, segments: number)
	local frame = Color3.fromRGB(40, 38, 45)
	makeCylinder({
		name = "HypeColumnBase", parent = parent, diameter = 3.4, height = 0.6,
		cframe = cf * CFrame.new(0, 0.3, 0), color = frame, material = Enum.Material.Metal,
	})
	makeBlock({
		name = "HypeColumnCore", parent = parent, size = Vector3.new(1.2, 9.2, 1.2),
		cframe = cf * CFrame.new(0, 5.2, 0), color = frame, material = Enum.Material.Metal,
	})
	-- One neon segment per charge step (zone.ChargeMax), packed into the
	-- same 8.5-stud span so the column height never changes.
	local count = math.max(1, segments)
	local step = 8.5 / count
	for i = 0, count - 1 do
		makeBlock({
			name = "HypeSegment", parent = parent, size = Vector3.new(2.4, step * 0.76, 1.5),
			cframe = cf * CFrame.new(0, 1.55 + step * (i + 0.5), 0),
			color = segColor:Lerp(WHITE, if count > 1 then i * 0.64 / (count - 1) else 0),
			material = Enum.Material.Neon, canCollide = false,
		})
	end
	local cap = makeBall({
		name = "HypeColumnCap", parent = parent, diameter = 1.9,
		cframe = cf * CFrame.new(0, 10.5, 0), color = capColor,
		material = Enum.Material.Neon, canCollide = false,
	})
	addPointLight(cap, segColor, 12, 0.8)
	local plate = makeBlock({
		name = "HypeColumnLabel", parent = parent, size = Vector3.new(3.0, 0.9, 0.25),
		cframe = cf * CFrame.new(0, 1.05, -0.75), color = WHITE, canCollide = false,
	})
	addSurfaceText(plate, title, Enum.Font.LuckiestGuy, segColor, Enum.NormalId.Front, nil, plate.Color)
end

local function buildMechanicProp(zoneModel: Model, cf: CFrame, zone: GameConfig.ZoneDef, hasCounterPlaque: boolean)
	local props = makeModel("MechanicProp", zoneModel)
	if zone.Mechanic == "Tap" then
		buildTapButton(props, cf, zone, not hasCounterPlaque)
	elseif zone.Mechanic == "Hold" then
		if zone.Id == "CarWash" then
			buildConveyor(props, cf, zone)
		else
			buildPawPath(props, cf, zone)
		end
	elseif zone.Mechanic == "Timing" then
		local isStock = zone.Id == "StockDesk"
		buildHypeBoard(
			props, cf, if isStock then Color3.fromRGB(70, 255, 130) else zone.SignColor, if isStock then "TICKER" else "HYPE",
			if isStock then STOCK_DEEP_GREEN else nil
		)
	elseif zone.Mechanic == "Charge" then
		local isStartup = zone.Id == "StartupHQ"
		buildHypeColumn(
			props, cf,
			if isStartup then zone.AccentColor else zone.SignColor,
			if isStartup then zone.SignColor else zone.AccentColor,
			if isStartup then "FUNDING" else "HYPE",
			zone.ChargeMax
		)
	end
end

----------------------------------------------------------------------
-- Zone 1: Lemonade Stand — wooden stand, fabric canopy, giant lemon
----------------------------------------------------------------------

local function buildLemonadeStand(zoneModel: Model, zoneCF: CFrame, zone: GameConfig.ZoneDef)
	local yellow = zone.SignColor
	makeBlock({
		name = "StandBase", parent = zoneModel, size = Vector3.new(10, 3.2, 2.6),
		cframe = zoneCF * CFrame.new(0, 1.6, 9), color = WOOD, material = Enum.Material.WoodPlanks,
	})
	makeBlock({
		name = "StandTop", parent = zoneModel, size = Vector3.new(11, 0.5, 3.2),
		cframe = zoneCF * CFrame.new(0, 3.45, 9), color = CREAM, material = Enum.Material.WoodPlanks,
	})
	-- Striped front skirt
	for i = 0, 4 do
		makeBlock({
			name = "StandStripe", parent = zoneModel, size = Vector3.new(1.9, 2.9, 0.2),
			cframe = zoneCF * CFrame.new(-3.8 + i * 1.9, 1.65, 7.65),
			color = if i % 2 == 0 then yellow else WHITE, canCollide = false,
		})
	end
	-- Canopy posts + striped fabric canopy
	for _, xOff in { -4.6, 4.6 } do
		makeBlock({ -- 0.72 thick: 0.04 inside the base's / counter's end + back faces
			name = "CanopyPost", parent = zoneModel, size = Vector3.new(0.72, 8.4, 0.72),
			cframe = zoneCF * CFrame.new(xOff, 4.2, 10.2), color = DARK_WOOD, material = Enum.Material.Wood,
		})
	end
	for i = 0, 4 do
		makeBlock({ -- front edge (z 5.89) 0.04 behind the name board's face
			name = "CanopyStripe", parent = zoneModel, size = Vector3.new(2.3, 0.4, 6.46),
			cframe = zoneCF * CFrame.new(-4.6 + i * 2.3, 8.6, 9.12),
			color = if i % 2 == 0 then yellow else WHITE, material = Enum.Material.Fabric,
		})
	end
	-- GIANT lemon on the roof (ball + two tips, slightly tilted)
	local lemonCF = zoneCF * CFrame.new(0, 12.2, 9.1) * CFrame.Angles(0, 0, math.rad(10))
	makeBall({
		name = "GiantLemon", parent = zoneModel, diameter = 7.4,
		cframe = lemonCF, color = yellow, canCollide = false,
	})
	for _, xOff in { -4.0, 4.0 } do
		makeBall({
			name = "LemonTip", parent = zoneModel, diameter = 1.6,
			cframe = lemonCF * CFrame.new(xOff, 0, 0), color = Color3.fromRGB(235, 190, 28),
			canCollide = false,
		})
	end
	-- Glass pitcher of lemonade (with citrus sparkle) + cups on the counter
	local pitcher = makeCylinder({
		name = "Pitcher", parent = zoneModel, diameter = 1.5, height = 2.3,
		cframe = zoneCF * CFrame.new(2.6, 4.85, 9), color = Color3.fromRGB(255, 236, 150),
		material = Enum.Material.Glass, transparency = 0.3, canCollide = false,
	})
	addSparkle(pitcher, "CitrusSparkle", yellow, WHITE, 4, 0.25, 0.5)
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
	addSignBoard(zoneModel, zoneCF * CFrame.new(0, 7.6, 6.1), 9, 2, zone.Name, zoneSignFace(zone), WHITE)
end

----------------------------------------------------------------------
-- Zone 2: Dog Walking — park lawn, fence, dog house, giant bone, blocky dogs
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
		name = "DogNose", parent = parent, diameter = 0.35,
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

local function buildDogWalking(zoneModel: Model, zoneCF: CFrame, zone: GameConfig.ZoneDef)
	local fenceWhite = Color3.fromRGB(242, 240, 234)
	-- Real grass lawn inside the fence
	makeBlock({
		name = "ParkLawn", parent = zoneModel, size = Vector3.new(52, 0.2, 44),
		cframe = zoneCF * CFrame.new(0, 0.1, 0), color = Color3.fromRGB(98, 184, 82),
		material = Enum.Material.Grass,
	})
	-- White wooden fence along both sides of the park
	for _, xOff in { -28, 28 } do
		for z = -20, 20, 10 do
			makeBlock({
				name = "FencePost", parent = zoneModel, size = Vector3.new(0.7, 2.8, 0.7),
				cframe = zoneCF * CFrame.new(xOff, 1.4, z), color = fenceWhite, material = Enum.Material.Wood,
			})
		end
		for _, yOff in { 1, 2 } do
			makeBlock({
				name = "FenceRail", parent = zoneModel, size = Vector3.new(0.4, 0.35, 42),
				cframe = zoneCF * CFrame.new(xOff, yOff, 0), color = fenceWhite,
				material = Enum.Material.Wood, canCollide = false,
			})
		end
	end
	-- Red dog house with gabled roof
	local houseRed = Color3.fromRGB(196, 60, 54)
	local roofRed = Color3.fromRGB(140, 40, 36)
	makeBlock({
		name = "DogHouse", parent = zoneModel, size = Vector3.new(8, 6, 7),
		cframe = zoneCF * CFrame.new(10, 3, 14), color = houseRed, material = Enum.Material.WoodPlanks,
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
	local boneCF = zoneCF * CFrame.new(-8, 1.5, 2) * CFrame.Angles(0, math.rad(25), 0)
	makeCylinder({
		name = "BoneShaft", parent = zoneModel, diameter = 2, height = 7, axis = "X",
		cframe = boneCF, color = boneWhite,
	})
	for _, xOff in { -3.5, 3.5 } do
		for _, zOff in { -0.9, 0.9 } do
			makeBall({
				name = "BoneKnob", parent = zoneModel, diameter = 3,
				cframe = boneCF * CFrame.new(xOff, 0, zOff), color = boneWhite,
			})
		end
	end
	-- Two tiny blocky dogs
	buildDog(zoneModel, zoneCF * CFrame.new(-14, 0, 12) * CFrame.Angles(0, math.rad(140), 0), Color3.fromRGB(150, 103, 60))
	buildDog(zoneModel, zoneCF * CFrame.new(12, 0, -4) * CFrame.Angles(0, math.rad(-35), 0), Color3.fromRGB(240, 238, 230))
	-- Pink heart-ish motes drifting over the lawn
	local motes = makeMarker(zoneModel, "HeartMotes", zoneCF * CFrame.new(0, 4, 4), Vector3.new(24, 3, 20))
	addParticles(motes, "Hearts", {
		color = ColorSequence.new(Color3.fromRGB(255, 120, 170), Color3.fromRGB(255, 190, 215)),
		size = NumberSequence.new(0.5, 0.9),
		rate = 4,
		lifetime = NumberRange.new(2, 3),
		speed = NumberRange.new(0.6, 1.2),
		acceleration = Vector3.new(0, 0.8, 0),
		lightEmission = 0.9,
	})
	addSignBoard(zoneModel, zoneCF * CFrame.new(10, 9.3, 14), 10, 2.2, zone.Name, zoneSignFace(zone), WHITE)
end

----------------------------------------------------------------------
-- Zone 3: Sneaker Street — concrete storefront, glass window, giant sneaker
----------------------------------------------------------------------

local function buildSneakerFlipping(zoneModel: Model, zoneCF: CFrame, zone: GameConfig.ZoneDef)
	local wallPurple = Color3.fromRGB(74, 64, 120)
	makeBlock({
		name = "StoreBody", parent = zoneModel, size = Vector3.new(22, 14, 12),
		cframe = zoneCF * CFrame.new(0, 7, 16), color = wallPurple, material = Enum.Material.Concrete,
	})
	makeBlock({
		name = "StoreRoof", parent = zoneModel, size = Vector3.new(23, 0.8, 13),
		cframe = zoneCF * CFrame.new(0, 14.4, 16), color = Color3.fromRGB(50, 42, 84),
	})
	makeBlock({
		name = "StoreWindow", parent = zoneModel, size = Vector3.new(12, 5.5, 0.5),
		cframe = zoneCF * CFrame.new(-2, 5.2, 9.8), color = Color3.fromRGB(150, 170, 220),
		material = Enum.Material.Glass, transparency = 0.35, canCollide = false,
	})
	makeBlock({
		name = "StoreDoor", parent = zoneModel, size = Vector3.new(4, 7.5, 0.5),
		cframe = zoneCF * CFrame.new(7.5, 3.75, 9.8), color = zone.SignColor:Lerp(NAVY, 0.35), canCollide = false,
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
	-- Giant sneaker on a marble display pedestal
	local pedestal = makeCylinder({
		name = "SneakerPedestal", parent = zoneModel, diameter = 7, height = 2.4,
		cframe = zoneCF * CFrame.new(-12, 1.2, -2), color = WHITE, material = Enum.Material.Marble,
	})
	addSparkle(pedestal, "HypeSparkle", zone.SignColor, zone.AccentColor, 2, 0.3, 0.6)
	local shoeCF = zoneCF * CFrame.new(-12, 0, -2)
	makeBlock({
		name = "SneakerSole", parent = zoneModel, size = Vector3.new(7.5, 0.9, 3),
		cframe = shoeCF * CFrame.new(0, 2.85, 0), color = WHITE,
		canCollide = false,
	})
	makeBlock({
		name = "SneakerHeel", parent = zoneModel, size = Vector3.new(2.4, 1.6, 2.9),
		cframe = shoeCF * CFrame.new(-2.3, 4.1, 0), color = zone.SignColor,
		canCollide = false,
	})
	makeBlock({
		name = "SneakerBody", parent = zoneModel, size = Vector3.new(4.5, 2.1, 2.9),
		cframe = shoeCF * CFrame.new(-0.4, 4.35, 0), color = zone.SignColor,
		canCollide = false,
	})
	makeWedge({
		name = "SneakerToe", parent = zoneModel, size = Vector3.new(2.9, 1.9, 2.4),
		cframe = shoeCF * CFrame.new(2.6, 4.25, 0) * CFrame.Angles(0, -RAD_90, 0), color = zone.SignColor,
		canCollide = false,
	})
	makeBlock({
		name = "SneakerSwoosh", parent = zoneModel, size = Vector3.new(2.8, 0.5, 0.2),
		cframe = shoeCF * CFrame.new(0, 4.4, -1.55) * CFrame.Angles(0, 0, math.rad(-14)),
		color = zone.AccentColor, material = Enum.Material.Neon, canCollide = false,
	})
	addSignBoard(zoneModel, zoneCF * CFrame.new(0, 11.8, 9.85), 14, 2.6, zone.Name, zoneSignFace(zone), WHITE)
end

----------------------------------------------------------------------
-- Zone 4: Car Wash — metal/glass tunnel, roller brushes, blocky car, foam
----------------------------------------------------------------------

local function buildCarWash(zoneModel: Model, zoneCF: CFrame, zone: GameConfig.ZoneDef)
	local aqua = zone.SignColor
	-- Tunnel: low front wall (so the inside is visible), full back wall, roof, columns
	makeBlock({
		name = "TunnelFrontWall", parent = zoneModel, size = Vector3.new(22, 4.5, 1.2),
		cframe = zoneCF * CFrame.new(0, 2.25, 2), color = aqua, material = Enum.Material.Metal,
	})
	makeBlock({
		name = "TunnelBackWall", parent = zoneModel, size = Vector3.new(22, 9, 1.2),
		cframe = zoneCF * CFrame.new(0, 4.5, 14), color = aqua, material = Enum.Material.Metal,
	})
	for _, xOff in { -10.5, 10.5 } do
		makeBlock({
			name = "TunnelColumn", parent = zoneModel, size = Vector3.new(1.6, 9, 1.6),
			cframe = zoneCF * CFrame.new(xOff, 4.5, 2), color = aqua, material = Enum.Material.Metal,
		})
	end
	makeBlock({
		name = "TunnelRoof", parent = zoneModel, size = Vector3.new(23, 1.2, 14),
		cframe = zoneCF * CFrame.new(0, 9.6, 8), color = Color3.fromRGB(44, 150, 170),
		material = Enum.Material.Metal,
	})
	makeBlock({
		name = "TunnelGlass", parent = zoneModel, size = Vector3.new(20, 3.6, 0.4),
		cframe = zoneCF * CFrame.new(0, 6.5, 2), color = Color3.fromRGB(160, 225, 245),
		material = Enum.Material.Glass, transparency = 0.45, canCollide = false,
	})
	makeBlock({ -- 0.04 proud of the roof's front face and ends
		name = "TunnelTrim", parent = zoneModel, size = Vector3.new(23.08, 0.8, 0.8),
		cframe = zoneCF * CFrame.new(0, 10.3, 1.36), color = zone.AccentColor,
		material = Enum.Material.Neon, canCollide = false,
	})
	-- Big fabric roller brushes hanging from the roof (Y 1.3..9.0): clear of
	-- the conveyor rollers (top 1.25) and of the car body (X -4..4, Z 5.9..10.1)
	for _, offset in { Vector3.new(-6, 0, 5.4), Vector3.new(0, 0, 11.7), Vector3.new(6, 0, 5.4) } do
		makeCylinder({
			name = "RollerBrush", parent = zoneModel, diameter = 3, height = 7.7,
			cframe = zoneCF * CFrame.new(offset.X, 5.15, offset.Z), color = Color3.fromRGB(30, 70, 115),
			material = Enum.Material.Fabric,
		})
	end
	-- Chunky blocky car riding the conveyor: raised 1.25 so the wheel bottoms
	-- (diameter 2 at local y 1) rest on the roller tops (0.8 + 0.45 = 1.25).
	local carCF = zoneCF * CFrame.new(0, 1.25, 0)
	makeBlock({
		name = "CarBody", parent = zoneModel, size = Vector3.new(8, 2.2, 4.2),
		cframe = carCF * CFrame.new(0, 2.1, 8), color = Color3.fromRGB(224, 82, 72),
	})
	makeBlock({
		name = "CarCabin", parent = zoneModel, size = Vector3.new(4, 1.8, 3.8),
		cframe = carCF * CFrame.new(-0.4, 4.1, 8), color = Color3.fromRGB(120, 170, 210),
		material = Enum.Material.Glass, transparency = 0.35,
	})
	for _, xOff in { -2.8, 2.8 } do
		for _, zOff in { -2.3, 2.3 } do
			makeCylinder({
				name = "CarWheel", parent = zoneModel, diameter = 2, height = 0.8, axis = "Z",
				cframe = carCF * CFrame.new(xOff, 1, 8 + zOff), color = WHEEL_DARK,
			})
		end
	end
	-- A few static foam blobs on the car + rising foam bubbles in the tunnel
	for _, bubble in { { Vector3.new(0, 3.6, 7), 1.8 }, { Vector3.new(2.4, 3.5, 9), 1.4 }, { Vector3.new(0.8, 5.3, 8.2), 1.6 }, { Vector3.new(-2.6, 3.4, 7.4), 1.3 } } do
		makeBall({
			name = "FoamBubble", parent = zoneModel, diameter = bubble[2],
			cframe = carCF * CFrame.new(bubble[1]), color = Color3.fromRGB(250, 250, 255),
			transparency = 0.2, canCollide = false,
		})
	end
	local foam = makeMarker(zoneModel, "FoamVolume", zoneCF * CFrame.new(0, 2.5, 8), Vector3.new(18, 2, 10))
	addParticles(foam, "FoamBubbles", {
		color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(225, 245, 255)),
		size = NumberSequence.new(0.6, 1.2),
		transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.15),
			NumberSequenceKeypoint.new(0.8, 0.3),
			NumberSequenceKeypoint.new(1, 1),
		}),
		rate = 8,
		lifetime = NumberRange.new(1.6, 2.4),
		speed = NumberRange.new(1, 2),
		acceleration = Vector3.new(0, 1.2, 0),
		lightEmission = 0.3,
	})
	addSignBoard(zoneModel, zoneCF * CFrame.new(0, 11.6, 2), 14, 2.4, zone.Name, zoneSignFace(zone), WHITE)
end

----------------------------------------------------------------------
-- Zone 5: Food Truck — metal truck, diamond-plate skirt, HUGE burger, smoke
----------------------------------------------------------------------

local function buildFoodTruck(zoneModel: Model, zoneCF: CFrame, zone: GameConfig.ZoneDef)
	local orange = zone.SignColor
	local truckCF = zoneCF * CFrame.new(0, 0, 8)
	makeBlock({
		name = "TruckBody", parent = zoneModel, size = Vector3.new(15, 5, 6),
		cframe = truckCF * CFrame.new(0, 3.9, 0), color = orange, material = Enum.Material.Metal,
	})
	makeBlock({
		name = "TruckSkirt", parent = zoneModel, size = Vector3.new(15.2, 1.0, 6.2),
		cframe = truckCF * CFrame.new(0, 1.7, 0), color = Color3.fromRGB(150, 150, 160),
		material = Enum.Material.DiamondPlate,
	})
	makeBlock({
		name = "TruckCab", parent = zoneModel, size = Vector3.new(4, 3.6, 5.6),
		cframe = truckCF * CFrame.new(-9.5, 3.2, 0), color = orange, material = Enum.Material.Metal,
	})
	makeBlock({
		name = "TruckWindshield", parent = zoneModel, size = Vector3.new(0.5, 1.8, 4.4),
		cframe = truckCF * CFrame.new(-11.3, 4.2, 0), color = Color3.fromRGB(120, 170, 210),
		material = Enum.Material.Glass, transparency = 0.3, canCollide = false,
	})
	for _, xOff in { -9, 5 } do
		for _, zOff in { -3.4, 3.4 } do
			makeCylinder({
				name = "TruckWheel", parent = zoneModel, diameter = 2.4, height = 0.9, axis = "Z",
				cframe = truckCF * CFrame.new(xOff, 1.2, zOff), color = WHEEL_DARK,
			})
		end
	end
	-- Serving window + counter lip + fabric awning (front side, facing the plaza)
	makeBlock({
		name = "ServingWindow", parent = zoneModel, size = Vector3.new(6, 2.4, 0.4),
		cframe = truckCF * CFrame.new(0.5, 4.4, -3.05), color = Color3.fromRGB(80, 90, 110),
		material = Enum.Material.Glass, transparency = 0.3, canCollide = false,
	})
	makeBlock({
		name = "WindowCounter", parent = zoneModel, size = Vector3.new(6.6, 0.4, 1),
		cframe = truckCF * CFrame.new(0.5, 3.1, -3.5), color = CREAM, material = Enum.Material.WoodPlanks,
	})
	makeBlock({
		name = "Awning", parent = zoneModel, size = Vector3.new(7, 0.4, 2.4),
		cframe = truckCF * CFrame.new(0.5, 5.9, -3.8) * CFrame.Angles(math.rad(-20), 0, 0),
		color = zone.AccentColor, material = Enum.Material.Fabric, canCollide = false,
	})
	-- Grill chimney with smoke
	local chimney = makeCylinder({
		name = "GrillChimney", parent = zoneModel, diameter = 1.2, height = 1.6,
		cframe = truckCF * CFrame.new(5.5, 7.2, 1.5), color = METAL_DARK, material = Enum.Material.Metal,
		canCollide = false,
	})
	addParticles(chimney, "GrillSmoke", {
		color = ColorSequence.new(Color3.fromRGB(150, 150, 155), Color3.fromRGB(205, 205, 210)),
		size = NumberSequence.new(1, 2.6),
		transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.4),
			NumberSequenceKeypoint.new(0.6, 0.7),
			NumberSequenceKeypoint.new(1, 1),
		}),
		rate = 5,
		lifetime = NumberRange.new(2, 3),
		speed = NumberRange.new(2, 3),
		spread = Vector2.new(10, 10),
		acceleration = Vector3.new(0, 1, 0),
		lightEmission = 0,
		rotSpeed = NumberRange.new(-20, 20),
	})
	-- HUGE burger on the roof: bun / patty / cheese / lettuce / dome bun
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
	-- Dome bun: a sphere whose equator sits at the lettuce (lower half hidden)
	makeBall({
		name = "BurgerBunTop", parent = zoneModel, diameter = 6.6,
		cframe = truckCF * CFrame.new(0, 9.7, 0), color = Color3.fromRGB(233, 170, 92), canCollide = false,
	})
	for _, offset in { Vector3.new(-1.4, 12.5, 0.8), Vector3.new(1.2, 12.6, -0.6), Vector3.new(0.2, 12.8, 1.2) } do
		makeBall({
			name = "SesameSeed", parent = zoneModel, diameter = 0.45,
			cframe = truckCF * CFrame.new(offset), color = CREAM, canCollide = false,
		})
	end
	-- Menu board beside the truck
	addSignBoard(zoneModel, zoneCF * CFrame.new(10.5, 4, 2), 4.2, 3, "MENU", WHITE, zone.SignColor, zone.SignColor)
	makeBlock({
		name = "MenuPost", parent = zoneModel, size = Vector3.new(0.4, 3.2, 0.4),
		cframe = zoneCF * CFrame.new(10.5, 1.6, 2), color = DARK_WOOD, material = Enum.Material.Wood,
	})
	-- Name sign on two posts left of the truck (in front of the cab, clear of
	-- the counter so it reads from the plaza; board Y 5.6..7.6 above the pad)
	for _, xOff in { -20, -12 } do
		makeBlock({ -- 0.42 deep: 0.04 inside the 0.5-deep board it holds up
			name = "NameSignPost", parent = zoneModel, size = Vector3.new(0.5, 5.8, 0.42),
			cframe = zoneCF * CFrame.new(xOff, 2.9, 0), color = DARK_WOOD, material = Enum.Material.Wood,
		})
	end
	addSignBoard(zoneModel, zoneCF * CFrame.new(-16, 6.6, 0), 9, 2, zone.Name, zoneSignFace(zone), WHITE)
end

----------------------------------------------------------------------
-- Zone 6: Creator Studio — pink neon, glass window, giant ring light, tripod
----------------------------------------------------------------------

local function buildContentCreator(zoneModel: Model, zoneCF: CFrame, zone: GameConfig.ZoneDef)
	local pink = zone.SignColor
	local studioDark = Color3.fromRGB(40, 38, 45)
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
		cframe = zoneCF * CFrame.new(0, 6, 9.8), color = Color3.fromRGB(220, 150, 220),
		material = Enum.Material.Glass, transparency = 0.35, canCollide = false,
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
		cframe = zoneCF * CFrame.new(-9, 0.25, -2), color = studioDark, material = Enum.Material.Metal,
	})
	makeCylinder({
		name = "RingLightPole", parent = zoneModel, diameter = 0.7, height = 5.5,
		cframe = zoneCF * CFrame.new(-9, 3.25, -2), color = studioDark, material = Enum.Material.Metal,
	})
	local ring = makeCylinder({
		name = "RingLight", parent = zoneModel, diameter = 9, height = 0.8, axis = "Z",
		cframe = zoneCF * CFrame.new(-9, 7, -2), color = pink,
		material = Enum.Material.Neon, canCollide = false,
	})
	addPointLight(ring, pink, 16, 0.9)
	makeCylinder({
		name = "RingLightInner", parent = zoneModel, diameter = 6.8, height = 0.7, axis = "Z",
		cframe = zoneCF * CFrame.new(-9, 7, -2.15), color = studioDark, canCollide = false,
	})
	-- Pink neon motes around the ring light
	local motes = makeMarker(zoneModel, "NeonMotes", zoneCF * CFrame.new(-9, 6, -2), Vector3.new(10, 8, 8))
	addSparkle(motes, "PinkMotes", pink, Color3.fromRGB(255, 180, 230), 5, 0.3, 0.7)
	-- Phone on a tripod, filming the ring light
	local tripodCF = zoneCF * CFrame.new(-9, 0, -8.5)
	for i = 0, 2 do
		makeBlock({
			name = "TripodLeg", parent = zoneModel, size = Vector3.new(0.35, 4.4, 0.35),
			cframe = tripodCF * CFrame.Angles(0, math.rad(i * 120), 0) * CFrame.new(0, 2.1, -1) * CFrame.Angles(math.rad(14), 0, 0),
			color = studioDark, material = Enum.Material.Metal,
		})
	end
	makeBlock({
		name = "TripodHead", parent = zoneModel, size = Vector3.new(0.8, 0.8, 0.8),
		cframe = tripodCF * CFrame.new(0, 4.3, 0), color = studioDark, canCollide = false,
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
	-- Yaw +90 puts each wedge's tall back face at zone-local +X, so the apex
	-- points to -X = the right-hand side of a viewer looking from the plaza.
	makeWedge({
		name = "PlayTriangleTop", parent = zoneModel, size = Vector3.new(0.8, 1.4, 2.8),
		cframe = zoneCF * CFrame.new(9, 4.15, -4.15) * CFrame.Angles(0, RAD_90, 0),
		color = WHITE, canCollide = false,
	})
	makeWedge({
		name = "PlayTriangleBottom", parent = zoneModel, size = Vector3.new(0.8, 1.4, 2.8),
		cframe = zoneCF * CFrame.new(9, 2.75, -4.15) * CFrame.Angles(0, RAD_90, 0) * CFrame.Angles(0, 0, math.rad(180)),
		color = WHITE, canCollide = false,
	})
	addSignBoard(zoneModel, zoneCF * CFrame.new(0, 10.4, 9.85), 14, 2.5, zone.Name, zoneSignFace(zone), WHITE)
end

----------------------------------------------------------------------
-- Zone 7: Stock Desk — dark metal office, neon ticker screens, big up arrow
----------------------------------------------------------------------

local function buildStockDesk(zoneModel: Model, zoneCF: CFrame, zone: GameConfig.ZoneDef)
	local neonGreen = Color3.fromRGB(70, 255, 130)
	-- Local override (GameConfig keeps its near-black AccentColor): the
	-- backdrop and screens are a deep ticker green, never the darkest shapes
	-- in the zone.
	local deepGreen = STOCK_DEEP_GREEN
	local screenGreen = deepGreen:Lerp(NAVY, 0.25)
	makeBlock({
		name = "OfficeBody", parent = zoneModel, size = Vector3.new(18, 12, 12),
		cframe = zoneCF * CFrame.new(0, 6, 14), color = deepGreen,
	})
	makeBlock({
		name = "OfficeRoof", parent = zoneModel, size = Vector3.new(19, 0.8, 13),
		cframe = zoneCF * CFrame.new(0, 12.4, 14), color = deepGreen:Lerp(WHITE, 0.2),
	})
	makeBlock({
		name = "OfficeDoor", parent = zoneModel, size = Vector3.new(3.5, 6, 0.5),
		cframe = zoneCF * CFrame.new(0, 3, 7.8), color = screenGreen, canCollide = false,
	})
	makeBlock({
		name = "OfficeTrim", parent = zoneModel, size = Vector3.new(18.6, 0.6, 0.6),
		cframe = zoneCF * CFrame.new(0, 12.1, 8), color = zone.SignColor,
		material = Enum.Material.Neon, canCollide = false,
	})
	for _, xOff in { -9.1, 9.1 } do
		makeBlock({
			name = "OfficeCornerStrip", parent = zoneModel, size = Vector3.new(0.6, 12.4, 0.6),
			cframe = zoneCF * CFrame.new(xOff, 6.2, 8), color = zone.SignColor,
			material = Enum.Material.Neon, canCollide = false,
		})
	end
	-- Green-on-black ticker screens on the front wall
	for _, xOff in { -4.5, 4.5 } do
		makeBlock({
			name = "TickerScreen", parent = zoneModel, size = Vector3.new(6.5, 3, 0.5),
			cframe = zoneCF * CFrame.new(xOff, 6.8, 7.8), color = screenGreen, canCollide = false,
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
	-- Green money sparkle over the trading counter
	local sparkle = makeMarker(zoneModel, "MoneySparkle", zoneCF * CFrame.new(0, 7, -8), Vector3.new(8, 2, 4))
	addSparkle(sparkle, "MoneySparkle", Color3.fromRGB(60, 255, 120), Color3.fromRGB(180, 255, 200), 5, 0.4, 0.8)
	addSignBoard(zoneModel, zoneCF * CFrame.new(0, 10.6, 7.85), 13, 2.5, zone.Name, zoneSignFace(zone), WHITE)
end

----------------------------------------------------------------------
-- Zone 8: Startup HQ — sleek white tower with glass bands, logo cube, rocket
----------------------------------------------------------------------

local function buildStartupHQ(zoneModel: Model, zoneCF: CFrame, zone: GameConfig.ZoneDef)
	local glassBlue = Color3.fromRGB(90, 150, 255)
	local towerCF = zoneCF * CFrame.new(0, 0, 18)
	local tiers = {
		{ size = Vector3.new(16, 5, 16), y = 2.5, glass = false },
		{ size = Vector3.new(16.4, 1.8, 16.4), y = 6.4, glass = true },
		{ size = Vector3.new(14, 5, 14), y = 9.8, glass = false },
		{ size = Vector3.new(14.4, 1.8, 14.4), y = 13.2, glass = true },
		{ size = Vector3.new(12, 5, 12), y = 16.6, glass = false },
		{ size = Vector3.new(10, 2, 10), y = 20.1, glass = false },
	}
	for _, tier in tiers do
		makeBlock({
			name = if tier.glass then "TowerGlass" else "TowerTier", parent = zoneModel, size = tier.size,
			cframe = towerCF * CFrame.new(0, tier.y, 0),
			color = if tier.glass then glassBlue else WHITE,
			material = if tier.glass then Enum.Material.Glass else Enum.Material.SmoothPlastic,
			transparency = if tier.glass then 0.35 else 0,
		})
	end
	makeBlock({
		name = "TowerDoor", parent = zoneModel, size = Vector3.new(3.5, 5.5, 0.6),
		cframe = towerCF * CFrame.new(0, 2.75, -8.1), color = Color3.fromRGB(120, 170, 230),
		material = Enum.Material.Glass, transparency = 0.3, canCollide = false,
	})
	-- Blue neon logo cube on a small pole, tilted like a diamond
	makeBlock({
		name = "LogoPole", parent = zoneModel, size = Vector3.new(0.4, 1.6, 0.4),
		cframe = towerCF * CFrame.new(0, 21.9, 0), color = WHITE, canCollide = false,
	})
	local logo = makeBlock({
		name = "LogoCube", parent = zoneModel, size = Vector3.new(2.8, 2.8, 2.8),
		cframe = towerCF * CFrame.new(0, 23.2, 0) * CFrame.Angles(math.rad(35), math.rad(45), 0),
		color = zone.AccentColor, material = Enum.Material.Neon, canCollide = false,
	})
	addPointLight(logo, zone.AccentColor, 16, 0.8)
	-- Small rocket statue: cylinder body, crossed-wedge nose cone, wedge fins
	local rocketCF = zoneCF * CFrame.new(-12, 0, -4)
	makeCylinder({
		name = "RocketPedestal", parent = zoneModel, diameter = 5.5, height = 1.2,
		cframe = rocketCF * CFrame.new(0, 0.6, 0), color = Color3.fromRGB(205, 198, 182),
		material = Enum.Material.Marble,
	})
	makeCylinder({
		name = "RocketBody", parent = zoneModel, diameter = 3, height = 7,
		cframe = rocketCF * CFrame.new(0, 4.7, 0), color = Color3.fromRGB(244, 244, 248),
		material = Enum.Material.Metal,
	})
	makeBall({
		name = "RocketWindow", parent = zoneModel, diameter = 1.3,
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
	-- Blue sparkle around the rocket
	local sparkle = makeMarker(zoneModel, "RocketSparkle", rocketCF * CFrame.new(0, 5, 0), Vector3.new(5, 8, 5))
	addSparkle(sparkle, "BlueSparkle", zone.AccentColor, Color3.fromRGB(170, 210, 255), 5, 0.3, 0.7)
	addSignBoard(zoneModel, towerCF * CFrame.new(0, 8.5, -8.1), 12, 2.2, zone.Name, zoneSignFace(zone), WHITE)
end

----------------------------------------------------------------------
-- Generic fallback for any future zone id without a bespoke builder
----------------------------------------------------------------------

local function buildGenericZone(zoneModel: Model, zoneCF: CFrame, zone: GameConfig.ZoneDef)
	makeBlock({
		name = "Building", parent = zoneModel, size = Vector3.new(20, 12, 12),
		cframe = zoneCF * CFrame.new(0, 6, 16), color = zone.SignColor, material = Enum.Material.Concrete,
	})
	addSignBoard(zoneModel, zoneCF * CFrame.new(0, 10, 9.8), 14, 2.5, zone.Name, zoneSignFace(zone), WHITE)
end

local ZONE_BUILDERS: { [string]: (Model, CFrame, GameConfig.ZoneDef) -> () } = {
	LemonadeStand = buildLemonadeStand,
	DogWalking = buildDogWalking,
	SneakerFlipping = buildSneakerFlipping,
	CarWash = buildCarWash,
	FoodTruck = buildFoodTruck,
	ContentCreator = buildContentCreator,
	StockDesk = buildStockDesk,
	StartupHQ = buildStartupHQ,
}

-- Hustle station placement per zone (zone-local, on the pad top; -Z = plaza).
local STATIONS: { [string]: StationSpec } = {
	-- The stand itself is the counter (top Y 3.7, X -5.5..5.5, Z 7.4..10.6);
	-- PromptPart lands at (0, 3, 4.6) in front of it. FeedbackPart sits right
	-- above the prompt (6.3 over the stand top, in front of canopy + lemon);
	-- AutoAnchor stands on open pad 4 studs clear of the stand's +X side.
	LemonadeStand = {
		pos = Vector3.new(0, 0, 7), counter = false,
		feedback = Vector3.new(0, 10, 4.6),
		anchor = Vector3.new(9.5, 0.5, 8.5), anchorLook = Vector3.new(0, 0.5, 9),
	},
	DogWalking = { pos = Vector3.new(0, 0, -12), counter = true, material = Enum.Material.WoodPlanks, baseColor = WOOD },
	SneakerFlipping = { pos = Vector3.new(6, 0, -8), counter = true, material = Enum.Material.Concrete },
	CarWash = { pos = Vector3.new(0, 0, -12), counter = true, material = Enum.Material.Metal },
	FoodTruck = { pos = Vector3.new(0, 0, -2), counter = true, material = Enum.Material.DiamondPlate },
	ContentCreator = { pos = Vector3.new(0, 0, -8), counter = true, material = Enum.Material.SmoothPlastic },
	StockDesk = { pos = Vector3.new(0, 0, -8), counter = true, material = Enum.Material.Metal },
	StartupHQ = { pos = Vector3.new(6, 0, -8), counter = true, material = Enum.Material.SmoothPlastic, baseColor = WHITE },
}
local DEFAULT_STATION: StationSpec = { pos = Vector3.new(0, 0, -10), counter = true }

-- Mechanic prop anchor per zone (zone-local CFrame; see buildMechanicProp).
local MECHANIC_PROP_CF: { [string]: CFrame } = {
	LemonadeStand = CFrame.new(0, 3.7, 9), -- SQUEEZE! button on the stand top
	DogWalking = CFrame.new(0, 0, -19), -- paw-print path in front of the counter
	SneakerFlipping = CFrame.new(-4, 0, -6), -- hype board left of the counter
	CarWash = CFrame.new(0, 0, 8), -- roller conveyor through the tunnel
	FoodTruck = CFrame.new(0, 3.5, -2), -- GRILL! button on the counter top
	ContentCreator = CFrame.new(-6, 0, -9), -- hype meter column
	StockDesk = CFrame.new(-8, 0, -5), -- ticker board
	StartupHQ = CFrame.new(-1, 0, -9), -- funding meter column
}

local function buildZone(zonesFolder: Folder, zone: GameConfig.ZoneDef)
	-- Contract: the same function the client uses for nearest-zone lookups.
	local groundCF = Mechanics.zoneGroundCFrame(zone.Order)

	local zoneModel = Instance.new("Model")
	zoneModel.Name = zone.Id
	zoneModel:SetAttribute("ZoneId", zone.Id)
	zoneModel.Parent = zonesFolder

	-- Colored floor pad: the brightest ground in town (signature color mixed
	-- 35% toward white) striped like a carpet: five 9.6-wide stripes run from
	-- the gate to the back (local Z) over the middle 48 x 48, the center and
	-- outer stripes in the near-full signature color (10% white; Startup HQ's
	-- accent blue 25% white), the two between light (60% white), so even a
	-- pale signature (Car Wash aqua) reads as a bold carpet from the gate to
	-- the counter, never an empty pool floor. Chunky signature curbs with neon strips on the
	-- three non-entrance edges. Startup HQ's SignColor is near-white, so its
	-- pad, stripes and curbs are built from the AccentColor blue instead.
	-- The pad is 3 thick centered on Y=0: top at PAD_TOP, bottom buried.
	local signFace = zoneSignFace(zone)
	local isPaleSign = signFace ~= zone.SignColor
	local padColor = if isPaleSign then Color3.fromRGB(196, 220, 255) else zone.SignColor:Lerp(WHITE, 0.35)
	-- neon edge strips: the zone's neon accent; white on Startup HQ's blue curbs
	local edgeNeon = if isPaleSign then NEON_WHITE else neonAccent(zone)
	makeBlock({
		name = "ZonePad", parent = zoneModel, size = Vector3.new(PAD_SIZE, PAD_TOP * 2, PAD_SIZE),
		cframe = groundCF, color = padColor,
	})
	if zone.Id ~= "DogWalking" then -- the dog park's lawn already covers its pad
		local stripeBase = if isPaleSign then zone.AccentColor else zone.SignColor
		local rich, light = stripeBase:Lerp(WHITE, if isPaleSign then 0.25 else 0.1), stripeBase:Lerp(WHITE, 0.6)
		for i, x in { -19.2, -9.6, 0, 9.6, 19.2 } do
			makeBlock({
				name = "PadStripe", parent = zoneModel, size = Vector3.new(9.6, 0.06, PAD_SIZE - 16),
				cframe = groundCF * CFrame.new(x, PAD_TOP + 0.03, 0), color = if i % 2 == 1 then rich else light,
				canCollide = false, castShadow = false,
			})
		end
	end
	local curbW, curbH = 2, 0.5
	local edge = PAD_SIZE / 2 - curbW / 2
	-- front (entrance, toward the plaza) and back curbs run the full width;
	-- side curbs fit between them
	for _, zOff in { -edge, edge } do
		makeBlock({
			name = "PadCurb", parent = zoneModel, size = Vector3.new(PAD_SIZE, curbH, curbW),
			cframe = groundCF * CFrame.new(0, PAD_TOP + curbH / 2, zOff), color = signFace,
			canCollide = false, castShadow = false,
		})
	end
	for _, xOff in { -edge, edge } do
		makeBlock({
			name = "PadCurb", parent = zoneModel, size = Vector3.new(curbW, curbH, PAD_SIZE - curbW * 2),
			cframe = groundCF * CFrame.new(xOff, PAD_TOP + curbH / 2, 0), color = signFace,
			canCollide = false, castShadow = false,
		})
		makeBlock({
			name = "PadCurbNeon", parent = zoneModel, size = Vector3.new(0.6, 0.2, PAD_SIZE - curbW * 2),
			cframe = groundCF * CFrame.new(xOff, PAD_TOP + curbH + 0.1, 0), color = edgeNeon,
			material = Enum.Material.Neon, canCollide = false, castShadow = false,
		})
	end
	makeBlock({
		name = "PadCurbNeon", parent = zoneModel, size = Vector3.new(PAD_SIZE, 0.2, 0.6),
		cframe = groundCF * CFrame.new(0, PAD_TOP + curbH + 0.1, edge), color = edgeNeon,
		material = Enum.Material.Neon, canCollide = false, castShadow = false,
	})
	-- Entrance carpet on the outer sidewalk: links the zebra crossing to the
	-- gate (zone-local z -45..-32, r 105..118), flush enough (top <= ROAD_TOP
	-- + 0.08) for walkers and crossers to pass over it.
	makeBlock({
		name = "EntranceCarpet", parent = zoneModel, size = Vector3.new(14, 0.06, 13),
		cframe = groundCF * CFrame.new(0, ROAD_TOP + 0.03, -38.5), color = signFace,
		canCollide = false, castShadow = false,
	})
	for _, xOff in { -7.25, 7.25 } do
		makeBlock({
			name = "EntranceCarpetNeon", parent = zoneModel, size = Vector3.new(0.5, 0.08, 13),
			cframe = groundCF * CFrame.new(xOff, ROAD_TOP + 0.04, -38.5), color = edgeNeon,
			material = Enum.Material.Neon, canCollide = false, castShadow = false,
		})
	end

	local zoneCF = groundCF * CFrame.new(0, PAD_TOP, 0)
	local builder = ZONE_BUILDERS[zone.Id] or buildGenericZone
	builder(zoneModel, zoneCF, zone)

	local stationSpec = STATIONS[zone.Id] or DEFAULT_STATION
	buildHustleStation(zoneModel, zoneCF, zone, stationSpec)
	buildMechanicProp(zoneModel, zoneCF * (MECHANIC_PROP_CF[zone.Id] or CFrame.new(-6, 0, -6)), zone, stationSpec.counter)
	-- Themed clutter on the pad (keeps the gate -> counter walkway and the
	-- prompt / automation anchor clear; see ZoneDressing).
	ZoneDressing.build(zoneModel, zoneCF, zone)

	-- Entrance lamps on the sidewalk just in front of the pad, in the zone's
	-- own colors (pole = sign face 15% toward navy, base 35%), so every
	-- entrance is framed by a pair of lamps that point at its zone.
	local lampPole = signFace:Lerp(NAVY, 0.15)
	local lampBase = signFace:Lerp(NAVY, 0.35)
	for _, xOff in { -16, 16 } do
		local lamp = makeModel("EntranceLamp", zoneModel)
		buildLampPost(lamp, groundCF * CFrame.new(xOff, ROAD_TOP, -35), lampPole, lampBase)
	end

	if zone.UnlockLevel > 1 then
		buildGate(zoneModel, zoneCF, zone)
	end
end

----------------------------------------------------------------------
-- Decor: road-side signposts (the city lives in CityBuilder)
----------------------------------------------------------------------

-- Small signpost (warm brown post): a board in the zone's signature color with the zone
-- name in white and a diamond arrow tip on the board's +X end.
local function buildSignpost(parent: Instance, cf: CFrame, text: string, color: Color3)
	makeBlock({
		name = "SignpostPole", parent = parent, size = Vector3.new(0.5, 5.2, 0.5),
		cframe = cf * CFrame.new(0, 2.6, 0), color = MapKit.TRUNK, -- warm brown, never near-black at eye level
	})
	local board = makeBlock({
		name = "SignpostBoard", parent = parent, size = Vector3.new(6, 1.5, 0.35),
		cframe = cf * CFrame.new(1.2, 4.6, 0), color = color, canCollide = false,
	})
	addSurfaceText(board, text, Enum.Font.FredokaOne, WHITE, Enum.NormalId.Front, nil, color)
	makeBlock({
		name = "SignpostTip", parent = parent, size = Vector3.new(1.06, 1.06, 0.35),
		cframe = cf * CFrame.new(4.2, 4.6, 0) * CFrame.Angles(0, 0, math.rad(45)), color = color, canCollide = false,
	})
end

local function buildDecor(parent: Instance)
	-- (No beach palms: at r 347-350 they stood behind the 64-185-stud outer
	-- ring where no player ever saw them; their parts paid for city life.)
	-- Road-side signposts (CityLayout.signposts): a few degrees past each
	-- zone, board facing the plaza, arrow tip swung back toward the zone's pad.
	for _, post in CityLayout.signposts do
		local zone = GameConfig.getZone(post.zoneId)
		if zone then
			buildSignpost(parent, post.cframe, zone.Name, zoneSignFace(zone))
		end
	end
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

function MapBuilder.build(): ()
	if Workspace:FindFirstChild("SideHustleMap") then
		return
	end

	setupLighting()

	local okTerrain, terrainErr = pcall(buildTerrain)
	if not okTerrain then
		warn("[MapBuilder] Terrain generation failed: " .. tostring(terrainErr))
	end
	local okStyle, styleErr = pcall(styleTerrain)
	if not okStyle then
		warn("[MapBuilder] Terrain styling failed: " .. tostring(styleErr))
	end

	local map = Instance.new("Folder")
	map.Name = "SideHustleMap"

	local ground = buildGround(map, okTerrain)
	buildPlaza(map)

	local zonesFolder = Instance.new("Folder")
	zonesFolder.Name = "Zones"
	zonesFolder.Parent = map

	for _, zone in GameConfig.Zones do
		buildZone(zonesFolder, zone)
	end

	buildDecor(ground)

	-- The downtown: street markings + traffic lights, skyline, storefronts,
	-- zone anchor buildings, street furniture and plaza buzz.
	CityBuilder.build(map)

	map.Parent = Workspace
end

return MapBuilder
