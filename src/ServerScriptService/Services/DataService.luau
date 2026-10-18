--[[
	DataService.luau (v2)
	Persistence + the ONLY cash mutation API (ARCHITECTURE.md "Data schema v2").

	- DataStore GameConfig.Data.StoreName ("SideHustleData_v2"), key "Player_" .. UserId.
	- UpdateAsync-based session locking: stored value is
	  { Data = PlayerData, Lock = { JobId, SessionId, Time }? } owned by SessionId.
	- Load retry/kick flow when a foreign lock is fresh (SE-1).
	- 60s lock refresh loop for loaded players.
	- Stored Data whose DataVersion ~= GameConfig.Data.Version is replaced by
	  GameConfig.Data.Defaults() (fresh game); everything else is reconciled
	  against the v2 defaults (Upgrades is a map of per-zone tables).
	- Validation before every save; corrupt data is never written.
	- Final save on leave clears the lock; BindToClose drains in-flight saves.
	- DataService is the ONLY creator of leaderstats (Cash, Level, Rebirths IntValues).
	- XP is written by LevelService only (contract); rebirth reset by RebirthService.
]]

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
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

-- Each load claims the lock under a unique session GUID, so a stale lock left
-- by the player's PREVIOUS session on this same server is still recognized as
-- not ours (JobId alone cannot tell the two apart on a fast same-server rejoin).
local sessionIds: { [number]: string } = {} -- UserId -> active session GUID
-- UserId -> true while that player's final (leave-time) save is in flight, so
-- a fast rejoin waits for it instead of loading a pre-save snapshot.
local savingUserIds: { [number]: boolean } = {}
-- Writes currently in flight anywhere (auto-save, leave, shutdown); BindToClose
-- holds the server open until this drains or the deadline passes.
local pendingSaves = 0

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
-- v2: Upgrades is a map zoneId -> { upgradeId -> level }; the template holds
-- one empty table per zone, so recursing creates every missing zone table.
-- A stored value whose type does not match the template (or a non-finite
-- number) is replaced by the default rather than left to block every save.
local function reconcile(data: { [any]: any }, template: { [any]: any })
	for key, default in template do
		local value = data[key]
		if typeof(default) == "table" then
			if typeof(value) ~= "table" then
				data[key] = deepClone(default)
			else
				reconcile(value, default)
			end
		elseif typeof(default) == "number" then
			if not isFiniteNumber(value) then
				data[key] = default
			end
		elseif value == nil or typeof(value) ~= typeof(default) then
			data[key] = default
		end
	end
end

-- True when every value of a table is a finite, non-negative number.
local function allNonNegativeNumbers(levels: any): boolean
	if typeof(levels) ~= "table" then
		return false
	end
	for _, level in levels do
		if not isFiniteNumber(level) or level < 0 then
			return false
		end
	end
	return true
end

-- Reject corrupt data before it ever reaches the DataStore (v2 fields).
local function validate(data: any): boolean
	if typeof(data) ~= "table" then
		return false
	end
	if not isFiniteNumber(data.Cash) or data.Cash < 0 then
		return false
	end
	if not isFiniteNumber(data.Level) or data.Level < 1 then
		return false
	end
	if not isFiniteNumber(data.Xp) or data.Xp < 0 then
		return false
	end
	if not isFiniteNumber(data.Rebirths) or data.Rebirths < 0 then
		return false
	end
	-- Upgrades: zoneId -> { upgradeId -> level }
	if typeof(data.Upgrades) ~= "table" then
		return false
	end
	for _, zoneUpgrades in data.Upgrades do
		if not allNonNegativeNumbers(zoneUpgrades) then
			return false
		end
	end
	-- Perks: perkId -> level
	if not allNonNegativeNumbers(data.Perks) then
		return false
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

local function setIntValue(parent: Instance, name: string, value: number)
	local child = parent:FindFirstChild(name)
	if child and child:IsA("IntValue") then
		child.Value = math.floor(value)
	end
end

local function updateLeaderstats(player: Player, data: PlayerData)
	local leaderstats = player:FindFirstChild("leaderstats")
	if not leaderstats then
		return
	end
	setIntValue(leaderstats, "Cash", data.Cash)
	setIntValue(leaderstats, "Level", data.Level)
	setIntValue(leaderstats, "Rebirths", data.Rebirths)
end

local function newIntValue(name: string, value: number, parent: Instance)
	local intValue = Instance.new("IntValue")
	intValue.Name = name
	intValue.Value = math.floor(value)
	intValue.Parent = parent
end

-- DataService is the ONLY creator of leaderstats.
local function createLeaderstats(player: Player, data: PlayerData)
	if player:FindFirstChild("leaderstats") then
		updateLeaderstats(player, data)
		return
	end

	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"

	newIntValue("Cash", data.Cash, leaderstats)
	newIntValue("Level", data.Level, leaderstats)
	newIntValue("Rebirths", data.Rebirths, leaderstats)

	leaderstats.Parent = player
end

----------------------------------------------------------------------
-- DataStore writes
----------------------------------------------------------------------

-- A stored lock blocks us when it belongs to a DIFFERENT session (by GUID)
-- and is still fresh. Sessions are compared by GUID, not JobId, so a stale
-- lock from the player's previous visit to this same server never passes.
local function isForeignLock(lock: any, sessionId: string): boolean
	return typeof(lock) == "table"
		and lock.SessionId ~= sessionId
		and typeof(lock.Time) == "number"
		and os.time() - lock.Time < GameConfig.Data.LockTimeout
end

-- Write a player's data under its session GUID. Keeps the session lock unless
-- clearLock is true, and never re-asserts a lock for a session that has ended
-- meanwhile (an auto-save finishing after the leave-time save must not lock
-- the key again). Never clobbers a fresh lock owned by another session.
local function writeDataInner(userId: number, data: PlayerData, sessionId: string, clearLock: boolean): boolean
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
				if isForeignLock(stored.Lock, sessionId) then
					foreignLock = true
					return nil -- abort: another live session owns this key
				end

				local entry: { [string]: any } = { Data = data }
				if not clearLock and sessionIds[userId] == sessionId then
					entry.Lock = { JobId = game.JobId, SessionId = sessionId, Time = os.time() }
				end
				return entry
			end)
		end)

		if foreignLock then
			warn(`[DataService] Skipped save for user {userId}: session owned elsewhere`)
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

local function writeData(userId: number, data: PlayerData, sessionId: string, clearLock: boolean): boolean
	pendingSaves += 1
	local ok, result = pcall(writeDataInner, userId, data, sessionId, clearLock)
	pendingSaves -= 1
	if not ok then
		warn(`[DataService] Save for user {userId} raised: {result}`)
		return false
	end
	return result
end

-- Release this session's lock without touching Data (player left during load).
local function releaseLock(userId: number, sessionId: string)
	pcall(function()
		dataStore:UpdateAsync(keyFor(userId), function(stored)
			if typeof(stored) ~= "table" then
				return nil
			end
			local lock = stored.Lock
			if typeof(lock) ~= "table" or lock.SessionId ~= sessionId then
				return nil -- not this session's lock; leave untouched
			end
			stored.Lock = nil
			return stored
		end)
	end)
end

-- Bump Lock.Time so other servers keep seeing this session as alive.
local function refreshLock(player: Player)
	local sessionId = sessionIds[player.UserId]
	if not sessionId then
		return
	end
	local ok, err = pcall(function()
		dataStore:UpdateAsync(keyFor(player.UserId), function(stored)
			if typeof(stored) ~= "table" then
				return nil
			end
			local lock = stored.Lock
			if typeof(lock) ~= "table" or lock.SessionId ~= sessionId then
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

-- Fires the full data snapshot to the client and refreshes leaderstats
-- (Cash, Level, Rebirths).
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

-- Adds to Cash and Stats.TotalCashEarned, then syncs. Server-only.
function DataService.addCash(player: Player, amount: number)
	local data = loaded[player]
	if not data then
		return
	end
	if not isFiniteNumber(amount) or amount <= 0 then
		return
	end
	data.Cash += amount
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
-- version-check + reconcile against defaults, create leaderstats.
function DataService.loadPlayer(player: Player)
	if loaded[player] then
		return
	end

	local userId = player.UserId

	-- A leave-time save from this player's previous session on THIS server may
	-- still be in flight (it retries on DataStore errors). Wait for it so we
	-- never read the pre-save snapshot; bounded so a wedged save cannot block
	-- the join forever (the lock check below still guards correctness).
	local waitDeadline = os.clock() + SAVE_ATTEMPTS * (SAVE_RETRY_DELAY + 8)
	while savingUserIds[userId] and os.clock() < waitDeadline do
		task.wait(0.1)
	end
	if not player:IsDescendantOf(Players) then
		return
	end

	local key = keyFor(userId)
	local sessionId = HttpService:GenerateGUID(false)
	local lockBusy = false
	local storedData: any = nil
	local claimed = false

	for attempt = 1, LOAD_ATTEMPTS do
		lockBusy = false
		local ok, err = pcall(function()
			dataStore:UpdateAsync(key, function(stored)
				stored = if typeof(stored) == "table" then stored else {}
				if isForeignLock(stored.Lock, sessionId) then
					lockBusy = true
					return nil -- abort: session still owned elsewhere
				end
				stored.Lock = { JobId = game.JobId, SessionId = sessionId, Time = os.time() }
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

	sessionIds[userId] = sessionId

	-- Player may have left during the async load: release the lock and bail.
	if not player:IsDescendantOf(Players) then
		if sessionIds[userId] == sessionId then
			sessionIds[userId] = nil
		end
		task.spawn(releaseLock, userId, sessionId)
		return
	end

	-- v2 schema: anything stored under a different DataVersion (including a
	-- v1 table with no DataVersion at all) is a fresh game.
	local data: PlayerData
	if typeof(storedData) == "table" and storedData.DataVersion == GameConfig.Data.Version then
		data = storedData :: PlayerData
	else
		if typeof(storedData) == "table" then
			warn(`[DataService] {player.Name} had DataVersion {tostring(storedData.DataVersion)}; resetting to v{GameConfig.Data.Version} defaults`)
		end
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

	local userId = player.UserId
	local sessionId = sessionIds[userId]
	if not sessionId then
		return
	end

	if joinedAt then
		data.Stats.PlayTime += math.max(0, math.floor(os.clock() - joinedAt + 0.5))
	end

	-- Mark the final save in flight so a fast same-server rejoin waits for it
	-- instead of loading a stale snapshot. Clearing sessionIds first also stops
	-- any in-flight auto-save from re-asserting the lock after we clear it.
	savingUserIds[userId] = true
	sessionIds[userId] = nil
	writeData(userId, data, sessionId, true)
	savingUserIds[userId] = nil
	print(`[DataService] Unloaded data for {player.Name}`)
end

-- Auto-save every loaded player (keeps the session lock). Non-blocking.
function DataService.saveAll()
	for player, data in loaded do
		local sessionId = sessionIds[player.UserId]
		if sessionId then
			task.spawn(writeData, player.UserId, data, sessionId, false)
		end
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
			-- Nothing left to start, but saves begun from PlayerRemoving may
			-- still be in flight: drain them before letting the server close.
			local deadline = os.clock() + SHUTDOWN_DEADLINE
			while pendingSaves > 0 and os.clock() < deadline do
				task.wait(0.1)
			end
			return
		end

		local finished = 0
		for player, data in toSave do
			loaded[player] = nil
			local joinedAt = joinClocks[player]
			joinClocks[player] = nil
			local userId = player.UserId
			local sessionId = sessionIds[userId]
			sessionIds[userId] = nil
			task.spawn(function()
				if joinedAt then
					data.Stats.PlayTime += math.max(0, math.floor(os.clock() - joinedAt + 0.5))
				end
				if sessionId then
					writeData(userId, data, sessionId, true)
				end
				finished += 1
			end)
		end

		-- Hold the server open for this batch AND for saves already in flight
		-- elsewhere (a PlayerRemoving final save, a late auto-save) until they
		-- commit or the deadline passes.
		local deadline = os.clock() + SHUTDOWN_DEADLINE
		while (finished < total or pendingSaves > 0) and os.clock() < deadline do
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
