-- ShopController (LocalScript inside ShopGui)
-- Refreshes upgrade/crate cards from DataSync snapshots, fires BuyUpgrade /
-- HireWorker, sparkles on upgrade level-ups, and bounces the panel open.
-- The client only displays and asks; the server validates every purchase.
-- See ARCHITECTURE.md "UI contract".

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local FormatNumber = require(Shared:WaitForChild("FormatNumber"))
local ButtonFX = require(Shared:WaitForChild("ButtonFX"))
local ClientEffects = require(Shared:WaitForChild("ClientEffects"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local DataSync = Remotes:WaitForChild("DataSync")
local BuyUpgrade = Remotes:WaitForChild("BuyUpgrade")
local HireWorker = Remotes:WaitForChild("HireWorker")
local WorkerHired = Remotes:WaitForChild("WorkerHired")

local gui = script.Parent
local main = gui:WaitForChild("Main")
local openScale = main:WaitForChild("OpenScale")
local body = main:WaitForChild("Body")
local items = body:WaitForChild("Items")
local upgradeGrid = items:WaitForChild("UpgradeGrid")
local crateGrid = items:WaitForChild("CrateGrid")
local closeButton = main:WaitForChild("CloseButton")

local UPGRADE_IDS = { "HustlePower", "WorkerEfficiency", "WalkSpeed", "WorkerSlots" }
local CRATE_IDS = { "StarterCrate", "ProCrate", "EliteCrate" }

local AFFORD_COLOR = Color3.fromRGB(255, 255, 255) -- gradient shows at full strength
local LOCKED_COLOR = Color3.fromRGB(135, 135, 145) -- grays the green gradient out

----------------------------------------------------------------------
-- Card lookup tables (cached once; the layout is static in the spec)
----------------------------------------------------------------------

type UpgradeCard = {
	card: Frame,
	level: TextLabel,
	buyButton: TextButton,
	price: TextLabel,
}

type CrateCard = {
	card: Frame,
	odds: TextLabel,
	hireButton: TextButton,
	price: TextLabel,
}

local upgradeCards: { [string]: UpgradeCard } = {}
for _, id in UPGRADE_IDS do
	local card = upgradeGrid:WaitForChild(id)
	local buyButton = card:WaitForChild("BuyButton")
	upgradeCards[id] = {
		card = card,
		level = card:WaitForChild("Level"),
		buyButton = buyButton,
		price = buyButton:WaitForChild("Price"),
	}
end

local crateCards: { [string]: CrateCard } = {}
for _, id in CRATE_IDS do
	local card = crateGrid:WaitForChild(id)
	local hireButton = card:WaitForChild("HireButton")
	crateCards[id] = {
		card = card,
		odds = card:WaitForChild("Odds"),
		hireButton = hireButton,
		price = hireButton:WaitForChild("Price"),
	}
end

----------------------------------------------------------------------
-- Crate odds text, computed from GameConfig.WorkerCrates[id].Weights
----------------------------------------------------------------------

local function oddsText(crateId: string): string
	local crate = GameConfig.WorkerCrates[crateId]
	if not crate then
		return ""
	end
	local total = 0
	for _, weight in crate.Weights do
		total += weight
	end
	if total <= 0 then
		return ""
	end
	local parts = {}
	for _, rarity in GameConfig.WorkerRarities do
		local weight = crate.Weights[rarity.Id]
		if weight and weight > 0 then
			local percent = weight / total * 100
			local percentText = if percent == math.floor(percent)
				then tostring(math.floor(percent))
				else string.format("%.1f", percent)
			table.insert(parts, rarity.Name .. " " .. percentText .. "%")
		end
	end
	return table.concat(parts, " / ")
end

for id, entry in crateCards do
	entry.odds.Text = oddsText(id)
end

----------------------------------------------------------------------
-- Refresh from DataSync snapshots
----------------------------------------------------------------------

local lastLevels: { [string]: number } = {}
local firstSnapshot = true

local function setAffordable(button: TextButton, affordable: boolean)
	button.BackgroundColor3 = if affordable then AFFORD_COLOR else LOCKED_COLOR
end

local function refresh(snapshot: { [string]: any })
	local cash = tonumber(snapshot.Cash) or 0
	local upgrades = if typeof(snapshot.Upgrades) == "table" then snapshot.Upgrades else {}

	for _, id in UPGRADE_IDS do
		local entry = upgradeCards[id]
		local def = GameConfig.Upgrades[id]
		if not entry or not def then
			continue
		end
		local level = tonumber(upgrades[id]) or 0
		entry.level.Text = "Lv " .. level .. "/" .. def.MaxLevel

		local cost = GameConfig.getUpgradeCost(id, level)
		if cost == nil then
			-- Maxed out: show MAX and stop accepting taps.
			entry.price.Text = "MAX"
			entry.buyButton.Active = false
			entry.buyButton.AutoButtonColor = false
			setAffordable(entry.buyButton, false)
		else
			entry.price.Text = FormatNumber.money(cost)
			entry.buyButton.Active = true
			entry.buyButton.AutoButtonColor = true
			setAffordable(entry.buyButton, cash >= cost)
		end

		-- Juice when a DataSync shows this upgrade's level went up.
		local previous = lastLevels[id]
		if not firstSnapshot and previous ~= nil and level > previous then
			ClientEffects.sparkle(entry.card)
			ClientEffects.playSound("LevelUp")
		end
		lastLevels[id] = level
	end

	for _, id in CRATE_IDS do
		local entry = crateCards[id]
		local crate = GameConfig.WorkerCrates[id]
		if not entry or not crate then
			continue
		end
		entry.price.Text = FormatNumber.money(crate.Cost)
		setAffordable(entry.hireButton, cash >= crate.Cost)
	end

	firstSnapshot = false
end

DataSync.OnClientEvent:Connect(function(snapshot)
	if typeof(snapshot) ~= "table" then
		return
	end
	refresh(snapshot)
end)

-- Crate-open juice: the server confirms a hire with the full WorkerEntry.
WorkerHired.OnClientEvent:Connect(function(worker)
	if typeof(worker) ~= "table" then
		return
	end
	local entry = if typeof(worker.Crate) == "string" then crateCards[worker.Crate] else nil
	if entry then
		ClientEffects.sparkle(entry.card)
	end
	ClientEffects.playSound("Hire")
end)

----------------------------------------------------------------------
-- Buttons
----------------------------------------------------------------------

for id, entry in upgradeCards do
	ButtonFX.attach(entry.buyButton)
	entry.buyButton.Activated:Connect(function()
		BuyUpgrade:FireServer(id)
	end)
end

for id, entry in crateCards do
	ButtonFX.attach(entry.hireButton)
	entry.hireButton.Activated:Connect(function()
		HireWorker:FireServer(id)
	end)
end

ButtonFX.attach(closeButton)
closeButton.Activated:Connect(function()
	gui.Enabled = false
end)

----------------------------------------------------------------------
-- Open bounce: watch Enabled, tween the UIScale 0.6 -> 1 (Back)
----------------------------------------------------------------------

gui:GetPropertyChangedSignal("Enabled"):Connect(function()
	if gui.Enabled then
		openScale.Scale = 0.6
		TweenService:Create(
			openScale,
			TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Scale = 1 }
		):Play()
	else
		openScale.Scale = 1 -- reset so a disabled panel never keeps a mid-tween scale
	end
end)
