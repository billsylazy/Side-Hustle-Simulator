-- ZoneService: zone unlock purchases via gate ProximityPrompts.
-- Contract: ARCHITECTURE.md "Map contract" + "Gate behavior".
-- Server-authoritative: validates data loaded, not-already-unlocked,
-- sequential order (zone with Order-1 must be unlocked), distance and cost.
-- Gate visuals/collision for unlocked zones are handled client-side by
-- ZoneGateController reacting to DataSync; this service only mutates data.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

local ZoneService = {}

-- Injected via init(services) -- never require sibling services directly.
local DataService
local RemoteService

local UNLOCK_DEBOUNCE = 0.5 -- seconds between unlock attempts, per player
local MAX_PROMPT_DISTANCE = 20 -- studs; re-validated server-side per contract
local MAP_WAIT_TIMEOUT = 30 -- MapBuilder runs before start(); this is a safety net
local CHILD_WAIT_TIMEOUT = 5

-- UserId -> os.clock() of the last unlock attempt (debounce)
local lastUnlockAttempt: { [number]: number } = {}

-- Zones indexed by Order, for the sequential-unlock check.
local zonesByOrder: { [number]: GameConfig.ZoneDef } = {}
for _, zone in GameConfig.Zones do
	zonesByOrder[zone.Order] = zone
end

-- Fires a S->C RemoteEvent to one player. Prefers the RemoteService wrapper
-- (assumed API: RemoteService.fireClient(player, remoteName, ...)); falls back
-- to the contract-pinned ReplicatedStorage.Remotes folder so player feedback
-- never silently drops if the wrapper exposes a differently-named fire API.
local function fireClient(player: Player, remoteName: string, ...: any)
	if RemoteService ~= nil and typeof(RemoteService.fireClient) == "function" then
		RemoteService.fireClient(remoteName, player, ...)
		return
	end
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local remote = remotes and remotes:FindFirstChild(remoteName)
	if remote and remote:IsA("RemoteEvent") then
		remote:FireClient(player, ...)
	end
end

local function toast(player: Player, message: string, kind: string)
	fireClient(player, "Toast", message, kind)
end

local function isUnlockedInData(data: any, zoneId: string): boolean
	for _, unlockedId in data.UnlockedZones do
		if unlockedId == zoneId then
			return true
		end
	end
	return false
end

local function onUnlockTriggered(zone: GameConfig.ZoneDef, promptPart: BasePart, player: Player)
	-- Debounce per player (0.5 s), on attempt.
	local now = os.clock()
	if now - (lastUnlockAttempt[player.UserId] or 0) < UNLOCK_DEBOUNCE then
		return
	end
	lastUnlockAttempt[player.UserId] = now

	-- Data must be loaded.
	local data = DataService.getData(player)
	if not data then
		return
	end

	-- Already owned? Nothing to do (client hides the prompt, but never trust it).
	if isUnlockedInData(data, zone.Id) then
		return
	end

	-- Re-validate distance server-side (< 20 studs), per contract.
	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if not rootPart or not rootPart:IsA("BasePart") then
		return
	end
	if (rootPart.Position - promptPart.Position).Magnitude >= MAX_PROMPT_DISTANCE then
		return
	end

	-- Sequential unlocking: the zone with Order-1 must already be unlocked.
	local previousZone = zonesByOrder[zone.Order - 1]
	if previousZone and not isUnlockedInData(data, previousZone.Id) then
		toast(player, "Unlock " .. previousZone.Name .. " first!", "error")
		return
	end

	-- Cost: spendCash is the only legal way to take cash (it syncs + updates leaderstats).
	if not DataService.spendCash(player, zone.UnlockCost) then
		toast(player, "Not enough cash!", "error")
		return
	end

	table.insert(data.UnlockedZones, zone.Id)
	data.Stats.ZonesUnlockedCount = math.max(data.Stats.ZonesUnlockedCount, #data.UnlockedZones)
	DataService.sync(player)
	toast(player, zone.Name .. " unlocked!", "success")
end

-- Resolves one zone's gate prompt and connects it. Each step uses WaitForChild
-- with a timeout and warns + skips on failure, so one missing part never kills
-- the server or the other zones.
local function connectZoneGate(zonesFolder: Instance, zone: GameConfig.ZoneDef)
	local zoneModel = zonesFolder:WaitForChild(zone.Id, CHILD_WAIT_TIMEOUT)
	if not zoneModel then
		warn("[ZoneService] Zone model missing for " .. zone.Id .. "; unlock prompt skipped")
		return
	end

	local gate = zoneModel:WaitForChild("Gate", CHILD_WAIT_TIMEOUT)
	if not gate then
		warn("[ZoneService] Gate missing for zone " .. zone.Id .. "; unlock prompt skipped")
		return
	end

	local promptPart = gate:WaitForChild("PromptPart", CHILD_WAIT_TIMEOUT)
	if not promptPart or not promptPart:IsA("BasePart") then
		warn("[ZoneService] Gate PromptPart missing for zone " .. zone.Id .. "; unlock prompt skipped")
		return
	end

	local prompt = promptPart:WaitForChild("UnlockPrompt", CHILD_WAIT_TIMEOUT)
	if not prompt or not prompt:IsA("ProximityPrompt") then
		warn("[ZoneService] UnlockPrompt missing for zone " .. zone.Id .. "; unlock prompt skipped")
		return
	end

	-- Prompt connections live for the server's lifetime; per-player state is
	-- cleared in cleanupPlayer instead.
	prompt.Triggered:Connect(function(player: Player)
		onUnlockTriggered(zone, promptPart, player)
	end)
end

function ZoneService.init(services: { [string]: any })
	DataService = services.DataService
	RemoteService = services.RemoteService
end

function ZoneService.start()
	local map = Workspace:WaitForChild("SideHustleMap", MAP_WAIT_TIMEOUT)
	if not map then
		warn("[ZoneService] Workspace.SideHustleMap missing; no unlock prompts connected")
		return
	end

	local zonesFolder = map:WaitForChild("Zones", CHILD_WAIT_TIMEOUT)
	if not zonesFolder then
		warn("[ZoneService] SideHustleMap.Zones missing; no unlock prompts connected")
		return
	end

	for _, zone in GameConfig.Zones do
		if zone.UnlockCost > 0 then
			task.spawn(connectZoneGate, zonesFolder, zone)
		end
	end
end

-- True when the player's loaded data contains zoneId. Used by HustleService
-- (via injection) to reject hustles in locked zones.
function ZoneService.isZoneUnlocked(player: Player, zoneId: string): boolean
	local data = DataService.getData(player)
	if not data then
		return false
	end
	return isUnlockedInData(data, zoneId)
end

function ZoneService.cleanupPlayer(player: Player)
	lastUnlockAttempt[player.UserId] = nil
end

return ZoneService
