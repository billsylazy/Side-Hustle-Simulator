-- HoldPromptController: makes each Hold zone's hold last the player's current
-- cooldown, LOCALLY. The server prompt carries the shortest possible hold
-- (zone.HoldDuration = the cooldown at max Speed); here every Hold prompt is
-- stretched to Mechanics.cooldownFor(zone, upgrades), so a completed hold is
-- never inside the server cooldown (no silently eaten holds) and the zone's
-- Speed upgrade visibly shortens the hold. The server still enforces the
-- cooldown itself; this is purely about the player's local prompt.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local Mechanics = require(Shared:WaitForChild("Mechanics"))

local WAIT_TIMEOUT = 20

local prompts: { [string]: ProximityPrompt } = {} -- zoneId -> HustlePrompt
local lastUpgrades: any = nil

local HoldPromptController = {}

local function holdFor(zone: GameConfig.ZoneDef): number
	return math.max(zone.HoldDuration, Mechanics.cooldownFor(zone, lastUpgrades))
end

local function apply(zoneId: string)
	local prompt = prompts[zoneId]
	local zone = GameConfig.getZone(zoneId)
	if not prompt or not zone or lastUpgrades == nil then
		return
	end
	local hold = holdFor(zone)
	if math.abs(prompt.HoldDuration - hold) > 1e-3 then
		prompt.HoldDuration = hold
	end
end

local function registerZone(zoneModel: Instance)
	local zone = GameConfig.getZone(zoneModel.Name)
	if not zone or zone.Mechanic ~= "Hold" or prompts[zone.Id] then
		return
	end
	task.spawn(function()
		local station = zoneModel:WaitForChild("HustleStation", WAIT_TIMEOUT)
		local promptPart = station and station:WaitForChild("PromptPart", WAIT_TIMEOUT)
		local prompt = promptPart and promptPart:WaitForChild("HustlePrompt", WAIT_TIMEOUT)
		if not prompt or not prompt:IsA("ProximityPrompt") then
			warn("[HoldPromptController] No HustlePrompt for " .. zone.Id)
			return
		end
		prompts[zone.Id] = prompt
		apply(zone.Id)
	end)
end

function HoldPromptController.start()
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local dataSync = remotes:WaitForChild("DataSync") :: RemoteEvent

	dataSync.OnClientEvent:Connect(function(snapshot: any)
		if typeof(snapshot) ~= "table" or typeof(snapshot.Upgrades) ~= "table" then
			return
		end
		lastUpgrades = snapshot.Upgrades
		for zoneId in prompts do
			apply(zoneId)
		end
	end)

	task.spawn(function()
		local map = workspace:WaitForChild("SideHustleMap", 60)
		local zones = map and map:WaitForChild("Zones", 30)
		if not zones then
			warn("[HoldPromptController] SideHustleMap.Zones not found")
			return
		end
		for _, zoneModel in zones:GetChildren() do
			registerZone(zoneModel)
		end
		zones.ChildAdded:Connect(registerZone)
	end)
end

return HoldPromptController
