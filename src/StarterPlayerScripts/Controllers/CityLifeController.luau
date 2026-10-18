-- CityLifeController: the downtown's ambient life on the client: traffic on
-- the ring road (cars, taxis, a police car with a flashing lightbar, a bus,
-- an ice-cream van, a delivery truck) braking at crosswalk lights and for
-- players plus a taxi and a car on the Back Avenue, chibi citizens on every
-- sidewalk (two dog-walkers), 12 shoppers going in and out of the Shop A
-- doors with shopping bags, rush-hour groups of 3 on every zebra, people at
-- shop windows and café tables, customer queues (3, 4 at the Lemonade Stand)
-- buying at every hustle counter (coin pops), sitting on the zone seats and
-- browsing the props, the zones' hero props in motion (spinning lemon /
-- rocket / heart / burger / mini sneakers, a car rolling through the car
-- wash, two dogs running the agility course, the Stock Desk ticker chase and
-- the creator heartbeat), a plaza street act with a clapping crowd, a selfie
-- trio and chatting idlers, pigeons that scatter, a blimp, bird flocks,
-- drifting clouds, hot-air balloons, spinning rooftop coins / CitySpin models,
-- and the "city pulse" (marquee chase only on the zone anchor boards, the
-- plaza title billboard and the hero-tower billboards, breathing anchor
-- trims, rooftop aviation blinkers, breathing blade signs: local property
-- sets on the map's own neon, 10 Hz, restored when the city life stops).
--
-- Pure view layer, client-only. All the behaviour lives in the PURE shared
-- simulation (ReplicatedStorage/Shared/CityLifeSim over CityLayout), which the
-- offline render preview runs too. This shell only:
--   * builds the sim into the local-only Workspace folder "CityLife"
--     (every part Anchored, CanCollide / CanQuery / CanTouch false)
--   * binds the map once it exists (traffic light lamps are recolored LOCALLY
--     by light state; rooftop coins; parts tagged with the "CitySpin"
--     attribute; the zone customers, built once from the replicated zone
--     models - spots validated against their parts - into CityLife.Customers;
--     the zone life into CityLife.ZoneLife: non-colliding hero props spun
--     LOCALLY, never a collider or a hustle contract part)
--   * feeds player root positions + the camera position to the sim and moves
--     every changed part with ONE workspace:BulkMoveTo on ONE Heartbeat
--     (no Instance creation or table allocation per frame; distance LOD:
--     citizens animate every frame within 140 studs, every 2nd frame to 260,
--     rest pose every 4th frame to 400, parked beyond; the city pulse runs
--     at 10 Hz inside sim:step for map parts within 500 studs; see CityLifeSim)
--   * on stop (folder removed / sim error) disconnects and calls
--     sim:unbindMap(), which restores every map color / transparency the
--     pulse changed and puts the spun zone props back in their built pose

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local CityLifeSim = require(sharedFolder:WaitForChild("CityLifeSim"))

local FOLDER_NAME = "CityLife"
local MAP_WAIT = 60 -- seconds to wait for Workspace.SideHustleMap

local CityLifeController = {}

local started = false
local sim = nil
local heartbeat: RBXScriptConnection? = nil

-- Player HumanoidRootParts (rebuilt on character events only, never per frame)
local rootByPlayer: { [Player]: BasePart } = {}
local roots: { BasePart } = {}
local playerConnections: { [Player]: { RBXScriptConnection } } = {}

local function rebuildRoots()
	table.clear(roots)
	for _, root in rootByPlayer do
		table.insert(roots, root)
	end
end

local function trackCharacter(player: Player, character: Model)
	local root = character:WaitForChild("HumanoidRootPart", 10)
	if root and root:IsA("BasePart") and player.Character == character then
		rootByPlayer[player] = root
		rebuildRoots()
	end
end

local function onPlayerAdded(player: Player)
	if playerConnections[player] then
		return
	end
	playerConnections[player] = {
		player.CharacterAdded:Connect(function(character)
			task.spawn(trackCharacter, player, character)
		end),
		player.CharacterRemoving:Connect(function()
			rootByPlayer[player] = nil
			rebuildRoots()
		end),
	}
	if player.Character then
		task.spawn(trackCharacter, player, player.Character)
	end
end

local function onPlayerRemoving(player: Player)
	local connections = playerConnections[player]
	if connections then
		for _, connection in connections do
			connection:Disconnect()
		end
		playerConnections[player] = nil
	end
	rootByPlayer[player] = nil
	rebuildRoots()
end

local function makeFolder(): Folder
	local existing = workspace:FindFirstChild(FOLDER_NAME)
	if existing then
		existing:Destroy() -- stale copy (controller re-run); the sim owns a fresh one
	end
	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = workspace
	return folder
end

local function bindMapWhenReady()
	if not game:IsLoaded() then
		game.Loaded:Wait() -- initial replication of the map (StreamingEnabled is off)
	end
	local map = workspace:WaitForChild("SideHustleMap", MAP_WAIT)
	if not map then
		warn("[CityLifeController] SideHustleMap never appeared; traffic lights and rooftop coins stay static")
		return
	end
	local city = map:WaitForChild("City", 30)
	if city then
		city:WaitForChild("Street", 15)
		city:WaitForChild("Skyline", 15)
	end
	map:WaitForChild("Zones", 15) -- the zone customers are planned from the zone models
	if sim then
		sim:bindMap(map)
	end
end

function CityLifeController.start()
	if started then
		return
	end
	started = true

	local folder = makeFolder()
	sim = CityLifeSim.new(folder)

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end

	task.spawn(bindMapWhenReady)

	local outParts, outCFrames = sim.outParts, sim.outCFrames
	local playerPos = sim.playerPos
	local bulkMode = Enum.BulkMoveMode.FireCFrameChanged
	local function stop()
		if heartbeat then
			heartbeat:Disconnect()
			heartbeat = nil
		end
		-- the city pulse recolors map neon locally: put the originals back
		pcall(sim.unbindMap, sim)
	end
	heartbeat = RunService.Heartbeat:Connect(function(dt: number)
		if folder.Parent == nil then
			stop()
			return
		end
		local count = 0
		for i = 1, #roots do
			local root = roots[i]
			if root.Parent ~= nil then
				count += 1
				playerPos[count] = root.Position
			end
		end
		sim.playerCount = count

		local camera = workspace.CurrentCamera
		local ok, n = pcall(sim.step, sim, dt, if camera then camera.CFrame.Position else nil)
		if not ok then
			warn("[CityLifeController] city life stopped: " .. tostring(n))
			stop()
			return
		end
		if n > 0 then
			workspace:BulkMoveTo(outParts, outCFrames, bulkMode)
		end
	end)
end

return CityLifeController
