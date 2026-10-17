--!strict
-- Mechanics: PURE helpers shared by server and client (no services, no state).
-- The server resolves outcomes with these; the client renders previews with
-- the same functions so what the player sees matches what they get paid.

local GameConfig = require(script.Parent.GameConfig)

local Mechanics = {}

-- 0..1 hype/market factor for a Timing zone at a given server time
-- (workspace:GetServerTimeNow()). Smooth sine; both sides compute identically.
function Mechanics.marketFactor(zone: GameConfig.ZoneDef, serverTime: number): number
	local period = zone.MarketPeriod
	if period <= 0 then
		return 1
	end
	local phase = (serverTime % period) / period
	return (math.sin(phase * math.pi * 2) + 1) / 2
end

-- Cash multiplier for a Timing zone at a given server time.
function Mechanics.marketMult(zone: GameConfig.ZoneDef, serverTime: number): number
	local timing = GameConfig.Mechanics.Timing
	local factor = Mechanics.marketFactor(zone, serverTime)
	return timing.MinMult + (timing.MaxMult - timing.MinMult) * factor
end

-- Ring position of a zone center on the ground plane (Y = 0).
-- MapBuilder MUST place zones with this so nearestZoneId is accurate.
function Mechanics.zoneCenter(zoneOrder: number): Vector3
	local angle = math.rad((zoneOrder - 1) * GameConfig.Map.ZoneAngleStep)
	local radius = GameConfig.Map.ZoneRadius
	return Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
end

-- CFrame at a zone's center with -Z facing the plaza (origin).
function Mechanics.zoneGroundCFrame(zoneOrder: number): CFrame
	local pos = Mechanics.zoneCenter(zoneOrder)
	return CFrame.lookAt(pos, Vector3.new(0, 0, 0))
end

-- Id of the zone whose center is closest to a world position (XZ plane).
function Mechanics.nearestZoneId(position: Vector3): string
	local bestId = GameConfig.StartingZoneId
	local bestDistance = math.huge
	local flat = Vector3.new(position.X, 0, position.Z)
	for _, zone in GameConfig.Zones do
		local distance = (Mechanics.zoneCenter(zone.Order) - flat).Magnitude
		if distance < bestDistance then
			bestDistance = distance
			bestId = zone.Id
		end
	end
	return bestId
end

-- Effective cooldown for a zone given the player's upgrades table.
function Mechanics.cooldownFor(zone: GameConfig.ZoneDef, upgradesTable: any): number
	local speed = GameConfig.UpgradeEffects.Speed
	local level = GameConfig.getZoneEffectLevel(upgradesTable, zone.Id, "Speed")
	local factor = math.max(speed.MinCooldownFactor, 1 - speed.PerLevel * level)
	return zone.HustleCooldown * factor
end

-- Automation payout fraction for an Auto upgrade level (0 when level is 0).
function Mechanics.autoPercent(autoLevel: number): number
	if autoLevel <= 0 then
		return 0
	end
	local auto = GameConfig.UpgradeEffects.Auto
	return auto.BasePercent + auto.PercentPerLevel * (autoLevel - 1)
end

return Mechanics
