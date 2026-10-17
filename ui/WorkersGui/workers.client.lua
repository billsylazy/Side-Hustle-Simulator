-- WorkersController (LocalScript inside WorkersGui)
-- Grid of owned workers cloned from the hidden WorkerCardTemplate.
-- EQUIP/UNEQUIP fire the EquipWorker/UnequipWorker remotes; the server validates
-- everything and answers with a DataSync snapshot, which is the only source of truth.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local FormatNumber = require(Shared:WaitForChild("FormatNumber"))
local ButtonFX = require(Shared:WaitForChild("ButtonFX"))
local ClientEffects = require(Shared:WaitForChild("ClientEffects"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local DataSync = Remotes:WaitForChild("DataSync")
local EquipWorker = Remotes:WaitForChild("EquipWorker")
local UnequipWorker = Remotes:WaitForChild("UnequipWorker")

local gui = script.Parent
local main = gui:WaitForChild("Main")
local panelScale = main:WaitForChild("PanelScale")
local panel = main:WaitForChild("Panel")
local slotsLabel = panel:WaitForChild("SlotsLabel")
local items = panel:WaitForChild("Items")
local template = items:WaitForChild("WorkerCardTemplate")
local emptyState = panel:WaitForChild("EmptyState")
local closeButton = main:WaitForChild("CloseButton")

local EQUIP_GRADIENT = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(71, 198, 78)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(42, 147, 42)),
})
local UNEQUIP_GRADIENT = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(247, 55, 92)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(170, 19, 69)),
})

local lastSnapshot: { [string]: any }? = nil
local lastSignature = ""
local cards: { Frame } = {}

-- Equipped first, then income desc, then Uid for a stable order.
local function sortedWorkers(workers: { any }): { any }
	local list = table.clone(workers)
	table.sort(list, function(a, b)
		if a.Equipped ~= b.Equipped then
			return a.Equipped
		end
		local incomeA = GameConfig.getWorkerIncome(a.Rarity, a.Crate)
		local incomeB = GameConfig.getWorkerIncome(b.Rarity, b.Crate)
		if incomeA ~= incomeB then
			return incomeA > incomeB
		end
		return tostring(a.Uid) < tostring(b.Uid)
	end)
	return list
end

local function buildCard(worker: any, layoutOrder: number): Frame
	local card = template:Clone()
	card.Name = "Card_" .. tostring(worker.Uid)
	card.LayoutOrder = layoutOrder
	card.Visible = true

	local rarity = GameConfig.getRarity(worker.Rarity)
	local rarityBar = card:FindFirstChild("RarityBar")
	if rarityBar and rarityBar:IsA("Frame") then
		if rarity then
			rarityBar.BackgroundColor3 = rarity.Color
		end
		local rarityLabel = rarityBar:FindFirstChild("RarityLabel")
		if rarityLabel and rarityLabel:IsA("TextLabel") then
			rarityLabel.Text = if rarity then rarity.Name else tostring(worker.Rarity)
		end
	end

	-- The card has a CHILD called "Name"; dot access would return the instance's
	-- own Name property, so FindFirstChild is required here.
	local nameLabel = card:FindFirstChild("Name")
	if nameLabel and nameLabel:IsA("TextLabel") then
		nameLabel.Text = tostring(worker.Name)
	end

	local incomeLabel = card:FindFirstChild("Income")
	if incomeLabel and incomeLabel:IsA("TextLabel") then
		local income = GameConfig.getWorkerIncome(worker.Rarity, worker.Crate)
		incomeLabel.Text = FormatNumber.money(income) .. "/s"
	end

	local action = card:FindFirstChild("ActionButton")
	if action and action:IsA("TextButton") then
		local equipped = worker.Equipped == true
		action.Text = if equipped then "UNEQUIP" else "EQUIP"
		local grad = action:FindFirstChild("ButtonGrad")
		if grad and grad:IsA("UIGradient") then
			grad.Color = if equipped then UNEQUIP_GRADIENT else EQUIP_GRADIENT
		end
		local uid = worker.Uid
		action.Activated:Connect(function()
			if equipped then
				UnequipWorker:FireServer(uid)
			else
				EquipWorker:FireServer(uid)
				ClientEffects.sparkle(card)
			end
		end)
		ButtonFX.attach(action)
	end

	card.Parent = items
	return card
end

local function refresh(snapshot: { [string]: any }?)
	if not snapshot then
		return
	end
	local workers = snapshot.Workers or {}

	local equippedCount = 0
	for _, worker in workers do
		if worker.Equipped then
			equippedCount += 1
		end
	end
	local slotLevels = (snapshot.Upgrades and snapshot.Upgrades.WorkerSlots) or 0
	slotsLabel.Text = "Equipped " .. equippedCount .. "/" .. (GameConfig.Workers.BaseEquipSlots + slotLevels)
	emptyState.Visible = #workers == 0

	-- Only rebuild the grid when the roster actually changed; DataSync fires
	-- every second from the income tick and rebuilding would eat clicks.
	local list = sortedWorkers(workers)
	local parts = table.create(#list)
	for _, worker in list do
		parts[#parts + 1] = tostring(worker.Uid) .. (if worker.Equipped then "+" else "-")
	end
	local signature = table.concat(parts, "|")
	if signature == lastSignature then
		return
	end
	lastSignature = signature

	for _, card in cards do
		card:Destroy()
	end
	table.clear(cards)
	for index, worker in list do
		cards[#cards + 1] = buildCard(worker, index)
	end
end

local function bounceOpen()
	panelScale.Scale = 0.6
	TweenService:Create(
		panelScale,
		TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = 1 }
	):Play()
end

gui:GetPropertyChangedSignal("Enabled"):Connect(function()
	if gui.Enabled then
		bounceOpen()
		refresh(lastSnapshot)
	end
end)

DataSync.OnClientEvent:Connect(function(snapshot)
	lastSnapshot = snapshot
	if gui.Enabled then
		refresh(snapshot)
	end
end)

closeButton.Activated:Connect(function()
	gui.Enabled = false
end)
ButtonFX.attach(closeButton)
