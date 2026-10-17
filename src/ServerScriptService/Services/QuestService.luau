-- QuestService: one-time quest claiming. Progress is never tracked here --
-- quests read the lifetime Stats that other services already maintain
-- (HustleCount, TotalCashEarned, WorkersHired, ZonesUnlockedCount,
-- TotalRebirths), so the client renders progress straight from DataSync and
-- the server only validates claims.
-- Contract: ARCHITECTURE.md "Remotes" + GameConfig.Quests.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

local QuestService = {}

-- Injected via init(services) -- never require sibling services directly.
local DataService
local RemoteService

local started = false

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

local function toast(player: Player, message: string, kind: string)
	RemoteService.fireClient("Toast", player, message, kind)
end

----------------------------------------------------------------------
-- Remote handler
----------------------------------------------------------------------

local function onClaimQuest(player: Player, questId: string)
	-- Data must be loaded.
	local data = DataService.getData(player)
	if not data then
		return
	end

	-- Existence re-checked here even though the validator already did (defense
	-- in depth; the handler must stand on its own).
	local quest = GameConfig.getQuest(questId)
	if not quest then
		return
	end

	-- One-time only. A legit client disables claimed rows, so drop silently.
	if data.ClaimedQuests[questId] then
		return
	end

	-- Progress comes from lifetime Stats (survive rebirth).
	local progress = data.Stats[quest.Stat]
	if typeof(progress) ~= "number" or progress < quest.Target then
		toast(player, "Quest not complete yet!", "error")
		return
	end

	-- Mark claimed BEFORE paying out so a re-entrant claim can never double-pay.
	data.ClaimedQuests[questId] = true
	DataService.addCash(player, quest.Reward)
	toast(player, "Quest complete: +$" .. quest.Reward .. "!", "success")
	DataService.sync(player)
end

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------

function QuestService.init(services: { [string]: any })
	DataService = services.DataService
	RemoteService = services.RemoteService
end

function QuestService.start()
	if started then
		return
	end
	started = true

	-- Cooldown per the ARCHITECTURE.md remotes table; RemoteService adds
	-- rate limiting and violation kicks on top.
	RemoteService.register({
		Name = "ClaimQuest",
		Cooldown = 0.3,
		Validator = function(_player: Player, questId: any): (boolean, string?)
			if typeof(questId) ~= "string" then
				return false, "questId must be a string"
			end
			if GameConfig.getQuest(questId) == nil then
				return false, "unknown questId"
			end
			return true
		end,
		Handler = onClaimQuest,
	})
end

function QuestService.cleanupPlayer(_player: Player)
	-- No per-player state here: cooldown/rate bookkeeping is owned by
	-- RemoteService, claim state by DataService. Kept for the uniform shape.
end

return QuestService
