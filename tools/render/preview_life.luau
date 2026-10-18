-- Render preview of the client city life (traffic, pedestrians, shoppers,
-- zone customers, zone life, plaza life, sky, city pulse). export_map.luau /
-- check_map.luau call the returned function after MapBuilder.build(). It runs
-- the SAME simulation the client runs (Shared/CityLifeSim, which builds every
-- rig with ChibiRig / VehicleRig and places it on the CityLayout sidewalks,
-- lanes, back lanes and Back Avenue sidewalks, crosswalks, café seats, shop
-- doors and plaza spots, and - from the real zone models - the customer
-- queues, sitters and browsers at every hustle counter plus the zone life:
-- the hero-prop spinners, the car-wash car and the agility dogs), warms it up
-- for 4.5 s, then writes one full STATIC snapshot into Workspace.LifePreview:
-- 20 vehicles (incl. the police car, lightbar flashing), 107 citizens
-- (sidewalk walkers incl. 2 dog-walkers - OuterA and the Back Avenue - 12
-- shoppers, 24 rush-hour crossers, plaza idlers, storefront loiterers, café
-- sitters, the street act + crowd, the fountain selfie trio, 2 window
-- washers on their cradles), 33 zone customers + their coins, the car-wash
-- car and 2 agility dogs, 3 pigeon flocks, the blimp, bird flocks, 12
-- clouds, 5 hot-air balloons and the rooftop coins. The snapshot is timed
-- for the render views: a shopper glances at the PIZZA window (gap) and one
-- walks down the DONUTS frontage with its bag (r5_sidewalk_tan), the yellow
-- car rolls half out of the car wash (r4_zone_top), an agility dog hops into
-- the first hoop (r4_dog_inside: the Dog Walking queue in front of that
-- camera hides the rest of the course), the lemon / rocket / heart / burger
-- / mini sneakers have
-- turned; six zebras have their group of 3 mid-road with taxis / cars held
-- at the red lights (Lemonade in the spawn view, Car Wash in outward,
-- Content Creator in r3_skyline_eye), the Sneaker Street (r2_gate) and
-- Startup HQ (r4_ring_eye) groups wait at the outer curb, every zone queue
-- is full, the street performer is mid head spin, and the final posed step
-- also applies the city pulse to the map (an anchor marquee bar lit in each
-- zone board's color with the rest dimmed, the title / hero-tower chase,
-- breathing anchor trims, the ticker chase, the heartbeat, blinker /
-- blade-sign transparencies), so the export shows it.
--   ctx = { Workspace, require, Shared, REPO }

local WARM_UP_SECONDS = 4.5 -- crossers mid-street, cars queued at the lights, a coin mid-pop
local STEP = 1 / 30

return function(ctx)
	local CityLifeSim = ctx.require(ctx.Shared.CityLifeSim)

	local existing = ctx.Workspace:FindFirstChild("LifePreview")
	if existing then
		existing:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = "LifePreview"
	folder.Parent = ctx.Workspace

	local sim = CityLifeSim.new(folder, "High") -- the default (desktop) crowd the players see
	local map = ctx.Workspace:FindFirstChild("SideHustleMap")
	if map then
		-- traffic light colors, rooftop coins, CitySpin models, the zone
		-- customers and the zone life (validated against the real zone parts),
		-- the city pulse, as on the client
		sim:bindMap(map)
	end

	sim:advance(WARM_UP_SECONDS, STEP)
	local n = sim:step(STEP, nil, true) -- pose everything (no LOD)
	for i = 1, n do
		sim.outParts[i].CFrame = sim.outCFrames[i]
	end

	local counts = sim:getCounts()
	print(("preview_life: %d citizens (%d walkers, %d shoppers, %d crossers), %d customers (%d parts), %d vehicles (police %d), zone life %d spin groups / car %d / %d dogs (%d parts, %d skipped), %d window washers, %d birds, %d pigeons, %d clouds, %d balloons, %d coins, pulse %d frames (%d anchor) / %d trims / %d tickers / %d tips / %d blades, %d parts (t=%.1fs)"):format(
		counts.citizens, counts.walkers, counts.shoppers, counts.crossers, counts.customers, counts.customerParts, counts.vehicles, counts.police,
		counts.zoneSpinGroups, counts.washCar, counts.courseDogs, counts.zoneLifeParts, counts.zoneSkipped, counts.washers, counts.birds, counts.pigeons,
		counts.clouds, counts.balloons, counts.coins, counts.pulseFrames, counts.anchorFrames, counts.pulseTrims, counts.tickerGroups, counts.pulseTips,
		counts.pulseBlades, counts.parts, sim.t))
	return sim
end
