-- RebirthService (v2): level-gated rebirth validation, reset and multiplier
-- queries. Contract: ARCHITECTURE.md "Rebirth" + "Remotes".
-- Requires Level >= GameConfig.Rebirth.RequiredLevel and Rebirths < MaxRebirths.
-- Rebirth RESETS: Cash, Level, Xp, Upgrades (fresh per-zone empty tables),
-- Perks (all 0), WalkSpeed back to base, workers unequipped beyond the base cap.
-- KEEPS: Workers, Stats, ClaimedQuests. Rebirths += 1, Stats.TotalRebirths += 1.
-- C->S traffic goes through RemoteService.register (RequestRebirth, 2 s
-- cooldown, no args); result goes back on the RebirthResult RemoteEvent:
--   "SUCCESS", newRebirths, cashMult   |   "INSUFFICIENT", requiredLevel

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

local RebirthService = {}

-- Injected via init(services) -- never require sibling services directly.
local DataService
local RemoteService

local started = false

-- Fires a S->C RemoteEvent to one player via RemoteService.fireClient(name,
-- player, ...); falls back to the contract-pinned ReplicatedStorage.Remotes
-- folder so player feedback never silently drops.
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

local function onRequestRebirth(player: Player)
	-- Data must be loaded.
	local data = DataService.getData(player)
	if not data then
		return
	end

	local requiredLevel = GameConfig.Rebirth.RequiredLevel
	local level = if typeof(data.Level) == "number" then data.Level else 1

	-- Must be below the rebirth cap and have reached the required level.
	if data.Rebirths >= GameConfig.Rebirth.MaxRebirths or level < requiredLevel then
		fireClient(player, "RebirthResult", "INSUFFICIENT", requiredLevel)
		return
	end

	-- Apply the reset (see header). This is the contract's carve-out: the
	-- rebirth reset may assign data fields directly, then DataService.sync.
	local defaults = GameConfig.Data.Defaults()
	data.Cash = 0
	data.Level = 1
	data.Xp = 0
	data.Upgrades = defaults.Upgrades -- fresh per-zone empty tables
	data.Perks = defaults.Perks -- WalkSpeed / WorkerSlots / WorkerEfficiency = 0
	data.Rebirths += 1
	data.Stats.TotalRebirths += 1

	-- WorkerSlots just reset to 0, so the equip cap shrank back to the base.
	-- Unequip any workers beyond the new cap or they would keep earning
	-- against a cap the player no longer owns (WorkerService also clamps the
	-- income tick defensively, but the data should be honest too).
	local cap = GameConfig.Workers.BaseEquipSlots
	local equipped = 0
	for _, worker in data.Workers do
		if worker.Equipped then
			equipped += 1
			if equipped > cap then
				worker.Equipped = false
			end
		end
	end

	-- WalkSpeed perk just reset to level 0 -> back to base walk speed.
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = GameConfig.BaseWalkSpeed
	end

	-- Push the fresh snapshot; sync also refreshes leaderstats (Cash, Level, Rebirths).
	DataService.sync(player)

	-- RebirthWatcher plays the full-screen celebration off this.
	fireClient(
		player,
		"RebirthResult",
		"SUCCESS",
		data.Rebirths,
		GameConfig.getRebirthCashMultiplier(data.Rebirths)
	)
end

function RebirthService.init(services: { [string]: any })
	DataService = services.DataService
	RemoteService = services.RemoteService
end

function RebirthService.start()
	if started then
		return
	end
	started = true

	-- RemoteService.register handles type validation, the per-remote cooldown
	-- (2 s, per the remotes table), rate limiting and violation kicks.
	RemoteService.register({
		Name = "RequestRebirth",
		Cooldown = 2,
		Handler = onRequestRebirth,
	})
end

-- cashMult = 1 + GameConfig.Rebirth.CashBonusPerRebirth * rebirths.
-- Delegates to GameConfig so there is exactly one source of truth.
function RebirthService.getCashMultiplier(rebirths: number): number
	return GameConfig.getRebirthCashMultiplier(rebirths)
end

-- xpMult = 1 + GameConfig.Rebirth.XpBonusPerRebirth * rebirths.
function RebirthService.getXpMultiplier(rebirths: number): number
	return GameConfig.getRebirthXpMultiplier(rebirths)
end

-- True when the player could rebirth right now (UI/other services may ask).
function RebirthService.canRebirth(player: Player): boolean
	local data = DataService.getData(player)
	if not data then
		return false
	end
	return data.Rebirths < GameConfig.Rebirth.MaxRebirths and data.Level >= GameConfig.Rebirth.RequiredLevel
end

function RebirthService.cleanupPlayer(_player: Player)
	-- No per-player state here: the RequestRebirth cooldown bookkeeping is
	-- owned by RemoteService. Kept for the uniform service module shape.
end

return RebirthService
