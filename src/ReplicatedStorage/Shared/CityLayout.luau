--!strict
-- CityLayout: PURE description of the downtown around the spawn plaza (no
-- Instances, no services, no state). The server's MapBuilder / CityBuilder
-- build the streets and buildings FROM this module, and the client city-life
-- system (pedestrians, cars) walks and drives on it, so both always agree.
--
-- Coordinates: world studs, plaza center at the origin, terrain top at Y = 0.
-- Angles are in DEGREES around the origin: angle a is the point
-- (cos a * r, y, sin a * r); "increasing angle" turns from +X toward +Z.
-- Zone i (GameConfig order) sits on the axis angle (i - 1) * ZoneAngleStep.
--
-- API
--   CityLayout.Street             -- street cross-section (radii + surface tops), see below
--   CityLayout.ringPos(radius, degrees, y?) -> Vector3
--   CityLayout.angleOf(position) -> number           -- 0..360 degrees
--   CityLayout.facingCFrame(radius, degrees, y?) -> CFrame
--       ground CFrame on the ring whose -Z (LookVector) faces the plaza origin
--       (identical to Mechanics.zoneGroundCFrame for a zone center)
--   CityLayout.zoneAngles: { number }                 -- axis angle per zone order
--   CityLayout.gapAngles: { number }                  -- bisector angle between zone k and k+1
--
--   CityLayout.sidewalkLoops: { Loop }  -- pedestrian loops (closed polylines at feet height)
--       "OuterSidewalk" r 113.5, Y 0.5  (outer sidewalk r 105.2..120; furniture strip is r 105..112)
--       "InnerSidewalk" r 62,    Y 0.75 (inner sidewalk r 58..64.8, between plaza rim and road curb)
--     points are ordered with increasing angle; walkers may go either way.
--   CityLayout.laneLoops: { Loop }      -- car lanes (closed polylines at tire height Y 0.6)
--       right-hand traffic: "Inner1" r 70.75 and "Inner2" r 80.25 drive with increasing
--       angle (direction = +1); "Outer1" r 89.75 and "Outer2" r 99.25 drive with decreasing
--       angle (direction = -1). points are ALREADY ordered in the travel direction.
--   CityLayout.backLaneLoops: { Loop }  -- the Back Avenue between the skyline rings
--       (asphalt r 250.6..270, Y Street.BackAsphaltTop 0.12; no crosswalks or lights):
--       "Back1" r 255 direction +1, "Back2" r 265 direction -1 (same right-hand rule).
--       Deliberately NOT part of laneLoops (ring-road traffic + crosswalk logic).
--   CityLayout.backSidewalkLoops: { Loop } -- pedestrian loops along the Back Avenue
--       "BackInner" r 247.3, Y 0.2 (city-block ground, between the mid-ring backs ~244.6 and
--       the avenue edge r 250) and "BackOuter" r 273.4, Y 0 (pavement terrain, between the
--       avenue edge r 270.6 and the outer-ring fronts / pillars / round plinths >= 275.5).
--       Kept OUT of sidewalkLoops (crosswalk / window-shopping logic is ring-road only).
--   Loop = { name, kind ("Sidewalk" | "Lane"), radius, y, direction (+1 | -1), points: { Vector3 } }
--   CityLayout.loopPoint(loop, degrees) -> Vector3   -- exact point on a loop's circle
--
--   CityLayout.crosswalks: { Crosswalk } -- one zebra crossing on every zone axis
--     Crosswalk = { zoneId, angle, center, innerPoint (on the inner sidewalk loop),
--       outerPoint (on the outer sidewalk loop), direction (unit, plaza -> zone),
--       halfWidth (tangential, studs), innerRadius, outerRadius (radial extent of the stripes) }
--   CityLayout.crosswalkHalfAngle(radius) -> number  -- angular half-width (deg) of every
--       crosswalk band at a lane radius (+ CityLayout.Street.CrosswalkStopMargin studs to stop)
--   CityLayout.isOnCrosswalk(position) -> (boolean, Crosswalk?)
--   CityLayout.roadDashes: { Dash } / CityLayout.backDashes: { Dash } -- every lane dash (120 on
--       the ring road: yellow "Center" r 85 + white "Lane" r 75.5 / 94.5, 15 around each gap
--       bisector, never within Street.DashSkip deg of a zone axis; 72 yellow "Back" dashes at
--       r 260 every 5 deg). Dash = { kind, angle, radius, length (tangential), width (radial),
--       cframe (center at the paint height, X along the dash) }
--   CityLayout.markingDecks / backMarkingDecks: { MarkingDeck } -- 8 + 8 invisible flat decks (one
--       per gap octant) whose SurfaceGui "Markings" PAINTS those dashes (zero dash parts):
--       MarkingDeck = { name, gapIndex, angle, cframe (horizontal center frame), width, depth,
--       pixelsPerStud, dashes } (each dash is on exactly one deck: |angleDelta| < 22.5 of its bisector)
--
--   CityLayout.wanderAreas: { WanderArea } -- "Plaza": annulus minRadius..maxRadius at Y
--     WanderArea = { name, center, minRadius, maxRadius, y, obstacles: { { position, radius } } }
--   CityLayout.isPlazaPointFree(position, clearance?) -> boolean
--
--   CityLayout.skyline: { BuildingSpec }   -- 48 skyline buildings (two rings): 24 "MidBuilding<k>"
--       (r 232), 18 "OuterBuilding<k>" (r 292) and 6 landmark "HeroTower<k>" in outer slots
--       k = 2, 7, 10, 14, 19, 22 (spec.hero = "Stepped" | "Round" | "Billboard"; spec.height =
--       collider roof height, spec.top = highest point incl. spire / dome / billboard)
--   CityLayout.rowhouses: { BuildingSpec } -- 24 narrow 20-tall infills between the mid-ring
--       buildings (angles 15k, r 220..238), so the mid ring reads as one street wall
--   CityLayout.shops: { ShopSpec }         -- 16 storefronts in the gaps between zones
--   CityLayout.anchors: { AnchorSpec }     -- one landmark behind each zone pad
--   CityLayout.footprints: { Footprint }   -- every solid footprint to keep clear of
--     Footprint = { name, cframe (ground center, -Z to the plaza), size (W, H, D) }
--   CityLayout.isInFootprint(position, margin?) -> boolean
--   CityLayout.trafficLights: { { zoneId, angle, cframe (pole base) } }
--       built as Model "TrafficLight" (attribute ZoneId) with Neon parts named
--       SignalRed / SignalAmber / SignalGreen (clients may recolor them locally)
--   CityLayout.busStops: { { name, angle, cframe (ground center, -Z faces the road) } }
--   CityLayout.parks: { { name, angle, cframe (lawn center on the ground, -Z to the plaza),
--       size (W, H, D) } } -- walkable pocket-park lawns (top Y 0.3) behind the shops;
--       trees stand at CityLayout.parkTrees (collidable trunks, radius ~1)
--   CityLayout.cafes: { { gapIndex, cframe, position, radius } } -- café tables (umbrella
--       canopy radius 4, CanCollide false) on the pavement in front of every Shop A
--   CityLayout.cafeSeats: { { position (stool top, world Y 2.0), facing (unit, toward the
--       table), gapIndex } } -- 2 stools per table, 4 per gap (32 in all)
--   CityLayout.Cafe -- café geometry constants (tableX, z, stoolOffset, stoolTop, canopyY, terrace ...)
--   CityLayout.cafeTerraces: { { gapIndex, accentIndex, cframe (center), size } } -- flat checkered
--       patio rug (CanCollide false, top 0.28) under each Shop A café, Shop-A-local x -13.5..5,
--       z -17..-8.5; walkable (surfaceY still reports the 0.2 block ground under it)
--   CityLayout.pocketTrees: { Vector3 } / CityLayout.pocketLamps: { Vector3 } -- trees in
--       planters (angles 30k) and lamp posts (angles 15 + 30k) at r 241.5 in the pockets behind
--       the rowhouses (between the mid-ring buildings); collidable trunk / pole, in footprints
--   CityLayout.gapTrees: { Vector3 } -- street trees beside both shops of every gap (planter
--       center on the block ground; planter radius 2.5, collidable trunk radius ~0.8)
--   CityLayout.streetFurniture: { { kind, position, radius } } -- sidewalk props on the outer furniture
--       strip r 105..112 (all CanCollide false except lamp / signal poles). kind "Lamp" = tall
--       double lamp (15-tall pole, 6-wide arm at y 14.6) with festival banners hanging in the
--       tangential plane (y 8.1..12.7, radial extent +-0.15): fields light (PointLight or not),
--       bannerZones = { lower-angle zone id, higher-angle zone id } and, on the 16 zone lamps
--       (zone axis +- 10.5 deg, slid clear of other furniture / signposts), zoneId
--   CityLayout.signposts: { { zoneId, angle, cframe, position, boardFrom, boardTo } } -- road-side
--       zone signposts (r 108, zone axis + 12 deg); the board spans boardFrom..boardTo at y ~4.6
--   CityLayout.TowerCranes: { [outerIndex]: { rate } } + CityLayout.Crane (mastZ, mastTop, pivotY,
--       reach, top, loadBottom) -- two slewing rooftop cranes (OuterBuilding1 / OuterBuilding13);
--       the turning "CraneTop" (CitySpin) sweeps r 254.5..337.5 at y 125.8..153.1 (load r >= 268.5)
--   CityLayout.plazaProps: { { kind, position, radius, angle } } -- food carts + balloon vendor
--   CityLayout.plazaPlanters: { { position, radius, angle, colorIndex } } -- 5 raised round
--       flower planters on the plaza (collidable, 9 wide, 2.4 tall; obstacle radius 5)
--   CityLayout.storefronts: { { name, position, facing: Vector3 } } -- spot on the pavement
--       in front of each shop door (window shoppers), facing the door
--   CityLayout.surfaceY(position) -> number -- walkable surface height at a world XZ
--       (plaza 1.5, plaza rim 1.3, inner sidewalk 0.75, road 0.6, outer sidewalk 0.5,
--        zone pads 1.5, white curb 0.3, park lawns 0.3 (curb 0.25), city-block ground 0.2
--        (r 122.5..250), Back Avenue asphalt 0.12 (edges 0.16 / 0.08), pavement terrain 0)
--   CityLayout.skylineTop -> number -- highest roof point of the skyline (studs)

local GameConfig = require(script.Parent.GameConfig)

local CityLayout = {}

local ZONE_RADIUS = GameConfig.Map.ZoneRadius
local ZONE_STEP = GameConfig.Map.ZoneAngleStep
local ZONE_COUNT = #GameConfig.Zones
local PAD_HALF = 32 -- zone pads are 64 x 64

----------------------------------------------------------------------
-- Street cross-section (radii from the plaza origin; tops are world Y)
----------------------------------------------------------------------

CityLayout.Street = {
	PlazaRadius = 55,
	PlazaTop = 1.5,
	PlazaTrimRadius = 58,
	PlazaTrimTop = 1.3,
	InnerSidewalkRadius = 66, -- inner sidewalk disc (visible r 58..66)
	InnerSidewalkTop = 0.75,
	AsphaltInner = 66,
	AsphaltOuter = 104, -- asphalt disc (visible r 66..104)
	AsphaltTop = 0.6,
	OuterSidewalkRadius = 120, -- outer sidewalk disc (visible r 104..120) == MapBuilder ROAD_TOP
	OuterSidewalkTop = 0.5,
	OuterCurbRadius = 122.5, -- white trim ring around the outer sidewalk
	OuterCurbTop = 0.3,
	-- curbs on the asphalt edges (1.2 wide, 0.3 tall blocks)
	InnerCurbRadius = 65.4,
	RoadCurbRadius = 104.6,
	CurbWidth = 1.2,
	CurbHeight = 0.3,
	-- markings
	CenterLineRadius = 85,
	LaneDividerRadii = { 75.5, 94.5 },
	MarkingTop = 0.65,
	DashStep = 6, -- degrees between dashes
	DashSkip = 9, -- no dashes within this many degrees of a zone axis (crosswalks)
	DashLength = 5, -- tangential (studs)
	DashWidth = 0.8, -- radial (studs)
	-- every dash is PAINTED (SurfaceGui frames) on one of 8 invisible flat
	-- MarkingDeck<k> parts per ring (CityLayout.markingDecks / backMarkingDecks)
	MarkingDeckRadius = 84,
	MarkingDeckY = 0.65, -- deck center (0.05 thick: paint at 0.675)
	MarkingDeckWidth = 48, -- tangential
	MarkingDeckDepth = 26, -- radial (r 71..97 on the bisector)
	MarkingDeckPixelsPerStud = 10,
	-- crosswalks (on every zone axis)
	CrosswalkFirstRadius = 68,
	CrosswalkStep = 4.2,
	CrosswalkBars = 9,
	CrosswalkWidth = 16, -- tangential
	CrosswalkBarDepth = 2.2, -- radial
	CrosswalkStopMargin = 3,
	-- walking / driving
	OuterWalkRadius = 113.5,
	InnerWalkRadius = 62,
	LaneRadii = { 70.75, 80.25, 89.75, 99.25 },
	LaneWidth = 9.5,
	-- street furniture strip on the outer sidewalk (between the curb and the walk loop)
	FurnitureRadius = 108,
	-- city-block ground: one smooth sidewalk-colored disc over the terrain from
	-- the outer curb (r 122.5) to the back avenue (r 250)
	BlockGroundRadius = 250,
	BlockGroundTop = 0.2,
	-- Back Avenue between the mid and outer skyline rings: white edge rings
	-- (r 250..250.6 and 270..270.6) around a 2-lane asphalt ring
	BackAsphaltInner = 250,
	BackAsphaltOuter = 270,
	BackEdgeWidth = 0.6,
	BackAsphaltTop = 0.12,
	BackEdgeInnerTop = 0.16,
	BackEdgeOuterTop = 0.08,
	BackLaneRadii = { 255, 265 },
	BackCenterLineRadius = 260,
	BackDashStep = 5, -- degrees between Back Avenue center dashes
	BackDashLength = 4,
	BackDashWidth = 0.5,
	BackMarkingDeckRadius = 250.1,
	BackMarkingDeckY = 0.15, -- deck center (paint at 0.175, over the 0.12 avenue)
	BackMarkingDeckWidth = 205,
	BackMarkingDeckDepth = 25,
	BackMarkingDeckPixelsPerStud = 5,
	-- Back Avenue sidewalk loops (CityLayout.backSidewalkLoops)
	BackInnerWalkRadius = 247.3, -- on the city-block ground (Y 0.2)
	BackOuterWalkRadius = 273.4, -- on the pavement terrain (Y 0)
}
local S = CityLayout.Street

----------------------------------------------------------------------
-- Ring helpers
----------------------------------------------------------------------

function CityLayout.ringPos(radius: number, degrees: number, y: number?): Vector3
	local a = math.rad(degrees)
	return Vector3.new(math.cos(a) * radius, y or 0, math.sin(a) * radius)
end

function CityLayout.angleOf(position: Vector3): number
	return math.deg(math.atan2(position.Z, position.X)) % 360
end

-- -Z faces the origin: LookVector = (-cos a, 0, -sin a). Built without
-- CFrame.lookAt so it is exact everywhere.
function CityLayout.facingCFrame(radius: number, degrees: number, y: number?): CFrame
	local a = math.rad(degrees)
	return CFrame.new(math.cos(a) * radius, y or 0, math.sin(a) * radius) * CFrame.Angles(0, math.pi / 2 - a, 0)
end

local ringPos = CityLayout.ringPos
local facingCFrame = CityLayout.facingCFrame

local zoneAngles: { number } = {}
local gapAngles: { number } = {}
for i = 1, ZONE_COUNT do
	zoneAngles[i] = (i - 1) * ZONE_STEP
	gapAngles[i] = (i - 1) * ZONE_STEP + ZONE_STEP / 2
end
CityLayout.zoneAngles = zoneAngles
CityLayout.gapAngles = gapAngles

-- Signed smallest difference a - b in degrees (-180..180).
local function angleDelta(a: number, b: number): number
	return (a - b + 180) % 360 - 180
end
CityLayout.angleDelta = angleDelta

----------------------------------------------------------------------
-- Loops (sidewalks + lanes)
----------------------------------------------------------------------

export type Loop = {
	name: string,
	kind: string,
	radius: number,
	y: number,
	direction: number,
	points: { Vector3 },
}

local LOOP_STEP = 5 -- degrees between polyline points (sagitta < 0.11 studs at r 114)

local function makeLoop(name: string, kind: string, radius: number, y: number, direction: number): Loop
	local points = {}
	local count = math.floor(360 / LOOP_STEP)
	for i = 0, count - 1 do
		local degrees = if direction >= 0 then i * LOOP_STEP else -i * LOOP_STEP
		table.insert(points, ringPos(radius, degrees % 360, y))
	end
	return { name = name, kind = kind, radius = radius, y = y, direction = direction, points = points }
end

CityLayout.sidewalkLoops = {
	makeLoop("OuterSidewalk", "Sidewalk", S.OuterWalkRadius, S.OuterSidewalkTop, 1),
	makeLoop("InnerSidewalk", "Sidewalk", S.InnerWalkRadius, S.InnerSidewalkTop, 1),
}

CityLayout.laneLoops = {
	makeLoop("Inner1", "Lane", S.LaneRadii[1], S.AsphaltTop, 1),
	makeLoop("Inner2", "Lane", S.LaneRadii[2], S.AsphaltTop, 1),
	makeLoop("Outer1", "Lane", S.LaneRadii[3], S.AsphaltTop, -1),
	makeLoop("Outer2", "Lane", S.LaneRadii[4], S.AsphaltTop, -1),
}

-- Back Avenue lanes (between the skyline rings; no crosswalks, no lights).
-- Kept OUT of laneLoops so the ring-road traffic / crosswalk logic is untouched.
CityLayout.backLaneLoops = {
	makeLoop("Back1", "Lane", S.BackLaneRadii[1], S.BackAsphaltTop, 1),
	makeLoop("Back2", "Lane", S.BackLaneRadii[2], S.BackAsphaltTop, -1),
}

-- Back Avenue sidewalks (walkers between the skyline rings): inner on the
-- city-block ground, outer on the pavement terrain in front of the outer ring.
CityLayout.backSidewalkLoops = {
	makeLoop("BackInner", "Sidewalk", S.BackInnerWalkRadius, S.BlockGroundTop, 1),
	makeLoop("BackOuter", "Sidewalk", S.BackOuterWalkRadius, 0, 1),
}

function CityLayout.loopPoint(loop: Loop, degrees: number): Vector3
	return ringPos(loop.radius, degrees, loop.y)
end

----------------------------------------------------------------------
-- Crosswalks
----------------------------------------------------------------------

export type Crosswalk = {
	zoneId: string,
	angle: number,
	center: Vector3,
	innerPoint: Vector3,
	outerPoint: Vector3,
	direction: Vector3,
	halfWidth: number,
	innerRadius: number,
	outerRadius: number,
}

local CROSS_INNER = S.CrosswalkFirstRadius - S.CrosswalkBarDepth / 2
local CROSS_OUTER = S.CrosswalkFirstRadius + S.CrosswalkStep * (S.CrosswalkBars - 1) + S.CrosswalkBarDepth / 2

local crosswalks: { Crosswalk } = {}
for i, zone in GameConfig.Zones do
	local angle = zoneAngles[i]
	table.insert(crosswalks, {
		zoneId = zone.Id,
		angle = angle,
		center = ringPos((CROSS_INNER + CROSS_OUTER) / 2, angle, S.AsphaltTop),
		innerPoint = ringPos(S.InnerWalkRadius, angle, S.InnerSidewalkTop),
		outerPoint = ringPos(S.OuterWalkRadius, angle, S.OuterSidewalkTop),
		direction = ringPos(1, angle, 0),
		halfWidth = S.CrosswalkWidth / 2,
		innerRadius = CROSS_INNER,
		outerRadius = CROSS_OUTER,
	})
end
CityLayout.crosswalks = crosswalks

function CityLayout.crosswalkHalfAngle(radius: number): number
	return math.deg(math.asin(math.clamp(S.CrosswalkWidth / 2 / radius, 0, 1)))
end

function CityLayout.isOnCrosswalk(position: Vector3): (boolean, Crosswalk?)
	local flat = Vector3.new(position.X, 0, position.Z)
	local r = flat.Magnitude
	if r < CROSS_INNER or r > CROSS_OUTER then
		return false, nil
	end
	for _, cw in crosswalks do
		local u = cw.direction
		local side = -flat.X * u.Z + flat.Z * u.X
		if math.abs(side) <= cw.halfWidth and flat:Dot(u) > 0 then
			return true, cw
		end
	end
	return false, nil
end

----------------------------------------------------------------------
-- Road markings: PAINTED dashes (SurfaceGui frames on invisible flat decks)
----------------------------------------------------------------------
-- Ring road: around every gap bisector g, a dash at g + j * DashStep
-- (j = -2..2) on the yellow center line (r 85) and on both white lane
-- dividers (r 75.5 / 94.5), never within DashSkip degrees of a zone axis
-- (the zebras live there): 15 per gap, 120 in all. Back Avenue: a yellow
-- center dash every BackDashStep degrees at r 260 (72). Each dash belongs to
-- exactly one deck: octant k (bisector g = gapAngles[k]) takes the dashes
-- with angleDelta(angle, g) in [-22.5, 22.5).

export type Dash = {
	kind: string, -- "Center" (yellow) | "Lane" (white) | "Back" (yellow, Back Avenue)
	angle: number,
	radius: number,
	length: number, -- tangential
	width: number, -- radial
	cframe: CFrame, -- dash center at its deck's paint height, X axis along the dash
}

export type MarkingDeck = {
	name: string, -- "MarkingDeck<k>" | "BackMarkingDeck<k>"
	gapIndex: number,
	angle: number, -- the deck's bisector
	cframe: CFrame, -- horizontal frame at the deck center (-Z toward the plaza)
	width: number,
	depth: number,
	pixelsPerStud: number,
	dashes: { Dash },
}

local function octantOf(degrees: number): number
	for k, g in gapAngles do
		local d = angleDelta(degrees, g)
		if d >= -ZONE_STEP / 2 and d < ZONE_STEP / 2 then
			return k
		end
	end
	return 1
end

local function makeDecks(prefix: string, radius: number, y: number, width: number, depth: number, pps: number): { MarkingDeck }
	local decks: { MarkingDeck } = {}
	for k, g in gapAngles do
		decks[k] = {
			name = prefix .. k,
			gapIndex = k,
			angle = g,
			cframe = facingCFrame(radius, g, y),
			width = width,
			depth = depth,
			pixelsPerStud = pps,
			dashes = {},
		}
	end
	return decks
end

local markingDecks = makeDecks("MarkingDeck", S.MarkingDeckRadius, S.MarkingDeckY, S.MarkingDeckWidth, S.MarkingDeckDepth, S.MarkingDeckPixelsPerStud)
local backMarkingDecks = makeDecks("BackMarkingDeck", S.BackMarkingDeckRadius, S.BackMarkingDeckY, S.BackMarkingDeckWidth, S.BackMarkingDeckDepth, S.BackMarkingDeckPixelsPerStud)

local function nearZoneAxis(degrees: number, within: number): boolean
	for _, axis in zoneAngles do
		if math.abs(angleDelta(degrees, axis)) < within then
			return true
		end
	end
	return false
end

local RING_LINES: { { kind: string, radius: number } } = {
	{ kind = "Center", radius = S.CenterLineRadius },
	{ kind = "Lane", radius = S.LaneDividerRadii[1] },
	{ kind = "Lane", radius = S.LaneDividerRadii[2] },
}
local roadDashes: { Dash } = {}
local ringPaintY = S.MarkingDeckY + 0.025
for _, g in gapAngles do
	for j = -2, 2 do
		local a = g + j * S.DashStep
		if not nearZoneAxis(a, S.DashSkip) then
			for _, line in RING_LINES do
				local dash: Dash = {
					kind = line.kind,
					angle = a % 360,
					radius = line.radius,
					length = S.DashLength,
					width = S.DashWidth,
					cframe = facingCFrame(line.radius, a, ringPaintY),
				}
				table.insert(roadDashes, dash)
				table.insert(markingDecks[octantOf(a)].dashes, dash)
			end
		end
	end
end
local backDashes: { Dash } = {}
local backPaintY = S.BackMarkingDeckY + 0.025
for i = 0, math.floor(360 / S.BackDashStep) - 1 do
	local a = i * S.BackDashStep
	local dash: Dash = {
		kind = "Back",
		angle = a,
		radius = S.BackCenterLineRadius,
		length = S.BackDashLength,
		width = S.BackDashWidth,
		cframe = facingCFrame(S.BackCenterLineRadius, a, backPaintY),
	}
	table.insert(backDashes, dash)
	table.insert(backMarkingDecks[octantOf(a)].dashes, dash)
end
CityLayout.roadDashes = roadDashes
CityLayout.backDashes = backDashes
CityLayout.markingDecks = markingDecks
CityLayout.backMarkingDecks = backMarkingDecks

----------------------------------------------------------------------
-- Buildings (skyline rings, storefronts, zone anchors)
----------------------------------------------------------------------

export type BuildingSpec = {
	name: string,
	ring: string, -- "Mid" | "Outer"
	index: number, -- 0-based within its ring
	angle: number,
	radius: number,
	width: number, -- tangential
	height: number, -- collider roof height
	depth: number, -- radial
	cframe: CFrame, -- ground center, -Z faces the plaza
	hero: string?, -- landmark towers only: "Stepped" | "Round" | "Billboard"
	top: number?, -- landmark towers only: highest point (spire / dome / billboard)
}

local MID_RING = {
	radius = 232,
	startAngle = 7.5,
	step = 15,
	count = 24,
	depth = 24,
	widths = { 40, 36, 42, 38, 40, 36, 42, 38 },
	heights = { 36, 48, 40, 56, 34, 52, 44, 60 },
}
local OUTER_RING = {
	radius = 292,
	startAngle = 0,
	step = 15,
	count = 24,
	depth = 30,
	widths = { 44, 38, 48, 40, 46, 38, 50, 42 },
	heights = { 72, 98, 64, 112, 84, 68, 104, 78 },
}
CityLayout.MidRing = MID_RING
CityLayout.OuterRing = OUTER_RING

-- Landmark towers replacing six outer-ring slots (same ring + cframe; they
-- stay inside the 30-deep outer footprint so the Back Avenue sidewalk and
-- the blimp path (r 250, y 120, >= 27 studs from every face) stay clear).
--   Stepped:   3 setback tiers 36x80x28 / 28x45x22 / 20x25x16, spire to y 185.25
--   Round:     30-dia cylinder x 140 on a 33-dia plinth, dome (30) + finial, antenna
--   Billboard: 34x130x26 slab, stepped crown, 30x12 rooftop billboard to y 147
local HERO_TOWERS = {
	[2] = { hero = "Stepped", width = 36, depth = 28, height = 150, top = 185.25 },
	[7] = { hero = "Round", width = 30, depth = 30, height = 140, top = 175.4 },
	[10] = { hero = "Billboard", width = 34, depth = 26, height = 130, top = 147 },
	[14] = { hero = "Stepped", width = 36, depth = 28, height = 150, top = 185.25 },
	[19] = { hero = "Round", width = 30, depth = 30, height = 140, top = 175.4 },
	[22] = { hero = "Billboard", width = 34, depth = 26, height = 130, top = 147 },
}
CityLayout.HeroTowers = HERO_TOWERS

-- Slewing tower cranes on two outer-ring roofs (in place of their water
-- towers): outer index k -> CitySpin rate (deg/s, + = the client sim's
-- positive Y turn). Geometry (building-local): mast axis at (0, roof, mastZ)
-- (r 296) up to y mastTop; the turning top pivots on the mast axis at pivotY:
-- jib y 141.5..144.1 reaching `reach` studs (tip x +38, counter-jib -12, tie
-- bars to y `top`), trolley + hanging load at x trolleyX down to loadBottom.
-- The load always hangs at r >= 268.5 and the jib tip at r >= 258 sits >= 21
-- studs above the blimp path (r 250, y 120, +- 9 incl. fins).
CityLayout.TowerCranes = {
	[1] = { rate = 4 },
	[13] = { rate = -3 },
}
CityLayout.Crane = { mastZ = 4, mastTop = 136, pivotY = 137, trolleyX = 24, reach = 41.5, top = 153.1, loadBottom = 125.8 }

local skyline: { BuildingSpec } = {}
for _, ringDef in { { name = "Mid", def = MID_RING }, { name = "Outer", def = OUTER_RING } } do
	local ringName, def = ringDef.name, ringDef.def
	for k = 0, def.count - 1 do
		local angle = (def.startAngle + def.step * k) % 360
		local cycle = k % #def.widths + 1
		local hero = if ringName == "Outer" then HERO_TOWERS[k] else nil
		table.insert(skyline, {
			name = if hero then "HeroTower" .. k else ringName .. "Building" .. k,
			ring = ringName,
			index = k,
			angle = angle,
			radius = def.radius,
			width = if hero then hero.width else def.widths[cycle],
			height = if hero then hero.height else def.heights[cycle],
			depth = if hero then hero.depth else def.depth,
			cframe = facingCFrame(def.radius, angle, 0),
			hero = if hero then hero.hero else nil,
			top = if hero then hero.top else nil,
		})
	end
end
CityLayout.skyline = skyline

-- Rowhouse infill: one narrow 20-tall connector in every gap of the mid ring
-- (between mid buildings k-1 and k, i.e. on the angles 15k), its front flush
-- with the mid ring fronts (r 220) so the ring reads as one street wall.
-- width = front chord between the neighbours' centers - their half widths - 4.
local MID_FRONT = MID_RING.radius - MID_RING.depth / 2
local ROWHOUSE = { depth = 18, height = 20, radius = MID_FRONT + 18 / 2 }
CityLayout.Rowhouse = ROWHOUSE
local rowhouses: { BuildingSpec } = {}
do
	local chord = 2 * MID_FRONT * math.sin(math.rad(MID_RING.step / 2))
	for k = 0, MID_RING.count - 1 do
		local leftIndex = (k - 1) % MID_RING.count -- building on the lower-angle side
		local wLeft = MID_RING.widths[leftIndex % #MID_RING.widths + 1]
		local wRight = MID_RING.widths[k % #MID_RING.widths + 1]
		local angle = (MID_RING.startAngle - MID_RING.step / 2 + MID_RING.step * k) % 360
		table.insert(rowhouses, {
			name = "Rowhouse" .. k,
			ring = "Mid",
			index = k,
			angle = angle,
			radius = ROWHOUSE.radius,
			width = chord - (wLeft + wRight) / 2 - 4,
			height = ROWHOUSE.height,
			depth = ROWHOUSE.depth,
			cframe = facingCFrame(ROWHOUSE.radius, angle, 0),
		})
	end
end
CityLayout.rowhouses = rowhouses

export type ShopSpec = {
	name: string,
	kind: string, -- "A" (one-storey boutique) | "B" (3-storey with rooftop billboard)
	gapIndex: number, -- 1-based gap (between zone gapIndex and gapIndex + 1)
	angle: number,
	radius: number,
	width: number,
	height: number,
	depth: number,
	slogan: string?, -- B only: rooftop billboard text
	accentIndex: number, -- 1..6 into the builder's saturated accent list
	cframe: CFrame,
}

local SHOP_A = { radius = 140, width = 24, height = 18, depth = 16 }
local SHOP_B = { radius = 170, width = 40, height = 28, depth = 22 }
CityLayout.ShopA = SHOP_A
CityLayout.ShopB = SHOP_B
local SHOP_A_NAMES = { "PIZZA", "DONUTS", "BOBA", "TACOS", "BAKERY", "SUSHI", "CAFE", "ICE CREAM" }
local SHOP_B_NAMES = { "ARCADE", "BANK", "GYM", "COMICS", "TOYS", "MUSIC", "HOTEL", "MALL" }
local SLOGANS = { "GET RICH!", "HUSTLE 24/7", "BE THE BOSS", "BIG MONEY BANK", "CASH CITY", "LEVEL UP!", "DREAM BIG", "$$$" }

local shops: { ShopSpec } = {}
for k, g in gapAngles do
	local nameA = SHOP_A_NAMES[(k - 1) % #SHOP_A_NAMES + 1]
	local nameB = SHOP_B_NAMES[(k - 1) % #SHOP_B_NAMES + 1]
	table.insert(shops, {
		name = nameA,
		kind = "A",
		gapIndex = k,
		angle = g,
		radius = SHOP_A.radius,
		width = SHOP_A.width,
		height = SHOP_A.height,
		depth = SHOP_A.depth,
		slogan = nil,
		accentIndex = (k - 1) % 6 + 1,
		cframe = facingCFrame(SHOP_A.radius, g, 0),
	})
	table.insert(shops, {
		name = nameB,
		kind = "B",
		gapIndex = k,
		angle = g,
		radius = SHOP_B.radius,
		width = SHOP_B.width,
		height = SHOP_B.height,
		depth = SHOP_B.depth,
		slogan = SLOGANS[(k - 1) % #SLOGANS + 1],
		accentIndex = (k + 2) % 6 + 1,
		cframe = facingCFrame(SHOP_B.radius, g, 0),
	})
end
CityLayout.shops = shops

export type AnchorSpec = {
	zoneId: string,
	order: number,
	angle: number,
	width: number,
	height: number,
	depth: number,
	cframe: CFrame, -- == Mechanics.zoneGroundCFrame(order) * CFrame.new(0, 0, 46)
}

local ANCHOR_OFFSET = 46 -- behind the pad (pad back edge is +32 in zone space)
CityLayout.AnchorOffset = ANCHOR_OFFSET
local anchors: { AnchorSpec } = {}
for i, zone in GameConfig.Zones do
	table.insert(anchors, {
		zoneId = zone.Id,
		order = zone.Order,
		angle = zoneAngles[i],
		width = 56,
		height = 30 + 4 * (zone.Order - 1),
		depth = 18,
		cframe = facingCFrame(ZONE_RADIUS + ANCHOR_OFFSET, zoneAngles[i], 0),
	})
end
CityLayout.anchors = anchors

-- Highest roof point of the skyline including roof props (antennas reach
-- ~+0.3H+11; landmark towers carry their own top).
local skylineTop = 0
for _, b in skyline do
	skylineTop = math.max(skylineTop, b.top or (b.height * 1.3 + 11))
end
CityLayout.skylineTop = skylineTop

-- Pocket trees + lamps behind the rowhouses (r 238 rowhouse backs .. 244
-- mid-ring backs, ~21 studs between the mid buildings): a tree in a planter
-- on the angles 30k, a lamp post on 15 + 30k, all at r 241.5.
local POCKET = { radius = 241.5, treeScale = 0.8, planterDiameter = 3.6 }
CityLayout.Pocket = POCKET
local pocketTrees: { Vector3 } = {}
local pocketLamps: { Vector3 } = {}
for k = 0, MID_RING.count - 1 do
	local angle = (MID_RING.startAngle - MID_RING.step / 2 + MID_RING.step * k) % 360
	local p = ringPos(POCKET.radius, angle, S.BlockGroundTop)
	if k % 2 == 0 then
		table.insert(pocketTrees, p)
	else
		table.insert(pocketLamps, p)
	end
end
CityLayout.pocketTrees = pocketTrees
CityLayout.pocketLamps = pocketLamps

----------------------------------------------------------------------
-- Footprints (solid things pedestrians / cars must avoid)
----------------------------------------------------------------------

export type Footprint = { name: string, cframe: CFrame, size: Vector3 }

local footprints: { Footprint } = {}
for _, b in skyline do
	table.insert(footprints, { name = b.name, cframe = b.cframe, size = Vector3.new(b.width + 3, b.height, b.depth + 2) })
end
for _, b in rowhouses do
	table.insert(footprints, { name = b.name, cframe = b.cframe, size = Vector3.new(b.width + 1, b.height, b.depth + 4) })
end
for _, shop in shops do
	table.insert(footprints, { name = "Shop" .. shop.name, cframe = shop.cframe, size = Vector3.new(shop.width + 1, shop.height, shop.depth + 4) })
end
for _, anchor in anchors do
	table.insert(footprints, { name = "Anchor" .. anchor.zoneId, cframe = anchor.cframe, size = Vector3.new(anchor.width + 3, anchor.height, anchor.depth + 1) })
end
for i, p in pocketTrees do
	local r = Vector3.new(p.X, 0, p.Z).Magnitude
	table.insert(footprints, { name = "PocketTree" .. i, cframe = facingCFrame(r, CityLayout.angleOf(p), 0), size = Vector3.new(POCKET.planterDiameter + 0.4, 6, POCKET.planterDiameter + 0.4) })
end
for i, p in pocketLamps do
	local r = Vector3.new(p.X, 0, p.Z).Magnitude
	table.insert(footprints, { name = "PocketLamp" .. i, cframe = facingCFrame(r, CityLayout.angleOf(p), 0), size = Vector3.new(2, 10, 2) })
end
for i, zone in GameConfig.Zones do
	table.insert(footprints, { name = "Pad" .. zone.Id, cframe = facingCFrame(ZONE_RADIUS, zoneAngles[i], 0), size = Vector3.new(PAD_HALF * 2, 1.5, PAD_HALF * 2) })
end
CityLayout.footprints = footprints

function CityLayout.isInFootprint(position: Vector3, margin: number?): boolean
	local m = margin or 0
	local flat = Vector3.new(position.X, 0, position.Z)
	for _, fp in footprints do
		local l = fp.cframe:PointToObjectSpace(flat)
		if math.abs(l.X) < fp.size.X / 2 + m and math.abs(l.Z) < fp.size.Z / 2 + m then
			return true
		end
	end
	return false
end

----------------------------------------------------------------------
-- Street furniture, traffic lights, bus stops
----------------------------------------------------------------------

local trafficLights = {}
for i, zone in GameConfig.Zones do
	-- zone-local (x = +12, z = -44): beside the crosswalk on the outer sidewalk
	table.insert(trafficLights, {
		zoneId = zone.Id,
		angle = zoneAngles[i],
		cframe = facingCFrame(ZONE_RADIUS, zoneAngles[i], S.OuterSidewalkTop) * CFrame.new(12, 0, -44),
	})
end
CityLayout.trafficLights = trafficLights

local BUS_STOP_GAPS = { 2, 6 } -- gap indices (angles 67.5 and 247.5 with the default ring)
local busGap: { [number]: boolean } = {}
local busStops = {}
for _, gapIndex in BUS_STOP_GAPS do
	if gapAngles[gapIndex] then
		busGap[gapIndex] = true
		table.insert(busStops, {
			name = "BusStop" .. gapIndex,
			angle = gapAngles[gapIndex],
			cframe = facingCFrame(109, gapAngles[gapIndex], S.OuterSidewalkTop),
		})
	end
end
CityLayout.busStops = busStops

-- Road-side zone signposts (built by MapBuilder into Ground): pole on the
-- outer sidewalk at r 108, zone axis + 12 deg; the board (local x -1.8 ..
-- +4.95 incl. its arrow tip, yawed -30 deg) points back toward the zone axis.
local SIGNPOST = { radius = 108, offset = 12, yaw = -30, boardFrom = -1.8, boardTo = 4.95 }
CityLayout.Signpost = SIGNPOST
local signposts = {}
for i, zone in GameConfig.Zones do
	local angle = zoneAngles[i] + SIGNPOST.offset
	local cf = facingCFrame(SIGNPOST.radius, angle, S.OuterSidewalkTop) * CFrame.Angles(0, math.rad(SIGNPOST.yaw), 0)
	table.insert(signposts, {
		zoneId = zone.Id,
		angle = angle,
		cframe = cf, -- pole base; board along local +X
		position = cf.Position,
		boardFrom = (cf * CFrame.new(SIGNPOST.boardFrom, 0, 0)).Position,
		boardTo = (cf * CFrame.new(SIGNPOST.boardTo, 0, 0)).Position,
	})
end
CityLayout.signposts = signposts

-- Per gap (degrees relative to the gap bisector g): street trees in planters at
-- g +- 7, a tall double lamp at g + 5; non-bus gaps add a hydrant (g + 2.5), a
-- trash can (g - 2.5) and a news box (g). All sit in r 105..111.5, inside the
-- walk loop. Every tall lamp carries zone-colored festival banners
-- (bannerZones = { lower-angle zone id, higher-angle zone id }).
local streetFurniture: { any } = {}
for k, g in gapAngles do
	local zoneLow = GameConfig.Zones[k].Id
	local zoneHigh = GameConfig.Zones[k % ZONE_COUNT + 1].Id
	table.insert(streetFurniture, { kind = "Planter", position = ringPos(108.5, g - 7, S.OuterSidewalkTop), radius = 2.8 })
	table.insert(streetFurniture, { kind = "Planter", position = ringPos(108.5, g + 7, S.OuterSidewalkTop), radius = 2.8 })
	table.insert(streetFurniture, {
		kind = "Lamp", position = ringPos(106, g + 5, S.OuterSidewalkTop), radius = 1,
		light = true, bannerZones = { zoneLow, zoneHigh },
	})
	if not busGap[k] then
		table.insert(streetFurniture, { kind = "Hydrant", position = ringPos(107, g + 2.5, S.OuterSidewalkTop), radius = 1 })
		table.insert(streetFurniture, { kind = "TrashCan", position = ringPos(107, g - 2.5, S.OuterSidewalkTop), radius = 1.1 })
		table.insert(streetFurniture, { kind = "NewsBox", position = ringPos(108, g, S.OuterSidewalkTop), radius = 1.2 })
	end
end
for _, stop in busStops do
	table.insert(streetFurniture, { kind = "BusStop", position = stop.cframe.Position, radius = 7.5 })
end
for _, light in trafficLights do
	table.insert(streetFurniture, { kind = "TrafficLight", position = light.cframe.Position, radius = 0.8 })
end

-- Boulevard rhythm: two more tall lamps per zone (no PointLight) at r 106 on
-- the furniture strip, zone axis +- 10.5 deg, both banners in that zone's
-- color. A spot within 2 studs (+ radii) of any furniture item or a signpost
-- board slides away from the axis in 0.5-deg steps (up to 14 deg), else
-- toward it (down to 8 deg); a spot that fits nowhere is skipped.
local TALL_LAMP = { radius = 106, offset = 10.5, maxOffset = 14, minOffset = 8, step = 0.5, clearance = 2, lampRadius = 1 }
CityLayout.TallLamp = TALL_LAMP
local function segmentDistanceXZ(p: Vector3, a: Vector3, b: Vector3): number
	local ab = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
	local ap = Vector3.new(p.X - a.X, 0, p.Z - a.Z)
	local t = math.clamp(ap:Dot(ab) / math.max(ab:Dot(ab), 1e-9), 0, 1)
	return (ap - ab * t).Magnitude
end
local function lampSpotFree(p: Vector3): boolean
	local need = TALL_LAMP.clearance + TALL_LAMP.lampRadius
	for _, item in streetFurniture do
		local o = item.position
		if Vector3.new(p.X - o.X, 0, p.Z - o.Z).Magnitude < need + item.radius then
			return false
		end
	end
	for _, post in signposts do
		if segmentDistanceXZ(p, post.boardFrom, post.boardTo) < need + 0.25 then
			return false
		end
	end
	return true
end
local zoneLamps = {}
for i, zone in GameConfig.Zones do
	for _, side in { -1, 1 } do
		local chosen: Vector3? = nil
		local offset = TALL_LAMP.offset
		while offset <= TALL_LAMP.maxOffset + 1e-6 do
			local p = ringPos(TALL_LAMP.radius, zoneAngles[i] + side * offset, S.OuterSidewalkTop)
			if lampSpotFree(p) then
				chosen = p
				break
			end
			offset += TALL_LAMP.step
		end
		offset = TALL_LAMP.offset - TALL_LAMP.step
		while not chosen and offset >= TALL_LAMP.minOffset - 1e-6 do
			local p = ringPos(TALL_LAMP.radius, zoneAngles[i] + side * offset, S.OuterSidewalkTop)
			if lampSpotFree(p) then
				chosen = p
			end
			offset -= TALL_LAMP.step
		end
		if chosen then
			table.insert(zoneLamps, {
				kind = "Lamp", position = chosen, radius = TALL_LAMP.lampRadius,
				light = false, bannerZones = { zone.Id, zone.Id }, zoneId = zone.Id,
			})
		end
	end
end
for _, lamp in zoneLamps do
	table.insert(streetFurniture, lamp)
end
CityLayout.streetFurniture = streetFurniture

-- Pocket parks on the gap bisectors between the shops (back r 181) and the
-- mid skyline ring (front r 216 incl. awnings).
local PARK = { radius = 200, width = 34, depth = 22, top = 0.3 }
CityLayout.Park = PARK
local parks = {}
local parkTrees = {}
for k, g in gapAngles do
	local cf = facingCFrame(PARK.radius, g, 0)
	table.insert(parks, { name = "Park" .. k, angle = g, cframe = cf, size = Vector3.new(PARK.width, PARK.top, PARK.depth) })
	for _, off in { Vector3.new(-11, 0, 4), Vector3.new(10, 0, -4), Vector3.new(3, 0, 7) } do
		table.insert(parkTrees, (cf * CFrame.new(off.X, PARK.top, off.Z)).Position)
	end
end
CityLayout.parks = parks
CityLayout.parkTrees = parkTrees

-- Gap-block dressing (every gap between two zones). Shop frames: local -Z
-- faces the plaza, +X points toward the lower-angle zone.
--   Café terrace on the pavement in front of each Shop A (r ~126.5, between
--   the outer curb r 122.5 and the shop front r 132): 2 tables under
--   umbrellas, a stool on each side of every table. The window-shopper spot
--   at Shop-A-local (8.5, -11) stays clear.
local CAFE = {
	tableX = { -8, 0.5 }, -- Shop-A-local x of the two tables (canopies 8 wide never overlap)
	z = -13.5, -- Shop-A-local z (in front of the shop)
	stoolOffset = 2.6, -- stools at table-local x = +-2.6
	stoolTop = 2.0, -- seat top, world Y
	tableTop = 3.2,
	canopyY = 7.4,
	canopyDiameter = 8,
	-- checkered patio rug under both tables and all 4 stools (Shop-A-local
	-- x -13.5..5, z -17..-8.5 = r ~123..131.5): clear of the door / shopper
	-- lane (x >= 7), the gap-tree planters (|x| >= 14.25) and the outer curb
	terrace = { x = -4.25, z = -12.75, width = 18.5, depth = 8.5, thickness = 0.08 },
}
CityLayout.Cafe = CAFE
local cafes = {}
local cafeSeats = {}
--   Street trees in round planters beside both shops: Shop-A-local x = +-16.5,
--   Shop-B-local x = +-25 (planter radius 2.5, collidable trunk at the center).
local GAP_TREE_X = { A = 16.5, B = 25 }
CityLayout.GapTreeX = GAP_TREE_X
local gapTrees: { Vector3 } = {}
for _, shop in shops do
	if shop.kind == "A" then
		for _, x in CAFE.tableX do
			local tableCF = shop.cframe * CFrame.new(x, 0, CAFE.z)
			table.insert(cafes, { gapIndex = shop.gapIndex, cframe = tableCF, position = tableCF.Position, radius = CAFE.canopyDiameter / 2 })
			for _, side in { -1, 1 } do
				local seat = tableCF * CFrame.new(side * CAFE.stoolOffset, 0, 0)
				local toTable = tableCF.Position - seat.Position
				table.insert(cafeSeats, {
					position = Vector3.new(seat.Position.X, CAFE.stoolTop, seat.Position.Z),
					facing = Vector3.new(toTable.X, 0, toTable.Z).Unit,
					gapIndex = shop.gapIndex,
				})
			end
		end
	end
	local treeX = if shop.kind == "A" then GAP_TREE_X.A else GAP_TREE_X.B
	for _, side in { -1, 1 } do
		local p = (shop.cframe * CFrame.new(side * treeX, 0, 0)).Position
		table.insert(gapTrees, Vector3.new(p.X, S.BlockGroundTop, p.Z))
	end
end
CityLayout.cafes = cafes
CityLayout.cafeSeats = cafeSeats
local cafeTerraces = {}
for _, shop in shops do
	if shop.kind == "A" then
		local T = CAFE.terrace
		table.insert(cafeTerraces, {
			gapIndex = shop.gapIndex,
			accentIndex = shop.accentIndex,
			cframe = shop.cframe * CFrame.new(T.x, S.BlockGroundTop + T.thickness / 2, T.z),
			size = Vector3.new(T.width, T.thickness, T.depth),
		})
	end
end
CityLayout.cafeTerraces = cafeTerraces
CityLayout.gapTrees = gapTrees

----------------------------------------------------------------------
-- Plaza: props (built by CityBuilder) + the wander area for pedestrians
----------------------------------------------------------------------

local PLAZA_TOP = S.PlazaTop
-- Food carts sit near the gap bisectors (>= 20 degrees off every zone axis and
-- off the spawn sightline); 155 would collide with the title billboard (157.5).
local CART_ANGLES = { 65, 200, 245, 335 }
local CART_KINDS = { "IceCream", "HotDog", "Popcorn", "Drinks" }
local plazaProps = {}
for i, a in CART_ANGLES do
	table.insert(plazaProps, { kind = CART_KINDS[i], position = ringPos(51, a, PLAZA_TOP), radius = 4.5, angle = a })
end
table.insert(plazaProps, { kind = "BalloonVendor", position = ringPos(36, 110, PLAZA_TOP), radius = 2.5, angle = 110 })
CityLayout.plazaProps = plazaProps

-- Raised round flower planters (islands that break up the plaza floor):
-- 9 wide, 2.4 tall, collidable; never on a zone axis, >= 8.5 studs off the
-- spawn -> Lemonade sightline, 250 deg / r 34 kept free for a street performer.
local PLAZA_PLANTERS = { { 36, 22.5 }, { 24, 112.5 }, { 24, 157.5 }, { 24, 202.5 }, { 36, 337.5 } }
local plazaPlanters = {}
for i, p in PLAZA_PLANTERS do
	table.insert(plazaPlanters, { position = ringPos(p[1], p[2], PLAZA_TOP), radius = 4.8, angle = p[2], colorIndex = i })
end
CityLayout.plazaPlanters = plazaPlanters

-- Obstacles inside the plaza (mirrors MapBuilder's plaza layout + plazaProps).
local plazaObstacles = {
	{ position = Vector3.new(0, PLAZA_TOP, 0), radius = 12.5 }, -- coin fountain
	{ position = ringPos(20, 0, PLAZA_TOP), radius = 9 }, -- spawn pad (12 x 12)
	{ position = ringPos(47, 157.5, PLAZA_TOP), radius = 12.5 }, -- title billboard
}
for i = 0, 5 do
	table.insert(plazaObstacles, { position = ringPos(44, 10 + i * 60, PLAZA_TOP), radius = 1.3 }) -- lamp posts
end
for _, a in { 55, 185, 300 } do
	table.insert(plazaObstacles, { position = ringPos(30, a, PLAZA_TOP), radius = 3.3 }) -- benches
end
for _, a in { 40, 100, 220, 280 } do
	table.insert(plazaObstacles, { position = ringPos(40, a, PLAZA_TOP), radius = 1.6 }) -- flower beds
end
for _, prop in plazaProps do
	table.insert(plazaObstacles, { position = prop.position, radius = prop.radius })
end
for _, planter in plazaPlanters do
	table.insert(plazaObstacles, { position = planter.position, radius = 5 })
end

export type WanderArea = {
	name: string,
	center: Vector3,
	minRadius: number,
	maxRadius: number,
	y: number,
	obstacles: { { position: Vector3, radius: number } },
}

local plazaArea: WanderArea = {
	name = "Plaza",
	center = Vector3.new(0, PLAZA_TOP, 0),
	minRadius = 14,
	maxRadius = 50,
	y = PLAZA_TOP,
	obstacles = plazaObstacles,
}
CityLayout.wanderAreas = { plazaArea }

function CityLayout.isPlazaPointFree(position: Vector3, clearance: number?): boolean
	local c = clearance or 1.5
	local flat = Vector3.new(position.X, 0, position.Z)
	local r = flat.Magnitude
	if r < plazaArea.minRadius or r > plazaArea.maxRadius then
		return false
	end
	for _, obstacle in plazaObstacles do
		local o = obstacle.position
		if (flat - Vector3.new(o.X, 0, o.Z)).Magnitude < obstacle.radius + c then
			return false
		end
	end
	return true
end

-- Window-shopping spots: 3 studs in front of each shop door, facing it.
local storefronts = {}
for _, shop in shops do
	local doorX = if shop.kind == "A" then 8.5 else 13
	local spot = shop.cframe * CFrame.new(doorX, 0, -shop.depth / 2 - 3)
	local door = shop.cframe * CFrame.new(doorX, 0, -shop.depth / 2)
	table.insert(storefronts, {
		name = shop.name,
		position = spot.Position,
		facing = (door.Position - spot.Position).Unit,
	})
end
CityLayout.storefronts = storefronts

----------------------------------------------------------------------
-- Surface height
----------------------------------------------------------------------

function CityLayout.surfaceY(position: Vector3): number
	local flat = Vector3.new(position.X, 0, position.Z)
	for _, a in zoneAngles do
		local u = ringPos(1, a, 0)
		local along = flat:Dot(u) - ZONE_RADIUS
		local side = -flat.X * u.Z + flat.Z * u.X
		if math.abs(along) <= PAD_HALF and math.abs(side) <= PAD_HALF then
			return 1.5
		end
	end
	local r = flat.Magnitude
	if r <= S.PlazaRadius then
		return S.PlazaTop
	elseif r <= S.PlazaTrimRadius then
		return S.PlazaTrimTop
	elseif r <= S.AsphaltInner then
		return S.InnerSidewalkTop
	elseif r <= S.AsphaltOuter then
		return S.AsphaltTop
	elseif r <= S.OuterSidewalkRadius then
		return S.OuterSidewalkTop
	elseif r <= S.OuterCurbRadius then
		return S.OuterCurbTop
	end
	-- pocket parks: lawn (PARK.top) inside a 0.6 white curb (PARK.top - 0.05)
	if r > PARK.radius - PARK.width and r < PARK.radius + PARK.width then
		for _, park in parks do
			local l = park.cframe:PointToObjectSpace(flat)
			local ax, az = math.abs(l.X), math.abs(l.Z)
			if ax <= PARK.width / 2 + 0.6 and az <= PARK.depth / 2 + 0.6 then
				return if ax <= PARK.width / 2 and az <= PARK.depth / 2 then PARK.top else PARK.top - 0.05
			end
		end
	end
	if r <= S.BlockGroundRadius then
		return S.BlockGroundTop
	elseif r <= S.BackAsphaltInner + S.BackEdgeWidth then
		return S.BackEdgeInnerTop
	elseif r <= S.BackAsphaltOuter then
		return S.BackAsphaltTop
	elseif r <= S.BackAsphaltOuter + S.BackEdgeWidth then
		return S.BackEdgeOuterTop
	end
	return 0
end

return CityLayout
