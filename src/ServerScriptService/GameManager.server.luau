--[[
	GameManager.server.luau (v2)
	Server entry point (ARCHITECTURE.md "Service pattern"):
	1. Build the map + lighting (MapBuilder.build(), idempotent).
	2. Create every remote (RemoteService.init()).
	3. Require all 9 services, init(services) all, then start() all.
	4. Player lifecycle: load/sync on join, unload + per-service cleanup on leave.
	5. Auto-save loop every GameConfig.Data.SaveInterval.
	game:BindToClose is handled inside DataService.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

-- 1. Build the world FIRST so zones, prompts and spawns exist before any
--    service connects to them and before any player spawns.
local MapBuilder = require(script.Parent.World.MapBuilder)
MapBuilder.build()

-- 2. Remotes must exist before services register handlers against them.
local servicesFolder = script.Parent.Services
local RemoteService = require(servicesFolder.RemoteService)
RemoteService.init()

-- 3. Require all services, inject the services table, init all, start all.
--    Order matters only loosely (DataService/RemoteService first so every
--    other service's start() can register remotes and query data; LevelService
--    before the services that delegate zone-unlock queries to it).
local SERVICE_ORDER = {
	"DataService",
	"RemoteService",
	"LevelService",
	"ZoneService",
	"HustleService",
	"WorkerService",
	"UpgradeService",
	"RebirthService",
	"QuestService",
}

local services: { [string]: any } = {}
for _, name in SERVICE_ORDER do
	local moduleScript = servicesFolder:FindFirstChild(name)
	assert(moduleScript ~= nil, `[GameManager] Missing service module: Services.{name}`)
	local service = require(moduleScript)
	assert(typeof(service) == "table", `[GameManager] Services.{name} must return a table`)
	services[name] = service
end

for _, name in SERVICE_ORDER do
	local service = services[name]
	if typeof(service.init) == "function" then
		service.init(services)
	end
end

for _, name in SERVICE_ORDER do
	local service = services[name]
	if typeof(service.start) == "function" then
		service.start()
	end
end

local DataService = services.DataService

-- 4. Player lifecycle.
local function onPlayerAdded(player: Player)
	DataService.loadPlayer(player)
	DataService.sync(player)
end

local function onPlayerRemoving(player: Player)
	DataService.unloadPlayer(player)
	for _, name in SERVICE_ORDER do
		local service = services[name]
		if typeof(service.cleanupPlayer) == "function" then
			service.cleanupPlayer(player)
		end
	end
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

-- Handle players already present (Studio fast-start edge case).
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

-- 5. Auto-save loop.
task.spawn(function()
	while true do
		task.wait(GameConfig.Data.SaveInterval)
		DataService.saveAll()
	end
end)

print(`[GameManager] Side Hustle Simulator v{GameConfig.Data.Version} server ready ({#SERVICE_ORDER} services)`)
