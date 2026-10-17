-- QuestsController (LocalScript inside QuestsGui)
-- One row per GameConfig.Quests entry, cloned once from the hidden
-- QuestRowTemplate and updated in place from DataSync snapshots.
-- Claimed rows show a checkmark, dim, and sink to the bottom of the list.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local FormatNumber = require(Shared:WaitForChild("FormatNumber"))
local ButtonFX = require(Shared:WaitForChild("ButtonFX"))
local ClientEffects = require(Shared:WaitForChild("ClientEffects"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local DataSync = Remotes:WaitForChild("DataSync")
local ClaimQuest = Remotes:WaitForChild("ClaimQuest")

local gui = script.Parent
local main = gui:WaitForChild("Main")
local panelScale = main:WaitForChild("PanelScale")
local panel = main:WaitForChild("Panel")
local items = panel:WaitForChild("Items")
local template = items:WaitForChild("QuestRowTemplate")
local closeButton = main:WaitForChild("CloseButton")

local CLAIMED_SORT_OFFSET = 1000 -- claimed rows sink below every unclaimed row

local lastSnapshot: { [string]: any }? = nil
local rows: { [string]: CanvasGroup } = {}

-- Build all rows once, in GameConfig.Quests (config) order.
for index, quest in GameConfig.Quests do
	local row = template:Clone()
	row.Name = quest.Id
	row.LayoutOrder = index
	row.Visible = true

	local title = row:FindFirstChild("Title")
	if title and title:IsA("TextLabel") then
		title.Text = quest.Name
	end
	local desc = row:FindFirstChild("Desc")
	if desc and desc:IsA("TextLabel") then
		desc.Text = quest.Description
	end
	local reward = row:FindFirstChild("Reward")
	if reward and reward:IsA("TextLabel") then
		reward.Text = FormatNumber.money(quest.Reward)
	end

	local claim = row:FindFirstChild("ClaimButton")
	if claim and claim:IsA("TextButton") then
		claim.Visible = false -- enabled by refresh() once the quest is completable
		local questId = quest.Id
		claim.Activated:Connect(function()
			-- Optimistic juice; the server validates the claim and the row
			-- settles on the next DataSync snapshot either way.
			ClaimQuest:FireServer(questId)
			ClientEffects.sparkle(row)
			ClientEffects.playSound("Buy")
		end)
		ButtonFX.attach(claim)
	end

	row.Parent = items
	rows[quest.Id] = row
end

local function refresh(snapshot: { [string]: any }?)
	if not snapshot then
		return
	end
	local stats = snapshot.Stats or {}
	local claimedQuests = snapshot.ClaimedQuests or {}

	for index, quest in GameConfig.Quests do
		local row = rows[quest.Id]
		if not row then
			continue
		end
		local progress = math.min(stats[quest.Stat] or 0, quest.Target)
		local claimed = claimedQuests[quest.Id] == true
		local canClaim = progress >= quest.Target and not claimed

		local progressBack = row:FindFirstChild("ProgressBack")
		if progressBack then
			local fill = progressBack:FindFirstChild("ProgressFill")
			if fill and fill:IsA("Frame") then
				local alpha = if quest.Target > 0 then math.clamp(progress / quest.Target, 0, 1) else 0
				fill.Size = UDim2.new(alpha, 0, 1, 0)
			end
			local label = progressBack:FindFirstChild("ProgressLabel")
			if label and label:IsA("TextLabel") then
				label.Text = FormatNumber.abbreviate(progress) .. "/" .. FormatNumber.abbreviate(quest.Target)
			end
		end

		local claim = row:FindFirstChild("ClaimButton")
		if claim and claim:IsA("TextButton") then
			claim.Visible = canClaim
			claim.Active = canClaim
		end
		local checkmark = row:FindFirstChild("Claimed")
		if checkmark and checkmark:IsA("ImageLabel") then
			checkmark.Visible = claimed
		end

		row.GroupTransparency = if claimed then 0.45 else 0
		row.LayoutOrder = if claimed then CLAIMED_SORT_OFFSET + index else index
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
