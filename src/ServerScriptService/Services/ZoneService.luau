-- ZoneService: level-based zone unlock queries + nearest-zone helper.
-- Contract: ARCHITECTURE.md "Map contract" (v2: NO UnlockPrompt, no cash gates).
-- Zone unlock state is derived from the player's level, so this service owns
-- no data of its own: isZoneUnlocked delegates to LevelService and the gate
-- visuals open per-player on the client (ZoneGateController reacting to
-- DataSync). The server still rejects hustles in locked zones (HustleService).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local Mechanics = require(ReplicatedStorage.Shared.Mechanics)

local ZoneService = {}

-- Injected via init(services) -- never require sibling services directly.
local LevelService

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

-- unlocked <=> data.Level >= zone.UnlockLevel (unknown zone / unloaded -> false).
function ZoneService.isZoneUnlocked(player: Player, zoneId: string): boolean
	if GameConfig.getZone(zoneId) == nil then
		return false
	end
	return LevelService.isZoneUnlocked(player, zoneId)
end

-- Id of the zone whose ring center is closest to a world position.
function ZoneService.getZoneForPosition(position: Vector3): string
	return Mechanics.nearestZoneId(position)
end

-- Level a zone needs (nil for an unknown zone).
function ZoneService.getUnlockLevel(zoneId: string): number?
	local zone = GameConfig.getZone(zoneId)
	return if zone then zone.UnlockLevel else nil
end

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------

function ZoneService.init(services: { [string]: any })
	LevelService = services.LevelService
end

function ZoneService.start()
	-- v2 has no gate prompts to connect: gates are purely visual and open on
	-- the client once the player's level reaches zone.UnlockLevel.
end

function ZoneService.cleanupPlayer(_player: Player)
	-- No per-player state.
end

return ZoneService
