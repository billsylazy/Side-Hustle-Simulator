--!nonstrict
-- CityLifeSim: the downtown's ambient life (traffic, pedestrians, sky) as a
-- PURE, deterministic simulation over Shared/CityLayout. It creates its rigs
-- once (ChibiRig citizens, VehicleRig vehicles, birds, a blimp, rooftop coins)
-- and then only does CFrame math: no services, no events, no Instance creation
-- and no table allocation per step. Two shells drive it:
--   * StarterPlayerScripts/Controllers/CityLifeController (client, Heartbeat +
--     workspace:BulkMoveTo, real players and camera)
--   * tools/render/preview_life.luau (offline render: warm up a few seconds,
--     then write one full snapshot into Workspace.LifePreview)
-- so the renders show exactly what the game shows.
--
-- API
--   CityLifeSim.Config                         -- tuning (radii, speeds, LOD, timings)
--   CityLifeSim.TIERS / TIER_ORDER             -- device tiers "High" / "Medium" / "Low"
--   CityLifeSim.detectTier(info) -> tier       -- pure: { touch, keyboard, quality } -> tier
--   CityLifeSim.new(folder, tier?) -> sim      -- builds every rig into `folder` (tier
--       "Low": about half the crowd; default "High", what the renders show)
--   sim:bindMap(map)                           -- once SideHustleMap exists: traffic
--       light lamps (recolored locally by state), entrance carpets, rooftop coins
--       on every DomeFinial, parts/models carrying the "CitySpin" attribute
--       (deg/s), the zone customers, the city pulse (map neon) and the zone
--       life (hero-prop spinners, ticker chase, heartbeat, car-wash car,
--       agility dogs)
--   sim:unbindMap()                            -- restores every map color /
--       transparency the city pulse changed and the spun zone props' CFrames
--       (the shell calls it on stop)
--   sim.playerPos: { Vector3 }, sim.playerCount -- filled by the shell before step()
--   sim:heartbeat(dt, cameraPos?, cameraLook?) -> n -- the shell's per-Heartbeat entry: the
--       runtime governor (Heartbeat dt EMA -> runtime tier) + the tier's step rate
--       (Low: one step every 2nd Heartbeat); n = 0 on a Heartbeat without a step
--   sim:step(dt, cameraPos?, forceAll?, cameraLook?) -> n -- advances the world; the
--       moved parts are sim.outParts[1..n] with sim.outCFrames[1..n] (feed straight
--       to BulkMoveTo; at most the runtime tier's part cap unless forceAll)
--   sim:setRuntimeTier(tier)                   -- LOD radii / part cap / step rate only
--   sim:advance(seconds, dt)                   -- simulate without posing (warm-up)
--   sim:getCounts() -> { citizens, walkers, shoppers, crossers, customers, customerParts,
--       vehicles, police, zoneSpinGroups, zoneSkipped, washCar, courseDogs, zoneLifeParts,
--       washers, birds, pigeons, clouds, balloons, dogs, coins, spinners, pulseFrames,
--       anchorFrames, pulseTrims, tickerGroups, heartParts, pulseTips, pulseBlades, parts }
--
-- Behaviour summary
--   Traffic (20 vehicles): 18 on the 4 CityLayout ring-road lanes (right-hand
--     traffic; lanes never touch pads or the plaza; one is a police car whose
--     lightbar flashes) + a taxi and a car on the Back Avenue
--     (CityLayout.backLaneLoops, no lights). Each keeps a slot on an evenly
--     spaced schedule (catch-up up to +30%), keeps MinGap to the vehicle ahead,
--     stops for amber/red crosswalk lights (ring road only), for a player
--     standing ON its asphalt lane ahead (at most PlayerYieldMax 3 s, then it
--     creeps through at PlayerCreepSpeed with a little hop: life parts never
--     collide, so one idle player can never stop a lane), and the bus dwells
--     at CityLayout.busStops. Speed eases exponentially (rate 6/s) and never
--     overshoots a stop (hard clamp).
--   Crosswalk lights: one per zone axis. A waiting crosser requests -> amber ->
--     red for cars -> once the zebra band is clear every ready crosser of that
--     zebra steps off, joined by everyone there whose wait ends within
--     CrossJoinWindow s (each after a 0..0.8 s hash delay) -> the light holds
--     red until the last of them is off the asphalt -> green (>= MinGo 10 s).
--     A player on the zebra holds / extends the red at most PlayerHoldMax 6 s
--     per red phase, then the lights cycle normally.
--   Performance (see TIERS): device tier at start ("Low" builds about half the
--     crowd and steps at 30 Hz), a runtime governor that steps the LOD / part
--     cap / step rate down one tier while frames are slow (and back up),
--     distance + facing LOD (agents behind the camera update every 4th frame
--     in a rest pose), a hard per-step BulkMoveTo part cap shared fairly
--     (near agents first, an even share per poser, deferred poses first next
--     step), still idlers emitting only the limbs that move, and constant
--     pivot CFrames folded into one matrix.
--   Citizens (107): 35 sidewalk walkers (24 on the outer sidewalk incl. a
--     dog-walker, 10 on the inner one, BackInner's dog-walker; pausing to
--     window-shop at the zones, waving; keeping FollowGap behind whoever walks
--     ahead on the outer sidewalk; letting zebra crossers pass), 12 shoppers
--     (outer-sidewalk walkers that turn off at their next Shop A, glance at
--     the window, go in through the door for 5-9 s, come out with a bag and
--     walk on to the next gap), 24 rush-hour crossers (a group of 3 per zebra,
--     each on its own line at lateral -5 / 0 / +5 in both directions, 5.6-7.4
--     studs/s, kids +10%; the middle one points across the road while
--     waiting), plaza idlers (balloon-vendor kids, hot-dog queue, bench
--     chatters), 8 storefront loiterers (Shop A windows), 8 café sitters
--     (sipping coffee), a breakdancing street performer with 6 clapping
--     spectators, a fountain selfie trio and 2 window washers.
--   Zone customers (33, built in bindMap from the real zone models): a queue at
--     every hustle counter (4 at the Lemonade Stand, 3 everywhere else incl.
--     Sneaker Street's velvet-rope lane) whose head 'buys' every 5.5-8.5 s
--     (steps up, hops with both arms up while a gold coin pops from the
--     counter), walks a ~6 s loop and rejoins the tail while the rest shuffle
--     forward (keeping 2.4 studs behind anyone still walking up); plus sitters
--     on the zone's own seats (café stools, a picnic bench, the creator couch,
--     a beanbag) or a browser strolling between the props. Every spot is
--     validated against the zone's visible parts (see _bindCustomers).
--   Zone life (bindMap, never a collider or a hustle contract part): the
--     lemon, mini sneakers, rocket, neon heart (+ heartbeat) and roof burger
--     spin; the Stock Desk ticker chases; a car rolls through the car wash
--     every ~12 s; two dogs run the agility course (hops through the hoops,
--     the weave). See _bindZoneLife.
--   Plaza pigeons: 3 flocks of 6 that peck and hop, and flap up in an arc to a
--     free spot 10-16 studs away when a player or citizen comes within 6 studs
--     (or now and then on their own).
--   Sky: blimp circling at r 250, three bird flocks over the plaza, 12 chunky
--     drifting clouds, 5 hot-air balloons in the zone colors, spinning gold coins
--     above the skyline domes, every map part / model tagged with a numeric
--     "CitySpin" attribute, and 2 window-washer cradles riding up and down
--     mid-ring fronts.
--   City pulse (0 parts, 10 Hz, within 500 studs): a marquee chase only on the
--     zone anchor boards (every 0.3 s, unlit bars dimmed), the plaza title and
--     hero-tower billboards; breathing anchor trims (a wave round the zones),
--     aviation blinkers, breathing blade signs, the ticker chase, the heartbeat
--     and the police lightbar. See _bindPulse.

local Shared = script.Parent
local CityLayout = require(Shared:WaitForChild("CityLayout"))
local ChibiRig = require(Shared:WaitForChild("ChibiRig"))
local VehicleRig = require(Shared:WaitForChild("VehicleRig"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local Mechanics = require(Shared:WaitForChild("Mechanics"))

local CityLifeSim = {}
CityLifeSim.__index = CityLifeSim

local S = CityLayout.Street
local DEG = math.pi / 180
local HALF_PI = math.pi / 2
local PARK = CFrame.new(0, -1000, 0)
local IDENTITY = CFrame.new()

local sin, cos, abs, floor, sqrt, exp = math.sin, math.cos, math.abs, math.floor, math.sqrt, math.exp
local clamp, min, max, atan2 = math.clamp, math.min, math.max, math.atan2

local Config = {
	CitizenScale = 1.25, -- adults read at player height (workers stay 1.0)
	KidScale = 1.0,
	-- level of detail (distance from the camera; the High tier's radii - every
	-- tier's own are in TIERS)
	PedFullRadius = 140, -- every frame + limb animation
	PedMidRadius = 260, -- every 2nd frame + limb animation; beyond: every 4th frame, rest pose
	PedLowEvery = 4,
	HideRadius = 400, -- citizens / vehicles / birds parked out of sight beyond this
	VehicleDetailRadius = 260, -- suspension bob + brake pitch
	SkyHideRadius = 1500,
	CoinRadius = 700,
	BehindRadius = 25, -- beyond this, an agent behind the camera...
	BehindDot = -0.2, -- ...(dot(look, toAgentUnit) < this) takes the low tier (rest pose, every 4th frame)
	-- runtime governor (sim:heartbeat): an EMA of the Heartbeat dt steps the runtime
	-- tier down one notch after GovernorSlowFor s above GovernorSlowDt and back up
	-- one (never above the device tier) after GovernorFastFor s under GovernorFastDt
	GovernorTau = 0.5, -- EMA time constant (s)
	GovernorSlowDt = 1 / 50,
	GovernorSlowFor = 3,
	GovernorFastDt = 1 / 58,
	GovernorFastFor = 10, -- doubled (up to GovernorFastMax) when a recovered tier drops again within 30 s
	GovernorFastMax = 80,
	GovernorWarmup = 5, -- s of Heartbeats ignored after start (join hitches)
	GovernorMaxDt = 0.25, -- one hitch counts at most this much
	-- traffic
	VehicleEase = 6, -- exponential speed easing rate (1/s)
	BrakeProfile = 14, -- studs/s^2 used to plan stops (v = sqrt(2 a d))
	BrakeHard = 40, -- amber: commit through when it cannot stop with this decel
	MinGap = 5, -- bumper-to-bumper gap kept to the vehicle ahead (cars ~16 center-to-center)
	CatchUpStuds = 40, -- schedule lag (studs) that maps to +100% catch-up (capped at +30%)
	PlayerLaneMargin = 2, -- a player ON the lane's asphalt within half-width + this of the lane center blocks it...
	PlayerLookAhead = 30,
	PlayerStopGap = 3,
	PlayerYieldMax = 3, -- ...for at most this many s; then the vehicle creeps through (life parts never collide)
	PlayerCreepSpeed = 4, -- studs/s while passing through a player
	PlayerHoldMax = 6, -- a player on a zebra holds / extends its red light at most this many s per red phase
	BusDwell = 3,
	-- crosswalk lights
	MinGo = 10, -- traffic always keeps at least a 10 s green between crossings
	AmberTime = 1.6,
	MinStop = 2.5,
	MaxStop = 16,
	-- crossers: 3 per zebra (A / B / C), each on its own line inside the 16-wide
	-- zebra in both directions, so crossers never meet
	CrossLaterals = { -5, 0, 5 }, -- tangential offset from the zone axis (A, B, C)
	CrossInnerRadius = 57, -- waits on the plaza rim (clear of the inner sidewalk walkers)
	CrossOuterRadii = { 116.5, 116.6, 116.5 }, -- waits on the outer sidewalk in front of the gate (backpacks /
	-- hair clear of the pad edge at r 118 and a locked gate wall at r 119)
	CrossSpeedMin = 5.6, -- per-crosser walking speed (hash), kids +10%
	CrossSpeedMax = 7.4,
	CrossKidBoost = 1.1,
	CrossWaitMin = 12, -- wait on arrival before asking for the light again
	CrossWaitMax = 20,
	CrossJoinWindow = 8, -- when a zebra goes, idle crossers due within this many s join in...
	CrossJoinDelay = 0.8, -- ...each stepping off after a 0..0.8 s hash delay
	CrossCorridor = 2.9, -- half-width of a crosser's line (two body half-extents) for walkers
	CrossYieldMax = 1.5, -- a crosser waits at most this long for a walker in its line
	WalkerYieldMax = 2.5, -- a walker waits at most this long for crossers on the zebra ahead
	-- city pulse (the map's own neon, 0 parts): property sets at 10 Hz, only
	-- within PulseRadius of the camera
	PulseHz = 10,
	PulseRadius = 500,
	ChaseStep = 0.45, -- marquee chase: the highlighted bar moves on (clockwise) every 0.45 s
	BlinkPeriod = 1.8, -- aviation blinkers: lit for BlinkOn s every BlinkPeriod s...
	BlinkOn = 0.35,
	BlinkOffTransparency = 0.8, -- ...and this transparent otherwise
	BreathPeriod = 3, -- blade-sign neon: transparency 0 -> BreathDepth -> 0
	BreathDepth = 0.35,
	-- sky
	BlimpRadius = 250,
	BlimpHeight = 120,
	BlimpSpeed = 6,
	CloudOrbit = 0.5, -- degrees per second about the origin (~4 studs/s at r 450)
	CloudBob = 0.5,
	-- plaza street act (performer spot, kept free by CityLayout's plaza planters)
	PerformerRadius = 34,
	PerformerAngle = 250,
	PerformerReserve = 7.5, -- other idlers / pigeons stay out of this circle
	SpectatorRing = 6.5,
	-- pigeons
	PigeonScare = 6, -- a player / citizen this close to a pigeon flushes the flock
	PigeonFlight = 1.5, -- seconds from take-off to landing (incl. stagger)
	PigeonPeak = 7,
	PigeonHopMin = 10, -- landing spot distance (studs)
	PigeonHopMax = 16,
	PigeonFlocks = 3, -- of the 4 preferred spots: the 4th flock (30 parts) paid for the zone customers
	-- zone customers
	CustomerClearance = 1.2, -- every standing spot: clear of visible zone parts by this...
	CustomerBandLow = 0.3, -- ...from this height above the feet...
	CustomerBandHigh = 4.9, -- ...to this one
	CustomerPathClearance = 1.0, -- walking loops / browse paths
	PromptKeep = 4.5, -- XZ distance from PromptPart (the hustle prompt stays reachable)
	AnchorKeep = 4, -- XZ distance from AutoAnchor (the automation rig's spot)
	CoreHalfWidth = 4, -- gate -> prompt walkway kept free of queues and loops
	QueueSlideMax = 6, -- a blocked spot slides away from the counter 1 stud at a time
	QueueWalk = 2.6, -- shuffle-forward speed (studs/s)
	BuyMin = 5.5, -- the head of a queue buys every BuyMin..BuyMax s (hash-timed per zone)
	BuyMax = 8.5,
	LoopSeconds = 6, -- the buyer's walk back to the tail
	BrowseSpeed = 2.5,
	AsideRadius = 2.5, -- a player this close makes a standing customer step aside...
	AsideStep = 1.5, -- ...this far, returning 2 s after the player left
	AsideHold = 2,
	-- hot-air balloons (CityLife.Sky)
	BalloonOrbit = 0.8, -- degrees per second, alternating directions
	BalloonBob = 1.5,
	BalloonBobPeriod = 8,
	BalloonSway = 3, -- degrees
	-- outer-sidewalk walkers keep this along-track gap (studs, center to
	-- center) to whoever walks ahead in their lane (shoppers merge in and out)
	FollowGap = 3.0,
	-- shoppers (Shop A doors <-> the outer sidewalk)
	ShopperCount = 12,
	ShopperFrontSpeed = 4.4, -- studs/s on the shop frontage
	ShopperInsideMin = 5, -- s inside the shop (hash)
	ShopperInsideMax = 9,
	ShopperDoorTime = 0.5, -- s: step up into / down out of the door
	ShopperGlanceMin = 2.2, -- s looking at the display window on the way in
	ShopperGlanceMax = 3.6,
	-- city pulse hierarchy: running lights only on the zone anchor boards (fast),
	-- the plaza title billboard and the hero-tower billboards
	AnchorChaseStep = 0.3,
	AnchorDim = 0.35, -- the 3 unlit bars of an anchor marquee
	TrimBreathPeriod = 2, -- anchor NeonTrim: transparency 0 <-> TrimBreathDepth
	TrimBreathDepth = 0.4,
	TrimWave = 0.25, -- s of phase per zone Order (a wave round the 8 zones)
	PoliceFlashHz = 2.5, -- lightbar halves alternate (transparency 0 / PoliceDim)
	PoliceDim = 0.7,
	-- zone life (hero props in motion, CityLife.ZoneLife)
	ZoneSpinRadius = 260, -- zone spinners turn within this many studs of the camera
	TickerStep = 0.3, -- Stock Desk ticker chase: one lit segment, the rest dim
	TickerDim = 0.5,
	HeartBeatPeriod = 1.2, -- Creator Studio heart: transparency 0 -> 0.3 -> 0
	HeartBeatDepth = 0.3,
	WashScale = 0.62, -- the car-wash car: a VehicleRig Car scaled to the zone's 8-stud cars
	WashSpeed = 2.5, -- studs/s on the conveyor
	WashAccel = 0.5, -- s to reach / leave WashSpeed
	WashScrub = 2, -- s stopped under the roller brushes
	WashScrubBob = 0.15,
	WashHold = 0.5, -- s parked at the exit before it vanishes
	WashHidden = 4, -- s hidden between passes
	WashSpawnHoldMax = 5, -- a new pass / the swap past the demo car waits at most this long for a player standing there
	CourseDogSpeed = 6, -- agility dogs (Dog Walking)
	CourseDogHop = 1.5, -- hop height through each hoop...
	CourseDogHopTime = 0.4, -- ...and its duration
	CourseDogClearance = 1.0, -- course clearance from every visible zone part
	CourseDogSit = 1.5, -- s sitting when a player comes within CourseDogSitRadius
	CourseDogSitRadius = 3,
	-- window washers on two mid-ring fronts (CityLife.Sky)
	WasherPeriod = 60, -- s: cornice -> y 12 -> cornice
	WasherBottom = 12, -- platform bottom at its lowest
	WasherCableEvery = 0.25, -- s between cable resizes
}
CityLifeSim.Config = Config

-- Device / runtime tiers. The DEVICE tier is chosen once by the shell
-- (CityLifeSim.detectTier) and fixes the crowd at CityLifeSim.new: "half" (Low)
-- builds every 2nd sidewalk walker and shopper, 2 crossers per zebra (A / C),
-- no storefront loiterers, café sitters or window washers, 1 pigeon flock, 6
-- clouds, 2 balloons and 10 ring-road vehicles. The RUNTIME tier (starts at the
-- device tier; sim:heartbeat's governor moves it down / back up, never above the
-- device tier) sets only the per-step knobs, so no rebuild is ever needed:
--   full / mid: citizen LOD radii (animated every frame within `full`, every
--     `midEvery` frames to `mid`, every 4th frame in a rest pose beyond, and
--     behind the camera beyond BehindRadius); vehicle / sky: the radius within
--     which vehicles (bob + brake pitch) and sky / spinner parts move every
--     frame (every `midEvery` frames beyond, every 4th behind the camera);
--   cap: hard limit of parts per step through BulkMoveTo (shared fairly, see
--     _admit); stepEvery: 1 = step every Heartbeat, 2 = cap the sim at 30 Hz
--     (time-based, see heartbeat).
local TIER_ORDER = { "High", "Medium", "Low" }
local TIERS = {
	High = { index = 1, crowd = "full", full = Config.PedFullRadius, mid = Config.PedMidRadius, vehicle = Config.VehicleDetailRadius, sky = 260, midEvery = 2, cap = 1200, stepEvery = 1 },
	Medium = { index = 2, crowd = "full", full = 90, mid = 180, vehicle = 180, sky = 180, midEvery = 3, cap = 800, stepEvery = 1 },
	Low = { index = 3, crowd = "half", full = 60, mid = 140, vehicle = 140, sky = 140, midEvery = 3, cap = 450, stepEvery = 2 },
}
CityLifeSim.TIERS = TIERS
CityLifeSim.TIER_ORDER = TIER_ORDER

-- Device tier from what the shell can read (pure, so tests can drive it):
--   info.touch / info.keyboard: UserInputService.TouchEnabled / KeyboardEnabled
--   info.quality: UserGameSettings.SavedQualityLevel as a number (0 or nil =
--     Automatic, 1..10 = QualityLevel1..10)
-- Low: touch without a keyboard (phones / tablets) or a saved quality 1-4;
-- Medium: saved quality 5-7, or Automatic on a touch device with a keyboard;
-- High: everything else (Automatic on desktop, quality 8-10).
function CityLifeSim.detectTier(info): string
	local quality = if type(info) == "table" and type(info.quality) == "number" then info.quality else 0
	local touch = type(info) == "table" and info.touch == true
	local keyboard = type(info) == "table" and info.keyboard == true
	if touch and not keyboard then
		return "Low"
	elseif quality >= 1 and quality <= 4 then
		return "Low"
	elseif quality >= 5 and quality <= 7 then
		return "Medium"
	elseif quality < 1 and touch then
		return "Medium"
	end
	return "High"
end

-- tools/render/preview_life.luau: warm-up (4.5 s) + one posed step. Phases
-- that should land on a given picture in the renders are set against it.
local SNAPSHOT_T = 4.5 + 1 / 30
CityLifeSim.SNAPSHOT_T = SNAPSHOT_T

local ZONE_COUNT = #CityLayout.zoneAngles
local ZONE_STEP = 360 / ZONE_COUNT

local GO, AMBER, STOP = 0, 1, 2
CityLifeSim.LIGHT_GO, CityLifeSim.LIGHT_AMBER, CityLifeSim.LIGHT_STOP = GO, AMBER, STOP

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

-- Deterministic 0..1 noise (same values in Roblox and in the Lune preview).
local function hash01(a: number, b: number): number
	local x = sin(a * 127.1 + b * 311.7) * 43758.5453
	return x - floor(x)
end

-- Signed smallest difference in degrees (-180..180].
local function wrapDeg(d: number): number
	return (d + 180) % 360 - 180
end

local function wrapRad(d: number): number
	return (d + math.pi) % (2 * math.pi) - math.pi
end

-- CFrame at (x, y, z) yawed like CFrame.Angles(0, yaw, 0) (one allocation).
local function yawCF(x: number, y: number, z: number, yaw: number): CFrame
	local c, s = cos(yaw), sin(yaw)
	return CFrame.new(x, y, z, c, 0, s, 0, 1, 0, -s, 0, c)
end

-- The pose helpers below fold constant pivots / offsets and CFrame.Angles into
-- ONE matrix (one allocation instead of 3-5 per call; same result to float
-- precision).
-- yawCF(x, y, z, yaw) * CFrame.Angles(0, 0, roll)
local function yawRollCF(x: number, y: number, z: number, yaw: number, roll: number): CFrame
	local c, s = cos(yaw), sin(yaw)
	local cr, sr = cos(roll), sin(roll)
	return CFrame.new(x, y, z, c * cr, -c * sr, s, sr, cr, 0, -s * cr, s * sr, c)
end

-- yawCF(x, y, z, yaw) * CFrame.Angles(pitch, 0, 0)
local function yawPitchCF(x: number, y: number, z: number, yaw: number, pitch: number): CFrame
	local c, s = cos(yaw), sin(yaw)
	local ca, sa = cos(pitch), sin(pitch)
	return CFrame.new(x, y, z, c, s * sa, s * ca, 0, ca, -sa, -s, c * sa, c * ca)
end

-- CFrame.new(px, py, 0) * CFrame.Angles(pitch, 0, roll) * CFrame.new(-px, -py, 0):
-- a limb turned about its shoulder / hip (rig pivots have z = 0).
local function limbCF(px: number, py: number, pitch: number, roll: number): CFrame
	local ca, sa = cos(pitch), sin(pitch)
	local cb, sb = cos(roll), sin(roll)
	local r10, r11, r20, r21 = ca * sb, ca * cb, sa * sb, sa * cb
	return CFrame.new(px - (cb * px - sb * py), py - (r10 * px + r11 * py), -(r20 * px + r21 * py), cb, -sb, 0, r10, r11, -sa, r20, r21, ca)
end

-- CFrame.new(hx, hy, hz) * CFrame.Angles(0, 0, a) * CFrame.new(ox, 0, 0): a wing
-- flapping about its hinge.
local function hingeZ(hx: number, hy: number, hz: number, a: number, ox: number): CFrame
	local c, s = cos(a), sin(a)
	return CFrame.new(hx + ox * c, hy + ox * s, hz, c, -s, 0, s, c, 0, 0, 0, 1)
end

-- Yaw whose -Z (LookVector) points along the ring tangent at `a` (radians).
local function tangentYaw(a: number, dir: number): number
	return if dir > 0 then math.pi - a else -a
end

-- Yaw facing radially outward (+1) or toward the plaza (-1) at `a` (radians).
local function radialYaw(a: number, outward: boolean): number
	return if outward then -HALF_PI - a else HALF_PI - a
end

local function yawToward(dx: number, dz: number): number
	return atan2(-dx, -dz)
end

local function smooth01(u: number): number
	u = clamp(u, 0, 1)
	return u * u * (3 - 2 * u)
end

-- Distance LOD for a ground agent: "hide" | "low" | "full" | "skip".
local LOD_HIDE, LOD_SKIP, LOD_LOW, LOD_FULL = 0, 1, 2, 3
-- Part cap: while a priority class is over its share of the cap, it gets
-- share / CAP_SLOTS of its requests through, spread evenly per poser by a
-- small accumulator (capSlot, 0..CAP_SLOTS-1, seeded per poser so the phases
-- differ): see _admit.
local CAP_SLOTS = 13
local BEHIND_DOT2 = Config.BehindDot * Config.BehindDot
-- LOD stagger slots ("low"): 12 divides evenly by every cadence (2, 3, 4)
local LOD_SLOTS = 12

----------------------------------------------------------------------
-- Palettes + plan (who drives / walks where at t = 0)
----------------------------------------------------------------------

-- Shirts avoid the worker rarity colors (gray / green / blue / gold) so a
-- citizen never reads as one of the player's workers.
local SHIRTS = {
	rgb(255, 120, 100), rgb(40, 190, 190), rgb(170, 110, 255), rgb(255, 130, 190), rgb(255, 150, 60),
	rgb(120, 200, 255), rgb(230, 70, 90), rgb(120, 230, 170), rgb(250, 236, 200), rgb(220, 80, 200),
	rgb(255, 180, 120), rgb(200, 165, 255), rgb(255, 90, 140),
}
local SKINS = { rgb(255, 224, 189), rgb(241, 194, 150), rgb(224, 172, 105), rgb(198, 134, 66), rgb(141, 85, 36), rgb(255, 205, 170) }
local PANTS = { rgb(52, 52, 72), rgb(60, 90, 160), rgb(200, 170, 120), rgb(40, 40, 48), rgb(90, 60, 120), rgb(130, 175, 225) }
local HAIRS = { rgb(60, 40, 30), rgb(25, 22, 22), rgb(240, 200, 110), rgb(200, 100, 50), rgb(255, 140, 200), rgb(130, 90, 60) }
local BRIGHTS = { rgb(255, 70, 70), rgb(255, 200, 40), rgb(70, 180, 255), rgb(120, 220, 90), rgb(255, 120, 200), rgb(170, 110, 255), rgb(255, 150, 40) }

-- Vehicles: lane (CityLayout.laneLoops / backLaneLoops name), kind, color,
-- start angle (deg). Evenly spaced per lane so every ring view holds 2-4.
-- `low`: kept by the Low device tier (10 of the 18 ring-road vehicles, the
-- police car and the bus among them, + both Back Avenue ones).
local FLEET = {
	-- Inner1 (r 70.75, +angle)
	{ lane = "Inner1", kind = "Taxi", angle = 330, low = true },
	{ lane = "Inner1", kind = "Car", color = rgb(255, 90, 90), angle = 60 },
	{ lane = "Inner1", kind = "Car", color = rgb(110, 215, 120), angle = 150, low = true },
	{ lane = "Inner1", kind = "Car", color = rgb(90, 200, 255), angle = 240 },
	-- Inner2 (r 80.25, +angle)
	{ lane = "Inner2", kind = "IceCreamVan", angle = 20, low = true },
	{ lane = "Inner2", kind = "Car", color = rgb(70, 150, 255), angle = 110 },
	{ lane = "Inner2", kind = "Taxi", angle = 200, low = true },
	{ lane = "Inner2", kind = "Taxi", angle = 290 },
	-- Outer1 (r 89.75, -angle)
	{ lane = "Outer1", kind = "Car", color = rgb(140, 230, 110), angle = 0 },
	{ lane = "Outer1", kind = "Car", color = rgb(170, 120, 255), angle = 60, low = true },
	{ lane = "Outer1", kind = "Taxi", angle = 120 },
	{ lane = "Outer1", kind = "Police", angle = 180, low = true }, -- flashing lightbar (city pulse)
	{ lane = "Outer1", kind = "Car", color = rgb(255, 150, 60), angle = 240 },
	{ lane = "Outer1", kind = "Taxi", angle = 300, low = true },
	-- Outer2 (r 99.25, -angle): the slow lane (bus + delivery truck)
	{ lane = "Outer2", kind = "Car", color = rgb(255, 120, 170), angle = 20 },
	{ lane = "Outer2", kind = "Bus", angle = 110, low = true },
	{ lane = "Outer2", kind = "Truck", angle = 200, low = true },
	{ lane = "Outer2", kind = "Car", color = rgb(80, 210, 210), angle = 290, low = true },
	-- Back Avenue (between the skyline rings; no lights, no crosswalks): one
	-- per lane (the r2_backstreet view frames the taxi)
	{ lane = "Back1", kind = "Taxi", angle = 356, low = true },
	{ lane = "Back2", kind = "Car", color = rgb(170, 120, 255), angle = 42, low = true },
}
-- Lane cruise speeds (studs/s): the outermost ring lane is the slow bus /
-- truck lane (the delivery truck cruises at 13).
local LANE_SPEED = { Inner1 = 18, Inner2 = 20, Outer1 = 21, Outer2 = 13, Back1 = 16, Back2 = 17 }
CityLifeSim.FLEET = FLEET

-- Sidewalk walking lanes (two per sidewalk loop, opposite directions).
-- Outer lanes tuck inward near every zone axis (`nearRadius` within ~11
-- degrees): the zone entrance lamps stand at r ~116.1 (zone-local x +-16) and
-- the furniture strip (planters, bus stops) reaches r ~111.9 only between the
-- zones, so the walkers use the free band on each side. minR / maxR bound the
-- sidestep around players. `follow`: walkers keep Config.FollowGap behind
-- whoever walks ahead in the lane (the shoppers join these two lanes).
-- OuterA's first walker (`dogAt` 0) walks a dog on its outward / left side
-- (`dogSide` +1, `dogLateral` studs out, `dogLead` studs ahead: r ~114.85
-- between the zones, ~113.25 at the zone axes), clear of the entrance lamps,
-- signposts, bus stops and the crossers waiting at r 116.5.
local WALK_LANES = {
	{ name = "OuterA", radius = S.OuterWalkRadius + 0.1, nearRadius = 112.0, y = S.OuterSidewalkTop, dir = 1, speed = 5.4, count = 12, start = 8, pauseChance = 0.35, pauseOut = true, minR = 112.1, maxR = 117.6, minRNear = 109.3, maxRNear = 114.3, follow = true, dogAt = 0, dogSide = 1, dogLateral = 1.25, dogLead = 1.2 },
	{ name = "OuterB", radius = S.OuterWalkRadius + 2.4, nearRadius = 114.15, y = S.OuterSidewalkTop, dir = -1, speed = 6.3, count = 12, start = 50, pauseChance = 0.35, pauseOut = true, minR = 112.1, maxR = 117.6, minRNear = 109.3, maxRNear = 114.3, follow = true },
	{ name = "InnerA", radius = S.InnerWalkRadius - 0.6, y = S.InnerSidewalkTop, dir = 1, speed = 5.0, count = 5, start = 25, pauseChance = 0.15, pauseLead = 9, pauseOut = false, minR = 60.6, maxR = 63.6 },
	{ name = "InnerB", radius = S.InnerWalkRadius + 1.4, y = S.InnerSidewalkTop, dir = -1, speed = 5.8, count = 5, start = 85, pauseChance = 0.15, pauseLead = 9, pauseOut = false, minR = 60.6, maxR = 63.6 },
}
-- Back Avenue sidewalks (CityLayout.backSidewalkLoops): only a few players
-- ever see the avenue, so its crowd moved to the outer sidewalk; BackInner
-- keeps its dog-walker (clockwise, +angle, with the Back1 traffic; framed by
-- r3_back_walk at the render snapshot) and BackOuter is empty (count 0; its
-- door window-shopping, `doorChance`, stays available). The sidestep bounds
-- keep the body (+-1.45) on the walk: off the avenue asphalt (r 250..270) and
-- clear of the mid-ring backs / outer-ring fronts. `dogAt`: the walker
-- (0-based) with the dog, which trots on the avenue side (`dogSide`, +1 =
-- outward). `angles`: explicit start angles.
for _, loop in (CityLayout.backSidewalkLoops or {}) do
	if loop.name == "BackInner" then
		table.insert(WALK_LANES, { name = "BackInner", radius = loop.radius, y = loop.y, dir = 1, speed = 5.2, count = 1, angles = { 230.5 }, pauseChance = 0, pauseOut = false, minR = loop.radius - 0.4, maxR = loop.radius + 1.2, dogAt = 0, dogSide = 1 })
	elseif loop.name == "BackOuter" then
		table.insert(WALK_LANES, { name = "BackOuter", radius = loop.radius, y = loop.y, dir = -1, speed = 5.6, count = 0, angles = {}, pauseChance = 0, doorChance = 0.25, pauseOut = true, minR = loop.radius - 1.3, maxR = loop.radius })
	end
end
CityLifeSim.WALK_LANES = WALK_LANES
local NEAR_AXIS_IN, NEAR_AXIS_OUT = 9.5, 13.5 -- degrees: full tuck / back on the open lane

-- Outer-ring shop doors on the Back Avenue as world angles, sorted (CityBuilder:
-- the door stands at building-local x = +W/4 on the front face; on the round
-- hero towers it is tangent to the plinth at -18 degrees). BackOuter walkers
-- window-shop at some of them.
local OUTER_DOORS: { number } = {}
for _, b in CityLayout.skyline do
	if b.ring == "Outer" then
		local cf = if b.hero == "Round"
			then b.cframe * CFrame.Angles(0, -18 * DEG, 0) * CFrame.new(0, 0, -16.7)
			else b.cframe * CFrame.new(b.width / 4, 0, -b.depth / 2 - 0.7)
		table.insert(OUTER_DOORS, CityLayout.angleOf(cf.Position))
	end
end
table.sort(OUTER_DOORS)
CityLifeSim.OUTER_DOORS = OUTER_DOORS

-- Index of the first door ahead of `theta` (degrees) walking in `dir`.
local function nextDoorIndex(theta: number, dir: number): number
	local n = #OUTER_DOORS
	if dir > 0 then
		for i = 1, n do
			if OUTER_DOORS[i] > theta then
				return i
			end
		end
		return 1
	end
	for i = n, 1, -1 do
		if OUTER_DOORS[i] < theta then
			return i
		end
	end
	return n
end

-- 1 within NEAR_AXIS_IN degrees of a zone axis, 0 beyond NEAR_AXIS_OUT (smooth).
local function nearAxisWeight(lane, degrees: number): number
	if lane.nearRadius == nil then
		return 0
	end
	local m = degrees % ZONE_STEP
	local d = min(m, ZONE_STEP - m)
	if d <= NEAR_AXIS_IN then
		return 1
	elseif d >= NEAR_AXIS_OUT then
		return 0
	end
	local u = (NEAR_AXIS_OUT - d) / (NEAR_AXIS_OUT - NEAR_AXIS_IN)
	return u * u * (3 - 2 * u)
end

-- Walking radius of a lane at `degrees` (+ the sidestep bounds there).
local function walkRadius(lane, degrees: number): (number, number, number)
	local w = nearAxisWeight(lane, degrees)
	if w == 0 then
		return lane.radius, lane.minR, lane.maxR
	end
	return lane.radius + (lane.nearRadius - lane.radius) * w,
		lane.minR + (lane.minRNear - lane.minR) * w,
		lane.maxR + (lane.maxRNear - lane.maxR) * w
end
CityLifeSim.walkRadius = walkRadius

-- Rush-hour crossers: a group of 3 per zebra (zone order). A (lateral -5) and
-- B (lateral 0, the one who points across the road) start on the outer
-- sidewalk in front of the gate, C (lateral +5) on the plaza rim. `wait`: the
-- first wait (s) of A / B / C; `red`: the zebra starts at red (t = 0) so its
-- group is already mid-road when the render snapshot is taken (t ~4.5 s);
-- `kid`: the member (1..3) who is a kid. Snapshot plan: six zebras mid-road
-- (Lemonade in the spawn view, Car Wash in outward, Content Creator in
-- r3_skyline_eye), Sneaker Street (r2_gate) and Startup HQ (r4_ring_eye)
-- with their groups waiting at the outer curb.
local CROSS_GROUPS = {
	{ zone = 1, red = true, wait = { 0, 0.3, 0 } },
	{ zone = 2, red = true, wait = { 0.6, 0.2, 0 }, kid = 3 },
	{ zone = 3, wait = { 6.5, 7.5, 13 } },
	{ zone = 4, red = true, wait = { 0.2, 0, 0.5 }, kid = 1 },
	{ zone = 5, red = true, wait = { 0.4, 0, 0.9 } },
	{ zone = 6, red = true, wait = { 0, 0.6, 0.2 } },
	{ zone = 7, red = true, wait = { 0.8, 0, 1.2 }, kid = 2 },
	{ zone = 8, wait = { 6.0, 7.0, 12 } },
}
CityLifeSim.CROSS_GROUPS = CROSS_GROUPS

-- Shoppers: they circulate between the 8 Shop A doors. Shop-A-local frame
-- (CityLayout.shops[i].cframe): -Z faces the plaza, +X points toward the
-- lower-angle zone; the door is at x 8.5 on the front face (z -8, a 1.2-tall
-- plinth band 0.5 proud of it). A shopper leaves its outer-sidewalk lane at
-- local x 10 (~5 degrees before the gap bisector), walks up the door lane
-- (x 7.5..10.5, clear of the café terrace x -13.5..5, the window shopper at
-- (4.5, -10.5) and the gap-tree planters at |x| >= 14), glances at the display
-- window from (9.5, -12), steps up into the doorway and disappears for 5-9 s,
-- comes back out holding a ShoppingBag, rejoins the sidewalk at the same spot
-- and walks on (its lane's direction) to the neighbouring gap's Shop A.
local SHOP_FRONT = {
	laneX = 10, -- where shoppers leave / rejoin the sidewalk lane
	glance = Vector3.new(9.5, 0, -12),
	step = Vector3.new(8.5, 0, -10), -- in front of the door (head clear of it)
	door = Vector3.new(8.5, 0, -8.2), -- in the doorway, on the plinth
	window = Vector3.new(3, 0, -8.3), -- what the glance looks at
	plinthTop = 1.2,
}
CityLifeSim.SHOP_FRONT = SHOP_FRONT
-- Shop A frontage per gap index: world points + the departure angle on each
-- outer lane (the lane circle at shop-local x = laneX).
local FRONTAGES = {}
for _, shop in CityLayout.shops do
	if shop.kind == "A" then
		local cf = shop.cframe
		local function at(l: Vector3): Vector3
			local p = cf:PointToWorldSpace(l)
			return Vector3.new(p.X, CityLayout.surfaceY(p), p.Z)
		end
		local door = cf:PointToWorldSpace(SHOP_FRONT.door)
		local step = at(SHOP_FRONT.step)
		local glance = at(SHOP_FRONT.glance)
		local window = cf:PointToWorldSpace(SHOP_FRONT.window)
		local f = {
			gapIndex = shop.gapIndex, name = shop.name, angle = shop.angle,
			glance = glance, step = step, door = Vector3.new(door.X, SHOP_FRONT.plinthTop, door.Z),
			inYaw = yawToward(door.X - step.X, door.Z - step.Z), -- facing the door
			outYaw = yawToward(cf.LookVector.X, cf.LookVector.Z), -- facing the plaza (shop -Z)
			glanceYaw = yawToward(window.X - glance.X, window.Z - glance.Z),
			theta = {}, lanePoint = {},
		}
		for _, lane in WALK_LANES do
			if lane.follow then
				local delta = math.deg(math.atan(SHOP_FRONT.laneX / lane.radius))
				local theta = (shop.angle - delta) % 360 -- +X = toward the lower angle
				f.theta[lane.name] = theta
				local p = CityLayout.ringPos(lane.radius, theta, 0)
				f.lanePoint[lane.name] = Vector3.new(p.X, lane.y, p.Z)
			end
		end
		FRONTAGES[shop.gapIndex] = f
	end
end
CityLifeSim.FRONTAGES = FRONTAGES

-- Shopper start states (deterministic): `gap` = target Shop A, `lane`,
-- `start` = "walk" (`lead` degrees before the departure point) | "front"
-- (leaving the lane at t = 0) | "shop" (inside, out after `timer` s) | "out"
-- (stepping out of the door at t = 0), `bag` = already carrying one. At the
-- render snapshot (t ~4.5 s) shopper 1 glances at the PIZZA window (gap.png)
-- and shopper 2 walks down the DONUTS frontage with its bag
-- (r5_sidewalk_tan); the rest are spread so ~4 are on frontages at a time.
local SHOPPERS = {
	{ gap = 1, lane = "OuterB", start = "front" },
	{ gap = 2, lane = "OuterA", start = "shop", timer = 1.6 },
	{ gap = 3, lane = "OuterA", start = "walk", lead = 16, bag = true },
	{ gap = 4, lane = "OuterB", start = "shop", timer = 6 },
	{ gap = 5, lane = "OuterA", start = "front" },
	{ gap = 6, lane = "OuterB", start = "walk", lead = 28, bag = true },
	{ gap = 7, lane = "OuterA", start = "out" },
	{ gap = 8, lane = "OuterB", start = "walk", lead = 9 },
	{ gap = 4, lane = "OuterA", start = "walk", lead = 24, bag = true },
	{ gap = 6, lane = "OuterA", start = "shop", timer = 3.5 },
	{ gap = 8, lane = "OuterA", start = "walk", lead = 36 },
	{ gap = 3, lane = "OuterB", start = "walk", lead = 33, bag = true },
}
CityLifeSim.SHOPPERS = SHOPPERS
local SHOP_WALK, SHOP_FRONT_IN, SHOP_ENTER, SHOP_INSIDE, SHOP_EXIT, SHOP_FRONT_OUT = 1, 2, 3, 4, 5, 6
CityLifeSim.SHOPPER_MODES = { walk = SHOP_WALK, frontIn = SHOP_FRONT_IN, enter = SHOP_ENTER, inside = SHOP_INSIDE, exit = SHOP_EXIT, frontOut = SHOP_FRONT_OUT }

----------------------------------------------------------------------
-- Rigs: shared helpers
----------------------------------------------------------------------

local function newPart(parent: Instance, name: string, shape: Enum.PartType, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Shape = shape
	part.Size = size
	part.CFrame = cf
	part.Color = color
	part.Material = material or Enum.Material.SmoothPlastic
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function newFolder(parent: Instance, name: string): Folder
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

-- Collects a built model's parts with their build CFrames as rest offsets.
local function collect(model: Instance)
	local parts, rest = {}, {}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(parts, d)
			table.insert(rest, d.CFrame)
		end
	end
	return parts, rest
end

----------------------------------------------------------------------
-- Citizens (ChibiRig + scale + outfit + accessories)
----------------------------------------------------------------------

-- Pose groups: every part follows one pivot.
local G_ROOT, G_HEAD, G_LARM, G_RARM, G_LLEG, G_RLEG = 1, 2, 3, 4, 5, 6
-- By part NAME (robust everywhere: in Lune the same Instance can come back as
-- a different userdata, so Instance-keyed tables are avoided).
local GROUP_OF = {
	Head = G_HEAD, LeftEye = G_HEAD, RightEye = G_HEAD, Smile = G_HEAD, Sunglasses = G_HEAD,
	Hair = G_HEAD, Ponytail = G_HEAD, HairBun = G_HEAD, HatBrim = G_HEAD, HatCrown = G_HEAD,
	LeftArm = G_LARM, RightArm = G_RARM, CoffeeCup = G_RARM, CupHandle = G_RARM,
	ShoppingBag = G_RARM, BagHandle = G_RARM, Phone = G_RARM,
	LeftLeg = G_LLEG, RightLeg = G_RLEG,
	-- Backpack, BalloonString, Balloon, Body: the root
}
-- Unscaled pivots (ChibiRig dimensions): head center, shoulders, hips.
local PIVOTS = {
	[G_HEAD] = Vector3.new(0, ChibiRig.HEAD_CENTER_Y or 2.85, 0),
	[G_LARM] = Vector3.new(-0.98, 1.675, 0),
	[G_RARM] = Vector3.new(0.98, 1.675, 0),
	[G_LLEG] = Vector3.new(-0.38, 0.5, 0),
	[G_RLEG] = Vector3.new(0.38, 0.5, 0),
}
local BODY_BOTTOM = 0.5 -- unscaled height of the body block's bottom (seat contact)

type Look = {
	shirt: Color3, skin: Color3, pants: Color3, hair: Color3, hairStyle: number,
	hat: boolean, hatColor: Color3, backpack: boolean, bag: boolean, balloon: boolean,
	accent: Color3, kid: boolean, prop: string, phone: boolean, cupColor: Color3?,
	shopBag: boolean?, bagColor: Color3?,
}

local function lookFor(i: number, overrides: { [string]: any }?): Look
	local look = {
		shirt = SHIRTS[(i * 7 + 3) % #SHIRTS + 1],
		skin = SKINS[(i * 5 + 1) % #SKINS + 1],
		pants = PANTS[(i * 3) % #PANTS + 1],
		hair = HAIRS[(i * 11 + 2) % #HAIRS + 1],
		hairStyle = i % 3, -- 0 bob, 1 bob + ponytail, 2 bob + bun
		hat = i % 3 == 1,
		hatColor = BRIGHTS[(i * 5 + 2) % #BRIGHTS + 1],
		backpack = i % 4 == 2,
		bag = i % 4 == 0,
		balloon = i % 6 == 5,
		accent = BRIGHTS[(i * 3 + 1) % #BRIGHTS + 1],
		kid = false,
		-- existing ChibiRig props, used sparingly: a coffee to go, cool shades
		prop = if i % 9 == 4 then "CoffeeCup" elseif i % 11 == 7 then "GoldSuit" else "None",
		phone = false,
	}
	if overrides then
		for k, v in overrides do
			look[k] = v
		end
	end
	if look.prop == "CoffeeCup" or look.phone then
		look.bag = false -- all live in the right hand
	end
	if look.balloon then
		look.kid = if overrides and overrides.kid ~= nil then overrides.kid else true
	end
	return look
end

local function buildCitizen(parent: Instance, index: number, look: Look)
	-- Prop "GoldSuit" only adds ChibiRig's sunglasses here (BodyColor wins).
	local model = ChibiRig.build({ Name = "Citizen", BodyColor = look.shirt, Prop = look.prop })
	model.Name = "Citizen" .. index
	local head = model:FindFirstChild("Head") :: BasePart
	local tag = head and head:FindFirstChild("NameTag")
	if tag then
		tag:Destroy() -- citizens are scenery: no floating name tags
	end
	local rootPart = model:FindFirstChild("RootPart")
	if rootPart then
		rootPart:Destroy() -- invisible pivot: the sim poses every part by CFrame math
	end
	head.Color = look.skin
	for _, legName in { "LeftLeg", "RightLeg" } do
		local leg = model:FindFirstChild(legName) :: BasePart?
		if leg then
			leg.Color = look.pants
		end
	end
	if look.cupColor then
		-- a lemonade / soda cup instead of the white coffee cup
		for _, cupName in { "CoffeeCup", "CupHandle" } do
			local cup = model:FindFirstChild(cupName) :: BasePart?
			if cup then
				cup.Color = look.cupColor
			end
		end
	end

	-- Accessories in ChibiRig's unscaled rig space (feet at 0, facing -Z); the
	-- pose group comes from GROUP_OF[name] (the `group` argument documents it).
	local headY = ChibiRig.HEAD_CENTER_Y or 2.85
	local function add(name, shape, size, cf, color, group, material)
		assert((GROUP_OF[name] or G_ROOT) == group, "pose group mismatch for " .. name)
		return newPart(model, name, shape, size, cf, color, material)
	end
	-- hair: a dome behind/above the face (+ ponytail or bun)
	add("Hair", Enum.PartType.Ball, Vector3.new(2.32, 2.32, 2.32), CFrame.new(0, headY + 0.32, 0.28), look.hair, G_HEAD)
	if look.hairStyle == 1 and not look.hat then
		add("Ponytail", Enum.PartType.Ball, Vector3.new(0.9, 0.9, 0.9), CFrame.new(0, headY + 0.1, 1.4), look.hair, G_HEAD)
	elseif look.hairStyle == 2 and not look.hat then
		add("HairBun", Enum.PartType.Ball, Vector3.new(0.95, 0.95, 0.95), CFrame.new(0, headY + 1.5, 0.35), look.hair, G_HEAD)
	end
	if look.hat then
		local flat = CFrame.Angles(0, 0, HALF_PI) -- cylinder axis onto Y
		add("HatBrim", Enum.PartType.Cylinder, Vector3.new(0.3, 2.6, 2.6), CFrame.new(0, headY + 0.95, 0.05) * flat, look.hatColor, G_HEAD)
		add("HatCrown", Enum.PartType.Cylinder, Vector3.new(1.2, 1.8, 1.8), CFrame.new(0, headY + 1.6, 0.05) * flat, look.hatColor:Lerp(rgb(30, 30, 40), 0.25), G_HEAD)
	end
	if look.backpack then
		add("Backpack", Enum.PartType.Block, Vector3.new(1.2, 1.25, 0.6), CFrame.new(0, 1.3, 0.72), look.accent, G_ROOT)
	end
	if look.bag then
		add("ShoppingBag", Enum.PartType.Block, Vector3.new(0.75, 0.8, 0.4), CFrame.new(1.17, 0.45, -0.05), look.accent, G_RARM)
		add("BagHandle", Enum.PartType.Block, Vector3.new(0.08, 0.3, 0.3), CFrame.new(1.17, 0.95, -0.05), rgb(250, 250, 250), G_RARM)
	end
	if look.balloon then
		add("BalloonString", Enum.PartType.Block, Vector3.new(0.08, 3.8, 0.08), CFrame.new(-1.12, 2.75, -0.05), rgb(250, 250, 250), G_ROOT)
		add("Balloon", Enum.PartType.Ball, Vector3.new(1.4, 1.4, 1.4), CFrame.new(-1.12, 5.3, -0.05), look.accent, G_ROOT)
	end
	if look.phone then
		-- 0.3 x 1 x 0.6 phone lying flat in the hanging right hand (thin along
		-- rest Y): raised forward-up for a selfie its screen faces the group.
		add("Phone", Enum.PartType.Block, Vector3.new(0.3, 1, 0.6), CFrame.new(0.98, 0.7, -0.05) * CFrame.Angles(0, 0, HALF_PI), rgb(4, 4, 53), G_RARM)
	end
	if look.shopBag then
		-- a shopper's purchase, swinging from the right hand (one part; the sim
		-- parks it while the shopper is not carrying one)
		add("ShoppingBag", Enum.PartType.Block, Vector3.new(0.85, 0.9, 0.45), CFrame.new(1.17, 0.6, -0.05), look.bagColor or look.accent, G_RARM)
	end

	-- Scale every part about the feet (rig is still at the origin) and record
	-- rest offsets + pose groups.
	local scale = if look.kid then Config.KidScale else Config.CitizenScale
	local rig = {
		model = model, parts = {}, rest = {}, group = {}, n = 0, scale = scale,
		pivot = {}, px = {}, py = {}, gcf = {}, hidden = false, holdsBalloon = look.balloon,
		-- per pose group: the part indices + their count (a still idler emits only
		-- the groups whose angles changed, see _poseCitizen)
		gidx = { {}, {}, {}, {}, {}, {} }, gn = { 0, 0, 0, 0, 0, 0 },
		-- last emitted pose (posed = false: emit every part next time)
		posed = false, lastRoot = IDENTITY, lHead = 0, lLa = 0, lLaRoll = 0, lRa = 0, lRaRoll = 0, lLl = 0, lRl = 0,
		bagPark = false, lBagPark = false,
		capSlot = index % CAP_SLOTS, owed = false,
	}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			local cf = d.CFrame
			local rest = CFrame.new(cf.Position * scale) * (CFrame.new(-cf.Position) * cf)
			d.Size = d.Size * scale
			d.CFrame = rest
			rig.n += 1
			rig.parts[rig.n] = d
			rig.rest[rig.n] = rest
			local g = GROUP_OF[d.Name] or G_ROOT
			rig.group[rig.n] = g
			rig.gn[g] += 1
			rig.gidx[g][rig.gn[g]] = rig.n
			if look.shopBag and d.Name == "ShoppingBag" then
				rig.bagIndex = rig.n
			end
		end
	end
	for g = G_HEAD, G_RLEG do
		rig.pivot[g] = PIVOTS[g] * scale
		rig.px[g], rig.py[g] = rig.pivot[g].X, rig.pivot[g].Y
	end
	for g = 1, 6 do
		rig.gcf[g] = IDENTITY
	end
	model.Parent = parent
	return rig
end

----------------------------------------------------------------------
-- Construction
----------------------------------------------------------------------

-- Ring-road lane (crosswalk lights apply) or Back Avenue lane (no lights).
local function laneByName(name: string)
	for _, loop in CityLayout.laneLoops do
		if loop.name == name then
			return loop, true
		end
	end
	for _, loop in (CityLayout.backLaneLoops or {}) do
		if loop.name == name then
			return loop, false
		end
	end
	return nil, false
end

-- Plaza feet height incl. the decorative inlay discs (tops 1.54..1.62).
local function plazaFeetY(position: Vector3): number
	local r = Vector3.new(position.X, 0, position.Z).Magnitude
	if r <= 44 then
		return S.PlazaTop + 0.1
	elseif r <= 50 then
		return S.PlazaTop + 0.05
	end
	return CityLayout.surfaceY(position)
end

function CityLifeSim.new(folder: Instance, tier: string?)
	local self = setmetatable({}, CityLifeSim)
	self.folder = folder
	-- device tier (fixes the crowd) + runtime tier (per-step knobs, see TIERS)
	self.tier = if tier and TIERS[tier] then tier else "High"
	self.half = TIERS[self.tier].crowd == "half"
	self.t = 0
	self.frame = 0
	self.simOnly = false
	self.outParts = {}
	self.outCFrames = {}
	self.outCount = 0
	self.prevCount = 0
	self.camera = nil
	self.cameraLook = nil
	-- part cap (see _admit): per priority class (1 near, 2 mid, 3 low / behind /
	-- sky) the parts requested this step / last step and this step's share
	-- (of CAP_SLOTS)
	self.capOn = false
	self.capDemand = { 0, 0, 0 }
	self.capShare = { CAP_SLOTS, CAP_SLOTS, CAP_SLOTS }
	self.capPrev = { 0, 0, 0 } -- last step's demand per class
	self.capDenied = 0 -- parts the hard cap deferred this step (owed: first next time)
	self.capReserve = 0
	self.lodPrio = 1
	-- runtime governor (sim:heartbeat)
	self.gov = { ema = 1 / 60, slowT = 0, fastT = 0, t = 0, acc = 0, beat = 0,
		recoverAfter = Config.GovernorFastFor, lastRecover = -math.huge, changes = 0 }
	self:setRuntimeTier(self.tier)
	self.playerPos = {}
	self.playerCount = 0
	self.vehicles = {}
	self.walkers = {}
	self.crossers = {}
	self.idlers = {}
	self.flocks = {}
	self.clouds = {}
	self.pigeonFlocks = {}
	self.pigeonSpots = {}
	self.plazaProps = {}
	self.reserved = {} -- plaza circles kept free of other idlers / pigeons
	self.staticSpots = {} -- feet of every idler (pigeons keep their distance)
	self.coins = {}
	self.spinners = {} -- every spun map part (unbindMap restores the zone ones)
	self.spinGroups = {} -- the same parts grouped per model (what _stepSky turns)
	self.balloons = {}
	self.dogs = {}
	self.customers = {} -- queue + browse customers (sitters are idlers)
	self.customerZones = {}
	self.customerGeo = {} -- zone id -> polylines (world) the zone's customers stand / walk on
	self.customerCount = 0
	self.shopperCount = 0
	self.courseDogs = {} -- Dog Walking agility dogs (bindMap)
	self.washCar = nil -- the car-wash car (bindMap)
	self.zoneSpinGroups = 0
	self.zoneSkipped = {}
	self.police = nil
	self.poseAllNext = false
	self.mapBound = false
	self.citizenCount = 0

	self.trafficFolder = newFolder(folder, "Traffic")
	self.citizenFolder = newFolder(folder, "Citizens")
	self.plazaFolder = newFolder(folder, "Plaza")
	self.skyFolder = newFolder(folder, "Sky")

	self:_buildCrosswalks()
	self:_buildVehicles()
	self:_buildWalkers()
	self:_buildShoppers()
	-- ring-sidewalk walkers a zebra crosser may meet (outer r ~112-115.6, inner ~61-63)
	self.outerWalkers, self.innerWalkers = {}, {}
	for _, w in self.walkers do
		if w.lane.radius > 100 and w.lane.radius < 125 then
			table.insert(self.outerWalkers, w)
		elseif w.lane.radius < 70 then
			table.insert(self.innerWalkers, w)
		end
	end
	-- the follow rule: everyone in a `follow` lane (walkers + shoppers) knows
	-- the others in it
	for _, w in self.walkers do
		if w.lane.follow then
			w.mates = {}
			for _, o in self.walkers do
				if o ~= w and o.lane == w.lane then
					table.insert(w.mates, o)
				end
			end
		end
	end
	self:_buildCrossers()
	self:_buildIdlers()
	self:_buildStreetAct()
	self:_buildSelfie()
	self:_buildStorefronts()
	self:_buildCafeSitters()
	self:_buildPigeons()
	self:_buildSky()
	self:_buildWashers()
	return self
end

function CityLifeSim:_newCitizen(overrides)
	self.citizenCount += 1
	local i = self.citizenCount
	return buildCitizen(self.citizenFolder, i, lookFor(i, overrides))
end

function CityLifeSim:_buildCrosswalks()
	self.crosswalks = {}
	self.crosswalkByZone = {}
	for i, cw in CityLayout.crosswalks do
		local rec = {
			index = i,
			zoneId = cw.zoneId,
			angle = cw.angle,
			state = GO,
			timer = Config.MinGo, -- the first request goes amber at once
			requests = 0,
			occupants = 0,
			players = 0, -- players on the zebra while it is red...
			playerHoldT = 0, -- ...and how long they have held this red phase (<= PlayerHoldMax)
			crossers = {}, -- this zebra's crosser group (A, B, C)
			lamps = nil, -- { Red = { {part, color} }, Amber = ..., Green = ... } after bindMap
		}
		self.crosswalks[i] = rec
		self.crosswalkByZone[cw.zoneId] = rec
	end
	self.busStops = {}
	for i, stop in CityLayout.busStops do
		self.busStops[i] = { angle = stop.angle }
	end
end

function CityLifeSim:_buildVehicles()
	local lanes = {}
	for i, spec in FLEET do
		local loop, lights = laneByName(spec.lane)
		if loop == nil then
			continue -- e.g. no Back Avenue in this layout: skip its vehicles
		end
		if self.half and not spec.low then
			continue -- Low device tier: 10 ring-road vehicles
		end
		local kind = VehicleRig.KINDS[spec.kind] and spec.kind or "Car"
		local def = VehicleRig.KINDS[kind]
		local model = VehicleRig.build(kind, spec.color)
		model.Name = kind .. i
		model.Parent = self.trafficFolder
		local parts, rest = collect(model)
		local wheel = {}
		for j, p in parts do
			wheel[j] = VehicleRig.isWheel(p)
		end
		local base = LANE_SPEED[loop.name] or def.speed
		local v = {
			model = model, parts = parts, rest = rest, wheel = wheel, n = #parts,
			kind = kind, isBus = kind == "Bus", lights = lights, maxPitch = def.maxPitch or 0.05,
			radius = loop.radius, dir = loop.direction, y = loop.y, laneName = loop.name,
			base = base, speed = base, accel = 0, pitch = 0,
			theta = spec.angle % 360, sched = spec.angle % 360,
			halfLen = def.length / 2, halfWidth = def.width / 2,
			bandHalf = CityLayout.crosswalkHalfAngle(loop.radius),
			stopHalf = CityLayout.crosswalkHalfAngle(loop.radius) + S.CrosswalkStopMargin / loop.radius / DEG,
			dwell = 0, lastStop = 0, phase = i * 1.7, hidden = false, still = false, laneMates = {},
			-- a player on the lane ahead: yieldT s waited; `through`: creeping through
			-- them (after PlayerYieldMax), hopT: the little "honk" hop as it starts
			yieldT = 0, through = false, hopT = 0,
			slot = #self.vehicles + 1, capSlot = (#self.vehicles + 1) % CAP_SLOTS, owed = false,
		}
		table.insert(self.vehicles, v)
		if kind == "Police" then
			-- its lightbar flashes with the city pulse
			v.lightRed = model:FindFirstChild("LightbarRed")
			v.lightBlue = model:FindFirstChild("LightbarBlue")
			if v.lightRed and v.lightBlue then
				self.police = v
			end
		end
		lanes[loop.name] = lanes[loop.name] or {}
		table.insert(lanes[loop.name], v)
	end
	for _, list in lanes do
		for _, v in list do
			for _, o in list do
				if o ~= v then
					table.insert(v.laneMates, o)
				end
			end
		end
	end
end

function CityLifeSim:_buildWalkers()
	for laneIndex, lane in WALK_LANES do
		-- Low device tier: every 2nd walker (the lane's spacing doubles)
		local count = if self.half and not lane.angles then math.ceil(lane.count / 2) else lane.count
		for k = 0, count - 1 do
			local hasDog = lane.dogAt == k
			-- the dog-walker holds the leash in the left hand (no balloon there)
			local rig = self:_newCitizen(if hasDog then { balloon = false, kid = false } else nil)
			-- evenly spread, with a small deterministic jitter (+-14% of the spacing)
			local spacing = 360 / count
			local jitter = ((9 * k * k + laneIndex * 5) % 20 - 10) / 10 * 0.14 * spacing
			local theta = if lane.angles then lane.angles[k + 1] % 360 else (lane.start + k * spacing + jitter) % 360
			local seed = laneIndex * 31 + k * 7
			local a = theta * DEG
			local w = {
				x = 0, z = 0,
				rig = rig, lane = lane, theta = theta, sched = theta, speed = lane.speed,
				lateral = 0, pause = 0, wave = false, seed = seed, pauseCount = 0, avoidSide = 0, ghost = false, waitT = 0,
				r = lane.radius, crossWait = 0,
				sector = floor((theta + lane.dir * (lane.pauseLead or 5)) / ZONE_STEP) % ZONE_COUNT, phase = hash01(seed, 1) * 6.28,
				walkClock = hash01(seed, 2) * 6.28, amp = 1, yaw = tangentYaw(a, lane.dir), low = k % LOD_SLOTS,
				nextDoor = if lane.doorChance and #OUTER_DOORS > 0 then nextDoorIndex(theta, lane.dir) else 0, doorCount = 0,
				dog = nil, dogTheta = theta, dogR = lane.radius, dogLead = 0,
				onLane = true, index = #self.walkers + 1, moving = false, holdT = 0, mates = nil,
			}
			if hasDog then
				w.dog = self:_buildDog(#self.dogs + 1)
				w.dogLead = lane.dogLead or 2
				table.insert(self.dogs, w.dog)
			end
			table.insert(self.walkers, w)
		end
	end
end

-- Chibi dog (7 parts, dog space: feet at 0, nose toward -Z): a round body and
-- head, ears, a nose, a wagging tail and a leash (re-spanned hand -> collar
-- every step) - or, for the agility dogs off the leash, a collar. Every part
-- non-colliding, no shadow.
local DOG_FUR = rgb(230, 180, 120)
local DOG_EAR = rgb(176, 118, 70)
local DOG_COLLAR = Vector3.new(0, 1.0, -0.42)
local DOG_TAIL_PIVOT = Vector3.new(0, 1.0, 0.55)
local LEASH_COLOR = rgb(235, 60, 90)
local DOG_PARTS = 7 -- body, head, nose, 2 ears, tail + the leash (or the collar)
-- constant offsets of the dog parts (dog space)
local DOG_BODY_OFF = CFrame.new(0, 0.72, 0)
local DOG_HEAD_OFF = CFrame.new(0, 1.42, -0.62)
local DOG_NOSE_OFF = CFrame.new(0, -0.08, -0.5)
local DOG_EAR_L_OFF = CFrame.new(-0.42, 0.18, 0.05) * CFrame.Angles(0, 0, 0.35)
local DOG_EAR_R_OFF = CFrame.new(0.42, 0.18, 0.05) * CFrame.Angles(0, 0, -0.35)
local DOG_COLLAR_OFF = CFrame.new(0, 1.13, -0.46) * CFrame.Angles(-0.72, 0, 0)
local DOG_TAIL_C, DOG_TAIL_S = math.cos(0.75), math.sin(0.75) -- the tail's fixed 0.75 rad lift

function CityLifeSim:_buildDog(index: number, opts: { fur: Color3?, ear: Color3?, collar: boolean?, parent: Instance? }?)
	local o = opts or {}
	local fur, ear = o.fur or DOG_FUR, o.ear or DOG_EAR
	local model = Instance.new("Model")
	model.Name = "Dog" .. index
	local dog = {
		model = model,
		body = newPart(model, "DogBody", Enum.PartType.Ball, Vector3.new(1.4, 1.4, 1.4), IDENTITY, fur),
		head = newPart(model, "DogHead", Enum.PartType.Ball, Vector3.new(1, 1, 1), IDENTITY, fur),
		nose = newPart(model, "DogNose", Enum.PartType.Ball, Vector3.new(0.3, 0.3, 0.3), IDENTITY, rgb(40, 30, 34)),
		earL = newPart(model, "DogEar", Enum.PartType.Block, Vector3.new(0.2, 0.5, 0.36), IDENTITY, ear),
		earR = newPart(model, "DogEar", Enum.PartType.Block, Vector3.new(0.2, 0.5, 0.36), IDENTITY, ear),
		tail = newPart(model, "DogTail", Enum.PartType.Block, Vector3.new(0.2, 0.2, 0.8), IDENTITY, fur),
		leash = if o.collar then nil else newPart(model, "DogLeash", Enum.PartType.Block, Vector3.new(0.08, 0.08, 2.2), IDENTITY, LEASH_COLOR),
		collar = if o.collar then newPart(model, "DogCollar", Enum.PartType.Block, Vector3.new(0.86, 0.2, 0.62), IDENTITY, LEASH_COLOR) else nil,
		leashLength = 2.2,
		hidden = false,
	}
	model.Parent = o.parent or self.citizenFolder
	return dog
end

-- Shoppers (SHOPPERS): walker records on the OuterA / OuterB lanes with a
-- shop-visit state machine on top (see _stepShopper). Adults at 1.25 in the
-- citizen palette, no balloon / bag / cup of their own: they carry a
-- ShoppingBag (in their accent color) after their first visit.
function CityLifeSim:_buildShoppers()
	local lanes = {}
	for _, lane in WALK_LANES do
		lanes[lane.name] = lane
	end
	for i, plan in SHOPPERS do
		if i > Config.ShopperCount then
			break
		end
		if self.half and i % 2 == 0 then
			continue -- Low device tier: every 2nd shopper
		end
		local lane = lanes[plan.lane]
		local front = FRONTAGES[plan.gap]
		if lane == nil or front == nil or front.theta[lane.name] == nil then
			continue
		end
		local rig = self:_newCitizen({
			kid = false, balloon = false, bag = false, shopBag = true,
			prop = if i % 4 == 3 then "GoldSuit" else "None", -- some wear shades
			backpack = i % 5 == 2,
		})
		self.shopperCount += 1
		local seed = 3100 + i * 37
		local dep = front.theta[lane.name]
		local theta = (dep - lane.dir * (plan.lead or 0)) % 360
		local a = theta * DEG
		local w = {
			x = 0, z = 0,
			rig = rig, lane = lane, theta = theta, sched = theta, speed = lane.speed,
			lateral = 0, pause = 0, wave = false, seed = seed, pauseCount = 0, avoidSide = 0, ghost = false, waitT = 0,
			r = lane.radius, crossWait = 0,
			sector = floor((theta + lane.dir * 5) / ZONE_STEP) % ZONE_COUNT, phase = hash01(seed, 1) * 6.28,
			walkClock = hash01(seed, 2) * 6.28, amp = 1, yaw = tangentYaw(a, lane.dir), low = i % LOD_SLOTS,
			nextDoor = 0, doorCount = 0,
			dog = nil, dogTheta = theta, dogR = lane.radius, dogLead = 0,
			onLane = true, index = #self.walkers + 1, moving = false, holdT = 0, mates = nil,
			-- shopper state
			shopper = true, mode = SHOP_WALK, gap = plan.gap, wp = 1, t0 = 0, timer = 0, glance = 0,
			carry = plan.bag == true, visits = 0, mergeWait = 0, y = lane.y,
			speedMul = 0.94 + 0.12 * hash01(seed, 3),
		}
		local p = CityLayout.ringPos(lane.radius, theta, 0)
		w.x, w.z = p.X, p.Z
		if plan.start == "front" then
			w.mode, w.onLane, w.wp = SHOP_FRONT_IN, false, 1
			local lp = front.lanePoint[lane.name]
			w.x, w.z, w.y = lp.X, lp.Z, lp.Y
			w.yaw = yawToward(front.glance.X - lp.X, front.glance.Z - lp.Z)
		elseif plan.start == "shop" then
			w.mode, w.onLane, w.timer = SHOP_INSIDE, false, plan.timer or 3
			w.x, w.z, w.y = front.door.X, front.door.Z, front.door.Y
			w.carry = false
		elseif plan.start == "out" then
			w.mode, w.onLane, w.t0, w.carry = SHOP_EXIT, false, 0, true
			w.x, w.z, w.y = front.door.X, front.door.Z, front.door.Y
			w.yaw = front.outYaw
		end
		table.insert(self.walkers, w)
	end
end

function CityLifeSim:_buildCrossers()
	local laterals, outerRadii = Config.CrossLaterals, Config.CrossOuterRadii
	for _, group in CROSS_GROUPS do
		local spec = CityLayout.crosswalks[group.zone]
		local cw = self.crosswalks[group.zone]
		if spec and cw then
			if group.red then
				cw.state, cw.timer = STOP, 0 -- this group is mid-road at the render snapshot
			end
			local a = spec.angle * DEG
			for m = 1, #laterals do
				if self.half and m == 2 then
					continue -- Low device tier: A and C only (their own checked lines)
				end
				local kid = group.kid == m
				local rig = self:_newCitizen(if kid then { kid = true } else nil)
				local i = #self.crossers + 1
				local seed = 500 + i * 13
				local outer = m <= 2 -- A and B start in front of the gate, C on the plaza rim
				local speed = Config.CrossSpeedMin + (Config.CrossSpeedMax - Config.CrossSpeedMin) * hash01(seed, 17)
				if rig.scale < Config.CitizenScale then
					speed *= Config.CrossKidBoost
				end
				local c = {
					x = 0, z = 0,
					rig = rig, cw = cw, angle = a, member = m,
					ux = cos(a), uz = sin(a), px = -sin(a), pz = cos(a), side = laterals[m],
					innerR = Config.CrossInnerRadius, outerR = outerRadii[m],
					atOuter = outer, crossing = false, ready = false, pending = false, goAt = 0,
					timer = group.wait[m] or 0, speed = speed, holdT = 0,
					along = if outer then outerRadii[m] else Config.CrossInnerRadius,
					yaw = radialYaw(a, not outer), seed = seed, waits = 0,
					phase = hash01(seed, 5) * 6.28, walkClock = i, amp = 0, low = i % LOD_SLOTS,
					pointer = m == 2, -- B points across the road now and then
					y = S.OuterSidewalkTop, -- feet height at the last pose (for the LOD test)
				}
				table.insert(self.crossers, c)
				table.insert(cw.crossers, c)
			end
		end
	end
end

-- Plaza circles reserved for an act (other idlers and pigeons keep out).
function CityLifeSim:_reserve(center: Vector3, radius: number)
	table.insert(self.reserved, { x = center.X, z = center.Z, radius = radius })
end

-- isPlazaPointFree + outside every reserved circle.
function CityLifeSim:_spotFree(p: Vector3, clearance: number): boolean
	if not CityLayout.isPlazaPointFree(p, clearance) then
		return false
	end
	for _, r in self.reserved do
		local dx, dz = p.X - r.x, p.Z - r.z
		if dx * dx + dz * dz < (r.radius + clearance) ^ 2 then
			return false
		end
	end
	return true
end

-- One standing / sitting citizen that never walks. `opts`: kind, look, yaw,
-- hop, wave, talk, slow (posed every 2nd frame: everyone but the spinning
-- dancer), plus any extra fields the kind's animation reads.
function CityLifeSim:_addIdler(feet: Vector3, faceAt: Vector3?, opts)
	local rig = self:_newCitizen(opts.look)
	local index = #self.idlers + 1
	local d = {
		rig = rig, kind = opts.kind or "Stand", x = feet.X, y = feet.Y, z = feet.Z,
		yaw = opts.yaw or (if faceAt then yawToward(faceAt.X - feet.X, faceAt.Z - feet.Z) else 0),
		hop = opts.hop == true, wave = opts.wave == true, talk = opts.talk == true,
		phase = index * 1.9, low = index % LOD_SLOTS, slow = opts.slow == true,
		seed = 900 + index * 17, rootY = math.huge, rootYaw = 0, -- the last posed root's inputs
	}
	for k, v in opts do
		if d[k] == nil and k ~= "look" then
			d[k] = v
		end
	end
	self.idlers[index] = d
	table.insert(self.staticSpots, { x = feet.X, z = feet.Z })
	return d
end

-- Plaza idlers placed next to real CityLayout props (never on the fountain,
-- never within 15 degrees of the spawn axis, always on free plaza points and
-- outside the street-act circle; the raised plaza planters are CityLayout
-- plaza obstacles, so every spot below is re-validated against them).
function CityLifeSim:_buildIdlers()
	local props = {}
	for _, prop in CityLayout.plazaProps do
		props[prop.kind] = prop
	end
	-- the street act's circle is reserved before anyone else is placed
	self.performerCenter = CityLayout.ringPos(Config.PerformerRadius, Config.PerformerAngle, 0)
	self:_reserve(self.performerCenter, Config.PerformerReserve)

	local function farFromSpawnAxis(p: Vector3): boolean
		return abs(wrapDeg(CityLayout.angleOf(p))) > 15
	end

	-- (a) kids around the balloon vendor, on its plaza-center side
	local vendor = props.BalloonVendor
	if vendor then
		local c = vendor.position
		local base = atan2(-c.Z, -c.X)
		local placed = 0
		for k = 0, 11 do
			if placed >= 3 then
				break
			end
			local off = (if k % 2 == 0 then 1 else -1) * floor((k + 1) / 2) * 34 * DEG
			local p = Vector3.new(c.X + cos(base + off) * 4.4, 0, c.Z + sin(base + off) * 4.4)
			if self:_spotFree(p, 1.2) and farFromSpawnAxis(p) then
				placed += 1
				local feet = Vector3.new(p.X, plazaFeetY(p), p.Z)
				self:_addIdler(feet, c, {
					look = { kid = true, balloon = placed == 2, hat = placed == 3 },
					hop = placed ~= 2, wave = placed == 2, slow = true,
				})
			end
		end
	end

	-- (b) queue in front of the hot dog cart, facing it
	local cart = props.HotDog
	if cart then
		local a = cart.angle
		local spots = { { 44.6, a - 2.6 }, { 44.6, a + 2.6 }, { 41.2, a + 0.4 }, { 41.2, a - 4.5 }, { 41.2, a + 5 } }
		local placed = 0
		for _, spot in spots do
			if placed >= 3 then
				break
			end
			local p = CityLayout.ringPos(spot[1], spot[2], 0)
			if self:_spotFree(p, 1.2) and farFromSpawnAxis(p) then
				placed += 1
				self:_addIdler(Vector3.new(p.X, plazaFeetY(p), p.Z), cart.position, { wave = placed == 3, talk = placed ~= 3, slow = true })
			end
		end
	end

	-- (c) two friends chatting on the plaza bench nearest 300 degrees
	local area = CityLayout.wanderAreas[1]
	local bench, bestDelta = nil, 40
	for _, ob in (area and area.obstacles or {}) do
		if abs(ob.radius - 3.3) < 0.05 then
			local d = abs(wrapDeg(CityLayout.angleOf(ob.position) - 300))
			if d < bestDelta then
				bench, bestDelta = ob, d
			end
		end
	end
	if bench then
		local flat = Vector3.new(bench.position.X, 0, bench.position.Z)
		-- Mirrors MapBuilder.buildBench: lookAt the plaza center, seat top 1.625 above the floor.
		local benchCF = CityLayout.facingCFrame(flat.Magnitude, CityLayout.angleOf(flat), S.PlazaTop)
		for _, x in { -1.45, 1.45 } do
			local rigScale = Config.CitizenScale
			local seat = benchCF * CFrame.new(x, 1.625 - BODY_BOTTOM * rigScale, -0.05)
			-- facingCFrame yaw is (90 - angle) degrees; turn the two friends toward each other
			local yaw = HALF_PI - CityLayout.angleOf(flat) * DEG - x * 0.12
			self:_addIdler(seat.Position, nil, { kind = "Sit", yaw = yaw, talk = true, slow = true, look = { kid = false, balloon = false } })
		end
	end
end

-- Plaza street act at CityLayout.ringPos(34, 250): a breakdancer on a
-- cardboard mat next to a boombox, 6 clapping spectators on a ring around.
local DANCE_CYCLE = 5.5 -- 0.25 dive, 3 s head spin, 0.25 flip out, 2 s hop + wave
local DANCE_PHASE = 2.8 -- the render snapshot (t ~ 4.5) lands mid head spin
local HAIR_TOP = 4.33 -- unscaled top of a citizen's hair dome (head-spin contact)

function CityLifeSim:_buildStreetAct()
	local c = self.performerCenter
	if c == nil then
		return
	end
	local feetY = plazaFeetY(c)
	local matTop = feetY + 0.14
	local toPlaza = atan2(-c.Z, -c.X) -- world angle (radians) from the act toward the plaza center
	local front = yawToward(-c.X, -c.Z)
	newPart(self.plazaFolder, "DanceMat", Enum.PartType.Cylinder, Vector3.new(0.1, 6, 6),
		CFrame.new(c.X, matTop - 0.05, c.Z) * CFrame.Angles(0, 0, HALF_PI), rgb(200, 160, 110))

	-- boombox just off the mat, beside it (never hidden behind the dancer from
	-- the plaza), speakers toward the plaza
	local boxAngle = toPlaza - 82 * DEG
	local bx, bz = c.X + cos(boxAngle) * 4.3, c.Z + sin(boxAngle) * 4.3
	local boxY = feetY + 0.65
	local boxCF = yawCF(bx, boxY, bz, front)
	local box = newPart(self.plazaFolder, "Boombox", Enum.PartType.Block, Vector3.new(2.2, 1.3, 0.9), boxCF, rgb(60, 60, 80))
	local speakers = {}
	for i, sx in { -0.55, 0.55 } do
		local rest = CFrame.new(sx, 0, -0.47) * CFrame.Angles(0, HALF_PI, 0)
		speakers[i] = { part = newPart(self.plazaFolder, "BoomboxSpeaker", Enum.PartType.Cylinder, Vector3.new(0.12, 0.9, 0.9), boxCF * rest, rgb(255, 110, 190), Enum.Material.Neon), rest = rest }
	end
	self.boombox = { part = box, x = bx, y = boxY, z = bz, yaw = front, speakers = speakers }

	-- the breakdancer (no hat, short hair: the hair dome takes the head spin)
	self:_addIdler(Vector3.new(c.X, matTop, c.Z), nil, {
		kind = "Dancer", yaw = front, front = front,
		look = { kid = false, hat = false, hairStyle = 0, balloon = false, backpack = false, bag = false, prop = "None",
			shirt = rgb(255, 110, 190), pants = rgb(40, 40, 48) },
	})

	-- spectators on a 6.5 ring facing in, open toward the plaza center so the
	-- spawn / plaza views see the act (the boombox sits between two of them)
	for k, rel in { -55, 55, -110, 110, -150, 150 } do
		for _, nudge in { 0, 8, -8, 16, -16 } do
			local a = toPlaza + (rel + nudge) * DEG
			local p = Vector3.new(c.X + cos(a) * Config.SpectatorRing, 0, c.Z + sin(a) * Config.SpectatorRing)
			if CityLayout.isPlazaPointFree(p, 1.0) then
				self:_addIdler(Vector3.new(p.X, plazaFeetY(p), p.Z), c, {
					kind = "Clap", slow = true, period = 2.6 + 2.4 * hash01(k, 61),
					look = { kid = k == 4, balloon = false, bag = false },
				})
				break
			end
		end
	end
end

-- Fountain selfie trio (r 14.5, 135/145/155 degrees, facing outward): the
-- middle one holds a phone up; teen scale so the squeezed-in trio never clips.
function CityLifeSim:_buildSelfie()
	for k, angle in { 135, 145, 155 } do
		local p = CityLayout.ringPos(14.5, angle, 0)
		if self:_spotFree(p, 0.8) then
			local role = k - 2 -- -1 (middle at +X), 0 (phone), +1 (middle at -X)
			self:_addIdler(Vector3.new(p.X, plazaFeetY(p), p.Z), nil, {
				kind = "Selfie", role = role, slow = true,
				yaw = radialYaw(angle * DEG, true),
				look = { kid = true, balloon = false, bag = false, phone = role == 0, prop = "None", hat = role == 1 },
			})
		end
	end
end

-- Storefront loiterers: one in front of the display window of every Shop A
-- (Shop-A-local (4.5, -10.5), left of the door lane x 7.5..10.5 the shoppers
-- use), looking at the window with idle head turns; every 25-40 s they turn
-- to face the plaza for 4 s. They never walk.
local LOITER_SPOT = Vector3.new(4.5, 0, -10.5)
CityLifeSim.LOITER_SPOT = LOITER_SPOT
function CityLifeSim:_buildStorefronts()
	if self.half then
		return -- Low device tier: no storefront loiterers
	end
	for _, shop in CityLayout.shops do
		if shop.kind == "A" then
			local spot = shop.cframe:PointToWorldSpace(LOITER_SPOT)
			local feet = Vector3.new(spot.X, CityLayout.surfaceY(spot), spot.Z)
			-- the display window spans shop-local x -10.5..5.5 left of the door (x 8.5)
			local windowAt = (shop.cframe * CFrame.new(5, 0, -7)).Position
			local k = shop.gapIndex
			-- on the café terrace rug (flat, 0.08 over the block ground) where it reaches
			local T = CityLayout.Cafe and CityLayout.Cafe.terrace
			if T and abs(LOITER_SPOT.X - T.x) <= T.width / 2 and abs(LOITER_SPOT.Z - T.z) <= T.depth / 2 then
				feet = Vector3.new(feet.X, S.BlockGroundTop + T.thickness, feet.Z)
			end
			self:_addIdler(feet, nil, {
				kind = "Loiter", slow = true,
				yaw = yawToward(windowAt.X - feet.X, windowAt.Z - feet.Z),
				baseYaw = yawToward(windowAt.X - feet.X, windowAt.Z - feet.Z),
				altYaw = yawToward(-feet.X, -feet.Z),
				nextTurn = 1 + 30 * hash01(k, 71), turnUntil = -1, turnCount = 0,
				look = { kid = false, balloon = false, bag = k % 2 == 1, backpack = k % 4 == 2 },
			})
		end
	end
end

-- Café sitters: one on the first stool of every gap's terrace
-- (CityLayout.cafeSeats), seated, facing the table, sipping a coffee.
function CityLifeSim:_buildCafeSitters()
	local seats = CityLayout.cafeSeats
	if seats == nil or self.half then
		return -- (Low device tier: no café sitters)
	end
	local taken = {}
	for _, seat in seats do
		local g = seat.gapIndex
		if not taken[g] then
			taken[g] = true
			local scale = Config.CitizenScale
			local pos = seat.position
			self:_addIdler(Vector3.new(pos.X, pos.Y - BODY_BOTTOM * scale, pos.Z), nil, {
				kind = "Cafe", slow = true,
				yaw = yawToward(seat.facing.X, seat.facing.Z),
				period = 6.5 + 2.5 * hash01(g, 81),
				look = { kid = false, balloon = false, prop = "CoffeeCup", backpack = false },
			})
		end
	end
end

----------------------------------------------------------------------
-- Zone customers: a queue at every hustle counter + sitters / browsers
----------------------------------------------------------------------
-- Everything is planned in zone-local space (Mechanics.zoneGroundCFrame at the
-- pad top: -Z faces the plaza, the pad spans x / z -32..32) and validated in
-- bindMap against the zone model's real parts, so the spots follow the map.

local PAD_TOP = S.PlazaTop -- zone pads share the plaza top (1.5)
local COIN_GOLD = rgb(255, 206, 40)
local Q_WAIT, Q_BUY, Q_LOOP, B_WALK, B_PAUSE = 1, 2, 3, 4, 5
local BUY_STEP, BUY_HOP, COIN_RISE = 0.3, 0.4, 0.6 -- seconds: step up, hop, coin pop
local GATE_LOCAL = Vector3.new(0, 0, -31) -- zone entrance (gate) center, zone-local
local QUEUE_GAP = 2.4 -- a customer walking up the queue keeps this far behind the one ahead

-- Generic queue candidates (offsets from the counter center P): the first
-- whose spots validate unmoved wins. Each is a head pair plus a third spot
-- appended at the tail with the same spacing (3-person queues).
local QUEUE_CANDIDATES = {
	{ Vector3.new(-7.5, 0, -2), Vector3.new(-9.5, 0, -4.4) },
	{ Vector3.new(-9, 0, -6), Vector3.new(-11, 0, -8.4) },
	{ Vector3.new(7, 0, -6), Vector3.new(9, 0, -8.4) },
}
local QUEUE_LENGTH = 3
for _, spots in QUEUE_CANDIDATES do
	while #spots < QUEUE_LENGTH do
		local last, prev = spots[#spots], spots[#spots - 1]
		table.insert(spots, last + (last - prev))
	end
end

-- Per-zone plan (zone-local studs). queue: explicit spots (else 2 from
-- QUEUE_CANDIDATES); faceAt: what the queue looks at (else P); loop: explicit
-- walk-back waypoints; seats: sitters on Dressing parts found by name nearest
-- `near`; browse: a 3-waypoint stroll near the props.
local CUSTOMER_PLAN = {
	LemonadeStand = {
		P = Vector3.new(0, 0, 9), -- the stand itself is the counter (top 3.7)
		queue = { Vector3.new(-7.5, 0, 6.0), Vector3.new(-9.5, 0, 3.6), Vector3.new(-11.5, 0, 1.2), Vector3.new(-13.5, 0, -1.2) },
		faceAt = Vector3.new(0, 0, 9),
		firstBuy = 4.0, -- the render snapshot (t ~ 4.5 s) catches a coin mid-pop
		coin = Vector3.new(-5.4, 0, 7.4), -- the stand top's queue-side end, clear of the name board above its middle
		kidSlot = 3, -- a kid with a balloon...
		cupKidSlot = 4, -- ...and, at the very back, a kid with a lemonade already in hand
		cupColor = rgb(255, 230, 90),
		seats = {
			{ part = "Stool", near = Vector3.new(-16.6, 0, -10), faceNearest = "TableTop", kind = "Cafe", cup = rgb(255, 230, 90) },
			{ part = "Stool", near = Vector3.new(16.6, 0, -10), faceNearest = "TableTop", kind = "Cafe", cup = rgb(255, 230, 90) },
		},
	},
	SneakerFlipping = {
		-- sneakerheads inside the velvet-rope lane, facing the store door (-X)
		queue = { Vector3.new(14, 0, 5), Vector3.new(17, 0, 5), Vector3.new(20, 0, 5) },
		faceAt = Vector3.new(8, 0, 5),
		phoneSlot = 2,
		-- out of the lane's open -X end, around the ropes, back in at the +X end
		loop = { Vector3.new(10.4, 0, 5), Vector3.new(10.4, 0, 0.6), Vector3.new(25.4, 0, 0.6), Vector3.new(25.4, 0, 5) },
	},
	-- around the agility hoops (clear of the giant bone)
	-- (firstBuy > 4.53: the r4_dog_inside / r4_zone_top / r4_stock_inside renders show the whole line of 3)
	-- Dog Walking: the generic line's 3rd spot would stand on the paw-print trail
	-- (and slide out of the r4_dog_inside frame), so this line runs sideways
	-- from the counter's end instead
	DogWalking = {
		queue = { Vector3.new(-7.5, 0, -10.5), Vector3.new(-10.3, 0, -10.5), Vector3.new(-13.1, 0, -10.5) },
		browse = { Vector3.new(-14.5, 0, -4.5), Vector3.new(-11.5, 0, -2.2), Vector3.new(-15, 0, 1.2) }, browseKid = true, firstBuy = 5.2,
	},
	-- between the two queued cars, clear of the buckets and >= 2.4 from the
	-- car-wash car's lane (conveyor z 8 +- 4)
	CarWash = { browse = { Vector3.new(-14.5, 0, 0.8), Vector3.new(-12.5, 0, -2.6), Vector3.new(-15.2, 0, -4.8) }, firstBuy = 5.6 },
	FoodTruck = {
		seats = { { part = "PicnicBench", near = Vector3.new(20, 0, -13.6), faceNearest = "PicnicTop", axis = true, kind = "Cafe", cup = rgb(235, 60, 60) } },
	},
	ContentCreator = {
		seats = { { part = "Cushion", near = Vector3.new(-21.8, 0, 2.4), faceLookOf = "CouchSeat", kind = "Sit", phone = true } },
	},
	StockDesk = { browse = { Vector3.new(-17, 0, 8.5), Vector3.new(-12.5, 0, 12), Vector3.new(-16, 0, 15.5) }, firstBuy = 5.0 },
	StartupHQ = {
		seats = { { part = "Beanbag", near = Vector3.new(-22, 0, 8), faceCounter = true, kind = "Sit", sink = 0.3, kid = true, hop = true } },
	},
}
CityLifeSim.CUSTOMER_PLAN = CUSTOMER_PLAN

local SHAPE_BOX, SHAPE_BALL, SHAPE_CYLINDER = 0, 1, 2

-- Visible parts of a zone model as distance primitives (world AABB height
-- range + horizontal bounding radius for a cheap pre-filter).
local function collectColliders(root: Instance)
	local list = {}
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") and d.Transparency < 1 then
			local cf, h = d.CFrame, d.Size * 0.5
			local _, _, _, _, _, _, r10, r11, r12 = cf:GetComponents()
			local ey = abs(r10) * h.X + abs(r11) * h.Y + abs(r12) * h.Z
			local p = cf.Position
			local shape = SHAPE_BOX
			if d:IsA("Part") then
				if d.Shape == Enum.PartType.Ball then
					shape = SHAPE_BALL
				elseif d.Shape == Enum.PartType.Cylinder then
					shape = SHAPE_CYLINDER
				end
			end
			table.insert(list, { cf = cf, h = h, shape = shape, x = p.X, z = p.Z, yb = p.Y - ey, yt = p.Y + ey, rad = h.Magnitude, name = d.Name })
		end
	end
	return list
end
CityLifeSim.collectColliders = collectColliders

-- Distance from a world point to a collider's solid (0 inside).
local function colliderDistance(c, x: number, y: number, z: number): number
	local l = c.cf:PointToObjectSpace(Vector3.new(x, y, z))
	local h = c.h
	if c.shape == SHAPE_BALL then
		return max(0, l.Magnitude - min(h.X, h.Y, h.Z))
	elseif c.shape == SHAPE_CYLINDER then
		local radial = max(0, sqrt(l.Y * l.Y + l.Z * l.Z) - min(h.Y, h.Z))
		local axial = max(0, abs(l.X) - h.X)
		return sqrt(radial * radial + axial * axial)
	end
	local dx, dy, dz = max(0, abs(l.X) - h.X), max(0, abs(l.Y) - h.Y), max(0, abs(l.Z) - h.Z)
	return sqrt(dx * dx + dy * dy + dz * dz)
end

-- True when the vertical body column at (x, z) from feetY + CustomerBandLow to
-- feetY + CustomerBandHigh keeps `clearance` from every collider (parts wholly
-- below / above the band are ignored, so the pad and its stripes never count).
-- The distance to a convex solid is convex along the column: ternary search.
-- Ankle-high floor decals (top <= feet + DECAL_TOP: paw prints, the dog-walk
-- mat, the car-wash conveyor bed) are walk-over: a standing spot only keeps
-- `decalReach` from them (its feet never stand on one); paths pass 0 and
-- ignore them.
local DECAL_TOP = 0.7
local function columnClear(list, x: number, feetY: number, z: number, clearance: number, decalReach: number?): (boolean, string?)
	local y0, y1 = feetY + Config.CustomerBandLow, feetY + Config.CustomerBandHigh
	local reachDecal = decalReach or 0.8
	for _, c in list do
		if c.yt >= y0 and c.yt <= feetY + DECAL_TOP and c.yb <= y1 then
			if reachDecal > 0 then
				local dx, dz = c.x - x, c.z - z
				local reach = c.rad + reachDecal
				if dx * dx + dz * dz < reach * reach and colliderDistance(c, x, c.yt - 0.01, z) < reachDecal then
					return false, c.name
				end
			end
		elseif c.yt >= y0 and c.yb <= y1 then
			local dx, dz = c.x - x, c.z - z
			local reach = c.rad + clearance
			if dx * dx + dz * dz < reach * reach then
				local lo, hi = y0, y1
				for _ = 1, 24 do
					local m1 = lo + (hi - lo) / 3
					local m2 = hi - (hi - lo) / 3
					if colliderDistance(c, x, m1, z) <= colliderDistance(c, x, m2, z) then
						hi = m2
					else
						lo = m1
					end
				end
				if colliderDistance(c, x, (lo + hi) / 2, z) < clearance then
					return false, c.name
				end
			end
		end
	end
	return true, nil
end
CityLifeSim.columnClear = columnClear

-- Distance from p to segment a-b on the XZ plane.
local function segmentDistanceXZ(px: number, pz: number, ax: number, az: number, bx: number, bz: number): number
	local dx, dz = bx - ax, bz - az
	local len2 = dx * dx + dz * dz
	local u = if len2 > 0 then clamp(((px - ax) * dx + (pz - az) * dz) / len2, 0, 1) else 0
	local ex, ez = ax + dx * u - px, az + dz * u - pz
	return sqrt(ex * ex + ez * ez)
end

-- Validation context of one zone (zone-local tests + world column tests).
local function zoneContext(zoneModel: Instance, zoneCF: CFrame, feetY: number)
	local station = zoneModel:FindFirstChild("HustleStation")
	local prompt = station and station:FindFirstChild("PromptPart")
	local anchor = station and station:FindFirstChild("AutoAnchor")
	local promptL = if prompt then zoneCF:PointToObjectSpace((prompt :: BasePart).CFrame.Position) else nil
	local anchorL = if anchor then zoneCF:PointToObjectSpace((anchor :: BasePart).CFrame.Position) else nil
	return {
		cf = zoneCF, feetY = feetY, colliders = collectColliders(zoneModel),
		promptL = promptL, anchorL = anchorL, occupied = {},
	}
end

-- Zone-local XZ spot rules shared by standing spots and walk paths.
local function localRulesOk(ctx, l: Vector3, keepScale: number): boolean
	if abs(l.X) > 30 or abs(l.Z) > 30 then
		return false -- stay on the pad
	end
	if ctx.promptL then
		local q = ctx.promptL
		if Vector3.new(l.X - q.X, 0, l.Z - q.Z).Magnitude < Config.PromptKeep * keepScale then
			return false
		end
		-- gate -> prompt walkway
		if segmentDistanceXZ(l.X, l.Z, GATE_LOCAL.X, GATE_LOCAL.Z, q.X, q.Z) < Config.CoreHalfWidth then
			return false
		end
	elseif abs(l.X) < Config.CoreHalfWidth and l.Z < 0 then
		return false
	end
	if ctx.anchorL then
		local q = ctx.anchorL
		if Vector3.new(l.X - q.X, 0, l.Z - q.Z).Magnitude < Config.AnchorKeep * keepScale then
			return false
		end
	end
	return true
end

-- A standing spot (zone-local): local rules, the 1.2 column clearance and
-- 2.4 studs from every spot already taken in this zone.
local function spotOk(ctx, l: Vector3): boolean
	if not localRulesOk(ctx, l, 1) then
		return false
	end
	for _, o in ctx.occupied do
		if Vector3.new(l.X - o.X, 0, l.Z - o.Z).Magnitude < 2.4 then
			return false
		end
	end
	local w = ctx.cf:PointToWorldSpace(l)
	return (columnClear(ctx.colliders, w.X, ctx.feetY, w.Z, Config.CustomerClearance))
end
CityLifeSim.customerSpotOk = spotOk

-- A walking path (zone-local polyline): every 0.5 studs keeps the walking
-- clearance, stays on the pad and off the gate -> counter walkway.
local function pathOk(ctx, points: { Vector3 }): boolean
	for i = 1, #points - 1 do
		local a, b = points[i], points[i + 1]
		local steps = max(1, math.ceil((b - a).Magnitude / 0.5))
		for k = 0, steps do
			local l = a:Lerp(b, k / steps)
			if not localRulesOk(ctx, l, 0.75) then
				return false
			end
			local w = ctx.cf:PointToWorldSpace(l)
			if not columnClear(ctx.colliders, w.X, ctx.feetY, w.Z, Config.CustomerPathClearance, 0) then
				return false
			end
		end
	end
	return true
end

-- Slides a blocked spot away from the counter along `dir` 1 stud at a time
-- (up to QueueSlideMax); nil when it never validates.
local function slideSpot(ctx, l: Vector3, dir: Vector3): Vector3?
	for s = 0, Config.QueueSlideMax do
		local p = l + dir * s
		if spotOk(ctx, p) then
			return p
		end
	end
	return nil
end

-- Validates a queue (zone-local spots, head first): returns the accepted
-- spots (possibly slid; fewer when some had to be dropped) and the total slide.
local function validateQueue(ctx, spots: { Vector3 }): ({ Vector3 }, number)
	local dir = if #spots >= 2 then Vector3.new(spots[2].X - spots[1].X, 0, spots[2].Z - spots[1].Z).Unit else Vector3.new(0, 0, -1)
	local accepted = {}
	local slide = 0
	local saved = #ctx.occupied
	for _, l in spots do
		local p = slideSpot(ctx, l, dir)
		if p then
			slide += (p - l).Magnitude
			table.insert(accepted, p)
			table.insert(ctx.occupied, p)
		end
	end
	-- roll back the occupancy; the caller commits the winner
	for i = #ctx.occupied, saved + 1, -1 do
		ctx.occupied[i] = nil
	end
	return accepted, slide
end

-- The buyer's step toward the counter and its walk-back loop for a queue
-- (zone-local): the step is 1.2 studs against the queue direction; the loop
-- is the plan's explicit one, else 3 waypoints around the queue's outer side
-- (away from the gate -> counter walkway, wider first). Returns the step,
-- the queue direction and the first loop whose whole path validates (or nil).
local function planLoop(ctx, spots: { Vector3 }, faceL: Vector3, P: Vector3, explicit: { Vector3 }?)
	local u = if #spots >= 2 then Vector3.new(spots[2].X - spots[1].X, 0, spots[2].Z - spots[1].Z).Unit
		else Vector3.new(spots[1].X - faceL.X, 0, spots[1].Z - faceL.Z).Unit
	local stepL = spots[1] - u * 1.2
	local tail = spots[#spots]
	local candidates = {}
	local v = Vector3.new(-u.Z, 0, u.X)
	for _, offset in { 3, 2.2 } do
		for _, side in { 1, -1 } do
			local vv = v * side * offset
			local first = spots[1] + vv
			table.insert(candidates, {
				points = { first, tail + vv + u * 2.5, tail + u * 2.5 },
				score = segmentDistanceXZ(first.X, first.Z, GATE_LOCAL.X, GATE_LOCAL.Z, P.X, P.Z) + offset * 0.1,
			})
		end
	end
	table.sort(candidates, function(a, b)
		return a.score > b.score
	end)
	if explicit then
		table.insert(candidates, 1, { points = explicit, score = math.huge })
	end
	for _, cand in candidates do
		local path = { stepL }
		for _, p in cand.points do
			table.insert(path, p)
		end
		table.insert(path, tail)
		if pathOk(ctx, path) then
			return stepL, u, cand.points
		end
	end
	return stepL, u, nil
end

-- Nearest Dressing part named `name` to the zone-local point `near`.
local function findSeatPart(zoneModel: Instance, zoneCF: CFrame, name: string, near: Vector3): BasePart?
	local best, bestD = nil, math.huge
	for _, d in zoneModel:GetDescendants() do
		if d.Name == name and d:IsA("BasePart") then
			local l = zoneCF:PointToObjectSpace(d.CFrame.Position)
			local dist = Vector3.new(l.X - near.X, 0, l.Z - near.Z).Magnitude
			if dist < bestD then
				best, bestD = d, dist
			end
		end
	end
	return if bestD < 6 then best else nil
end

-- One rig for a customer (citizen palette, NameTag removed, adults 1.25 / kids 1.0).
function CityLifeSim:_newCustomerRig(overrides)
	self.customerCount += 1
	local look = { balloon = false }
	for k, v in overrides do
		look[k] = v
	end
	return self:_newCitizen(look)
end

-- Builds every zone's customers + its coin from the real zone models.
function CityLifeSim:_bindCustomers(map: Instance)
	local zonesFolder = map:FindFirstChild("Zones")
	if zonesFolder == nil then
		return
	end
	self.customerFolder = newFolder(self.folder, "Customers")
	local zones = table.clone(GameConfig.Zones)
	table.sort(zones, function(a, b)
		return a.Order < b.Order
	end)
	for _, zone in zones do
		local zoneModel = zonesFolder:FindFirstChild(zone.Id)
		if zoneModel then
			self:_bindZoneCustomers(zone, zoneModel, CUSTOMER_PLAN[zone.Id] or {})
		end
	end
	self.poseAllNext = true -- new rigs are at the origin: pose everything once
end

function CityLifeSim:_bindZoneCustomers(zone, zoneModel: Instance, plan)
	local order = zone.Order
	local zoneCF = Mechanics.zoneGroundCFrame(order) * CFrame.new(0, PAD_TOP, 0)
	local feetLocal = if zone.Id == "DogWalking" then 0.2 else 0.06 -- dog lawn / pad stripes
	local feetY = zoneCF.Position.Y + feetLocal
	local ctx = zoneContext(zoneModel, zoneCF, feetY)

	-- counter center P (zone-local): the real CounterTop when there is one
	local station = zoneModel:FindFirstChild("HustleStation")
	local counterTop = (station and station:FindFirstChild("CounterTop")) or zoneModel:FindFirstChild("StandTop")
	local P = plan.P or Vector3.new(0, 0, -10)
	local topY = 3.5
	if counterTop and counterTop:IsA("BasePart") then
		local l = zoneCF:PointToObjectSpace(counterTop.CFrame.Position)
		topY = l.Y + counterTop.Size.Y / 2
		if plan.P == nil then
			P = Vector3.new(l.X, 0, l.Z)
		end
	end

	-- everything this zone's customers stand on / walk along (world), so the
	-- zone life (car-wash car, agility dogs) can keep its distance
	local geo = { points = {}, paths = {} }
	self.customerGeo[zone.Id] = geo

	-- sitters first (their seats are fixed): they become idlers
	local customers = 0
	for _, seatPlan in (plan.seats or {}) do
		local part = findSeatPart(zoneModel, zoneCF, seatPlan.part, seatPlan.near)
		if part then
			customers += self:_addSeatCustomer(zone, zoneModel, zoneCF, P, part, seatPlan, ctx)
			table.insert(geo.points, part.CFrame.Position)
		end
	end

	-- the queue: explicit spots, or the first generic candidate pair whose two
	-- spots validate unmoved with a valid walk-back loop (else the best one:
	-- most spots, a loop, the least sliding)
	local faceL = plan.faceAt or P
	local spots, stepL, loopL = {}, nil, nil
	if plan.queue then
		spots = validateQueue(ctx, plan.queue)
		if #spots > 0 then
			local s1, _, l1 = planLoop(ctx, spots, faceL, P, plan.loop)
			stepL, loopL = s1, l1
		end
	else
		local bestScore = -math.huge
		for index, candidate in QUEUE_CANDIDATES do
			local candidateSpots = table.create(#candidate)
			for k, offset in candidate do
				candidateSpots[k] = P + offset
			end
			local accepted, slide = validateQueue(ctx, candidateSpots)
			if #accepted > 0 then
				local s1, _, l1 = planLoop(ctx, accepted, faceL, P, nil)
				local score = #accepted * 1000 + (if l1 then 100 else 0) - slide * 5 - index
				if score > bestScore then
					bestScore = score
					spots, stepL, loopL = accepted, s1, l1
				end
				if #accepted == #candidate and l1 and slide < 0.01 then
					break
				end
			end
		end
	end
	for _, l in spots do
		table.insert(ctx.occupied, l)
	end

	local zr = nil
	if #spots > 0 then
		local face = zoneCF:PointToWorldSpace(faceL)
		zr = {
			id = zone.Id, order = order, cf = zoneCF, feetY = feetY, n = #spots,
			spots = {}, asideOk = {}, faceX = face.X, faceZ = face.Z,
			members = {}, count = 0, buys = 0, buyer = nil,
			nextBuy = self.t + (plan.firstBuy or (2 + 7 * hash01(order, 3))),
			loop = {}, loopN = 0, loopSpeed = Config.QueueWalk,
			gateX = 0, gateZ = 0, playerNear = false, px = 0, pz = 0,
		}
		local gate = zoneCF:PointToWorldSpace(GATE_LOCAL)
		zr.gateX, zr.gateZ = gate.X, gate.Z
		for k, l in spots do
			local w = zoneCF:PointToWorldSpace(Vector3.new(l.X, feetLocal, l.Z))
			zr.spots[k] = w
			zr.asideOk[k] = self:_asideDirections(ctx, l)
		end
		zr.stepPos = zoneCF:PointToWorldSpace(Vector3.new(stepL.X, feetLocal, stepL.Z))
		if loopL then
			local tail = spots[#spots]
			local length = (loopL[1] - stepL).Magnitude
			for k, l in loopL do
				zr.loop[k] = zoneCF:PointToWorldSpace(Vector3.new(l.X, feetLocal, l.Z))
				if k > 1 then
					length += (l - loopL[k - 1]).Magnitude
				end
			end
			length += (tail - loopL[#loopL]).Magnitude
			zr.loopN = #loopL
			zr.loopSpeed = clamp(length / Config.LoopSeconds, 2.4, 5.5)
		end
		for _, w in zr.spots do
			table.insert(geo.points, w)
		end
		local walk = { zr.spots[1], zr.stepPos }
		for _, w in zr.loop do
			table.insert(walk, w)
		end
		table.insert(walk, zr.spots[#zr.spots])
		table.insert(geo.paths, walk)
		-- the coin: parked until the head of the queue buys
		local side = if spots[1].X < P.X then -1 else 1
		local coinL = Vector3.new(P.X + side * 1.8, topY + 0.55, P.Z - 0.7)
		if plan.coin then
			coinL = Vector3.new(plan.coin.X, topY + 0.55, plan.coin.Z)
		elseif counterTop and counterTop:IsA("BasePart") then
			local l = zoneCF:PointToObjectSpace(counterTop.CFrame.Position)
			coinL = Vector3.new(l.X + side * 1.8, topY + 0.55, l.Z - min(0.7, counterTop.Size.Z / 2 - 0.4))
		end
		local coinW = zoneCF:PointToWorldSpace(coinL)
		local coin = newPart(self.customerFolder, "CustomerCoin", Enum.PartType.Ball, Vector3.new(1, 1, 1), PARK, COIN_GOLD, Enum.Material.Neon)
		coin.Name = "CustomerCoin" .. order
		zr.coin = { part = coin, x = coinW.X, y = coinW.Y, z = coinW.Z, t0 = -100, parked = true, capSlot = (order * 3) % CAP_SLOTS, owed = false }
		-- the queue members (head first)
		for k = 1, #spots do
			local kid = plan.kidSlot == k
			local cupKid = plan.cupKidSlot == k
			local rig = self:_newCustomerRig({
				kid = kid or cupKid, balloon = kid, hat = if plan.phoneSlot then k ~= plan.phoneSlot else nil,
				phone = plan.phoneSlot == k,
				prop = if plan.phoneSlot == k then "None" elseif cupKid then "CoffeeCup" else nil,
				cupColor = if cupKid then plan.cupColor else nil,
			})
			rig.model.Parent = self.customerFolder
			local w = zr.spots[k]
			local c = self:_newCustomer(rig, zr, w, Q_WAIT)
			c.phoneUp = plan.phoneSlot == k
			zr.count += 1
			zr.members[zr.count] = c
			c.slot = k
			c.yaw = yawToward(zr.faceX - w.X, zr.faceZ - w.Z)
			customers += 1
		end
		table.insert(self.customerZones, zr)
	end

	-- a browser strolling near the props (when the zone has no seat for its extra)
	if plan.browse then
		local center = Vector3.zero
		for _, l in plan.browse do
			center += l
		end
		center /= #plan.browse
		local points = {}
		for _, l in plan.browse do
			local p = l
			for _ = 0, 8 do
				if spotOk(ctx, p) then
					break
				end
				p = p + (center - p).Unit * 0.5
			end
			if spotOk(ctx, p) then
				table.insert(points, p)
			end
		end
		if #points >= 2 then
			local closed = table.clone(points)
			table.insert(closed, points[1])
			if pathOk(ctx, closed) then
				local rig = self:_newCustomerRig({ kid = plan.browseKid == true })
				rig.model.Parent = self.customerFolder
				local worldPoints, asides = {}, {}
				for k, l in points do
					worldPoints[k] = zoneCF:PointToWorldSpace(Vector3.new(l.X, feetLocal, l.Z))
					asides[k] = self:_asideDirections(ctx, l)
					table.insert(ctx.occupied, l)
				end
				local c = self:_newCustomer(rig, zr, worldPoints[1], B_PAUSE)
				c.points, c.pointAside, c.nPoints, c.wp = worldPoints, asides, #worldPoints, 1
				local loop = table.clone(worldPoints)
				table.insert(loop, worldPoints[1])
				table.insert(geo.paths, loop)
				c.pauseT = 1 + hash01(order, 41) * 2
				local gate = zoneCF:PointToWorldSpace(GATE_LOCAL)
				c.gateX, c.gateZ = gate.X, gate.Z
				customers += 1
			end
		end
	end
	return customers
end

-- 8 aside directions (zone-local unit XZ) and whether a 1.5-stud step that
-- way stays clear (standing clearance 1.0).
local ASIDE_DIRS = {}
for k = 0, 7 do
	local a = k * math.pi / 4
	ASIDE_DIRS[k + 1] = Vector3.new(cos(a), 0, sin(a))
end

function CityLifeSim:_asideDirections(ctx, l: Vector3)
	local ok = {}
	for k, d in ASIDE_DIRS do
		local p = l + d * Config.AsideStep
		local wpos = ctx.cf:PointToWorldSpace(p)
		local clear = abs(p.X) < 30 and abs(p.Z) < 30
			and (columnClear(ctx.colliders, wpos.X, ctx.feetY, wpos.Z, 1.0))
		-- store the WORLD direction (the sim moves in world space)
		local wd = ctx.cf:VectorToWorldSpace(d)
		ok[k] = { x = wd.X, z = wd.Z, ok = clear }
	end
	return ok
end

function CityLifeSim:_newCustomer(rig, zr, w: Vector3, state: number)
	local index = #self.customers + 1
	local c = {
		rig = rig, zr = zr, state = state, slot = 0, t0 = 0, wp = 0,
		x = w.X, y = w.Y, z = w.Z, yaw = 0,
		walkClock = hash01(index, 3) * 6.28, amp = 0, moving = false,
		phase = hash01(index, 5) * 6.28, seed = 1300 + index * 23, low = index % LOD_SLOTS,
		ax = 0, az = 0, axGoal = 0, azGoal = 0, asideT = 0,
		nextWave = 3 + 10 * hash01(index, 7), waveUntil = -1, waves = 0,
		holdT = 0, phoneUp = false,
		points = nil, pointAside = nil, nPoints = 0, pauseT = 0,
	}
	self.customers[index] = c
	return c
end

-- A seated customer (an idler of kind "Cafe" / "Sit") on a zone's own seat.
function CityLifeSim:_addSeatCustomer(zone, zoneModel: Instance, zoneCF: CFrame, P: Vector3, part: BasePart, seatPlan, ctx): number
	local kid = seatPlan.kid == true
	local scale = if kid then Config.KidScale else Config.CitizenScale
	local cf = part.CFrame
	local _, _, _, _, _, _, r10, r11, r12 = cf:GetComponents()
	local h = part.Size * 0.5
	local top = cf.Position.Y + abs(r10) * h.X + abs(r11) * h.Y + abs(r12) * h.Z
	if seatPlan.sink then
		-- a squashy beanbag: sit down into it
		top = cf.Position.Y + seatPlan.sink * part.Size.Y
	end
	local seat = cf.Position
	-- facing (world XZ)
	local fx, fz = 0, -1
	if seatPlan.faceNearest then
		local target = findSeatPart(zoneModel, zoneCF, seatPlan.faceNearest, zoneCF:PointToObjectSpace(seat))
		if target then
			local d = target.CFrame.Position - seat
			if seatPlan.axis then
				-- benches: face straight across, along the bench's short axis
				local look = cf.LookVector
				local sgn = if d.X * look.X + d.Z * look.Z >= 0 then 1 else -1
				fx, fz = look.X * sgn, look.Z * sgn
			else
				fx, fz = d.X, d.Z
			end
		end
	elseif seatPlan.faceLookOf then
		local couch = findSeatPart(zoneModel, zoneCF, seatPlan.faceLookOf, zoneCF:PointToObjectSpace(seat))
		local look = (if couch then couch.CFrame else cf).LookVector
		fx, fz = look.X, look.Z
	elseif seatPlan.faceCounter then
		local p = zoneCF:PointToWorldSpace(P)
		fx, fz = p.X - seat.X, p.Z - seat.Z
	end
	local feet = Vector3.new(seat.X, top - BODY_BOTTOM * scale, seat.Z)
	self.customerCount += 1
	local look = {
		kid = kid, balloon = false, bag = false, backpack = false,
		prop = if seatPlan.cup then "CoffeeCup" else "None", cupColor = seatPlan.cup,
		phone = seatPlan.phone == true,
	}
	local d = self:_addIdler(feet, nil, {
		kind = seatPlan.kind, slow = true, yaw = yawToward(fx, fz),
		period = 6.5 + 2.5 * hash01(zone.Order, 83), phoneUp = seatPlan.phone == true,
		hop = seatPlan.hop == true, talk = false, wave = seatPlan.phone ~= true,
		look = look, customer = true,
	})
	d.rig.model.Parent = self.customerFolder
	table.insert(ctx.occupied, zoneCF:PointToObjectSpace(seat))
	return 1
end

-- Moves (x, z) toward (tx, tz) at `speed`; returns the distance left.
local function approach(c, tx: number, tz: number, speed: number, dt: number): number
	local dx, dz = tx - c.x, tz - c.z
	local d = sqrt(dx * dx + dz * dz)
	if d < 1e-3 then
		c.moving = false
		return 0
	end
	local stepLen = min(d, speed * dt)
	c.x += dx / d * stepLen
	c.z += dz / d * stepLen
	c.moving = true
	c.walkClock += dt * 9 * speed / 6
	c.yaw += wrapRad(yawToward(dx, dz) - c.yaw) * min(1, dt * 10)
	return d - stepLen
end

-- Nearest player to each customer zone (waves look at them).
function CityLifeSim:_scanZonePlayers()
	local players, count = self.playerPos, self.playerCount
	for _, zr in self.customerZones do
		zr.playerNear = false
		local best = 60 * 60
		for p = 1, count do
			local pos = players[p]
			local dx, dz = pos.X - zr.gateX, pos.Z - zr.gateZ
			local d2 = dx * dx + dz * dz
			if d2 < best then
				best = d2
				zr.playerNear, zr.px, zr.pz = true, pos.X, pos.Z
			end
		end
	end
end

-- Steps aside from a player standing within AsideRadius of the spot (one of
-- the spot's pre-validated directions, the most "away" one); back 2 s later.
function CityLifeSim:_stepAside(c, homeX: number, homeZ: number, asideOk, dt: number)
	local players, count = self.playerPos, self.playerCount
	local r2 = Config.AsideRadius * Config.AsideRadius
	for p = 1, count do
		local pos = players[p]
		local dx, dz = homeX + c.ax - pos.X, homeZ + c.az - pos.Z
		if dx * dx + dz * dz < r2 and abs(pos.Y - c.y - 2.5) < 4 then
			if c.asideT <= 0 and asideOk then
				local bestDot, bx, bz = -math.huge, 0, 0
				for k = 1, #asideOk do
					local a = asideOk[k]
					if a.ok then
						local dot = a.x * dx + a.z * dz
						if dot > bestDot then
							bestDot, bx, bz = dot, a.x, a.z
						end
					end
				end
				c.axGoal, c.azGoal = bx * Config.AsideStep, bz * Config.AsideStep
			end
			c.asideT = Config.AsideHold
			break
		end
	end
	if c.asideT > 0 then
		c.asideT -= dt
		if c.asideT <= 0 then
			c.axGoal, c.azGoal = 0, 0
		end
	end
	local k = min(1, dt * 6)
	c.ax += (c.axGoal - c.ax) * k
	c.az += (c.azGoal - c.az) * k
end

-- True when a player stands within 2.2 studs ahead of a walking customer
-- (it waits, then walks on after 2.5 s so nobody ever gets stuck).
function CityLifeSim:_playerAhead(c, dt: number): boolean
	local players, count = self.playerPos, self.playerCount
	local fx, fz = -sin(c.yaw), -cos(c.yaw)
	for p = 1, count do
		local pos = players[p]
		local dx, dz = pos.X - c.x, pos.Z - c.z
		local ahead = dx * fx + dz * fz
		if ahead > 0 and ahead < 2.4 and abs(dx * fz - dz * fx) < 1.6 and abs(pos.Y - c.y - 2.5) < 4 then
			c.holdT += dt
			return c.holdT < 2.5
		end
	end
	c.holdT = 0
	return false
end

function CityLifeSim:_stepCustomers(dt: number)
	local t = self.t
	if #self.customerZones > 0 then
		self:_scanZonePlayers()
	end
	-- 1) the head of each queue buys every BuyMin..BuyMax s
	for _, zr in self.customerZones do
		if zr.count > 0 and t >= zr.nextBuy then
			local head = zr.members[1]
			local s1 = zr.spots[1]
			local dx, dz = head.x - s1.X, head.z - s1.Z
			if head.state == Q_WAIT and dx * dx + dz * dz < 0.04 and head.asideT <= 0 then
				for k = 1, zr.count - 1 do
					zr.members[k] = zr.members[k + 1]
					zr.members[k].slot = k
				end
				zr.members[zr.count] = nil
				zr.count -= 1
				head.state, head.t0, head.slot = Q_BUY, t, 0
				zr.buyer = head
				head.ax, head.az, head.axGoal, head.azGoal = 0, 0, 0, 0
				zr.coin.t0 = t + BUY_STEP
				zr.buys += 1
				zr.nextBuy = t + Config.BuyMin + (Config.BuyMax - Config.BuyMin) * hash01(zr.order * 7, zr.buys)
			else
				zr.nextBuy = t + 0.5 -- try again once the head is in place
			end
		end
	end
	-- 2) every customer
	for i = 1, #self.customers do
		local c = self.customers[i]
		local zr = c.zr
		local state = c.state
		local hopY, armsUp = 0, false
		if state == Q_WAIT then
			local spot = zr.spots[c.slot]
			-- walking up the line: keep QUEUE_GAP behind the one ahead while they
			-- are still shuffling up (the new head: behind the buyer until it has
			-- stepped away from the counter)
			local ahead = nil
			if c.slot > 1 then
				ahead = zr.members[c.slot - 1]
				local aheadSpot = zr.spots[c.slot - 1]
				if ahead and (ahead.x - aheadSpot.X) ^ 2 + (ahead.z - aheadSpot.Z) ^ 2 <= 0.01 then
					ahead = nil -- already standing at its spot
				end
			elseif zr.buyer and zr.buyer.state ~= Q_WAIT then
				ahead = zr.buyer
			end
			local left = 1
			if ahead and (ahead.x - c.x) ^ 2 + (ahead.z - c.z) ^ 2 < QUEUE_GAP * QUEUE_GAP
				and (spot.X - c.x) ^ 2 + (spot.Z - c.z) ^ 2 > 0.01 then
				c.moving = false
			else
				left = approach(c, spot.X, spot.Z, Config.QueueWalk, dt)
			end
			if left <= 0 then
				c.moving = false
				local face = yawToward(zr.faceX - c.x, zr.faceZ - c.z)
				c.yaw += wrapRad(face - c.yaw) * min(1, dt * 5)
				self:_stepAside(c, spot.X, spot.Z, zr.asideOk[c.slot], dt)
			end
		elseif state == Q_BUY then
			local u = t - c.t0
			local s1, sp = zr.spots[1], zr.stepPos
			local k = smooth01(u / BUY_STEP)
			c.x, c.z = s1.X + (sp.X - s1.X) * k, s1.Z + (sp.Z - s1.Z) * k
			c.moving = u < BUY_STEP
			if c.moving then
				c.walkClock += dt * 9 * 1.2 / BUY_STEP / 6
			end
			local face = yawToward(zr.faceX - c.x, zr.faceZ - c.z)
			c.yaw += wrapRad(face - c.yaw) * min(1, dt * 8)
			if u >= BUY_STEP and u < BUY_STEP + BUY_HOP then
				hopY = 0.8 * c.rig.scale * sin(math.pi * (u - BUY_STEP) / BUY_HOP)
				armsUp = true
			elseif u >= BUY_STEP + BUY_HOP + 0.15 then
				c.state, c.wp = Q_LOOP, 1 -- (no valid loop: rejoins the tail straight away)
			end
		elseif state == Q_LOOP then
			local target = if c.wp <= zr.loopN then zr.loop[c.wp] else nil
			if target == nil then
				-- rejoin the tail
				zr.count += 1
				zr.members[zr.count] = c
				c.slot, c.state = zr.count, Q_WAIT
			elseif not self:_playerAhead(c, dt) then
				if approach(c, target.X, target.Z, zr.loopSpeed, dt) <= 0 then
					c.wp += 1
				end
			else
				c.moving = false
			end
		elseif state == B_PAUSE then
			local p = c.points[c.wp]
			c.moving = false
			c.pauseT -= dt
			self:_stepAside(c, p.X, p.Z, c.pointAside[c.wp], dt)
			if c.pauseT <= 0 and c.asideT <= 0 then
				c.wp = c.wp % c.nPoints + 1
				c.state = B_WALK
			end
		elseif state == B_WALK then
			local p = c.points[c.wp]
			if self:_playerAhead(c, dt) then
				c.moving = false
			elseif approach(c, p.X, p.Z, Config.BrowseSpeed, dt) <= 0 then
				c.state = B_PAUSE
				c.waves += 1
				c.pauseT = 1.5 + 1.5 * hash01(c.seed, c.waves)
			end
		end
		c.amp += ((if c.moving then 1 else 0) - c.amp) * min(1, dt * 8)
		-- an occasional wave toward the nearest player (or the gate)
		if t >= c.nextWave then
			c.waves += 1
			c.nextWave = t + 9 + 8 * hash01(c.seed, c.waves)
			if not c.moving and state ~= Q_BUY then
				c.waveUntil = t + 1.6
			end
		end
		if self.simOnly then
			continue
		end
		local x, z = c.x + c.ax, c.z + c.az
		-- standing customers: every 2nd frame is plenty
		local visible, animate = self:_citizenVisible(c.rig, x, c.y, z, c.low, if not c.moving and not armsUp then 2 else nil)
		if visible then
			self:_poseCustomer(c, x, z, t, animate, hopY, armsUp)
		end
	end
	-- 3) the coins: pop 3 studs up from the counter over 0.6 s, then park
	for _, zr in self.customerZones do
		local coin = zr.coin
		local u = (t - coin.t0) / COIN_RISE
		if u >= 0 and u < 1 and not self.simOnly then
			local lod = self:_pedLod(coin.x, coin.y, coin.z, 0)
			if lod ~= LOD_HIDE and self:_admit(coin, 1) then
				local k = 1 - (1 - u) * (1 - u)
				self:_emit(coin.part, CFrame.new(coin.x, coin.y + 3 * k, coin.z))
				coin.parked = false
			end
		elseif not coin.parked and not self.simOnly and self:_capRoom(1) then
			coin.parked = true
			self:_emit(coin.part, PARK)
		end
	end
end

function CityLifeSim:_poseCustomer(c, x: number, z: number, t: number, animate: boolean, hopY: number, armsUp: boolean)
	local s = c.rig.scale
	local swing = if animate then sin(c.walkClock) * c.amp else 0
	local y = c.y + hopY
	local la, laRoll, ra, raRoll, ll, rl, head = 0.6 * swing, 0, -0.6 * swing, 0, -0.5 * swing, 0.5 * swing, 0
	local roll = 0
	if armsUp then
		laRoll, raRoll = -2.6, 2.6
		la, ra, ll, rl = 0, 0, -0.35, -0.35
	elseif c.amp > 0.05 then
		y += 0.12 * s * abs(sin(c.walkClock)) * c.amp
		roll = 0.06 * swing
	elseif animate then
		-- idle: weight shift + looking around (at the counter, the plaza, friends)
		roll = 0.045 * sin(1.3 * t + c.phase)
		y += 0.03 * s * (1 - cos(2.6 * t + c.phase))
		head = 0.45 * sin(0.8 * t + c.phase)
		if t < c.waveUntil then
			-- wave at the nearest player (else toward the gate, where players come from)
			local zr = c.zr
			local tx, tz = c.gateX or x, c.gateZ or z
			if zr then
				if zr.playerNear then
					tx, tz = zr.px, zr.pz
				else
					tx, tz = zr.gateX, zr.gateZ
				end
			end
			head = clamp(wrapRad(yawToward(tx - x, tz - z) - c.yaw), -1.1, 1.1)
			raRoll = 2.5 + 0.4 * sin(12 * t + c.phase)
			ra = 0
		end
	end
	if c.phoneUp then
		ra, raRoll = 2.3, 0.5 -- filming the drop
	end
	local root = if roll ~= 0 then yawRollCF(x, y, z, c.yaw, roll) else yawCF(x, y, z, c.yaw)
	self:_poseCitizen(c.rig, root, la, laRoll, ra, raRoll, ll, rl, head)
end

----------------------------------------------------------------------
-- Zone life: every hustle zone's hero prop in motion
----------------------------------------------------------------------
-- Bound once in bindMap from the replicated zone models (client-local, like
-- the customers): spinners on the hero props, the Stock Desk ticker chase and
-- the Creator Studio heartbeat (city pulse, 10 Hz), a car rolling through the
-- car wash and two dogs running the agility course (CityLife.ZoneLife).
-- Hard rules: nothing here ever moves or recolors PromptPart / HustlePrompt /
-- FeedbackPart / AutoAnchor / HustleStation / CounterTop / Gate* or any part
-- with CanCollide true; an entry whose named parts are missing or collide is
-- skipped, and all skipped entries are reported in ONE warning.

-- Spinners about world Y. `parts`: names in the zone model (every part with
-- that name turns); pivot: `pivotTop` = top center of that part, `axisPart` =
-- a vertical axis through that part's center. `snap`: the angle (deg) the
-- group has turned at the render snapshot.
local ZONE_SPINNERS = {
	LemonadeStand = {
		{ label = "giant lemon", parts = { "GiantLemon", "LemonTip" }, axisPart = "GiantLemon", rate = 20, snap = 40 },
	},
	SneakerFlipping = {
		{ label = "giant sneaker", parts = { "SneakerSole", "SneakerHeel", "SneakerBody", "SneakerToe", "SneakerSwoosh" }, pivotTop = "SneakerPedestal", rate = 30, snap = 45 },
		-- the 3 mini sneakers on the DisplayPedestals, alternating directions
		{ label = "mini sneakers", minis = true, rate = 45, snap = 45 },
	},
	StartupHQ = {
		-- the collidable RocketBody stays put: it is a vertical cylinder on the
		-- spin axis, so the nose, fins and window turning round it read as the
		-- whole rocket turning (no bob: the body may not move)
		{ label = "rocket", parts = { "RocketNose", "RocketFin", "RocketWindow" }, axisPart = "RocketBody", rate = 20, snap = 30 },
	},
	ContentCreator = {
		{ label = "neon heart", parts = { "HeartBody", "HeartLobe" }, axisPart = "HeartPost", rate = 35, snap = 35, beat = true },
	},
	FoodTruck = {
		{ label = "roof burger", parts = { "BurgerBunBottom", "BurgerPatty", "BurgerCheese", "BurgerLettuce", "BurgerBunTop", "SesameSeed" }, axisPart = "BurgerBunBottom", rate = 25, snap = 20 },
	},
}
CityLifeSim.ZONE_SPINNERS = ZONE_SPINNERS
local MINI_SNEAKER_PARTS = { "MiniSole", "MiniUpper", "MiniToe" }
-- Stock Desk ticker chase groups (each its own chase): the hype board's
-- zig-zag (climbing), the office screens' lines, the pillar stripes
local TICKER_GROUPS = { "TickerStrip", "TickerLine", "TickerStripe" }
local TICKER_LIT = rgb(60, 255, 120)
local CONTRACT_NAMES = { PromptPart = true, HustlePrompt = true, FeedbackPart = true, AutoAnchor = true, HustleStation = true, CounterTop = true }

-- True when the zone life may move / recolor this part (never a collider,
-- a contract part or anything inside the HustleStation or a gate).
local function zoneLifeMovable(part: BasePart): boolean
	if part.CanCollide or CONTRACT_NAMES[part.Name] or string.sub(part.Name, 1, 4) == "Gate" then
		return false
	end
	local a = part.Parent
	while a ~= nil and not a:IsA("Folder") do
		if CONTRACT_NAMES[a.Name] or string.sub(a.Name, 1, 4) == "Gate" then
			return false
		end
		if a:GetAttribute("ZoneId") ~= nil then
			break -- the zone model itself
		end
		a = a.Parent
	end
	return true
end
CityLifeSim.zoneLifeMovable = zoneLifeMovable

-- World-space vertical half extent of a part's bounding box.
local function halfHeight(part: BasePart): number
	local _, _, _, _, _, _, r10, r11, r12 = part.CFrame:GetComponents()
	local h = part.Size * 0.5
	return abs(r10) * h.X + abs(r11) * h.Y + abs(r12) * h.Z
end

-- Min / max corner of a part's box in `cf`'s object space.
local function localBox(cf: CFrame, part: BasePart): (Vector3, Vector3)
	local h = part.Size * 0.5
	local lo, hi = nil, nil
	for _, sx in { -1, 1 } do
		for _, sy in { -1, 1 } do
			for _, sz in { -1, 1 } do
				local p = cf:PointToObjectSpace(part.CFrame:PointToWorldSpace(Vector3.new(sx * h.X, sy * h.Y, sz * h.Z)))
				lo = if lo then lo:Min(p) else p
				hi = if hi then hi:Max(p) else p
			end
		end
	end
	return lo, hi
end

-- XZ distance from a point to a zone-local rectangle (x0..x1, z0..z1).
local function rectDistance(lx: number, lz: number, x0: number, x1: number, z0: number, z1: number): number
	local dx = max(x0 - lx, 0, lx - x1)
	local dz = max(z0 - lz, 0, lz - z1)
	return sqrt(dx * dx + dz * dz)
end

-- Smallest XZ distance from a zone's customer geometry (points + paths
-- sampled every 0.5 studs, world) to a zone-local test function.
local function customerDistance(geo, zoneCF: CFrame, distanceAt: (number, number) -> number): number
	local best = math.huge
	if geo == nil then
		return best
	end
	for _, p in geo.points do
		local l = zoneCF:PointToObjectSpace(p)
		best = min(best, distanceAt(l.X, l.Z))
	end
	for _, path in geo.paths do
		for i = 1, #path - 1 do
			local a, b = zoneCF:PointToObjectSpace(path[i]), zoneCF:PointToObjectSpace(path[i + 1])
			local n = max(1, math.ceil((b - a).Magnitude / 0.5))
			for k = 0, n do
				local l = a:Lerp(b, k / n)
				best = min(best, distanceAt(l.X, l.Z))
			end
		end
	end
	return best
end

-- Trapezoid speed profile: `d` studs at top speed `v`, `ta` s to reach it
-- (triangular when too short). Duration, and distance done after `u` s.
local function rollTime(d: number, v: number, ta: number): number
	if d >= v * ta then
		return d / v + ta
	end
	return 2 * sqrt(d * ta / v)
end
local function rollDistance(u: number, d: number, v: number, ta: number): number
	local a = v / ta
	local T = rollTime(d, v, ta)
	if u <= 0 then
		return 0
	elseif u >= T then
		return d
	end
	if d >= v * ta then
		if u < ta then
			return 0.5 * a * u * u
		elseif u > T - ta then
			local r = T - u
			return d - 0.5 * a * r * r
		end
		return 0.5 * v * ta + v * (u - ta)
	end
	if u < T / 2 then
		return 0.5 * a * u * u
	end
	local r = T - u
	return d - 0.5 * a * r * r
end
CityLifeSim.rollDistance = rollDistance

function CityLifeSim:_bindZoneLife(map: Instance)
	local zonesFolder = map:FindFirstChild("Zones")
	if zonesFolder == nil then
		return
	end
	self.zoneLifeFolder = newFolder(self.folder, "ZoneLife")
	local zones = table.clone(GameConfig.Zones)
	table.sort(zones, function(a, b)
		return a.Order < b.Order
	end)
	for _, zone in zones do
		local zoneModel = zonesFolder:FindFirstChild(zone.Id)
		if zoneModel == nil then
			continue
		end
		local zoneCF = Mechanics.zoneGroundCFrame(zone.Order) * CFrame.new(0, PAD_TOP, 0)
		local byName = {}
		for _, d in zoneModel:GetDescendants() do
			if d:IsA("BasePart") then
				byName[d.Name] = byName[d.Name] or {}
				table.insert(byName[d.Name], d)
			end
		end
		for _, spec in (ZONE_SPINNERS[zone.Id] or {}) do
			if spec.minis then
				self:_bindMiniSpinners(zone, zoneCF, byName, spec)
			else
				self:_bindZoneSpinner(zone, byName, spec)
			end
		end
		if zone.Id == "StockDesk" then
			self:_bindTicker(byName)
		elseif zone.Id == "CarWash" then
			self:_bindCarWash(zone, zoneModel, zoneCF, byName)
		elseif zone.Id == "DogWalking" then
			self:_bindCourse(zone, zoneModel, zoneCF, byName)
		end
	end
	if #self.zoneSkipped > 0 then
		warn("[CityLifeSim] zone life skipped (missing or collidable parts are never moved): " .. table.concat(self.zoneSkipped, "; "))
	end
	self.poseAllNext = true
end

function CityLifeSim:_addZoneSpinner(parts: { BasePart }, pivot: Vector3, rate: number, snap: number)
	local a0 = snap - rate * SNAPSHOT_T -- turned `snap` degrees at the render snapshot
	local group = {}
	for _, p in parts do
		local sp = {
			part = p, pivot = pivot, offset = CFrame.new(-pivot) * p.CFrame, rate = rate, a0 = a0,
			zone = true, orig = p.CFrame,
		}
		table.insert(self.spinners, sp)
		table.insert(group, sp)
	end
	self:_addSpinGroup(group, pivot, rate, a0, true)
	self.zoneSpinGroups += 1
end

function CityLifeSim:_bindZoneSpinner(zone, byName, spec)
	local parts, problems = {}, {}
	for _, name in spec.parts do
		local found = byName[name]
		if found == nil then
			table.insert(problems, name .. " missing")
			continue
		end
		local blocked = false
		for _, p in found do
			if not zoneLifeMovable(p) then
				blocked = true
			end
			table.insert(parts, p)
		end
		if blocked then
			table.insert(problems, name)
		end
	end
	local pivot = nil
	local base = (byName[spec.pivotTop or spec.axisPart] or {})[1]
	if base == nil then
		table.insert(problems, (spec.pivotTop or spec.axisPart) .. " missing")
	elseif spec.pivotTop then
		pivot = base.CFrame.Position + Vector3.new(0, halfHeight(base), 0)
	else
		pivot = base.CFrame.Position
	end
	if #problems > 0 or pivot == nil then
		local collide = {}
		for _, name in problems do
			if not string.find(name, "missing", 1, true) then
				table.insert(collide, name)
			end
		end
		local text = table.concat(problems, ", ")
		if #collide == #problems and #collide > 0 then
			text = table.concat(collide, ", ") .. " collide"
		end
		table.insert(self.zoneSkipped, ("%s %s (%s)"):format(zone.Id, spec.label, text))
		return
	end
	self:_addZoneSpinner(parts, pivot, spec.rate, spec.snap)
	if spec.beat and self.pulse then
		-- the heartbeat: transparency 0 -> 0.3 -> 0 (city pulse, 10 Hz)
		for _, p in parts do
			table.insert(self.pulse.hearts, { part = p, orig = p.Transparency, last = -1, pos = pivot })
		end
	end
end

function CityLifeSim:_bindMiniSpinners(zone, zoneCF: CFrame, byName, spec)
	local pedestals = table.clone(byName.DisplayPedestal or {})
	table.sort(pedestals, function(a, b)
		return zoneCF:PointToObjectSpace(a.CFrame.Position).Z < zoneCF:PointToObjectSpace(b.CFrame.Position).Z
	end)
	for k, pedestal in pedestals do
		local c = pedestal.CFrame.Position
		local parts, ok = {}, true
		for _, name in MINI_SNEAKER_PARTS do
			for _, p in (byName[name] or {}) do
				local d = p.CFrame.Position - c
				if d.X * d.X + d.Z * d.Z < 2.2 * 2.2 then
					if zoneLifeMovable(p) then
						table.insert(parts, p)
					else
						ok = false
					end
				end
			end
		end
		if ok and #parts > 0 then
			local rate = if k % 2 == 1 then spec.rate else -spec.rate
			self:_addZoneSpinner(parts, c + Vector3.new(0, halfHeight(pedestal), 0), rate, spec.snap * (if rate > 0 then 1 else -1))
		else
			table.insert(self.zoneSkipped, ("%s mini sneaker %d (%s)"):format(zone.Id, k, if ok then "missing" else "collides"))
		end
	end
end

-- Stock Desk ticker chase (city pulse): per group one lit segment
-- (TICKER_LIT, transparency 0) every TickerStep s, the rest at TickerDim.
function CityLifeSim:_bindTicker(byName)
	local pulse = self.pulse
	if pulse == nil then
		return
	end
	for _, name in TICKER_GROUPS do
		local list = {}
		for _, p in (byName[name] or {}) do
			if zoneLifeMovable(p) then
				table.insert(list, p)
			end
		end
		if #list < 2 then
			continue
		end
		-- the zig-zag climbs (by height), the screen lines / pillar stripes run
		-- along the zone (by angle round the ticker's own center)
		local center = Vector3.zero
		for _, p in list do
			center += p.CFrame.Position
		end
		center /= #list
		table.sort(list, function(a, b)
			local pa, pb = a.CFrame.Position, b.CFrame.Position
			if name == "TickerStrip" then
				return pa.Y < pb.Y
			end
			return atan2(pa.Z - center.Z, pa.X - center.X) < atan2(pb.Z - center.Z, pb.X - center.X)
		end)
		local group = { parts = list, base = {}, baseT = {}, n = #list, cur = 0, pos = center }
		for k, p in list do
			group.base[k] = p.Color
			group.baseT[k] = p.Transparency
		end
		table.insert(pulse.tickers, group)
	end
end

----------------------------------------------------------------------
-- Car wash: a VehicleRig Car (scaled to the zone's 8-stud cars) rolls along
-- the conveyor centerline at WashSpeed: in at the -X end (the end with the
-- queued cars), WashScrub s under the roller brushes with a scrub bob, out
-- of the +X end where it eases to a stop, parks hidden for WashHidden s and
-- comes again in the next color (one pass ~12 s). The tunnel's middle bay
-- holds the map's own collidable demo car, which may never move: the moving
-- car stops nose-to-tail behind it (the first brush scrubs its flank), then
-- continues from just past its front bumper - a swap hidden by the tunnel
-- roof, its 4.5-tall front wall and the taller demo car itself.
----------------------------------------------------------------------

local WASH_COLORS = { rgb(255, 206, 40), rgb(255, 120, 170), rgb(90, 200, 255), rgb(140, 230, 110) }
local WASH_SNAP = 0.85 -- the render snapshot catches the car this far down its exit roll (half out of the tunnel, r4_zone_top)
local WASH_IN, WASH_SCRUB, WASH_OUT, WASH_HOLD, WASH_HIDDEN = 1, 2, 3, 4, 5

function CityLifeSim:_bindCarWash(zone, zoneModel: Instance, zoneCF: CFrame, byName)
	local base = (byName.ConveyorBase or {})[1]
	local ends = byName.ConveyorEnd or {}
	if base == nil or #ends < 2 or byName.ConveyorRoller == nil then
		table.insert(self.zoneSkipped, "CarWash car (no conveyor)")
		return
	end
	local cz = zoneCF:PointToObjectSpace(base.CFrame.Position).Z
	local rideY = 0
	for _, roller in byName.ConveyorRoller do
		local _, hi = localBox(zoneCF, roller)
		rideY = max(rideY, hi.Y)
	end
	local endIn, endOut = -math.huge, math.huge -- inner faces of the two end stops
	for _, e in ends do
		local lo, hi = localBox(zoneCF, e)
		if lo.X + hi.X < 0 then
			endIn = max(endIn, hi.X)
		else
			endOut = min(endOut, lo.X)
		end
	end
	-- the collidable demo car in the tunnel's middle bay (direct children)
	local demoLo, demoHi = math.huge, -math.huge
	for _, name in { "CarBody", "CarCabin", "CarWheel" } do
		for _, p in (byName[name] or {}) do
			if p.Parent == zoneModel then
				local lo, hi = localBox(zoneCF, p)
				if lo.Z < cz + 3 and hi.Z > cz - 3 then
					demoLo, demoHi = min(demoLo, lo.X), max(demoHi, hi.X)
				end
			end
		end
	end

	local s = Config.WashScale
	local model = VehicleRig.build("Car", WASH_COLORS[1])
	model.Name = "WashCar"
	local parts, rest = {}, {}
	local chassis, cabin = nil, nil
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			local cf = d.CFrame
			local r = CFrame.new(cf.Position * s) * (CFrame.new(-cf.Position) * cf)
			d.Size = d.Size * s
			d.CFrame = PARK
			table.insert(parts, d)
			table.insert(rest, r)
			if d.Name == "Chassis" then
				chassis = d
			elseif d.Name == "Cabin" then
				cabin = d
			end
		end
	end
	local def = VehicleRig.KINDS.Car
	local halfLen = def.length / 2 * s
	local wheelReach = (3.6 + 1.3) * s -- wheel center + tire radius from the car's middle
	local startX = endIn + 0.2 + wheelReach
	local endX = endOut - 0.2 - wheelReach
	local stopX, swapX
	if demoLo < demoHi then
		stopX = demoLo - 0.35 - halfLen
		swapX = demoHi + 0.35 + halfLen
	else
		-- no demo car: drive straight through, scrub under the brush nearest the middle
		local brushX, bestD = 0, math.huge
		for _, b in (byName.RollerBrush or {}) do
			local x = zoneCF:PointToObjectSpace(b.CFrame.Position).X
			if abs(x) < bestD then
				brushX, bestD = x, abs(x)
			end
		end
		stopX, swapX = brushX, brushX
	end
	if not (startX < stopX and swapX < endX) then
		model:Destroy()
		table.insert(self.zoneSkipped, "CarWash car (conveyor too short)")
		return
	end

	-- the critic's footprint rules: +-4 wide, never within 4.5 (XZ) of the
	-- PromptPart, 4 of the AutoAnchor, 2.4 of any customer spot or walk path
	local rects = {
		{ startX - halfLen, stopX + halfLen, cz - 4, cz + 4 },
		{ swapX - halfLen, endX + halfLen, cz - 4, cz + 4 },
	}
	local function footprintDistance(lx: number, lz: number): number
		local d = math.huge
		for _, r in rects do
			d = min(d, rectDistance(lx, lz, r[1], r[2], r[3], r[4]))
		end
		return d
	end
	local station = zoneModel:FindFirstChild("HustleStation")
	local problem = nil
	for _, rule in { { "PromptPart", Config.PromptKeep }, { "AutoAnchor", Config.AnchorKeep } } do
		local part = station and station:FindFirstChild(rule[1])
		if part and part:IsA("BasePart") then
			local l = zoneCF:PointToObjectSpace(part.CFrame.Position)
			if footprintDistance(l.X, l.Z) < rule[2] then
				problem = rule[1]
			end
		end
	end
	local customerGap = customerDistance(self.customerGeo[zone.Id], zoneCF, footprintDistance)
	if customerGap < 2.4 then
		problem = ("customers %.1f studs away"):format(customerGap)
	end
	if problem then
		model:Destroy()
		table.insert(self.zoneSkipped, "CarWash car (" .. problem .. ")")
		return
	end
	model.Parent = self.zoneLifeFolder

	local v, ta = Config.WashSpeed, Config.WashAccel
	local tIn = rollTime(stopX - startX, v, ta)
	local tOut = rollTime(endX - swapX, v, ta)
	local cycle = tIn + Config.WashScrub + tOut + Config.WashHold + Config.WashHidden
	-- at the snapshot the (yellow) car is WASH_SNAP of the way down its exit roll
	local dOut = endX - swapX
	local lo, hi = 0, tOut
	for _ = 1, 30 do
		local mid = (lo + hi) / 2
		if rollDistance(mid, dOut, v, ta) < WASH_SNAP * dOut then
			lo = mid
		else
			hi = mid
		end
	end
	local snapClock = tIn + Config.WashScrub + lo
	local clock0 = (snapClock - SNAPSHOT_T) % cycle
	self.washCar = {
		model = model, parts = parts, rest = rest, n = #parts, chassis = chassis, cabin = cabin,
		frame = zoneCF * CFrame.new(0, 0, cz) * CFrame.Angles(0, -HALF_PI, 0), -- local -Z = zone +X
		zoneCF = zoneCF, cz = cz, rideY = rideY, halfLen = halfLen,
		startX = startX, stopX = stopX, swapX = swapX, endX = endX,
		tIn = tIn, tOut = tOut, cycle = cycle, clock = clock0,
		-- the yellow car is the one in the snapshot
		colorBase = -floor((clock0 + SNAPSHOT_T) / cycle), color = 0,
		x = startX, phase = WASH_HIDDEN, hidden = true, still = false, low = 1,
		spawnWait = 0, capSlot = 7, owed = false,
	}
end

-- Position (zone-local x), bob and phase of the wash car at its clock.
function CityLifeSim:_washState(car): (number, number, number)
	local tau = car.clock % car.cycle
	local v, ta = Config.WashSpeed, Config.WashAccel
	if tau < car.tIn then
		return car.startX + rollDistance(tau, car.stopX - car.startX, v, ta), 0, WASH_IN
	end
	tau -= car.tIn
	if tau < Config.WashScrub then
		return car.stopX, Config.WashScrubBob * 0.5 * (1 - cos(2 * math.pi * 3 * tau)), WASH_SCRUB
	end
	tau -= Config.WashScrub
	if tau < car.tOut then
		return car.swapX + rollDistance(tau, car.endX - car.swapX, v, ta), 0, WASH_OUT
	end
	tau -= car.tOut
	if tau < Config.WashHold then
		return car.endX, 0, WASH_HOLD
	end
	return car.endX, 0, WASH_HIDDEN
end

-- True when a player stands on the conveyor lane (+-4 of its centerline,
-- body band) between zone-local x0 and x1.
function CityLifeSim:_washPlayerIn(car, x0: number, x1: number): boolean
	local players = self.playerPos
	for p = 1, self.playerCount do
		local l = car.zoneCF:PointToObjectSpace(players[p])
		if l.X > x0 and l.X < x1 and abs(l.Z - car.cz) < 4 and l.Y > -2 and l.Y < 9 then
			return true
		end
	end
	return false
end

function CityLifeSim:_stepWashCar(dt: number)
	local car = self.washCar
	if car == nil then
		return
	end
	local x0, _, phase0 = self:_washState(car)
	local L = car.halfLen
	local hold = false
	if phase0 == WASH_IN or phase0 == WASH_OUT then
		car.spawnWait = 0
		-- a player standing on the conveyor just ahead of the nose holds the car;
		-- one already inside its footprint does not (it rolls on through them:
		-- life parts never collide, and it never parks inside anyone)
		hold = self:_washPlayerIn(car, x0 + L, x0 + L + 2.5)
	elseif phase0 == WASH_HIDDEN or phase0 == WASH_SCRUB then
		-- never appear on top of a player: a new pass (at startX) / the swap
		-- past the demo car (to swapX) waits while one stands there, at most
		-- WashSpawnHoldMax s
		local tau = car.clock % car.cycle
		local boundary = if phase0 == WASH_HIDDEN then car.cycle else car.tIn + Config.WashScrub
		if tau + dt >= boundary and car.spawnWait < Config.WashSpawnHoldMax then
			local x = if phase0 == WASH_HIDDEN then car.startX else car.swapX
			if self:_washPlayerIn(car, x - L - 1, x + L + 1) then
				car.spawnWait += dt
				hold = true
			end
		end
	end
	if not hold then
		car.clock += dt
	end
	if self.simOnly then
		return
	end
	local x, bob, phase = self:_washState(car)
	-- a new pass: the next color (2 property sets)
	local color = (floor(car.clock / car.cycle) + car.colorBase) % #WASH_COLORS + 1
	if color ~= car.color then
		car.color = color
		local c = WASH_COLORS[color]
		if car.chassis then
			car.chassis.Color = c
		end
		if car.cabin then
			car.cabin.Color = VehicleRig.cabinColor(c)
		end
	end
	local cf = car.frame * CFrame.new(0, car.rideY + bob, -x)
	local at = cf.Position
	local lod = self:_pedLod(at.X, at.Y, at.Z, car.low, nil, car.owed)
	if phase == WASH_HIDDEN or lod == LOD_HIDE then
		if not car.hidden and self:_tryPark(car.parts, car.n) then
			car.hidden, car.owed = true, false
		end
		return
	end
	if lod == LOD_SKIP and not car.hidden then
		return
	end
	local moving = phase == WASH_IN or phase == WASH_OUT or phase == WASH_SCRUB
	if not moving and car.still and not car.hidden and not self.forceAll then
		return -- parked at the exit: posed once
	end
	if not self:_admit(car, car.n) then
		return
	end
	car.still = not moving
	car.hidden = false
	for j = 1, car.n do
		self:_emit(car.parts[j], cf * car.rest[j])
	end
end

----------------------------------------------------------------------
-- Dog Walking agility course: two chibi dogs (7 parts: the leash dog rig
-- with a collar) run a loop through both hoops (a CourseDogHop hop over
-- CourseDogHopTime through each) and round the weave poles at
-- CourseDogSpeed, tails wagging at 6 Hz. Course (zone-local, planned from
-- the real hoops / poles): up the hoop line, a left turn into the weave, a
-- semicircle round each pole on alternate sides (radius = half the pole
-- spacing, so every pole stays 1.0 from the course), a happy loop at the
-- top, down the free lane between the hoop posts and the fence, a U-turn back
-- onto the hoop line. Validated at CourseDogClearance from every visible zone
-- part (the hoops themselves only while hopping through them, checked
-- separately), 2.4 from every customer and the prompt / anchor rules. A dog
-- sits for CourseDogSit s when a player comes within CourseDogSitRadius.
----------------------------------------------------------------------

-- The render snapshot catches dog 1 hopping into this hoop (by z), this far
-- through its hop: r4_dog_inside looks past the Dog Walking queue, which
-- hides the rest of the course; hoop 1's take-off is just clear of it.
local COURSE_SNAP_HOOP = 1
local COURSE_SNAP_U = 0.3
local COURSE_DOGS = {
	{ fur = rgb(230, 180, 120), ear = rgb(176, 118, 70) },
	{ fur = rgb(250, 250, 250), ear = rgb(150, 100, 60) },
}
local COURSE_BAND = 2.2 -- dog height (head + ears)
local HOP_LEAD = 0.25 -- the hop's apex this far past the hoop plane

-- Course clearance at one point: the dog's column (feet + 0.3 .. + COURSE_BAND)
-- keeps `clearance` from every collider, except names in `ignore`.
local function dogColumnClear(list, x: number, y0: number, z: number, clearance: number, ignore): (boolean, string?)
	local y1 = y0 + COURSE_BAND
	y0 += 0.3
	for _, c in list do
		if c.yt >= y0 and c.yb <= y1 and not (ignore and ignore[c.name]) then
			local dx, dz = c.x - x, c.z - z
			local reach = c.rad + clearance
			if dx * dx + dz * dz < reach * reach then
				for k = 0, 6 do
					if colliderDistance(c, x, y0 + (y1 - y0) * k / 6, z) < clearance then
						return false, c.name
					end
				end
			end
		end
	end
	return true, nil
end

function CityLifeSim:_bindCourse(zone, zoneModel: Instance, zoneCF: CFrame, byName)
	local bars, poles = byName.HoopBar or {}, byName.WeavePole or {}
	-- hoops: bars grouped by their zone-local z (each hoop is one plane)
	local hoops = {}
	for _, bar in bars do
		local l = zoneCF:PointToObjectSpace(bar.CFrame.Position)
		local hoop = nil
		for _, h in hoops do
			if abs(h.z - l.Z) < 1 then
				hoop = h
			end
		end
		if hoop == nil then
			hoop = { x = 0, y = 0, z = l.Z, n = 0 }
			table.insert(hoops, hoop)
		end
		hoop.x += l.X
		hoop.y += l.Y
		hoop.n += 1
	end
	for _, h in hoops do
		h.x /= h.n
		h.y /= h.n
	end
	table.sort(hoops, function(a, b)
		return a.z < b.z
	end)
	local pts = {}
	for _, p in poles do
		table.insert(pts, zoneCF:PointToObjectSpace(p.CFrame.Position))
	end
	table.sort(pts, function(a, b)
		return a.Z < b.Z
	end)
	if #hoops < 1 or #pts < 2 then
		table.insert(self.zoneSkipped, "DogWalking agility dogs (no hoops / weave poles)")
		return
	end
	local hx = hoops[1].x
	local wx = pts[1].X
	local R = (pts[#pts].Z - pts[1].Z) / (#pts - 1) / 2 -- half the pole spacing
	local lawn = (byName.ParkLawn or {})[1]
	local lawnLo, lawnHi = nil, nil
	if lawn then
		lawnLo, lawnHi = localBox(zoneCF, lawn)
	end
	local function feetAt(x: number, z: number): number
		if lawnLo and x >= lawnLo.X and x <= lawnHi.X and z >= lawnLo.Z and z <= lawnHi.Z then
			return lawnHi.Y
		end
		return 0
	end

	-- the course polyline (zone-local XZ), sampled every ~0.3 studs
	local xs, zs, cum = {}, {}, {}
	local function push(x: number, z: number)
		local n = #xs
		if n > 0 then
			local d = sqrt((x - xs[n]) ^ 2 + (z - zs[n]) ^ 2)
			if d < 1e-4 then
				return
			end
			cum[n + 1] = cum[n] + d
		else
			cum[1] = 0
		end
		xs[n + 1], zs[n + 1] = x, z
	end
	local function line(x1: number, z1: number)
		local n0 = #xs
		local x0, z0 = xs[n0], zs[n0]
		local steps = max(1, math.ceil(sqrt((x1 - x0) ^ 2 + (z1 - z0) ^ 2) / 0.3))
		for k = 1, steps do
			push(x0 + (x1 - x0) * k / steps, z0 + (z1 - z0) * k / steps)
		end
	end
	local function arc(cx: number, cz: number, r: number, a0: number, a1: number)
		local steps = max(2, math.ceil(abs(a1 - a0) * DEG * r / 0.3))
		for k = 0, steps do
			local a = (a0 + (a1 - a0) * k / steps) * DEG
			push(cx + cos(a) * r, cz + sin(a) * r)
		end
	end
	local zb = hoops[1].z - 5 -- the hoop line starts 5 studs before the first hoop
	local returnX = hx - 5.3 -- the west lane, midway between the hoop posts and the fence
	local rho1 = hx - wx -- left turn from the hoop line into the weave
	local z0 = pts[1].Z - R - rho1
	push(hx, zb)
	line(hx, z0)
	arc(wx, z0, rho1, 0, 90)
	for k, p in pts do
		if k % 2 == 1 then
			arc(wx, p.Z, R, -90, -270) -- round the west side
		else
			arc(wx, p.Z, R, -90, 90) -- round the east side
		end
	end
	local zt = pts[#pts].Z + R
	local headingEast = #pts % 2 == 1 -- after an odd pole count the dog leaves the weave heading +x
	local rho2, rho3 = 1.5, wx - returnX
	if headingEast then
		arc(wx, zt + rho2, rho2, -90, 90) -- the happy loop (bulges east), now heading west
		arc(wx, zt + 2 * rho2 - rho3, rho3, 90, 180) -- down into the west lane
	else
		arc(wx, zt - rho3, rho3, 90, 180)
	end
	local rho4 = (hx - returnX) / 2
	line(returnX, zb)
	arc(returnX + rho4, zb, rho4, 180, 360) -- U-turn back onto the hoop line
	local n = #xs
	if n > 2 and (xs[1] - xs[n]) ^ 2 + (zs[1] - zs[n]) ^ 2 < 0.05 ^ 2 then
		-- the U-turn closes the loop on the first point: drop the duplicate
		xs[n], zs[n], cum[n] = nil, nil, nil
		n -= 1
	end
	local length = cum[n] + sqrt((xs[1] - xs[n]) ^ 2 + (zs[1] - zs[n]) ^ 2)
	local ys, yaws = {}, {}
	for k = 1, n do
		local k2 = k % n + 1
		ys[k] = feetAt(xs[k], zs[k])
		yaws[k] = yawToward(xs[k2] - xs[k], zs[k2] - zs[k])
	end
	-- hops: where the hoop line crosses each hoop plane. The apex sits
	-- HOP_LEAD past the plane: the dog is ~2.2 studs nose to tail, so its body
	-- clears the bottom bar on the way up and its tail on the way down.
	local hopLen = Config.CourseDogSpeed * Config.CourseDogHopTime
	local hopAt = {}
	for k, h in hoops do
		hopAt[k] = h.z - zb + HOP_LEAD -- the hoop line is the course's first stretch
	end

	-- validation
	local colliders = collectColliders(zoneModel)
	local hoopNames = { HoopBar = true, HoopPost = true }
	local station = zoneModel:FindFirstChild("HustleStation")
	local promptL, anchorL = nil, nil
	if station then
		local prompt, anchor = station:FindFirstChild("PromptPart"), station:FindFirstChild("AutoAnchor")
		promptL = prompt and zoneCF:PointToObjectSpace((prompt :: BasePart).CFrame.Position)
		anchorL = anchor and zoneCF:PointToObjectSpace((anchor :: BasePart).CFrame.Position)
	end
	local problem = nil
	for k = 1, n do
		local x, z = xs[k], zs[k]
		if abs(x) > 30 or abs(z) > 30 then
			problem = ("off the pad at (%.1f, %.1f)"):format(x, z)
			break
		end
		local hopping = false
		for _, s0 in hopAt do
			if abs(cum[k] - s0) < hopLen / 2 + 0.6 then
				hopping = true
			end
		end
		local w = zoneCF:PointToWorldSpace(Vector3.new(x, ys[k], z))
		-- a weave pole's semicircle keeps exactly R - pole radius (1.0): allow float error
		local ok, hit = dogColumnClear(colliders, w.X, w.Y, w.Z, Config.CourseDogClearance - 0.01, if hopping then hoopNames else nil)
		if not ok then
			problem = ("%s at (%.1f, %.1f)"):format(tostring(hit), x, z)
			break
		end
		if promptL and Vector3.new(x - promptL.X, 0, z - promptL.Z).Magnitude < Config.PromptKeep then
			problem = "PromptPart"
			break
		end
		if anchorL and Vector3.new(x - anchorL.X, 0, z - anchorL.Z).Magnitude < Config.AnchorKeep then
			problem = "AutoAnchor"
			break
		end
	end
	if problem == nil then
		local gap = customerDistance(self.customerGeo[zone.Id], zoneCF, function(lx, lz)
			local best = math.huge
			for k = 1, n do
				best = min(best, sqrt((lx - xs[k]) ^ 2 + (lz - zs[k]) ^ 2))
			end
			return best
		end)
		if gap < 2.4 then
			problem = ("customers %.1f studs away"):format(gap)
		end
	end
	if problem then
		table.insert(self.zoneSkipped, "DogWalking agility dogs (" .. problem .. ")")
		return
	end

	self.course = {
		xs = xs, zs = zs, ys = ys, yaws = yaws, cum = cum, n = n, length = length,
		hopAt = hopAt, hopLen = hopLen, zoneCF = zoneCF, zoneY = zoneCF.Position.Y, hoops = hoops,
	}
	local snapHoop = hopAt[min(COURSE_SNAP_HOOP, #hopAt)] + (COURSE_SNAP_U - 0.5) * hopLen
	for i, look in COURSE_DOGS do
		local dog = self:_buildDog(#self.dogs + #self.courseDogs + 1, { fur = look.fur, ear = look.ear, collar = true, parent = self.zoneLifeFolder })
		dog.model.Name = "AgilityDog" .. i
		-- dog 1 mid-hop through the snapshot hoop at the snapshot, dog 2 half a lap behind
		local s0 = (snapHoop - Config.CourseDogSpeed * SNAPSHOT_T - (i - 1) * length / 2) % length
		table.insert(self.courseDogs, {
			dog = dog, s = s0, k = 1, sitT = 0, phase = i * 2.1, low = i % LOD_SLOTS, moving = true, x = 0, z = 0,
			capSlot = (i * 6 + 5) % CAP_SLOTS, owed = false,
		})
	end
end

-- Course point at distance s: zone-local x, feet y, z, yaw (index cached).
function CityLifeSim:_coursePoint(d, s: number): (number, number, number, number)
	local c = self.course
	local cum, n = c.cum, c.n
	local k = d.k
	if s < cum[k] then
		k = 1
	end
	while k < n and cum[k + 1] <= s do
		k += 1
	end
	d.k = k
	local k2 = k % n + 1
	local seg = (if k < n then cum[k + 1] else c.length) - cum[k]
	local u = if seg > 0 then clamp((s - cum[k]) / seg, 0, 1) else 0
	local x = c.xs[k] + (c.xs[k2] - c.xs[k]) * u
	local z = c.zs[k] + (c.zs[k2] - c.zs[k]) * u
	local y = c.ys[k] + (c.ys[k2] - c.ys[k]) * u
	return x, y, z, c.yaws[k]
end

function CityLifeSim:_stepCourseDogs(dt: number)
	local c = self.course
	if c == nil then
		return
	end
	local t = self.t
	local L = c.length
	local players, count = self.playerPos, self.playerCount
	local r2 = Config.CourseDogSitRadius * Config.CourseDogSitRadius
	for i = 1, #self.courseDogs do
		local d = self.courseDogs[i]
		local hopping = false
		for _, s0 in c.hopAt do
			local u = (d.s - s0) % L
			if u < c.hopLen / 2 or u > L - c.hopLen / 2 then
				hopping = true
			end
		end
		-- a player close by: the dog sits (never mid-hop) for CourseDogSit s
		if not hopping then
			for p = 1, count do
				local pos = players[p]
				local dx, dz = pos.X - d.x, pos.Z - d.z
				if dx * dx + dz * dz < r2 and abs(pos.Y - c.zoneY - 2.5) < 5 then
					d.sitT = Config.CourseDogSit
				end
			end
		end
		d.moving = false
		if d.sitT > 0 and not hopping then
			d.sitT -= dt
		else
			-- keep 3 studs behind the other dog
			local clear = true
			for j = 1, #self.courseDogs do
				local o = self.courseDogs[j]
				if o ~= d and (o.s - d.s) % L < 3 then
					clear = false
				end
			end
			if clear or hopping then
				d.s = (d.s + Config.CourseDogSpeed * dt) % L
				d.moving = true
			end
		end
		local x, y, z, yaw = self:_coursePoint(d, d.s)
		local w = c.zoneCF:PointToWorldSpace(Vector3.new(x, y, z))
		d.x, d.z = w.X, w.Z
		if self.simOnly then
			continue
		end
		local lod = self:_pedLod(w.X, w.Y, w.Z, d.low, nil, d.owed)
		local dog = d.dog
		if lod == LOD_HIDE then
			if not dog.hidden and self:_capRoom(DOG_PARTS) then
				dog.hidden = true
				self:_parkDog(dog)
			end
			continue
		elseif lod == LOD_SKIP and not dog.hidden then
			continue
		end
		if not self:_admit(d, DOG_PARTS) then
			continue
		end
		dog.hidden = false
		local hopY, pitch = 0, 0
		for _, s0 in c.hopAt do
			local u = ((d.s - s0 + c.hopLen / 2) % L) / c.hopLen
			if u >= 0 and u <= 1 then
				hopY = Config.CourseDogHop * sin(math.pi * u)
				pitch = 0.4 * sin(2 * math.pi * u) -- nose up climbing, down descending (level at both ends)
			end
		end
		local bob = if d.moving and hopY == 0 then 0.14 * abs(sin(6 * math.pi * t + d.phase)) else 0
		if not d.moving then
			pitch = 0.18 -- sitting: nose up a little
		end
		local cf = c.zoneCF * (if pitch ~= 0 then yawPitchCF(x, y + hopY + bob, z, yaw, pitch) else yawCF(x, y + hopY + bob, z, yaw))
		local wag = (if d.moving then 0.5 else 0.75) * sin(2 * math.pi * (if d.moving then 6 else 8) * t + d.phase)
		self:_emitDog(dog, cf, wag)
		self:_emit(dog.collar, cf * DOG_COLLAR_OFF)
	end
end

----------------------------------------------------------------------
-- Window washers: a cradle on two mid-ring plaza fronts (pure CityLayout
-- data, no map binding): a 10 x 1 x 2.4 orange platform 1.5 studs in front of
-- the face (clear of the 0.8-deep mullions / 0.6 window bands), a worker in a
-- yellow hard hat scrubbing the windows, two 0.2 cables from just above the
-- cornice (resized at most every WasherCableEvery s). The cradle rides from
-- under the cornice down to WasherBottom and back every WasherPeriod s, on
-- the side of the front away from the blade sign (x = +-(W/2 - 4)) and above
-- the awning (top 9.2): MidBuilding0 (7.5 deg, behind the Lemonade Stand:
-- its right half shows in the spawn view) and MidBuilding13 (202.5 deg).
----------------------------------------------------------------------

local WASHERS = {
	{ building = "MidBuilding0", x = -12, snap = 0.5 }, -- `snap`: share of the way down at the render snapshot
	{ building = "MidBuilding13", x = 6, snap = 0.2 },
}
CityLifeSim.WASHERS = WASHERS
local WASHER_ORANGE = rgb(255, 170, 40)
local HARD_HAT = rgb(255, 206, 40)
local CABLE_GREY = rgb(70, 74, 96)

function CityLifeSim:_buildWashers()
	self.washers = {}
	if self.half then
		return -- Low device tier: no window washers
	end
	local specs = {}
	for _, spec in CityLayout.skyline do
		specs[spec.name] = spec
	end
	for i, plan in WASHERS do
		local spec = specs[plan.building]
		if spec == nil or spec.hero then
			continue
		end
		local W, H, D = spec.width, spec.height, spec.depth
		local bladeX = (if spec.index % 2 == 0 then 1 else -1) * (W / 2 - 4)
		if abs(plan.x - bladeX) < 5 + 0.5 + 1 or abs(plan.x) > W / 2 - 1.5 - 5 then
			continue -- never against the blade sign or the corner pillars
		end
		local model = Instance.new("Model")
		model.Name = "WindowWasher" .. i
		local platform = newPart(model, "WasherCradle", Enum.PartType.Block, Vector3.new(10, 1, 2.4), PARK, WASHER_ORANGE)
		local cables = {
			newPart(model, "WasherCable", Enum.PartType.Block, Vector3.new(0.2, 10, 0.2), PARK, CABLE_GREY),
			newPart(model, "WasherCable", Enum.PartType.Block, Vector3.new(0.2, 10, 0.2), PARK, CABLE_GREY),
		}
		model.Parent = self.skyFolder
		local rig = self:_newCitizen({
			kid = false, balloon = false, bag = false, backpack = false, prop = "None",
			hat = true, hatColor = HARD_HAT, shirt = rgb(70, 150, 255), pants = rgb(52, 52, 72),
		})
		rig.model.Name = "WindowWasherWorker" .. i
		rig.model.Parent = model
		local top = H - 7 -- platform center at its highest: the worker's hat stays under the cornice
		local bottom = Config.WasherBottom + 0.5
		table.insert(self.washers, {
			model = model, platform = platform, cables = cables, rig = rig, cf = spec.cframe,
			x = plan.x, z = -D / 2 - 1.5 - 1.2, cableTop = H + 1.2, top = top, bottom = bottom,
			-- `snap` of the way down at the render snapshot (descending)
			phase = math.acos(1 - 2 * plan.snap) / (2 * math.pi) * Config.WasherPeriod - SNAPSHOT_T,
			cableLen = 0, cableT = -1, hidden = false, low = i % 2, y = top,
		})
	end
end

-- Platform center height (building-local) at time t.
function CityLifeSim:_washerY(w, t: number): number
	local f = 0.5 - 0.5 * cos(2 * math.pi * (t + w.phase) / Config.WasherPeriod)
	return w.top - (w.top - w.bottom) * f
end

function CityLifeSim:_stepWashers(dt: number)
	if self.simOnly or self.washers == nil then
		return
	end
	local t = self.t
	for i = 1, #self.washers do
		local w = self.washers[i]
		local y = self:_washerY(w, t)
		local base = w.cf * CFrame.new(w.x, y, w.z)
		local at = base.Position
		-- a slow ride: every 2nd frame is plenty
		local lod = self:_pedLod(at.X, at.Y, at.Z, w.low, 2, w.rig.owed)
		if lod == LOD_HIDE then
			if not w.hidden and self:_capRoom(3 + w.rig.n) then
				w.hidden = true
				self:_emit(w.platform, PARK)
				self:_emit(w.cables[1], PARK)
				self:_emit(w.cables[2], PARK)
				self:_parkRig(w.rig)
			end
			continue
		end
		if lod == LOD_SKIP and not w.hidden then
			continue
		end
		-- the worker faces the wall (+Z) and scrubs in circles with the right
		-- arm, the left hand on the cable side; admitted with the cradle + cables
		local platformTop = y + 0.5
		local scrub = 6 * t + i
		local root = w.cf * CFrame.new(w.x + 1.6, platformTop + 0.02 * abs(sin(scrub)), w.z + 0.2) * CFrame.Angles(0, math.pi, 0)
		local head = 0.2 * sin(0.7 * t + i)
		if not self:_poseCitizen(w.rig, root, 0.4, -0.25, 1.75 + 0.3 * sin(scrub), 0.35 * cos(scrub), 0, 0, head, 3) then
			continue
		end
		w.hidden = false
		w.y = y
		self:_emit(w.platform, base)
		-- cables: from just above the cornice down to the platform top
		if t - w.cableT >= Config.WasherCableEvery or self.forceAll then
			w.cableT = t
			local len = w.cableTop - platformTop
			if abs(len - w.cableLen) > 0.01 then
				w.cableLen = len
				w.cables[1].Size = Vector3.new(0.2, len, 0.2)
				w.cables[2].Size = Vector3.new(0.2, len, 0.2)
			end
		end
		local cy = w.cableTop - w.cableLen / 2
		self:_emit(w.cables[1], w.cf * CFrame.new(w.x - 4.6, cy, w.z + 0.95))
		self:_emit(w.cables[2], w.cf * CFrame.new(w.x + 4.6, cy, w.z + 0.95))
	end
end

----------------------------------------------------------------------
-- Plaza pigeons
----------------------------------------------------------------------

local PIGEON_BODY = rgb(176, 176, 196)
local PIGEON_HEAD = rgb(120, 128, 170)
local PIGEON_WING = rgb(140, 140, 168)
local PIGEON_BEAK = rgb(255, 170, 60)
-- loose flock: 2 in the middle, 4 around (studs from the flock center)
local PIGEON_OFFSETS = { { 0.8, 10 }, { 0.8, 190 }, { 2.0, 45 }, { 2.1, 140 }, { 1.9, 230 }, { 2.0, 320 } }
local FLOCK_SPREAD = 2.6 -- max offset + body radius
local PIGEON_START = { { 30, 32 }, { 22, 80 }, { 42, 178 }, { 26, 292 } } -- preferred (r, deg)

function CityLifeSim:_pigeonSpotOk(x: number, z: number): boolean
	for _, s in self.staticSpots do
		local dx, dz = x - s.x, z - s.z
		if dx * dx + dz * dz < 64 then -- 8 studs from any idler
			return false
		end
	end
	return true
end

function CityLifeSim:_buildPigeons()
	-- candidate landing spots (free with the flock's spread + 1 clearance)
	for r = 18, 46, 2 do
		for deg = 0, 357, 6 do
			local p = CityLayout.ringPos(r, deg + (r % 4) * 1.5, 0)
			if self:_spotFree(p, FLOCK_SPREAD + 1) and self:_pigeonSpotOk(p.X, p.Z) then
				table.insert(self.pigeonSpots, { x = p.X, z = p.Z, y = plazaFeetY(p) })
			end
		end
	end
	if #self.pigeonSpots == 0 then
		return
	end
	for f, pref in PIGEON_START do
		if f > (if self.half then 1 else Config.PigeonFlocks) then
			break -- (Low device tier: 1 flock)
		end
		local want = CityLayout.ringPos(pref[1], pref[2], 0)
		local best, bestD = nil, math.huge
		for _, s in self.pigeonSpots do
			local d = (s.x - want.X) ^ 2 + (s.z - want.Z) ^ 2
			local clash = false
			for _, other in self.pigeonFlocks do
				if (s.x - other.cx) ^ 2 + (s.z - other.cz) ^ 2 < 144 then
					clash = true
				end
			end
			if not clash and d < bestD then
				best, bestD = s, d
			end
		end
		if best then
			local flock = {
				cx = best.x, cz = best.z, cy = best.y, fx = best.x, fz = best.z, fy = best.y, tx = best.x, tz = best.z, ty = best.y,
				flying = false, t0 = 0, landedAt = -10, nextSpont = 14 + 22 * hash01(f, 91), flights = 0,
				hidden = false, low = f % LOD_SLOTS, birds = {}, capSlot = f % CAP_SLOTS, owed = false,
			}
			for k, off in PIGEON_OFFSETS do
				local a = (off[2] + 14 * (hash01(f, k) - 0.5)) * DEG
				local model = Instance.new("Model")
				model.Name = "Pigeon" .. f .. "_" .. k
				local bird = {
					ox = cos(a) * off[1], oz = sin(a) * off[1],
					baseYaw = hash01(k, f + 3) * 6.28, phase = hash01(f * 7 + k, 5) * 9,
					peck = 1 + 2 * hash01(f + k * 3, 7), hopEvery = 3.5 + 3 * hash01(k + f * 5, 9),
					delay = (k - 1) * 0.05, still = false,
					-- this step's pose (see _posePigeons)
					emitNow = false, stillNext = false, px = 0, py = 0, pz = 0, yaw = 0, pitch = 0, dip = 0, wing = 0,
					body = newPart(model, "PigeonBody", Enum.PartType.Ball, Vector3.new(1, 1, 1), IDENTITY, PIGEON_BODY),
					head = newPart(model, "PigeonHead", Enum.PartType.Ball, Vector3.new(0.55, 0.55, 0.55), IDENTITY, PIGEON_HEAD),
					wingL = newPart(model, "PigeonWing", Enum.PartType.Block, Vector3.new(0.66, 0.1, 0.55), IDENTITY, PIGEON_WING),
					wingR = newPart(model, "PigeonWing", Enum.PartType.Block, Vector3.new(0.66, 0.1, 0.55), IDENTITY, PIGEON_WING),
				}
				local beak = Instance.new("WedgePart")
				beak.Name = "PigeonBeak"
				beak.Size = Vector3.new(0.2, 0.2, 0.35)
				beak.Color = PIGEON_BEAK
				beak.Material = Enum.Material.SmoothPlastic
				beak.Anchored = true
				beak.CanCollide = false
				beak.CanQuery = false
				beak.CanTouch = false
				beak.CastShadow = false
				beak.Parent = model
				bird.beak = beak
				model.Parent = self.plazaFolder
				table.insert(flock.birds, bird)
			end
			table.insert(self.pigeonFlocks, flock)
		end
	end
end

-- Picks a landing spot 10-16 studs away (away from `threat` when given),
-- clear of the other flocks; deterministic (hash-rotated scan, no allocation).
function CityLifeSim:_pigeonTarget(flock, fi: number, threatX: number?, threatZ: number?): boolean
	local spots = self.pigeonSpots
	local n = #spots
	if n == 0 then
		return false
	end
	local start = floor(hash01(fi * 13 + flock.flights, 17) * n)
	for pass = 1, 2 do
		local lo = if pass == 1 then Config.PigeonHopMin else 6
		local hi = if pass == 1 then Config.PigeonHopMax else 22
		for j = 0, n - 1 do
			local s = spots[(start + j) % n + 1]
			local dx, dz = s.x - flock.cx, s.z - flock.cz
			local d = sqrt(dx * dx + dz * dz)
			local ok = d >= lo and d <= hi
			if ok and threatX then
				local tx, tz = s.x - threatX, s.z - threatZ
				ok = tx * tx + tz * tz > 81 and (dx * (flock.cx - threatX) + dz * (flock.cz - threatZ)) > 0
			end
			if ok then
				for _, other in self.pigeonFlocks do
					if other ~= flock then
						local ax, az = s.x - other.cx, s.z - other.cz
						local bx, bz = s.x - other.tx, s.z - other.tz
						if ax * ax + az * az < 100 or bx * bx + bz * bz < 100 then
							ok = false
							break
						end
					end
				end
			end
			if ok then
				flock.fx, flock.fz, flock.fy = flock.cx, flock.cz, flock.cy
				flock.tx, flock.tz, flock.ty = s.x, s.z, s.y
				return true
			end
		end
	end
	return false
end

-- Hot-air balloons (envelope center radius / height; dir alternates by
-- index: + for 1, 3, 5 and - for 2, 4). The + balloons fly the outer orbits
-- (r 174-186) and the - ones the inner orbits (r 152-157), so balloons going
-- opposite ways always pass >= 15 studs apart radially, while same-direction
-- ones keep their angular spacing forever. Each height keeps the basket
-- (VehicleRig.BALLOON_DROP below the center, minus the bob) >= 25 studs above
-- every roof / sign / icon under its orbit, and every orbit stays >= 50
-- studs (radially) inside the blimp path (r 250).
local BALLOONS = {
	{ color = rgb(255, 212, 31), radius = 178, height = 96, snapAngle = 3 }, -- over the Lemonade Stand, seen from spawn
	{ color = rgb(88, 190, 72), radius = 152, height = 106, snapAngle = 212 }, -- behind the spawn (r2_spawn_back), beside the coin column
	{ color = rgb(64, 200, 224), radius = 186, height = 124, snapAngle = 128 },
	{ color = rgb(255, 92, 180), radius = 157, height = 114, snapAngle = 322 }, -- the plaza view
	{ color = rgb(60, 130, 255), radius = 174, height = 116, snapAngle = 248 },
}
CityLifeSim.BALLOONS = BALLOONS

function CityLifeSim:_buildSky()
	-- Blimp
	local blimp = VehicleRig.buildBlimp()
	blimp.Parent = self.skyFolder
	local parts, rest = collect(blimp)
	self.blimp = { model = blimp, parts = parts, rest = rest, n = #parts, theta0 = 330, hidden = false, slot = 0, capSlot = 0, owed = false }

	-- Bird flocks: V of five white cartoon birds each
	local FLOCKS = {
		{ radius = 62, height = 58, speed = 10, dir = 1, theta0 = 10 },
		{ radius = 80, height = 70, speed = 12, dir = -1, theta0 = 140 },
		{ radius = 94, height = 64, speed = 9, dir = 1, theta0 = 250 },
	}
	local V = { Vector3.new(0, 0, 0), Vector3.new(-3.2, 0.4, 3.2), Vector3.new(3.2, 0.4, 3.2), Vector3.new(-6.4, 0.8, 6.4), Vector3.new(6.4, 0.8, 6.4) }
	local white = rgb(248, 248, 244)
	for f, spec in FLOCKS do
		-- a flock's 5 birds move on the same steps (the V never shears)
		local flock = { spec = spec, birds = {}, slot = f, capSlot = (f * 5) % CAP_SLOTS, owed = false, hidden = false }
		for b, offset in V do
			local model = Instance.new("Model")
			model.Name = "Bird" .. f .. "_" .. b
			local body = newPart(model, "BirdBody", Enum.PartType.Block, Vector3.new(1.28, 0.8, 2.24), IDENTITY, white)
			local beak = newPart(model, "BirdBeak", Enum.PartType.Block, Vector3.new(0.35, 0.3, 0.6), IDENTITY, rgb(255, 170, 40))
			local wingL = newPart(model, "BirdWing", Enum.PartType.Block, Vector3.new(2.56, 0.24, 1.28), IDENTITY, white)
			local wingR = newPart(model, "BirdWing", Enum.PartType.Block, Vector3.new(2.56, 0.24, 1.28), IDENTITY, white)
			model.Parent = self.skyFolder
			table.insert(flock.birds, {
				body = body, beak = beak, wingL = wingL, wingR = wingR,
				offset = offset, phase = f * 3.1 + b * 0.9, hidden = false,
			})
		end
		table.insert(self.flocks, flock)
	end

	-- Chunky cartoon clouds: 5 white balls each (cloud space: long axis X,
	-- -Z faces the plaza). 10 on a ring just over the skyline from eye height
	-- (angles 36k + jitter, r 400 / 480, y 165-225) + 2 high ones (r 200, y 260).
	local CLOUD_BALLS = {
		{ 30, Vector3.new(0, 0, 0) },
		{ 22, Vector3.new(17, -3, 0) },
		{ 22, Vector3.new(-17, -3, 0) },
		{ 22, Vector3.new(-7, 8, 2) },
		{ 18, Vector3.new(8, 6, -3) },
	}
	local cloudWhite = rgb(255, 255, 255)
	for k = 0, 11 do
		if self.half and k % 2 == 1 then
			continue -- Low device tier: 6 clouds (5 on the ring + 1 high one)
		end
		local angle, radius, height
		if k < 10 then
			angle = 36 * k + 15 * hash01(k, 41)
			radius = if k % 2 == 0 then 400 else 480
			height = 165 + 60 * hash01(k, 43)
		else
			angle = 75 + 180 * (k - 10) + 20 * hash01(k, 41)
			radius = 200
			height = 260
		end
		local scale = 0.8 + 0.6 * hash01(k, 47)
		local model = Instance.new("Model")
		model.Name = "Cloud" .. (k + 1)
		local parts, rest = {}, {}
		for b, ball in CLOUD_BALLS do
			local d = ball[1] * scale
			parts[b] = newPart(model, "CloudPuff", Enum.PartType.Ball, Vector3.new(d, d, d), IDENTITY, cloudWhite)
			rest[b] = CFrame.new(ball[2] * scale)
		end
		model.Parent = self.skyFolder
		table.insert(self.clouds, {
			parts = parts, rest = rest, n = #parts, angle0 = angle, radius = radius, height = height,
			phase = hash01(k, 53) * 6.28, hidden = false, slot = k, capSlot = (k * 3 + 1) % CAP_SLOTS, owed = false,
		})
	end

	-- Hot-air balloons in the zone colors
	for k, spec in BALLOONS do
		if self.half and k ~= 1 and k ~= 4 then
			continue -- Low device tier: the spawn view's yellow and the plaza view's pink
		end
		local model = VehicleRig.buildBalloon(spec.color)
		model.Name = "Balloon" .. k
		model.Parent = self.skyFolder
		local parts, rest = collect(model)
		local dir = if k % 2 == 1 then 1 else -1
		table.insert(self.balloons, {
			parts = parts, rest = rest, n = #parts, dir = dir, radius = spec.radius, height = spec.height,
			-- placed so the render snapshot (t = SNAPSHOT_T) frames them where wanted
			angle0 = spec.snapAngle - dir * Config.BalloonOrbit * SNAPSHOT_T,
			phase = hash01(k, 61) * 6.28, hidden = false, slot = k, capSlot = (k * 7 + 2) % CAP_SLOTS, owed = false,
		})
	end
end

----------------------------------------------------------------------
-- Map binding (traffic light lamps, rooftop coins, CitySpin parts)
----------------------------------------------------------------------

local LAMP_KINDS = { SignalRed = "Red", SignalAmber = "Amber", SignalGreen = "Green" }
local DIM = rgb(40, 40, 56)

local function setLamps(list, on: boolean)
	if list == nil then
		return
	end
	for _, lamp in list do
		local part = lamp.part
		if part.Parent ~= nil then
			part.Material = if on then Enum.Material.Neon else Enum.Material.SmoothPlastic
			part.Color = if on then lamp.color else lamp.color:Lerp(DIM, 0.72)
		end
	end
end

function CityLifeSim:_applyLight(cw)
	local lamps = cw.lamps
	if lamps == nil then
		return
	end
	setLamps(lamps.Green, cw.state == GO)
	setLamps(lamps.Amber, cw.state == AMBER)
	setLamps(lamps.Red, cw.state == STOP)
end

function CityLifeSim:_setLight(cw, state: number)
	cw.state = state
	cw.timer = 0
	if state == STOP then
		cw.playerHoldT = 0 -- a fresh red phase: players may hold it PlayerHoldMax s again
	end
	self:_applyLight(cw)
end

function CityLifeSim:bindMap(map: Instance)
	if self.mapBound or map == nil then
		return
	end
	self.mapBound = true
	local city = map:FindFirstChild("City")

	-- Traffic light lamps by ZoneId
	local street = city and city:FindFirstChild("Street")
	if street then
		for _, model in street:GetChildren() do
			if model.Name == "TrafficLight" then
				local cw = self.crosswalkByZone[model:GetAttribute("ZoneId")]
				if cw then
					cw.lamps = cw.lamps or { Red = {}, Amber = {}, Green = {} }
					for _, d in model:GetDescendants() do
						local kind = LAMP_KINDS[d.Name]
						if kind and d:IsA("BasePart") then
							table.insert(cw.lamps[kind], { part = d, color = d.Color })
						end
					end
					self:_applyLight(cw)
				end
			end
		end
	end

	-- Entrance carpets in front of every gate (crossers waiting there stand on them)
	local zonesFolder = map:FindFirstChild("Zones")
	for _, cw in self.crosswalks do
		local zoneModel = zonesFolder and zonesFolder:FindFirstChild(cw.zoneId)
		local carpet = zoneModel and zoneModel:FindFirstChild("EntranceCarpet")
		if carpet and carpet:IsA("BasePart") then
			local a = cw.angle * DEG
			local u, p = Vector3.new(cos(a), 0, sin(a)), Vector3.new(-sin(a), 0, cos(a))
			local cf, h = carpet.CFrame, carpet.Size * 0.5
			local function extent(dir: Vector3): number
				return abs(cf.RightVector:Dot(dir)) * h.X + abs(cf.UpVector:Dot(dir)) * h.Y + abs(cf.LookVector:Dot(dir)) * h.Z
			end
			local center = cf.Position
			local along, side = center:Dot(u), center:Dot(p)
			local er, el = extent(u), extent(p)
			cw.carpet = { r0 = along - er, r1 = along + er, l0 = side - el, l1 = side + el, top = center.Y + extent(Vector3.yAxis) }
		end
	end

	-- Spinning gold coins floating above every skyline dome
	local skyline = city and city:FindFirstChild("Skyline")
	if skyline then
		local finials = {}
		for _, d in skyline:GetDescendants() do
			if d.Name == "DomeFinial" and d:IsA("BasePart") then
				table.insert(finials, d)
			end
		end
		table.sort(finials, function(a, b)
			local pa, pb = a.CFrame.Position, b.CFrame.Position
			return CityLayout.angleOf(pa) + pa.Y * 1e-3 < CityLayout.angleOf(pb) + pb.Y * 1e-3
		end)
		local gold = rgb(255, 196, 40)
		for i, finial in finials do
			local model = Instance.new("Model")
			model.Name = "RoofCoin" .. i
			local center = finial.CFrame.Position + Vector3.new(0, finial.Size.Y / 2 + 4.6, 0)
			local rim = newPart(model, "CoinRim", Enum.PartType.Cylinder, Vector3.new(1, 7, 7), CFrame.new(center), gold)
			rim.Reflectance = 0.15
			local face = newPart(model, "CoinFace", Enum.PartType.Cylinder, Vector3.new(1.12, 5.2, 5.2), CFrame.new(center), rgb(255, 226, 110))
			for _, side in { Enum.NormalId.Right, Enum.NormalId.Left } do
				local gui = Instance.new("SurfaceGui")
				gui.Face = side
				gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
				gui.PixelsPerStud = 24
				gui.LightInfluence = 0
				gui.Parent = face
				local label = Instance.new("TextLabel")
				label.BackgroundTransparency = 1
				label.Size = UDim2.fromScale(1, 1)
				label.Font = Enum.Font.FredokaOne
				label.Text = "$"
				label.TextColor3 = rgb(230, 140, 20)
				label.TextScaled = true
				label.Parent = gui
			end
			model.Parent = self.skyFolder
			table.insert(self.coins, { rim = rim, face = face, center = center, phase = i * 0.77, slot = i, capSlot = (i * 4) % CAP_SLOTS, owed = false })
		end
	end

	-- Zone customers (queues, sitters, browsers) from the real zone models
	self:_bindCustomers(map)

	-- City pulse: marquee chase (anchors / title / hero billboards), anchor
	-- trims, aviation blinkers, breathing blade signs, police lightbar
	self:_bindPulse(map)

	-- Zone life: hero-prop spinners, the ticker chase and heartbeat (pulse),
	-- the car-wash car and the agility dogs (validated against the customers)
	self:_bindZoneLife(map)

	-- Generic spinners: any part (or model) the world builder tags with the
	-- "CitySpin" attribute (degrees per second) turns about world Y.
	for _, d in map:GetDescendants() do
		local rate = d:GetAttribute("CitySpin")
		if type(rate) == "number" and rate ~= 0 then
			if d:IsA("BasePart") then
				local pivot = d.CFrame.Position
				local sp = { part = d, pivot = pivot, offset = CFrame.new(-pivot) * d.CFrame, rate = rate, a0 = 0 }
				table.insert(self.spinners, sp)
				self:_addSpinGroup({ sp }, pivot, rate, 0, false)
			elseif d:IsA("Model") then
				local okPivot, pivotCF = pcall(function()
					return d:GetPivot()
				end)
				local pivot = if okPivot then pivotCF.Position else Vector3.zero
				local group = {}
				for _, p in d:GetDescendants() do
					if p:IsA("BasePart") then
						local sp = { part = p, pivot = pivot, offset = CFrame.new(-pivot) * p.CFrame, rate = rate, a0 = 0 }
						table.insert(self.spinners, sp)
						table.insert(group, sp)
					end
				end
				if #group > 0 then
					self:_addSpinGroup(group, pivot, rate, 0, false)
				end
			end
		end
	end
end

-- One spinning model / part set: its parts turn together about `pivot` (one
-- LOD decision, one cap admission, so a model never shears apart).
function CityLifeSim:_addSpinGroup(list, pivot: Vector3, rate: number, a0: number, zone: boolean)
	local index = #self.spinGroups + 1
	local parts, offsets = {}, {}
	for k, sp in list do
		parts[k], offsets[k] = sp.part, sp.offset
	end
	self.spinGroups[index] = {
		parts = parts, offsets = offsets, n = #parts, pivot = pivot, rate = rate, a0 = a0, zone = zone,
		slot = index, capSlot = (index * 5 + 3) % CAP_SLOTS, owed = false,
	}
end

----------------------------------------------------------------------
-- City pulse (0 parts): the map's own neon comes alive, by property sets
-- only, with a hierarchy - running lights mean "hustle here":
--   * marquee chase only on the 8 zone anchor boards (AnchorSign), the plaza
--     title billboard (BillboardBoard / BillboardTrim) and the 2 hero-tower
--     billboards: one bar of each 4-bar frame takes its board's face color,
--     the highlight running clockwise (as seen from the front). Anchor frames
--     step every AnchorChaseStep (0.3) s with the highlighted bar at
--     Transparency 0 and the other 3 at AnchorDim (0.35); the title / hero
--     frames every ChaseStep (0.45) s. Shop-B rooftop billboards and bus ads
--     stay steady (never touched).
--   * every anchor's NeonTrim breathes (transparency 0 <-> 0.4 over 2 s),
--     phase zone Order x 0.25 s, so a wave runs round the 8 zones;
--   * rooftop aviation tips (AntennaTip, SpireTip, crane JibTipLight) flash
--     for 0.35 s every 1.8 s (transparency 0.8 in between); mid-ring
--     blade-sign neon edges breathe (0 -> 0.35 -> 0 over 3 s), a wave round
--     the ring;
--   * zone life: the Stock Desk ticker chase (one lit segment per group every
--     0.3 s, the rest at 0.5) and the Creator Studio heartbeat (heart
--     transparency 0 -> 0.3 -> 0 over 1.2 s), both bound in _bindZoneLife;
--   * the police car's lightbar halves alternate (transparency 0 / 0.7) at
--     2.5 Hz.
-- 10 Hz from step() via an accumulator, only within PulseRadius of the
-- camera, writes only on change; zone contract parts, gates, pad curbs,
-- carpets, traffic lights and sign faces are never touched. unbindMap()
-- restores every original color / transparency (and the zone spinners'
-- CFrames).
----------------------------------------------------------------------

local TIP_NAMES = { AntennaTip = true, SpireTip = true, JibTipLight = true }
local FRAME_BAR_NAMES = { NeonFrame = true, BillboardTrim = true }

-- Sign boards of a model: child parts carrying a SurfaceGui with text (the
-- boards the marquee bars frame).
local function signBoards(model: Instance): { BasePart }
	local boards = {}
	for _, child in model:GetChildren() do
		if child:IsA("BasePart") and not FRAME_BAR_NAMES[child.Name] then
			for _, gui in child:GetChildren() do
				if gui:IsA("SurfaceGui") and gui:FindFirstChildWhichIsA("TextLabel", true) then
					table.insert(boards, child)
					break
				end
			end
		end
	end
	return boards
end

-- Viewer-right sign of the board's local X for its text face (Front: the
-- viewer looks along +Z, so their right is -X).
local function boardRightSign(board: BasePart): number
	for _, gui in board:GetChildren() do
		if gui:IsA("SurfaceGui") and gui:FindFirstChildWhichIsA("TextLabel", true) then
			return if gui.Face == Enum.NormalId.Back then 1 else -1
		end
	end
	return -1
end

-- Which marquee frames chase: "anchor" | "title" | "hero" (nil: steady).
local function frameKind(board: BasePart): string?
	if board.Name == "AnchorSign" then
		return "anchor"
	elseif board.Name == "BillboardBoard" then
		return "title"
	elseif board.Name == "Billboard" then
		local model = board.Parent
		if model and string.sub(model.Name, 1, 9) == "HeroTower" then
			return "hero"
		end
	end
	return nil
end
CityLifeSim.frameKind = frameKind

function CityLifeSim:_bindPulse(map: Instance)
	local pulse = { frames = {}, tips = {}, blades = {}, trims = {}, tickers = {}, hearts = {}, heartLast = -1, policeOn = -1, acc = 0, bound = true }
	self.pulse = pulse
	local city = map:FindFirstChild("City")
	local models = {}
	for _, root in { city, map:FindFirstChild("Plaza") } do
		if root then
			if root:IsA("Model") then
				table.insert(models, root)
			end
			for _, d in root:GetDescendants() do
				if d:IsA("Model") then
					table.insert(models, d)
				end
			end
		end
	end
	local frameIndex = 0
	for _, model in models do
		local bars = {}
		for _, child in model:GetChildren() do
			if FRAME_BAR_NAMES[child.Name] and child:IsA("BasePart") then
				table.insert(bars, child)
			end
		end
		if #bars == 0 then
			continue
		end
		local boards = signBoards(model)
		local groups = {}
		for _, bar in bars do
			local best, bestD = 0, math.huge
			local p = bar.CFrame.Position
			for b, board in boards do
				local d = (board.CFrame.Position - p).Magnitude
				if d < bestD and d < board.Size.Magnitude / 2 + 3 then
					best, bestD = b, d
				end
			end
			if best > 0 then
				groups[best] = groups[best] or {}
				table.insert(groups[best], bar)
			end
		end
		for b, list in groups do
			local board = boards[b]
			local kind = frameKind(board)
			if kind == nil then
				continue -- Shop-B billboards, bus ads: steady neon
			end
			local boardCF = board.CFrame
			local right = boardRightSign(board)
			-- clockwise from the top as seen from the front
			local order = {}
			for _, bar in list do
				local l = boardCF:PointToObjectSpace(bar.CFrame.Position)
				table.insert(order, { bar = bar, a = (atan2(right * l.X, l.Y) + 2 * math.pi + 1e-4) % (2 * math.pi) })
			end
			table.sort(order, function(u, v)
				return u.a < v.a
			end)
			frameIndex += 1
			local anchor = kind == "anchor"
			local frame = { bars = {}, base = {}, baseT = {}, n = #order, hi = board.Color, cur = 0, kind = kind,
				step = if anchor then Config.AnchorChaseStep else Config.ChaseStep,
				dim = if anchor then Config.AnchorDim else nil,
				phase = floor(hash01(frameIndex, 91) * #order), pos = boardCF.Position }
			for k, o in order do
				frame.bars[k] = o.bar
				frame.base[k] = o.bar.Color
				frame.baseT[k] = o.bar.Transparency
			end
			table.insert(pulse.frames, frame)
		end
	end
	if city == nil then
		return
	end
	local orderById = {}
	for _, zone in GameConfig.Zones do
		orderById[zone.Id] = zone.Order
	end
	for _, d in city:GetDescendants() do
		if d:IsA("BasePart") then
			if TIP_NAMES[d.Name] then
				local i = #pulse.tips + 1
				pulse.tips[i] = { part = d, orig = d.Transparency, on = nil, pos = d.CFrame.Position,
					phase = hash01(i, 97) * Config.BlinkPeriod }
			elseif d.Name == "BladeSignNeon" then
				local model = d.Parent
				local k = tonumber(string.match(model and model.Name or "", "%d+")) or (#pulse.blades + 1)
				table.insert(pulse.blades, { part = d, orig = d.Transparency, last = -1, pos = d.CFrame.Position,
					phase = ((k - 1) % 24) / 24 })
			elseif d.Name == "NeonTrim" then
				-- anchor cornice neon: a breathing wave round the zones (by Order)
				local model = d.Parent
				local order = model and orderById[model:GetAttribute("ZoneId") :: any]
				if order then
					table.insert(pulse.trims, { part = d, orig = d.Transparency, last = -1, pos = d.CFrame.Position,
						phase = order * Config.TrimWave })
				end
			end
		end
	end
end

-- Breathing transparency (0 at phase 0, `depth` half a period later),
-- quantized to 0.01 so writes only happen on a visible change.
local function breath(t: number, period: number, depth: number): number
	return floor(depth * 0.5 * (1 - cos(2 * math.pi * t / period)) * 100 + 0.5) / 100
end

-- True when `pos` is beyond the pulse radius of the camera (nil: never).
local function pulseFar(pos: Vector3, cam: Vector3?): boolean
	if cam == nil then
		return false
	end
	local dp = pos - cam
	return dp:Dot(dp) > Config.PulseRadius * Config.PulseRadius
end

-- Applies the pulse state at time t (cam = nil: everything).
function CityLifeSim:_applyPulse(t: number, cam: Vector3?)
	local pulse = self.pulse
	for _, f in pulse.frames do
		if pulseFar(f.pos, cam) then
			continue
		end
		local k = (floor(t / f.step) + f.phase) % f.n + 1
		if k ~= f.cur then
			local bars = f.bars
			if f.dim then
				if f.cur == 0 then
					for b = 1, f.n do
						bars[b].Transparency = f.dim
					end
				else
					bars[f.cur].Color = f.base[f.cur]
					bars[f.cur].Transparency = f.dim
				end
				bars[k].Transparency = 0
			elseif f.cur > 0 then
				bars[f.cur].Color = f.base[f.cur]
			end
			bars[k].Color = f.hi
			f.cur = k
		end
	end
	local period, onFor, off = Config.BlinkPeriod, Config.BlinkOn, Config.BlinkOffTransparency
	for _, tip in pulse.tips do
		if pulseFar(tip.pos, cam) then
			continue
		end
		local on = (t + tip.phase) % period < onFor
		if on ~= tip.on then
			tip.on = on
			tip.part.Transparency = if on then 0 else off
		end
	end
	for _, b in pulse.blades do
		if pulseFar(b.pos, cam) then
			continue
		end
		local v = breath(t + b.phase * Config.BreathPeriod, Config.BreathPeriod, Config.BreathDepth)
		if v ~= b.last then
			b.last = v
			b.part.Transparency = v
		end
	end
	for _, tr in pulse.trims do
		if pulseFar(tr.pos, cam) then
			continue
		end
		local v = breath(t - tr.phase, Config.TrimBreathPeriod, Config.TrimBreathDepth)
		if v ~= tr.last then
			tr.last = v
			tr.part.Transparency = v
		end
	end
	-- Stock Desk ticker: one lit segment per group, the rest dim
	for _, g in pulse.tickers do
		if pulseFar(g.pos, cam) then
			continue
		end
		local k = floor(t / Config.TickerStep) % g.n + 1
		if k ~= g.cur then
			if g.cur == 0 then
				for j = 1, g.n do
					g.parts[j].Transparency = Config.TickerDim
				end
			else
				g.parts[g.cur].Color = g.base[g.cur]
				g.parts[g.cur].Transparency = Config.TickerDim
			end
			g.parts[k].Color = TICKER_LIT
			g.parts[k].Transparency = 0
			g.cur = k
		end
	end
	-- Creator Studio heartbeat
	if #pulse.hearts > 0 and not pulseFar(pulse.hearts[1].pos, cam) then
		local v = breath(t, Config.HeartBeatPeriod, Config.HeartBeatDepth)
		if v ~= pulse.heartLast then
			pulse.heartLast = v
			for _, h in pulse.hearts do
				h.part.Transparency = v
			end
		end
	end
	-- the police car's lightbar: red / blue alternate at PoliceFlashHz
	local police = self.police
	if police and police.lightRed and not police.hidden then
		local a = police.theta * DEG
		if not pulseFar(Vector3.new(cos(a) * police.radius, police.y, sin(a) * police.radius), cam) then
			local on = floor(t * 2 * Config.PoliceFlashHz) % 2
			if on ~= pulse.policeOn then
				pulse.policeOn = on
				police.lightRed.Transparency = if on == 0 then 0 else Config.PoliceDim
				police.lightBlue.Transparency = if on == 0 then Config.PoliceDim else 0
			end
		end
	end
end

function CityLifeSim:_stepPulse(dt: number)
	local pulse = self.pulse
	if pulse == nil or not pulse.bound or self.simOnly then
		return
	end
	local period = 1 / Config.PulseHz
	pulse.acc += dt
	if pulse.acc < period and not self.forceAll then
		return
	end
	pulse.acc %= period
	self:_applyPulse(self.t, if self.forceAll then nil else self.camera)
end

-- Restores everything the pulse and the zone life changed on the map (the
-- controller calls this when the city life stops).
function CityLifeSim:unbindMap()
	local pulse = self.pulse
	if pulse == nil or not pulse.bound then
		return
	end
	pulse.bound = false
	for _, f in pulse.frames do
		for k = 1, f.n do
			local bar = f.bars[k]
			if bar.Parent ~= nil then
				bar.Color = f.base[k]
				bar.Transparency = f.baseT[k]
			end
		end
		f.cur = 0
	end
	for _, list in { pulse.tips, pulse.blades, pulse.trims, pulse.hearts } do
		for _, item in list do
			if item.part.Parent ~= nil then
				item.part.Transparency = item.orig
			end
			item.on, item.last = nil, -1
		end
	end
	pulse.heartLast = -1
	for _, g in pulse.tickers do
		for j = 1, g.n do
			local part = g.parts[j]
			if part.Parent ~= nil then
				part.Color = g.base[j]
				part.Transparency = g.baseT[j]
			end
		end
		g.cur = 0
	end
	-- zone spinners back to their built pose
	for _, sp in self.spinners do
		if sp.zone and sp.part.Parent ~= nil then
			sp.part.CFrame = sp.orig
		end
	end
end

----------------------------------------------------------------------
-- Output helpers (no allocation: arrays are reused, tail cleared per step)
----------------------------------------------------------------------

function CityLifeSim:_emit(part: BasePart, cf: CFrame)
	local n = self.outCount + 1
	self.outCount = n
	self.outParts[n] = part
	self.outCFrames[n] = cf
end

function CityLifeSim:_park(parts, n: number)
	for i = 1, n do
		self:_emit(parts[i], PARK)
	end
end

-- True when `n` more parts still fit under the part cap this step.
function CityLifeSim:_capRoom(n: number): boolean
	return not self.capOn or self.outCount + n <= self.partCap
end

-- Parks `n` parts unless that would break the part cap this step (false: the
-- caller leaves its hidden flag off and simply tries again next step).
function CityLifeSim:_tryPark(parts, n: number): boolean
	if not self:_capRoom(n) then
		return false
	end
	self:_park(parts, n)
	return true
end

-- Parks a citizen rig out of sight (its next pose emits every part).
function CityLifeSim:_parkRig(rig): boolean
	if not self:_tryPark(rig.parts, rig.n) then
		return false
	end
	rig.hidden, rig.posed, rig.owed = true, false, false
	return true
end

----------------------------------------------------------------------
-- Runtime tier, governor and part cap
----------------------------------------------------------------------

-- The per-step knobs of a tier (TIERS); the crowd stays as built.
function CityLifeSim:setRuntimeTier(name: string)
	local valid = TIERS[name] ~= nil
	local spec = if valid then TIERS[name] else TIERS.High
	self.runtimeTier = if valid then name else "High"
	self.lodFull, self.lodMid = spec.full, spec.mid
	self.lodFull2, self.lodMid2 = spec.full * spec.full, spec.mid * spec.mid
	self.lodVehicle2 = spec.vehicle * spec.vehicle
	self.lodSky2 = spec.sky * spec.sky
	self.midEvery = spec.midEvery
	self.partCap = spec.cap
	self.stepEvery = spec.stepEvery
end

-- One notch down (+1) / back up (-1): never above the device tier, never below Low.
function CityLifeSim:_shiftRuntimeTier(delta: number): boolean
	local g = self.gov
	local index = clamp(TIERS[self.runtimeTier].index + delta, TIERS[self.tier].index, #TIER_ORDER)
	local name = TIER_ORDER[index]
	if name == self.runtimeTier then
		return false
	end
	if delta > 0 and g.t - g.lastRecover < 30 then
		-- slow again soon after recovering: wait longer before the next try
		g.recoverAfter = min(g.recoverAfter * 2, Config.GovernorFastMax)
	elseif delta < 0 then
		g.lastRecover = g.t
	end
	g.changes += 1
	self:setRuntimeTier(name)
	return true
end

-- The shell's per-Heartbeat entry: the governor (an EMA of the Heartbeat dt:
-- above GovernorSlowDt for GovernorSlowFor s -> one runtime tier down; under
-- GovernorFastDt for GovernorFastFor s -> one back up), then one sim step every
-- Heartbeat (stepEvery 1) or at most 30 times a second (stepEvery 2, time-based)
-- over the accumulated dt. Returns the number of parts
-- to move: 0 on a Heartbeat without a step (move nothing then).
function CityLifeSim:heartbeat(dt: number, cameraPos: Vector3?, cameraLook: Vector3?): number
	local g = self.gov
	local d = clamp(dt, 0, Config.GovernorMaxDt)
	g.t += d
	if g.t > Config.GovernorWarmup then
		g.ema += (d - g.ema) * (1 - exp(-d / Config.GovernorTau))
		if g.ema > Config.GovernorSlowDt then
			g.slowT += d
			g.fastT = 0
			if g.slowT >= Config.GovernorSlowFor then
				g.slowT = 0
				self:_shiftRuntimeTier(1)
			end
		elseif g.ema < Config.GovernorFastDt then
			g.fastT += d
			g.slowT = 0
			if g.fastT >= g.recoverAfter then
				g.fastT = 0
				self:_shiftRuntimeTier(-1)
			end
		else
			g.slowT, g.fastT = 0, 0
		end
	end
	-- Time-based cadence (not a Heartbeat count): stepEvery > 1 caps the sim
	-- at 30 Hz. The remainder carries over, so 45 FPS still steps ~30 times
	-- a second; at 30 FPS or below every Heartbeat steps with all the time
	-- accumulated since the last step (never slower than the frame rate).
	g.acc += dt
	local interval = if self.stepEvery > 1 then 1 / 30 else 0
	if g.acc < interval - 1e-3 then
		return 0
	end
	local stepDt = if interval > 0 and g.acc < 2 * interval then interval else g.acc
	g.acc = math.max(0, g.acc - stepDt)
	return self:step(stepDt, cameraPos, false, cameraLook)
end

-- Start of a posing step: each priority class's window width from what the
-- classes asked for last step (class 1 near, 2 mid, 3 low / behind / far
-- sky, in that order, after the parts the hard cap deferred last step: those
-- are owed and go first).
function CityLifeSim:_capBegin()
	self.capOn = not self.forceAll and not self.simOnly and self.partCap > 0
	if not self.capOn then
		return
	end
	local demand, share, prev = self.capDemand, self.capShare, self.capPrev
	local budget = self.partCap - self.capDenied
	self.capReserve = self.capDenied
	self.capDenied = 0
	for c = 1, 3 do
		local want = demand[c]
		if want <= budget then
			share[c] = CAP_SLOTS
			budget -= want
		else
			share[c] = max(1, floor(CAP_SLOTS * max(budget, 0) / want))
			budget = 0
		end
		prev[c] = want
		demand[c] = 0
	end
end

-- Part-cap admission of a poser (`obj`: rig / vehicle / sky object with
-- capSlot and owed) about to emit `k` parts, at the priority (self.lodPrio)
-- of its LOD test just before. A class over its share passes share / 13 of
-- its requests (evenly, per poser: everyone's turn comes round); the hard cap
-- defers anything past partCap minus the room kept for last step's deferred
-- posers and for the higher classes still to come - a deferred poser is
-- `owed`: it skips its LOD cadence and is admitted first next time. Never
-- allocates.
function CityLifeSim:_admit(obj, k: number): boolean
	if not self.capOn or k <= 0 then
		return true
	end
	if obj.owed then
		if self.outCount + k > self.partCap then
			self.capDenied += k
			return false
		end
		obj.owed = false
		self.capReserve = max(0, self.capReserve - k)
		return true
	end
	local c = self.lodPrio
	local demand = self.capDemand
	demand[c] += k
	local share = self.capShare[c]
	if share < CAP_SLOTS then
		-- this class gets share / CAP_SLOTS of its requests through: each poser
		-- adds `share` to its own accumulator (capSlot) per request and passes
		-- when it reaches CAP_SLOTS - an even cadence, and a turn within 13
		-- requests even at the minimum share of 1
		local acc = obj.capSlot + share
		if acc < CAP_SLOTS then
			obj.capSlot = acc
			return false
		end
		obj.capSlot = acc - CAP_SLOTS
	end
	-- room left after the owed reserve and what the higher classes asked for
	-- last step but have not asked for yet this step (posers come in a fixed
	-- order, so a far vehicle never takes a near walker's place)
	local need = self.capReserve
	if c > 1 then
		local prev = self.capPrev
		for h = 1, c - 1 do
			local left = prev[h] - demand[h]
			if left > 0 then
				need += left
			end
		end
	end
	if self.outCount + k + need > self.partCap then
		obj.owed = true
		self.capDenied += k
		return false
	end
	return true
end

-- True when (dx, dy, dz) from the camera (d2 = its squared length) is more
-- than BehindRadius away and behind it: dot(look, toAgentUnit) < BehindDot.
function CityLifeSim:_isBehind(dx: number, dy: number, dz: number, d2: number): boolean
	local look = self.cameraLook
	if look == nil or d2 <= Config.BehindRadius * Config.BehindRadius then
		return false
	end
	local dot = dx * look.X + dy * look.Y + dz * look.Z
	return dot < 0 and dot * dot > BEHIND_DOT2 * d2
end

-- Distance + facing LOD of a ground agent at (x, y, z) for the runtime tier:
-- LOD_HIDE beyond HideRadius; LOD_LOW (rest pose, every PedLowEvery-th step)
-- beyond the tier's mid radius or behind the camera; animated every
-- midEvery-th step to the mid radius and every step within the full radius
-- (LOD_FULL). `slot` staggers the steps, `minEvery` (slow idlers, standing
-- customers: 2) caps the rate and `owed` (a pose the part cap deferred) skips
-- the cadence (LOD_SKIP: not this step). Sets self.lodPrio for _admit.
function CityLifeSim:_pedLod(x: number, y: number, z: number, slot: number, minEvery: number?, owed: boolean?): number
	if self.forceAll then
		self.lodPrio = 1
		return LOD_FULL
	end
	local every, lod, prio = 1, LOD_FULL, 1
	local c = self.camera
	if c then
		local dx, dy, dz = x - c.X, y - c.Y, z - c.Z
		local d2 = dx * dx + dy * dy + dz * dz
		if d2 > Config.HideRadius * Config.HideRadius then
			return LOD_HIDE
		end
		if d2 > self.lodMid2 or self:_isBehind(dx, dy, dz, d2) then
			every, lod, prio = Config.PedLowEvery, LOD_LOW, 3
		elseif d2 > self.lodFull2 then
			every, prio = self.midEvery, 2
		end
	end
	self.lodPrio = prio
	if minEvery and minEvery > every then
		every = minEvery
	end
	if every > 1 and not owed and (self.frame + slot) % every ~= 0 then
		return LOD_SKIP
	end
	return lod
end

-- The same rules for sky objects and spinners, against the tier's `sky`
-- radius (every step within it in front, every midEvery-th step beyond, every
-- 4th behind the camera); LOD_HIDE beyond `hide` studs. Sets self.lodPrio.
function CityLifeSim:_skyLod(x: number, y: number, z: number, slot: number, minEvery: number?, owed: boolean?, hide: number): number
	if self.forceAll then
		self.lodPrio = 1
		return LOD_FULL
	end
	local every, prio = 1, 1
	local c = self.camera
	if c then
		local dx, dy, dz = x - c.X, y - c.Y, z - c.Z
		local d2 = dx * dx + dy * dy + dz * dz
		if d2 > hide * hide then
			return LOD_HIDE
		end
		if self:_isBehind(dx, dy, dz, d2) then
			every, prio = Config.PedLowEvery, 3
		elseif d2 > self.lodSky2 then
			every, prio = self.midEvery, 3
		elseif d2 > self.lodFull2 then
			prio = 2
		end
	end
	self.lodPrio = prio
	if minEvery and minEvery > every then
		every = minEvery
	end
	if every > 1 and not owed and (self.frame + slot) % every ~= 0 then
		return LOD_SKIP
	end
	return LOD_FULL
end

-- Emits the parts of one pose group (a still idler's changed limb).
local function emitGroup(self, rig, gi: number, bagI: number)
	local list, gcf = rig.gidx[gi], rig.gcf[gi]
	local parts, rest = rig.parts, rig.rest
	local outP, outC = self.outParts, self.outCFrames
	local n = self.outCount
	for j = 1, #list do
		local i = list[j]
		n += 1
		outP[n] = parts[i]
		outC[n] = if i == bagI then PARK else gcf * rest[i]
	end
	self.outCount = n
end

-- Poses a citizen: root CFrame (feet) + limb angles (radians, about the
-- shoulders / hips / head center). When the root has not moved since its
-- last pose (a still idler) only the groups whose angles changed are emitted
-- (a head turn: the head group only). A shopper's bag (rig.bagPark) goes out
-- parked. `extra`: parts the caller emits right after (a dog, the boombox, a
-- cradle), admitted together. Returns false when the part cap deferred it
-- (nothing emitted; the caller skips its extras too).
function CityLifeSim:_poseCitizen(rig, rootCF: CFrame, la: number, laRoll: number, ra: number, raRoll: number, ll: number, rl: number, headYaw: number, extra: number?): boolean
	local full = not rig.posed or self.forceAll or self.noDelta == true or rootCF ~= rig.lastRoot
	local bagPark = rig.bagPark
	local chHead, chL, chR, chLL, chRL = true, true, true, true, true
	local k = rig.n
	if not full then
		local gn = rig.gn
		chHead = headYaw ~= rig.lHead
		chL = la ~= rig.lLa or laRoll ~= rig.lLaRoll
		chR = ra ~= rig.lRa or raRoll ~= rig.lRaRoll or bagPark ~= rig.lBagPark
		chLL = ll ~= rig.lLl
		chRL = rl ~= rig.lRl
		k = (if chHead then gn[G_HEAD] else 0) + (if chL then gn[G_LARM] else 0) + (if chR then gn[G_RARM] else 0)
			+ (if chLL then gn[G_LLEG] else 0) + (if chRL then gn[G_RLEG] else 0)
	end
	local total = k + (extra or 0)
	if total == 0 then
		return true -- nothing moved since the last pose
	end
	if not self:_admit(rig, total) then
		return false
	end
	local g, px, py = rig.gcf, rig.px, rig.py
	if full then
		g[G_ROOT] = rootCF
	end
	if chHead then
		-- the head pivot lies on the rig's Y axis: a head turn is a plain yaw
		g[G_HEAD] = if headYaw ~= 0 then rootCF * yawCF(0, 0, 0, headYaw) else rootCF
	end
	if chL then
		g[G_LARM] = if la ~= 0 or laRoll ~= 0 then rootCF * limbCF(px[G_LARM], py[G_LARM], la, laRoll) else rootCF
	end
	if chR then
		g[G_RARM] = if ra ~= 0 or raRoll ~= 0 then rootCF * limbCF(px[G_RARM], py[G_RARM], ra, raRoll) else rootCF
	end
	if chLL then
		g[G_LLEG] = if ll ~= 0 then rootCF * limbCF(px[G_LLEG], py[G_LLEG], ll, 0) else rootCF
	end
	if chRL then
		g[G_RLEG] = if rl ~= 0 then rootCF * limbCF(px[G_RLEG], py[G_RLEG], rl, 0) else rootCF
	end
	local bagI = if bagPark and rig.bagIndex then rig.bagIndex else 0
	if full then
		local parts, rest, group = rig.parts, rig.rest, rig.group
		local outP, outC = self.outParts, self.outCFrames
		local n = self.outCount
		for i = 1, rig.n do
			n += 1
			outP[n] = parts[i]
			outC[n] = if i == bagI then PARK else g[group[i]] * rest[i]
		end
		self.outCount = n
	else
		if chHead then
			emitGroup(self, rig, G_HEAD, bagI)
		end
		if chL then
			emitGroup(self, rig, G_LARM, bagI)
		end
		if chR then
			emitGroup(self, rig, G_RARM, bagI)
		end
		if chLL then
			emitGroup(self, rig, G_LLEG, bagI)
		end
		if chRL then
			emitGroup(self, rig, G_RLEG, bagI)
		end
	end
	rig.posed, rig.hidden = true, false
	rig.lastRoot = rootCF
	rig.lHead, rig.lLa, rig.lLaRoll, rig.lRa, rig.lRaRoll, rig.lLl, rig.lRl = headYaw, la, laRoll, ra, raRoll, ll, rl
	rig.lBagPark = bagPark
	return true
end

-- LOD bookkeeping for a citizen: parks it beyond HideRadius; returns whether
-- it should be posed this step and whether its limbs animate (`minEvery`: see
-- _pedLod).
function CityLifeSim:_citizenVisible(rig, x: number, y: number, z: number, lowSlot: number, minEvery: number?): (boolean, boolean)
	local lod = self:_pedLod(x, y, z, lowSlot, minEvery, rig.owed)
	if lod == LOD_HIDE then
		if not rig.hidden then
			self:_parkRig(rig)
		end
		return false, false
	elseif lod == LOD_SKIP then
		return false, false
	end
	return true, lod == LOD_FULL
end

----------------------------------------------------------------------
-- Step: lights -> vehicles -> crossers -> walkers -> idlers -> sky
----------------------------------------------------------------------

-- True when no vehicle conflicts with the zebra band: a vehicle conflicts
-- from the moment its nose passes the stop line until its tail has left the
-- band (a car waiting AT the line does not).
function CityLifeSim:_bandClear(cw): boolean
	local vehicles = self.vehicles
	for i = 1, #vehicles do
		local v = vehicles[i]
		if v.lights then -- Back Avenue traffic never meets a zebra
			local degPerStud = 1 / (v.radius * DEG)
			local s = v.dir * wrapDeg(v.theta - cw.angle) -- negative while approaching
			local front = s + v.halfLen * degPerStud
			local rear = s - v.halfLen * degPerStud
			if front > -(v.stopHalf - 0.25 * degPerStud) and rear < v.bandHalf + 1.5 * degPerStud then
				return false
			end
		end
	end
	return true
end

local ROAD_CLEAR = 0.8 -- a crosser's half depth + margin past the asphalt edge
local VEHICLE_HOP_TIME, VEHICLE_HOP = 0.35, 0.35 -- s / studs: the hop before creeping through a player

function CityLifeSim:_stepLights(dt: number)
	local cws = self.crosswalks
	for i = 1, #cws do
		local cw = cws[i]
		cw.requests = 0
		cw.occupants = 0
		cw.players = 0
	end
	-- a crosser holds its light red from the moment it commits until its body
	-- has left the asphalt (the rest of the walk is on the sidewalk)
	local crossers = self.crossers
	local inClear, outClear = S.AsphaltInner - ROAD_CLEAR, S.AsphaltOuter + ROAD_CLEAR
	for i = 1, #crossers do
		local c = crossers[i]
		if c.pending or (c.crossing and (if c.atOuter then c.along > inClear else c.along < outClear)) then
			c.cw.occupants += 1
		elseif c.ready and not c.crossing then
			c.cw.requests += 1
		end
	end
	-- Players on a zebra band hold that light at red too (friendly city) - but
	-- only PlayerHoldMax s per red phase: an idle player never stops the ring
	-- (the cars then yield to a player on their lane and creep through, see
	-- _stepVehicles)
	for p = 1, self.playerCount do
		local onIt, cwData = CityLayout.isOnCrosswalk(self.playerPos[p])
		if onIt and cwData then
			local cw = self.crosswalkByZone[cwData.zoneId]
			if cw and cw.state == STOP then
				cw.players += 1
			end
		end
	end
	for i = 1, #cws do
		local cw = cws[i]
		cw.timer += dt
		if cw.state == GO then
			if cw.requests > 0 and cw.timer >= Config.MinGo then
				self:_setLight(cw, AMBER)
			end
		elseif cw.state == AMBER then
			if cw.timer >= Config.AmberTime then
				self:_setLight(cw, STOP)
			end
		else
			local playerHold = false
			if cw.players > 0 then
				cw.playerHoldT += dt
				playerHold = cw.playerHoldT < Config.PlayerHoldMax
			end
			if cw.occupants == 0 and not playerHold and ((cw.requests == 0 and cw.timer >= Config.MinStop) or cw.timer >= Config.MaxStop) then
				self:_setLight(cw, GO)
			end
		end
	end
end

function CityLifeSim:_stepVehicles(dt: number)
	local vehicles = self.vehicles
	local cws = self.crosswalks
	local players, playerCount = self.playerPos, self.playerCount
	local easeK = 1 - exp(-Config.VehicleEase * dt)
	local huge = math.huge
	for i = 1, #vehicles do
		local v = vehicles[i]
		local r, dir = v.radius, v.dir
		local degPerStud = 1 / (r * DEG)
		v.sched = (v.sched + dir * v.base * dt * degPerStud) % 360
		local lag = dir * wrapDeg(v.sched - v.theta) / degPerStud
		local cruise = v.base * clamp(1 + lag / Config.CatchUpStuds, 0.7, 1.3)
		local limit = huge
		local front = v.theta + dir * v.halfLen * degPerStud

		-- keep the gap to the vehicle ahead in this lane
		for _, o in v.laneMates do
			local ahead = ((dir * (o.theta - v.theta)) % 360) / degPerStud
			local gap = ahead - v.halfLen - o.halfLen - Config.MinGap
			if gap < limit then
				limit = gap
			end
		end
		-- crosswalk lights ahead (amber: commit through when it cannot stop);
		-- the Back Avenue has no lights
		for c = 1, (if v.lights then #cws else 0) do
			local cw = cws[c]
			if cw.state ~= GO then
				local stopAngle = cw.angle - dir * v.stopHalf
				-- signed: a nose resting ON the line (float error) still counts
				local d = wrapDeg(dir * (stopAngle - front)) / degPerStud
				if d > -0.25 and d < 45 then
					d = max(d, 0)
					if cw.state == STOP or d > v.speed * v.speed / (2 * Config.BrakeHard) + 0.5 then
						if d < limit then
							limit = d
						end
					end
				end
			end
		end
		-- a player standing ON this lane's asphalt ahead (or beside the car;
		-- never one on the sidewalk next to the curb): wait at most
		-- PlayerYieldMax s, then creep through them (life parts never collide)
		local playerAhead = false
		local roadIn = if v.lights then S.AsphaltInner else (S.BackAsphaltInner or 0)
		local roadOut = if v.lights then S.AsphaltOuter else (S.BackAsphaltOuter or huge)
		for p = 1, playerCount do
			local pos = players[p]
			if pos.Y < 25 then
				local pr = sqrt(pos.X * pos.X + pos.Z * pos.Z)
				if pr >= roadIn and pr <= roadOut and abs(pr - r) < v.halfWidth + Config.PlayerLaneMargin then
					local pa = atan2(pos.Z, pos.X) / DEG
					local ahead = wrapDeg(dir * (pa - front)) / degPerStud
					if ahead > -(2 * v.halfLen + 1) and ahead < Config.PlayerLookAhead then
						playerAhead = true
						if not v.through then
							local d = ahead - Config.PlayerStopGap
							if d < limit then
								limit = d
							end
						end
					end
				end
			end
		end
		if v.hopT > 0 then
			v.hopT = max(0, v.hopT - dt)
		end
		if not playerAhead then
			v.yieldT, v.through = 0, false
		elseif not v.through and v.speed < 0.5 then
			v.yieldT += dt
			if v.yieldT >= Config.PlayerYieldMax then
				v.through = true
				v.hopT = VEHICLE_HOP_TIME -- a little "honk" hop, then on through
			end
		end
		-- bus stops
		if v.isBus then
			if v.dwell > 0 then
				v.dwell = max(0, v.dwell - dt)
				limit = min(limit, 0)
			else
				for s, stop in self.busStops do
					if s ~= v.lastStop then
						local d = ((dir * (stop.angle - v.theta)) % 360) / degPerStud
						if d < 60 then
							limit = min(limit, d)
							if d < 0.5 and v.speed < 0.6 then
								v.dwell = Config.BusDwell
								v.lastStop = s
							end
						end
					end
				end
			end
		end

		local target = cruise
		if limit < huge then
			local brake = sqrt(2 * Config.BrakeProfile * max(0, limit))
			if brake < target then
				target = brake
			end
		end
		if v.through and playerAhead and target > Config.PlayerCreepSpeed then
			target = Config.PlayerCreepSpeed -- slowly through the player
		end
		local speed = v.speed + (target - v.speed) * easeK
		local travel = speed * dt
		if travel > limit then
			travel = max(0, limit)
			speed = travel / dt
		end
		v.accel = (speed - v.speed) / dt
		v.speed = speed
		v.theta = (v.theta + dir * travel * degPerStud) % 360
	end
end

function CityLifeSim:_poseVehicles(dt: number)
	local vehicles = self.vehicles
	local cam = self.camera
	local t = self.t
	local hide2 = Config.HideRadius * Config.HideRadius
	for i = 1, #vehicles do
		local v = vehicles[i]
		local a = v.theta * DEG
		local x, z = cos(a) * v.radius, sin(a) * v.radius
		-- LOD: suspension bob + brake pitch every step within the tier's vehicle
		-- radius (in front), every midEvery-th step beyond, every 4th behind the
		-- camera; parked beyond HideRadius
		local detail, every = true, 1
		self.lodPrio = 1
		if cam and not self.forceAll then
			local dx, dy, dz = x - cam.X, v.y - cam.Y, z - cam.Z
			local d2 = dx * dx + dy * dy + dz * dz
			if d2 > hide2 then
				if not v.hidden and self:_tryPark(v.parts, v.n) then
					v.hidden, v.owed = true, false
				end
				continue
			end
			if self:_isBehind(dx, dy, dz, d2) then
				detail, every, self.lodPrio = false, Config.PedLowEvery, 3
			elseif d2 > self.lodVehicle2 then
				detail, every, self.lodPrio = false, self.midEvery, 3
			elseif d2 > self.lodFull2 then
				self.lodPrio = 2
			end
		end
		local wasHidden = v.hidden
		local settled = v.speed < 1e-3 and abs(v.pitch) < 0.002 and v.hopT <= 0
		if not self.forceAll and not wasHidden and not v.owed then
			if settled then
				-- stopped and settled (red light, queue, bus stop): hold the pose, emit once
				if v.still then
					continue
				end
			elseif every > 1 and (self.frame + v.slot) % every ~= 0 then
				continue
			end
		end
		if not self:_admit(v, v.n) then
			continue
		end
		v.hidden = false
		if settled then
			v.pitch = 0
			v.still = true
		else
			v.still = false
		end
		local base = yawCF(x, v.y, z, tangentYaw(a, v.dir))
		local parts, rest, wheel = v.parts, v.rest, v.wheel
		if detail then
			v.pitch += (clamp(v.accel * 0.004, -v.maxPitch, v.maxPitch) - v.pitch) * min(1, dt * 6)
			local bob = 0.07 * sin(12 * t + v.phase) * min(1, v.speed / 6)
			if v.hopT > 0 then
				bob += VEHICLE_HOP * sin(math.pi * (1 - v.hopT / VEHICLE_HOP_TIME))
			end
			-- base * up(2) * bob * pitch * down(2) as one matrix
			local ca, sa = cos(v.pitch), sin(v.pitch)
			local body = base * CFrame.new(0, 2 + bob - 2 * ca, -2 * sa, 1, 0, 0, 0, ca, -sa, 0, sa, ca)
			for j = 1, v.n do
				self:_emit(parts[j], (if wheel[j] then base else body) * rest[j])
			end
		else
			for j = 1, v.n do
				self:_emit(parts[j], base * rest[j])
			end
		end
	end
end

-- True while a sidewalk walker is in this crosser's line just ahead of it
-- (the crosser lets it pass; at most CrossYieldMax s per encounter).
function CityLifeSim:_crosserYields(c, inward: boolean, dt: number): boolean
	local along = c.along
	local list = if along > 100 then self.outerWalkers elseif along < 70 then self.innerWalkers else nil
	if list == nil then
		c.holdT = 0
		return false
	end
	local s = if inward then -1 else 1
	local cwAngle, side, corridor = c.cw.angle, c.side, Config.CrossCorridor
	for k = 1, #list do
		local w = list[k]
		if w.onLane then -- (shoppers off at a shop door are nowhere near a zebra)
			local d = wrapDeg(w.theta - cwAngle)
			if d > -8 and d < 8 then
				local ahead = s * (w.r - along)
				if ahead > 0 and ahead < 3 and abs(w.r * sin(d * DEG) - side) < corridor then
					c.holdT += dt
					return c.holdT < Config.CrossYieldMax
				end
			end
			if w.dog then
				-- ...nor through a walker's dog (body radius ~0.75)
				local dd = wrapDeg(w.dogTheta - cwAngle)
				if dd > -8 and dd < 8 then
					local ahead = s * (w.dogR - along)
					if ahead > 0 and ahead < 2.4 and abs(w.dogR * sin(dd * DEG) - side) < 2.2 then
						c.holdT += dt
						return c.holdT < Config.CrossYieldMax
					end
				end
			end
		end
	end
	c.holdT = 0
	return false
end

-- True while a crosser on the zebra ahead is about to walk through this
-- walker's path (it waits at the edge of that crosser's line; at most
-- WalkerYieldMax s, so nobody is ever stuck).
function CityLifeSim:_walkerYields(w, rr: number, dt: number): boolean
	local lane = w.lane
	if lane.radius > 125 then
		return false -- the Back Avenue has no zebras
	end
	local cw = self.crosswalks[floor(w.theta / ZONE_STEP + 0.5) % ZONE_COUNT + 1]
	local d = if cw then wrapDeg(w.theta - cw.angle) else 180
	if d > -12 and d < 12 then
		local lat = rr * sin(d * DEG)
		-- a dog trotting `dogLead` ahead reaches the crosser's line first
		local corridor = Config.CrossCorridor + (if w.dog then max(0, w.dogLead - 0.5) + 0.2 else 0)
		local list = cw.crossers
		for k = 1, #list do
			local c = list[k]
			if c.crossing then
				local ahead = lane.dir * (c.side - lat)
				if ahead > corridor and ahead < corridor + 2 and abs(c.along - rr) < 4.5 then
					w.crossWait += dt
					return w.crossWait < Config.WalkerYieldMax
				end
			end
		end
	end
	w.crossWait = 0
	return false
end

function CityLifeSim:_stepCrossers(dt: number)
	local t = self.t
	-- 1) rush hour: on red with the zebra band clear, every ready crosser of that
	--    zebra goes - and so does everyone else there whose wait ends within
	--    CrossJoinWindow s - each stepping off after a 0..CrossJoinDelay s hash delay
	local cws = self.crosswalks
	for i = 1, #cws do
		local cw = cws[i]
		if cw.state == STOP and cw.timer > 0.3 then
			local list = cw.crossers
			local anyReady = false
			for k = 1, #list do
				if list[k].ready then
					anyReady = true
					break
				end
			end
			if anyReady and self:_bandClear(cw) then
				for k = 1, #list do
					local c = list[k]
					if not c.crossing and not c.pending and (c.ready or c.timer <= Config.CrossJoinWindow) then
						c.pending, c.ready = true, false
						c.goAt = t + Config.CrossJoinDelay * hash01(c.seed, c.waits + 31)
					end
				end
			end
		end
	end
	-- 2) every crosser
	for i = 1, #self.crossers do
		local c = self.crossers[i]
		local walking = false
		if c.pending then
			if t >= c.goAt then
				c.pending, c.crossing, c.holdT = false, true, 0
			end
		elseif not c.crossing then
			if c.timer > 0 then
				c.timer -= dt
			else
				c.ready = true
			end
		end
		if c.crossing then
			local inward = c.atOuter
			local target = if inward then c.innerR else c.outerR
			if not self:_crosserYields(c, inward, dt) then
				local stepLen = c.speed * dt
				if inward then
					c.along = max(target, c.along - stepLen)
				else
					c.along = min(target, c.along + stepLen)
				end
				c.walkClock += dt * 9 * c.speed / 6
				walking = true
			end
			if c.along == target then
				-- arrived: wait on this side with a fresh timer (the sides mix naturally)
				c.atOuter = not c.atOuter
				c.crossing = false
				c.waits += 1
				c.timer = Config.CrossWaitMin + (Config.CrossWaitMax - Config.CrossWaitMin) * hash01(c.seed, c.waits)
			end
		end
		-- facing: toward the other end (walking or waiting to walk)
		local targetYaw = radialYaw(c.angle, not c.atOuter)
		c.yaw += wrapRad(targetYaw - c.yaw) * min(1, dt * 8)
		c.amp += ((if walking then 1 else 0) - c.amp) * min(1, dt * 8)

		local x = c.ux * c.along + c.px * c.side
		local z = c.uz * c.along + c.pz * c.side
		c.x, c.z = x, z
		if self.simOnly then
			continue
		end
		-- LOD on the last feet height (the surface lookup only when posing)
		local visible, animate = self:_citizenVisible(c.rig, x, c.y, z, c.low)
		if visible then
			local y = CityLayout.surfaceY(Vector3.new(x, 0, z))
			local carpet = c.cw.carpet -- feet on the zone's entrance carpet (a thin slab on the sidewalk)
			if carpet and c.along > carpet.r0 and c.along < carpet.r1 and c.side > carpet.l0 and c.side < carpet.l1 and carpet.top > y then
				y = carpet.top
			end
			c.y = y
			local s = c.rig.scale
			local swing = if animate then sin(c.walkClock) * c.amp else 0
			local bob = if animate then 0.12 * s * abs(sin(c.walkClock)) * c.amp else 0
			local head, roll = 0, 0
			local ra, raRoll = -0.6 * swing, 0
			if animate and not c.crossing then
				-- waiting: weight shift, looking both ways; B points across the
				-- road, the others wave at the traffic now and then
				roll = 0.045 * sin(1.3 * t + c.phase)
				bob = 0.03 * s * (1 - cos(2.6 * t + c.phase))
				head = 0.8 * sin(1.2 * t + c.phase)
				if c.pointer and (t + c.phase) % 7 < 1.8 then
					ra, raRoll = 1.45 + 0.06 * sin(3 * t), -0.12
					head = 0.15 * sin(2 * t)
				elseif (c.ready or c.pending) and (t + c.phase) % 6 < 1.4 then
					ra, raRoll = 0, 2.5 + 0.4 * sin(12 * t)
				end
			end
			local root = if roll ~= 0 then yawRollCF(x, y + bob, z, c.yaw, roll) else yawCF(x, y + bob, z, c.yaw)
			self:_poseCitizen(c.rig, root, 0.6 * swing, 0, ra, raRoll, -0.5 * swing, 0.5 * swing, head)
		end
	end
end

-- The follow rule: the largest speed that keeps Config.FollowGap (+ a dog's
-- lead) to whoever walks ahead in the lane (math.huge when nobody is close).
-- Off-lane shoppers do not count; equal angles break ties by index.
function CityLifeSim:_followCap(w): number
	local mates = w.mates
	if mates == nil then
		return math.huge
	end
	local dir = w.lane.dir
	local best = 360
	for k = 1, #mates do
		local o = mates[k]
		if o.onLane then
			local d = (dir * (o.theta - w.theta)) % 360
			if d == 0 and o.index > w.index then
				d = 360
			end
			if d < best then
				best = d
			end
		end
	end
	local ahead = best * DEG * w.lane.radius
	local need = Config.FollowGap + w.dogLead
	if ahead >= need + 2 then
		return math.huge
	end
	return max(0, (ahead - need) * 2.5)
end

-- True when an on-lane walker (or its dog) of `w`'s lane is within `gap`
-- studs of the lane angle `theta` (a shopper waits before merging in).
function CityLifeSim:_laneBusy(w, theta: number, gap: number): boolean
	local mates = w.mates
	if mates == nil then
		return false
	end
	local perDeg = w.lane.radius * DEG
	for k = 1, #mates do
		local o = mates[k]
		if o.onLane then
			if abs(wrapDeg(o.theta - theta)) * perDeg < gap then
				return true
			end
			if o.dog and abs(wrapDeg(o.dogTheta - theta)) * perDeg < gap then
				return true
			end
		end
	end
	return false
end

function CityLifeSim:_stepWalkers(dt: number)
	local t = self.t
	local players, playerCount = self.playerPos, self.playerCount
	for i = 1, #self.walkers do
		local w = self.walkers[i]
		if w.shopper and w.mode ~= SHOP_WALK then
			self:_stepShopper(w, dt, t)
			continue
		end
		local lane = w.lane
		local r, dir = lane.radius, lane.dir
		local degPerStud = 1 / (r * DEG)
		if w.shopper then
			w.sched = w.theta -- shoppers keep their own pace (no schedule slot)
		else
			w.sched = (w.sched + dir * lane.speed * dt * degPerStud) % 360
		end

		-- players on the sidewalk ahead: step around them on a side with room
		-- (at both the walker's and the player's angle; the choice sticks for the
		-- encounter), else wait politely and squeeze past after 3 s.
		local laneR, minR, maxR = walkRadius(lane, w.theta)
		local avoidR: number? = nil
		local blocked = false
		local engaged = false
		do
			local myR = laneR + w.lateral
			for p = 1, playerCount do
				local pos = players[p]
				local pr = sqrt(pos.X * pos.X + pos.Z * pos.Z)
				if abs(pr - myR) < 2.2 + (if w.avoidSide ~= 0 then 2.6 else 0) and abs(pos.Y - lane.y - 2.5) < 4 then
					local pa = atan2(pos.Z, pos.X) / DEG
					local ahead = wrapDeg(dir * (pa - w.theta)) / degPerStud
					local isAhead = ahead > -1.5 and ahead < 5
					if isAhead then
						engaged = true
					end
					if isAhead and not w.ghost then
						local _, minP, maxP = walkRadius(lane, pa)
						local lo, hi = max(minR, minP), min(maxR, maxP)
						local inner, outer = pr - 2.6, pr + 2.6
						if w.avoidSide == 0 then
							local okIn, okOut = inner >= lo, outer <= hi
							if okIn and (laneR <= pr or not okOut) then
								w.avoidSide = -1
							elseif okOut then
								w.avoidSide = 1
							end
						end
						if w.avoidSide == -1 then
							avoidR = max(inner, lo)
						elseif w.avoidSide == 1 then
							avoidR = min(outer, hi)
						elseif ahead > 0 then
							blocked = true
						end
					end
				end
			end
		end
		if not engaged then
			w.avoidSide = 0
			w.ghost = false
			w.waitT = 0
		end
		if blocked then
			w.waitT += dt
			if w.waitT > 3 then
				w.ghost = true -- squeeze past (never jam a sidewalk behind an AFK player)
				blocked = false
			end
		end
		local latGoal = clamp(avoidR or laneR, minR, maxR) - laneR
		w.lateral += (latGoal - w.lateral) * min(1, dt * 4)

		local speed = 0
		if w.pause > 0 then
			w.pause = max(0, w.pause - dt)
		elseif blocked or (avoidR ~= nil and abs(w.lateral - latGoal) > 1.2) then
			-- waiting for the player / finishing the sidestep first
			speed = 0
		elseif self:_walkerYields(w, laneR + w.lateral, dt) then
			speed = 0 -- letting a zebra crosser pass
		else
			local lag = dir * wrapDeg(w.sched - w.theta) / degPerStud
			speed = lane.speed * (w.speedMul or 1) * clamp(1 + lag / 25, 0.75, 1.3) + 0.25 * sin(0.45 * t + w.phase)
			if lane.follow then
				-- never walk into the back of whoever is ahead (shoppers merge in
				-- and out, a window-shopper stops): slow down / wait behind them
				speed = clamp(self:_followCap(w), 0, speed)
				if speed < 0.15 then
					speed = 0
				end
			end
			w.theta = (w.theta + dir * speed * dt * degPerStud) % 360
			-- window-shopping stops 5 degrees before each zone axis (inner
			-- sidewalk: 9, outside the zebra crossers' lines)
			local sector = floor((w.theta + dir * (lane.pauseLead or 5)) / ZONE_STEP) % ZONE_COUNT
			if sector ~= w.sector then
				w.sector = sector
				w.pauseCount += 1
				if hash01(w.seed, w.pauseCount) < lane.pauseChance then
					w.pause = 2.5 + 2 * hash01(w.seed + 7, w.pauseCount)
					w.wave = hash01(w.seed + 3, w.pauseCount) < 0.35
				end
			end
			-- Back Avenue: window-shop 3-5 s at about 1 in 4 outer-ring doors
			if w.nextDoor > 0 then
				local stop = OUTER_DOORS[w.nextDoor]
				local past = dir * wrapDeg(w.theta - stop)
				if past >= 0 and past < 5 then
					w.doorCount += 1
					if hash01(w.seed + 11, w.doorCount) < lane.doorChance then
						w.theta = stop -- stand right in front of the door
						w.pause = 3 + 2 * hash01(w.seed + 13, w.doorCount)
						w.wave = hash01(w.seed + 17, w.doorCount) < 0.3
					end
					local n = #OUTER_DOORS
					w.nextDoor = if dir > 0 then w.nextDoor % n + 1 else (w.nextDoor - 2) % n + 1
				end
			end
		end
		w.speed = speed

		local a = w.theta * DEG
		local paused = w.pause > 0 or speed == 0
		local targetYaw = if w.pause > 0 then radialYaw(a, lane.pauseOut) else tangentYaw(a, dir)
		w.yaw += wrapRad(targetYaw - w.yaw) * min(1, dt * 8)
		w.amp += ((if paused then 0 else 1) - w.amp) * min(1, dt * 8)
		w.walkClock += dt * 9 * speed / 6

		local rr = laneR + w.lateral
		local x, z = cos(a) * rr, sin(a) * rr
		w.x, w.z, w.r = x, z, rr
		if w.dog then
			self:_placeDog(w, rr)
		end
		-- a shopper reaching its Shop A's door lane turns off the sidewalk
		if w.shopper and w.pause <= 0 then
			local front = FRONTAGES[w.gap]
			local dep = front and front.theta[lane.name]
			if dep then
				local past = dir * wrapDeg(w.theta - dep)
				if past >= 0 and past < 6 then
					w.mode, w.wp, w.onLane, w.y = SHOP_FRONT_IN, 1, false, lane.y
					w.lateral, w.avoidSide, w.ghost, w.waitT, w.holdT = 0, 0, false, 0, 0
				end
			end
		end
		if self.simOnly then
			continue
		end
		local visible, animate = self:_citizenVisible(w.rig, x, lane.y, z, w.low)
		if visible then
			local head, raRoll = 0, 0
			if animate then
				head = if paused then 0.6 * sin(1.5 * t + w.phase) else 0.15 * sin(0.7 * t + w.phase)
				if paused and w.wave then
					raRoll = 2.5 + 0.4 * sin(12 * t + w.phase)
				end
			end
			-- the dog is admitted with its walker (the leash spans the posed hand)
			if self:_poseWalker(w, x, lane.y, z, animate, head, raRoll, 0, if w.dog then DOG_PARTS else nil) and w.dog then
				self:_poseDog(w, paused, t)
			end
		elseif w.dog and w.rig.hidden and not w.dog.hidden and self:_capRoom(DOG_PARTS) then
			w.dog.hidden = true
			self:_parkDog(w.dog)
		end
	end
end

-- Poses a walking citizen (walker / shopper): waddle, bob and sway from its
-- walk clock, a head turn, a waving right arm (raRoll), a hop (hopY); a
-- shopper's bag is parked while it carries none.
function CityLifeSim:_poseWalker(w, x: number, y: number, z: number, animate: boolean, head: number, raRoll: number, hopY: number, extra: number?): boolean
	local rig = w.rig
	local s = rig.scale
	local swing = if animate then sin(w.walkClock) * w.amp else 0
	local bob = if animate then 0.12 * s * abs(sin(w.walkClock)) * w.amp else 0
	local root = if animate then yawRollCF(x, y + bob + hopY, z, w.yaw, 0.06 * swing) else yawCF(x, y + bob + hopY, z, w.yaw)
	local la = if rig.holdsBalloon then 0 elseif w.dog then 0.55 + 0.08 * swing else 0.6 * swing
	local ra = if raRoll ~= 0 then 0 elseif rig.bagIndex then -0.35 * swing else -0.6 * swing
	rig.bagPark = rig.bagIndex ~= nil and not w.carry -- a shopper's bag is parked while it carries none
	return self:_poseCitizen(rig, root, la, 0, ra, raRoll, -0.5 * swing, 0.5 * swing, head, extra)
end

-- A shopper off the sidewalk: up the door lane to the window (a glance), into
-- the doorway (a step up onto the plinth), 5-9 s parked out of sight inside,
-- out of the door with a bag (a hop down), down the door lane and back into
-- its lane at the same spot (waiting for a gap), then on to the next gap.
function CityLifeSim:_stepShopper(w, dt: number, t: number)
	local f = FRONTAGES[w.gap]
	local mode = w.mode
	local hopY = 0
	local head = 0
	local y = w.y
	if mode == SHOP_FRONT_IN then
		if w.glance > 0 then
			w.glance -= dt
			w.moving = false
			w.yaw += wrapRad(f.glanceYaw - w.yaw) * min(1, dt * 6)
			head = 0.35 * sin(1.4 * t + w.phase)
			if w.glance <= 0 then
				w.wp = 2
			end
		else
			local target = if w.wp == 1 then f.glance else f.step
			if self:_playerAhead(w, dt) then
				w.moving = false
			elseif approach(w, target.X, target.Z, Config.ShopperFrontSpeed, dt) <= 0 then
				if w.wp == 1 then
					w.visits += 1
					w.glance = Config.ShopperGlanceMin + (Config.ShopperGlanceMax - Config.ShopperGlanceMin) * hash01(w.seed + 21, w.visits)
				else
					w.mode, w.t0 = SHOP_ENTER, t
				end
			end
			y = CityLayout.surfaceY(Vector3.new(w.x, 0, w.z))
		end
	elseif mode == SHOP_ENTER then
		local u = (t - w.t0) / Config.ShopperDoorTime
		if u >= 1 then
			-- inside: the rig (and its bag) is parked until it comes back out
			w.mode = SHOP_INSIDE
			w.visits += 1
			w.timer = Config.ShopperInsideMin + (Config.ShopperInsideMax - Config.ShopperInsideMin) * hash01(w.seed + 29, w.visits)
			w.carry = false
			w.moving = false
			if not w.rig.hidden and not self.simOnly then
				self:_parkRig(w.rig) -- (under the part cap: retried while inside)
			end
			return
		end
		local k = smooth01(u)
		w.x = f.step.X + (f.door.X - f.step.X) * k
		w.z = f.step.Z + (f.door.Z - f.step.Z) * k
		y = f.step.Y + (f.door.Y - f.step.Y) * k
		hopY = 0.35 * sin(math.pi * u)
		w.yaw = f.inYaw
		w.moving = true
		w.walkClock += dt * 9
	elseif mode == SHOP_INSIDE then
		w.timer -= dt
		if not w.rig.hidden and not self.simOnly then
			self:_parkRig(w.rig)
		end
		if w.timer <= 0 then
			w.mode, w.t0, w.carry = SHOP_EXIT, t, true
			w.yaw = f.outYaw
		end
		return
	elseif mode == SHOP_EXIT then
		local u = (t - w.t0) / Config.ShopperDoorTime
		if u >= 1 then
			w.mode, w.wp = SHOP_FRONT_OUT, 1
			u = 1
		end
		local k = smooth01(u)
		w.x = f.door.X + (f.step.X - f.door.X) * k
		w.z = f.door.Z + (f.step.Z - f.door.Z) * k
		y = f.door.Y + (f.step.Y - f.door.Y) * k
		hopY = 0.35 * sin(math.pi * u)
		w.yaw = f.outYaw
		w.moving = true
		w.walkClock += dt * 9
	elseif mode == SHOP_FRONT_OUT then
		local lp = f.lanePoint[w.lane.name]
		local target = if w.wp == 1 then f.glance else lp
		if self:_playerAhead(w, dt) then
			w.moving = false
		elseif approach(w, target.X, target.Z, Config.ShopperFrontSpeed, dt) <= 0 then
			if w.wp == 1 then
				w.wp = 2
			else
				-- back on the sidewalk: merge into the lane once nobody is right there
				w.moving = false
				local dep = f.theta[w.lane.name]
				local lane = w.lane
				w.yaw += wrapRad(tangentYaw(dep * DEG, lane.dir) - w.yaw) * min(1, dt * 6)
				w.mergeWait += dt
				if w.mergeWait > 3 or not self:_laneBusy(w, dep, Config.FollowGap + 0.5) then
					w.mode, w.onLane, w.mergeWait = SHOP_WALK, true, 0
					w.theta, w.sched, w.lateral = dep, dep, 0
					w.pause, w.speed = 0, 0
					w.sector = floor((dep + lane.dir * (lane.pauseLead or 5)) / ZONE_STEP) % ZONE_COUNT
					-- on to the neighbouring gap's Shop A (the lane's direction)
					w.gap = if lane.dir > 0 then w.gap % #FRONTAGES + 1 else (w.gap - 2) % #FRONTAGES + 1
				end
			end
		end
		y = CityLayout.surfaceY(Vector3.new(w.x, 0, w.z))
	end
	w.y = y
	w.amp += ((if w.moving then 1 else 0) - w.amp) * min(1, dt * 8)
	if self.simOnly then
		return
	end
	local visible, animate = self:_citizenVisible(w.rig, w.x, y, w.z, w.low)
	if visible then
		self:_poseWalker(w, w.x, y, w.z, animate, if animate then head else 0, 0, hopY)
	end
end

-- Dog parts parked out of sight (with its walker).
function CityLifeSim:_parkDog(dog)
	self:_emit(dog.body, PARK)
	self:_emit(dog.head, PARK)
	self:_emit(dog.nose, PARK)
	self:_emit(dog.earL, PARK)
	self:_emit(dog.earR, PARK)
	self:_emit(dog.tail, PARK)
	if dog.leash then
		self:_emit(dog.leash, PARK)
	end
	if dog.collar then
		self:_emit(dog.collar, PARK)
	end
end

-- Emits a dog's body, head, nose, ears and tail for a root CFrame (feet,
-- nose toward -Z) and a tail wag angle.
function CityLifeSim:_emitDog(dog, cf: CFrame, wag: number)
	local head = cf * DOG_HEAD_OFF
	self:_emit(dog.body, cf * DOG_BODY_OFF)
	self:_emit(dog.head, head)
	self:_emit(dog.nose, head * DOG_NOSE_OFF)
	self:_emit(dog.earL, head * DOG_EAR_L_OFF)
	self:_emit(dog.earR, head * DOG_EAR_R_OFF)
	-- CFrame.new(DOG_TAIL_PIVOT) * CFrame.Angles(0.75, wag, 0) * CFrame.new(0, 0, 0.4) as one matrix
	local ca, sa, cb, sb = DOG_TAIL_C, DOG_TAIL_S, cos(wag), sin(wag)
	local p = DOG_TAIL_PIVOT
	self:_emit(dog.tail, cf * CFrame.new(p.X + 0.4 * sb, p.Y - 0.4 * sa * cb, p.Z + 0.4 * ca * cb, cb, 0, sb, sa * sb, ca, -sa * cb, -ca * sb, sa, ca * cb))
end

-- Where a walker's dog trots (sim state, also during warm-up): `dogLead`
-- studs ahead and `dogLateral` studs to the `dogSide` (inside the lane's
-- sidestep band at that angle; OuterA: never past its outer bound, which
-- keeps the dog off the crossers waiting at r 116.5).
function CityLifeSim:_placeDog(w, walkerR: number)
	local lane = w.lane
	local lead = lane.dogLead or 2
	local guess = walkerR + (lane.dogLateral or 1) * lane.dogSide
	local dogDeg = w.theta + lane.dir * lead / (guess * DEG)
	local _, minR, maxR = walkRadius(lane, dogDeg)
	local pad = if lane.follow then 0 else 0.6
	w.dogR = clamp(guess, minR - 0.6, maxR + pad)
	w.dogTheta = dogDeg % 360
end

-- The dog trots ahead of its walker (see _placeDog) with a fast 6 Hz bob; it
-- sits and wags while the walker window-shops or waits. The leash spans the
-- walker's left hand (the just-posed arm group) to the collar.
function CityLifeSim:_poseDog(w, paused: boolean, t: number)
	local dog, lane = w.dog, w.lane
	dog.hidden = false
	local dir = lane.dir
	local dogR = w.dogR
	local da = w.dogTheta * DEG
	local dx, dz = cos(da) * dogR, sin(da) * dogR
	local moving = not paused and w.speed > 0.2
	local bob = if moving then 0.14 * abs(sin(6 * math.pi * t + w.phase)) else 0
	-- sitting: nose up a little
	local cf = if moving then yawCF(dx, lane.y + bob, dz, tangentYaw(da, dir)) else yawPitchCF(dx, lane.y + bob, dz, tangentYaw(da, dir), 0.18)
	-- tail wag at 6 Hz trotting, faster sitting
	local wag = (if moving then 0.45 else 0.7) * sin(2 * math.pi * (if moving then 6 else 8) * t + w.phase)
	self:_emitDog(dog, cf, wag)
	-- leash: hand (end of the posed left arm) -> collar
	local s = w.rig.scale
	local hand = w.rig.gcf[G_LARM] * Vector3.new(-0.98 * s, 0.83 * s, 0)
	local collar = cf * DOG_COLLAR
	local span = collar - hand
	local length = span.Magnitude
	if length > 0.05 then
		if abs(length - dog.leashLength) > 0.06 then
			dog.leashLength = length
			dog.leash.Size = Vector3.new(0.08, 0.08, length)
		end
		self:_emit(dog.leash, CFrame.lookAt((hand + collar) * 0.5, collar))
	end
end


-- Breakdancer: dive into a head spin (300 deg/s for 3 s, legs scissoring,
-- arms out), flip back up with a flourish, then hop and wave for 2 s. The
-- boombox bounces to the beat.
function CityLifeSim:_poseDancer(d, t: number, act: number)
	local s = d.rig.scale
	local hc = HAIR_TOP * s / 2 -- flips about the rig's middle so nothing dips into the mat
	local flip, yaw, hopY = 0, d.front, 0
	local laRoll, raRoll, ll, rl = 0, 0, 0, 0
	if act < 0.25 then
		local k = smooth01(act / 0.25)
		flip = math.pi * k
		hopY = 0.8 * sin(math.pi * k)
		laRoll, raRoll = -1.45 * k, 1.45 * k
	elseif act < 3.25 then
		flip = math.pi
		yaw = d.front + (act - 0.25) * 300 * DEG
		laRoll, raRoll = -1.45, 1.45
		local scissor = 0.55 + 0.2 * sin(9 * t)
		ll, rl = scissor, -scissor
	elseif act < 3.5 then
		local k = smooth01((act - 3.25) / 0.25)
		flip = math.pi * (1 - k)
		yaw = d.front + (900 + 180 * k) * DEG
		hopY = 0.8 * sin(math.pi * k)
		laRoll, raRoll = -1.45, 1.45
	else
		local u = act - 3.5
		hopY = 0.9 * s * abs(sin(2 * math.pi * u)) -- two hops a second
		laRoll = -(2.4 + 0.35 * sin(12 * t))
		raRoll = 2.4 + 0.35 * sin(12 * t + 1.3)
	end
	local root = yawCF(d.x, d.y + hopY + hc, d.z, yaw)
	if flip ~= 0 then
		root = root * CFrame.Angles(flip, 0, 0) * CFrame.new(0, -hc, 0)
	else
		root = root * CFrame.new(0, -hc, 0)
	end
	local box = self.boombox
	if not self:_poseCitizen(d.rig, root, 0, laRoll, 0, raRoll, ll, rl, 0, if box then 1 + #box.speakers else nil) then
		return -- (the part cap deferred the act: the boombox with it)
	end
	if box then
		local cf = yawCF(box.x, box.y + 0.07 * abs(sin(2 * math.pi * t)), box.z, box.yaw)
		self:_emit(box.part, cf)
		for j = 1, #box.speakers do
			local sp = box.speakers[j]
			self:_emit(sp.part, cf * sp.rest)
		end
	end
end

-- Poses one idler (every kind except the dancer).
function CityLifeSim:_poseIdler(d, t: number, animate: boolean, cheering: boolean)
	local s = d.rig.scale
	local kind = d.kind
	local y = d.y
	local la, laRoll, ra, raRoll, ll, rl = 0, 0, 0, 0, 0, 0
	local head = 0
	if kind == "Sit" or kind == "Cafe" then
		ll, rl = HALF_PI, HALF_PI
	end
	if kind == "Cafe" then
		la, ra = 1.45, 1.45 -- forearms on the table, the cup in the right hand
	elseif (kind == "Selfie" and d.role == 0) or d.phoneUp then
		ra, raRoll = 2.3, 0.5 -- the phone stays up
	end
	if animate then
		if kind == "Stand" or kind == "Sit" then
			head = 0.5 * sin(0.9 * t + d.phase)
			if d.hop then
				local u = ((t + d.phase * 3) % 5.5) / 0.5
				if u < 1 then
					y += 0.7 * s * sin(math.pi * u)
					laRoll, raRoll = -1.1, 1.1 -- "yay!" arms
				end
			end
			if d.wave and (t + d.phase) % 7 < 1.8 then
				raRoll = 2.5 + 0.4 * sin(12 * t + d.phase)
			elseif d.talk then
				-- hand gestures while chatting (forearm forward, bobbing)
				ra = 0.35 + 0.35 * sin(3.1 * t + d.phase) * (if (t + d.phase) % 5 < 2.5 then 1 else 0)
			end
		elseif kind == "Loiter" then
			-- browsing the window (slow look around), or glancing at the plaza
			head = if t < d.turnUntil then 0.3 * sin(1.3 * t + d.phase) else 0.55 * sin(0.8 * t + d.phase)
			ra = 0.12 + 0.06 * sin(0.7 * t + d.phase)
		elseif kind == "Cafe" then
			-- slow sip: raise the cup (1 s), sip (1.2 s), lower (1 s), chat
			local u = (t + d.phase * 3) % d.period
			local k = if u < 1 then smooth01(u) elseif u < 2.2 then 1 elseif u < 3.2 then 1 - smooth01(u - 2.2) else 0
			ra = 1.45 + 0.75 * k
			raRoll = -0.45 * k
			head = (1 - k) * 0.4 * sin(0.5 * t + d.phase)
		elseif kind == "Clap" then
			if cheering then
				laRoll = -(2.3 + 0.3 * sin(11 * t + d.phase))
				raRoll = 2.3 + 0.3 * sin(11 * t + d.phase + 1.2)
			else
				-- both arms swing together at 2 Hz (hands meet in front)
				local clap = 0.5 + 0.5 * sin(4 * math.pi * t + d.phase * 0.2)
				la, ra = 1.4, 1.4
				laRoll = 0.3 + 0.6 * clap
				raRoll = -(0.3 + 0.6 * clap)
			end
			local u = (t + d.phase * 2) % d.period
			if u < 0.35 then
				y += 0.45 * s * sin(math.pi * u / 0.35)
			end
			head = 0.15 * sin(1.1 * t + d.phase)
		elseif kind == "Selfie" then
			-- "say cheese!" for 3.5 s (outer arms up), then check the photo
			local u = (t + 3) % 6
			local posing = u < 3.5
			local toMid = -d.role -- +1: the phone holder is on this one's +X side
			if u < 0.3 then
				y += 0.25 * s * sin(math.pi * u / 0.3)
			end
			if d.role == 0 then
				ra = if posing then 2.3 else 2.0
				raRoll = 0.5
				head = -0.25
				laRoll = if posing then -(2.4 + 0.2 * sin(8 * t)) else -0.15
			else
				head = -0.35 * toMid
				if posing then
					if toMid > 0 then
						laRoll = -(2.5 + 0.15 * sin(7 * t + d.phase))
					else
						raRoll = 2.5 + 0.15 * sin(7 * t + d.phase)
					end
				end
			end
		end
	elseif kind == "Clap" then
		la, ra, laRoll, raRoll = 1.4, 1.4, 0.6, -0.6
	end
	-- a still idler keeps its root (no new CFrame): only its moving limbs go out
	local rig = d.rig
	local root = if rig.posed and y == d.rootY and d.yaw == d.rootYaw then rig.lastRoot else yawCF(d.x, y, d.z, d.yaw)
	if self:_poseCitizen(rig, root, la, laRoll, ra, raRoll, ll, rl, head) then
		d.rootY, d.rootYaw = y, d.yaw -- (only for a root that went out: lastRoot)
	end
end

function CityLifeSim:_stepIdlers(dt: number)
	local t = self.t
	-- the street act's clock drives the dancer and his crowd
	local act = (t + DANCE_PHASE) % DANCE_CYCLE
	local cheering = act >= 3.5
	for i = 1, #self.idlers do
		local d = self.idlers[i]
		-- state that advances during warm-up too
		if d.kind == "Loiter" then
			if t >= d.nextTurn then
				d.turnCount += 1
				d.turnUntil = t + 4
				d.nextTurn = t + 4 + 25 + 15 * hash01(d.seed, d.turnCount)
			end
			local target = if t < d.turnUntil then d.altYaw else d.baseYaw
			d.yaw += wrapRad(target - d.yaw) * min(1, dt * 5)
		end
		if self.simOnly then
			continue
		end
		-- slow animations: every 2nd frame is plenty (and a still idler emits
		-- only the limbs that moved, see _poseCitizen)
		local visible, animate = self:_citizenVisible(d.rig, d.x, d.y, d.z, d.low, if d.slow then 2 else nil)
		if visible then
			if d.kind == "Dancer" then
				self:_poseDancer(d, t, act)
			else
				self:_poseIdler(d, t, animate, cheering)
			end
		end
	end
end

----------------------------------------------------------------------
-- Pigeons: peck + hop on the ground, flush in an arc to a free spot
----------------------------------------------------------------------

local WING_FOLDED = -1.3

function CityLifeSim:_flushPigeons(flock, f: number, threatX: number?, threatZ: number?)
	flock.flights += 1
	if self:_pigeonTarget(flock, f, threatX, threatZ) then
		flock.flying = true
		flock.t0 = self.t
	else
		flock.nextSpont = self.t + 5
	end
end

function CityLifeSim:_stepPigeons(dt: number)
	local t = self.t
	local flocks = self.pigeonFlocks
	local players, playerCount = self.playerPos, self.playerCount
	local reach = Config.PigeonScare + FLOCK_SPREAD
	local reach2 = reach * reach
	local walkers, crossers = self.walkers, self.crossers
	for f = 1, #flocks do
		local flock = flocks[f]
		if flock.flying then
			if t - flock.t0 >= Config.PigeonFlight then
				flock.flying = false
				flock.cx, flock.cz, flock.cy = flock.tx, flock.tz, flock.ty
				flock.landedAt = t
				flock.nextSpont = t + 20 + 20 * hash01(f, flock.flights + 31)
				-- keep facing the flight direction after landing
				local flightYaw = yawToward(flock.tx - flock.fx, flock.tz - flock.fz)
				for k = 1, #flock.birds do
					local b = flock.birds[k]
					b.baseYaw = flightYaw - floor((t + b.phase) / b.hopEvery) * 1.3
					b.still = false
				end
			end
		elseif t - flock.landedAt > 0.6 then
			-- a player or a citizen within PigeonScare of the flock flushes it
			local cx, cz = flock.cx, flock.cz
			local threatX, threatZ = nil, nil
			for p = 1, playerCount do
				local pos = players[p]
				local dx, dz = pos.X - cx, pos.Z - cz
				if dx * dx + dz * dz < reach2 and pos.Y < flock.cy + 12 then
					threatX, threatZ = pos.X, pos.Z
					break
				end
			end
			if threatX == nil then
				for i = 1, #walkers do
					local w = walkers[i]
					local dx, dz = w.x - cx, w.z - cz
					if dx * dx + dz * dz < reach2 then
						threatX, threatZ = w.x, w.z
						break
					end
				end
			end
			if threatX == nil then
				for i = 1, #crossers do
					local c = crossers[i]
					local dx, dz = c.x - cx, c.z - cz
					if dx * dx + dz * dz < reach2 then
						threatX, threatZ = c.x, c.z
						break
					end
				end
			end
			if threatX ~= nil or t >= flock.nextSpont then
				self:_flushPigeons(flock, f, threatX, threatZ)
			end
		end
		if not self.simOnly then
			self:_posePigeons(flock, t)
		end
	end
end

local PIGEON_BEAK_OFF = CFrame.new(0, -0.03, -0.4)

function CityLifeSim:_posePigeons(flock, t: number)
	local birds = flock.birds
	local mx, mz = flock.cx, flock.cz
	if flock.flying then
		mx, mz = (flock.fx + flock.tx) / 2, (flock.fz + flock.tz) / 2
	end
	local lod = self:_pedLod(mx, flock.cy, mz, flock.low, nil, flock.owed)
	if lod == LOD_HIDE then
		if not flock.hidden and self:_capRoom(5 * #birds) then
			flock.hidden = true
			for k = 1, #birds do
				local b = birds[k]
				self:_emit(b.body, PARK)
				self:_emit(b.head, PARK)
				self:_emit(b.beak, PARK)
				self:_emit(b.wingL, PARK)
				self:_emit(b.wingR, PARK)
			end
		end
		return
	end
	if lod == LOD_SKIP and not flock.flying and not flock.hidden then
		return
	end
	local fresh = flock.hidden or self.forceAll -- re-pose resting birds too
	local span = Config.PigeonFlight - 0.3
	-- pass 1: each bird's pose, and whether it moves (a resting bird - no hop,
	-- no peck - holds its last pose: emitted once)
	local moving = 0
	for k = 1, #birds do
		local b = birds[k]
		local px, py, pz, yaw
		local pitch, dip, wing = 0, 0, WING_FOLDED
		local u = -1
		if flock.flying then
			u = clamp((t - flock.t0 - b.delay) / span, 0, 1)
		end
		local airborne = u > 0 and u < 1
		local still = false
		if airborne then
			local m = smooth01(u)
			px = flock.fx + (flock.tx - flock.fx) * m + b.ox
			pz = flock.fz + (flock.tz - flock.fz) * m + b.oz
			py = flock.fy + (flock.ty - flock.fy) * m + 0.5 + Config.PigeonPeak * 4 * u * (1 - u)
			yaw = yawToward(flock.tx - flock.fx, flock.tz - flock.fz)
			pitch = 0.35 * (1 - 2 * u) -- nose up on the climb, down on the descent
			wing = 0.9 * sin(50 * t + b.phase) -- ~8 flaps a second
		else
			local gx, gz, gy = flock.cx, flock.cz, flock.cy
			local hopY = 0
			if u >= 1 then
				-- touched down before the rest of the flock: wait, facing the flight way
				gx, gz, gy = flock.tx, flock.tz, flock.ty
				yaw = yawToward(flock.tx - flock.fx, flock.tz - flock.fz)
			else
				local clock = t + b.phase
				local hopIndex = floor(clock / b.hopEvery)
				local hu = clock - hopIndex * b.hopEvery
				yaw = b.baseYaw + hopIndex * 1.3
				if hu < 0.3 then
					hopY = 0.45 * sin(math.pi * hu / 0.3) -- short hop, turning on the way
					yaw -= 1.3 * (1 - hu / 0.3)
				else
					local pu = (clock * 1.7) % b.peck
					if pu < 0.22 then
						dip = sin(math.pi * pu / 0.22) -- peck: the head dips 0.3
					end
				end
			end
			px, pz, py = gx + b.ox, gz + b.oz, gy + 0.5 + hopY
			pitch = -0.3 * dip
			still = hopY == 0 and dip == 0
		end
		b.emitNow = not (still and b.still and not fresh)
		b.stillNext = still
		if b.emitNow then
			moving += 1
			b.px, b.py, b.pz, b.yaw, b.pitch, b.dip, b.wing = px, py, pz, yaw, pitch, dip, wing
		end
	end
	if moving == 0 or not self:_admit(flock, 5 * moving) then
		return
	end
	flock.hidden = false
	-- pass 2: emit
	for k = 1, #birds do
		local b = birds[k]
		if not b.emitNow then
			continue
		end
		b.still = b.stillNext
		local pitch, dip, wing = b.pitch, b.dip, b.wing
		local body = if pitch ~= 0 then yawPitchCF(b.px, b.py, b.pz, b.yaw, pitch) else yawCF(b.px, b.py, b.pz, b.yaw)
		local head = body * CFrame.new(0, 0.55 - 0.3 * dip, -0.45 - 0.15 * dip)
		self:_emit(b.body, body)
		self:_emit(b.head, head)
		self:_emit(b.beak, head * PIGEON_BEAK_OFF)
		self:_emit(b.wingR, body * hingeZ(0.45, 0.2, 0.05, wing, 0.33))
		self:_emit(b.wingL, body * hingeZ(-0.45, 0.2, 0.05, -wing, -0.33))
	end
end

local BIRD_BEAK_OFF = CFrame.new(0, 0.05, -1.4)

-- Sky + spinners, all under the sky LOD (_skyLod: every step within the
-- tier's sky radius in front, every midEvery-th step beyond, every 4th behind
-- the camera) and the part cap; clouds and balloons at most every 2nd step.
function CityLifeSim:_stepSky()
	if self.simOnly then
		return
	end
	local t = self.t
	local skyHide = Config.SkyHideRadius

	-- Blimp (parked beyond SkyHideRadius)
	local b = self.blimp
	local ba = (b.theta0 + Config.BlimpSpeed / Config.BlimpRadius * t / DEG) * DEG
	local bx, bz = cos(ba) * Config.BlimpRadius, sin(ba) * Config.BlimpRadius
	local by = Config.BlimpHeight + 1.5 * sin(0.35 * t)
	local lod = self:_skyLod(bx, by, bz, b.slot, nil, b.owed, skyHide)
	if lod == LOD_HIDE then
		if not b.hidden and self:_tryPark(b.parts, b.n) then
			b.hidden, b.owed = true, false
		end
	elseif (lod == LOD_FULL or b.hidden) and self:_admit(b, b.n) then
		b.hidden = false
		local cf = yawCF(bx, by, bz, tangentYaw(ba, 1)) * CFrame.Angles(0.025 * sin(0.5 * t), 0, 0.02 * sin(0.31 * t))
		for j = 1, b.n do
			self:_emit(b.parts[j], cf * b.rest[j])
		end
	end

	-- Birds: one LOD decision per V (its 5 birds move together; parked beyond HideRadius)
	local flapHinge = 0.55
	for f = 1, #self.flocks do
		local flock = self.flocks[f]
		local spec = flock.spec
		local fa = (spec.theta0 + spec.dir * spec.speed / spec.radius * t / DEG) * DEG
		local fx, fz = cos(fa) * spec.radius, sin(fa) * spec.radius
		local fy = spec.height + 1.5 * sin(0.6 * t + f)
		local birds = flock.birds
		local flod = self:_skyLod(fx, fy, fz, flock.slot, nil, flock.owed, Config.HideRadius)
		if flod == LOD_HIDE then
			if not flock.hidden and self:_capRoom(4 * #birds) then
				flock.hidden, flock.owed = true, false
				for k = 1, #birds do
					local bird = birds[k]
					self:_emit(bird.body, PARK)
					self:_emit(bird.beak, PARK)
					self:_emit(bird.wingL, PARK)
					self:_emit(bird.wingR, PARK)
				end
			end
		elseif (flod == LOD_FULL or flock.hidden) and self:_admit(flock, 4 * #birds) then
			flock.hidden = false
			local flockCF = yawCF(fx, fy, fz, tangentYaw(fa, spec.dir)) * CFrame.Angles(0, 0, -spec.dir * 0.22)
			for k = 1, #birds do
				local bird = birds[k]
				local o = bird.offset
				local birdCF = flockCF * CFrame.new(o.X, o.Y + 0.5 * sin(1.4 * t + bird.phase), o.Z)
				local glide = clamp(0.5 + 1.5 * sin(0.9 * t + bird.phase), 0, 1)
				local flap = 0.61 * glide * sin(31.4 * t + bird.phase) -- 5 Hz, +-35 degrees
				self:_emit(bird.body, birdCF)
				self:_emit(bird.beak, birdCF * BIRD_BEAK_OFF)
				self:_emit(bird.wingR, birdCF * hingeZ(flapHinge, 0.15, 0.1, flap, 1.28))
				self:_emit(bird.wingL, birdCF * hingeZ(-flapHinge, 0.15, 0.1, -flap, -1.28))
			end
		end
	end

	-- Clouds: slow orbit about the origin + a gentle bob (at most every 2nd
	-- step: ~4 studs/s at 400+ studs away); parked beyond SkyHideRadius
	for i = 1, #self.clouds do
		local c = self.clouds[i]
		local a = (c.angle0 + Config.CloudOrbit * t) * DEG
		local x, z = cos(a) * c.radius, sin(a) * c.radius
		local y = c.height + Config.CloudBob * sin(0.25 * t + c.phase)
		local clod = self:_skyLod(x, y, z, c.slot, 2, c.owed, skyHide)
		if clod == LOD_HIDE then
			if not c.hidden and self:_tryPark(c.parts, c.n) then
				c.hidden, c.owed = true, false
			end
		elseif (clod == LOD_FULL or c.hidden) and self:_admit(c, c.n) then
			c.hidden = false
			local cf = yawCF(x, y, z, radialYaw(a, false)) -- long axis along the ring
			for j = 1, c.n do
				self:_emit(c.parts[j], cf * c.rest[j])
			end
		end
	end

	-- Hot-air balloons: slow orbit, 1.5-stud bob (8 s), +-3 degree sway; at
	-- most every 2nd step like the clouds, parked beyond SkyHideRadius
	local bobW = 2 * math.pi / Config.BalloonBobPeriod
	local sway = Config.BalloonSway * DEG
	for i = 1, #self.balloons do
		local bl = self.balloons[i]
		local a = (bl.angle0 + bl.dir * Config.BalloonOrbit * t) * DEG
		local x, z = cos(a) * bl.radius, sin(a) * bl.radius
		local y = bl.height + Config.BalloonBob * sin(bobW * t + bl.phase)
		local blod = self:_skyLod(x, y, z, bl.slot, 2, bl.owed, skyHide)
		if blod == LOD_HIDE then
			if not bl.hidden and self:_tryPark(bl.parts, bl.n) then
				bl.hidden, bl.owed = true, false
			end
		elseif (blod == LOD_FULL or bl.hidden) and self:_admit(bl, bl.n) then
			bl.hidden = false
			local cf = yawCF(x, y, z, tangentYaw(a, bl.dir)) * CFrame.Angles(sway * sin(0.9 * t + bl.phase), 0, sway * sin(1.1 * t + 2 * bl.phase))
			for j = 1, bl.n do
				self:_emit(bl.parts[j], cf * bl.rest[j])
			end
		end
	end

	-- Rooftop coins (beyond CoinRadius they hold their pose)
	for i = 1, #self.coins do
		local coin = self.coins[i]
		local c = coin.center
		local y = c.Y + 0.4 * sin(1.1 * t + coin.phase)
		if self:_skyLod(c.X, y, c.Z, coin.slot, nil, coin.owed, Config.CoinRadius) == LOD_FULL and self:_admit(coin, 2) then
			local cf = yawCF(c.X, y, c.Z, (90 * t + coin.phase * 57) * DEG)
			self:_emit(coin.rim, cf)
			self:_emit(coin.face, cf)
		end
	end

	-- CitySpin models + the zone hero-prop spinners, per model (the zone ones
	-- only within ZoneSpinRadius of the camera; beyond it they hold their pose)
	local huge = math.huge
	for i = 1, #self.spinGroups do
		local sg = self.spinGroups[i]
		local p = sg.pivot
		local slod = self:_skyLod(p.X, p.Y, p.Z, sg.slot, nil, sg.owed, if sg.zone then Config.ZoneSpinRadius else huge)
		if slod == LOD_FULL and self:_admit(sg, sg.n) then
			local cf = yawCF(p.X, p.Y, p.Z, (sg.rate * t + sg.a0) * DEG)
			local parts, offsets = sg.parts, sg.offsets
			for j = 1, sg.n do
				self:_emit(parts[j], cf * offsets[j])
			end
		end
	end
end

-- Advances the world by dt (seconds). cameraPos drives LOD (nil = everything
-- full detail) and cameraLook (the camera's LookVector) the facing LOD;
-- forceAll poses every agent regardless of LOD or the part cap (the first
-- step and the one after bindMap do too). Returns the number of parts to move
-- (sim.outParts / sim.outCFrames [1..n]; <= the runtime tier's part cap).
function CityLifeSim:step(dt: number, cameraPos: Vector3?, forceAll: boolean?, cameraLook: Vector3?): number
	dt = clamp(dt, 1e-4, 0.1)
	self.t += dt
	self.frame += 1
	self.camera = cameraPos
	self.cameraLook = if cameraPos then cameraLook else nil -- facing LOD (nil: distance only)
	-- the first frame poses everything (rigs are built at the origin), LOD after
	self.forceAll = forceAll == true or (not self.simOnly and (self.frame == 1 or self.poseAllNext))
	if self.forceAll and not self.simOnly then
		self.poseAllNext = false
	end
	self.outCount = 0
	self:_capBegin()

	self:_stepLights(dt)
	self:_stepVehicles(dt)
	if not self.simOnly then
		self:_poseVehicles(dt)
	end
	self:_stepCrossers(dt)
	self:_stepWalkers(dt)
	self:_stepIdlers(dt)
	self:_stepCustomers(dt)
	self:_stepWashCar(dt)
	self:_stepCourseDogs(dt)
	self:_stepWashers(dt)
	self:_stepPigeons(dt)
	self:_stepSky()
	self:_stepPulse(dt)

	local n = self.outCount
	local outP, outC = self.outParts, self.outCFrames
	for i = n + 1, self.prevCount do
		outP[i] = nil
		outC[i] = nil
	end
	self.prevCount = n
	return n
end

-- Simulates `seconds` without posing anything (render warm-up, tests).
function CityLifeSim:advance(seconds: number, dt: number?)
	local stepDt = dt or 1 / 30
	self.simOnly = true
	local steps = math.max(0, math.floor(seconds / stepDt + 0.5))
	for _ = 1, steps do
		self:step(stepDt, nil, false)
	end
	self.simOnly = false
end

function CityLifeSim:getCounts()
	local parts = 0
	for _, d in self.folder:GetDescendants() do
		if d:IsA("BasePart") then
			parts += 1
		end
	end
	local birds = 0
	for _, flock in self.flocks do
		birds += #flock.birds
	end
	local pigeons = 0
	for _, flock in self.pigeonFlocks do
		pigeons += #flock.birds
	end
	local customerParts = 0
	if self.customerFolder then
		for _, d in self.customerFolder:GetDescendants() do
			if d:IsA("BasePart") then
				customerParts += 1
			end
		end
	end
	local zoneLifeParts = 0
	if self.zoneLifeFolder then
		for _, d in self.zoneLifeFolder:GetDescendants() do
			if d:IsA("BasePart") then
				zoneLifeParts += 1
			end
		end
	end
	local pulse = self.pulse
	local anchorFrames = 0
	if pulse then
		for _, f in pulse.frames do
			if f.kind == "anchor" then
				anchorFrames += 1
			end
		end
	end
	return {
		citizens = self.citizenCount - self.customerCount,
		shoppers = self.shopperCount,
		walkers = #self.walkers - self.shopperCount,
		zoneSpinGroups = self.zoneSpinGroups,
		zoneSkipped = #self.zoneSkipped,
		washCar = if self.washCar then 1 else 0,
		courseDogs = #self.courseDogs,
		zoneLifeParts = zoneLifeParts,
		tickerGroups = if pulse then #pulse.tickers else 0,
		heartParts = if pulse then #pulse.hearts else 0,
		anchorFrames = anchorFrames,
		pulseTrims = if pulse then #pulse.trims else 0,
		police = if self.police then 1 else 0,
		washers = if self.washers then #self.washers else 0,
		crossers = #self.crossers,
		customers = self.customerCount,
		customerParts = customerParts,
		vehicles = #self.vehicles,
		birds = birds,
		pigeons = pigeons,
		clouds = #self.clouds,
		balloons = #self.balloons,
		dogs = #self.dogs,
		coins = #self.coins,
		spinners = #self.spinners,
		pulseFrames = if pulse then #pulse.frames else 0,
		pulseTips = if pulse then #pulse.tips else 0,
		pulseBlades = if pulse then #pulse.blades else 0,
		parts = parts,
		tier = self.tier,
		runtimeTier = self.runtimeTier,
	}
end

return CityLifeSim
