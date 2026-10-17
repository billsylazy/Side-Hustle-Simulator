--[[
	DataService.luau
	Persistence + the ONLY cash mutation API (ARCHITECTURE.md "Data schema").

	- UpdateAsync-based session locking: stored value is
	  { Data = PlayerData, Lock = { JobId = game.JobId, Time = os.time() }? }.
	- Load retry/kick flow when a foreign lock is fresh (SE-1).
	- 60s lock refresh loop for loaded players.
	- Validation before every save; corrupt data is never written.
	- Final save on leave clears the lock; BindToClose saves in parallel.
	- DataService is the ONLY creator of leaderstats (Cash, Rebirths IntValues).
]]

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local Types = require(ReplicatedStorage.Shared.Types)

type PlayerData = Types.PlayerData

local DataService = {}

local LOAD_ATTEMPTS = 5
local LOAD_RETRY_DELAY = 2
local SAVE_ATTEMPTS = 3
local SAVE_RETRY_DELAY = 2
local SHUTDOWN_DEADLINE = 25 -- leave buffer before Roblox's 30s BindToClose hard limit

local LOCK_KICK_MESSAGE = "Your data is still saving from another server — rejoin in a minute."
local LOAD_FAIL_KICK_MESSAGE = "Failed to load your data. Please rejoin."

local dataStore = DataStoreService:GetDataStore(GameConfig.Data.StoreName)

local services: { [string]: any }? = nil
local loaded: { [Player]: PlayerData } = {}
local joinClocks: { [Player]: number } = {}
local started = false
local shuttingDown = false

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

local function keyFor(userId: number): string
	return "Player_" .. userId
end

local function isFiniteNumber(value: any): boolean
	return typeof(value) == "number"
		and value == value -- NaN check
		and value ~= math.huge
		and value ~= -math.huge
end

local function deepClone(original: { [any]: any }): { [any]: any }
	local clone = {}
	for key, value in original do
		if typeof(value) == "table" then
			clone[key] = deepClone(value)
		else
			clone[key] = value
		end
	end
	return clone
end

-- Fill missing keys recursively from the template (GameConfig.Data.Defaults()).
local function reconcile(data: { [any]: any }, template: { [any]: any })
	for key, default in template do
		if data[key] == nil then
			if typeof(default) == "table" then
				data[key] = deepClone(default)
			else
				data[key] = default
			end
		elseif typeof(default) == "table" and typeof(data[key]) == "table" then
			reconcile(data[key], default)
		end
	end
end

-- Reject corrupt data before it ever reaches the DataStore.
local function validate(data: any): boolean
	if typeof(data) ~= "table" then
		return false
	end
	if not isFiniteNumber(data.Cash) or data.Cash < 0 then
		return false
	end
	if not isFiniteNumber(data.CashThisLife) or data.CashThisLife < 0 then
		return false
	end
	if not isFiniteNumber(data.Rebirths) or data.Rebirths < 0 then
		return false
	end
	if typeof(data.UnlockedZones) ~= "table" then
		return false
	end
	if typeof(data.Upgrades) ~= "table" then
		return false
	end
	for _, level in data.Upgrades do
		if not isFiniteNumber(level) or level < 0 then
			return false
		end
	end
	if typeof(data.Workers) ~= "table" then
		return false
	end
	if typeof(data.Stats) ~= "table" then
		return false
	end
	for _, value in data.Stats do
		if not isFiniteNumber(value) then
			return false
		end
	end
	if typeof(data.ClaimedQuests) ~= "table" then
		return false
	end
	return true
end

local function updateLeaderstats(player: Player, data: PlayerData)
	local leaderstats = player:FindFirstChild("leaderstats")
	if not leaderstats then
		return
	end
	local cash = leaderstats:FindFirstChild("Cash")
	if cash and cash:IsA("IntValue") then
		cash.Value = math.floor(data.Cash)
	end
	local rebirths = leaderstats:FindFirstChild("Rebirths")
	if rebirths and rebirths:IsA("IntValue") then
		rebirths.Value = math.floor(data.Rebirths)
	end
end

-- DataService is the ONLY creator of leaderstats.
local function createLeaderstats(player: Player, data: PlayerData)
	if player:FindFirstChild("leaderstats") then
		updateLeaderstats(player, data)
		return
	end

	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"

	local cash = Instance.new("IntValue")
	cash.Name = "Cash"
	cash.Value = math.floor(data.Cash)
	cash.Parent = leaderstats

	local rebirths = Instance.new("IntValue")
	rebirths.Name = "Rebirths"
	rebirths.Value = math.floor(data.Rebirths)
	rebirths.Parent = leaderstats

	leaderstats.Parent = player
end

----------------------------------------------------------------------
-- DataStore writes
----------------------------------------------------------------------

-- Write a player's data. Keeps our lock unless clearLock is true.
-- Never clobbers a fresh foreign lock (another server owns the session).
local function writeData(userId: number, data: PlayerData, clearLock: boolean): boolean
	if not validate(data) then
		warn(`[DataService] Data for user {userId} failed validation, skipping save`)
		return false
	end

	data.LastSeen = os.time()
	local key = keyFor(userId)

	for attempt = 1, SAVE_ATTEMPTS do
		local foreignLock = false
		local ok, err = pcall(function()
			dataStore:UpdateAsync(key, function(stored)
				stored = if typeof(stored) == "table" then stored else {}
				local lock = stored.Lock
				if
					typeof(lock) == "table"
					and lock.JobId ~= game.JobId
					and typeof(lock.Time) == "number"
					and os.time() - lock.Time < GameConfig.Data.LockTimeout
				then
					foreignLock = true
					return nil -- abort: another live server owns this session
				end

				local entry: { [string]: any } = { Data = data }
				if not clearLock then
					entry.Lock = { JobId = game.JobId, Time = os.time() }
				end
				return entry
			end)
		end)

		if foreignLock then
			warn(`[DataService] Skipped save for user {userId}: session owned by another server`)
			return false
		end
		if ok then
			return true
		end

		warn(`[DataService] Save attempt {attempt}/{SAVE_ATTEMPTS} failed for user {userId}: {err}`)
		if attempt < SAVE_ATTEMPTS then
			task.wait(SAVE_RETRY_DELAY)
		end
	end

	warn(`[DataService] All save retries exhausted for user {userId}`)
	return false
end

-- Release our lock without touching Data (player left during load).
local function releaseLock(userId: number)
	pcall(function()
		dataStore:UpdateAsync(keyFor(userId), function(stored)
			if typeof(stored) ~= "table" then
				return nil
			end
			local lock = stored.Lock
			if typeof(lock) ~= "table" or lock.JobId ~= game.JobId then
				return nil -- not ours; leave untouched
			end
			stored.Lock = nil
			return stored
		end)
	end)
end

-- Bump Lock.Time so other servers keep seeing our session as alive.
local function refreshLock(player: Player)
	local ok, err = pcall(function()
		dataStore:UpdateAsync(keyFor(player.UserId), function(stored)
			if typeof(stored) ~= "table" then
				return nil
			end
			local lock = stored.Lock
			if typeof(lock) ~= "table" or lock.JobId ~= game.JobId then
				return nil -- we lost the lock; do not fight over it
			end
			lock.Time = os.time()
			return stored
		end)
	end)
	if not ok then
		warn(`[DataService] Lock refresh failed for {player.Name}: {err}`)
	end
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

function DataService.getData(player: Player): PlayerData?
	return loaded[player]
end

function DataService.getLoadedPlayers(): { Player }
	local result: { Player } = {}
	for player in loaded do
		table.insert(result, player)
	end
	return result
end

-- Fires the full data snapshot to the client and refreshes leaderstats.
function DataService.sync(player: Player)
	local data = loaded[player]
	if not data then
		return
	end
	updateLeaderstats(player, data)
	if services and services.RemoteService then
		services.RemoteService.fireClient("DataSync", player, data)
	end
end

-- Adds to Cash, CashThisLife and Stats.TotalCashEarned. Server-only.
function DataService.addCash(player: Player, amount: number)
	local data = loaded[player]
	if not data then
		return
	end
	if not isFiniteNumber(amount) or amount <= 0 then
		return
	end
	data.Cash += amount
	data.CashThisLife += amount
	data.Stats.TotalCashEarned += amount
	DataService.sync(player)
end

-- Returns false if the player cannot afford it. Server-only.
function DataService.spendCash(player: Player, amount: number): boolean
	local data = loaded[player]
	if not data then
		return false
	end
	if not isFiniteNumber(amount) or amount < 0 then
		return false
	end
	if data.Cash < amount then
		return false
	end
	data.Cash -= amount
	DataService.sync(player)
	return true
end

-- Claim the session lock (retrying against a fresh foreign lock), load,
-- reconcile against defaults, create leaderstats.
function DataService.loadPlayer(player: Player)
	if loaded[player] then
		return
	end

	local key = keyFor(player.UserId)
	local lockBusy = false
	local storedData: any = nil
	local claimed = false

	for attempt = 1, LOAD_ATTEMPTS do
		lockBusy = false
		local ok, err = pcall(function()
			dataStore:UpdateAsync(key, function(stored)
				stored = if typeof(stored) == "table" then stored else {}
				local lock = stored.Lock
				if
					typeof(lock) == "table"
					and lock.JobId ~= game.JobId
					and typeof(lock.Time) == "number"
					and os.time() - lock.Time < GameConfig.Data.LockTimeout
				then
					lockBusy = true
					return nil -- abort: session still owned elsewhere
				end
				stored.Lock = { JobId = game.JobId, Time = os.time() }
				storedData = stored.Data
				return stored
			end)
		end)

		if ok and not lockBusy then
			claimed = true
			break
		end

		if not ok then
			warn(`[DataService] Load attempt {attempt}/{LOAD_ATTEMPTS} failed for {player.Name}: {err}`)
		end
		if attempt < LOAD_ATTEMPTS then
			task.wait(LOAD_RETRY_DELAY)
		end
	end

	if not claimed then
		player:Kick(if lockBusy then LOCK_KICK_MESSAGE else LOAD_FAIL_KICK_MESSAGE)
		return
	end

	-- Player may have left during the async load: release the lock and bail.
	if not player:IsDescendantOf(Players) then
		task.spawn(releaseLock, player.UserId)
		return
	end

	local data: PlayerData
	if typeof(storedData) == "table" then
		data = storedData :: PlayerData
	else
		data = GameConfig.Data.Defaults() :: PlayerData
	end
	reconcile(data :: any, GameConfig.Data.Defaults())

	loaded[player] = data
	joinClocks[player] = os.clock()
	createLeaderstats(player, data)
	print(`[DataService] Loaded data for {player.Name}`)
end

-- Fold in PlayTime, final save, clear the lock.
function DataService.unloadPlayer(player: Player)
	local data = loaded[player]
	loaded[player] = nil
	local joinedAt = joinClocks[player]
	joinClocks[player] = nil

	if not data then
		return
	end

	if joinedAt then
		data.Stats.PlayTime += math.max(0, math.floor(os.clock() - joinedAt + 0.5))
	end

	writeData(player.UserId, data, true)
	print(`[DataService] Unloaded data for {player.Name}`)
end

-- Auto-save every loaded player (keeps our lock). Non-blocking.
function DataService.saveAll()
	for player, data in loaded do
		task.spawn(writeData, player.UserId, data, false)
	end
end

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------

function DataService.init(injectedServices: { [string]: any })
	services = injectedServices
end

function DataService.start()
	if started then
		return
	end
	started = true

	-- Session lock refresh loop (keeps Lock.Time fresh while we own the session).
	task.spawn(function()
		while not shuttingDown do
			task.wait(GameConfig.Data.LockRefreshInterval)
			if shuttingDown then
				break
			end
			for player in loaded do
				task.spawn(refreshLock, player)
			end
		end
	end)

	-- Shutdown: parallel final saves (clearing locks) with a deadline (SE-6).
	game:BindToClose(function()
		shuttingDown = true

		local toSave: { [Player]: PlayerData } = {}
		local total = 0
		for player, data in loaded do
			toSave[player] = data
			total += 1
		end
		if total == 0 then
			return
		end

		local finished = 0
		for player, data in toSave do
			loaded[player] = nil
			local joinedAt = joinClocks[player]
			joinClocks[player] = nil
			task.spawn(function()
				if joinedAt then
					data.Stats.PlayTime += math.max(0, math.floor(os.clock() - joinedAt + 0.5))
				end
				writeData(player.UserId, data, true)
				finished += 1
			end)
		end

		local deadline = os.clock() + SHUTDOWN_DEADLINE
		while finished < total and os.clock() < deadline do
			task.wait(0.1)
		end

		if finished < total then
			warn(`[DataService] Shutdown saved {finished}/{total} players before the deadline`)
		else
			print(`[DataService] Shutdown save complete ({total} players)`)
		end
	end)
end

return DataService
