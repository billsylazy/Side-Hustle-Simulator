-- WorkerService (v2): crate hiring (weighted RNG), equip/unequip, passive income tick.
-- Contract: ARCHITECTURE.md "Remotes" + "Upgrades & perks" + "Data schema v2".
-- Equip cap = GameConfig.Workers.BaseEquipSlots + data.Perks.WorkerSlots.
-- Worker income/sec = sum(getWorkerIncome(Rarity, Crate) for the first `cap`
--   equipped workers) * (1 + WorkerEfficiencyPerLevel * Perks.WorkerEfficiency)
--   * GameConfig.getRebirthCashMultiplier(Rebirths), floored, applied every
--   GameConfig.Workers.IncomeTickSeconds via DataService.addCash (which syncs).
-- Server-authoritative: crate existence is checked in the validator (a crate id
-- outside GameConfig can only come from a tampered client), storage/cost/slot
-- caps re-checked in the handlers. All C->S traffic goes through
-- RemoteService.register (rate limit + per-remote cooldown + violation kicks).

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local Types = require(ReplicatedStorage.Shared.Types)

type WorkerEntry = Types.WorkerEntry

local WorkerService = {}

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

-- Perk level from a data table (missing/corrupt -> 0).
local function perkLevel(data: any, perkId: string): number
	local perks = data.Perks
	if typeof(perks) ~= "table" then
		return 0
	end
	local level = perks[perkId]
	return if typeof(level) == "number" then level else 0
end

-- Weighted RNG over crate.Weights. Weights need not sum to 100 (normalized
-- implicitly by rolling against their total). Iterates the ordered rarity
-- list so the roll is stable regardless of dictionary iteration order.
local function rollRarity(crate: GameConfig.CrateDef): GameConfig.RarityDef
	local total = 0
	for _, rarity in GameConfig.WorkerRarities do
		total += crate.Weights[rarity.Id] or 0
	end
	if total <= 0 then
		-- Misconfigured crate; fall back to the most common rarity.
		return GameConfig.WorkerRarities[1]
	end

	local roll = math.random() * total
	local cumulative = 0
	for _, rarity in GameConfig.WorkerRarities do
		cumulative += crate.Weights[rarity.Id] or 0
		if roll < cumulative then
			return rarity
		end
	end
	-- Float edge case (roll == total): rarest bucket.
	return GameConfig.WorkerRarities[#GameConfig.WorkerRarities]
end

local function findWorker(data: any, uid: string): WorkerEntry?
	for _, worker in data.Workers do
		if worker.Uid == uid then
			return worker
		end
	end
	return nil
end

local function countEquipped(data: any): number
	local count = 0
	for _, worker in data.Workers do
		if worker.Equipped then
			count += 1
		end
	end
	return count
end

-- Equipped worker cap = BaseEquipSlots + WorkerSlots perk level.
local function equipCap(data: any): number
	return GameConfig.Workers.BaseEquipSlots + perkLevel(data, "WorkerSlots")
end

-- Public so UI-facing services can show the cap; reads the loaded data only.
function WorkerService.getEquipCap(player: Player): number
	local data = DataService.getData(player)
	if not data then
		return GameConfig.Workers.BaseEquipSlots
	end
	return equipCap(data)
end

----------------------------------------------------------------------
-- Remote handlers
----------------------------------------------------------------------

local function onHireWorker(player: Player, crateId: string)
	-- Data must be loaded.
	local data = DataService.getData(player)
	if not data then
		return
	end

	-- Existence re-checked here even though the validator already did (defense
	-- in depth; the handler must stand on its own).
	local crate = GameConfig.WorkerCrates[crateId]
	if not crate then
		return
	end

	if #data.Workers >= GameConfig.Workers.MaxStorage then
		toast(player, "Worker storage full!", "error")
		return
	end

	if not DataService.spendCash(player, crate.Cost) then
		toast(player, "Not enough cash!", "error")
		return
	end

	local rarity = rollRarity(crate)
	local firstName = GameConfig.WorkerNames[math.random(#GameConfig.WorkerNames)]

	local worker: WorkerEntry = {
		Uid = HttpService:GenerateGUID(false),
		Id = rarity.Id, -- reserved for future distinct characters; currently rarity id
		Rarity = rarity.Id,
		Crate = crateId,
		Name = firstName .. " the " .. rarity.Name,
		Equipped = false,
	}

	-- Auto-equip when a slot is free: nicer first-time UX (hire -> instant income).
	if countEquipped(data) < equipCap(data) then
		worker.Equipped = true
	end

	table.insert(data.Workers, worker)
	data.Stats.WorkersHired += 1

	-- Client plays the crate-open juice off this (art & feel guide).
	RemoteService.fireClient("WorkerHired", player, worker)
	toast(player, "Hired " .. worker.Name .. "!", "success")
	DataService.sync(player)
end

local function onEquipWorker(player: Player, workerUid: string)
	local data = DataService.getData(player)
	if not data then
		return
	end

	local worker = findWorker(data, workerUid)
	if not worker or worker.Equipped then
		-- Unknown uid or already equipped: stale UI, drop silently.
		return
	end

	if countEquipped(data) >= equipCap(data) then
		toast(player, "No free worker slots!", "error")
		return
	end

	worker.Equipped = true
	DataService.sync(player)
end

local function onUnequipWorker(player: Player, workerUid: string)
	local data = DataService.getData(player)
	if not data then
		return
	end

	local worker = findWorker(data, workerUid)
	if not worker or not worker.Equipped then
		return
	end

	worker.Equipped = false
	DataService.sync(player)
end

----------------------------------------------------------------------
-- Passive income tick
----------------------------------------------------------------------

-- Income for one tick: sum of equipped workers' base income, scaled by the
-- WorkerEfficiency perk and the rebirth cash multiplier, floored.
local function computeTickIncome(data: any): number
	-- Count at most equipCap(data) equipped workers: saved data can hold more
	-- Equipped flags than the current cap (the WorkerSlots perk resets on
	-- rebirth), and the extra ones must not earn.
	local base = 0
	local counted = 0
	local cap = equipCap(data)
	for _, worker in data.Workers do
		if worker.Equipped then
			counted += 1
			if counted > cap then
				break
			end
			base += GameConfig.getWorkerIncome(worker.Rarity, worker.Crate)
		end
	end
	if base <= 0 then
		return 0
	end

	local efficiencyMult = 1 + GameConfig.WorkerEfficiencyPerLevel * perkLevel(data, "WorkerEfficiency")
	local rebirths = if typeof(data.Rebirths) == "number" then data.Rebirths else 0
	return math.floor(base * efficiencyMult * GameConfig.getRebirthCashMultiplier(rebirths))
end

-- Public query so UI/other services can show "$/s" without duplicating the math.
function WorkerService.getIncomePerTick(player: Player): number
	local data = DataService.getData(player)
	if not data then
		return 0
	end
	return computeTickIncome(data)
end

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------

function WorkerService.init(services: { [string]: any })
	DataService = services.DataService
	RemoteService = services.RemoteService
end

function WorkerService.start()
	if started then
		return
	end
	started = true

	-- Cooldowns per the ARCHITECTURE.md remotes table; RemoteService adds
	-- rate limiting and violation kicks on top.
	RemoteService.register({
		Name = "HireWorker",
		Cooldown = 0.5,
		Validator = function(_player: Player, crateId: any): (boolean, string?)
			if typeof(crateId) ~= "string" then
				return false, "crateId must be a string"
			end
			if GameConfig.WorkerCrates[crateId] == nil then
				return false, "unknown crateId"
			end
			return true
		end,
		Handler = onHireWorker,
	})

	RemoteService.register({
		Name = "EquipWorker",
		Cooldown = 0.2,
		Validator = function(_player: Player, workerUid: any): (boolean, string?)
			if typeof(workerUid) ~= "string" then
				return false, "workerUid must be a string"
			end
			return true
		end,
		Handler = onEquipWorker,
	})

	RemoteService.register({
		Name = "UnequipWorker",
		Cooldown = 0.2,
		Validator = function(_player: Player, workerUid: any): (boolean, string?)
			if typeof(workerUid) ~= "string" then
				return false, "workerUid must be a string"
			end
			return true
		end,
		Handler = onUnequipWorker,
	})

	-- Passive income tick. addCash syncs (DataSync >= 1/s per player is fine
	-- per contract); players with zero income still get a sync every tick.
	task.spawn(function()
		while true do
			task.wait(GameConfig.Workers.IncomeTickSeconds)
			for _, player in DataService.getLoadedPlayers() do
				local data = DataService.getData(player)
				if data then
					local income = computeTickIncome(data)
					if income > 0 then
						DataService.addCash(player, income)
					else
						-- Keep the >=1/s DataSync cadence even with no income,
						-- so clients whose listeners connected after the load-time
						-- snapshot still receive their data within a second.
						DataService.sync(player)
					end
				end
			end
		end
	end)
end

function WorkerService.cleanupPlayer(_player: Player)
	-- No per-player state here: cooldown/rate bookkeeping is owned by
	-- RemoteService, worker data by DataService. Kept for the uniform shape.
end

return WorkerService
