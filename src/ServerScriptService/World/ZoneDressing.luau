--!nonstrict
-- ZoneDressing: themed clutter that turns each 64 x 64 zone pad into a busy
-- mini-district (cafe tables at the Lemonade Stand, agility hoops at Dog
-- Walking, a velvet-rope queue at Sneaker Street ...). Built into
-- <ZoneId>.Dressing in zone-local space (zoneCF = pad top center, -Z faces the
-- plaza, pad spans x / z -32..32).
--
-- Keep-outs (tools/check_map.luau audits the colliders): the walkway from the
-- gate (z -32) to the counter (|x| < 8, or the diagonal to an off-center
-- counter), 6 studs around PromptPart / AutoAnchor, and every existing prop.
-- Small parts never collide and never cast shadows; only a few big props far
-- from the walkway (parked cars, giant bottles) collide.

local MapKit = require(script.Parent.MapKit)

local makeBlock = MapKit.makeBlock
local makeBall = MapKit.makeBall
local makeCylinder = MapKit.makeCylinder
local makeModel = MapKit.makeModel
local addSurfaceText = MapKit.addSurfaceText

local ZoneDressing = {}

local NAVY = MapKit.NAVY
local WHITE = MapKit.WHITE
local WOOD = MapKit.WOOD
local DARK_WOOD = MapKit.DARK_WOOD
local POLE = MapKit.STREET_POLE -- toy-city cobalt hardware (table poles, posts, legs)

local function deco(props)
	if props.canCollide == nil then
		props.canCollide = false
	end
	if props.castShadow == nil then
		props.castShadow = false
	end
	return props
end
local function block(props)
	return makeBlock(deco(props))
end
local function ball(props)
	return makeBall(deco(props))
end
local function cylinder(props)
	return makeCylinder(deco(props))
end

-- Local CFrame helper: position (x, y, z) in zone space, optional yaw (deg).
local function at(zoneCF: CFrame, x: number, y: number, z: number, yawDeg: number?): CFrame
	local cf = zoneCF * CFrame.new(x, y, z)
	if yawDeg then
		cf *= CFrame.Angles(0, math.rad(yawDeg), 0)
	end
	return cf
end

-- A thin block spanning two points (wires, ropes, strings).
local function span(parent: Instance, name: string, from: Vector3, to: Vector3, thickness: number, color: Color3, material: Enum.Material?)
	local length = (to - from).Magnitude
	block({
		name = name, parent = parent, size = Vector3.new(thickness, thickness, length),
		cframe = CFrame.lookAt((from + to) / 2, to), color = color, material = material,
	})
end

----------------------------------------------------------------------
-- Shared small props
----------------------------------------------------------------------

-- Cartoon car (static). cf = ground center, car points along local +X.
local function buildCar(parent: Instance, cf: CFrame, color: Color3)
	makeBlock({
		name = "CarBody", parent = parent, size = Vector3.new(8, 2.2, 4.2),
		cframe = cf * CFrame.new(0, 2.1, 0), color = color, castShadow = true,
	})
	block({
		name = "CarCabin", parent = parent, size = Vector3.new(4.2, 1.9, 3.8),
		cframe = cf * CFrame.new(-0.5, 4.1, 0), color = Color3.fromRGB(170, 225, 255), castShadow = true,
	})
	block({
		name = "CarRoof", parent = parent, size = Vector3.new(4.4, 0.4, 4),
		cframe = cf * CFrame.new(-0.5, 5.2, 0), color = color,
	})
	for _, x in { -2.7, 2.7 } do
		for _, z in { -2.1, 2.1 } do
			cylinder({
				name = "CarWheel", parent = parent, diameter = 2, height = 0.8, axis = "Z",
				cframe = cf * CFrame.new(x, 1, z), color = MapKit.WHEEL_DARK,
			})
		end
	end
	for _, z in { -1.3, 1.3 } do
		ball({
			name = "CarHeadlight", parent = parent, diameter = 0.8,
			cframe = cf * CFrame.new(4, 2.4, z), color = Color3.fromRGB(255, 244, 190), material = Enum.Material.Neon,
		})
	end
end

-- Octagonal neon hoop standing upright, its opening facing local Z.
local function buildHoop(parent: Instance, cf: CFrame, radius: number, color: Color3)
	local side = 2 * radius * math.tan(math.rad(22.5))
	for i = 0, 7 do
		local a = math.rad(i * 45)
		block({
			name = "HoopBar", parent = parent, size = Vector3.new(side + 0.1, 0.35, 0.35),
			cframe = cf * CFrame.new(math.sin(a) * radius, math.cos(a) * radius, 0) * CFrame.Angles(0, 0, -a),
			color = color, material = Enum.Material.Neon,
		})
	end
end

----------------------------------------------------------------------
-- Per-zone dressing
----------------------------------------------------------------------

local DRESS: { [string]: (Instance, CFrame, any) -> () } = {}

-- Lemonade Stand: cafe tables with striped umbrellas, lemon crates, potted lemon trees
DRESS.LemonadeStand = function(parent, zoneCF, zone)
	local yellow = zone.SignColor
	for i, pos in { Vector3.new(-20, 0, -10), Vector3.new(-20, 0, 12), Vector3.new(20, 0, -10) } do
		local cf = at(zoneCF, pos.X, 0, pos.Z)
		cylinder({ name = "TableFoot", parent = parent, diameter = 2.2, height = 0.3, cframe = cf * CFrame.new(0, 0.15, 0), color = POLE })
		cylinder({ name = "TablePole", parent = parent, diameter = 0.4, height = 2.6, cframe = cf * CFrame.new(0, 1.4, 0), color = POLE })
		cylinder({ name = "TableTop", parent = parent, diameter = 5, height = 0.4, cframe = cf * CFrame.new(0, 2.9, 0), color = WHITE, castShadow = true })
		cylinder({ name = "UmbrellaPole", parent = parent, diameter = 0.25, height = 5.2, cframe = cf * CFrame.new(0, 5.6, 0), color = WHITE })
		cylinder({ name = "UmbrellaCanopy", parent = parent, diameter = 7, height = 0.5, cframe = cf * CFrame.new(0, 8.2, 0), color = yellow, castShadow = true })
		-- y 8.025 .. 8.525: 0.075 inside the canopy's underside, 0.075 over its top
		cylinder({ name = "UmbrellaStripe", parent = parent, diameter = 5, height = 0.5, cframe = cf * CFrame.new(0, 8.275, 0), color = WHITE })
		ball({ name = "UmbrellaFinial", parent = parent, diameter = 0.7, cframe = cf * CFrame.new(0, 8.75, 0), color = yellow })
		for j, x in { -3.4, 3.4 } do
			block({
				name = "Stool", parent = parent, size = Vector3.new(1.6, 1.6, 1.6),
				cframe = cf * CFrame.new(x, 0.8, 0), color = if (i + j) % 2 == 0 then Color3.fromRGB(255, 140, 120) else Color3.fromRGB(120, 210, 255),
			})
		end
	end
	-- Lemon crate stacks
	for i, pos in { Vector3.new(20, 0, 14), Vector3.new(24, 0, 20) } do
		local cf = at(zoneCF, pos.X, 0, pos.Z, i * 17)
		local levels = if i == 1 then 1 else 2
		for l = 1, levels do
			block({
				name = "LemonCrate", parent = parent, size = Vector3.new(3, 2, 3),
				cframe = cf * CFrame.new(0, 1 + (l - 1) * 2, 0) * CFrame.Angles(0, math.rad((l - 1) * 12), 0),
				color = WOOD, material = Enum.Material.WoodPlanks, castShadow = true,
			})
		end
		local top = levels * 2 + 0.5
		for _, off in { Vector3.new(-0.7, 0, -0.5), Vector3.new(0.7, 0, -0.4), Vector3.new(0, 0.3, 0.6) } do
			ball({ name = "Lemon", parent = parent, diameter = 1.4, cframe = cf * CFrame.new(off.X, top + off.Y, off.Z), color = yellow })
		end
	end
	-- Potted lemon trees in the four corners
	for _, x in { -27, 27 } do
		for _, z in { -27, 27 } do
			local cf = at(zoneCF, x, 0, z)
			cylinder({ name = "LemonPot", parent = parent, diameter = 3.2, height = 2, cframe = cf * CFrame.new(0, 1, 0), color = Color3.fromRGB(214, 120, 80) })
			cylinder({ name = "LemonTrunk", parent = parent, diameter = 0.7, height = 3, cframe = cf * CFrame.new(0, 3.3, 0), color = DARK_WOOD })
			ball({ name = "LemonLeaves", parent = parent, diameter = 4.6, cframe = cf * CFrame.new(0, 6, 0), color = Color3.fromRGB(96, 196, 80), castShadow = true })
			for _, off in { Vector3.new(1.6, 5.4, -1.4), Vector3.new(-1.7, 6.2, -1), Vector3.new(0.2, 7.3, -1.6) } do
				ball({ name = "LemonFruit", parent = parent, diameter = 0.9, cframe = cf * CFrame.new(off), color = yellow })
			end
		end
	end
end

-- Dog Walking: agility hoops + weave poles, a hydrant, dog bowls, a tennis-ball pit
DRESS.DogWalking = function(parent, zoneCF, zone)
	local lawn = 0.2 -- the park lawn sits 0.2 above the pad
	local green = Color3.fromRGB(80, 230, 110)
	for _, z in { -6, 4 } do
		local cf = at(zoneCF, -20, lawn, z)
		for _, x in { -2.6, 2.6 } do
			block({ name = "HoopPost", parent = parent, size = Vector3.new(0.4, 4.6, 0.4), cframe = cf * CFrame.new(x, 2.3, 0), color = WHITE })
		end
		buildHoop(parent, cf * CFrame.new(0, 2.6, 0), 2.1, green)
	end
	-- weave poles
	for i = 0, 4 do
		local cf = at(zoneCF, -22, lawn, 12 + i * 2.4)
		cylinder({
			name = "WeavePole", parent = parent, diameter = 0.4, height = 3.4,
			cframe = cf * CFrame.new(0, 1.7, 0), color = if i % 2 == 0 then zone.SignColor else WHITE,
		})
	end
	-- red hydrant (every dog's favorite)
	local hydrant = at(zoneCF, 20, lawn, 2)
	local red = Color3.fromRGB(235, 60, 60)
	cylinder({ name = "Hydrant", parent = parent, diameter = 1.5, height = 2.6, cframe = hydrant * CFrame.new(0, 1.3, 0), color = red, castShadow = true })
	ball({ name = "HydrantCap", parent = parent, diameter = 1.6, cframe = hydrant * CFrame.new(0, 2.6, 0), color = red })
	cylinder({ name = "HydrantNubs", parent = parent, diameter = 0.6, height = 2.3, axis = "X", cframe = hydrant * CFrame.new(0, 1.8, 0), color = Color3.fromRGB(255, 214, 60) })
	-- three dog bowls
	for i, x in { 16, 18.5, 21 } do
		local cf = at(zoneCF, x, lawn, -10)
		cylinder({
			name = "DogBowl", parent = parent, diameter = 1.7, height = 0.6, cframe = cf * CFrame.new(0, 0.3, 0),
			color = ({ Color3.fromRGB(255, 90, 90), Color3.fromRGB(60, 170, 255), Color3.fromRGB(255, 200, 40) })[i],
		})
		cylinder({ name = "DogFood", parent = parent, diameter = 1.2, height = 0.1, cframe = cf * CFrame.new(0, 0.6, 0), color = Color3.fromRGB(140, 90, 50) })
	end
	-- tennis-ball pit
	local pit = at(zoneCF, 21, lawn, 19)
	cylinder({ name = "BallPitWall", parent = parent, diameter = 8, height = 1.2, cframe = pit * CFrame.new(0, 0.6, 0), color = Color3.fromRGB(60, 150, 255) })
	cylinder({ name = "BallPitRim", parent = parent, diameter = 8.4, height = 0.3, cframe = pit * CFrame.new(0, 1.25, 0), color = WHITE })
	local tennis = Color3.fromRGB(214, 250, 60)
	for i = 0, 8 do
		local a = math.rad(i * 40)
		local r = if i == 8 then 0 else (if i % 2 == 0 then 2.4 else 1.3)
		ball({ name = "TennisBall", parent = parent, diameter = 1, cframe = pit * CFrame.new(math.cos(a) * r, 1.45 + (i % 3) * 0.25, math.sin(a) * r), color = tennis })
	end
end

-- Sneaker Street: shoe-box towers, display pedestals with mini sneakers, velvet-rope queue
DRESS.SneakerFlipping = function(parent, zoneCF, zone)
	local purple = zone.SignColor
	-- velvet-rope queue to the right of the store door
	local gold = Color3.fromRGB(255, 200, 60)
	local velvet = Color3.fromRGB(200, 30, 60)
	for _, z in { 3, 7 } do
		local tops = {}
		for _, x in { 13, 18, 23 } do
			local cf = at(zoneCF, x, 0, z)
			cylinder({ name = "Stanchion", parent = parent, diameter = 0.35, height = 2.6, cframe = cf * CFrame.new(0, 1.3, 0), color = gold })
			ball({ name = "StanchionTop", parent = parent, diameter = 0.6, cframe = cf * CFrame.new(0, 2.7, 0), color = gold })
			table.insert(tops, zoneCF:PointToWorldSpace(Vector3.new(x, 2.3, z)))
		end
		for i = 1, #tops - 1 do
			local mid = (tops[i] + tops[i + 1]) / 2 - Vector3.new(0, 0.35, 0)
			span(parent, "VelvetRope", tops[i], mid, 0.25, velvet)
			span(parent, "VelvetRope", mid, tops[i + 1], 0.25, velvet)
		end
	end
	-- display pedestals with mini sneakers (left column)
	local shoeColors = { Color3.fromRGB(255, 90, 90), Color3.fromRGB(60, 200, 255), purple }
	for i, z in { -16, -6, 6 } do
		local cf = at(zoneCF, -25, 0, z, 90)
		cylinder({ name = "DisplayPedestal", parent = parent, diameter = 3, height = 3, cframe = cf * CFrame.new(0, 1.5, 0), color = WHITE, castShadow = true })
		cylinder({ name = "DisplayRing", parent = parent, diameter = 3.1, height = 0.25, cframe = cf * CFrame.new(0, 2.6, 0), color = purple, material = Enum.Material.Neon })
		local shoe = cf * CFrame.new(0, 3, 0) * CFrame.Angles(0, math.rad(-20), 0)
		block({ name = "MiniSole", parent = parent, size = Vector3.new(2.6, 0.4, 1.1), cframe = shoe * CFrame.new(0, 0.2, 0), color = WHITE })
		block({ name = "MiniUpper", parent = parent, size = Vector3.new(1.7, 0.9, 1.05), cframe = shoe * CFrame.new(-0.35, 0.85, 0), color = shoeColors[i] })
		ball({ name = "MiniToe", parent = parent, diameter = 1.05, cframe = shoe * CFrame.new(0.65, 0.7, 0), color = shoeColors[i] })
	end
	-- shoe-box towers
	for t, pos in { Vector3.new(-18, 0, 15), Vector3.new(18, 0, 16), Vector3.new(24, 0, -19) } do
		local cf = at(zoneCF, pos.X, 0, pos.Z, t * 23)
		local height = 4 + t % 2
		for b = 0, height - 1 do
			block({
				name = "ShoeBox", parent = parent, size = Vector3.new(3, 1.5, 2),
				cframe = cf * CFrame.new(0, 0.75 + b * 1.5, 0) * CFrame.Angles(0, math.rad((b % 3 - 1) * 9), 0),
				color = if b % 2 == 0 then purple else WHITE, castShadow = b == 0,
			})
		end
	end
end

-- Car Wash: two queued cars, a giant soap bottle, floating bubbles, buckets
DRESS.CarWash = function(parent, zoneCF, zone)
	buildCar(parent, at(zoneCF, -23.5, 0, 8), Color3.fromRGB(255, 200, 50))
	buildCar(parent, at(zoneCF, -22, 0, -7, -25), Color3.fromRGB(150, 110, 255))
	-- giant soap bottle
	local bottle = at(zoneCF, 22, 0, -6)
	makeCylinder({ name = "SoapBottle", parent = parent, diameter = 4, height = 8, cframe = bottle * CFrame.new(0, 4, 0), color = zone.AccentColor, castShadow = true })
	cylinder({ name = "SoapLabel", parent = parent, diameter = 4.1, height = 2.4, cframe = bottle * CFrame.new(0, 4, 0), color = WHITE })
	cylinder({ name = "SoapNeck", parent = parent, diameter = 1.4, height = 1.2, cframe = bottle * CFrame.new(0, 8.6, 0), color = WHITE })
	block({ name = "SoapPump", parent = parent, size = Vector3.new(1, 1.4, 1), cframe = bottle * CFrame.new(0, 9.8, 0), color = WHITE })
	block({ name = "SoapNozzle", parent = parent, size = Vector3.new(0.6, 0.6, 2.2), cframe = bottle * CFrame.new(0, 10.2, -1.2), color = WHITE })
	-- bubbles drifting out of the tunnel exit
	for _, b in { { 19, 3, 6, 2.6 }, { 21.5, 5.5, 9, 1.8 }, { 24, 2.2, 12, 2.2 }, { 20, 7.5, 12.5, 1.4 }, { 26, 4.5, 7, 1.6 }, { 23, 9, 9, 1.2 } } do
		ball({
			name = "Bubble", parent = parent, diameter = b[4], cframe = at(zoneCF, b[1], b[2], b[3]),
			color = Color3.fromRGB(200, 240, 255), transparency = 0.3,
		})
	end
	-- buckets + sponges by the tunnel entrance
	for i, x in { -20, -17.5 } do
		local cf = at(zoneCF, x, 0, -1.5)
		cylinder({ name = "Bucket", parent = parent, diameter = 1.8, height = 1.8, cframe = cf * CFrame.new(0, 0.9, 0), color = if i == 1 then Color3.fromRGB(255, 120, 60) else zone.SignColor })
		block({ name = "Sponge", parent = parent, size = Vector3.new(1.2, 0.6, 0.8), cframe = cf * CFrame.new(0, 2, 0), color = Color3.fromRGB(255, 230, 80) })
	end
end

-- Food Truck: picnic tables, giant ketchup + mustard, a string-light canopy
DRESS.FoodTruck = function(parent, zoneCF, zone)
	local red = Color3.fromRGB(235, 60, 60)
	for _, pos in { Vector3.new(-21, 0, -16), Vector3.new(20, 0, -16), Vector3.new(20, 0, 21) } do
		local cf = at(zoneCF, pos.X, 0, pos.Z)
		for p = -1, 1 do
			block({
				name = "PicnicTop", parent = parent, size = Vector3.new(6, 0.4, 1),
				cframe = cf * CFrame.new(0, 2.6, p), color = if p == 0 then WHITE else red, castShadow = p == 0,
			})
		end
		for _, z in { -2.4, 2.4 } do
			block({ name = "PicnicBench", parent = parent, size = Vector3.new(6, 0.3, 1), cframe = cf * CFrame.new(0, 1.5, z), color = WOOD, material = Enum.Material.WoodPlanks })
		end
		for _, x in { -2.4, 2.4 } do
			block({ name = "PicnicLegs", parent = parent, size = Vector3.new(0.4, 2.4, 5.2), cframe = cf * CFrame.new(x, 1.2, 0), color = DARK_WOOD })
		end
	end
	-- giant ketchup + mustard bottles
	for i, pos in { Vector3.new(-23, 0, 15), Vector3.new(-18.5, 0, 18) } do
		local cf = at(zoneCF, pos.X, 0, pos.Z)
		local color = if i == 1 then red else Color3.fromRGB(255, 210, 40)
		makeCylinder({ name = "SauceBottle", parent = parent, diameter = 3, height = 8, cframe = cf * CFrame.new(0, 4, 0), color = color, castShadow = true })
		cylinder({ name = "SauceCap", parent = parent, diameter = 1.8, height = 1.2, cframe = cf * CFrame.new(0, 8.6, 0), color = WHITE })
		cylinder({ name = "SauceTip", parent = parent, diameter = 0.7, height = 1.4, cframe = cf * CFrame.new(0, 9.9, 0), color = color })
	end
	-- string-light canopy over the front-right dining spot
	local corners = {
		Vector3.new(14.5, 0, -24), Vector3.new(26, 0, -24), Vector3.new(26, 0, -9), Vector3.new(14.5, 0, -9),
	}
	local tops = {}
	for _, c in corners do
		local cf = at(zoneCF, c.X, 0, c.Z)
		cylinder({ name = "LightPost", parent = parent, diameter = 0.4, height = 8, cframe = cf * CFrame.new(0, 4, 0), color = DARK_WOOD })
		table.insert(tops, zoneCF:PointToWorldSpace(Vector3.new(c.X, 7.8, c.Z)))
	end
	local bulbColors = { Color3.fromRGB(255, 212, 31), Color3.fromRGB(255, 92, 180), Color3.fromRGB(64, 200, 224), Color3.fromRGB(255, 123, 34) }
	for i = 1, 4 do
		local from, to = tops[i], tops[i % 4 + 1]
		local mid = (from + to) / 2 - Vector3.new(0, 0.9, 0)
		span(parent, "LightWire", from, mid, 0.1, Color3.fromRGB(48, 48, 56))
		span(parent, "LightWire", mid, to, 0.1, Color3.fromRGB(48, 48, 56))
		for k = 1, 3 do
			local p = if k <= 1 then from:Lerp(mid, 0.6) elseif k == 2 then mid else mid:Lerp(to, 0.4)
			ball({ name = "LightBulb", parent = parent, diameter = 0.6, cframe = CFrame.new(p - Vector3.new(0, 0.3, 0)), color = bulbColors[(i + k) % 4 + 1], material = Enum.Material.Neon })
		end
	end
end

-- Creator Studio: pink couch on a rug, giant neon heart, two spotlights on tripods
DRESS.ContentCreator = function(parent, zoneCF, zone)
	local pink = zone.SignColor
	local couch = at(zoneCF, -22, 0, 4, -90) -- faces +X (toward the ring light)
	block({ name = "Rug", parent = parent, size = Vector3.new(12, 0.1, 8), cframe = couch * CFrame.new(0, 0.05, -2.5), color = Color3.fromRGB(255, 200, 230) })
	block({ name = "CouchSeat", parent = parent, size = Vector3.new(7, 1.4, 3), cframe = couch * CFrame.new(0, 0.9, 0), color = pink, castShadow = true })
	block({ name = "CouchBack", parent = parent, size = Vector3.new(7, 2.6, 0.9), cframe = couch * CFrame.new(0, 2, 1.2), color = pink })
	for _, x in { -3.6, 3.6 } do
		-- 3.08 deep: 0.04 proud of the seat's front / back faces (not in their plane)
		block({ name = "CouchArm", parent = parent, size = Vector3.new(0.9, 2, 3.08), cframe = couch * CFrame.new(x, 1.3, 0), color = pink:Lerp(Color3.new(1, 1, 1), 0.25) })
	end
	for _, x in { -1.6, 1.6 } do
		block({ name = "Cushion", parent = parent, size = Vector3.new(2.4, 0.5, 2.2), cframe = couch * CFrame.new(x, 1.85, -0.2), color = Color3.fromRGB(255, 180, 225) })
	end
	-- giant neon heart on a post, facing the plaza
	local heart = at(zoneCF, 22, 0, 9)
	cylinder({ name = "HeartPost", parent = parent, diameter = 0.6, height = 4.5, cframe = heart * CFrame.new(0, 2.25, 0), color = POLE })
	block({
		name = "HeartBody", parent = parent, size = Vector3.new(4, 4, 1),
		cframe = heart * CFrame.new(0, 6.8, 0) * CFrame.Angles(0, 0, math.rad(45)), color = pink, material = Enum.Material.Neon,
	})
	for _, x in { -1.42, 1.42 } do
		ball({ name = "HeartLobe", parent = parent, diameter = 4, cframe = heart * CFrame.new(x, 8.2, 0), color = pink, material = Enum.Material.Neon })
	end
	-- two spotlights on tripods aimed at the set
	for _, spec in { { x = -22, z = -14, yaw = 42 }, { x = 22, z = -14, yaw = -42 } } do
		local cf = at(zoneCF, spec.x, 0, spec.z, spec.yaw)
		for i = 0, 2 do
			block({
				name = "SpotTripodLeg", parent = parent, size = Vector3.new(0.3, 4.2, 0.3),
				cframe = cf * CFrame.Angles(0, math.rad(i * 120), 0) * CFrame.new(0, 2, -0.9) * CFrame.Angles(math.rad(14), 0, 0),
				color = POLE,
			})
		end
		local head = cf * CFrame.new(0, 4.6, 0) * CFrame.Angles(math.rad(-12), 0, 0)
		cylinder({ name = "SpotHead", parent = parent, diameter = 1.8, height = 2.2, axis = "Z", cframe = head, color = Color3.fromRGB(40, 38, 45) })
		cylinder({ name = "SpotLens", parent = parent, diameter = 1.5, height = 0.2, axis = "Z", cframe = head * CFrame.new(0, 0, 1.15), color = Color3.fromRGB(255, 240, 200), material = Enum.Material.Neon })
	end
end

-- Stock Desk: mini ticker pillars, money bags with $ labels, gold coin stacks
DRESS.StockDesk = function(parent, zoneCF, zone)
	local green = Color3.fromRGB(70, 255, 130)
	for i, pos in { Vector3.new(-22, 0, -16), Vector3.new(22, 0, -16), Vector3.new(-22, 0, 2), Vector3.new(22, 0, 2) } do
		local cf = at(zoneCF, pos.X, 0, pos.Z)
		block({ name = "TickerPillar", parent = parent, size = Vector3.new(2, 6, 2), cframe = cf * CFrame.new(0, 3, 0), color = MapKit.STOCK_DEEP_GREEN, castShadow = true })
		block({ name = "TickerStripe", parent = parent, size = Vector3.new(2.1, 0.6, 2.1), cframe = cf * CFrame.new(0, 4.6, 0), color = if i % 2 == 0 then green else Color3.fromRGB(255, 80, 80), material = Enum.Material.Neon })
		block({ name = "TickerCap", parent = parent, size = Vector3.new(2.3, 0.4, 2.3), cframe = cf * CFrame.new(0, 6.2, 0), color = zone.SignColor })
	end
	local bagColor = Color3.fromRGB(120, 190, 100)
	for _, pos in { Vector3.new(-22, 0, 16), Vector3.new(-18.5, 0, 19), Vector3.new(-25, 0, 21), Vector3.new(20, 0, 17), Vector3.new(23.5, 0, 20) } do
		local cf = at(zoneCF, pos.X, 0, pos.Z)
		ball({ name = "MoneyBag", parent = parent, diameter = 3.4, cframe = cf * CFrame.new(0, 1.6, 0), color = bagColor, castShadow = true })
		cylinder({ name = "MoneyBagTie", parent = parent, diameter = 1, height = 1, cframe = cf * CFrame.new(0, 3.4, 0), color = Color3.fromRGB(200, 160, 60) })
		local label = cylinder({ name = "MoneyBagLabel", parent = parent, diameter = 1.6, height = 0.2, axis = "Z", cframe = cf * CFrame.new(0, 1.7, -1.62), color = NAVY })
		addSurfaceText(label, "$", Enum.Font.LuckiestGuy, green, Enum.NormalId.Right, 30)
	end
	local gold = Color3.fromRGB(255, 205, 60)
	for _, pos in { Vector3.new(-14, 0, 20), Vector3.new(14, 0, 22) } do
		for c = 0, 3 do
			cylinder({
				name = "CoinStack", parent = parent, diameter = 2.2, height = 0.45,
				cframe = at(zoneCF, pos.X + (c % 2) * 0.25, 0.25 + c * 0.47, pos.Z), color = if c % 2 == 0 then gold else Color3.fromRGB(235, 180, 40),
			})
		end
	end
end

-- Startup HQ: ping-pong table, beanbags, scooters, a whiteboard
DRESS.StartupHQ = function(parent, zoneCF, zone)
	local blue = zone.AccentColor
	local tableCF = at(zoneCF, 21, 0, 12)
	block({ name = "PingPongTop", parent = parent, size = Vector3.new(9, 0.4, 5), cframe = tableCF * CFrame.new(0, 2.6, 0), color = Color3.fromRGB(40, 90, 200), castShadow = true })
	-- center line: a strip 0.04 over the top (2.8), its ends 0.05 inside the table's
	block({ name = "PingPongLine", parent = parent, size = Vector3.new(8.9, 0.08, 0.15), cframe = tableCF * CFrame.new(0, 2.8, 0), color = WHITE })
	block({ name = "PingPongNet", parent = parent, size = Vector3.new(0.12, 0.8, 5.2), cframe = tableCF * CFrame.new(0, 3.2, 0), color = WHITE })
	for _, x in { -3.4, 3.4 } do
		block({ name = "PingPongLegs", parent = parent, size = Vector3.new(0.4, 2.4, 4), cframe = tableCF * CFrame.new(x, 1.2, 0), color = POLE })
	end
	for _, x in { -2.5, 2.5 } do
		cylinder({ name = "Paddle", parent = parent, diameter = 1.2, height = 0.15, cframe = tableCF * CFrame.new(x, 2.9, 1.2), color = Color3.fromRGB(235, 60, 60) })
	end
	-- beanbags (squashy balls half sunk into the pad)
	for i, pos in { Vector3.new(-22, 0, 8), Vector3.new(-25.5, 0, 12.5), Vector3.new(-20, 0, 14.5), Vector3.new(-25, 0, 3.5) } do
		ball({ name = "Beanbag", parent = parent, diameter = 3.2, cframe = at(zoneCF, pos.X, 0.9, pos.Z), color = if i % 2 == 0 then WHITE else blue, castShadow = true })
	end
	-- two scooters
	for i, pos in { Vector3.new(-22, 0, -16), Vector3.new(-19, 0, -19) } do
		local cf = at(zoneCF, pos.X, 0, pos.Z, 30 + i * 20)
		local color = if i == 1 then Color3.fromRGB(255, 110, 190) else Color3.fromRGB(80, 220, 120)
		block({ name = "ScooterDeck", parent = parent, size = Vector3.new(3, 0.3, 0.8), cframe = cf * CFrame.new(0, 0.6, 0), color = color })
		cylinder({ name = "ScooterStem", parent = parent, diameter = 0.25, height = 3.4, cframe = cf * CFrame.new(1.4, 2.3, 0) * CFrame.Angles(0, 0, math.rad(-10)), color = POLE })
		block({ name = "ScooterBar", parent = parent, size = Vector3.new(0.2, 0.2, 1.8), cframe = cf * CFrame.new(1.7, 4, 0), color = POLE })
		for _, x in { -1.3, 1.4 } do
			cylinder({ name = "ScooterWheel", parent = parent, diameter = 0.8, height = 0.3, axis = "Z", cframe = cf * CFrame.new(x, 0.4, 0), color = MapKit.WHEEL_DARK })
		end
	end
	-- whiteboard with a hockey-stick growth chart, facing the plaza
	local board = at(zoneCF, 22, 0, -16)
	for _, x in { -3, 3 } do
		-- 0.22 deep: 0.04 inside the 0.3-deep board's faces (not in their plane)
		block({ name = "WhiteboardLeg", parent = parent, size = Vector3.new(0.3, 5.6, 0.22), cframe = board * CFrame.new(x, 2.8, 0), color = POLE })
	end
	block({ name = "Whiteboard", parent = parent, size = Vector3.new(7, 4, 0.3), cframe = board * CFrame.new(0, 4, 0), color = WHITE, castShadow = true })
	local lines = {
		{ Vector3.new(-2.8, -1.2, 0), Vector3.new(0.4, -0.8, 0), Color3.fromRGB(60, 130, 255) },
		{ Vector3.new(0.4, -0.8, 0), Vector3.new(2.6, 1.5, 0), Color3.fromRGB(60, 130, 255) },
		{ Vector3.new(-2.6, 1.2, 0), Vector3.new(-0.6, 1.2, 0), Color3.fromRGB(235, 60, 60) },
	}
	for _, line in lines do
		local a = (board * CFrame.new(0, 4, -0.2)):PointToWorldSpace(line[1])
		local b = (board * CFrame.new(0, 4, -0.2)):PointToWorldSpace(line[2])
		span(parent, "MarkerLine", a, b, 0.2, line[3])
	end
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

-- Builds <zoneModel>.Dressing for a zone (no-op for zones without a recipe).
function ZoneDressing.build(zoneModel: Model, zoneCF: CFrame, zone): Model?
	local recipe = DRESS[zone.Id]
	if not recipe then
		return nil
	end
	local dressing = makeModel("Dressing", zoneModel)
	recipe(dressing, zoneCF, zone)
	return dressing
end

-- Exposed so other builders can reuse the static car recipe.
ZoneDressing.buildCar = buildCar

return ZoneDressing
