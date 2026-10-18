-- ZoneGateController: LOCAL-ONLY gate visuals for the zones the local player
-- has unlocked by level (v2: zone unlocked <=> snapshot.Level >= zone.UnlockLevel).
-- The server stays authoritative (it rejects hustles in locked zones), so these
-- are pure view changes: a walk-through GateWall and a hidden sign billboard.
-- Watches DataSync and re-applies on every snapshot, which also restores the
-- gates when the level drops after a rebirth. No UnlockPrompt exists in v2.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))

type GateRefs = {
	zoneId: string,
	unlockLevel: number,
	gateWall: BasePart,
	originalTransparency: number,
	originalCanCollide: boolean,
	billboards: { BillboardGui },
}

local gates: { [string]: GateRefs } = {}
local registering: { [string]: boolean } = {}
local currentLevel: number? = nil -- nil until the first DataSync snapshot

local ZoneGateController = {}

local function applyGate(refs: GateRefs)
	local level = currentLevel
	if level == nil then
		return -- never touch gates before the first snapshot
	end
	local gateWall = refs.gateWall
	if not gateWall:IsDescendantOf(workspace) then
		return -- streamed out / rebuilt; registration will pick it back up
	end
	if level >= refs.unlockLevel then
		-- Unlocked: open the gate locally.
		gateWall.CanCollide = false
		gateWall.Transparency = 1
		for _, billboard in refs.billboards do
			billboard.Enabled = false
		end
	else
		-- Locked (including re-locked after rebirth): restore the server look.
		gateWall.CanCollide = refs.originalCanCollide
		gateWall.Transparency = refs.originalTransparency
		for _, billboard in refs.billboards do
			billboard.Enabled = true
		end
	end
end

local function applyAll()
	for _, refs in gates do
		applyGate(refs)
	end
end

-- The gate sign's BillboardGui lives on SignPart inside the Gate model (map
-- contract). Scan descendants with a short retry window in case it appears late.
local function findGateBillboards(gate: Instance): { BillboardGui }
	local deadline = os.clock() + 5
	while true do
		local found: { BillboardGui } = {}
		for _, descendant in gate:GetDescendants() do
			if descendant:IsA("BillboardGui") then
				table.insert(found, descendant)
			end
		end
		if #found > 0 or os.clock() > deadline then
			return found
		end
		task.wait(0.25)
	end
end

local function registerZone(zoneModel: Instance)
	local zoneId = zoneModel.Name
	local zoneDef = GameConfig.getZone(zoneId)
	if not zoneDef or zoneDef.UnlockLevel <= 1 then
		return -- not a zone, or the starting zone (no gate)
	end
	local existing = gates[zoneId]
	if existing and existing.gateWall:IsDescendantOf(workspace) then
		return -- already registered and alive
	end
	if registering[zoneId] then
		return
	end
	registering[zoneId] = true

	local gate = zoneModel:WaitForChild("Gate", 20)
	if not gate then
		registering[zoneId] = nil
		warn(("[ZoneGateController] Zone %s has no Gate model"):format(zoneId))
		return
	end
	local gateWall = gate:WaitForChild("GateWall", 20)
	if not gateWall or not gateWall:IsA("BasePart") then
		registering[zoneId] = nil
		warn(("[ZoneGateController] Gate for %s has no GateWall part"):format(zoneId))
		return
	end

	local billboards = findGateBillboards(gate)
	registering[zoneId] = nil

	gates[zoneId] = {
		zoneId = zoneId,
		unlockLevel = zoneDef.UnlockLevel,
		gateWall = gateWall,
		originalTransparency = gateWall.Transparency,
		originalCanCollide = gateWall.CanCollide,
		billboards = billboards,
	}
	applyGate(gates[zoneId])
end

function ZoneGateController.start(): ()
	-- Keep the player's level in sync with the server.
	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("Remotes")
		local dataSync = remotes:WaitForChild("DataSync")
		dataSync.OnClientEvent:Connect(function(snapshot)
			if type(snapshot) ~= "table" or type(snapshot.Level) ~= "number" then
				return
			end
			currentLevel = snapshot.Level
			applyAll()
		end)
	end)

	-- Register every gated zone's gate, including ones that show up late.
	task.spawn(function()
		local map = workspace:WaitForChild("SideHustleMap", 60)
		if not map then
			warn("[ZoneGateController] Workspace.SideHustleMap never appeared")
			return
		end
		local zonesFolder = map:WaitForChild("Zones", 30)
		if not zonesFolder then
			warn("[ZoneGateController] SideHustleMap.Zones never appeared")
			return
		end
		zonesFolder.ChildAdded:Connect(function(child)
			task.spawn(registerZone, child)
		end)
		for _, child in zonesFolder:GetChildren() do
			task.spawn(registerZone, child)
		end
	end)
end

return ZoneGateController
