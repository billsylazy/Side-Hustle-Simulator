--[[
	RemoteService.luau
	Creates ReplicatedStorage.Remotes and every remote named in ARCHITECTURE.md,
	and wraps all C->S handlers with validation, per-remote cooldown, rate
	limiting (timestamps pruned over a 10s window) and violation kicks (SE-5).

	Usage from other services (in start()):
		services.RemoteService.register({
			Name = "BuyUpgrade",
			Cooldown = 0.3,
			Validator = function(player, upgradeId)
				return typeof(upgradeId) == "string", "upgradeId must be a string"
			end,
			Handler = function(player, upgradeId)
				...
			end,
		})
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RemoteService = {}

export type RemoteConfig = {
	Name: string,
	Handler: (player: Player, ...any) -> (),
	-- Return false (optionally with a reason) to reject; rejections count as violations.
	Validator: ((player: Player, ...any) -> (boolean, string?))?,
	Cooldown: number?, -- seconds between accepted fires (default 0 = none)
	RateLimit: number?, -- max fires per RATE_WINDOW (default DEFAULT_MAX_PER_WINDOW)
}

local RATE_WINDOW = 10 -- seconds
local DEFAULT_MAX_PER_WINDOW = 30
local KICK_AFTER_VIOLATIONS = 5

-- Every remote in the ARCHITECTURE.md table. All are RemoteEvents.
local REMOTE_NAMES = {
	-- S -> C
	"DataSync",
	"HustleResult",
	"Toast",
	"WorkerHired",
	"RebirthResult",
	-- C -> S
	"HireWorker",
	"EquipWorker",
	"UnequipWorker",
	"BuyUpgrade",
	"RequestRebirth",
	"ClaimQuest",
}

local initialized = false
local remotes: { [string]: RemoteEvent } = {}

-- Per-player, per-remote request timestamps within the rate window.
local rateTimestamps: { [Player]: { [string]: { number } } } = {}
-- Per-player, per-remote time of the last accepted fire.
local lastAccepted: { [Player]: { [string]: number } } = {}
-- Per-player violation counts (rate limit breaches + validator failures).
local violations: { [Player]: number } = {}

----------------------------------------------------------------------
-- Internals
----------------------------------------------------------------------

local function recordViolation(player: Player, remoteName: string, reason: string)
	local count = (violations[player] or 0) + 1
	violations[player] = count
	warn(`[RemoteService] {player.Name} violation #{count} on "{remoteName}": {reason}`)
	if count >= KICK_AFTER_VIOLATIONS then
		task.defer(function()
			player:Kick("Too many bad requests. Please rejoin.")
		end)
	end
end

local function checkRateLimit(player: Player, remoteName: string, maxPerWindow: number): boolean
	local now = os.clock()

	local perPlayer = rateTimestamps[player]
	if not perPlayer then
		perPlayer = {}
		rateTimestamps[player] = perPlayer
	end

	local timestamps = perPlayer[remoteName]
	if not timestamps then
		timestamps = {}
		perPlayer[remoteName] = timestamps
	end

	-- Prune timestamps that fell out of the window.
	local windowStart = now - RATE_WINDOW
	local pruned: { number } = {}
	for _, ts in timestamps do
		if ts > windowStart then
			table.insert(pruned, ts)
		end
	end
	perPlayer[remoteName] = pruned

	if #pruned >= maxPerWindow then
		recordViolation(player, remoteName, "rate limit exceeded")
		return false
	end

	table.insert(pruned, now)
	return true
end

-- Cooldown misses are dropped silently (double-clicks are not malicious).
local function checkCooldown(player: Player, remoteName: string, cooldown: number): boolean
	local now = os.clock()

	local perPlayer = lastAccepted[player]
	if not perPlayer then
		perPlayer = {}
		lastAccepted[player] = perPlayer
	end

	local last = perPlayer[remoteName]
	if last and now - last < cooldown then
		return false
	end
	perPlayer[remoteName] = now
	return true
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

-- Creates the Remotes folder and every remote. Idempotent: GameManager calls
-- this before service init, and it is called again via the services loop.
function RemoteService.init(_injectedServices: { [string]: any }?)
	if initialized then
		return
	end
	initialized = true

	local folder = ReplicatedStorage:FindFirstChild("Remotes")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Remotes"
		folder.Parent = ReplicatedStorage
	end

	for _, name in REMOTE_NAMES do
		local existing = folder:FindFirstChild(name)
		if existing and existing:IsA("RemoteEvent") then
			remotes[name] = existing
		else
			local remote = Instance.new("RemoteEvent")
			remote.Name = name
			remote.Parent = folder
			remotes[name] = remote
		end
	end

	print(`[RemoteService] Created {#REMOTE_NAMES} remotes`)
end

function RemoteService.start() end

-- Wrap a C->S RemoteEvent handler with rate limit + cooldown + validation.
function RemoteService.register(config: RemoteConfig)
	local remote = remotes[config.Name]
	if not remote then
		error(`[RemoteService] register: unknown remote "{config.Name}" — add it to ARCHITECTURE.md and REMOTE_NAMES first`)
	end

	local cooldown = config.Cooldown or 0
	local maxPerWindow = config.RateLimit or DEFAULT_MAX_PER_WINDOW

	remote.OnServerEvent:Connect(function(player: Player, ...: any)
		if not checkRateLimit(player, config.Name, maxPerWindow) then
			return
		end
		if cooldown > 0 and not checkCooldown(player, config.Name, cooldown) then
			return
		end
		if config.Validator then
			local ok, reason = config.Validator(player, ...)
			if not ok then
				recordViolation(player, config.Name, reason or "invalid arguments")
				return
			end
		end
		config.Handler(player, ...)
	end)
end

-- S->C helper. Never errors on a missing remote; warns instead.
function RemoteService.fireClient(name: string, player: Player, ...: any)
	local remote = remotes[name]
	if not remote then
		warn(`[RemoteService] fireClient: unknown remote "{name}"`)
		return
	end
	remote:FireClient(player, ...)
end

-- Accessor for services that need the instance itself.
function RemoteService.get(name: string): RemoteEvent
	local remote = remotes[name]
	if not remote then
		error(`[RemoteService] get: unknown remote "{name}"`)
	end
	return remote
end

function RemoteService.cleanupPlayer(player: Player)
	rateTimestamps[player] = nil
	lastAccepted[player] = nil
	violations[player] = nil
end

return RemoteService
