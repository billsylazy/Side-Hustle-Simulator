-- ShopController (LocalScript inside ShopGui) — v2
-- PERKS (WalkSpeed / WorkerSlots / WorkerEfficiency, order GameConfig.PerkOrder)
-- and HIRE WORKERS (StarterCrate / ProCrate / EliteCrate, order GameConfig.CrateOrder).
--   DataSync     -> cash pill, perk levels "Lv 2/8", prices (MAX when maxed),
--                   buttons grayed when the snapshot's Cash can't afford them
--   BuyButton    -> BuyPerk(perkId)        HireButton -> HireWorker(crateId)
--   WorkerHired  -> sparkle the crate card + "Hire" sound
--   perk level up (seen in DataSync) -> sparkle + "LevelUp" sound
-- The client only displays and asks; UpgradeService / WorkerService validate
-- every purchase (cost, level cap, cash) and answer with Toasts on failure.
-- See ARCHITECTURE.md "UI contract".

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local FormatNumber = require(Shared:WaitForChild("FormatNumber"))
local ButtonFX = require(Shared:WaitForChild("ButtonFX"))
local ClientEffects = require(Shared:WaitForChild("ClientEffects"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local DataSync = Remotes:WaitForChild("DataSync") :: RemoteEvent
local BuyPerk = Remotes:WaitForChild("BuyPerk") :: RemoteEvent
local HireWorker = Remotes:WaitForChild("HireWorker") :: RemoteEvent
local WorkerHired = Remotes:WaitForChild("WorkerHired") :: RemoteEvent

local gui = script.Parent :: ScreenGui
local main = gui:WaitForChild("Main")
local openScale = main:WaitForChild("OpenScale") :: UIScale
local body = main:WaitForChild("Body")
local items = body:WaitForChild("Items") :: ScrollingFrame
local perkGrid = items:WaitForChild("PerkGrid")
local crateGrid = items:WaitForChild("CrateGrid")
local closeButton = main:WaitForChild("CloseButton") :: GuiButton
local cashAmount = main:WaitForChild("CashPill"):WaitForChild("Amount") :: TextLabel

local WHITE = Color3.fromRGB(255, 255, 255) -- gradient shows at full strength
local UNAFFORDABLE = Color3.fromRGB(135, 135, 145) -- multiplies the gradient toward gray
local GREEN_SEQUENCE = ColorSequence.new(Color3.fromRGB(71, 198, 78), Color3.fromRGB(42, 147, 42)) -- #47c64e -> #2a932a
local GOLD_SEQUENCE = ColorSequence.new(Color3.fromRGB(255, 212, 31), Color3.fromRGB(255, 123, 34)) -- #ffd41f -> #ff7b22

----------------------------------------------------------------------
-- Card lookup tables (cached once; the layout is static in the spec)
----------------------------------------------------------------------

type PerkCard = {
	card: GuiObject,
	level: TextLabel,
	buyButton: TextButton,
	gradient: UIGradient?,
	price: TextLabel,
}

type CrateCard = {
	card: GuiObject,
	hireButton: TextButton,
	gradient: UIGradient?,
	price: TextLabel,
}

local perkCards: { [string]: PerkCard } = {}
for index, perkId in GameConfig.PerkOrder do
	local def = GameConfig.Perks[perkId]
	local card = perkGrid:WaitForChild(perkId) :: GuiObject
	local buyButton = card:WaitForChild("BuyButton") :: TextButton
	card.LayoutOrder = index
	-- Static text comes from GameConfig so balance edits never need a UI rebuild.
	if def then
		local nameLabel = card:WaitForChild("Name") :: TextLabel
		local descLabel = card:WaitForChild("Desc") :: TextLabel
		nameLabel.Text = def.Name
		descLabel.Text = def.Description
	end
	perkCards[perkId] = {
		card = card,
		level = card:WaitForChild("Level") :: TextLabel,
		buyButton = buyButton,
		gradient = buyButton:FindFirstChildOfClass("UIGradient"),
		price = buyButton:WaitForChild("Price") :: TextLabel,
	}
end

-- "Intern 60%\nEmployee 28%\nManager 10%\nCEO 2%" from the crate weights.
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
	local lines = {}
	for _, rarity in GameConfig.WorkerRarities do
		local weight = crate.Weights[rarity.Id]
		if weight and weight > 0 then
			local percent = weight / total * 100
			local percentText = if percent == math.floor(percent)
				then tostring(math.floor(percent))
				else string.format("%.1f", percent)
			table.insert(lines, rarity.Name .. " " .. percentText .. "%")
		end
	end
	return table.concat(lines, "\n")
end

local crateCards: { [string]: CrateCard } = {}
for index, crateId in GameConfig.CrateOrder do
	local crate = GameConfig.WorkerCrates[crateId]
	local card = crateGrid:WaitForChild(crateId) :: GuiObject
	local hireButton = card:WaitForChild("HireButton") :: TextButton
	local price = hireButton:WaitForChild("Price") :: TextLabel
	card.LayoutOrder = index
	if crate then
		local nameLabel = card:WaitForChild("Name") :: TextLabel
		local oddsLabel = card:WaitForChild("Odds") :: TextLabel
		nameLabel.Text = crate.Name
		oddsLabel.Text = oddsText(crateId)
		price.Text = FormatNumber.money(crate.Cost)
	end
	crateCards[crateId] = {
		card = card,
		hireButton = hireButton,
		gradient = hireButton:FindFirstChildOfClass("UIGradient"),
		price = price,
	}
end

----------------------------------------------------------------------
-- Juice helpers
----------------------------------------------------------------------

-- Celebrate a card: sparkles only while the panel is visible (AbsolutePosition
-- of a hidden card is meaningless), the sound either way.
local function celebrate(card: GuiObject, soundName: string)
	if gui.Enabled then
		ClientEffects.sparkle(card)
	end
	ClientEffects.playSound(soundName)
end

----------------------------------------------------------------------
-- Refresh from DataSync snapshots
----------------------------------------------------------------------

local lastSnapshot: { [string]: any }? = nil
local lastPerkLevels: { [string]: number } = {}
local maxedPerks: { [string]: boolean } = {}

local function setButtonState(button: TextButton, gradient: UIGradient?, maxed: boolean, affordable: boolean)
	if gradient then
		gradient.Color = if maxed then GOLD_SEQUENCE else GREEN_SEQUENCE
	end
	button.Active = not maxed
	button.AutoButtonColor = not maxed
	button.BackgroundColor3 = if maxed or affordable then WHITE else UNAFFORDABLE
end

local function refresh(snapshot: { [string]: any })
	local cash = tonumber(snapshot.Cash) or 0
	local perks = if typeof(snapshot.Perks) == "table" then snapshot.Perks else {}
	cashAmount.Text = FormatNumber.money(cash)

	for _, perkId in GameConfig.PerkOrder do
		local entry = perkCards[perkId]
		local def = GameConfig.Perks[perkId]
		if not entry or not def then
			continue
		end
		local level = math.max(math.floor(tonumber(perks[perkId]) or 0), 0)
		entry.level.Text = "Lv " .. level .. "/" .. def.MaxLevel

		local cost = GameConfig.getPerkCost(perkId, level)
		if cost == nil then
			-- Maxed out: gold MAX button that no longer accepts taps.
			maxedPerks[perkId] = true
			entry.price.Text = "MAX"
			setButtonState(entry.buyButton, entry.gradient, true, true)
		else
			maxedPerks[perkId] = false
			entry.price.Text = FormatNumber.money(cost)
			setButtonState(entry.buyButton, entry.gradient, false, cash >= cost)
		end

		-- Juice when a DataSync shows this perk's level went up (not on the
		-- first snapshot, not on a rebirth reset).
		local previous = lastPerkLevels[perkId]
		if previous ~= nil and level > previous then
			celebrate(entry.card, "LevelUp")
		end
		lastPerkLevels[perkId] = level
	end

	for _, crateId in GameConfig.CrateOrder do
		local entry = crateCards[crateId]
		local crate = GameConfig.WorkerCrates[crateId]
		if not entry or not crate then
			continue
		end
		setButtonState(entry.hireButton, entry.gradient, false, cash >= crate.Cost)
	end
end

DataSync.OnClientEvent:Connect(function(snapshot: any)
	if typeof(snapshot) ~= "table" then
		return
	end
	lastSnapshot = snapshot
	refresh(snapshot)
end)

-- Crate-open juice: the server confirms a hire with the full WorkerEntry.
WorkerHired.OnClientEvent:Connect(function(worker: any)
	if typeof(worker) ~= "table" then
		return
	end
	local entry = if typeof(worker.Crate) == "string" then crateCards[worker.Crate] else nil
	if entry then
		celebrate(entry.card, "Hire")
	else
		ClientEffects.playSound("Hire")
	end
end)

----------------------------------------------------------------------
-- Buttons (the server re-validates everything; unaffordable taps still fire
-- so the server's "Not enough cash" toast explains why nothing happened)
----------------------------------------------------------------------

for perkId, entry in perkCards do
	ButtonFX.attach(entry.buyButton)
	entry.buyButton.Activated:Connect(function()
		if maxedPerks[perkId] then
			return
		end
		BuyPerk:FireServer(perkId)
	end)
end

for crateId, entry in crateCards do
	ButtonFX.attach(entry.hireButton)
	entry.hireButton.Activated:Connect(function()
		HireWorker:FireServer(crateId)
	end)
end

ButtonFX.attach(closeButton)
closeButton.Activated:Connect(function()
	gui.Enabled = false
end)

----------------------------------------------------------------------
-- Open bounce: watch Enabled, tween the UIScale 0.6 -> 1 (Back), refresh
-- from the cached snapshot and scroll back to the top.
----------------------------------------------------------------------

local OPEN_INFO = TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

gui:GetPropertyChangedSignal("Enabled"):Connect(function()
	if gui.Enabled then
		items.CanvasPosition = Vector2.zero
		local snapshot = lastSnapshot
		if snapshot then
			refresh(snapshot)
		end
		openScale.Scale = 0.6
		TweenService:Create(openScale, OPEN_INFO, { Scale = 1 }):Play()
	else
		openScale.Scale = 1 -- a closed panel never keeps a mid-tween scale
	end
end)
