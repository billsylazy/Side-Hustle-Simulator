-- UpgradeService (v2): per-zone hustle upgrades + global perks, and the ONLY
-- place (besides RebirthService's reset) that applies the WalkSpeed perk to
-- the live Humanoid -- both on purchase and on every spawn.
-- Contract: ARCHITECTURE.md "Remotes" + "Upgrades & perks".
--   BuyUpgrade(zoneId, upgradeId): zone unlocked by level, level < MaxLevel,
--     cost = GameConfig.getZoneUpgradeCost(zoneId, upgradeId, level) (nil = maxed),
--     data.Upgrades[zoneId][upgradeId] += 1.
--   BuyPerk(perkId): cost = GameConfig.getPerkCost(perkId, level) (nil = maxed),
--     data.Perks[perkId] += 1. humanoid WalkSpeed = BaseWalkSpeed + Perks.WalkSpeed.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

local UpgradeService = {}

-- Injected via init(services) -- never require sibling services directly.
local DataService
local RemoteService
local LevelService

local started = false

local HUMANOID_WAIT_TIMEOUT = 10
local DATA_POLL_INTERVAL = 0.5
local DATA_POLL_TIMEOUT = 10 -- data loads via DataStore; give it up to ~10 s

-- Player -> CharacterAdded connection; disconnected in cleanupPlayer so no
-- connection outlives its player (contract convention).
local characterConnections: { [Player]: RBXScriptConnection } = {}

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

local function toast(player: Player, message: string, kind: string)
	RemoteService.fireClient("Toast", player, message, kind)
end

-- Perk level from a data table (missing/corrupt -> 0).
function UpgradeService.getPerkLevel(data: any, perkId: string): number
	if typeof(data) ~= "table" or typeof(data.Perks) ~= "table" then
		return 0
	end
	local level = data.Perks[perkId]
	return if typeof(level) == "number" then level else 0
end

-- Effective walk speed for a data table: BaseWalkSpeed + WalkSpeed perk level.
function UpgradeService.getWalkSpeed(data: any): number
	return GameConfig.BaseWalkSpeed + UpgradeService.getPerkLevel(data, "WalkSpeed")
end

local function applyWalkSpeed(humanoid: Humanoid, data: any)
	humanoid.WalkSpeed = UpgradeService.getWalkSpeed(data)
end

-- Zone unlock is derived from level. LevelService owns the query; fall back to
-- the identical GameConfig rule if it is not injected (never trust the client
-- either way).
local function isZoneUnlocked(player: Player, data: any, zoneId: string): boolean
	if LevelService ~= nil and typeof(LevelService.isZoneUnlocked) == "function" then
		return LevelService.isZoneUnlocked(player, zoneId) == true
	end
	local level = if typeof(data.Level) == "number" then data.Level else 1
	return GameConfig.isZoneUnlockedAtLevel(zoneId, level)
end

-- Applies the WalkSpeed perk to a freshly spawned character. Data may still
-- be loading (DataStore), so poll briefly before giving up.
local function applyWalkSpeedOnSpawn(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid", HUMANOID_WAIT_TIMEOUT)
	if not humanoid or not humanoid:IsA("Humanoid") then
		return
	end

	local data = DataService.getData(player)
	local deadline = os.clock() + DATA_POLL_TIMEOUT
	while not data and os.clock() < deadline do
		task.wait(DATA_POLL_INTERVAL)
		if not player:IsDescendantOf(Players) then
			return -- player left while we waited
		end
		data = DataService.getData(player)
	end
	if not data then
		return -- data never loaded (DataService will have kicked the player)
	end

	-- The player may have respawned while we waited; only touch the humanoid
	-- if this character is still the live one.
	if player.Character == character and humanoid.Parent == character then
		applyWalkSpeed(humanoid, data)
	end
end

local function watchPlayer(player: Player)
	if characterConnections[player] then
		return
	end
	characterConnections[player] = player.CharacterAdded:Connect(function(character: Model)
		task.spawn(applyWalkSpeedOnSpawn, player, character)
	end)
	-- Character may already exist (players present before start()).
	if player.Character then
		task.spawn(applyWalkSpeedOnSpawn, player, player.Character)
	end
end

----------------------------------------------------------------------
-- Remote handlers
----------------------------------------------------------------------

local function onBuyUpgrade(player: Player, zoneId: string, upgradeId: string)
	-- Data must be loaded.
	local data = DataService.getData(player)
	if not data then
		return
	end

	-- Existence re-checked here even though the validator already did (defense
	-- in depth; the handler must stand on its own).
	local zone = GameConfig.getZone(zoneId)
	local def = GameConfig.getZoneUpgrade(zoneId, upgradeId)
	if not zone or not def then
		return
	end

	-- Zone must be unlocked by level (the client hides locked tabs, but never
	-- trust it).
	if not isZoneUnlocked(player, data, zoneId) then
		toast(player, "Unlock " .. zone.Name .. " first!", "error")
		return
	end

	local level = GameConfig.getZoneUpgradeLevel(data.Upgrades, zoneId, upgradeId)
	local cost = GameConfig.getZoneUpgradeCost(zoneId, upgradeId, level)
	if cost == nil then
		toast(player, "Maxed out!", "error")
		return
	end

	if not DataService.spendCash(player, cost) then
		toast(player, "Not enough cash!", "error")
		return
	end

	-- Upgrades is a map zoneId -> upgradeId -> level; create the zone table on
	-- first purchase (reconcile normally pre-creates it, but stand alone).
	if typeof(data.Upgrades) ~= "table" then
		data.Upgrades = {}
	end
	local zoneUpgrades = data.Upgrades[zoneId]
	if typeof(zoneUpgrades) ~= "table" then
		zoneUpgrades = {}
		data.Upgrades[zoneId] = zoneUpgrades
	end

	local newLevel = level + 1
	zoneUpgrades[upgradeId] = newLevel

	DataService.sync(player)

	-- The automation tier going 0 -> 1 is a hire, everything else is a level.
	if def.Effect == "Auto" and newLevel == 1 then
		toast(player, def.Name .. " hired!", "success")
	else
		toast(player, def.Name .. " Lv " .. newLevel .. "!", "success")
	end
end

local function onBuyPerk(player: Player, perkId: string)
	-- Data must be loaded.
	local data = DataService.getData(player)
	if not data then
		return
	end

	-- Existence re-checked here (defense in depth).
	local def = GameConfig.Perks[perkId]
	if not def then
		return
	end

	local level = UpgradeService.getPerkLevel(data, perkId)
	local cost = GameConfig.getPerkCost(perkId, level)
	if cost == nil then
		toast(player, "Maxed out!", "error")
		return
	end

	if not DataService.spendCash(player, cost) then
		toast(player, "Not enough cash!", "error")
		return
	end

	if typeof(data.Perks) ~= "table" then
		data.Perks = {}
	end
	local newLevel = level + 1
	data.Perks[perkId] = newLevel

	-- Fast Shoes applies instantly to the live character (feel guide: every
	-- purchase should be felt immediately).
	if perkId == "WalkSpeed" then
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			applyWalkSpeed(humanoid, data)
		end
	end

	DataService.sync(player)
	toast(player, def.Name .. " Lv " .. newLevel .. "!", "success")
end

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------

function UpgradeService.init(services: { [string]: any })
	DataService = services.DataService
	RemoteService = services.RemoteService
	LevelService = services.LevelService
end

function UpgradeService.start()
	if started then
		return
	end
	started = true

	-- Cooldowns per the ARCHITECTURE.md remotes table; RemoteService adds
	-- rate limiting and violation kicks on top.
	RemoteService.register({
		Name = "BuyUpgrade",
		Cooldown = 0.25,
		Validator = function(_player: Player, zoneId: any, upgradeId: any): (boolean, string?)
			if typeof(zoneId) ~= "string" then
				return false, "zoneId must be a string"
			end
			if typeof(upgradeId) ~= "string" then
				return false, "upgradeId must be a string"
			end
			if GameConfig.getZoneUpgrade(zoneId, upgradeId) == nil then
				return false, "unknown zone upgrade"
			end
			return true
		end,
		Handler = onBuyUpgrade,
	})

	RemoteService.register({
		Name = "BuyPerk",
		Cooldown = 0.3,
		Validator = function(_player: Player, perkId: any): (boolean, string?)
			if typeof(perkId) ~= "string" then
				return false, "perkId must be a string"
			end
			if GameConfig.Perks[perkId] == nil then
				return false, "unknown perkId"
			end
			return true
		end,
		Handler = onBuyPerk,
	})

	-- Apply the WalkSpeed perk on every spawn, for joiners and for players
	-- already present when the service starts.
	Players.PlayerAdded:Connect(watchPlayer)
	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end
end

function UpgradeService.cleanupPlayer(player: Player)
	local connection = characterConnections[player]
	if connection then
		connection:Disconnect()
		characterConnections[player] = nil
	end
end

return UpgradeService
