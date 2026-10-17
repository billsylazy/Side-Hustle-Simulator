-- ZoneGateController: LOCAL-ONLY gate visuals for the local player's unlocked
-- zones. The server stays authoritative (it rejects hustles in locked zones),
-- so these are pure view changes: walk-through walls, hidden signs/prompts.
-- Watches DataSync and re-applies on every snapshot, which also restores
-- gates for zones re-locked by rebirth (UnlockedZones shrinks).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))

type GateRefs = {
	zoneId: string,
	gateWall: BasePart,
	originalTransparency: number,
	originalCanCollide: boolean,
	billboard: BillboardGui?,
	prompt: ProximityPrompt?,
}

local gates: { [string]: GateRefs } = {}
local unlockedSet: { [string]: boolean } = {}
local hasData = false -- never touch gates before the first DataSync snapshot

local ZoneGateController = {}

local function applyGate(refs: GateRefs)
	if not hasData then
		return
	end
	local gateWall = refs.gateWall
	if not gateWall:IsDescendantOf(workspace) then
		return -- streamed out / rebuilt; registration will pick it back up
	end
	if unlockedSet[refs.zoneId] then
		-- Unlocked: open the gate locally.
		gateWall.CanCollide = false
		gateWall.Transparency = 1
		if refs.billboard then
			refs.billboard.Enabled = false
		end
		if refs.prompt then
			refs.prompt.Enabled = false
		end
	else
		-- Locked (including re-locked after rebirth): restore the server look.
		gateWall.CanCollide = refs.originalCanCollide
		gateWall.Transparency = refs.originalTransparency
		if refs.billboard then
			refs.billboard.Enabled = true
		end
		if refs.prompt then
			refs.prompt.Enabled = true
		end
	end
end

local function applyAll()
	for _, refs in gates do
		applyGate(refs)
	end
end

-- The gate sign's BillboardGui and the "UnlockPrompt" ProximityPrompt live on
-- parts inside the Gate model (SignPart / PromptPart per the map contract).
-- Scan descendants with a short retry window in case they appear late.
local function findGatePieces(gate: Instance): (BillboardGui?, ProximityPrompt?)
	local billboard: BillboardGui? = nil
	local prompt: ProximityPrompt? = nil
	local deadline = os.clock() + 5
	while true do
		for _, descendant in gate:GetDescendants() do
			if billboard == nil and descendant:IsA("BillboardGui") then
				billboard = descendant
			elseif prompt == nil and descendant:IsA("ProximityPrompt") and descendant.Name == "UnlockPrompt" then
				prompt = descendant
			end
		end
		if (billboard and prompt) or os.clock() > deadline then
			break
		end
		task.wait(0.25)
	end
	return billboard, prompt
end

local function registerZone(zoneModel: Instance)
	local zoneId = zoneModel.Name
	local zoneDef = GameConfig.getZone(zoneId)
	if not zoneDef or zoneDef.UnlockCost <= 0 then
		return -- not a zone, or the starting zone (no gate)
	end
	local existing = gates[zoneId]
	if existing and existing.gateWall:IsDescendantOf(workspace) then
		return -- already registered and alive
	end

	local gate = zoneModel:WaitForChild("Gate", 20)
	if not gate then
		warn(("[ZoneGateController] Zone %s has no Gate model"):format(zoneId))
		return
	end
	local gateWall = gate:WaitForChild("GateWall", 20)
	if not gateWall or not gateWall:IsA("BasePart") then
		warn(("[ZoneGateController] Gate for %s has no GateWall part"):format(zoneId))
		return
	end

	local billboard, prompt = findGatePieces(gate)

	gates[zoneId] = {
		zoneId = zoneId,
		gateWall = gateWall,
		originalTransparency = gateWall.Transparency,
		originalCanCollide = gateWall.CanCollide,
		billboard = billboard,
		prompt = prompt,
	}
	applyGate(gates[zoneId])
end

function ZoneGateController.start()
	-- Keep the unlocked-zone set in sync with the server.
	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("Remotes")
		local dataSync = remotes:WaitForChild("DataSync")
		dataSync.OnClientEvent:Connect(function(snapshot)
			if type(snapshot) ~= "table" or type(snapshot.UnlockedZones) ~= "table" then
				return
			end
			local newSet: { [string]: boolean } = {}
			for _, zoneId in snapshot.UnlockedZones do
				if type(zoneId) == "string" then
					newSet[zoneId] = true
				end
			end
			unlockedSet = newSet
			hasData = true
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
