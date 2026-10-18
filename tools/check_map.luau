-- Map check: executes the REAL MapBuilder.build() inside Lune's Roblox datatype /
-- reflection layer (invalid properties or enum values throw), with a mocked
-- Terrain, then audits contract + geometry.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox") :: any

local REPO = require("@lune/process").cwd:gsub("/$", "")
local Instance, Vector3, CFrame, Enum = roblox.Instance, roblox.Vector3, roblox.CFrame, roblox.Enum
local Color3, Vector2 = roblox.Color3, roblox.Vector2

-- Lune 0.8.9 has no Model:GetPivot (the client city-life sim pivots CitySpin
-- models with it). Mirror Roblox: PrimaryPart's CFrame, else WorldPivot,
-- else the center of the model's parts' bounding box.
roblox.implementMethod("Model", "GetPivot", function(self)
	local primary = self.PrimaryPart
	if primary then
		return primary.CFrame
	end
	local ok, pivot = pcall(function()
		return self.WorldPivot
	end)
	if ok and pivot then
		return pivot
	end
	local lo, hi
	for _, d in self:GetDescendants() do
		if d:IsA("BasePart") then
			local p = d.CFrame.Position
			lo = if lo then lo:Min(p) else p
			hi = if hi then hi:Max(p) else p
		end
	end
	return if lo then roblox.CFrame.new((lo + hi) / 2) else roblox.CFrame.new()
end)

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
		local value = realTerrain[k]
		if type(value) == "function" then
			-- Methods (SetMaterialColor, GetMaterialColor, ...) run on the real
			-- Lune Terrain, which validates their arguments like Roblox.
			return function(_self, ...)
				return value(realTerrain, ...)
			end
		end
		return value
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
local MapKit = env.require(worldFolder.MapKit)

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
-- Budget: 7,000 exported parts in total (map + the client-life preview the
-- render export adds); the map itself must leave room for that life. Round-5
-- envelopes: map <= 4,400 (painted lane dashes, no beach palms), total
-- <= 6,930 (hard cap 7,000).
local MAP_ENVELOPE = 4400
assert(counts.total <= MAP_ENVELOPE, "map part envelope exceeded (" .. counts.total .. " > " .. MAP_ENVELOPE .. ")")

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

-- Coarse XZ grid of EVERY part (bucketed by bounding sphere) so point queries
-- only test nearby parts; results are identical to scanning all parts.
local CELL = 16
local grid = {}
local function cellKey(cx, cz)
	return cx * 100000 + cz
end
for _, p in parts do
	local pos = p.CFrame.Position
	local reach = p.Size.Magnitude / 2 + 0.01
	for cx = math.floor((pos.X - reach) / CELL), math.floor((pos.X + reach) / CELL) do
		for cz = math.floor((pos.Z - reach) / CELL), math.floor((pos.Z + reach) / CELL) do
			local key = cellKey(cx, cz)
			local bucket = grid[key]
			if not bucket then
				bucket = {}
				grid[key] = bucket
			end
			table.insert(bucket, p)
		end
	end
end
local EMPTY = {}
local function nearbyParts(point: Vector3): { any }
	return grid[cellKey(math.floor(point.X / CELL), math.floor(point.Z / CELL))] or EMPTY
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
	for _, p in nearbyParts(origin) do
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
	for _, p in nearbyParts(point) do
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
		-- zone-colored: the signature color (the AccentColor for a near-white one, MapKit.zoneSignFace)
		assert(wall and wall.CanCollide and wall.Transparency > 0 and wall.Transparency < 1 and wall.Color == MapKit.zoneSignFace(zone), "GateWall " .. zone.Id)
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
	for _, p in nearbyParts(pt) do
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

----------------------------------------------------------------------
-- City (SideHustleMap.City): never on a pad, no collider in any zone's
-- walkway corridor, nothing near the spawn, everything anchored
----------------------------------------------------------------------
local CityLayout = env.require(shared.CityLayout)
local city = map:FindFirstChild("City")
assert(city and city:IsA("Model"), "City model missing")

-- Visible parts (Transparency < 1) containing a point, optionally filtered.
local function partsAt(point: Vector3, filter): { any }
	local hits = {}
	for _, p in nearbyParts(point) do
		if p.Transparency < 1 and (not filter or filter(p)) and containsPoint(p, point) then
			table.insert(hits, p)
		end
	end
	return hits
end

local spawnPos = spawn.CFrame.Position
local cityCount, cityColliders = 0, 0
for _, d in city:GetDescendants() do
	if d:IsA("BasePart") then
		cityCount += 1
		assert(d.Anchored, d:GetFullName() .. " not anchored")
		if d.CanCollide then
			cityColliders += 1
		end
		local pos = d.CFrame.Position
		local flat = Vector3.new(pos.X, 0, pos.Z)
		for _, zone in GameConfig.Zones do
			local l = Mechanics.zoneGroundCFrame(zone.Order):PointToObjectSpace(flat)
			assert(not (math.abs(l.X) < 34 and math.abs(l.Z) < 34), d:GetFullName() .. " on pad " .. zone.Id)
		end
		local toSpawn = Vector3.new(pos.X - spawnPos.X, 0, pos.Z - spawnPos.Z).Magnitude
		assert(toSpawn > 12, d:GetFullName() .. " within 12 studs of the SpawnLocation")
	end
end
-- Corridor: zone-local |x| < 10 for z -96..-32 (plaza edge -> gate), body heights.
local function isCityCollider(p)
	return p.CanCollide and p:IsDescendantOf(city)
end
for _, zone in GameConfig.Zones do
	local zcf = Mechanics.zoneGroundCFrame(zone.Order)
	for x = -9.5, 9.5, 1 do
		for z = -96, -32, 1 do
			for _, y in { 1.2, 3, 5.5 } do
				local hits = partsAt(zcf:PointToWorldSpace(Vector3.new(x, y, z)), isCityCollider)
				assert(#hits == 0, zone.Id .. " walkway corridor blocked by " .. (hits[1] and hits[1]:GetFullName() or "?"))
			end
		end
	end
end
print(("city parts %d (colliders %d): clear of pads, corridors and spawn"):format(cityCount, cityColliders))

----------------------------------------------------------------------
-- City life paths (Shared/CityLayout): pedestrians and cars must find their
-- sidewalk loops, lanes and crosswalks free of every visible part
----------------------------------------------------------------------
local function pathBlockers(point: Vector3, heights: { number }): { string }
	local names = {}
	for _, h in heights do
		for _, p in partsAt(point + Vector3.new(0, h, 0)) do
			table.insert(names, p:GetFullName())
		end
	end
	return names
end
for _, loop in CityLayout.sidewalkLoops do
	for deg = 0, 359.5, 0.5 do
		local hits = pathBlockers(CityLayout.loopPoint(loop, deg), { 0.3, 1.5, 3, 4.5 })
		assert(#hits == 0, ("sidewalk loop %s blocked at %.1f deg by %s"):format(loop.name, deg, hits[1] or "?"))
	end
end
for _, loop in CityLayout.laneLoops do
	for deg = 0, 359.5, 0.5 do
		local hits = pathBlockers(CityLayout.loopPoint(loop, deg), { 0.3, 2, 4, 6 })
		assert(#hits == 0, ("lane %s blocked at %.1f deg by %s"):format(loop.name, deg, hits[1] or "?"))
	end
end
-- Back Avenue lanes (between the skyline rings): centerline + both lane
-- edges (+-4) free up to 6 studs.
for _, loop in CityLayout.backLaneLoops do
	for deg = 0, 359.5, 0.5 do
		local center = CityLayout.loopPoint(loop, deg)
		local outward = Vector3.new(center.X, 0, center.Z).Unit
		for _, side in { -4, 0, 4 } do
			local hits = pathBlockers(center + outward * side, { 0.3, 2, 4, 6 })
			assert(#hits == 0, ("back lane %s blocked at %.1f deg by %s"):format(loop.name, deg, hits[1] or "?"))
		end
		assert(math.abs(CityLayout.surfaceY(center) - loop.y) < 1e-6, "back lane " .. loop.name .. " not on the back asphalt")
	end
end
-- Back Avenue sidewalk loops: walker body extent (r +-1.45, h 0.3..4.9)
-- free of every visible part, on their stated surface.
for _, loop in CityLayout.backSidewalkLoops do
	for deg = 0, 359.75, 0.25 do
		local center = CityLayout.loopPoint(loop, deg)
		local outward = Vector3.new(center.X, 0, center.Z).Unit
		for _, side in { -1.45, 0, 1.45 } do
			local hits = pathBlockers(center + outward * side, { 0.3, 1.5, 3, 4.9 })
			assert(#hits == 0, ("back sidewalk %s blocked at %.2f deg by %s"):format(loop.name, deg, hits[1] or "?"))
		end
		assert(math.abs(CityLayout.surfaceY(center) - loop.y) < 1e-6, "back sidewalk " .. loop.name .. " not on its surface")
	end
end
for _, cw in CityLayout.crosswalks do
	for k = 0, 100 do
		local pt = cw.innerPoint:Lerp(cw.outerPoint, k / 100)
		for _, side in { -4, 0, 4 } do
			local lateral = Vector3.new(-cw.direction.Z, 0, cw.direction.X) * side
			local base = pt + lateral
			local hits = pathBlockers(Vector3.new(base.X, CityLayout.surfaceY(base), base.Z), { 0.6, 2, 4 })
			assert(#hits == 0, ("crosswalk %s blocked by %s"):format(cw.zoneId, hits[1] or "?"))
		end
	end
end
-- Rush-hour crosser lines (client CityLifeSim: 3 per zebra at laterals
-- -5 / 0 / +5, waiting on the plaza rim and in front of the gate): every line
-- at walker body extent (+-1.45, 0.5..4.9 above the surface, so the feet may
-- step over the 0.3-tall curbs) from the inner to the outer waiting spot,
-- sampled every 0.5 studs along, ~0.73 across and ~0.7 up.
do
	local LifeConfig = env.require(shared.CityLifeSim).Config
	for _, cw in CityLayout.crosswalks do
		local u = cw.direction
		local p = Vector3.new(-u.Z, 0, u.X)
		for m, side in LifeConfig.CrossLaterals do
			local outerR = LifeConfig.CrossOuterRadii[m]
			local r = LifeConfig.CrossInnerRadius
			while r <= outerR + 1e-6 do
				for _, dl in { -1.45, -0.725, 0, 0.725, 1.45 } do
					local base = u * r + p * (side + dl)
					local hits = pathBlockers(Vector3.new(base.X, CityLayout.surfaceY(base), base.Z), { 0.5, 1.2, 1.9, 2.6, 3.3, 4.0, 4.9 })
					assert(#hits == 0, ("crosser line %s lateral %+.1f blocked at r %.2f by %s"):format(cw.zoneId, side, r, hits[1] or "?"))
				end
				r += 0.5
			end
		end
	end
end
-- Plaza wander area: free points exist and a sample of them is really free.
local freeSamples, blockedSamples = 0, 0
for r = 15, 49, 2 do
	for deg = 0, 355, 5 do
		local pt = CityLayout.ringPos(r, deg, CityLayout.Street.PlazaTop)
		if CityLayout.isPlazaPointFree(pt, 1.5) then
			freeSamples += 1
			local hits = pathBlockers(pt, { 0.6, 2, 4 })
			if #hits > 0 then
				blockedSamples += 1
				print("  plaza point free in CityLayout but blocked by", hits[1], pt)
			end
		end
	end
end
assert(freeSamples > 200, "plaza wander area too small: " .. freeSamples)
assert(blockedSamples == 0, "CityLayout.plazaObstacles misses " .. blockedSamples .. " blocked plaza points")
-- Café seats: a stool top right under every seat point, head room above it.
for i, seat in CityLayout.cafeSeats do
	local under = partsAt(seat.position - Vector3.new(0, 0.1, 0))
	local hasStool = false
	for _, p in under do
		if p.Name == "CafeStool" then
			hasStool = true
		end
	end
	assert(hasStool, "cafe seat " .. i .. " has no stool under it")
	local above = pathBlockers(seat.position, { 0.2, 1.5, 3, 4.5 })
	assert(#above == 0, "cafe seat " .. i .. " head room blocked by " .. (above[1] or "?"))
	assert(math.abs(seat.facing.Magnitude - 1) < 1e-4 and math.abs(seat.facing.Y) < 1e-6, "cafe seat facing")
end
print(("life paths clear: %d sidewalk loops, %d back sidewalk loops, %d lanes, %d back lanes, %d crosswalks (+ 3 crosser lines each), plaza %d free samples, %d cafe seats"):format(
	#CityLayout.sidewalkLoops, #CityLayout.backSidewalkLoops, #CityLayout.laneLoops, #CityLayout.backLaneLoops, #CityLayout.crosswalks, freeSamples, #CityLayout.cafeSeats))

----------------------------------------------------------------------
-- Rowhouse infill never cuts into its skyline neighbours, and every
-- CitySpin model pivots on its own parts (the client sim spins about it)
----------------------------------------------------------------------
local skylineModel = city:FindFirstChild("Skyline")
for _, spec in CityLayout.rowhouses do
	local model = skylineModel and skylineModel:FindFirstChild(spec.name)
	assert(model and model:FindFirstChild("Body"), "rowhouse " .. spec.name .. " missing")
	local body = model.Body
	local own = { [body:GetFullName() .. tostring(body.CFrame.Position)] = true }
	local h = body.Size / 2
	for _, x in { -1, -0.5, 0, 0.5, 1 } do
		for _, z in { -1, -0.5, 0, 0.5, 1 } do
			for _, y in { -0.9, 0, 0.9 } do
				local pt = body.CFrame:PointToWorldSpace(Vector3.new(x * (h.X - 0.05), y * h.Y, z * (h.Z - 0.05)))
				local hits = collidersAt(pt, own)
				assert(#hits == 0, spec.name .. " body overlaps " .. table.concat(hits, ", "))
			end
		end
	end
end
-- Painted windows: faces seen only from >= 150 studs carry SurfaceGui
-- "Windows" (lit, painted Frames) instead of part bands; the mid-ring backs
-- carry a "Mural" panel instead of WindowBandBack parts.
local function guiOn(part, name, face)
	for _, g in part:GetChildren() do
		if g:IsA("SurfaceGui") and g.Name == name and g.Face == face then
			return g
		end
	end
	return nil
end
local outerCount, midCount, paintedGuis = 0, 0, 0
for _, spec in CityLayout.skyline do
	local model = skylineModel:FindFirstChild(spec.name)
	assert(model and model:FindFirstChild("Body"), "skyline building " .. spec.name .. " missing")
	if spec.ring == "Outer" and not spec.hero then
		outerCount += 1
		for _, d in model:GetDescendants() do
			assert(not (d:IsA("BasePart") and (d.Name == "WindowBand" or d.Name == "WindowBandSide")),
				spec.name .. " still has a part window band " .. d.Name)
		end
		for _, face in { Enum.NormalId.Front, Enum.NormalId.Left, Enum.NormalId.Right } do
			local gui = guiOn(model.Body, "Windows", face)
			assert(gui and gui.LightInfluence == 1 and #gui:GetChildren() > 0, spec.name .. " has no painted Windows on " .. tostring(face))
			paintedGuis += 1
		end
	elseif spec.ring == "Mid" then
		midCount += 1
		for _, d in model:GetDescendants() do
			assert(not (d:IsA("BasePart") and (d.Name == "WindowBandBack" or d.Name == "WindowBandSide")),
				spec.name .. " still has a part " .. d.Name)
		end
		local mural = guiOn(model.Body, "Mural", Enum.NormalId.Back)
		local panel = mural and mural:FindFirstChild("Panel")
		assert(panel and panel:FindFirstChildOfClass("TextLabel"), spec.name .. " has no back Mural panel + slogan")
		-- the panel starts above the BackAwning / BackDoor (y >= 11)
		local bottomY = spec.height * (1 - panel.Position.Y.Scale - panel.Size.Y.Scale)
		assert(bottomY >= 10.99, spec.name .. " mural panel reaches down to y " .. bottomY)
		for _, face in { Enum.NormalId.Left, Enum.NormalId.Right } do
			assert(guiOn(model.Body, "Windows", face), spec.name .. " has no painted side Windows")
			paintedGuis += 1
		end
	end
end
assert(outerCount == 18 and midCount == 24, "skyline counts " .. outerCount .. " / " .. midCount)
-- Boulevard: 24 tall lamps (8 gap + 16 zone lamps), every one with a bar + 2 banners
local lampPoles, banners, bannerBars, tallLamps = 0, 0, 0, 0
for _, item in CityLayout.streetFurniture do
	if item.kind == "Lamp" then
		tallLamps += 1
		assert(item.bannerZones and GameConfig.getZone(item.bannerZones[1]) and GameConfig.getZone(item.bannerZones[2]), "tall lamp without banner zones")
	end
end
for _, d in city.Furniture:GetDescendants() do
	if d:IsA("BasePart") then
		if d.Name == "LampPole" then
			lampPoles += 1
		elseif d.Name == "Banner" then
			banners += 1
			assert(not d.CanCollide and not d.CastShadow, "banner flags")
		elseif d.Name == "BannerBar" then
			bannerBars += 1
		end
	end
end
assert(tallLamps == 24 and lampPoles == 24 and bannerBars == 24 and banners == 48,
	("tall lamps %d, poles %d, bars %d, banners %d"):format(tallLamps, lampPoles, bannerBars, banners))
print(("painted windows on %d faces (18 outer + 24 mid buildings), 24 back murals, %d banner lamps"):format(paintedGuis, tallLamps))

----------------------------------------------------------------------
-- Round 5: painted lane dashes, cobalt street hardware, zone-colored
-- entrance lamps, sign hierarchy, café terrace rugs, the spawn START mat
----------------------------------------------------------------------
local function near(a, b, tol)
	return math.abs(a.R - b.R) <= tol and math.abs(a.G - b.G) <= tol and math.abs(a.B - b.B) <= tol
end
local function luminance(c)
	return 0.299 * c.R + 0.587 * c.G + 0.114 * c.B
end
-- (1) No dash / palm parts are left: every lane dash is painted.
for _, d in map:GetDescendants() do
	if d:IsA("BasePart") then
		assert(d.Name ~= "LaneDash" and d.Name ~= "CenterDash" and d.Name ~= "BackDash", "dash part left: " .. d:GetFullName())
		assert(string.sub(d.Name, 1, 4) ~= "Palm", "palm part left: " .. d:GetFullName())
		if d.Name == "LampPole" or d.Name == "LampBase" then
			assert(d.Material ~= Enum.Material.Metal, d:GetFullName() .. " is Metal (street hardware is SmoothPlastic)")
		end
	end
end
-- (2) 16 decks, one lit "Markings" gui each on a face pointing straight up;
-- every OLD dash center (re-derived here from the round-4 layout: per gap
-- bisector g, g + 6j for j = -2..2 unless within 9 deg of a zone axis, at
-- r 75.5 / 85 / 94.5; Back Avenue every 5 deg at r 260) has exactly one
-- painted frame centered within 0.05 studs (XZ), along the same tangent,
-- with the same size and color.
local FACE_NORMAL = {
	Front = Vector3.new(0, 0, -1), Back = Vector3.new(0, 0, 1),
	Top = Vector3.new(0, 1, 0), Bottom = Vector3.new(0, -1, 0),
	Right = Vector3.new(1, 0, 0), Left = Vector3.new(-1, 0, 0),
}
local paintedDashes = {}
local function collectDecks(prefix: string): number
	local street = city:FindFirstChild("Street")
	local decks, frames = 0, 0
	for k = 1, 8 do
		local deck = street and street:FindFirstChild(prefix .. k)
		assert(deck and deck:IsA("BasePart"), prefix .. k .. " missing")
		assert(deck.Transparency == 1 and not deck.CanCollide and not deck.CanQuery and not deck.CanTouch and not deck.CastShadow and deck.Anchored, prefix .. k .. " flags")
		local guis = {}
		for _, g in deck:GetChildren() do
			if g:IsA("SurfaceGui") then
				table.insert(guis, g)
			end
		end
		assert(#guis == 1 and guis[1].Name == "Markings", prefix .. k .. " must carry exactly one Markings SurfaceGui")
		local gui = guis[1]
		assert(gui.LightInfluence == 1, prefix .. k .. " Markings must be lit (LightInfluence 1)")
		assert(gui.Face == Enum.NormalId.Back, prefix .. k .. " paints its Back face (side-face orientation is unambiguous)")
		local normal = deck.CFrame:VectorToWorldSpace(FACE_NORMAL[gui.Face.Name])
		assert(normal.Y > 0.9999, prefix .. k .. " painted face does not point up")
		-- Back face: gui x -> part +X, gui y (down) -> part -Y; face = X x Y studs
		local pps = gui.PixelsPerStud
		local W, H = deck.Size.X * pps, deck.Size.Y * pps
		for _, f in gui:GetChildren() do
			if f:IsA("Frame") then
				frames += 1
				assert(f.AnchorPoint == Vector2.new(0.5, 0.5) and f.BorderSizePixel == 0, f.Name .. " anchor / border")
				local cx = f.Position.X.Scale * W + f.Position.X.Offset
				local cy = f.Position.Y.Scale * H + f.Position.Y.Offset
				local sw = (f.Size.X.Scale * W + f.Size.X.Offset) / pps
				local sh = (f.Size.Y.Scale * H + f.Size.Y.Offset) / pps
				local center = deck.CFrame:PointToWorldSpace(Vector3.new(cx / pps - deck.Size.X / 2, deck.Size.Y / 2 - cy / pps, deck.Size.Z / 2))
				local th = math.rad(f.Rotation)
				local dir = deck.CFrame:VectorToWorldSpace(Vector3.new(math.cos(th), -math.sin(th), 0))
				assert(cx - sw * pps / 2 >= -1 and cx + sw * pps / 2 <= W + 1 and cy >= 0 and cy <= H, prefix .. k .. " frame off its deck")
				table.insert(paintedDashes, { center = center, dir = dir, w = sw, h = sh, color = f.BackgroundColor3, deck = prefix .. k })
			end
		end
		decks += 1
	end
	assert(decks == 8)
	return frames
end
local ringFrames = collectDecks("MarkingDeck")
local backFrames = collectDecks("BackMarkingDeck")
assert(ringFrames == 120 and backFrames == 72, ("painted dashes: %d ring (want 120), %d back (want 72)"):format(ringFrames, backFrames))
local oldDashes = {}
local YELLOW, LANE_WHITE = Color3.fromRGB(255, 214, 50), Color3.fromRGB(250, 250, 250)
for _, g in CityLayout.gapAngles do
	for j = -2, 2 do
		local a = g + j * 6
		local nearAxis = false
		for i = 1, #GameConfig.Zones do
			if math.abs((a - (i - 1) * 45 + 180) % 360 - 180) < 9 then
				nearAxis = true
			end
		end
		if not nearAxis then
			for _, line in { { 85, YELLOW }, { 75.5, LANE_WHITE }, { 94.5, LANE_WHITE } } do
				table.insert(oldDashes, { cf = CityLayout.facingCFrame(line[1], a, 0.6), w = 5, h = 0.8, color = line[2] })
			end
		end
	end
end
for i = 0, 71 do
	table.insert(oldDashes, { cf = CityLayout.facingCFrame(260, i * 5, 0.13), w = 4, h = 0.5, color = YELLOW })
end
assert(#oldDashes == 192, "old dash count " .. #oldDashes)
for _, old in oldDashes do
	local p = old.cf.Position
	local matches = 0
	for _, f in paintedDashes do
		local d = Vector3.new(f.center.X - p.X, 0, f.center.Z - p.Z).Magnitude
		if d < 0.05 then
			matches += 1
			assert(math.abs(f.dir:Dot(old.cf.RightVector)) > 0.9999, f.deck .. " dash at " .. tostring(p) .. " is not along its tangent")
			assert(math.abs(f.w - old.w) < 1e-3 and math.abs(f.h - old.h) < 1e-3, f.deck .. " dash size")
			assert(near(f.color, old.color, 1 / 255), f.deck .. " dash color")
			assert(f.center.Y > p.Y and f.center.Y - p.Y < 0.1, f.deck .. " dash paint height " .. f.center.Y)
		end
	end
	assert(matches == 1, ("old dash at %s has %d painted frames"):format(tostring(p), matches))
end
print(("painted dashes: %d ring + %d Back Avenue frames on 16 decks match all 192 old dash parts"):format(ringFrames, backFrames))

-- (3) Street hardware: cobalt SmoothPlastic, yellow signal heads, nothing near-black.
local HARDWARE = {
	SignalPole = true, SignalArm = true, SignalHanger = true, SignalBase = true, LampBase = true, LampPole = true,
	LampArm = true, BannerBar = true, BillboardLeg = true, RoofSignLeg = true, BusPost = true, BusBenchLeg = true,
	BusSignPole = true, CartLeg = true, UmbrellaPole = true, BalloonWeight = true, BalloonPole = true, IconPole = true,
}
local hardware, heads = 0, 0
for _, d in map:GetDescendants() do
	if d:IsA("BasePart") then
		if HARDWARE[d.Name] then
			hardware += 1
			assert(luminance(d.Color) > 0.25, d:GetFullName() .. " is near-black street hardware " .. tostring(d.Color))
		elseif d.Name == "SignalHead" then
			heads += 1
			assert(near(d.Color, Color3.fromRGB(255, 200, 40), 1 / 255), d:GetFullName() .. " signal head must be cartoon yellow")
		elseif d.Name == "TreeTrunk" then
			assert(d.Material == Enum.Material.SmoothPlastic and luminance(d.Color) > 0.4, d:GetFullName() .. " trunk too dark")
		end
	end
end
assert(heads == 8, "signal heads " .. heads)
-- (4) Every zone entrance is framed by two EntranceLamp models in its own color.
local NAVY = MapKit.NAVY
for _, zone in GameConfig.Zones do
	local zm = zonesFolder[zone.Id]
	local want = MapKit.zoneSignFace(zone):Lerp(NAVY, 0.15)
	local lamps = 0
	for _, c in zm:GetChildren() do
		if c:IsA("Model") and c.Name == "EntranceLamp" then
			lamps += 1
			local pole = c:FindFirstChild("LampPole")
			assert(pole and near(pole.Color, want, 2 / 255), zone.Id .. " EntranceLamp pole is not its zone color")
			assert(c:FindFirstChild("LampBase") and c:FindFirstChild("LampBulb"), zone.Id .. " EntranceLamp parts")
			local l = Mechanics.zoneGroundCFrame(zone.Order):PointToObjectSpace(pole.CFrame.Position)
			assert(math.abs(math.abs(l.X) - 16) < 0.01 and math.abs(l.Z + 35) < 0.01, zone.Id .. " EntranceLamp moved")
		end
	end
	assert(lamps == 2, zone.Id .. " has " .. lamps .. " EntranceLamps")
end
print(("street hardware: %d cobalt parts, %d yellow signal heads, zone-colored entrance lamps on all %d zones"):format(hardware, heads, #GameConfig.Zones))

-- (5) Sign hierarchy: every anchor (zone) board is 40 x 11.5, larger than
-- every shop billboard (20 x 8.5), and no shop billboard shares a hue with
-- either neighbouring zone (>= 25 deg apart).
local function hueOf(c): number
	local h = c:ToHSV()
	return h * 360
end
local function hueGap(a, b): number
	local d = math.abs(hueOf(a) - hueOf(b)) % 360
	return math.min(d, 360 - d)
end
local anchorsModel = city:FindFirstChild("Anchors")
for _, zone in GameConfig.Zones do
	local board = anchorsModel["Anchor" .. zone.Id]:FindFirstChild("AnchorSign")
	assert(board and math.abs(board.Size.X - 40) < 1e-3 and math.abs(board.Size.Y - 11.5) < 1e-3, zone.Id .. " AnchorSign must be 40 x 11.5")
end
local billboards = 0
for _, spec in CityLayout.shops do
	if spec.kind == "B" then
		local model = city.Shops:FindFirstChild("Shop" .. spec.name:gsub(" ", ""))
		local board = model and model:FindFirstChild("Billboard")
		assert(board and math.abs(board.Size.X - 20) < 1e-3 and math.abs(board.Size.Y - 8.5) < 1e-3, spec.name .. " billboard must be 20 x 8.5")
		local zA = GameConfig.Zones[spec.gapIndex]
		local zB = GameConfig.Zones[spec.gapIndex % #GameConfig.Zones + 1]
		for _, z in { zA, zB } do
			local gap = hueGap(board.Color, MapKit.zoneSignFace(z))
			assert(gap >= 25, ("%s billboard hue is %.0f deg from neighbouring zone %s"):format(spec.name, gap, z.Id))
		end
		billboards += 1
	end
end
assert(billboards == 8, "billboards " .. billboards)
print("sign hierarchy: 8 zone boards 40 x 11.5, 8 shop billboards 20 x 8.5, none in a neighbouring zone's hue")

-- (6) Café terrace rugs: one flat non-colliding checkered slab per Shop A,
-- under both tables and all 4 stools, clear of the door / shopper lane,
-- the gap-tree planters, the outer curb, the walker band and the crossers.
local terraces = 0
local LifeCfg = env.require(shared.CityLifeSim).Config
for _, t in CityLayout.cafeTerraces do
	local gapModel = city.GapBlocks:FindFirstChild("Gap" .. t.gapIndex)
	local slab
	for _, c in gapModel:GetChildren() do
		if c.Name == "CafeTerrace" and (c.CFrame.Position - t.cframe.Position).Magnitude < 1e-3 then
			slab = c
		end
	end
	assert(slab, "CafeTerrace missing in gap " .. t.gapIndex)
	terraces += 1
	assert(not slab.CanCollide and not slab.CanQuery and not slab.CastShadow, "CafeTerrace flags")
	local top = slab.CFrame.Position.Y + slab.Size.Y / 2
	assert(top <= 0.3 + 1e-6 and slab.CFrame.Position.Y - slab.Size.Y / 2 >= 0.2 - 1e-6, "CafeTerrace height " .. top)
	local checker = slab:FindFirstChild("Checker")
	assert(checker and checker:IsA("SurfaceGui") and checker.Face == Enum.NormalId.Top and #checker:GetChildren() >= 19, "CafeTerrace checker gui")
	local shopCF
	for _, spec in CityLayout.shops do
		if spec.kind == "A" and spec.gapIndex == t.gapIndex then
			shopCF = spec.cframe
		end
	end
	-- corners: outside the outer curb (r 122.5) and the walker band, away from every crosser line
	for _, sx in { -0.5, 0.5 } do
		for _, sz in { -0.5, 0.5 } do
			local corner = slab.CFrame:PointToWorldSpace(Vector3.new(sx * slab.Size.X, 0, sz * slab.Size.Z))
			local flat = Vector3.new(corner.X, 0, corner.Z)
			assert(flat.Magnitude > CityLayout.Street.OuterCurbRadius + 0.3, "CafeTerrace reaches the outer curb")
			for _, cw in CityLayout.crosswalks do
				local lateral = math.abs(-flat.X * cw.direction.Z + flat.Z * cw.direction.X)
				for _, lane in LifeCfg.CrossLaterals do
					assert(math.abs(lateral - math.abs(lane)) > 3 or flat:Dot(cw.direction) < 0, "CafeTerrace near a crosser line")
				end
			end
			local l = shopCF:PointToObjectSpace(corner)
			assert(l.X <= 5 + 1e-3, "CafeTerrace enters the door / shopper lane (shop-local x " .. l.X .. ")")
			assert(math.abs(l.X) <= CityLayout.GapTreeX.A - 2.25 + 1e-3, "CafeTerrace under a gap-tree planter")
		end
	end
	for _, seat in CityLayout.cafeSeats do
		if seat.gapIndex == t.gapIndex then
			local l = slab.CFrame:PointToObjectSpace(seat.position)
			assert(math.abs(l.X) < slab.Size.X / 2 - 0.8 and math.abs(l.Z) < slab.Size.Z / 2 - 0.8, "café stool off its terrace")
		end
	end
	local spot = CityLayout.storefronts
	for _, sf in spot do
		local l = slab.CFrame:PointToObjectSpace(sf.position)
		assert(math.abs(l.X) > slab.Size.X / 2 + 1 or math.abs(l.Z) > slab.Size.Z / 2 + 1, "CafeTerrace under a window-shopper spot")
	end
end
assert(terraces == 8, "terraces " .. terraces)
print("café terraces: 8 checkered rugs under every café, clear of the curb, door lanes, trees and crossers")

-- (7) The spawn START mat: painted on an invisible deck lying on the slab,
-- its gui up pointing at the starting zone; the slab itself is unchanged.
do
	assert(spawn.Size == Vector3.new(12, 1, 12) and spawn.Neutral and spawn.Duration == 0, "SpawnLocation changed")
	local deck = map.Plaza:FindFirstChild("SpawnWelcomeMat")
	assert(deck and deck.Transparency == 1 and not deck.CanCollide and not deck.CanQuery and not deck.CanTouch, "SpawnWelcomeMat deck flags")
	local gui = deck:FindFirstChild("WelcomeMat")
	assert(gui and gui:IsA("SurfaceGui"), "WelcomeMat gui")
	local normal = deck.CFrame:VectorToWorldSpace(FACE_NORMAL[gui.Face.Name])
	assert(normal.Y > 0.9999, "WelcomeMat does not face up")
	local guiUp = deck.CFrame:VectorToWorldSpace(Vector3.new(0, 1, 0)) -- Back face: gui up = part +Y
	local toZone = (Mechanics.zoneCenter(startZone.Order) - spawn.CFrame.Position) * Vector3.new(1, 0, 1)
	assert(guiUp:Dot(toZone.Unit) > 0.999, "WelcomeMat's up does not point at the starting zone")
	local slabTop = spawn.CFrame.Position.Y + spawn.Size.Y / 2
	assert(deck.CFrame.Position.Y > slabTop and deck.CFrame.Position.Y < slabTop + 0.1, "WelcomeMat deck height")
	local mat = gui:FindFirstChild("Mat")
	local label = mat and mat:FindFirstChildOfClass("TextLabel")
	assert(label and label.Text == "START" and label.Position.Y.Scale >= 0.5, "START must sit in the half nearer the fountain")
	local chevrons = 0
	for _, c in mat:GetChildren() do
		if c.Name == "Chevron" then
			chevrons += 1
			assert(c.Position.Y.Scale < 0.5, "chevron must sit in the far half")
		end
	end
	assert(chevrons == 2, "chevron bars " .. chevrons)
	print("spawn START mat painted, up toward", startZone.Id)
end

local spinModels = 0
for _, d in map:GetDescendants() do
	local rate = d:GetAttribute("CitySpin")
	if rate ~= nil then
		assert(type(rate) == "number" and rate ~= 0, d:GetFullName() .. " CitySpin must be a non-zero number")
		if d:IsA("Model") then
			spinModels += 1
			local pivot = d:GetPivot().Position
			local nearest = math.huge
			for _, p in d:GetDescendants() do
				if p:IsA("BasePart") then
					nearest = math.min(nearest, (p.CFrame.Position - pivot).Magnitude)
				end
			end
			assert(nearest < 12, d:GetFullName() .. " CitySpin pivot is " .. nearest .. " studs from its parts")
		end
	end
end
-- A full turn of every CitySpin model never sweeps through a neighbouring
-- part: a sample point of a spinning part may sit inside another visible part
-- at ALL angles (it rests on it: coin on its column, bun on the roof cap) but
-- never at only some of them. Nor through the blimp's path: a torus around
-- r 250, y 120 with a 12-stud tube (the blimp's 9-stud half height incl. fins
-- + margin), so the rooftop cranes can never swing into it.
local BLIMP_RING = { radius = 250, y = 120, tube = 12 }
local function inBlimpPath(pt: Vector3): boolean
	local dr = Vector3.new(pt.X, 0, pt.Z).Magnitude - BLIMP_RING.radius
	local dy = pt.Y - BLIMP_RING.y
	return dr * dr + dy * dy < BLIMP_RING.tube * BLIMP_RING.tube
end
local function shapeSamples(p)
	local pts = {}
	local h = p.Size / 2
	local s = shapeOf(p)
	if s == "Cylinder" then
		local r = math.min(h.Y, h.Z)
		for _, x in { -h.X, 0, h.X } do
			for a = 0, 330, 30 do
				table.insert(pts, p.CFrame:PointToWorldSpace(Vector3.new(x, math.cos(math.rad(a)) * r, math.sin(math.rad(a)) * r)))
			end
		end
	elseif s == "Ball" then
		for a = 0, 330, 30 do
			for _, e in { -60, -30, 0, 30, 60 } do
				local ce = math.cos(math.rad(e))
				table.insert(pts, p.CFrame:PointToWorldSpace(Vector3.new(math.cos(math.rad(a)) * ce, math.sin(math.rad(e)), math.sin(math.rad(a)) * ce) * h.X))
			end
		end
	else
		for _, x in { -1, 0, 1 } do
			for _, y in { -1, 0, 1 } do
				for _, z in { -1, 0, 1 } do
					table.insert(pts, p.CFrame:PointToWorldSpace(Vector3.new(x * h.X, y * h.Y, z * h.Z)))
				end
			end
		end
	end
	return pts
end
for _, d in map:GetDescendants() do
	if d:IsA("Model") and d:GetAttribute("CitySpin") then
		local pivot = d:GetPivot().Position
		local neighbours = {}
		for _, o in d.Parent:GetDescendants() do
			if o:IsA("BasePart") and not o:IsDescendantOf(d) and o.Transparency < 1 and (o.CFrame.Position - pivot).Magnitude < 45 then
				table.insert(neighbours, o)
			end
		end
		for _, p in d:GetDescendants() do
			if p:IsA("BasePart") then
				for _, pt in shapeSamples(p) do
					local rel = pt - pivot
					for deg = 0, 355, 5 do
						local swept = pivot + CFrame.Angles(0, math.rad(deg), 0):VectorToWorldSpace(rel)
						assert(not inBlimpPath(swept), ("%s: spinning %s swings into the blimp path"):format(d:GetFullName(), p.Name))
					end
					for _, o in neighbours do
						local inside = 0
						for deg = 0, 355, 5 do
							if containsPoint(o, pivot + CFrame.Angles(0, math.rad(deg), 0):VectorToWorldSpace(rel)) then
								inside += 1
							end
						end
						assert(inside == 0 or inside == 72, ("%s: spinning %s sweeps through %s"):format(d:GetFullName(), p.Name, o.Name))
					end
				end
			end
		end
	end
end
print(("rowhouses clear of their neighbours (%d); %d CitySpin models pivot on their parts and sweep clear"):format(#CityLayout.rowhouses, spinModels))

----------------------------------------------------------------------
-- SurfaceGui budget (the map is not streamed: every client holds every
-- gui). Every gui is drawn to its category's range (MapKit.GUI_RANGE): only
-- the landmarks (zone anchor boards, the plaza title billboard, the hero-
-- tower billboards) are unlimited. The total texture size (face studs^2 x
-- PixelsPerStud^2, summed) stays within budget. It was 9.18 M texels before
-- the density pass, 5.47 M after it.
----------------------------------------------------------------------
do
	local RANGE = MapKit.GUI_RANGE
	local TEXEL_BUDGET = 5.6e6
	local function expectedRange(gui, part)
		if part.Name == "AnchorSign" or part.Name == "BillboardBoard"
			or (part.Name == "Billboard" and part.Parent and string.sub(part.Parent.Name, 1, 9) == "HeroTower") then
			return RANGE.Landmark, "Landmark"
		elseif gui.Name == "Windows" or part.Name == "RoofSign" then
			return RANGE.Skyline, "Skyline"
		elseif gui.Name == "Mural" then
			return RANGE.Mural, "Mural"
		elseif gui.Name == "Markings" or gui.Name == "Checker" or gui.Name == "WelcomeMat" then
			return RANGE.Ground, "Ground"
		end
		return RANGE.Sign, "Sign"
	end
	local texels, guis, landmarks = 0, 0, 0
	local perClass = {}
	for _, gui in map:GetDescendants() do
		if gui:IsA("SurfaceGui") then
			guis += 1
			local part = gui.Adornee or gui.Parent
			assert(part and part:IsA("BasePart"), gui:GetFullName() .. " is not on a part")
			local want, class = expectedRange(gui, part)
			assert(gui.MaxDistance == want, ("%s MaxDistance %s, want %s (%s)"):format(gui:GetFullName(), tostring(gui.MaxDistance), tostring(want), class))
			if want == 0 then
				landmarks += 1
			end
			local w, h = MapKit.faceSize(part, gui.Face)
			local t = w * h * gui.PixelsPerStud * gui.PixelsPerStud
			texels += t
			perClass[class] = (perClass[class] or 0) + t
			-- a lowered texture density never leaves a sub-pixel text outline
			for _, stroke in gui:GetDescendants() do
				if stroke:IsA("UIStroke") and stroke.Parent:IsA("TextLabel") then
					assert(stroke.Thickness >= 2, stroke:GetFullName() .. " outline " .. stroke.Thickness .. " px")
				end
			end
		end
	end
	assert(landmarks == 11, "unlimited-range landmark guis: " .. landmarks .. " (want 8 anchors + title + 2 hero billboards)")
	assert(texels <= TEXEL_BUDGET, ("SurfaceGui texels %.2f M > budget %.2f M"):format(texels / 1e6, TEXEL_BUDGET / 1e6))
	local classes = {}
	for class, t in perClass do
		table.insert(classes, ("%s %.2f M"):format(class, t / 1e6))
	end
	table.sort(classes)
	print(("surface guis: %d, %.2f M texels (budget %.1f M; %s), %d unlimited landmarks"):format(
		guis, texels / 1e6, TEXEL_BUDGET / 1e6, table.concat(classes, ", "), landmarks))
end

----------------------------------------------------------------------
-- No flicker: no two visible parts of different color (or material) have
-- overlapping flat faces with the same outward normal less than 0.02
-- studs apart where the overlap is exposed (a probe 0.03 out along the
-- normal is inside no other opaque part and above the ground). Roblox
-- z-fights such faces. Offset one by >= 0.03, or shrink it.
-- Faces: blocks (6), cylinder end caps (16-gons), wedge back / bottom /
-- sides.
----------------------------------------------------------------------
do
	local EPS, MIN_AREA = 0.02, 0.005
	local visible, opaque = {}, {}
	for _, p in parts do
		if p.Transparency < 1 then
			table.insert(visible, p)
		end
		if p.Transparency < 0.5 then
			table.insert(opaque, p)
		end
	end
	local function kindOf(p)
		if p:IsA("WedgePart") then
			return "Wedge"
		elseif p:IsA("Part") or p:IsA("SpawnLocation") then
			return shapeOf(p)
		end
		return "Other"
	end
	local faces = {}
	for _, p in visible do
		local kind = kindOf(p)
		local cf, s = p.CFrame, p.Size
		local hx, hy, hz = s.X / 2, s.Y / 2, s.Z / 2
		local function W(x, y, z)
			return cf:PointToWorldSpace(Vector3.new(x, y, z))
		end
		local function add(n, poly)
			table.insert(faces, { n = n, d = n:Dot(poly[1]), poly = poly, part = p })
		end
		if kind == "Block" then
			add(cf.RightVector, { W(hx, -hy, -hz), W(hx, hy, -hz), W(hx, hy, hz), W(hx, -hy, hz) })
			add(-cf.RightVector, { W(-hx, -hy, -hz), W(-hx, -hy, hz), W(-hx, hy, hz), W(-hx, hy, -hz) })
			add(cf.UpVector, { W(-hx, hy, -hz), W(-hx, hy, hz), W(hx, hy, hz), W(hx, hy, -hz) })
			add(-cf.UpVector, { W(-hx, -hy, -hz), W(hx, -hy, -hz), W(hx, -hy, hz), W(-hx, -hy, hz) })
			add(-cf.LookVector, { W(-hx, -hy, hz), W(hx, -hy, hz), W(hx, hy, hz), W(-hx, hy, hz) })
			add(cf.LookVector, { W(-hx, -hy, -hz), W(-hx, hy, -hz), W(hx, hy, -hz), W(hx, -hy, -hz) })
		elseif kind == "Cylinder" then
			local r = math.min(hy, hz)
			for _, sg in { 1, -1 } do
				local poly = {}
				for k = 0, 15 do
					local a = sg * 2 * math.pi * k / 16
					table.insert(poly, W(sg * hx, math.cos(a) * r, math.sin(a) * r))
				end
				add(cf.RightVector * sg, poly)
			end
		elseif kind == "Wedge" then
			add(-cf.LookVector, { W(-hx, -hy, hz), W(hx, -hy, hz), W(hx, hy, hz), W(-hx, hy, hz) })
			add(-cf.UpVector, { W(-hx, -hy, -hz), W(hx, -hy, -hz), W(hx, -hy, hz), W(-hx, -hy, hz) })
			add(cf.RightVector, { W(hx, -hy, -hz), W(hx, hy, hz), W(hx, -hy, hz) })
			add(-cf.RightVector, { W(-hx, -hy, -hz), W(-hx, -hy, hz), W(-hx, hy, hz) })
		end
	end
	-- polygons in the plane of face f (2D, counter-clockwise)
	local function planar(f, poly)
		local n = f.n
		local u = if math.abs(n.Y) < 0.9 then n:Cross(Vector3.new(0, 1, 0)).Unit else n:Cross(Vector3.new(1, 0, 0)).Unit
		local v = n:Cross(u)
		local out, area = {}, 0
		for _, p in poly do
			table.insert(out, { p:Dot(u), p:Dot(v) })
		end
		for i = 1, #out do
			local a, b = out[i], out[i % #out + 1]
			area += a[1] * b[2] - b[1] * a[2]
		end
		if area < 0 then
			local rev = {}
			for i = #out, 1, -1 do
				table.insert(rev, out[i])
			end
			out = rev
		end
		return out, u, v
	end
	local function polyArea(poly)
		local a = 0
		for i = 1, #poly do
			local p, q = poly[i], poly[i % #poly + 1]
			a += p[1] * q[2] - q[1] * p[2]
		end
		return math.abs(a) / 2
	end
	local function clipPoly(subject, clipper) -- Sutherland-Hodgman (convex clipper)
		local out = subject
		for i = 1, #clipper do
			if #out == 0 then
				break
			end
			local a, b = clipper[i], clipper[i % #clipper + 1]
			local function inside(p)
				return (b[1] - a[1]) * (p[2] - a[2]) - (b[2] - a[2]) * (p[1] - a[1]) >= -1e-9
			end
			local function cross(p, q)
				local den = (a[1] - b[1]) * (p[2] - q[2]) - (a[2] - b[2]) * (p[1] - q[1])
				if math.abs(den) < 1e-12 then
					return q
				end
				local t = ((a[1] - p[1]) * (p[2] - q[2]) - (a[2] - p[2]) * (p[1] - q[1])) / den
				return { a[1] + t * (b[1] - a[1]), a[2] + t * (b[2] - a[2]) }
			end
			local input = out
			out = {}
			local prev = input[#input]
			for _, cur in input do
				if inside(cur) then
					if not inside(prev) then
						table.insert(out, cross(prev, cur))
					end
					table.insert(out, cur)
				elseif inside(prev) then
					table.insert(out, cross(prev, cur))
				end
				prev = cur
			end
		end
		return out
	end
	local function insideSolid(q, pt)
		if q:IsA("WedgePart") then
			local l = q.CFrame:PointToObjectSpace(pt)
			local s = q.Size
			if not (math.abs(l.X) < s.X / 2 and math.abs(l.Y) < s.Y / 2 and math.abs(l.Z) < s.Z / 2) then
				return false
			end
			return l.Y < -s.Y / 2 + (l.Z + s.Z / 2) / s.Z * s.Y -- under the slope
		end
		return containsPoint(q, pt)
	end
	local opaqueSet = {}
	for _, q in opaque do
		opaqueSet[q] = true
	end
	local function covered(pt, a, b)
		if pt.Y < 0 then
			return true -- under the ground
		end
		for _, q in nearbyParts(pt) do
			if q ~= a and q ~= b and opaqueSet[q] and insideSolid(q, pt) then
				return true
			end
		end
		return false
	end
	local function colorDiff(a, b)
		return math.abs(a.R - b.R) + math.abs(a.G - b.G) + math.abs(a.B - b.B)
	end
	local buckets = {}
	for i, f in faces do
		local key = math.floor(f.n.X * 50 + 0.5) .. "," .. math.floor(f.n.Y * 50 + 0.5) .. "," .. math.floor(f.n.Z * 50 + 0.5)
		buckets[key] = buckets[key] or {}
		table.insert(buckets[key], i)
	end
	local flicker = {}
	for _, list in buckets do
		table.sort(list, function(i, j)
			return faces[i].d < faces[j].d
		end)
		for x = 1, #list do
			local a = faces[list[x]]
			local y = x + 1
			while y <= #list and faces[list[y]].d - a.d < EPS do
				local b = faces[list[y]]
				local pa, pb = a.part, b.part
				if pa ~= pb and a.n:Dot(b.n) > 0.9995
					and (colorDiff(pa.Color, pb.Color) > 0.06 or pa.Material.Name ~= pb.Material.Name) then
					local A, u, v = planar(a, a.poly)
					local B = planar(a, b.poly)
					local I = clipPoly(A, B)
					local area = if #I >= 3 then polyArea(I) else 0
					if area > MIN_AREA then
						local minU, maxU, minV, maxV = math.huge, -math.huge, math.huge, -math.huge
						for _, p in I do
							minU, maxU = math.min(minU, p[1]), math.max(maxU, p[1])
							minV, maxV = math.min(minV, p[2]), math.max(maxV, p[2])
						end
						local N, total, exposed = 10, 0, 0
						local origin = a.n * a.d
						for i = 0, N do
							for j = 0, N do
								local pu = minU + (maxU - minU) * (i + 0.5) / (N + 1)
								local pv = minV + (maxV - minV) * (j + 0.5) / (N + 1)
								local inPoly = true
								for e = 1, #I do
									local p1, p2 = I[e], I[e % #I + 1]
									if (p2[1] - p1[1]) * (pv - p1[2]) - (p2[2] - p1[2]) * (pu - p1[1]) < -1e-9 then
										inPoly = false
										break
									end
								end
								if inPoly then
									total += 1
									if not covered(origin + u * pu + v * pv + a.n * 0.03, pa, pb) then
										exposed += 1
									end
								end
							end
						end
						local exposedArea = if total > 0 then area * exposed / total else 0
						if exposedArea > MIN_AREA then
							table.insert(flicker, ("%s ~ %s (%.2f studs^2 exposed, %.3f apart)"):format(
								pa:GetFullName(), pb:GetFullName(), exposedArea, b.d - a.d))
						end
					end
				end
				y += 1
			end
		end
	end
	assert(#flicker == 0, #flicker .. " flickering coplanar face pairs, e.g.\n  " .. table.concat(flicker, "\n  ", 1, math.min(#flicker, 12)))
	print(("no coplanar flicker: %d flat faces of %d visible parts, none within %.2f studs of a differently colored overlapping face"):format(#faces, #visible, EPS))
end

----------------------------------------------------------------------
-- Total exported part budget (map + client-life preview, as the render
-- export counts it): <= 7,000
----------------------------------------------------------------------
local previewPath = REPO .. "/tools/render/preview_life.luau"
if fs.isFile(previewPath) then
	local previewModule = Instance.new("ModuleScript")
	previewModule.Name = "PreviewLife"
	local previewFn = loadFile(previewPath, previewModule)
	assert(type(previewFn) == "function", "preview_life.luau must return a function(ctx)")
	previewFn({ Workspace = Workspace, require = env.require, Shared = shared, REPO = REPO })
end
local exportedParts = 0
for _, root in Workspace:GetChildren() do
	if root:IsA("Folder") or root:IsA("Model") then
		for _, d in root:GetDescendants() do
			if d:IsA("BasePart") then
				exportedParts += 1
			end
		end
	end
end
print(("exported part total %d (map %d, preview life %d) / 7000 (round-5 envelopes: map %d, total 6930)"):format(
	exportedParts, counts.total, exportedParts - counts.total, MAP_ENVELOPE))
if exportedParts > 6930 then
	print("NOTE: exported total is over the 6,930 round-5 envelope (hard cap 7,000)")
end
assert(exportedParts <= 7000, "exported part budget exceeded: " .. exportedParts .. " > 7000")

print("ALL MAP CHECKS PASSED")
