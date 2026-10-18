-- Map check: executes the REAL MapBuilder.build() inside Lune's Roblox datatype /
-- reflection layer (invalid properties or enum values throw), with a mocked
-- Terrain, then audits contract + geometry.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox") :: any

local REPO = require("@lune/process").cwd:gsub("/$", "")
local Instance, Vector3, CFrame, Enum = roblox.Instance, roblox.Vector3, roblox.CFrame, roblox.Enum

local game = Instance.new("DataModel")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local RS = game:GetService("ReplicatedStorage")
local shared = Instance.new("Folder")
shared.Name = "Shared"
shared.Parent = RS
local moduleFiles = {}
for _, entry in fs.readDir(REPO .. "/src/ReplicatedStorage/Shared") do
	local name = string.match(entry, "^(.+)%.luau$")
	if name then
		local m = Instance.new("ModuleScript")
		m.Name = name
		m.Parent = shared
		moduleFiles[m:GetFullName()] = REPO .. "/src/ReplicatedStorage/Shared/" .. entry
	end
end

local warnings = {}
local fills = {}
local realTerrain = Instance.new("Terrain")
local function isMaterial(v)
	return typeof(v) == "EnumItem" and string.find(tostring(v), "Enum.Material.", 1, true) ~= nil
end
local terrainMock = setmetatable({}, {
	__index = function(_, k)
		if k == "Clear" then
			return function(_self)
				table.insert(fills, { op = "Clear" })
			end
		elseif k == "FillBlock" then
			return function(_self, cf, size, mat)
				assert(typeof(cf) == "CFrame", "FillBlock arg1 must be CFrame, got " .. typeof(cf))
				assert(typeof(size) == "Vector3", "FillBlock arg2 must be Vector3")
				assert(isMaterial(mat), "FillBlock arg3 must be Material")
				table.insert(fills, { op = "FillBlock", cf = cf, size = size, mat = mat })
			end
		elseif k == "FillCylinder" then
			return function(_self, cf, height, radius, mat)
				assert(typeof(cf) == "CFrame", "FillCylinder arg1 must be CFrame")
				assert(type(height) == "number" and type(radius) == "number", "FillCylinder height/radius numbers")
				assert(isMaterial(mat), "FillCylinder arg4 must be Material")
				table.insert(fills, { op = "FillCylinder", cf = cf, height = height, radius = radius, mat = mat })
			end
		elseif k == "FillBall" then
			return function(_self, center, radius, mat)
				assert(typeof(center) == "Vector3", "FillBall arg1 must be Vector3")
				assert(type(radius) == "number", "FillBall radius number")
				assert(isMaterial(mat), "FillBall arg3 must be Material")
				table.insert(fills, { op = "FillBall", center = center, radius = radius, mat = mat })
			end
		end
		return realTerrain[k]
	end,
	__newindex = function(_, k, v)
		-- Roblox marks these NotScriptable: a server script writing them errors.
		assert(k ~= "Decoration", "Terrain.Decoration is not scriptable in Roblox")
		realTerrain[k] = v -- validated by Lune reflection
	end,
})

local env = {}
for k, v in roblox do
	env[k] = v
end
env.game = game
-- Lune 0.8.9 CFrame.lookAt flips the Z of the look direction; Roblox returns
-- LookVector = (target - eye).Unit. Inject a correct implementation.
local function fixedLookAt(at, target, up)
	up = up or Vector3.new(0, 1, 0)
	local look = (target - at).Unit
	local right = look:Cross(up).Unit
	local up2 = right:Cross(look)
	return CFrame.fromMatrix(at, right, up2, -look)
end
env.CFrame = setmetatable({ lookAt = fixedLookAt }, { __index = roblox.CFrame })
CFrame = env.CFrame
env.warn = function(...)
	table.insert(warnings, table.concat({ ... }, " "))
	print("WARN", ...)
end
env.__TERRAIN__ = terrainMock

local cache = {}
local function loadFile(path: string, scriptInst)
	local src = fs.readFile(path)
	local count
	src, count = string.gsub(src, "Workspace%.Terrain", "__TERRAIN__")
	src = string.gsub(src, ":WaitForChild%(", ":FindFirstChild(")
	local chunkEnv = { script = scriptInst }
	for k, v in env do
		chunkEnv[k] = v
	end
	local fn = luau.load(src, { debugName = path, environment = chunkEnv })
	return fn(), count
end
env.require = function(inst)
	local key = inst:GetFullName()
	if cache[key] then
		return cache[key]
	end
	local path = moduleFiles[key]
	assert(path, "unknown module " .. tostring(inst))
	local result = loadFile(path, inst)
	cache[key] = result
	return result
end

-- World/* modules live in a fake ServerScriptService.World folder so
-- MapBuilder can require its siblings (script.Parent.<Name>).
local SSS = game:GetService("ServerScriptService")
local worldFolder = Instance.new("Folder")
worldFolder.Name = "World"
worldFolder.Parent = SSS
local mapModule
for _, entry in fs.readDir(REPO .. "/src/ServerScriptService/World") do
	local name = string.match(entry, "^(.+)%.luau$")
	if name then
		local m = Instance.new("ModuleScript")
		m.Name = name
		m.Parent = worldFolder
		moduleFiles[m:GetFullName()] = REPO .. "/src/ServerScriptService/World/" .. entry
		if name == "MapBuilder" then
			mapModule = m
		end
	end
end
local MapBuilder, terrainRefs = loadFile(REPO .. "/src/ServerScriptService/World/MapBuilder.luau", mapModule)
cache[mapModule:GetFullName()] = MapBuilder
local _ = terrainRefs -- terrain may live in any World module; checked via fills after build()

local GameConfig = env.require(shared.GameConfig)
local Mechanics = env.require(shared.Mechanics)

local t0 = os.clock()
MapBuilder.build()
print(("build() ok in %.2fs"):format(os.clock() - t0))
assert(#fills > 0, "terrain mock received no fills: is Workspace.Terrain referenced as `Workspace.Terrain`?")
assert(#warnings == 0, "build warned: " .. table.concat(warnings, "; "))

-- idempotency: second call is a no-op; rebuild after destroying keeps 1 of each Lighting child
MapBuilder.build()
local map = Workspace:FindFirstChild("SideHustleMap")
assert(map, "no map")
map:Destroy()
MapBuilder.build()
map = Workspace:FindFirstChild("SideHustleMap")
assert(map, "no map after rebuild")
local lightingCounts = {}
for _, child in Lighting:GetChildren() do
	lightingCounts[child.ClassName] = (lightingCounts[child.ClassName] or 0) + 1
end
for className, n in lightingCounts do
	assert(n == 1, "Lighting has " .. n .. " " .. className)
end
print("Lighting children:", lightingCounts.Atmosphere, lightingCounts.SunRaysEffect, lightingCounts.BloomEffect, lightingCounts.ColorCorrectionEffect, lightingCounts.Sky)
print("Lighting", Lighting.ClockTime, Lighting.Brightness, Lighting.ExposureCompensation, Lighting.Ambient, Lighting.OutdoorAmbient)

----------------------------------------------------------------------
-- Part census
----------------------------------------------------------------------
local parts = {}
local counts = { total = 0, lights = 0, emitters = 0 }
for _, d in map:GetDescendants() do
	if d:IsA("BasePart") then
		table.insert(parts, d)
		counts.total += 1
	elseif d:IsA("PointLight") then
		counts.lights += 1
	elseif d:IsA("ParticleEmitter") then
		counts.emitters += 1
		local face = d.EmissionDirection
		local normals = {
			["Enum.NormalId.Top"] = Vector3.new(0, 1, 0), ["Enum.NormalId.Bottom"] = Vector3.new(0, -1, 0),
			["Enum.NormalId.Right"] = Vector3.new(1, 0, 0), ["Enum.NormalId.Left"] = Vector3.new(-1, 0, 0),
			["Enum.NormalId.Back"] = Vector3.new(0, 0, 1), ["Enum.NormalId.Front"] = Vector3.new(0, 0, -1),
		}
		local world = d.Parent.CFrame:VectorToWorldSpace(normals[tostring(face)])
		assert(world.Y > 0.99, "emitter " .. d:GetFullName() .. " does not emit upward: " .. tostring(world))
	end
	if d.Name == "UnlockPrompt" then
		error("UnlockPrompt found: " .. d:GetFullName())
	end
end
print("parts", counts.total, "pointlights", counts.lights, "emitters", counts.emitters)
assert(counts.total < 3500, "part budget exceeded")

local byModel = {}
for _, p in parts do
	local top = p
	while top.Parent and top.Parent ~= map and top.Parent.Name ~= "Zones" do
		top = top.Parent
	end
	byModel[top.Name] = (byModel[top.Name] or 0) + 1
end
for name, n in byModel do
	print("  ", name, n)
end

----------------------------------------------------------------------
-- Geometry helpers (exact for blocks/balls/cylinders; wedges as boxes)
----------------------------------------------------------------------
local function shapeOf(p)
	if p:IsA("Part") or p:IsA("SpawnLocation") then
		if p.Shape == Enum.PartType.Ball then
			return "Ball"
		elseif p.Shape == Enum.PartType.Cylinder then
			return "Cylinder"
		end
	end
	return "Block"
end

local function containsPoint(p, point: Vector3, pad: number?): boolean
	local margin = pad or 0
	local l = p.CFrame:PointToObjectSpace(point)
	local h = p.Size / 2
	local s = shapeOf(p)
	if s == "Ball" then
		return l.Magnitude < h.X + margin
	elseif s == "Cylinder" then
		local r = math.min(h.Y, h.Z)
		return math.abs(l.X) < h.X + margin and math.sqrt(l.Y * l.Y + l.Z * l.Z) < r + margin
	end
	return math.abs(l.X) < h.X + margin and math.abs(l.Y) < h.Y + margin and math.abs(l.Z) < h.Z + margin
end

-- Raycast straight down: returns first hit (part, y) among CanQuery parts.
local function raycastDown(origin: Vector3, length: number, exclude)
	local best, bestY = nil, -math.huge
	for _, p in parts do
		if p.CanQuery and not (exclude and exclude[p:GetFullName() .. tostring(p.CFrame.Position)]) then
			-- march (cheap + shape exact via containsPoint)
			local step = 0.05
			local y = origin.Y
			while y > origin.Y - length do
				if containsPoint(p, Vector3.new(origin.X, y, origin.Z)) then
					if y > bestY then
						best, bestY = p, y
					end
					break
				end
				y -= step
			end
		end
	end
	if not best and origin.Y > 0 and origin.Y - length < 0 then
		return "Terrain", 0
	end
	return best, bestY
end

local function collidersAt(point: Vector3, exclude)
	local hits = {}
	for _, p in parts do
		if p.CanCollide and not (exclude and exclude[p:GetFullName() .. tostring(p.CFrame.Position)]) and containsPoint(p, point) then
			table.insert(hits, p:GetFullName())
		end
	end
	return hits
end

----------------------------------------------------------------------
-- Terrain audit
----------------------------------------------------------------------
assert(fills[1].op == "Clear", "terrain not cleared first")
for _, f in fills do
	if f.op == "FillCylinder" then
		print(("  FillCylinder %s r=%g y=%g..%g"):format(tostring(f.mat), f.radius, f.cf.Position.Y - f.height / 2, f.cf.Position.Y + f.height / 2))
	elseif f.op == "FillBlock" then
		print(("  FillBlock %s size=%s y=%g..%g"):format(tostring(f.mat), tostring(f.size), f.cf.Position.Y - f.size.Y / 2, f.cf.Position.Y + f.size.Y / 2))
	elseif f.op == "FillBall" then
		local c = f.center
		local footprint = math.sqrt(math.max(0, f.radius ^ 2 - c.Y ^ 2))
		local ring = Vector3.new(c.X, 0, c.Z).Magnitude
		print(("  FillBall r=%g ring=%.1f angle=%.1f peak=%.1f footprint=%.1f (span %.1f..%.1f)"):format(
			f.radius, ring, math.deg(math.atan2(c.Z, c.X)) % 360, c.Y + f.radius, footprint, ring - footprint, ring + footprint))
		-- never on a pad / road: distance from footprint circle to each pad square
		for _, zone in GameConfig.Zones do
			local zcf = Mechanics.zoneGroundCFrame(zone.Order)
			local l = zcf:PointToObjectSpace(Vector3.new(c.X, 0, c.Z))
			local dx = math.max(0, math.abs(l.X) - 32)
			local dz = math.max(0, math.abs(l.Z) - 32)
			assert(math.sqrt(dx * dx + dz * dz) > footprint + 20, "hill too close to pad " .. zone.Id)
		end
		assert(ring - footprint > 125 and ring + footprint < 330, "hill leaves the grass band")
	end
end
print("Terrain props", realTerrain.Decoration, realTerrain.WaterColor, realTerrain.WaterTransparency, realTerrain.WaterWaveSize)

----------------------------------------------------------------------
-- Contract audit per zone
----------------------------------------------------------------------
local zonesFolder = map:FindFirstChild("Zones")
assert(map:FindFirstChild("Ground") and map.Ground:IsA("Model"), "Ground model")
assert(map:FindFirstChild("Plaza") and map.Plaza:IsA("Model"), "Plaza model")
for _, zone in GameConfig.Zones do
	local zm = zonesFolder:FindFirstChild(zone.Id)
	assert(zm and zm:IsA("Model") and zm:GetAttribute("ZoneId") == zone.Id, "zone model " .. zone.Id)
	local station = zm:FindFirstChild("HustleStation")
	assert(station and station:IsA("Model"), "station " .. zone.Id)
	local promptPart = station:FindFirstChild("PromptPart")
	local prompt = promptPart and promptPart:FindFirstChild("HustlePrompt")
	assert(prompt and prompt:IsA("ProximityPrompt"), "HustlePrompt " .. zone.Id)
	assert(prompt.ActionText == zone.HustleVerb .. "!" and prompt.ObjectText == zone.Name, "prompt text")
	assert(math.abs(prompt.HoldDuration - zone.HoldDuration) < 1e-4 and prompt.MaxActivationDistance == 12 and prompt.RequiresLineOfSight == false, "prompt cfg")
	for _, name in { "FeedbackPart", "AutoAnchor" } do
		local m = station:FindFirstChild(name)
		assert(m and m:IsA("BasePart"), name)
		assert(m.Transparency == 1 and not m.CanCollide and not m.CanQuery and not m.CanTouch, name .. " flags")
	end
	local zcf = Mechanics.zoneGroundCFrame(zone.Order) * CFrame.new(0, 1.5, 0)
	local feedback, anchor = station.FeedbackPart, station.AutoAnchor
	local lf = zcf:PointToObjectSpace(feedback.CFrame.Position)
	local la = zcf:PointToObjectSpace(anchor.CFrame.Position)
	local lp = zcf:PointToObjectSpace(promptPart.CFrame.Position)

	-- Anchor: emulate AutomationVisualsController.findFeetPosition
	local hit, hitY = raycastDown(anchor.CFrame.Position + Vector3.new(0, 2, 0), 12, { [anchor:GetFullName() .. tostring(anchor.CFrame.Position)] = true })
	local hitName = if typeof(hit) == "Instance" then hit.Name else tostring(hit)
	local feetLocalY = hitY - zcf.Position.Y
	-- Rig volume (2.2 wide, 4 tall) must be free of colliders
	local rigBlocked = {}
	for _, dy in { 0.5, 1.5, 2.85, 3.8 } do
		for _, off in { Vector3.new(0, 0, 0), Vector3.new(1, 0, 0), Vector3.new(-1, 0, 0), Vector3.new(0, 0, 1), Vector3.new(0, 0, -1) } do
			local pt = Vector3.new(anchor.CFrame.Position.X, hitY + dy, anchor.CFrame.Position.Z) + zcf:VectorToWorldSpace(off)
			for _, h in collidersAt(pt) do
				rigBlocked[h] = true
			end
		end
	end
	local blockedList = {}
	for h in rigBlocked do
		table.insert(blockedList, h)
	end

	-- Player stand point: 3.5 studs in front of the prompt toward the plaza
	local standLocal = Vector3.new(lp.X, 3, lp.Z - 3.5)
	local stand = zcf:PointToWorldSpace(standLocal)
	local standBlocked = collidersAt(stand)
	-- Path from the pad's front (inside the gate) to the stand point, 3 lanes
	local gateWall = zm:FindFirstChild("Gate") and zm.Gate:FindFirstChild("GateWall")
	local pathBlocked = {}
	for _, lane in { -1.2, 0, 1.2 } do
		local from = Vector3.new(lane, 3, -33)
		local to = standLocal + Vector3.new(lane, 0, 0)
		for k = 0, 100 do
			local pt = zcf:PointToWorldSpace(from:Lerp(to, k / 100))
			for _, h in collidersAt(pt, if gateWall then { [gateWall:GetFullName() .. tostring(gateWall.CFrame.Position)] = true } else nil) do
				pathBlocked[h] = true
			end
		end
	end
	local pathList = {}
	for h in pathBlocked do
		table.insert(pathList, h)
	end
	local dist = (stand - promptPart.CFrame.Position).Magnitude

	print(("%-16s prompt=(%.1f,%.1f,%.1f) feedback=(%.1f,%.1f,%.1f) anchor=(%.1f,%.1f,%.1f) anchorHit=%s@%.2f standDist=%.1f"):format(
		zone.Id, lp.X, lp.Y, lp.Z, lf.X, lf.Y, lf.Z, la.X, la.Y, la.Z, hitName, feetLocalY, dist))
	assert(hit ~= nil, "anchor raycast hit nothing")
	assert(math.abs(feetLocalY) < 0.6, zone.Id .. " anchor does not stand on the pad level: " .. hitName .. " " .. feetLocalY)
	assert(#blockedList == 0, zone.Id .. " rig volume blocked by " .. table.concat(blockedList, ", "))
	assert(#standBlocked == 0, zone.Id .. " stand point blocked by " .. table.concat(standBlocked, ", "))
	assert(#pathList == 0, zone.Id .. " path to prompt blocked by " .. table.concat(pathList, ", "))
	assert(dist < 12, zone.Id .. " prompt out of reach")

	local gate = zm:FindFirstChild("Gate")
	if zone.UnlockLevel > 1 then
		assert(gate, "gate missing " .. zone.Id)
		local wall = gate:FindFirstChild("GateWall")
		assert(wall and wall.CanCollide and wall.Transparency > 0 and wall.Transparency < 1 and wall.Color == zone.SignColor, "GateWall " .. zone.Id)
		local lw = zcf:PointToObjectSpace(wall.CFrame.Position)
		assert(lw.Z < -29 and math.abs(lw.X) < 0.01, "gate not at the plaza-facing entrance")
		print("   wall pos", wall.CFrame.Position, wall.CFrame.Position.Magnitude, Mechanics.zoneCenter(zone.Order), Mechanics.zoneCenter(zone.Order).Magnitude)
		assert(wall.CFrame.Position.Magnitude < Mechanics.zoneCenter(zone.Order).Magnitude, "gate not between plaza and zone")
		-- the opening (posts inner edges) covers the walkway
		local posts = 0
		for _, c in gate:GetChildren() do
			if c.Name == "GatePost" then
				posts += 1
				assert(c.Material == Enum.Material.Neon, "post neon")
			end
			assert(c.Name ~= "PromptPart" and not c:FindFirstChildOfClass("ProximityPrompt"), "prompt in gate")
		end
		assert(posts == 2, "posts")
		local sign = gate:FindFirstChild("SignPart")
		local bb = sign and sign:FindFirstChildOfClass("BillboardGui")
		assert(bb, "gate billboard")
		local texts = {}
		for _, d in bb:GetDescendants() do
			if d:IsA("TextLabel") then
				table.insert(texts, d.Text)
			end
		end
		local joined = table.concat(texts, " | ")
		assert(string.find(joined, zone.Name, 1, true) and string.find(joined, "Reach Level " .. zone.UnlockLevel, 1, true) and string.find(joined, "\u{1F512}", 1, true), "gate texts " .. joined)
		-- billboard bottom clears the sign part top
		assert(bb.StudsOffset.Y - bb.Size.Y.Scale / 2 > sign.Size.Y / 2, "billboard intersects SignPart")
		print("   gate:", joined, ("wall z=%.1f"):format(lw.Z))
	else
		assert(gate == nil, "starting zone must not have a gate")
	end
end

----------------------------------------------------------------------
-- Plaza + spawn
----------------------------------------------------------------------
local spawn = map.Plaza:FindFirstChild("SpawnLocation")
assert(spawn and spawn:IsA("SpawnLocation"), "spawn")
print("spawn", spawn.CFrame.Position, "look", spawn.CFrame.LookVector)
local spawnSelf = { [spawn:GetFullName() .. tostring(spawn.CFrame.Position)] = true }
-- spawn slab must not be buried: points just above its top surface are free
for _, dx in { -5.5, 0, 5.5 } do
	for _, dz in { -5.5, 0, 5.5 } do
		for _, dy in { 0.6, 2.5, 4.5 } do
			local pt = spawn.CFrame:PointToWorldSpace(Vector3.new(dx, 0.5 + dy, dz))
			local hits = collidersAt(pt, spawnSelf)
			assert(#hits == 0, "spawn standing volume blocked by " .. table.concat(hits, ", "))
		end
	end
end
-- spawn rests on the plaza floor
local below, belowY = raycastDown(spawn.CFrame.Position - Vector3.new(0, 0.6, 0), 3, spawnSelf)
print("spawn rests on", if typeof(below) == "Instance" then below.Name else below, belowY)
-- first view: nothing collidable between the spawn and the starting zone stand
local startZone = GameConfig.getZone(GameConfig.StartingZoneId)
local target = Mechanics.zoneCenter(startZone.Order) + Vector3.new(0, 6, 0)
local eye = spawn.CFrame.Position + Vector3.new(0, 5, 0)
local blockers = {}
for k = 1, 199 do
	local pt = eye:Lerp(target, k / 200)
	for _, p in parts do
		if p.Transparency < 0.9 and containsPoint(p, pt) and p.Name ~= "SpawnLocation" then
			blockers[p.Name] = true
		end
	end
end
local blockerList = {}
for n in blockers do
	table.insert(blockerList, n)
end
print("sightline spawn->start zone blocked by:", #blockerList == 0 and "nothing" or table.concat(blockerList, ", "))

-- no visible part pokes below terrain-only ground in a way that floats: report parts whose bottom > 0.05 above any support is skipped (visual)

----------------------------------------------------------------------
-- Decor placement: never on a pad, the road (except signposts) or a hill
----------------------------------------------------------------------
local hills = {}
for _, f in fills do
	if f.op == "FillBall" then
		table.insert(hills, { center = Vector3.new(f.center.X, 0, f.center.Z), footprint = math.sqrt(f.radius ^ 2 - f.center.Y ^ 2) })
	end
end
local decorCount = 0
for _, d in map.Ground:GetDescendants() do
	if d:IsA("BasePart") then
		decorCount += 1
		local pos = d.CFrame.Position
		local flat = Vector3.new(pos.X, 0, pos.Z)
		local r = flat.Magnitude
		assert(r < 360, d.Name .. " off the island at r=" .. r)
		if not string.find(d.Name, "Signpost", 1, true) then
			assert(r > 124, d.Name .. " on the road/plaza at r=" .. r)
		end
		for _, zone in GameConfig.Zones do
			local l = Mechanics.zoneGroundCFrame(zone.Order):PointToObjectSpace(flat)
			assert(not (math.abs(l.X) < 34 and math.abs(l.Z) < 34), d.Name .. " on pad " .. zone.Id)
		end
		for _, h in hills do
			assert((flat - h.center).Magnitude > h.footprint + 2, d.Name .. " inside a hill")
		end
	end
end
print("decor parts", decorCount, "all clear of pads/road/hills")

----------------------------------------------------------------------
-- Road: plaza edge -> pad front along every zone axis is walkable; gate
-- openings have nothing but the GateWall in them
----------------------------------------------------------------------
for _, zone in GameConfig.Zones do
	local zcf = Mechanics.zoneGroundCFrame(zone.Order)
	for _, lane in { -6, 0, 6 } do
		for z = -96, -33, 0.5 do -- local z -96 = radius 54 (plaza), -33 = just before the pad
			local pt = zcf:PointToWorldSpace(Vector3.new(lane, 3.5, z))
			local hits = collidersAt(pt)
			assert(#hits == 0, zone.Id .. " road blocked by " .. table.concat(hits, ", "))
		end
	end
	local gate = map.Zones[zone.Id]:FindFirstChild("Gate")
	if gate then
		local wall = gate.GateWall
		local own = {}
		for _, c in gate:GetChildren() do
			own[c:GetFullName() .. tostring(c.CFrame.Position)] = true
		end
		for x = -12, 12, 1 do
			for y = 0.5, 10.5, 1 do
				local pt = wall.CFrame:PointToWorldSpace(Vector3.new(x, y - 5.5, 0))
				local hits = collidersAt(pt, own)
				assert(#hits == 0, zone.Id .. " gate opening blocked by " .. table.concat(hits, ", "))
			end
		end
	end
end
print("roads + gate openings clear")

print("ALL MAP CHECKS PASSED")
