-- HustleService: the core "hustle" action via each zone's HustleStation
-- ProximityPrompt, the four mechanics, cash/XP grants and the automation tick.
-- Contract: ARCHITECTURE.md "Earnings, XP and mechanics" + "Map contract".
--
-- Per zone: base = zone.HustleEarn, xpBase = zone.XpPerHustle, U = data.Upgrades[zoneId]
--   earnMult = 1 + Earn.PerLevel * U[Earn], xpMult = 1 + Xp.PerLevel * U[Xp]
--   cooldown = Mechanics.cooldownFor(zone, data.Upgrades)
--   manualCash = floor(base * earnMult * mechMult * rebirthCash)
--   manualXp   = floor(xpBase * xpMult * mechXpMult * rebirthXp)
-- Mechanics (all resolved HERE, never on the client):
--   Tap    - combo stacks while hits land within ComboWindow of the last ACCEPTED hit
--   Hold   - one hit per completed hold (prompt HoldDuration), mechMult = Hold.PayoutMult
--   Timing - shared server clock, mechMult = Mechanics.marketMult; >= PeakThreshold = "Peak"
--   Charge - every hit pays HitPercent of manual; the ChargeMax-th hit is the "Burst"
-- Automation: every Auto.Interval seconds each unlocked zone with Auto level > 0 pays
--   floor(manualCash_noMech * autoPercent) cash + the same fraction of XP, Kind "Auto".
-- Server-authoritative: validates data loaded, zone unlocked by level, distance
-- (< 20 studs from the prompt part) and per-player per-zone cooldown.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local Mechanics = require(ReplicatedStorage.Shared.Mechanics)
local Types = require(ReplicatedStorage.Shared.Types)

type HustleResultPayload = Types.HustleResultPayload
type PlayerData = Types.PlayerData

local HustleService = {}

-- Injected via init(services) -- never require sibling services directly.
local DataService
local RemoteService
local LevelService
local ZoneService

local started = false

local MAX_PROMPT_DISTANCE = 20 -- studs; re-validated server-side per contract
local LOCKED_TOAST_THROTTLE = 2 -- seconds between "locked zone" toasts, per player
local MAP_WAIT_TIMEOUT = 30 -- MapBuilder runs before start(); this is a safety net
local CHILD_WAIT_TIMEOUT = 5

-- Per-player per-zone mechanic state. lastHit doubles as the cooldown stamp:
-- it only ever records ACCEPTED hits, so an early (ignored) tap can neither
-- reset a combo nor extend a cooldown.
type ZoneState = {
	lastHit: number, -- os.clock() of the last accepted hit (0 = never)
	combo: number, -- Tap zones: current stack, 0..ComboMax
	charge: number, -- Charge zones: hits banked toward the next burst
	nextDue: number, -- Hold zones: os.clock() the next hit is scheduled for
}

-- Player -> zoneId -> ZoneState; cleared in cleanupPlayer.
local zoneStates: { [Player]: { [string]: ZoneState } } = {}
-- Player -> os.clock() of the last "locked zone" toast (throttle).
local lockedToastAt: { [Player]: number } = {}
-- Mechanic names we already warned about (unknown zone.Mechanic strings).
local warnedMechanics: { [string]: boolean } = {}

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

-- Payouts round to nearest: flooring small bases (Lemonade's $5) would make
-- the first +25% upgrade and early combo stacks pay exactly nothing extra.
local function round(x: number): number
	return math.floor(x + 0.5)
end

local function toast(player: Player, message: string, kind: string)
	RemoteService.fireClient("Toast", player, message, kind)
end

local function fireHustleResult(player: Player, zoneId: string, payload: HustleResultPayload)
	RemoteService.fireClient("HustleResult", player, zoneId, payload)
end

local function getZoneState(player: Player, zoneId: string): ZoneState
	local perPlayer = zoneStates[player]
	if not perPlayer then
		perPlayer = {}
		zoneStates[player] = perPlayer
	end
	local state = perPlayer[zoneId]
	if not state then
		state = { lastHit = 0, combo = 0, charge = 0, nextDue = 0 }
		perPlayer[zoneId] = state
	end
	return state
end

-- Upgrade/rebirth multipliers for one zone (everything except the mechanic).
local function getZoneMultipliers(data: PlayerData, zoneId: string): (number, number, number, number)
	local effects = GameConfig.UpgradeEffects
	local earnLevel = GameConfig.getZoneEffectLevel(data.Upgrades, zoneId, "Earn")
	local xpLevel = GameConfig.getZoneEffectLevel(data.Upgrades, zoneId, "Xp")
	local earnMult = 1 + effects.Earn.PerLevel * earnLevel
	local xpMult = 1 + effects.Xp.PerLevel * xpLevel
	local rebirthCash = GameConfig.getRebirthCashMultiplier(data.Rebirths)
	local rebirthXp = GameConfig.getRebirthXpMultiplier(data.Rebirths)
	return earnMult, xpMult, rebirthCash, rebirthXp
end

-- manualCash / manualXp for a zone at the given mechanic multipliers.
local function computeManual(zone: GameConfig.ZoneDef, data: PlayerData, mechMult: number, mechXpMult: number): (number, number)
	local earnMult, xpMult, rebirthCash, rebirthXp = getZoneMultipliers(data, zone.Id)
	local cash = round(zone.HustleEarn * earnMult * mechMult * rebirthCash)
	local xp = round(zone.XpPerHustle * xpMult * mechXpMult * rebirthXp)
	return math.max(0, cash), math.max(0, xp)
end

-- Resolves the zone's mechanic for one accepted hit: mutates the per-zone
-- state and returns the full HustleResult payload (Amount/Xp included).
local function resolveMechanic(zone: GameConfig.ZoneDef, data: PlayerData, state: ZoneState, now: number): HustleResultPayload
	local mechanic = zone.Mechanic
	local params = GameConfig.Mechanics

	if mechanic == "Tap" then
		local tap = params.Tap
		-- Combo continues only when this hit lands within ComboWindow of the
		-- previous ACCEPTED hit; a first-ever hit (lastHit = 0) starts at 0.
		if state.lastHit > 0 and now - state.lastHit <= tap.ComboWindow then
			state.combo = math.min(state.combo + 1, tap.ComboMax)
		else
			state.combo = 0
		end
		local mechMult = 1 + tap.ComboBonusPerStack * state.combo
		local cash, xp = computeManual(zone, data, mechMult, 1)
		return {
			Amount = cash,
			Xp = xp,
			Kind = "Manual",
			Mult = mechMult,
			Combo = state.combo,
		}
	elseif mechanic == "Timing" then
		local timing = params.Timing
		-- Shared clock: the client previews the same curve with the same function.
		-- The trigger arrives one-way latency after the press, so judge the
		-- flip at arrival OR PeakGrace earlier: a press the client saw inside
		-- the green window must not land off-peak and wipe the streak.
		local serverNow = Workspace:GetServerTimeNow()
		local marketMult = math.max(
			Mechanics.marketMult(zone, serverNow),
			Mechanics.marketMult(zone, serverNow - timing.PeakGrace)
		)
		local isPeak = marketMult >= timing.PeakThreshold
		-- Peak flips build a streak (stored in state.combo) that multiplies
		-- cash and XP; an off-peak flip sells cheap and resets it, so timing
		-- beats spamming at every cooldown.
		local mechMult: number
		local mechXpMult: number
		if isPeak then
			state.combo = math.min(state.combo + 1, timing.StreakMax)
			local streakMult = 1 + timing.StreakBonusPerStack * (state.combo - 1)
			mechMult = marketMult * streakMult
			mechXpMult = (1 + timing.PeakXpBonus) * streakMult
		else
			state.combo = 0
			mechMult = marketMult * timing.OffPeakMult
			mechXpMult = timing.OffPeakMult
		end
		local cash, xp = computeManual(zone, data, mechMult, mechXpMult)
		return {
			Amount = cash,
			Xp = xp,
			Kind = if isPeak then "Peak" else "Manual",
			Mult = mechMult,
			Combo = state.combo,
		}
	elseif mechanic == "Charge" then
		local charge = params.Charge
		local chargeMax = math.max(1, zone.ChargeMax)
		local manualCash, manualXp = computeManual(zone, data, 1, 1)
		state.charge += 1
		if state.charge >= chargeMax then
			-- The ChargeMax-th hit IS the burst: it pays the burst instead of a
			-- partial hit, then the bar empties.
			state.charge = 0
			local burstMult = chargeMax * charge.BurstMult
			return {
				Amount = round(manualCash * burstMult),
				Xp = round(manualXp * chargeMax * (1 + charge.BurstXpBonus)),
				Kind = "Burst",
				Mult = burstMult,
				Charge = 0,
				ChargeMax = chargeMax,
			}
		end
		return {
			Amount = round(manualCash * charge.HitPercent),
			Xp = round(manualXp * charge.HitPercent),
			Kind = "Manual",
			Mult = 1,
			Charge = state.charge,
			ChargeMax = chargeMax,
		}
	end

	-- Hold (and any unknown mechanic, which degrades to a plain hit).
	if mechanic ~= "Hold" and not warnedMechanics[mechanic] then
		warnedMechanics[mechanic] = true
		warn("[HustleService] Unknown Mechanic '" .. tostring(mechanic) .. "' on zone " .. zone.Id .. "; treating as Hold")
	end
	local mechMult = if mechanic == "Hold" then params.Hold.PayoutMult else 1
	local cash, xp = computeManual(zone, data, mechMult, 1)
	return {
		Amount = cash,
		Xp = xp,
		Kind = "Manual",
		Mult = mechMult,
	}
end

----------------------------------------------------------------------
-- Manual hustle (ProximityPrompt.Triggered)
----------------------------------------------------------------------

local function onHustleTriggered(zone: GameConfig.ZoneDef, promptPart: BasePart, player: Player)
	-- Data must be loaded.
	local data = DataService.getData(player)
	if not data then
		return
	end

	-- Zone must be unlocked by level. Locked-zone prompts stay visible on the
	-- client (ProximityPrompt.Enabled cannot be set per-player), so the server
	-- is the real gate: reject + toast, throttled to one toast per 2 s per player.
	if not ZoneService.isZoneUnlocked(player, zone.Id) then
		local now = os.clock()
		if now - (lockedToastAt[player] or 0) >= LOCKED_TOAST_THROTTLE then
			lockedToastAt[player] = now
			toast(player, "Reach level " .. zone.UnlockLevel .. " to unlock " .. zone.Name .. "!", "error")
		end
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

	-- Per-player, per-zone cooldown (Speed upgrade shortens it); early
	-- triggers are silently ignored and leave the mechanic state untouched.
	local state = getZoneState(player, zone.Id)
	local now = os.clock()
	local cooldown = Mechanics.cooldownFor(zone, data.Upgrades)
	if zone.Mechanic == "Hold" then
		-- HoldPromptController stretches the local hold to the full cooldown,
		-- so legit triggers are >= cooldown + re-press time apart. TriggerGrace
		-- absorbs network jitter, and the schedule advances a full cooldown per
		-- accepted hit, so the grace never compounds: the long-run rate stays
		-- capped at 1/cooldown even for a client that skips the hold.
		if now < state.nextDue - GameConfig.Mechanics.Hold.TriggerGrace then
			return
		end
		state.nextDue = math.max(now, state.nextDue) + cooldown
	elseif state.lastHit > 0 and now - state.lastHit < cooldown then
		return
	end

	-- All checks passed: resolve the mechanic, then stamp this accepted hit.
	local payload = resolveMechanic(zone, data, state, now)
	state.lastHit = now

	-- Bump the lifetime stat before addCash so the DataSync snapshot that
	-- addCash fires already carries the new HustleCount (quests read it).
	data.Stats.HustleCount += 1
	if payload.Amount > 0 then
		-- addXp below syncs, so skip addCash's own sync when XP follows.
		DataService.addCash(player, payload.Amount, payload.Xp > 0)
	end
	if payload.Xp > 0 then
		LevelService.addXp(player, payload.Xp)
	end
	if payload.Amount <= 0 and payload.Xp <= 0 then
		DataService.sync(player)
	end

	-- Client plays money popup / combo / peak / burst juice off this.
	fireHustleResult(player, zone.Id, payload)
end

-- Resolves one zone's hustle prompt and connects it. Each step uses
-- WaitForChild with a timeout and warns + skips on failure, so one missing
-- part never kills the server or the other zones.
local function connectHustleStation(zonesFolder: Instance, zone: GameConfig.ZoneDef)
	local zoneModel = zonesFolder:WaitForChild(zone.Id, CHILD_WAIT_TIMEOUT)
	if not zoneModel then
		warn("[HustleService] Zone model missing for " .. zone.Id .. "; hustle prompt skipped")
		return
	end

	local station = zoneModel:WaitForChild("HustleStation", CHILD_WAIT_TIMEOUT)
	if not station then
		warn("[HustleService] HustleStation missing for zone " .. zone.Id .. "; hustle prompt skipped")
		return
	end

	local promptPart = station:WaitForChild("PromptPart", CHILD_WAIT_TIMEOUT)
	if not promptPart or not promptPart:IsA("BasePart") then
		warn("[HustleService] HustleStation PromptPart missing for zone " .. zone.Id .. "; hustle prompt skipped")
		return
	end

	local prompt = promptPart:WaitForChild("HustlePrompt", CHILD_WAIT_TIMEOUT)
	if not prompt or not prompt:IsA("ProximityPrompt") then
		warn("[HustleService] HustlePrompt missing for zone " .. zone.Id .. "; hustle prompt skipped")
		return
	end

	-- Prompt connections live for the server's lifetime; per-player state is
	-- cleared in cleanupPlayer instead.
	prompt.Triggered:Connect(function(player: Player)
		onHustleTriggered(zone, promptPart, player)
	end)
end

----------------------------------------------------------------------
-- Automation tick
----------------------------------------------------------------------

-- One automation tick for one player: cash for ALL zones first (one addCash
-- -> one DataSync), then XP once with the total (one addXp -> one sync, plus
-- any level-ups), then one HustleResult per zone so the client can float a
-- "+$50" at each station.
local function tickAutomationFor(player: Player)
	local data = DataService.getData(player)
	if not data then
		return
	end

	local totalCash = 0
	local totalXp = 0
	local zonesTicked = 0
	local results: { { zoneId: string, payload: HustleResultPayload } } = {}

	for _, zone in GameConfig.Zones do
		local autoLevel = GameConfig.getZoneEffectLevel(data.Upgrades, zone.Id, "Auto")
		if autoLevel > 0 and LevelService.isZoneUnlocked(player, zone.Id) then
			local percent = Mechanics.autoPercent(autoLevel)
			local manualCash, manualXp = computeManual(zone, data, 1, 1)
			local amount = round(manualCash * percent)
			local xp = round(manualXp * percent)
			totalCash += amount
			totalXp += xp
			zonesTicked += 1
			table.insert(results, {
				zoneId = zone.Id,
				payload = {
					Amount = amount,
					Xp = xp,
					Kind = "Auto",
					Mult = 1,
				},
			})
		end
	end

	if zonesTicked == 0 then
		return
	end

	-- Stat first so the snapshot addCash fires already carries it.
	data.Stats.AutoHustleCount += zonesTicked
	if totalCash > 0 then
		DataService.addCash(player, totalCash, totalXp > 0)
	end
	if totalXp > 0 then
		LevelService.addXp(player, totalXp)
	end
	if totalCash <= 0 and totalXp <= 0 then
		-- Nothing else synced the stat bump; keep the client honest.
		DataService.sync(player)
	end

	for _, result in results do
		fireHustleResult(player, result.zoneId, result.payload)
	end
end

local function automationLoop()
	local interval = GameConfig.UpgradeEffects.Auto.Interval
	while true do
		task.wait(interval)
		for _, player in DataService.getLoadedPlayers() do
			-- One player's failure must never stall everyone else's rigs.
			local ok, err = pcall(tickAutomationFor, player)
			if not ok then
				warn("[HustleService] Automation tick failed for " .. player.Name .. ": " .. tostring(err))
			end
		end
	end
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

-- What ONE plain manual hit (mechMult 1) in this zone pays the player right
-- now, plus the effective cooldown. nil when the zone is unknown or the
-- player's data is not loaded. For UI/debug use.
function HustleService.getManualPreview(player: Player, zoneId: string): { Cash: number, Xp: number, Cooldown: number }?
	local zone = GameConfig.getZone(zoneId)
	if not zone then
		return nil
	end
	local data = DataService.getData(player)
	if not data then
		return nil
	end
	local cash, xp = computeManual(zone, data, 1, 1)
	return {
		Cash = cash,
		Xp = xp,
		Cooldown = Mechanics.cooldownFor(zone, data.Upgrades),
	}
end

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------

function HustleService.init(services: { [string]: any })
	DataService = services.DataService
	RemoteService = services.RemoteService
	LevelService = services.LevelService
	ZoneService = services.ZoneService
end

function HustleService.start()
	if started then
		return
	end
	started = true

	-- Automation runs regardless of whether the map resolved: it pays from
	-- data, not from world instances.
	task.spawn(automationLoop)

	local map = Workspace:WaitForChild("SideHustleMap", MAP_WAIT_TIMEOUT)
	if not map then
		warn("[HustleService] Workspace.SideHustleMap missing; no hustle prompts connected")
		return
	end

	local zonesFolder = map:WaitForChild("Zones", CHILD_WAIT_TIMEOUT)
	if not zonesFolder then
		warn("[HustleService] SideHustleMap.Zones missing; no hustle prompts connected")
		return
	end

	-- EVERY zone has a hustle station, including the free starting zone.
	for _, zone in GameConfig.Zones do
		task.spawn(connectHustleStation, zonesFolder, zone)
	end
end

function HustleService.cleanupPlayer(player: Player)
	zoneStates[player] = nil
	lockedToastAt[player] = nil
end

return HustleService
