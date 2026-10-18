-- WorkersController (LocalScript inside WorkersGui) — v2
-- Grid of owned workers cloned from the hidden WorkerCardTemplate.
-- EQUIP/UNEQUIP fire the EquipWorker/UnequipWorker remotes; WorkerService
-- validates everything (incl. the slot cap) and answers with a DataSync
-- snapshot, which is the only source of truth.
-- v2: slot cap = GameConfig.Workers.BaseEquipSlots + Perks.WorkerSlots, and the
-- per-worker income shown includes the WorkerEfficiency perk and the rebirth
-- cash multiplier (what WorkerService actually pays).
-- See ARCHITECTURE.md "Upgrades & perks" and "UI contract".

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local FormatNumber = require(Shared:WaitForChild("FormatNumber"))
local ButtonFX = require(Shared:WaitForChild("ButtonFX"))
local ClientEffects = require(Shared:WaitForChild("ClientEffects"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local DataSync = Remotes:WaitForChild("DataSync") :: RemoteEvent
local EquipWorker = Remotes:WaitForChild("EquipWorker") :: RemoteEvent
local UnequipWorker = Remotes:WaitForChild("UnequipWorker") :: RemoteEvent

local gui = script.Parent :: ScreenGui
local main = gui:WaitForChild("Main")
local panelScale = main:WaitForChild("PanelScale") :: UIScale
local panel = main:WaitForChild("Panel")
local slotsLabel = panel:WaitForChild("SlotsLabel") :: TextLabel
local items = panel:WaitForChild("Items") :: ScrollingFrame
local template = items:WaitForChild("WorkerCardTemplate") :: Frame
local emptyState = panel:WaitForChild("EmptyState") :: TextLabel
local closeButton = main:WaitForChild("CloseButton") :: GuiButton

template.Visible = false

local WHITE = Color3.fromRGB(255, 255, 255)
local SLOTS_FULL = Color3.fromRGB(135, 135, 145) -- multiplies the green toward gray
local EQUIP_GRADIENT = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(71, 198, 78)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(42, 147, 42)),
})
local UNEQUIP_GRADIENT = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(247, 55, 92)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(170, 19, 69)),
})

type CardEntry = {
	card: Frame,
	worker: any, -- Types.WorkerEntry
	income: TextLabel?,
	action: TextButton?,
}

local lastSnapshot: { [string]: any }? = nil
local lastSignature = ""
local cards: { CardEntry } = {}

local function numberOr(value: any, default: number): number
	return if typeof(value) == "number" and value == value then value else default
end

local function perkLevel(snapshot: { [string]: any }, perkId: string): number
	local perks = snapshot.Perks
	if typeof(perks) ~= "table" then
		return 0
	end
	return math.max(0, math.floor(numberOr(perks[perkId], 0)))
end

-- Equip cap = base slots + WorkerSlots perk level (WorkerService.equipCap).
local function equipCap(snapshot: { [string]: any }): number
	return GameConfig.Workers.BaseEquipSlots + perkLevel(snapshot, "WorkerSlots")
end

-- WorkerEfficiency perk x rebirth cash multiplier (WorkerService income tick).
local function incomeMultiplier(snapshot: { [string]: any }): number
	local efficiency = 1 + GameConfig.WorkerEfficiencyPerLevel * perkLevel(snapshot, "WorkerEfficiency")
	return efficiency * GameConfig.getRebirthCashMultiplier(numberOr(snapshot.Rebirths, 0))
end

-- Equipped first, then income desc, then Uid for a stable order.
local function sortedWorkers(workers: { any }): { any }
	local list = table.clone(workers)
	table.sort(list, function(a, b)
		if a.Equipped ~= b.Equipped then
			return a.Equipped == true
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

local function buildCard(worker: any, layoutOrder: number): CardEntry
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

	local incomeChild = card:FindFirstChild("Income")
	local actionChild = card:FindFirstChild("ActionButton")
	local entry: CardEntry = {
		card = card,
		worker = worker,
		income = if incomeChild and incomeChild:IsA("TextLabel") then incomeChild else nil,
		action = if actionChild and actionChild:IsA("TextButton") then actionChild else nil,
	}

	local action = entry.action
	if action then
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
				-- Fires even when slots look full: the server's "No free worker
				-- slots!" toast explains why nothing happened.
				EquipWorker:FireServer(uid)
				ClientEffects.sparkle(card)
			end
		end)
		ButtonFX.attach(action)
	end

	card.Parent = items
	return entry
end

local function refresh(snapshot: { [string]: any }?)
	if not snapshot then
		return
	end
	local workers = if typeof(snapshot.Workers) == "table" then snapshot.Workers else {}

	local equippedCount = 0
	for _, worker in workers do
		if worker.Equipped then
			equippedCount += 1
		end
	end
	local cap = equipCap(snapshot)
	slotsLabel.Text = "Equipped " .. equippedCount .. "/" .. cap
	emptyState.Visible = #workers == 0

	-- Only rebuild the grid when the roster actually changed; DataSync fires
	-- every second from the income tick and rebuilding would eat clicks.
	local list = sortedWorkers(workers)
	local parts = table.create(#list)
	for _, worker in list do
		parts[#parts + 1] = tostring(worker.Uid) .. (if worker.Equipped then "+" else "-")
	end
	local signature = table.concat(parts, "|")
	if signature ~= lastSignature then
		lastSignature = signature
		for _, entry in cards do
			entry.card:Destroy()
		end
		table.clear(cards)
		for index, worker in list do
			cards[#cards + 1] = buildCard(worker, index)
		end
	end

	-- Cheap per-sync updates (perks / rebirths change these without a rebuild).
	local multiplier = incomeMultiplier(snapshot)
	local slotsFull = equippedCount >= cap
	for _, entry in cards do
		if entry.income then
			local income = GameConfig.getWorkerIncome(entry.worker.Rarity, entry.worker.Crate) * multiplier
			entry.income.Text = FormatNumber.money(math.floor(income)) .. "/s"
		end
		if entry.action and entry.worker.Equipped ~= true then
			entry.action.BackgroundColor3 = if slotsFull then SLOTS_FULL else WHITE
		end
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

DataSync.OnClientEvent:Connect(function(snapshot: any)
	if typeof(snapshot) ~= "table" then
		return
	end
	lastSnapshot = snapshot
	if gui.Enabled then
		refresh(snapshot)
	end
end)

closeButton.Activated:Connect(function()
	gui.Enabled = false
end)
ButtonFX.attach(closeButton)
