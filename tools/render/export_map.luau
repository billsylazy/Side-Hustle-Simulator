-- Render export: runs the REAL MapBuilder.build() inside Lune's Roblox datatype /
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
-- Every Shared module is requirable (ChibiRig, city layout modules, ...).
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
	-- Lune instances have no WaitForChild; everything exists up front here.
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

-- ===================== EXPORT (render pipeline) =====================
local serde = require("@lune/serde")
local process = require("@lune/process")
local OUT = process.args[1]
local outPath = OUT or "map.json"

local function cfArr(cf)
	local c = { cf:GetComponents() }
	return c
end
local function col(c) return { c.R, c.G, c.B } end

local parts, lights, labels, emitters = {}, {}, {}, {}
-- Optional client-life preview: tools/render/preview_life.luau returns
-- function(ctx) that builds representative NPCs/cars (the things client
-- controllers spawn at runtime) into Workspace so the renders show them.
local previewPath = REPO .. "/tools/render/preview_life.luau"
if fs.isFile(previewPath) then
	local previewModule = Instance.new("ModuleScript")
	previewModule.Name = "PreviewLife"
	local previewFn = loadFile(previewPath, previewModule)
	assert(type(previewFn) == "function", "preview_life.luau must return a function(ctx)")
	previewFn({ Workspace = Workspace, require = env.require, Shared = shared, REPO = REPO })
	print("preview_life.luau applied")
end

local map = Workspace:FindFirstChild("SideHustleMap")
local roots = { map }
for _, extra in Workspace:GetChildren() do
	if extra ~= map and (extra:IsA("Folder") or extra:IsA("Model")) then
		table.insert(roots, extra)
	end
end
for _, root in roots do
	for _, inst in root:GetDescendants() do
		if inst:IsA("BasePart") then
			local shape = "Block"
			if inst:IsA("WedgePart") then shape = "Wedge"
			elseif inst:IsA("CornerWedgePart") then shape = "CornerWedge"
			elseif inst:IsA("Part") then shape = inst.Shape.Name end
			table.insert(parts, {
				n = inst.Name, s = shape,
				z = { inst.Size.X, inst.Size.Y, inst.Size.Z },
				cf = cfArr(inst.CFrame), c = col(inst.Color),
				m = inst.Material.Name, t = inst.Transparency,
			})
		elseif inst:IsA("PointLight") or inst:IsA("SurfaceLight") or inst:IsA("SpotLight") then
			local p = inst.Parent
			if p and p:IsA("BasePart") then
				table.insert(lights, { p = { p.CFrame.Position.X, p.CFrame.Position.Y, p.CFrame.Position.Z }, c = col(inst.Color), r = inst.Range, b = inst.Brightness })
			end
		elseif inst:IsA("ParticleEmitter") then
			local p = inst.Parent
			if p and p:IsA("BasePart") then
				local kp = inst.Color.Keypoints[1].Value
				table.insert(emitters, { p = { p.CFrame.Position.X, p.CFrame.Position.Y, p.CFrame.Position.Z }, c = col(kp), rate = inst.Rate })
			end
		elseif inst:IsA("TextLabel") then
			local gui = inst:FindFirstAncestorWhichIsA("LayerCollector")
			local adornee = gui and (gui:IsA("BillboardGui") and (gui.Adornee or gui.Parent) or gui:IsA("SurfaceGui") and (gui.Adornee or gui.Parent))
			if adornee and adornee:IsA("BasePart") and inst.Text ~= "" then
				local off = gui:IsA("BillboardGui") and gui.StudsOffset or Vector3.zero
				local pos = adornee.CFrame.Position + off
				table.insert(labels, {
					p = { pos.X, pos.Y, pos.Z }, text = inst.Text, c = col(inst.TextColor3),
					kind = gui.ClassName, size = math.max(adornee.Size.X, adornee.Size.Z),
				})
			end
		end
	end
end

local terrain = {}
for _, f in fills do
	local e = { op = f.op }
	if f.cf then e.cf = cfArr(f.cf) end
	if f.size then e.size = { f.size.X, f.size.Y, f.size.Z } end
	if f.height then e.height = f.height end
	if f.radius then e.radius = f.radius end
	if f.center then e.center = { f.center.X, f.center.Y, f.center.Z } end
	if f.mat then e.mat = f.mat.Name end
	table.insert(terrain, e)
end
local matColors = {}
for _, m in { "Grass", "Sand", "Ground", "Rock", "Asphalt", "Concrete", "Pavement", "LeafyGrass", "Mud", "Snow" } do
	local ok, c = pcall(function() return realTerrain:GetMaterialColor(Enum.Material[m]) end)
	if ok then matColors[m] = col(c) end
end

local L = Lighting
local out = {
	parts = parts, lights = lights, labels = labels, emitters = emitters, terrain = terrain,
	terrainColors = matColors,
	water = { c = col(realTerrain.WaterColor), t = realTerrain.WaterTransparency },
	lighting = {
		clock = L.ClockTime, brightness = L.Brightness, ambient = col(L.Ambient), outdoor = col(L.OutdoorAmbient),
		exposure = L.ExposureCompensation,
	},
}
local atm = L:FindFirstChildOfClass("Atmosphere")
if atm then out.atmosphere = { density = atm.Density, offset = atm.Offset, c = col(atm.Color), decay = col(atm.Decay), haze = atm.Haze } end
local cc = L:FindFirstChildOfClass("ColorCorrectionEffect")
if cc then out.cc = { sat = cc.Saturation, con = cc.Contrast, bri = cc.Brightness, tint = col(cc.TintColor) } end
fs.writeFile(outPath, serde.encode("json", out))
print(("exported %d parts, %d lights, %d labels, %d emitters, %d terrain ops -> %s"):format(#parts, #lights, #labels, #emitters, #terrain, outPath))
