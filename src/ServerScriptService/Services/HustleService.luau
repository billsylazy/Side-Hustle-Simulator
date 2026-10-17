-- HustleService: handles the core "hustle" action via each zone's
-- HustleStation ProximityPrompt and applies the earnings math.
-- Contract: ARCHITECTURE.md "Map contract" + "Earnings math".
-- Hustle earn = floor(zone.HustleEarn * (1 + 0.25 * HustlePowerLevel) * rebirthMult).
-- Server-authoritative: validates data loaded, zone unlocked, per-player
-- per-zone cooldown (zone.HustleCooldown) and distance (< 20 studs).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

local HustleService = {}

-- Injected via init(services) -- never require sibling services directly.
local DataService
local RemoteService
local ZoneService

local MAX_PROMPT_DISTANCE = 20 -- studs; re-validated server-side per contract
local LOCKED_TOAST_THROTTLE = 2 -- seconds between "locked zone" toasts, per player
local MAP_WAIT_TIMEOUT = 30 -- MapBuilder runs before start(); this is a safety net
local CHILD_WAIT_TIMEOUT = 5

-- UserId -> zoneId -> os.clock() of the last successful hustle
local hustleCooldowns: { [number]: { [string]: number } } = {}
-- UserId -> os.clock() of the last "locked zone" toast
local lockedToastAt: { [number]: number } = {}

-- Fires a S->C RemoteEvent to one player. Prefers the RemoteService wrapper
-- (assumed API: RemoteService.fireClient(player, remoteName, ...)); falls back
-- to the contract-pinned ReplicatedStorage.Remotes folder so player feedback
-- never silently drops if the wrapper exposes a differently-named fire API.
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

local function onHustleTriggered(zone: GameConfig.ZoneDef, promptPart: BasePart, player: Player)
	-- Data must be loaded.
	local data = DataService.getData(player)
	if not data then
		return
	end

	-- Zone must be unlocked. Locked-zone prompts stay visible on the client
	-- (ProximityPrompt.Enabled cannot be set per-player), so the server is the
	-- real gate: reject + toast, throttled to one toast per 2 s per player.
	if not ZoneService.isZoneUnlocked(player, zone.Id) then
		local now = os.clock()
		if now - (lockedToastAt[player.UserId] or 0) >= LOCKED_TOAST_THROTTLE then
			lockedToastAt[player.UserId] = now
			fireClient(player, "Toast", "Unlock this hustle first!", "error")
		end
		return
	end

	-- Per-player, per-zone cooldown; early triggers are silently ignored.
	local userCooldowns = hustleCooldowns[player.UserId]
	if not userCooldowns then
		userCooldowns = {}
		hustleCooldowns[player.UserId] = userCooldowns
	end
	local now = os.clock()
	if now - (userCooldowns[zone.Id] or 0) < zone.HustleCooldown then
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

	-- All checks passed: this attempt consumes the cooldown.
	userCooldowns[zone.Id] = now

	-- Earnings math (ARCHITECTURE.md): base * hustle-power multiplier * rebirth multiplier.
	local hustlePowerLevel = data.Upgrades.HustlePower or 0
	local amount = math.floor(
		zone.HustleEarn
			* (1 + GameConfig.HustlePowerPerLevel * hustlePowerLevel)
			* GameConfig.getRebirthMultiplier(data.Rebirths)
	)

	-- Bump the lifetime stat before addCash so the DataSync snapshot that
	-- addCash fires already carries the new HustleCount (quests read it).
	data.Stats.HustleCount += 1
	DataService.addCash(player, amount)

	-- Client plays money popup + coin sound off this (art & feel guide juice).
	fireClient(player, "HustleResult", zone.Id, amount)
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

function HustleService.init(services: { [string]: any })
	DataService = services.DataService
	RemoteService = services.RemoteService
	ZoneService = services.ZoneService
end

function HustleService.start()
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
	hustleCooldowns[player.UserId] = nil
	lockedToastAt[player.UserId] = nil
end

return HustleService
