-- RebirthService: rebirth validation, reset and multiplier queries.
-- Contract: ARCHITECTURE.md "Earnings math" + "Remotes".
-- Requirement = GameConfig.getRebirthRequirement(Rebirths), checked against
-- CashThisLife. Rebirth RESETS: Cash, CashThisLife, UnlockedZones (back to the
-- starting zone), all Upgrades to 0. KEEPS: Workers (equip state as-is),
-- Stats, ClaimedQuests. Rebirths += 1, Stats.TotalRebirths += 1.
-- C->S traffic goes through RemoteService.register (RequestRebirth, 2 s
-- cooldown, no args); result goes back on the RebirthResult RemoteEvent.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

local RebirthService = {}

-- Injected via init(services) -- never require sibling services directly.
local DataService
local RemoteService

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

	local requirement = GameConfig.getRebirthRequirement(data.Rebirths)

	-- Must be below the rebirth cap and have earned enough THIS life.
	if data.Rebirths >= GameConfig.Rebirth.MaxRebirths or data.CashThisLife < requirement then
		fireClient(player, "RebirthResult", "INSUFFICIENT", requirement)
		return
	end

	-- Apply the reset (see header). Setting every existing upgrade key to 0
	-- (rather than replacing the table) keeps the schema's key set intact.
	data.Cash = 0
	data.CashThisLife = 0
	data.UnlockedZones = { GameConfig.StartingZoneId }
	for upgradeId in data.Upgrades do
		data.Upgrades[upgradeId] = 0
	end
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

	-- WalkSpeed upgrade just reset to level 0 -> back to base walk speed.
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = GameConfig.BaseWalkSpeed
	end

	-- Push the fresh snapshot; sync also refreshes leaderstats (Cash, Rebirths).
	DataService.sync(player)

	-- RebirthWatcher plays the full-screen celebration off this.
	fireClient(
		player,
		"RebirthResult",
		"SUCCESS",
		data.Rebirths,
		GameConfig.getRebirthMultiplier(data.Rebirths)
	)
end

function RebirthService.init(services: { [string]: any })
	DataService = services.DataService
	RemoteService = services.RemoteService
end

function RebirthService.start()
	-- RemoteService.register handles type validation, the per-remote cooldown
	-- (2 s, per the remotes table), rate limiting and violation kicks.
	RemoteService.register({
		Name = "RequestRebirth",
		Cooldown = 2,
		Handler = onRequestRebirth,
	})
end

-- rebirthMult = 1 + GameConfig.Rebirth.BonusPerRebirth * rebirths.
-- Delegates to GameConfig so there is exactly one source of truth.
function RebirthService.getMultiplier(rebirths: number): number
	return GameConfig.getRebirthMultiplier(rebirths)
end

function RebirthService.cleanupPlayer(player: Player)
	-- No per-player state here: the RequestRebirth cooldown bookkeeping is
	-- owned by RemoteService. Kept for the uniform service module shape.
end

return RebirthService
