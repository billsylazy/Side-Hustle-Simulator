-- LevelService: XP + levels (ARCHITECTURE.md "Levels").
-- The ONLY writer of data.Xp / data.Level outside RebirthService's reset.
--   addXp(player, amount): Xp += amount; while Xp >= need and Level < MaxLevel:
--     Xp -= need, Level += 1, Stats.HighestLevel high-water mark, fire
--     LevelUp(newLevel, unlockedZoneId or nil) + Toast per level gained.
--     At MaxLevel XP is capped at need - 1. One DataService.sync at the end.
--   Zone unlock state is DERIVED: unlocked <=> data.Level >= zone.UnlockLevel.
-- WalkSpeed is untouched here (perks own it); level-ups never change it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

local LevelService = {}

-- Injected via init(services) -- never require sibling services directly.
local DataService
local RemoteService

local started = false

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

local function isFiniteNumber(value: any): boolean
	return typeof(value) == "number"
		and value == value -- NaN check
		and value ~= math.huge
		and value ~= -math.huge
end

local function toast(player: Player, message: string, kind: string)
	RemoteService.fireClient("Toast", player, message, kind)
end

-- Announces ONE gained level: LevelUp remote (with the zone that unlocks
-- exactly at this level, if any) and a success Toast.
local function announceLevel(player: Player, newLevel: number)
	local unlockedZone = GameConfig.getZoneUnlockedAtLevel(newLevel)
	local unlockedZoneId: string? = if unlockedZone then unlockedZone.Id else nil

	RemoteService.fireClient("LevelUp", player, newLevel, unlockedZoneId)

	if unlockedZone then
		toast(player, "Level " .. newLevel .. " - " .. unlockedZone.Name .. " unlocked!", "success")
	else
		toast(player, "Level " .. newLevel .. "!", "success")
	end
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

-- Grants XP and resolves every level-up it causes. Safe to call with any
-- amount: non-finite or non-positive amounts are ignored.
function LevelService.addXp(player: Player, amount: number)
	local data = DataService.getData(player)
	if not data then
		return
	end
	if not isFiniteNumber(amount) or amount <= 0 then
		return
	end

	local maxLevel = GameConfig.Levels.MaxLevel
	data.Xp += amount

	-- Multi-level loop: a single big grant (burst, auto tick) may cross
	-- several thresholds; each one fires its own LevelUp + Toast.
	local gainedLevels: { number } = {}
	while data.Level < maxLevel do
		local need = GameConfig.getXpForLevel(data.Level)
		if data.Xp < need then
			break
		end
		data.Xp -= need
		data.Level += 1
		table.insert(gainedLevels, data.Level)
	end

	-- At MaxLevel the bar can fill but never roll over.
	if data.Level >= maxLevel then
		data.Level = maxLevel
		local need = GameConfig.getXpForLevel(maxLevel)
		data.Xp = math.clamp(data.Xp, 0, math.max(0, need - 1))
	end

	if #gainedLevels > 0 then
		data.Stats.HighestLevel = math.max(data.Stats.HighestLevel or 1, data.Level)
		for _, newLevel in gainedLevels do
			announceLevel(player, newLevel)
		end
	end

	-- One snapshot per grant, after every level-up has been resolved, so the
	-- client's DataSync already carries the final Level/Xp/HighestLevel.
	DataService.sync(player)
end

-- Current level; 0 when the player's data is not loaded (so gates stay shut).
function LevelService.getLevel(player: Player): number
	local data = DataService.getData(player)
	if not data then
		return 0
	end
	return data.Level
end

-- unlocked <=> Level >= zone.UnlockLevel (unknown zone / unloaded data -> false).
function LevelService.isZoneUnlocked(player: Player, zoneId: string): boolean
	local data = DataService.getData(player)
	if not data then
		return false
	end
	return GameConfig.isZoneUnlockedAtLevel(zoneId, data.Level)
end

-- XP still needed to reach the next level (0 at MaxLevel or when unloaded).
function LevelService.xpToNext(player: Player): number
	local data = DataService.getData(player)
	if not data then
		return 0
	end
	if data.Level >= GameConfig.Levels.MaxLevel then
		return 0
	end
	local need = GameConfig.getXpForLevel(data.Level)
	return math.max(0, need - data.Xp)
end

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------

function LevelService.init(services: { [string]: any })
	DataService = services.DataService
	RemoteService = services.RemoteService
end

function LevelService.start()
	if started then
		return
	end
	started = true
	-- Stateless beyond player data; nothing to schedule.
end

function LevelService.cleanupPlayer(_player: Player)
	-- No per-player runtime state: everything lives in DataService's PlayerData.
end

return LevelService
