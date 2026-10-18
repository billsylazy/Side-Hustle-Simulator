--!nonstrict
-- CityBuilder: the cartoon downtown around the plaza, built from primitives
-- and laid out ENTIRELY by Shared/CityLayout (the client city-life system
-- walks and drives on the same data).
--
--   SideHustleMap.City (Model)
--     Street     curbs, PAINTED lane dashes (yellow center + white dividers on
--                8 invisible MarkingDeck<k> decks, a SurfaceGui frame per dash),
--                zebra crosswalks on every zone axis, TrafficLight models (ZoneId
--                attr, cobalt mast, yellow head, Neon SignalRed / SignalAmber /
--                SignalGreen), Back Avenue dashes (8 BackMarkingDeck<k>)
--     Skyline    48 chunky pastel buildings in two rings (r 220..244, 277..307):
--                mid-ring fronts carry part window bands + vertical neon-edged
--                blade signs, their backs a giant painted Mural over a Back
--                Avenue shopfront; every outer-ring front carries a shopfront and
--                PAINTED window bands (fronts + sides; mid-ring sides too); two
--                outer roofs carry slewing tower cranes (CitySpin); six outer
--                slots are landmark hero towers (Stepped / Round / Billboard)
--                + 24 rowhouse infills closing the mid-ring gaps
--     Shops      16 storefronts in the gaps between zones (awnings, accent name
--                boards, warm-lit windows, flower boxes, 20 x 8.5 rooftop
--                billboards never in a neighbouring zone's hue)
--     Anchors    one landmark per zone right behind its pad, in the zone's
--                signature color with a giant 40 x 11.5 rooftop name sign (the
--                largest board in its sector; white neon marquee) + a giant icon
--                Model that spins (CitySpin)
--     Furniture  street trees in planters, 24 tall lamps with zone-colored
--                festival banners, hydrants, trash cans, news boxes, bus stops
--                (outer sidewalk furniture strip, r 105..112)
--     GapBlocks  café terraces (checkered CafeTerrace rug, tables, stools) in
--                front of every Shop A + street trees beside both shops of every gap
--     Parks      pocket-park lawns behind the shops
--     BackPockets trees in planters + lamp posts behind the rowhouses
--     PlazaBuzz  food carts, balloon vendor, colored plaza inlay + sunburst,
--                raised round flower planters
--
-- Street hardware is toy-city cobalt (MapKit.STREET_POLE / STREET_BASE), never
-- gunmetal or near-black. Rules: buildings / bodies / poles collide; every small decor part is
-- CanCollide false + CastShadow false. Nothing here enters a zone pad, the
-- zone-axis walkway corridor (|zone-local x| < 10 from the plaza to the gate)
-- or the spawn (tools/check_map.luau audits all three). Every Block sign
-- board gets an unlit Face frame in its own color (MapKit.addSurfaceText
-- faceColor). Faces seen only from >= 150 studs are painted (MapKit.paintBands
-- / murals / marking decks: zero parts). ~3,250 parts.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local CityLayout = require(ReplicatedStorage.Shared.CityLayout)
local MapKit = require(script.Parent.MapKit)

local makeBlock = MapKit.makeBlock
local makeBall = MapKit.makeBall
local makeCylinder = MapKit.makeCylinder
local makeWedge = MapKit.makeWedge
local makeModel = MapKit.makeModel
local addSurfaceText = MapKit.addSurfaceText
local addPointLight = MapKit.addPointLight

local CityBuilder = {}

local S = CityLayout.Street
local ringPos = CityLayout.ringPos
local facingCFrame = CityLayout.facingCFrame
local RAD_90 = MapKit.RAD_90

----------------------------------------------------------------------
-- Palette
----------------------------------------------------------------------

local NAVY = MapKit.NAVY
local WHITE = MapKit.WHITE
local NEON_WHITE = MapKit.NEON_WHITE -- marquee frames around signature-colored boards
local FLOWER_COLORS = MapKit.FLOWER_COLORS
local zoneSignFace = MapKit.zoneSignFace
local SIDEWALK = Color3.fromRGB(236, 226, 208)
local CORNICE = Color3.fromRGB(248, 248, 244)
local PLINTH_DARK = Color3.fromRGB(40, 40, 70)
-- Street hardware (signal masts, lamp poles, legs, posts): toy-city cobalt,
-- foot plates a deeper cobalt; never gunmetal / near-black (art guide).
local POLE = MapKit.STREET_POLE
local POLE_BASE = MapKit.STREET_BASE
local SIGNAL_YELLOW = Color3.fromRGB(255, 200, 40) -- cartoon traffic-light housing
local WINDOW_BLUE = Color3.fromRGB(160, 220, 255)
local WINDOW_WARM = Color3.fromRGB(255, 236, 170)
local GLASS_BLUE = Color3.fromRGB(170, 225, 255)
local LAMP_GLOBE = Color3.fromRGB(255, 236, 180)

-- Soft pastels for buildings (the zones keep the saturated signature colors).
local PASTELS = {
	Color3.fromRGB(255, 150, 135), -- coral
	Color3.fromRGB(255, 190, 130), -- peach
	Color3.fromRGB(255, 228, 140), -- butter
	Color3.fromRGB(150, 226, 190), -- mint
	Color3.fromRGB(120, 206, 214), -- teal
	Color3.fromRGB(140, 192, 255), -- sky
	Color3.fromRGB(170, 170, 255), -- periwinkle
	Color3.fromRGB(206, 172, 255), -- lavender
	Color3.fromRGB(255, 170, 210), -- bubblegum
	Color3.fromRGB(196, 236, 120), -- lime (was cream: cream read khaki in shade)
}

-- Saturated accents (awnings, neon signs, billboards).
local ACCENTS = {
	Color3.fromRGB(255, 90, 90),
	Color3.fromRGB(255, 170, 40),
	Color3.fromRGB(60, 200, 255),
	Color3.fromRGB(255, 110, 190),
	Color3.fromRGB(120, 220, 90),
	Color3.fromRGB(170, 110, 255),
}

local ROOF_SIGNS = { "HUSTLE", "CASH CO", "BIG BANK", "PIZZA", "HOTEL", "24/7" }

-- Shop B rooftop billboard per gap: chosen so no billboard shares a hue with
-- either neighbouring zone (gap k sits between zone k and zone k + 1), so a
-- zone's own rooftop board is the only one in its color in its sector.
local SHOP_B_BILLBOARD = {
	Color3.fromRGB(170, 110, 255), -- gap 1: Lemonade | Dog
	Color3.fromRGB(255, 170, 40), -- gap 2: Dog | Sneaker
	Color3.fromRGB(255, 110, 190), -- gap 3: Sneaker | Car Wash
	Color3.fromRGB(120, 220, 90), -- gap 4: Car Wash | Food Truck
	Color3.fromRGB(60, 200, 255), -- gap 5: Food Truck | Creator
	Color3.fromRGB(255, 90, 90), -- gap 6: Creator | Stock
	Color3.fromRGB(255, 170, 40), -- gap 7: Stock | Startup
	Color3.fromRGB(255, 110, 190), -- gap 8: Startup | Lemonade
}

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

-- Small decor: never collides, never casts a shadow (unless told otherwise).
local function deco(props)
	if props.canCollide == nil then
		props.canCollide = false
	end
	if props.castShadow == nil then
		props.castShadow = false
	end
	return props
end

local function decoBlock(props)
	return makeBlock(deco(props))
end
local function decoBall(props)
	return makeBall(deco(props))
end
local function decoCylinder(props)
	return makeCylinder(deco(props))
end
local function decoWedge(props)
	return makeWedge(deco(props))
end

-- Neon accent for a zone: AccentColor, unless it is too dark to glow.
local function neonAccent(zone: GameConfig.ZoneDef): Color3
	local c = zone.AccentColor
	local luminance = 0.299 * c.R + 0.587 * c.G + 0.114 * c.B
	return if luminance < 0.25 then zone.SignColor else c
end

-- Four neon bars framing a board of size (w, h) centered at `cf` (board
-- plane = local XY, the frame sits flush with it, `depth` deep).
local function neonFrame(parent: Instance, cf: CFrame, w: number, h: number, depth: number, color: Color3, bar: number)
	for _, y in { -(h + bar) / 2, (h + bar) / 2 } do
		decoBlock({
			name = "NeonFrame", parent = parent, size = Vector3.new(w + bar * 2, bar, depth),
			cframe = cf * CFrame.new(0, y, 0), color = color, material = Enum.Material.Neon,
		})
	end
	for _, x in { -(w + bar) / 2, (w + bar) / 2 } do
		decoBlock({
			name = "NeonFrame", parent = parent, size = Vector3.new(bar, h, depth),
			cframe = cf * CFrame.new(x, 0, 0), color = color, material = Enum.Material.Neon,
		})
	end
end

-- Window bands on the plaza face (local -Z face) of a W x H x D box whose
-- ground center is `cf`: one band every `spacing` studs from `y0`, the top
-- band clear of the cornice. Returns the band heights used.
local function bandHeights(height: number, y0: number, maxBands: number): { number }
	local usable = height - y0 - 4
	if usable < 0 then
		return {}
	end
	local count = math.floor(usable / 9) + 1
	local spacing = 9
	if count > maxBands then
		count = maxBands
		spacing = usable / (maxBands - 1)
	end
	local ys = {}
	for i = 0, count - 1 do
		table.insert(ys, y0 + i * spacing)
	end
	return ys
end

-- Colored roof cap inside the white cornice so the city reads as candy
-- colors from above too (not a sea of white roofs).
local ROOF_TINT = Color3.fromRGB(80, 80, 112)
local function roofCap(parent: Instance, cf: CFrame, w: number, d: number, topOfCornice: number, body: Color3)
	decoBlock({
		name = "RoofCap", parent = parent, size = Vector3.new(w - 0.6, 0.2, d - 0.6),
		cframe = cf * CFrame.new(0, topOfCornice + 0.1, 0), color = body:Lerp(ROOF_TINT, 0.3),
	})
end

----------------------------------------------------------------------
-- Street details: curbs, markings, crosswalks, traffic lights
----------------------------------------------------------------------

local function buildCurbRing(parent: Instance, radius: number, segments: number, length: number, topY: number)
	for i = 0, segments - 1 do
		decoBlock({
			name = "Curb", parent = parent, size = Vector3.new(length, S.CurbHeight, S.CurbWidth),
			cframe = facingCFrame(radius, i * 360 / segments, topY + S.CurbHeight / 2),
			color = Color3.fromRGB(250, 250, 245),
		})
	end
end

local DASH_COLORS = {
	Center = Color3.fromRGB(255, 214, 50),
	Lane = Color3.fromRGB(250, 250, 250),
	Back = Color3.fromRGB(255, 214, 50),
}

-- PAINTED lane dashes: one invisible flat deck per gap octant
-- (CityLayout.markingDecks / backMarkingDecks) whose lit SurfaceGui
-- "Markings" holds one Frame per dash (same size, color, center and tangent
-- as the old 0.1-thick dash parts), so the markings shade like the asphalt
-- and cost 1 part per octant instead of 15 (ring) / 9 (Back Avenue).
local function buildMarkingDecks(parent: Instance, decks)
	for _, deck in decks do
		local _, gui = MapKit.makeGroundDeck(parent, deck.name, deck.cframe, deck.width, deck.depth, deck.pixelsPerStud, "Markings", 1, 1)
		-- scale (float) positions and sizes: UDim offsets are whole pixels
		local pps = deck.pixelsPerStud
		local gw, gh = deck.width * pps, deck.depth * pps
		for _, dash in deck.dashes do
			local px, py = MapKit.deckPixel(deck.cframe, deck.width, deck.depth, pps, dash.cframe.Position)
			MapKit.makeGuiFrame({
				name = "Dash", parent = gui, anchor = Vector2.new(0.5, 0.5),
				position = UDim2.fromScale(px / gw, py / gh),
				size = UDim2.fromScale(dash.length / deck.width, dash.width / deck.depth),
				rotation = MapKit.deckRotation(deck.cframe, dash.cframe.RightVector),
				color = DASH_COLORS[dash.kind] or WHITE,
			})
		end
	end
end

local function buildMarkings(parent: Instance)
	-- Painted dashes (no dash comes within 9 degrees of a zone axis: the
	-- crosswalks live there), then the zebra crosswalks on every zone axis.
	buildMarkingDecks(parent, CityLayout.markingDecks)
	local markingY = S.MarkingTop - 0.05
	for _, cw in CityLayout.crosswalks do
		for j = 0, S.CrosswalkBars - 1 do
			decoBlock({
				name = "CrosswalkBar", parent = parent,
				size = Vector3.new(S.CrosswalkWidth, 0.1, S.CrosswalkBarDepth),
				cframe = facingCFrame(S.CrosswalkFirstRadius + S.CrosswalkStep * j, cw.angle, markingY),
				color = Color3.fromRGB(250, 250, 250),
			})
		end
	end
end

-- Mast-arm traffic light: cobalt pole on the outer sidewalk, arm reaching
-- over the outer lanes toward the plaza, a cartoon-yellow head with red /
-- amber / green Neon lamps on both tangential faces (traffic runs both ways
-- past it; dimmed lenses read as dark discs on the yellow housing).
local function buildTrafficLight(parent: Instance, spec)
	local model = makeModel("TrafficLight", parent)
	model:SetAttribute("ZoneId", spec.zoneId)
	local cf = spec.cframe -- pole base on the sidewalk, -Z toward the plaza
	decoCylinder({
		name = "SignalBase", parent = model, diameter = 1.8, height = 0.6,
		cframe = cf * CFrame.new(0, 0.3, 0), color = POLE_BASE,
	})
	makeCylinder({
		name = "SignalPole", parent = model, diameter = 0.9, height = 16,
		cframe = cf * CFrame.new(0, 8, 0), color = POLE, castShadow = false,
	})
	decoBlock({
		name = "SignalArm", parent = model, size = Vector3.new(0.6, 0.6, 10),
		cframe = cf * CFrame.new(0, 15, -5), color = POLE,
	})
	local headCF = cf * CFrame.new(0, 12.2, -10)
	decoBlock({
		name = "SignalHead", parent = model, size = Vector3.new(1.8, 5, 1.8),
		cframe = headCF, color = SIGNAL_YELLOW,
	})
	decoBlock({
		name = "SignalHanger", parent = model, size = Vector3.new(0.4, 0.6, 0.4),
		cframe = headCF * CFrame.new(0, 2.8, 0), color = POLE,
	})
	local lamps = {
		{ name = "SignalRed", y = 1.55, color = Color3.fromRGB(255, 70, 70) },
		{ name = "SignalAmber", y = 0, color = Color3.fromRGB(255, 200, 40) },
		{ name = "SignalGreen", y = -1.55, color = Color3.fromRGB(80, 230, 120) },
	}
	for _, side in { -0.95, 0.95 } do
		for _, lamp in lamps do
			decoBall({
				name = lamp.name, parent = model, diameter = 1.2,
				cframe = headCF * CFrame.new(side, lamp.y, 0), color = lamp.color, material = Enum.Material.Neon,
			})
		end
	end
end

local function buildStreet(city: Instance)
	local street = makeModel("Street", city)
	-- Curbs on both asphalt edges (outer on the outer sidewalk, inner on the
	-- inner sidewalk).
	buildCurbRing(street, S.RoadCurbRadius, 48, 13.6, S.OuterSidewalkTop)
	buildCurbRing(street, S.InnerCurbRadius, 32, 12.8, S.InnerSidewalkTop)
	buildMarkings(street)
	-- Back Avenue (between the skyline rings): painted yellow center dashes
	-- every 5 degrees (the asphalt + white edge rings are MapBuilder's discs)
	buildMarkingDecks(street, CityLayout.backMarkingDecks)
	for _, spec in CityLayout.trafficLights do
		buildTrafficLight(street, spec)
	end
end

----------------------------------------------------------------------
-- Skyline: chunky pastel toy buildings, every one facing the plaza
----------------------------------------------------------------------

local function buildRoofProp(model: Instance, cf: CFrame, spec, variant: number, accent: Color3, pastel: Color3)
	local W, H, D = spec.width, spec.height, spec.depth
	local roofY = H + 1
	if variant == 0 then
		-- Setback penthouse + antenna with a red neon tip
		local setH = math.floor(0.3 * H)
		decoBlock({
			name = "Setback", parent = model, size = Vector3.new(0.65 * W, setH, 0.65 * D),
			cframe = cf * CFrame.new(0, roofY + setH / 2, 1), color = pastel:Lerp(WHITE, 0.25), castShadow = true,
		})
		decoCylinder({
			name = "Antenna", parent = model, diameter = 0.6, height = 10,
			cframe = cf * CFrame.new(0, roofY + setH + 5, 1), color = Color3.fromRGB(200, 204, 220),
		})
		decoBall({
			name = "AntennaTip", parent = model, diameter = 1.4,
			cframe = cf * CFrame.new(0, roofY + setH + 10.3, 1), color = Color3.fromRGB(255, 70, 70),
			material = Enum.Material.Neon,
		})
	elseif variant == 1 then
		-- Cartoon water tower on four legs
		local base = cf * CFrame.new(W * 0.2, roofY, D * 0.12)
		for _, off in { Vector3.new(-2.6, 0, -2.6), Vector3.new(2.6, 0, -2.6), Vector3.new(-2.6, 0, 2.6), Vector3.new(2.6, 0, 2.6) } do
			decoBlock({
				name = "TowerLeg", parent = model, size = Vector3.new(0.6, 4, 0.6),
				cframe = base * CFrame.new(off.X, 2, off.Z), color = Color3.fromRGB(90, 96, 130),
			})
		end
		decoCylinder({
			name = "WaterTank", parent = model, diameter = 8, height = 7,
			cframe = base * CFrame.new(0, 7.5, 0), color = Color3.fromRGB(255, 120, 100), castShadow = true,
		})
		decoBall({
			name = "WaterTankCap", parent = model, diameter = 8,
			cframe = base * CFrame.new(0, 11, 0), color = Color3.fromRGB(230, 80, 80),
		})
	elseif variant == 2 then
		-- Rooftop neon sign facing the plaza
		local signCF = cf * CFrame.new(0, roofY + 4.3, -D / 2 + 2)
		for _, x in { -7, 7 } do
			decoBlock({
				name = "RoofSignLeg", parent = model, size = Vector3.new(0.8, 2, 0.8),
				cframe = cf * CFrame.new(x, roofY + 1, -D / 2 + 2), color = POLE,
			})
		end
		local board = decoBlock({
			name = "RoofSign", parent = model, size = Vector3.new(20, 5, 1),
			cframe = signCF, color = WHITE,
		})
		addSurfaceText(board, ROOF_SIGNS[math.floor(spec.index / 4) % #ROOF_SIGNS + 1], Enum.Font.LuckiestGuy, accent, Enum.NormalId.Front, 20, WHITE)
		decoBlock({
			name = "RoofSignNeon", parent = model, size = Vector3.new(20.4, 0.5, 0.4),
			cframe = signCF * CFrame.new(0, -2.75, -0.4), color = accent, material = Enum.Material.Neon,
		})
	else
		-- Big candy dome + neon finial
		local d = 0.45 * W
		decoBall({
			name = "RoofDome", parent = model, diameter = d,
			cframe = cf * CFrame.new(0, roofY - 0.5, 0), color = pastel, castShadow = true,
		})
		decoBall({
			name = "DomeFinial", parent = model, diameter = 1.6,
			cframe = cf * CFrame.new(0, roofY - 0.5 + d / 2 + 0.5, 0), color = accent, material = Enum.Material.Neon,
		})
	end
end

-- Vertical blade signs on the mid-ring street wall (one per MidBuilding<k>,
-- in ring order): one letter per line on both faces.
local BLADE_WORDS = {
	"CAFE", "TOYS", "GYM", "DINER", "BOOKS", "PETS", "DONUT", "SHOES", "GAMES", "MUSIC", "CANDY", "PIZZA",
	"TACO", "BAKE", "ART", "SPA", "BOBA", "DELI", "SURF", "FILM", "JUICE", "TECH", "ARCADE", "HOTEL",
}

-- Blade sign perpendicular to the plaza face of a mid-ring building: a 1 x
-- 14 x 4.5 accent board (y 12..26, clear of the awning <= 9.2 and the corner
-- pillars) standing out from the wall at building-local x, white LuckiestGuy
-- letters on both (unlit) faces, a white neon strip on its outer edge.
local function buildBladeSign(model: Instance, cf: CFrame, spec)
	local W, D, k = spec.width, spec.depth, spec.index
	local side = if k % 2 == 0 then 1 else -1
	local color = ACCENTS[(k % #ACCENTS) + 1]
	local word = BLADE_WORDS[k % #BLADE_WORDS + 1]
	local x = side * (W / 2 - 4)
	local blade = decoBlock({
		name = "BladeSign", parent = model, size = Vector3.new(1, 14, 4.5),
		cframe = cf * CFrame.new(x, 19, -D / 2 - 0.05 - 2.25), color = color,
	})
	local letters = {}
	for i = 1, #word do
		table.insert(letters, string.sub(word, i, i))
	end
	local text = table.concat(letters, "\n")
	for _, face in { Enum.NormalId.Left, Enum.NormalId.Right } do
		addSurfaceText(blade, text, Enum.Font.LuckiestGuy, WHITE, face, 20, color)
	end
	decoBlock({
		name = "BladeSignNeon", parent = model, size = Vector3.new(0.4, 14.4, 0.4),
		cframe = cf * CFrame.new(x, 19, -D / 2 - 0.05 - 4.5 - 0.2), color = NEON_WHITE, material = Enum.Material.Neon,
	})
end

-- Ground-floor shopfront on an outer-ring building's plaza face (the face
-- that lines the Back Avenue, r ~277): accent awning, door, warm display
-- window. `front` = local z of the face the door + window stand on (the
-- plinth face). Awning bottom 8.0, door / window in front of the plinth:
-- the BackOuter sidewalk loop (r 273.4 +- 1.45) stays clear below 4.9.
local function buildOuterShopfront(model: Instance, cf: CFrame, W: number, D: number, front: number, accent: Color3)
	decoWedge({
		name = "Awning", parent = model, size = Vector3.new(W - 6, 1.2, 3),
		cframe = cf * CFrame.new(0, 8.6, -D / 2 - 2), color = accent,
	})
	decoBlock({
		name = "Door", parent = model, size = Vector3.new(5, 6.5, 0.4),
		cframe = cf * CFrame.new(W / 4, 3.25, front - 0.2), color = accent:Lerp(NAVY, 0.35),
	})
	decoBlock({
		name = "DisplayWindow", parent = model, size = Vector3.new(W / 2 - 5, 4, 0.3),
		cframe = cf * CFrame.new(-(W / 4 + 1), 4, front - 0.15), color = WINDOW_WARM,
	})
end

-- Giant painted wall ad (zero parts) on a mid-ring building's back face, the
-- inner wall of the Back Avenue: SurfaceGui "Mural" (5 px/stud, LightInfluence
-- 0.4, Brightness 1.4) with an accent Panel from x 3 .. W-3 and y 11 (over the
-- BackAwning / BackDoor) .. H-3, three soft circles + a diagonal stripe
-- clipped to it and a two-line LuckiestGuy slogan. The panel color is two
-- steps along the accent wheel from the building's blade sign and awning.
local MURAL_SLOGANS = {
	"DREAM\nBIG", "HUSTLE\nHARD", "BOSS\nMODE", "LEVEL\nUP!", "CASH\nFLOW", "GO GET\nIT!",
	"BIG\nMONEY", "TO THE\nMOON", "STAY\nHUNGRY", "SIDE\nHUSTLE", "GRIND\nTIME", "YOU GOT\nTHIS",
}
local MURAL_PPS = 5
local BUTTER = Color3.fromRGB(255, 228, 140)
local SKY = Color3.fromRGB(140, 192, 255)
local function buildMural(body: BasePart, spec)
	local W, H, k = spec.width, spec.height, spec.index
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Mural"
	gui.Face = Enum.NormalId.Back
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = MURAL_PPS
	gui.LightInfluence = 0.4
	gui.Brightness = 1.4
	gui.ClipsDescendants = true
	gui.Parent = body
	local x0, x1, y0, y1 = 3, W - 3, 11, H - 3
	local pw, ph = x1 - x0, y1 - y0
	local panel = MapKit.makeGuiFrame({
		name = "Panel", parent = gui,
		position = UDim2.fromScale(x0 / W, (H - y1) / H), size = UDim2.fromScale(pw / W, ph / H),
		color = ACCENTS[((k + 2) % #ACCENTS) + 1], corner = 0.06, zIndex = 1, clips = true,
	})
	-- circles: diameter d * ph (square in studs), centers in panel scale
	local function circle(name: string, d: number, cx: number, cy: number, color: Color3, transparency: number)
		MapKit.makeGuiFrame({
			name = name, parent = panel, anchor = Vector2.new(0.5, 0.5),
			position = UDim2.fromScale(cx, cy), size = UDim2.fromScale(d * ph / pw, d),
			color = color, transparency = transparency, corner = 0.5, zIndex = 2,
		})
	end
	circle("BigDot", 0.6, 0, 0, WHITE, 0.75)
	circle("ButterDot", 0.32, 1 - 0.14 * ph / pw, 0.86, BUTTER, 0.3)
	circle("SkyDot", 0.16, 1 - 0.2 * ph / pw, 0.17, SKY, 0.1)
	MapKit.makeGuiFrame({
		name = "Stripe", parent = panel, anchor = Vector2.new(0.5, 0.5),
		position = UDim2.fromScale(0.5, 0.5), size = UDim2.fromScale(0.96, 0.08),
		color = WHITE, transparency = 0.8, rotation = 18, zIndex = 3,
	})
	local label = MapKit.makeTextLabel(
		panel, MURAL_SLOGANS[k % #MURAL_SLOGANS + 1], Enum.Font.LuckiestGuy, WHITE,
		UDim2.fromScale(0.08, 0.22), UDim2.fromScale(0.84, 0.56)
	)
	label.ZIndex = 4
	-- chunky navy sticker outline sized to the two text lines (4..6 px)
	local stroke = label:FindFirstChildOfClass("UIStroke")
	if stroke then
		local linePx = ph * MURAL_PPS * 0.56 / 2
		stroke.Thickness = math.clamp(math.floor(0.14 * linePx + 0.5), 4, 6)
	end
	return gui
end

-- Slewing yellow tower crane on an outer-ring roof (CityLayout.TowerCranes /
-- CityLayout.Crane): a static mast with white collars from the roof to
-- C.mastTop (y 136), and a Model "CraneTop" (attribute CitySpin, WorldPivot
-- on the mast axis at C.pivotY) that the client city-life sim turns: slew
-- ring, cab, 50-long jib (crane-local x -12 .. +38, y 141.5..144.1), apex +
-- tie bars (to y 153.1), counterweight, trolley + hook line at x C.trolleyX,
-- a two-plank load (down to y 125.8) and a red neon jib-tip light. Low enough
-- that the jib shows in the spawn view over the Lemonade axis; the load
-- hangs >= 18 studs (radially) off the blimp path. Crane-local +X (the jib)
-- starts tangential (building-local +X) so it reads as a long line from the
-- plaza. Everything is Anchored, CanCollide false, CastShadow false.
local CRANE_YELLOW = Color3.fromRGB(255, 196, 40)
local CRANE_SLATE = Color3.fromRGB(64, 70, 120)
local CRANE_WHITE = Color3.fromRGB(248, 248, 244)
local function buildCrane(model: Instance, cf: CFrame, spec, crane)
	local roofTop = spec.height + 1
	local C = CityLayout.Crane
	local base = cf * CFrame.new(0, 0, C.mastZ)
	local y0 = C.mastTop
	local mastH = y0 - roofTop
	decoBlock({
		name = "CraneMast", parent = model, size = Vector3.new(4, mastH, 4),
		cframe = base * CFrame.new(0, roofTop + mastH / 2, 0), color = CRANE_YELLOW,
	})
	for i = 1, 3 do
		decoBlock({
			name = "CraneCollar", parent = model, size = Vector3.new(4.4, 0.8, 4.4),
			cframe = base * CFrame.new(0, roofTop + mastH * i / 4, 0), color = CRANE_WHITE,
		})
	end
	local top = makeModel("CraneTop", model)
	local function at(x: number, dy: number): CFrame
		return base * CFrame.new(x, y0 + dy, 0)
	end
	local tx = C.trolleyX
	decoCylinder({ name = "SlewRing", parent = top, diameter = 6, height = 1, cframe = at(0, 0.5), color = CRANE_SLATE })
	decoBlock({ name = "CraneCab", parent = top, size = Vector3.new(5, 4.5, 5), cframe = at(3, 3.25), color = CRANE_WHITE })
	decoBlock({ name = "CabWindow", parent = top, size = Vector3.new(0.3, 1.8, 4), cframe = at(5.65, 3.7), color = Color3.fromRGB(90, 200, 255) })
	decoBlock({ name = "CraneJib", parent = top, size = Vector3.new(50, 2.6, 2.6), cframe = at(13, 6.8), color = CRANE_YELLOW })
	decoBlock({ name = "CraneApex", parent = top, size = Vector3.new(2.2, 9, 2.2), cframe = at(0, 12.6), color = CRANE_YELLOW })
	local apex = Vector3.new(0, 17.1, 0)
	for _, tipX in { 38, -12 } do
		local tip = Vector3.new(tipX, 8.1, 0)
		local delta = tip - apex
		local mid = (apex + tip) / 2
		decoBlock({
			name = "CraneTie", parent = top, size = Vector3.new(0.35, 0.35, delta.Magnitude),
			cframe = at(mid.X, mid.Y) * CFrame.Angles(0, if tipX > 0 then RAD_90 else -RAD_90, 0)
				* CFrame.Angles(math.atan2(-delta.Y, math.abs(delta.X)), 0, 0),
			color = CRANE_WHITE,
		})
	end
	decoBlock({ name = "Counterweight", parent = top, size = Vector3.new(6, 5, 4.6), cframe = at(-9, 4.5), color = Color3.fromRGB(120, 128, 160) })
	decoBlock({ name = "CraneTrolley", parent = top, size = Vector3.new(3, 1.2, 3), cframe = at(tx, 4.9), color = CRANE_SLATE })
	decoBlock({ name = "HookLine", parent = top, size = Vector3.new(0.3, 12, 0.3), cframe = at(tx, -1.7), color = CRANE_SLATE })
	decoBlock({ name = "CraneLoad", parent = top, size = Vector3.new(7, 1.2, 2.4), cframe = at(tx, -8.4), color = Color3.fromRGB(255, 150, 40) })
	decoBlock({ name = "CraneLoad", parent = top, size = Vector3.new(7, 1.2, 2.4), cframe = at(tx, -9.6), color = Color3.fromRGB(90, 200, 255) })
	decoBall({
		name = "JibTipLight", parent = top, diameter = 1, cframe = at(38, 8.6),
		color = Color3.fromRGB(255, 60, 60), material = Enum.Material.Neon,
	})
	top.WorldPivot = base * CFrame.new(0, C.pivotY, 0)
	top:SetAttribute("CitySpin", crane.rate)
end

----------------------------------------------------------------------
-- Landmark hero towers (CityLayout.HeroTowers: six outer-ring slots)
----------------------------------------------------------------------

local HERO_STYLE = {
	[2] = { body = Color3.fromRGB(170, 170, 255), accent = Color3.fromRGB(255, 110, 190) }, -- periwinkle / hot pink
	[14] = { body = Color3.fromRGB(150, 226, 190), accent = Color3.fromRGB(255, 214, 50) }, -- mint / yellow
	[7] = { body = Color3.fromRGB(120, 206, 214), dome = Color3.fromRGB(255, 228, 140), accent = Color3.fromRGB(60, 200, 255) },
	[19] = { body = Color3.fromRGB(255, 150, 135), dome = Color3.fromRGB(206, 172, 255), accent = Color3.fromRGB(255, 214, 50) },
	[10] = { body = Color3.fromRGB(255, 170, 210), accent = Color3.fromRGB(255, 214, 50), text = "HUSTLE CITY" },
	[22] = { body = Color3.fromRGB(140, 192, 255), accent = Color3.fromRGB(255, 90, 170), text = "GO BIG!" },
}
local HERO_FALLBACK = { body = PASTELS[7], dome = PASTELS[3], accent = ACCENTS[4], text = "HUSTLE CITY" }
local SPIRE_RED = Color3.fromRGB(255, 70, 70)

-- "Stepped": three setback tiers (all collide) with white cornices, a neon
-- band under every cornice, blue window bands 5 / 3 / 2, a white spire with
-- a red neon ball on top (y 150 .. 185.25).
local function buildSteppedTower(model: Instance, cf: CFrame, style)
	local body = style.body
	decoBlock({
		name = "Plinth", parent = model, size = Vector3.new(37, 8, 29),
		cframe = cf * CFrame.new(0, 4, 0), color = body:Lerp(PLINTH_DARK, 0.18),
	})
	local tiers = {
		{ w = 36, h = 80, d = 28, y0 = 0, bands = 5, first = 14 },
		{ w = 28, h = 45, d = 22, y0 = 80, bands = 3, first = 88 },
		{ w = 20, h = 25, d = 16, y0 = 125, bands = 2, first = 133 },
	}
	for i, t in tiers do
		local top = t.y0 + t.h
		makeBlock({
			name = if i == 1 then "Body" else "BodyTier" .. i, parent = model, size = Vector3.new(t.w, t.h, t.d),
			cframe = cf * CFrame.new(0, t.y0 + t.h / 2, 0), color = if i == 2 then body:Lerp(WHITE, 0.15) else body,
		})
		decoBlock({
			name = "Cornice", parent = model, size = Vector3.new(t.w + 2, 1.6, t.d + 2),
			cframe = cf * CFrame.new(0, top + 0.2, 0), color = CORNICE,
		})
		decoBlock({
			name = "NeonBand", parent = model, size = Vector3.new(t.w + 1, 0.8, 0.6),
			cframe = cf * CFrame.new(0, top - 1.2, -t.d / 2 - 0.35), color = style.accent, material = Enum.Material.Neon,
		})
		local last = top - 6
		for b = 0, t.bands - 1 do
			local y = if t.bands > 1 then t.first + b * (last - t.first) / (t.bands - 1) else t.first
			decoBlock({
				name = "WindowBand", parent = model, size = Vector3.new(t.w - 6, 3.6, 0.6),
				cframe = cf * CFrame.new(0, y, -t.d / 2 - 0.25), color = WINDOW_BLUE,
			})
		end
	end
	decoCylinder({
		name = "Spire", parent = model, diameter = 2, height = 32,
		cframe = cf * CFrame.new(0, 150 + 16, 0), color = WHITE, castShadow = true,
	})
	decoBall({
		name = "SpireTip", parent = model, diameter = 3.5,
		cframe = cf * CFrame.new(0, 182 + 1.45, 0), color = SPIRE_RED, material = Enum.Material.Neon,
	})
	buildOuterShopfront(model, cf, 36, 28, -28 / 2 - 0.5, style.accent)
end

-- "Round": a 30-dia drum (the collider) on a 33-dia plinth, six blue window
-- rings, a neon ring under a big candy dome ("RoofDome") with a neon
-- "DomeFinial" (the client city-life sim floats a spinning coin over it) and
-- an antenna behind it. Door + display window sit tangent to the plinth.
local function buildRoundTower(model: Instance, cf: CFrame, style)
	local body = style.body
	decoCylinder({
		name = "Plinth", parent = model, diameter = 33, height = 8,
		cframe = cf * CFrame.new(0, 4, 0), color = body:Lerp(PLINTH_DARK, 0.18),
	})
	makeCylinder({
		name = "Body", parent = model, diameter = 30, height = 140,
		cframe = cf * CFrame.new(0, 70, 0), color = body,
	})
	for _, y in { 24, 44, 64, 84, 104, 124 } do
		decoCylinder({
			name = "WindowRing", parent = model, diameter = 30.8, height = 3.2,
			cframe = cf * CFrame.new(0, y, 0), color = WINDOW_BLUE,
		})
	end
	decoCylinder({
		name = "NeonRing", parent = model, diameter = 31.2, height = 1,
		cframe = cf * CFrame.new(0, 136, 0), color = style.accent, material = Enum.Material.Neon,
	})
	decoBall({
		name = "RoofDome", parent = model, diameter = 30,
		cframe = cf * CFrame.new(0, 140, 0), color = style.dome or body:Lerp(WHITE, 0.4), castShadow = true,
	})
	decoBall({
		name = "DomeFinial", parent = model, diameter = 1.6,
		cframe = cf * CFrame.new(0, 140 + 15 + 0.5, 0), color = style.accent, material = Enum.Material.Neon,
	})
	-- antenna on the back of the dome (dome surface at z +8 is y ~152.7),
	-- clear of the coin that spins over the finial
	decoCylinder({
		name = "Antenna", parent = model, diameter = 1.2, height = 22,
		cframe = cf * CFrame.new(0, 152 + 11, 8), color = Color3.fromRGB(200, 204, 220),
	})
	decoBall({
		name = "AntennaTip", parent = model, diameter = 1.6,
		cframe = cf * CFrame.new(0, 174.6, 8), color = SPIRE_RED, material = Enum.Material.Neon,
	})
	-- Shopfront tangent to the round plinth (r 16.5): door right of center,
	-- display window left, a small accent awning over each.
	local function tangent(degrees: number, radius: number, y: number): CFrame
		return cf * CFrame.Angles(0, math.rad(degrees), 0) * CFrame.new(0, y, -radius)
	end
	decoBlock({
		name = "Door", parent = model, size = Vector3.new(5, 6.5, 0.4),
		cframe = tangent(-18, 16.5 + 0.2, 3.25), color = style.accent:Lerp(NAVY, 0.35),
	})
	decoBlock({
		name = "DisplayWindow", parent = model, size = Vector3.new(7, 4, 0.3),
		cframe = tangent(22, 16.5 + 0.15, 4), color = WINDOW_WARM,
	})
	for _, degrees in { -18, 22 } do
		decoWedge({
			name = "Awning", parent = model, size = Vector3.new(8, 1.2, 3),
			cframe = tangent(degrees, 15 - 0.2 + 1.5, 8.6), color = style.accent,
		})
	end
end

-- "Billboard": a tall slab with corner pillars, eight window bands, a
-- stepped crown (accent / white / accent) and a giant unlit rooftop
-- billboard on two legs facing the plaza inside a white neon marquee.
local function buildBillboardTower(model: Instance, cf: CFrame, style)
	local W, H, D = 34, 130, 26
	local body = style.body
	makeBlock({
		name = "Body", parent = model, size = Vector3.new(W, H, D),
		cframe = cf * CFrame.new(0, H / 2, 0), color = body,
	})
	decoBlock({
		name = "Plinth", parent = model, size = Vector3.new(W + 1, 8, D + 1),
		cframe = cf * CFrame.new(0, 4, 0), color = body:Lerp(PLINTH_DARK, 0.18),
	})
	for _, x in { -W / 2, W / 2 } do
		decoCylinder({
			name = "Pillar", parent = model, diameter = 3, height = H,
			cframe = cf * CFrame.new(x, H / 2, -D / 2), color = body:Lerp(WHITE, 0.3),
		})
	end
	for _, y in bandHeights(H, 12, 8) do
		decoBlock({
			name = "WindowBand", parent = model, size = Vector3.new(W - 6, 3.6, 0.6),
			cframe = cf * CFrame.new(0, y, -D / 2 - 0.25), color = WINDOW_BLUE,
		})
	end
	decoBlock({
		name = "Cornice", parent = model, size = Vector3.new(W + 2, 1.6, D + 2),
		cframe = cf * CFrame.new(0, H + 0.2, 0), color = CORNICE,
	})
	local crown = { { 26, 20, style.accent }, { 18, 14, WHITE }, { 10, 8, style.accent } }
	for i, c in crown do
		decoBlock({
			name = "Crown", parent = model, size = Vector3.new(c[1], 5, c[2]),
			cframe = cf * CFrame.new(0, H + 1 + (i - 0.5) * 5, 3), color = c[3], castShadow = true,
		})
	end
	for _, x in { -10, 10 } do
		decoBlock({
			name = "BillboardLeg", parent = model, size = Vector3.new(1, 4.5, 1),
			cframe = cf * CFrame.new(x, H + 1 + 2.25, -10), color = POLE,
		})
	end
	local boardCF = cf * CFrame.new(0, H + 5.5 + 6, -10)
	local board = decoBlock({
		name = "Billboard", parent = model, size = Vector3.new(30, 12, 1.2),
		cframe = boardCF, color = style.accent, castShadow = true,
	})
	addSurfaceText(board, style.text or "HUSTLE CITY", Enum.Font.LuckiestGuy, WHITE, Enum.NormalId.Front, 16, style.accent)
	neonFrame(model, boardCF, 30, 12, 1.5, NEON_WHITE, 0.7)
	buildOuterShopfront(model, cf, W, D, -D / 2 - 0.5, style.accent)
end

local function buildHeroTower(parent: Instance, spec)
	local model = makeModel(spec.name, parent)
	local style = HERO_STYLE[spec.index] or HERO_FALLBACK
	if spec.hero == "Round" then
		buildRoundTower(model, spec.cframe, style)
	elseif spec.hero == "Billboard" then
		buildBillboardTower(model, spec.cframe, style)
	else
		buildSteppedTower(model, spec.cframe, style)
	end
end

local function buildSkylineBuilding(parent: Instance, spec)
	if spec.hero then
		buildHeroTower(parent, spec)
		return
	end
	local W, H, D = spec.width, spec.height, spec.depth
	local k = spec.index
	local isMid = spec.ring == "Mid"
	local body = if isMid then PASTELS[(k * 3) % #PASTELS + 1] else PASTELS[(k * 7 + 5) % #PASTELS + 1]
	local pastelAlt = PASTELS[(k * 3 + 4) % #PASTELS + 1]
	local accent = ACCENTS[(k + (if isMid then 0 else 3)) % #ACCENTS + 1]
	local windowColor = if k % 3 == 2 then WINDOW_WARM else WINDOW_BLUE
	local cf = spec.cframe
	local model = makeModel(spec.name, parent)

	-- (1) body: the only collider
	local bodyPart = makeBlock({
		name = "Body", parent = model, size = Vector3.new(W, H, D),
		cframe = cf * CFrame.new(0, H / 2, 0), color = body,
	})
	-- (2) plinth (a light tint: dark plinths read as grime under pastels)
	decoBlock({
		name = "Plinth", parent = model, size = Vector3.new(W + 1, 8, D + 1),
		cframe = cf * CFrame.new(0, 4, 0), color = body:Lerp(PLINTH_DARK, 0.18),
	})
	-- (3) rounded front-corner pillars (the chunky toy look)
	for _, x in { -W / 2, W / 2 } do
		decoCylinder({
			name = "Pillar", parent = model, diameter = 3, height = H,
			cframe = cf * CFrame.new(x, H / 2, -D / 2), color = body:Lerp(WHITE, 0.3),
		})
	end
	-- (4) window bands on the plaza face + (5) mullions -> a window grid.
	-- Mid ring (seen up close from the street): chunky 0.6-stud part bands
	-- and part mullions. Outer ring (seen only from >= 150 studs, mostly over
	-- the mid ring): the same bands, sills and mullions PAINTED on the body
	-- (MapKit.paintBands, zero parts).
	local bands = bandHeights(H, 12, 8)
	if isMid then
		for _, y in bands do
			decoBlock({
				name = "WindowBand", parent = model, size = Vector3.new(W - 6, 3.6, 0.6),
				cframe = cf * CFrame.new(0, y, -D / 2 - 0.25), color = windowColor,
			})
		end
		if #bands > 0 then
			local top = bands[#bands] + 2.6
			local bottom = 9.5
			for _, x in { -W / 4, 0, W / 4 } do
				decoBlock({
					name = "Mullion", parent = model, size = Vector3.new(1.2, top - bottom, 0.8),
					cframe = cf * CFrame.new(x, (top + bottom) / 2, -D / 2 - 0.4), color = body,
				})
			end
		end
	else
		MapKit.paintBands(bodyPart, Enum.NormalId.Front, bands, {
			width = W - 6, color = windowColor, mullions = { -W / 4, 0, W / 4 }, body = body,
		})
	end
	-- (6) painted bands on both side faces (zero parts). Outer ring: every
	-- band. Mid ring: the bands above the 20-tall rowhouses that hide the
	-- lowest one (y 12).
	local sideBands = {}
	for i, y in bands do
		if not isMid or i > 1 then
			table.insert(sideBands, y)
		end
	end
	if #sideBands > 0 then
		for _, face in { Enum.NormalId.Left, Enum.NormalId.Right } do
			MapKit.paintBands(bodyPart, face, sideBands, { width = D - 6, color = windowColor })
		end
	end
	-- (6b) mid ring: a giant painted wall ad (Mural, zero parts) over a back
	-- shop door under an accent awning, so the Back Avenue between the rings
	-- is lined by shopfronts and color on both sides, not blank walls (door
	-- in front of the plinth: r <= 245.2, inside the BackInner sidewalk at
	-- 247.3 - 1.45; awning bottom 8.0 over the walkers; mural from y 11)
	if isMid then
		buildMural(bodyPart, spec)
		decoWedge({
			name = "BackAwning", parent = model, size = Vector3.new(W - 8, 1.2, 3),
			cframe = cf * CFrame.new(0, 8.6, D / 2 + 2) * CFrame.Angles(0, math.pi, 0), color = accent,
		})
		decoBlock({
			name = "BackDoor", parent = model, size = Vector3.new(5, 6.5, 0.4),
			cframe = cf * CFrame.new(-W / 4, 3.25, D / 2 + 0.7), color = accent:Lerp(NAVY, 0.35),
		})
	end
	-- (7) cornice + colored roof cap
	decoBlock({
		name = "Cornice", parent = model, size = Vector3.new(W + 2, 1.6, D + 2),
		cframe = cf * CFrame.new(0, H + 0.2, 0), color = CORNICE,
	})
	roofCap(model, cf, W + 2, D + 2, H + 1, body)
	-- (8) roof prop
	local crane = if isMid then nil else CityLayout.TowerCranes[k]
	if crane then
		-- (8) a slewing tower crane replaces this roof's water tower
		buildCrane(model, cf, spec, crane)
	else
		buildRoofProp(model, cf, spec, k % 4, accent, pastelAlt)
	end
	if isMid then
		-- (9) mid ring: ground-floor awning + door (shops at street level)
		-- and a vertical blade sign on the street wall
		decoWedge({
			name = "Awning", parent = model, size = Vector3.new(W - 4, 1.2, 3),
			cframe = cf * CFrame.new(0, 8.6, -D / 2 - 2), color = accent,
		})
		decoBlock({
			name = "Door", parent = model, size = Vector3.new(5, 6.5, 0.4),
			cframe = cf * CFrame.new(0, 3.25, -D / 2 - 0.6), color = body:Lerp(NAVY, 0.45),
		})
		buildBladeSign(model, cf, spec)
	else
		-- (9) outer ring: shopfront on the Back Avenue
		buildOuterShopfront(model, cf, W, D, -D / 2 - 0.5, accent)
	end
end

-- Narrow rowhouse infill between two mid-ring buildings: a pastel body (the
-- only collider), a warm-lit window band, a 3-stripe awning over a colored
-- door, white cornice + roof cap. Front flush with the mid ring (r 220).
local function buildRowhouse(parent: Instance, spec)
	local W, H, D = spec.width, spec.height, spec.depth
	local k = spec.index
	local cf = spec.cframe
	local body = PASTELS[(k * 5 + 2) % #PASTELS + 1]
	local accent = ACCENTS[(k * 5 + 4) % #ACCENTS + 1]
	local model = makeModel(spec.name, parent)
	makeBlock({
		name = "Body", parent = model, size = Vector3.new(W, H, D),
		cframe = cf * CFrame.new(0, H / 2, 0), color = body,
	})
	decoBlock({
		name = "WindowBand", parent = model, size = Vector3.new(W - 3, 3.6, 0.6),
		cframe = cf * CFrame.new(0, 13, -D / 2 - 0.25), color = WINDOW_WARM,
	})
	local stripe = (W - 2) / 3
	for i = 0, 2 do
		decoWedge({
			name = "AwningStripe", parent = model, size = Vector3.new(stripe, 1.4, 3),
			cframe = cf * CFrame.new((i - 1) * stripe, 8.6, -D / 2 - 1.5),
			color = if i == 1 then CORNICE else accent,
		})
	end
	decoBlock({
		name = "Door", parent = model, size = Vector3.new(4, 6.5, 0.4),
		cframe = cf * CFrame.new(0, 3.25, -D / 2 - 0.2), color = accent:Lerp(NAVY, 0.35),
	})
	decoBlock({
		name = "Cornice", parent = model, size = Vector3.new(W + 0.6, 1.4, D + 1),
		cframe = cf * CFrame.new(0, H + 0.1, 0), color = CORNICE,
	})
	roofCap(model, cf, W + 0.6, D + 1, H + 0.8, body)
end

local function buildSkyline(city: Instance)
	local skyline = makeModel("Skyline", city)
	for _, spec in CityLayout.skyline do
		buildSkylineBuilding(skyline, spec)
	end
	for _, spec in CityLayout.rowhouses do
		buildRowhouse(skyline, spec)
	end
end

----------------------------------------------------------------------
-- Storefronts between the zones
----------------------------------------------------------------------

-- Striped awning of `count` wedges (each `stripe` wide), high edge against
-- the wall (local +Z), sloping down toward the plaza.
local function buildAwning(parent: Instance, cf: CFrame, count: number, stripe: number, depth: number, accent: Color3)
	for i = 0, count - 1 do
		local x = (i - (count - 1) / 2) * stripe
		decoWedge({
			name = "AwningStripe", parent = parent, size = Vector3.new(stripe, 1.4, depth),
			cframe = cf * CFrame.new(x, 0, 0), color = if i % 2 == 0 then CORNICE else accent,
		})
	end
end

local function buildShopFront(model: Instance, cf: CFrame, spec, frontWidth: number, accent: Color3, body: Color3)
	local D = spec.depth
	local front = -D / 2
	local doorX = if spec.kind == "A" then 8.5 else 13
	local windowW = if spec.kind == "A" then 16 else 22
	local windowX = if spec.kind == "A" then -2.5 else -3
	-- plinth band (1 stud proud, darker)
	decoBlock({
		name = "Plinth", parent = model, size = Vector3.new(spec.width + 1, 1.2, D + 1),
		cframe = cf * CFrame.new(0, 0.6, 0), color = body:Lerp(PLINTH_DARK, 0.35),
	})
	-- display window (Glass) with a white frame, and the door
	decoBlock({
		name = "WindowFrame", parent = model, size = Vector3.new(windowW + 1, 8, 0.3),
		cframe = cf * CFrame.new(windowX, 4.9, front - 0.1), color = CORNICE,
	})
	-- warm "lights on inside" panel, seen through the glass (its face sits
	-- between the glass front and the white frame)
	decoBlock({
		name = "WindowGlow", parent = model, size = Vector3.new(windowW, 6.6, 0.1),
		cframe = cf * CFrame.new(windowX, 4.9, front - 0.3), color = WINDOW_WARM,
	})
	decoBlock({
		name = "DisplayWindow", parent = model, size = Vector3.new(windowW, 7, 0.4),
		cframe = cf * CFrame.new(windowX, 4.9, front - 0.3), color = GLASS_BLUE,
		material = Enum.Material.Glass, transparency = 0.55,
	})
	decoBlock({
		name = "Door", parent = model, size = Vector3.new(4, 7, 0.4),
		cframe = cf * CFrame.new(doorX, 4.7, front - 0.2), color = accent:Lerp(NAVY, 0.35),
	})
	decoBlock({
		name = "DoorLight", parent = model, size = Vector3.new(4.4, 0.4, 0.5),
		cframe = cf * CFrame.new(doorX, 8.4, front - 0.25), color = accent, material = Enum.Material.Neon,
	})
	-- striped awning across the ground floor
	local stripes = if spec.kind == "A" then 6 else 8
	buildAwning(model, cf * CFrame.new(0, 9.6, front - 1.85), stripes, frontWidth / stripes, 3.5, accent)
	-- name board + neon underline
	local boardW = if spec.kind == "A" then 18 else 24
	local board = decoBlock({
		name = "ShopSign", parent = model, size = Vector3.new(boardW, 3.4, 0.8),
		cframe = cf * CFrame.new(0, 12.4, front - 0.4), color = accent,
	})
	addSurfaceText(board, spec.name, Enum.Font.FredokaOne, WHITE, Enum.NormalId.Front, 24, accent)
	decoBlock({
		name = "ShopSignNeon", parent = model, size = Vector3.new(boardW, 0.4, 0.3),
		cframe = cf * CFrame.new(0, 10.5, front - 0.7), color = NEON_WHITE, material = Enum.Material.Neon,
	})
end

local function buildShopA(parent: Instance, spec)
	local W, H, D = spec.width, spec.height, spec.depth
	local cf = spec.cframe
	local body = PASTELS[(spec.gapIndex * 2) % #PASTELS + 1]
	local accent = ACCENTS[spec.accentIndex]
	local model = makeModel("Shop" .. spec.name:gsub(" ", ""), parent)
	makeBlock({
		name = "Body", parent = model, size = Vector3.new(W, H, D),
		cframe = cf * CFrame.new(0, H / 2, 0), color = body,
	})
	buildShopFront(model, cf, spec, W, accent, body)
	-- small upstairs windows
	for _, x in { -6, 6 } do
		decoBlock({
			name = "UpperWindow", parent = model, size = Vector3.new(6, 2.6, 0.4),
			cframe = cf * CFrame.new(x, 15.6, -D / 2 - 0.2), color = WINDOW_BLUE,
		})
	end
	decoBlock({
		name = "Cornice", parent = model, size = Vector3.new(W + 1.5, 1.2, D + 1.5),
		cframe = cf * CFrame.new(0, H + 0.1, 0), color = CORNICE,
	})
	roofCap(model, cf, W + 1.5, D + 1.5, H + 0.7, body)
	for _, x in { -5, 5 } do
		decoBlock({
			name = "ACUnit", parent = model, size = Vector3.new(3, 2, 3),
			cframe = cf * CFrame.new(x, H + 1.7, 2.5), color = Color3.fromRGB(200, 206, 220),
		})
	end
end

local function buildShopB(parent: Instance, spec)
	local W, H, D = spec.width, spec.height, spec.depth
	local cf = spec.cframe
	local body = PASTELS[(spec.gapIndex * 2 + 5) % #PASTELS + 1]
	local accent = ACCENTS[spec.accentIndex]
	local model = makeModel("Shop" .. spec.name:gsub(" ", ""), parent)
	makeBlock({
		name = "Body", parent = model, size = Vector3.new(W, H, D),
		cframe = cf * CFrame.new(0, H / 2, 0), color = body,
	})
	buildShopFront(model, cf, spec, 30, accent, body)
	-- rounded corner pillars
	for _, x in { -W / 2, W / 2 } do
		decoCylinder({
			name = "Pillar", parent = model, diameter = 3, height = H,
			cframe = cf * CFrame.new(x, H / 2, -D / 2), color = body:Lerp(WHITE, 0.3),
		})
	end
	-- two window bands (upper floors)
	for _, y in { 17.5, 23.5 } do
		decoBlock({
			name = "WindowBand", parent = model, size = Vector3.new(W - 6, 3.6, 0.6),
			cframe = cf * CFrame.new(0, y, -D / 2 - 0.25), color = WINDOW_BLUE,
		})
	end
	decoBlock({
		name = "Cornice", parent = model, size = Vector3.new(W + 2, 1.4, D + 2),
		cframe = cf * CFrame.new(0, H + 0.1, 0), color = CORNICE,
	})
	roofCap(model, cf, W + 2, D + 2, H + 0.8, body)
	-- rooftop billboard facing the plaza: 2 legs, a saturated board (per
	-- gap, never a neighbouring zone's hue: SHOP_B_BILLBOARD) with white
	-- slogan text, unlit so it glows from any sun angle, inside a white neon
	-- marquee. 20 x 8.5: smaller than every zone's 40 x 11.5 anchor board.
	local roofY = H + 0.8
	for _, x in { -7, 7 } do
		decoBlock({
			name = "BillboardLeg", parent = model, size = Vector3.new(1, 6, 1),
			cframe = cf * CFrame.new(x, roofY + 3, -D / 2 + 3), color = POLE,
		})
	end
	local boardCF = cf * CFrame.new(0, roofY + 10, -D / 2 + 3)
	local billboardColor = SHOP_B_BILLBOARD[spec.gapIndex] or ACCENTS[(spec.gapIndex % #ACCENTS) + 1]
	local board = decoBlock({
		name = "Billboard", parent = model, size = Vector3.new(20, 8.5, 1),
		cframe = boardCF, color = billboardColor, castShadow = true,
	})
	addSurfaceText(board, spec.slogan or "$$$", Enum.Font.LuckiestGuy, WHITE, Enum.NormalId.Front, 20, billboardColor)
	neonFrame(model, boardCF, 20, 8.5, 1.3, NEON_WHITE, 0.6)
	-- flower boxes under the first upper-floor window band
	for i, x in { -10, 10 } do
		local boxCF = cf * CFrame.new(x, 15.2, -D / 2 - 0.6)
		decoBlock({
			name = "FlowerBox", parent = model, size = Vector3.new(8, 1, 1.2),
			cframe = boxCF, color = accent:Lerp(WHITE, 0.3),
		})
		for f = 0, 3 do
			decoBall({
				name = "Flower", parent = model, diameter = 1,
				cframe = boxCF * CFrame.new(-3 + f * 2, 0.75, -0.05),
				color = FLOWER_COLORS[(spec.gapIndex + i * 2 + f) % #FLOWER_COLORS + 1],
			})
		end
	end
end

local function buildShops(city: Instance)
	local shops = makeModel("Shops", city)
	for _, spec in CityLayout.shops do
		if spec.kind == "A" then
			buildShopA(shops, spec)
		else
			buildShopB(shops, spec)
		end
	end
end

----------------------------------------------------------------------
-- Zone anchor buildings: signature-colored landmark + giant name + icon
----------------------------------------------------------------------

-- Giant rooftop icons; `cf` = icon base on the roof (local -Z to the plaza).
local ICONS: { [string]: (Instance, CFrame, GameConfig.ZoneDef) -> () } = {}

ICONS.LemonadeStand = function(parent, cf, zone)
	local lemonCF = cf * CFrame.new(0, 8, 0) * CFrame.Angles(0, 0, math.rad(12))
	decoBall({ name = "IconLemon", parent = parent, diameter = 16, cframe = lemonCF, color = zone.SignColor, castShadow = true })
	for _, x in { -8.4, 8.4 } do
		decoBall({ name = "IconLemonTip", parent = parent, diameter = 3.4, cframe = lemonCF * CFrame.new(x, 0, 0), color = Color3.fromRGB(235, 190, 28) })
	end
	for _, spec in { { x = -1.5, roll = 30 }, { x = 1.8, roll = -25 } } do
		decoBlock({
			name = "IconLeaf", parent = parent, size = Vector3.new(4.5, 0.8, 2.2),
			cframe = lemonCF * CFrame.new(spec.x, 8.3, 0) * CFrame.Angles(0, 0, math.rad(spec.roll)),
			color = Color3.fromRGB(96, 200, 80),
		})
	end
end

ICONS.DogWalking = function(parent, cf, _zone)
	local boneWhite = Color3.fromRGB(250, 248, 240)
	decoCylinder({ name = "IconPole", parent = parent, diameter = 1.2, height = 6, cframe = cf * CFrame.new(0, 3, 0), color = POLE })
	local boneCF = cf * CFrame.new(0, 10, 0) * CFrame.Angles(0, 0, math.rad(28))
	decoBlock({ name = "IconBone", parent = parent, size = Vector3.new(14, 3.5, 3.5), cframe = boneCF, color = boneWhite, castShadow = true })
	for _, x in { -7, 7 } do
		for _, y in { -1.7, 1.7 } do
			decoBall({ name = "IconBoneKnob", parent = parent, diameter = 5, cframe = boneCF * CFrame.new(x, y, 0), color = boneWhite })
		end
	end
end

ICONS.SneakerFlipping = function(parent, cf, zone)
	decoBlock({ name = "IconStand", parent = parent, size = Vector3.new(14, 3, 8), cframe = cf * CFrame.new(0, 1.5, 0), color = zone.AccentColor })
	local shoe = cf * CFrame.new(0, 3, 0)
	decoBlock({ name = "IconSole", parent = parent, size = Vector3.new(16, 2, 7), cframe = shoe * CFrame.new(0, 1, 0), color = WHITE, castShadow = true })
	decoBlock({ name = "IconUpper", parent = parent, size = Vector3.new(11, 5, 6.5), cframe = shoe * CFrame.new(-2.5, 4.5, 0), color = zone.SignColor })
	decoBall({ name = "IconToe", parent = parent, diameter = 6.5, cframe = shoe * CFrame.new(3.6, 3.4, 0), color = zone.SignColor })
	decoBlock({ name = "IconCollar", parent = parent, size = Vector3.new(4, 1.4, 6.8), cframe = shoe * CFrame.new(-5.2, 7.4, 0), color = WHITE })
	decoBlock({
		name = "IconSwoosh", parent = parent, size = Vector3.new(8, 1.1, 0.4),
		cframe = shoe * CFrame.new(-1, 4.2, -3.45) * CFrame.Angles(0, 0, math.rad(-14)),
		color = zone.AccentColor, material = Enum.Material.Neon,
	})
end

ICONS.CarWash = function(parent, cf, _zone)
	local bubbles = {
		{ Vector3.new(-2, 4.5, 0), 8 },
		{ Vector3.new(4, 8.5, 1), 6 },
		{ Vector3.new(-1, 12.5, -1), 5 },
		{ Vector3.new(-6, 9.5, 1), 4.2 },
		{ Vector3.new(5, 2.8, -1.5), 4.6 },
	}
	for _, b in bubbles do
		decoBall({
			name = "IconBubble", parent = parent, diameter = b[2], cframe = cf * CFrame.new(b[1]),
			color = Color3.fromRGB(140, 230, 255), transparency = 0.3,
		})
		decoBall({
			name = "IconBubbleShine", parent = parent, diameter = b[2] * 0.22,
			cframe = cf * CFrame.new(b[1] + Vector3.new(-b[2] * 0.22, b[2] * 0.22, -b[2] * 0.35)),
			color = Color3.fromRGB(255, 255, 255), material = Enum.Material.Neon,
		})
	end
end

ICONS.FoodTruck = function(parent, cf, _zone)
	local bun = Color3.fromRGB(230, 150, 60)
	decoCylinder({ name = "IconBunBottom", parent = parent, diameter = 14, height = 3, cframe = cf * CFrame.new(0, 1.5, 0), color = bun, castShadow = true })
	decoCylinder({ name = "IconPatty", parent = parent, diameter = 15, height = 2, cframe = cf * CFrame.new(0, 4, 0), color = Color3.fromRGB(110, 60, 30) })
	decoBlock({
		name = "IconCheese", parent = parent, size = Vector3.new(13, 0.6, 13),
		cframe = cf * CFrame.new(0, 5.3, 0) * CFrame.Angles(0, math.rad(45), 0), color = Color3.fromRGB(255, 200, 40),
	})
	decoCylinder({ name = "IconLettuce", parent = parent, diameter = 15.5, height = 0.8, cframe = cf * CFrame.new(0, 5.9, 0), color = Color3.fromRGB(120, 220, 80) })
	decoBall({ name = "IconBunTop", parent = parent, diameter = 14, cframe = cf * CFrame.new(0, 6.2, 0), color = bun })
	for _, off in { Vector3.new(-3, 12.4, -2), Vector3.new(2.5, 12.8, -1.5), Vector3.new(0, 13, 1.5), Vector3.new(-4.5, 11, 2) } do
		decoBall({ name = "IconSesame", parent = parent, diameter = 1, cframe = cf * CFrame.new(off), color = Color3.fromRGB(255, 244, 214) })
	end
end

ICONS.ContentCreator = function(parent, cf, zone)
	decoCylinder({ name = "IconPole", parent = parent, diameter = 1.2, height = 3, cframe = cf * CFrame.new(0, 1.5, 0), color = POLE })
	local ringCF = cf * CFrame.new(0, 10.5, 0)
	decoCylinder({
		name = "IconRing", parent = parent, diameter = 16, height = 1.6, axis = "Z",
		cframe = ringCF, color = zone.SignColor, material = Enum.Material.Neon,
	})
	decoCylinder({ name = "IconRingInner", parent = parent, diameter = 12, height = 1.8, axis = "Z", cframe = ringCF, color = Color3.fromRGB(245, 60, 90) })
	-- white play triangle on the plaza face (two mirrored wedges)
	decoWedge({
		name = "IconPlay", parent = parent, size = Vector3.new(0.4, 2.6, 5),
		cframe = ringCF * CFrame.new(0, 1.3, -1.1) * CFrame.Angles(0, RAD_90, 0), color = WHITE,
	})
	decoWedge({
		name = "IconPlay", parent = parent, size = Vector3.new(0.4, 2.6, 5),
		cframe = ringCF * CFrame.new(0, -1.3, -1.1) * CFrame.Angles(0, RAD_90, 0) * CFrame.Angles(0, 0, math.rad(180)), color = WHITE,
	})
end

ICONS.StockDesk = function(parent, cf, zone)
	local green = zone.SignColor
	decoBlock({ name = "IconArrowShaft", parent = parent, size = Vector3.new(4, 12, 2), cframe = cf * CFrame.new(0, 6, 0), color = green, material = Enum.Material.Neon })
	decoWedge({
		name = "IconArrowHead", parent = parent, size = Vector3.new(2, 6, 5),
		cframe = cf * CFrame.new(-2.5, 15, 0) * CFrame.Angles(0, RAD_90, 0), color = green, material = Enum.Material.Neon,
	})
	decoWedge({
		name = "IconArrowHead", parent = parent, size = Vector3.new(2, 6, 5),
		cframe = cf * CFrame.new(2.5, 15, 0) * CFrame.Angles(0, -RAD_90, 0), color = green, material = Enum.Material.Neon,
	})
	-- candlestick bars beside it
	decoBlock({ name = "IconCandle", parent = parent, size = Vector3.new(2, 5, 2), cframe = cf * CFrame.new(-6, 2.5, 0), color = Color3.fromRGB(255, 80, 80) })
	decoBlock({ name = "IconCandle", parent = parent, size = Vector3.new(2, 8, 2), cframe = cf * CFrame.new(6, 4, 0), color = green })
end

ICONS.StartupHQ = function(parent, cf, zone)
	local blue = zone.AccentColor
	local bodyCF = cf * CFrame.new(0, 10.5, 0)
	decoCylinder({ name = "IconRocket", parent = parent, diameter = 5, height = 16, cframe = bodyCF, color = WHITE, castShadow = true })
	decoBall({ name = "IconRocketNose", parent = parent, diameter = 5, cframe = bodyCF * CFrame.new(0, 7.6, 0), color = blue })
	decoBall({ name = "IconRocketWindow", parent = parent, diameter = 2.2, cframe = bodyCF * CFrame.new(0, 3, -2.1), color = blue, material = Enum.Material.Neon })
	for i = 0, 2 do
		local yaw = math.rad(i * 120)
		decoWedge({
			name = "IconRocketFin", parent = parent, size = Vector3.new(0.6, 4, 3),
			cframe = bodyCF * CFrame.Angles(0, yaw, 0) * CFrame.new(0, -6, -3.6), color = blue,
		})
	end
	decoBall({
		name = "IconRocketFlame", parent = parent, diameter = 3.6, cframe = bodyCF * CFrame.new(0, -8.6, 0),
		color = Color3.fromRGB(255, 150, 40), material = Enum.Material.Neon,
	})
end

local function buildAnchor(parent: Instance, spec, zone: GameConfig.ZoneDef)
	local W, H, D = spec.width, spec.height, spec.depth
	local cf = spec.cframe
	local model = makeModel("Anchor" .. zone.Id, parent)
	model:SetAttribute("ZoneId", zone.Id)
	local sc = zone.SignColor
	local luminance = 0.299 * sc.R + 0.587 * sc.G + 0.114 * sc.B
	-- Body: a rich tint of the signature color (32% white). A bright yellow
	-- signature (luminance 0.75-0.85, Lemonade) goes 50% toward pure white =
	-- a warm butter (255,234,143), never cream / khaki; a near-white one
	-- (Startup HQ, > 0.85) is keyed to its AccentColor blue instead: a sky
	-- blue body (accent 60% white = (177,205,255)), accent glass bands, white
	-- pillars, an accent plinth, the accent neon trim.
	local PURE_WHITE = Color3.new(1, 1, 1)
	local isPale = luminance > 0.85
	local isBright = not isPale and luminance > 0.75
	local body = if isPale
		then zone.AccentColor:Lerp(PURE_WHITE, 0.6)
		elseif isBright then sc:Lerp(PURE_WHITE, 0.5)
		else sc:Lerp(WHITE, 0.32)
	local neon = if isPale then zone.AccentColor else neonAccent(zone)
	local windowColor = if isPale then zone.AccentColor else WINDOW_BLUE
	local pillarColor = if isPale
		then Color3.fromRGB(248, 250, 255)
		elseif isBright then Color3.fromRGB(255, 246, 205)
		else body:Lerp(WHITE, 0.3)
	local plinthColor = if isPale then zone.AccentColor:Lerp(NAVY, 0.3) else zone.SignColor:Lerp(NAVY, 0.3)
	-- Sign frame: the signature color, unless it is near-white (Startup HQ),
	-- where a white neon frame would just blow out: use the accent instead.
	local frameColor = if luminance > 0.85 then zone.AccentColor else sc

	makeBlock({
		name = "Body", parent = model, size = Vector3.new(W, H, D),
		cframe = cf * CFrame.new(0, H / 2, 0), color = body,
	})
	decoBlock({
		name = "Plinth", parent = model, size = Vector3.new(W + 1, 6, D + 1),
		cframe = cf * CFrame.new(0, 3, 0), color = plinthColor,
	})
	for _, x in { -W / 2, W / 2 } do
		decoCylinder({
			name = "Pillar", parent = model, diameter = 3, height = H,
			cframe = cf * CFrame.new(x, H / 2, -D / 2), color = pillarColor,
		})
	end
	local bands = bandHeights(H - 2, 10, 6)
	for _, y in bands do
		decoBlock({
			name = "WindowBand", parent = model, size = Vector3.new(W - 8, 3.6, 0.6),
			cframe = cf * CFrame.new(0, y, -D / 2 - 0.25), color = windowColor,
		})
	end
	if #bands > 0 then
		local top, bottom = bands[#bands] + 2.6, 7.5
		for _, x in { -W / 4, 0, W / 4 } do
			decoBlock({
				name = "Mullion", parent = model, size = Vector3.new(1.4, top - bottom, 0.8),
				cframe = cf * CFrame.new(x, (top + bottom) / 2, -D / 2 - 0.4), color = body,
			})
		end
	end
	decoBlock({
		name = "Cornice", parent = model, size = Vector3.new(W + 2, 1.6, D + 2),
		cframe = cf * CFrame.new(0, H + 0.2, 0), color = CORNICE,
	})
	roofCap(model, cf, W + 2, D + 2, H + 1, body)
	decoBlock({
		name = "NeonTrim", parent = model, size = Vector3.new(W + 2, 0.8, 0.6),
		cframe = cf * CFrame.new(0, H - 1.2, -D / 2 - 1.2), color = neon, material = Enum.Material.Neon,
	})

	-- Giant rooftop name sign (left) + icon (right), facing the plaza: a
	-- signature-colored board with white lettering inside a white neon
	-- marquee (the glow light stays in the signature color). 40 x 11.5: the
	-- largest rooftop board in its sector and the only one in its color.
	local roofY = H + 1
	local signX = -8
	local boardCF = cf * CFrame.new(signX, roofY + 4 + 5.75, -D / 2 + 2.5)
	for _, x in { -14, 14 } do
		decoBlock({
			name = "SignPost", parent = model, size = Vector3.new(1, 4, 1),
			cframe = cf * CFrame.new(signX + x, roofY + 2, -D / 2 + 2.5), color = NEON_WHITE, material = Enum.Material.Neon,
		})
	end
	local board = decoBlock({
		name = "AnchorSign", parent = model, size = Vector3.new(40, 11.5, 1.2),
		cframe = boardCF, color = zoneSignFace(zone), castShadow = true,
	})
	addSurfaceText(board, zone.Name, Enum.Font.FredokaOne, WHITE, Enum.NormalId.Front, 20, board.Color)
	addPointLight(board, frameColor, 20, 0.8)
	neonFrame(model, boardCF, 40, 11.5, 1.5, NEON_WHITE, 0.8)

	-- The giant icon is its own Model, pivoted at the icon base and tagged
	-- CitySpin (deg/s): the client city-life sim turns it about world Y. The
	-- base sits right of / behind the board's center line so a full turn of
	-- the widest icon (lemon tips reach ~10.1) never sweeps through the
	-- marquee (nearest frame point is ~10.6 from the pivot).
	local iconBuilder = ICONS[zone.Id]
	if iconBuilder then
		local iconCF = cf * CFrame.new(20.5, roofY, 1.5)
		local icon = makeModel("Icon", model)
		iconBuilder(icon, iconCF, zone)
		icon.WorldPivot = iconCF
		icon:SetAttribute("CitySpin", 25)
	end
end

local function buildAnchors(city: Instance)
	local anchors = makeModel("Anchors", city)
	for _, spec in CityLayout.anchors do
		local zone = GameConfig.getZone(spec.zoneId)
		if zone then
			buildAnchor(anchors, spec, zone)
		end
	end
end

----------------------------------------------------------------------
-- Street furniture (outer sidewalk) + bus stops
----------------------------------------------------------------------

local function groundCF(position: Vector3): CFrame
	-- -Z faces the plaza (toward the road)
	local r = Vector3.new(position.X, 0, position.Z).Magnitude
	return facingCFrame(r, CityLayout.angleOf(position), position.Y)
end

local FURNITURE: { [string]: (Instance, CFrame, any?) -> () } = {}

FURNITURE.Planter = function(parent, cf)
	decoCylinder({ name = "Planter", parent = parent, diameter = 5.6, height = 1.4, cframe = cf * CFrame.new(0, 0.7, 0), color = Color3.fromRGB(226, 214, 192) })
	decoCylinder({ name = "PlanterRim", parent = parent, diameter = 6, height = 0.3, cframe = cf * CFrame.new(0, 1.45, 0), color = Color3.fromRGB(250, 248, 240) })
	decoCylinder({ name = "PlanterSoil", parent = parent, diameter = 4.8, height = 0.2, cframe = cf * CFrame.new(0, 1.5, 0), color = Color3.fromRGB(110, 80, 60) })
	MapKit.buildTree(parent, cf.Position + Vector3.new(0, 1.5, 0), 1.1)
end

FURNITURE.Hydrant = function(parent, cf)
	local red = Color3.fromRGB(235, 60, 60)
	decoCylinder({ name = "HydrantBase", parent = parent, diameter = 1.7, height = 0.3, cframe = cf * CFrame.new(0, 0.15, 0), color = red })
	decoCylinder({ name = "Hydrant", parent = parent, diameter = 1.3, height = 2.2, cframe = cf * CFrame.new(0, 1.1, 0), color = red })
	decoBall({ name = "HydrantCap", parent = parent, diameter = 1.4, cframe = cf * CFrame.new(0, 2.2, 0), color = red })
	decoCylinder({ name = "HydrantNubs", parent = parent, diameter = 0.55, height = 2, axis = "X", cframe = cf * CFrame.new(0, 1.5, 0), color = Color3.fromRGB(255, 214, 60) })
end

FURNITURE.TrashCan = function(parent, cf)
	decoCylinder({ name = "TrashCan", parent = parent, diameter = 1.8, height = 2.6, cframe = cf * CFrame.new(0, 1.3, 0), color = Color3.fromRGB(70, 180, 110) })
	decoCylinder({ name = "TrashLid", parent = parent, diameter = 2, height = 0.3, cframe = cf * CFrame.new(0, 2.75, 0), color = Color3.fromRGB(50, 140, 86) })
end

FURNITURE.NewsBox = function(parent, cf)
	decoBlock({ name = "NewsBox", parent = parent, size = Vector3.new(1.8, 2.8, 1.6), cframe = cf * CFrame.new(0, 1.4, 0), color = Color3.fromRGB(70, 140, 255) })
	decoBlock({ name = "NewsPaper", parent = parent, size = Vector3.new(1.2, 0.8, 0.1), cframe = cf * CFrame.new(0, 2, 0.82), color = WHITE })
end

-- Tall double lamp (15-tall pole, 6-wide arm, 2 neon globes; the light only
-- when item.light ~= false) with zone-colored festival banners when the item
-- names item.bannerZones = { lower-angle zone id, higher-angle zone id }: a
-- BannerBar at y 12.7 and two 1.9 x 4.4 Banners (y 8.1 .. 12.5) hanging in
-- the tangential plane (radial extent +-0.1) at lamp-local x +1.25 (the
-- lower-angle side, the plaza viewer's left) and -1.25.
local BANNER_FACE: { [string]: Color3 } = {}
for _, zone in GameConfig.Zones do
	BANNER_FACE[zone.Id] = zoneSignFace(zone)
end
FURNITURE.Lamp = function(parent, cf, item)
	decoCylinder({ name = "LampBase", parent = parent, diameter = 1.6, height = 0.5, cframe = cf * CFrame.new(0, 0.25, 0), color = POLE_BASE })
	makeCylinder({ name = "LampPole", parent = parent, diameter = 0.9, height = 15, cframe = cf * CFrame.new(0, 7.5, 0), color = POLE, castShadow = false })
	decoBlock({ name = "LampArm", parent = parent, size = Vector3.new(6, 0.6, 0.6), cframe = cf * CFrame.new(0, 14.6, 0), color = POLE })
	for i, x in { -3, 3 } do
		local globe = decoBall({ name = "LampGlobe", parent = parent, diameter = 2.2, cframe = cf * CFrame.new(x, 13.6, 0), color = LAMP_GLOBE, material = Enum.Material.Neon })
		if i == 1 and not (item and item.light == false) then
			addPointLight(globe, MapKit.LAMP_WARM, 18, 0.9)
		end
	end
	local zones = item and item.bannerZones
	if zones then
		decoBlock({ name = "BannerBar", parent = parent, size = Vector3.new(4.6, 0.3, 0.3), cframe = cf * CFrame.new(0, 12.7, 0), color = POLE })
		for j, x in { 1.25, -1.25 } do
			decoBlock({
				name = "Banner", parent = parent, size = Vector3.new(1.9, 4.4, 0.2),
				cframe = cf * CFrame.new(x, 10.3, 0), color = BANNER_FACE[zones[j]] or WHITE,
			})
		end
	end
end

local function buildBusStop(parent: Instance, stop)
	local model = makeModel(stop.name, parent)
	local cf = stop.cframe -- -Z faces the road
	local orange = Color3.fromRGB(255, 150, 40)
	decoBlock({ name = "BusRoof", parent = model, size = Vector3.new(14, 0.8, 6), cframe = cf * CFrame.new(0, 8.4, 0), color = orange, castShadow = true })
	decoBlock({ name = "BusRoofTrim", parent = model, size = Vector3.new(14.2, 0.4, 0.4), cframe = cf * CFrame.new(0, 8.1, -3.1), color = WHITE, material = Enum.Material.Neon })
	for _, x in { -6.4, 6.4 } do
		decoBlock({ name = "BusPost", parent = model, size = Vector3.new(0.6, 8, 0.6), cframe = cf * CFrame.new(x, 4, 2.4), color = POLE })
	end
	decoBlock({
		name = "BusGlass", parent = model, size = Vector3.new(13, 6, 0.3), cframe = cf * CFrame.new(0, 4.2, 2.6),
		color = GLASS_BLUE, material = Enum.Material.Glass, transparency = 0.4,
	})
	decoBlock({ name = "BusBench", parent = model, size = Vector3.new(10, 0.8, 2), cframe = cf * CFrame.new(-1, 1.8, 1.3), color = MapKit.WOOD })
	for _, x in { -5, 3 } do
		decoBlock({ name = "BusBenchLeg", parent = model, size = Vector3.new(0.5, 1.4, 1.6), cframe = cf * CFrame.new(x, 0.7, 1.3), color = POLE })
	end
	-- Neon-framed ad panel on the glass
	local adCF = cf * CFrame.new(4.4, 4.4, 2.3)
	local ad = decoBlock({ name = "BusAd", parent = model, size = Vector3.new(4, 6, 0.3), cframe = adCF, color = WHITE })
	addSurfaceText(ad, "HUSTLE\nBUS", Enum.Font.LuckiestGuy, Color3.fromRGB(255, 110, 190), Enum.NormalId.Front, 24, WHITE)
	neonFrame(model, adCF, 4, 6, 0.4, Color3.fromRGB(255, 110, 190), 0.3)
	-- round BUS sign on a pole at the curb end
	decoCylinder({ name = "BusSignPole", parent = model, diameter = 0.4, height = 10, cframe = cf * CFrame.new(-8.5, 5, -2), color = POLE })
	local disc = decoCylinder({
		name = "BusSign", parent = model, diameter = 2.6, height = 0.3, axis = "Z",
		cframe = cf * CFrame.new(-8.5, 9.6, -2), color = Color3.fromRGB(60, 160, 255),
	})
	addSurfaceText(disc, "BUS", Enum.Font.LuckiestGuy, WHITE, Enum.NormalId.Right, 30)
end

local function buildFurniture(city: Instance)
	local furniture = makeModel("Furniture", city)
	for _, item in CityLayout.streetFurniture do
		local builder = FURNITURE[item.kind]
		if builder then
			builder(furniture, groundCF(item.position), item)
		end
	end
	for _, stop in CityLayout.busStops do
		buildBusStop(furniture, stop)
	end
end

----------------------------------------------------------------------
-- Gap blocks: café terraces in front of every Shop A, street trees in round
-- planters beside both shops (positions from CityLayout.cafes / gapTrees)
----------------------------------------------------------------------

-- One café set: white table on a pole under a two-tone umbrella, a stool on
-- each side. `cf` = table center on the ground, -Z toward the plaza.
local function buildCafeSet(parent: Instance, cf: CFrame, accent: Color3)
	local C = CityLayout.Cafe
	decoCylinder({
		name = "CafeTable", parent = parent, diameter = 4, height = 0.4,
		cframe = cf * CFrame.new(0, C.tableTop - 0.2, 0), color = WHITE,
	})
	decoCylinder({
		name = "CafePole", parent = parent, diameter = 0.5, height = C.canopyY,
		cframe = cf * CFrame.new(0, C.canopyY / 2, 0), color = WHITE,
	})
	decoCylinder({
		name = "CafeUmbrella", parent = parent, diameter = C.canopyDiameter, height = 0.5,
		cframe = cf * CFrame.new(0, C.canopyY, 0), color = accent, castShadow = true,
	})
	decoCylinder({
		name = "CafeUmbrellaTop", parent = parent, diameter = 5, height = 0.52,
		cframe = cf * CFrame.new(0, C.canopyY, 0), color = WHITE,
	})
	decoBall({
		name = "CafeFinial", parent = parent, diameter = 1.2,
		cframe = cf * CFrame.new(0, C.canopyY + 0.6, 0), color = accent,
	})
	for _, side in { -1, 1 } do
		decoCylinder({
			name = "CafeStool", parent = parent, diameter = 1.6, height = C.stoolTop,
			cframe = cf * CFrame.new(side * C.stoolOffset, C.stoolTop / 2, 0), color = accent:Lerp(WHITE, 0.4),
		})
	end
end

-- Checkered patio rug under a Shop A café (CityLayout.cafeTerraces): a flat
-- 0.08 slab in the shop's accent 45% toward white, its lit Top SurfaceGui
-- painting a 0.4-stud white border and a checker of 2 x 2-stud white squares
-- (pizzeria rug), so the café frontage is a destination, not bare pavement.
-- (A Top-face gui: the pattern reads the same either way round.)
local function buildCafeTerrace(parent: Instance, terrace)
	local accent = ACCENTS[terrace.accentIndex] or ACCENTS[1]
	local size = terrace.size
	local slab = decoBlock({
		name = "CafeTerrace", parent = parent, size = size, cframe = terrace.cframe,
		color = accent:Lerp(WHITE, 0.45),
	})
	slab.CanQuery = false
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Checker"
	gui.Face = Enum.NormalId.Top
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 8
	gui.LightInfluence = 1
	gui.Brightness = 1
	local w, d = size.X, size.Z
	local border = 0.4
	for _, edge in {
		{ 0.5, border / 2 / d, 1, border / d },
		{ 0.5, 1 - border / 2 / d, 1, border / d },
		{ border / 2 / w, 0.5, border / w, 1 },
		{ 1 - border / 2 / w, 0.5, border / w, 1 },
	} do
		MapKit.makeGuiFrame({
			name = "Border", parent = gui, anchor = Vector2.new(0.5, 0.5),
			position = UDim2.fromScale(edge[1], edge[2]), size = UDim2.fromScale(edge[3], edge[4]),
			color = WHITE, zIndex = 2,
		})
	end
	local cell = 2
	local cols, rows = math.floor(w / cell), math.floor(d / cell)
	local x0, z0 = (w - cols * cell) / 2, (d - rows * cell) / 2
	for i = 0, cols - 1 do
		for j = 0, rows - 1 do
			if (i + j) % 2 == 0 then
				MapKit.makeGuiFrame({
					name = "Check", parent = gui,
					position = UDim2.fromScale((x0 + i * cell) / w, (z0 + j * cell) / d),
					size = UDim2.fromScale(cell / w, cell / d),
					color = WHITE, transparency = 0.15, zIndex = 1,
				})
			end
		end
	end
	gui.Parent = slab
end

-- Street tree in a round planter whose rim takes the shop's accent.
local function buildGapTree(parent: Instance, position: Vector3, accent: Color3)
	local cf = CFrame.new(position.X, 0, position.Z)
	decoCylinder({
		name = "GapPlanter", parent = parent, diameter = 4.5, height = 1.2,
		cframe = cf * CFrame.new(0, 0.6, 0), color = Color3.fromRGB(240, 232, 214),
	})
	decoCylinder({
		name = "GapPlanterRim", parent = parent, diameter = 5, height = 0.3,
		cframe = cf * CFrame.new(0, 1.25, 0), color = accent:Lerp(WHITE, 0.5),
	})
	decoCylinder({
		name = "GapPlanterSoil", parent = parent, diameter = 4, height = 0.1,
		cframe = cf * CFrame.new(0, 1.43, 0), color = Color3.fromRGB(110, 80, 60),
	})
	MapKit.buildTree(parent, Vector3.new(position.X, 1.45, position.Z), 1.0)
end

local function buildGapBlocks(city: Instance)
	local blocks = makeModel("GapBlocks", city)
	local gapModels = {}
	local shopAByGap = {}
	for _, spec in CityLayout.shops do
		if spec.kind == "A" then
			shopAByGap[spec.gapIndex] = spec
		end
		if not gapModels[spec.gapIndex] then
			gapModels[spec.gapIndex] = makeModel("Gap" .. spec.gapIndex, blocks)
		end
	end
	for _, terrace in CityLayout.cafeTerraces do
		buildCafeTerrace(gapModels[terrace.gapIndex], terrace)
	end
	for _, cafe in CityLayout.cafes do
		local shop = shopAByGap[cafe.gapIndex]
		buildCafeSet(gapModels[cafe.gapIndex], cafe.cframe, ACCENTS[shop and shop.accentIndex or 1])
	end
	-- gapTrees are listed per shop (CityLayout.shops order), two per shop
	for i, spec in CityLayout.shops do
		for j = 1, 2 do
			local pos = CityLayout.gapTrees[(i - 1) * 2 + j]
			if pos then
				buildGapTree(gapModels[spec.gapIndex], pos, ACCENTS[spec.accentIndex])
			end
		end
	end
end

----------------------------------------------------------------------
-- Back pockets: a tree in a planter / a lamp post in every pocket behind
-- the rowhouses (CityLayout.pocketTrees / pocketLamps, r 241.5), so the
-- Back Avenue's inner side reads as a leafy side street
----------------------------------------------------------------------

local function buildBackPockets(city: Instance)
	local pockets = makeModel("BackPockets", city)
	local P = CityLayout.Pocket
	for i, pos in CityLayout.pocketTrees do
		local cf = CFrame.new(pos.X, pos.Y, pos.Z)
		local accent = ACCENTS[(i % #ACCENTS) + 1]
		decoCylinder({
			name = "PocketPlanter", parent = pockets, diameter = P.planterDiameter, height = 1.1,
			cframe = cf * CFrame.new(0, 0.55, 0), color = Color3.fromRGB(240, 232, 214),
		})
		decoCylinder({
			name = "PocketPlanterRim", parent = pockets, diameter = P.planterDiameter + 0.4, height = 0.3,
			cframe = cf * CFrame.new(0, 1.1, 0), color = accent:Lerp(WHITE, 0.45),
		})
		decoCylinder({
			name = "PocketPlanterSoil", parent = pockets, diameter = P.planterDiameter - 0.4, height = 0.1,
			cframe = cf * CFrame.new(0, 1.25, 0), color = Color3.fromRGB(110, 80, 60),
		})
		MapKit.buildTree(pockets, pos + Vector3.new(0, 1.25, 0), P.treeScale)
	end
	for _, pos in CityLayout.pocketLamps do
		MapKit.buildLampPost(pockets, CFrame.new(pos))
	end
end

----------------------------------------------------------------------
-- Pocket parks behind the shops (lawn, trees, a bench, a flower bed)
----------------------------------------------------------------------

local function buildParks(city: Instance)
	local parksModel = makeModel("Parks", city)
	local P = CityLayout.Park
	local treeIndex = 0
	for k, park in CityLayout.parks do
		local model = makeModel(park.name, parksModel)
		local cf = park.cframe
		decoBlock({
			name = "ParkCurb", parent = model, size = Vector3.new(P.width + 1.2, P.top - 0.05, P.depth + 1.2),
			cframe = cf * CFrame.new(0, (P.top - 0.05) / 2, 0), color = Color3.fromRGB(250, 248, 240), canCollide = true,
		})
		decoBlock({
			name = "ParkLawn", parent = model, size = Vector3.new(P.width, P.top, P.depth),
			cframe = cf * CFrame.new(0, P.top / 2, 0), color = Color3.fromRGB(108, 200, 76), canCollide = true,
		})
		for j = 1, 3 do
			treeIndex += 1
			local pos = CityLayout.parkTrees[treeIndex]
			MapKit.buildTree(model, pos, if j == 3 then 1.6 else (if (k + j) % 2 == 0 then 1.25 else 1.05))
		end
		-- bench facing the plaza side of the lawn
		local bench = cf * CFrame.new(-3, P.top, -7)
		decoBlock({ name = "ParkBench", parent = model, size = Vector3.new(5.5, 0.55, 1.8), cframe = bench * CFrame.new(0, 1.35, 0), color = MapKit.WOOD })
		decoBlock({ name = "ParkBenchBack", parent = model, size = Vector3.new(5.5, 1.6, 0.45), cframe = bench * CFrame.new(0, 2.3, 0.8), color = MapKit.WOOD })
		-- round flower bed
		local bed = cf * CFrame.new(11, P.top, 5)
		decoCylinder({ name = "FlowerBed", parent = model, diameter = 4, height = 0.5, cframe = bed * CFrame.new(0, 0.25, 0), color = Color3.fromRGB(120, 80, 60) })
		local flowerColors = { ACCENTS[(k % 6) + 1], ACCENTS[((k + 2) % 6) + 1], WHITE }
		for f = 0, 2 do
			local a = math.rad(f * 120 + k * 20)
			decoBall({ name = "Flower", parent = model, diameter = 1.1, cframe = bed * CFrame.new(math.cos(a) * 0.9, 0.8, math.sin(a) * 0.9), color = flowerColors[f + 1] })
		end
	end
end

----------------------------------------------------------------------
-- Plaza buzz: food carts, balloon vendor, colored inlay + sunburst
----------------------------------------------------------------------

local CARTS = {
	IceCream = { color = Color3.fromRGB(255, 140, 200), label = "ICE CREAM" },
	HotDog = { color = Color3.fromRGB(235, 70, 70), label = "HOT DOGS" },
	Popcorn = { color = Color3.fromRGB(255, 210, 60), label = "POPCORN" },
	Drinks = { color = Color3.fromRGB(80, 210, 210), label = "DRINKS" },
}

local CART_ITEMS: { [string]: (Instance, CFrame) -> () } = {}

CART_ITEMS.IceCream = function(parent, cf)
	decoCylinder({ name = "ItemCone", parent = parent, diameter = 1.6, height = 3, cframe = cf * CFrame.new(0, 1.5, 0), color = Color3.fromRGB(226, 170, 100) })
	decoBall({ name = "ItemScoop", parent = parent, diameter = 3, cframe = cf * CFrame.new(0, 3.7, 0), color = Color3.fromRGB(255, 140, 200) })
	decoBall({ name = "ItemScoop", parent = parent, diameter = 2.6, cframe = cf * CFrame.new(0, 5.8, 0), color = Color3.fromRGB(170, 240, 210) })
	decoBall({ name = "ItemCherry", parent = parent, diameter = 0.9, cframe = cf * CFrame.new(0, 7.3, 0), color = Color3.fromRGB(235, 40, 60) })
end

CART_ITEMS.HotDog = function(parent, cf)
	decoBlock({ name = "ItemBun", parent = parent, size = Vector3.new(5, 1, 2), cframe = cf * CFrame.new(0, 0.5, 0), color = Color3.fromRGB(230, 170, 90) })
	decoCylinder({ name = "ItemSausage", parent = parent, diameter = 1.4, height = 5.6, axis = "X", cframe = cf * CFrame.new(0, 1.3, 0), color = Color3.fromRGB(200, 80, 60) })
	decoBlock({ name = "ItemMustard", parent = parent, size = Vector3.new(4.4, 0.25, 0.4), cframe = cf * CFrame.new(0, 2.05, 0), color = Color3.fromRGB(255, 220, 40), material = Enum.Material.Neon })
end

CART_ITEMS.Popcorn = function(parent, cf)
	decoCylinder({ name = "ItemBucket", parent = parent, diameter = 3, height = 3, cframe = cf * CFrame.new(0, 1.5, 0), color = Color3.fromRGB(235, 60, 60) })
	decoCylinder({ name = "ItemBucketStripe", parent = parent, diameter = 3.05, height = 1, cframe = cf * CFrame.new(0, 1.5, 0), color = WHITE })
	for _, off in { Vector3.new(0, 3.4, 0), Vector3.new(0.8, 3.1, 0.5), Vector3.new(-0.8, 3.1, -0.4), Vector3.new(0.3, 3.2, -0.9), Vector3.new(-0.4, 3.9, 0.6) } do
		decoBall({ name = "ItemPopcorn", parent = parent, diameter = 1.2, cframe = cf * CFrame.new(off), color = Color3.fromRGB(255, 244, 200) })
	end
end

CART_ITEMS.Drinks = function(parent, cf)
	decoCylinder({ name = "ItemCup", parent = parent, diameter = 2, height = 3.5, cframe = cf * CFrame.new(0, 1.75, 0), color = Color3.fromRGB(80, 210, 210) })
	decoCylinder({ name = "ItemLid", parent = parent, diameter = 2.2, height = 0.3, cframe = cf * CFrame.new(0, 3.6, 0), color = WHITE })
	decoBlock({
		name = "ItemStraw", parent = parent, size = Vector3.new(0.3, 3, 0.3),
		cframe = cf * CFrame.new(0.3, 4.9, 0) * CFrame.Angles(0, 0, math.rad(-15)), color = Color3.fromRGB(255, 110, 190), material = Enum.Material.Neon,
	})
end

local function buildFoodCart(parent: Instance, prop)
	local cart = CARTS[prop.kind]
	if not cart then
		return
	end
	local model = makeModel("FoodCart" .. prop.kind, parent)
	local cf = facingCFrame(Vector3.new(prop.position.X, 0, prop.position.Z).Magnitude, prop.angle, prop.position.Y)
	-- the cart faces the plaza center (-Z): tangential 6 wide, radial 3.4 deep
	makeBlock({ name = "CartBody", parent = model, size = Vector3.new(6, 3, 3.4), cframe = cf * CFrame.new(0, 2.3, 0), color = cart.color })
	decoBlock({ name = "CartTop", parent = model, size = Vector3.new(6.4, 0.4, 3.8), cframe = cf * CFrame.new(0, 4, 0), color = WHITE })
	decoBlock({ name = "CartStripe", parent = model, size = Vector3.new(6.05, 0.5, 3.45), cframe = cf * CFrame.new(0, 3.2, 0), color = WHITE })
	for _, z in { -1.95, 1.95 } do
		decoCylinder({ name = "CartWheel", parent = model, diameter = 2.2, height = 0.5, axis = "Z", cframe = cf * CFrame.new(-1.6, 1.1, z), color = MapKit.WHEEL_DARK })
	end
	decoBlock({ name = "CartLeg", parent = model, size = Vector3.new(0.4, 0.9, 2.8), cframe = cf * CFrame.new(2.4, 0.45, 0), color = POLE })
	local plate = decoBlock({ name = "CartSign", parent = model, size = Vector3.new(4.6, 1.1, 0.2), cframe = cf * CFrame.new(0, 2.1, -1.8), color = WHITE })
	addSurfaceText(plate, cart.label, Enum.Font.FredokaOne, cart.color, Enum.NormalId.Front, 30, WHITE)
	-- umbrella: pole + white disc + accent disc + finial
	decoCylinder({ name = "UmbrellaPole", parent = model, diameter = 0.3, height = 9, cframe = cf * CFrame.new(1.8, 8.7, 0.6), color = POLE })
	decoCylinder({ name = "UmbrellaCanopy", parent = model, diameter = 8, height = 0.4, cframe = cf * CFrame.new(1.8, 12.9, 0.6), color = WHITE, castShadow = true })
	decoCylinder({ name = "UmbrellaTop", parent = model, diameter = 6, height = 0.5, cframe = cf * CFrame.new(1.8, 13.3, 0.6), color = cart.color })
	decoBall({ name = "UmbrellaFinial", parent = model, diameter = 0.7, cframe = cf * CFrame.new(1.8, 13.7, 0.6), color = WHITE })
	-- giant item on the counter (front-left of the umbrella pole)
	local itemBuilder = CART_ITEMS[prop.kind]
	if itemBuilder then
		itemBuilder(model, cf * CFrame.new(-1.6, 4.2, -0.2))
	end
end

local function buildBalloonVendor(parent: Instance, prop)
	local model = makeModel("BalloonVendor", parent)
	local base = CFrame.new(prop.position)
	decoCylinder({ name = "BalloonWeight", parent = model, diameter = 1.6, height = 0.6, cframe = base * CFrame.new(0, 0.3, 0), color = POLE })
	decoCylinder({ name = "BalloonPole", parent = model, diameter = 0.3, height = 8, cframe = base * CFrame.new(0, 4.3, 0), color = POLE })
	local colors = {
		Color3.fromRGB(255, 70, 70), Color3.fromRGB(255, 160, 40), Color3.fromRGB(255, 220, 50),
		Color3.fromRGB(100, 220, 90), Color3.fromRGB(70, 180, 255), Color3.fromRGB(160, 110, 255),
		Color3.fromRGB(255, 120, 200),
	}
	local tie = Vector3.new(0, 8.3, 0)
	for i, color in colors do
		local a = math.rad(i * 360 / #colors)
		local radius = if i % 2 == 0 then 2.2 else 1.4
		local pos = Vector3.new(math.cos(a) * radius, 10 + (i % 3) * 1.1, math.sin(a) * radius)
		decoBall({ name = "Balloon", parent = model, diameter = 2, cframe = base * CFrame.new(pos), color = color, reflectance = 0.1 })
		local from, to = tie, pos - Vector3.new(0, 1, 0)
		local mid = (from + to) / 2
		local dir = (to - from)
		decoBlock({
			name = "BalloonString", parent = model, size = Vector3.new(0.1, dir.Magnitude, 0.1),
			cframe = base * CFrame.new(mid) * CFrame.fromAxisAngle(Vector3.new(dir.Z, 0, -dir.X).Unit, math.acos(dir.Unit.Y)),
			color = WHITE,
		})
	end
end

local function buildPlazaBuzz(city: Instance)
	local buzz = makeModel("PlazaBuzz", city)
	-- Colored inlay on the plaza floor (thin non-colliding discs, no height change)
	local peach = Color3.fromRGB(255, 186, 140)
	local cream = Color3.fromRGB(247, 238, 214)
	-- Layers are >= 0.03 apart so they never z-fight at a distance.
	for _, disc in { { r = 50, top = 1.54, color = peach }, { r = 44, top = 1.58, color = cream }, { r = 24, top = 1.62, color = peach } } do
		decoCylinder({
			name = "PlazaInlay", parent = buzz, diameter = disc.r * 2, height = 0.06,
			cframe = CFrame.new(0, disc.top - 0.03, 0), color = disc.color,
		})
	end
	-- Sunburst: 16 triangular rays across the cream ring (apex at r 26, an
	-- 8-stud base at r 43), alternating colors. Each ray is two WedgeParts
	-- laid flat (rolled 90 degrees so the wedge profile lies in the floor).
	local rayColors = { Color3.fromRGB(255, 158, 112), Color3.fromRGB(112, 214, 200) }
	for i = 0, 15 do
		local rayCF = facingCFrame(34.5, 11.25 + i * 22.5, 1.59) -- top 1.61: over the cream ring
		for _, side in { -1, 1 } do
			decoWedge({
				name = "PlazaRay", parent = buzz, size = Vector3.new(0.04, 4, 17),
				cframe = rayCF * CFrame.new(side * 2, 0, 0) * CFrame.Angles(0, 0, -side * RAD_90),
				color = rayColors[i % 2 + 1],
			})
		end
	end
	for _, prop in CityLayout.plazaProps do
		if prop.kind == "BalloonVendor" then
			buildBalloonVendor(buzz, prop)
		else
			buildFoodCart(buzz, prop)
		end
	end
	-- Raised round flower planters: candy-colored wall (collides), white rim,
	-- soil, a tree and a ring of six flower heads.
	local planterColors = {
		Color3.fromRGB(255, 150, 135), -- coral
		Color3.fromRGB(150, 226, 190), -- mint
		Color3.fromRGB(255, 228, 140), -- butter
		Color3.fromRGB(140, 192, 255), -- sky
		Color3.fromRGB(255, 170, 210), -- bubblegum
	}
	for _, planter in CityLayout.plazaPlanters do
		local model = makeModel("PlazaPlanter", buzz)
		local base = CFrame.new(planter.position) -- on the plaza floor
		makeCylinder({
			name = "PlanterWall", parent = model, diameter = 9, height = 2.4,
			cframe = base * CFrame.new(0, 1.2, 0), color = planterColors[(planter.colorIndex - 1) % #planterColors + 1],
		})
		decoCylinder({
			name = "PlanterRim", parent = model, diameter = 9.6, height = 0.4,
			cframe = base * CFrame.new(0, 2.4, 0), color = WHITE,
		})
		decoCylinder({
			name = "PlanterSoil", parent = model, diameter = 8.2, height = 0.2,
			cframe = base * CFrame.new(0, 2.7, 0), color = Color3.fromRGB(110, 80, 60),
		})
		MapKit.buildTree(model, planter.position + Vector3.new(0, 2.8, 0), 0.9)
		for f = 0, 5 do
			local a = math.rad(f * 60 + 30)
			decoBall({
				name = "Flower", parent = model, diameter = 1.4,
				cframe = base * CFrame.new(math.cos(a) * 3, 3.3, math.sin(a) * 3),
				color = FLOWER_COLORS[(planter.colorIndex + f) % #FLOWER_COLORS + 1],
			})
		end
	end
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

-- Builds SideHustleMap.City under `map` (call once per map build).
function CityBuilder.build(map: Instance): Model
	local city = makeModel("City", map)
	buildStreet(city)
	buildSkyline(city)
	buildShops(city)
	buildAnchors(city)
	buildFurniture(city)
	buildGapBlocks(city)
	buildParks(city)
	buildBackPockets(city)
	buildPlazaBuzz(city)
	return city
end

-- Exposed for unit use (not required by the map).
CityBuilder.SIDEWALK_COLOR = SIDEWALK

return CityBuilder
