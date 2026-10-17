-- UpgradeService: upgrade purchases + multiplier queries, and the ONLY place
-- (besides RebirthService's reset) that applies the WalkSpeed upgrade to the
-- live Humanoid -- both on purchase and on every spawn.
-- Contract: ARCHITECTURE.md "Remotes" + "Earnings math".
-- cost = GameConfig.getUpgradeCost(id, level); nil means maxed.
-- humanoid WalkSpeed = GameConfig.BaseWalkSpeed + WalkSpeed level.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

local UpgradeService = {}

-- Injected via init(services) -- never require sibling services directly.
local DataService
local RemoteService

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

local function setWalkSpeed(humanoid: Humanoid, walkSpeedLevel: number)
	humanoid.WalkSpeed = GameConfig.BaseWalkSpeed + walkSpeedLevel
end

-- Applies the WalkSpeed upgrade to a freshly spawned character. Data may
-- still be loading (DataStore), so poll briefly before giving up.
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
		setWalkSpeed(humanoid, data.Upgrades.WalkSpeed or 0)
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
-- Remote handler
----------------------------------------------------------------------

local function onBuyUpgrade(player: Player, upgradeId: string)
	-- Data must be loaded.
	local data = DataService.getData(player)
	if not data then
		return
	end

	-- Existence re-checked here even though the validator already did (defense
	-- in depth; the handler must stand on its own).
	local def = GameConfig.Upgrades[upgradeId]
	if not def then
		return
	end

	local level = data.Upgrades[upgradeId] or 0
	local cost = GameConfig.getUpgradeCost(upgradeId, level)
	if cost == nil then
		toast(player, "Maxed out!", "error")
		return
	end

	if not DataService.spendCash(player, cost) then
		toast(player, "Not enough cash!", "error")
		return
	end

	local newLevel = level + 1
	data.Upgrades[upgradeId] = newLevel

	-- Fast Shoes applies instantly to the live character (feel guide: every
	-- purchase should be felt immediately).
	if upgradeId == "WalkSpeed" then
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			setWalkSpeed(humanoid, newLevel)
		end
	end

	DataService.sync(player)
	toast(player, def.Name .. " is now level " .. newLevel .. "!", "success")
end

----------------------------------------------------------------------
-- Multiplier queries (ARCHITECTURE.md service description)
----------------------------------------------------------------------

function UpgradeService.getLevel(player: Player, upgradeId: string): number
	local data = DataService.getData(player)
	if not data then
		return 0
	end
	return data.Upgrades[upgradeId] or 0
end

-- 1 + 0.25 per HustlePower level.
function UpgradeService.getHustleMultiplier(player: Player): number
	return 1 + GameConfig.HustlePowerPerLevel * UpgradeService.getLevel(player, "HustlePower")
end

-- 1 + 0.2 per WorkerEfficiency level.
function UpgradeService.getWorkerEfficiencyMultiplier(player: Player): number
	return 1 + GameConfig.WorkerEfficiencyPerLevel * UpgradeService.getLevel(player, "WorkerEfficiency")
end

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------

function UpgradeService.init(services: { [string]: any })
	DataService = services.DataService
	RemoteService = services.RemoteService
end

function UpgradeService.start()
	if started then
		return
	end
	started = true

	-- Cooldown per the ARCHITECTURE.md remotes table; RemoteService adds
	-- rate limiting and violation kicks on top.
	RemoteService.register({
		Name = "BuyUpgrade",
		Cooldown = 0.3,
		Validator = function(_player: Player, upgradeId: any): (boolean, string?)
			if typeof(upgradeId) ~= "string" then
				return false, "upgradeId must be a string"
			end
			if GameConfig.Upgrades[upgradeId] == nil then
				return false, "unknown upgradeId"
			end
			return true
		end,
		Handler = onBuyUpgrade,
	})

	-- Apply the WalkSpeed upgrade on every spawn, for joiners and for players
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
