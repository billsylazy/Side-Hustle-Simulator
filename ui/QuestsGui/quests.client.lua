-- QuestsController (LocalScript inside QuestsGui) — v2
-- One row per GameConfig.Quests entry (15 in v2), cloned once from the hidden
-- QuestRowTemplate into the Items ScrollingFrame (AutomaticCanvasSize = Y, so
-- the list scrolls) and updated in place from DataSync snapshots.
-- Progress is read generically from snapshot.Stats[quest.Stat]; the stat names
-- live only in GameConfig.Quests (lifetime Stats survive rebirth).
-- Row order: claimable first, then in progress, then claimed (dimmed, with a
-- checkmark) - config order within each group.
-- CLAIM fires ClaimQuest(questId); QuestService validates and pays.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local FormatNumber = require(Shared:WaitForChild("FormatNumber"))
local ButtonFX = require(Shared:WaitForChild("ButtonFX"))
local ClientEffects = require(Shared:WaitForChild("ClientEffects"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local DataSync = Remotes:WaitForChild("DataSync") :: RemoteEvent
local ClaimQuest = Remotes:WaitForChild("ClaimQuest") :: RemoteEvent

local gui = script.Parent :: ScreenGui
local main = gui:WaitForChild("Main")
local panelScale = main:WaitForChild("PanelScale") :: UIScale
local panel = main:WaitForChild("Panel")
local items = panel:WaitForChild("Items") :: ScrollingFrame
local template = items:WaitForChild("QuestRowTemplate") :: CanvasGroup
local closeButton = main:WaitForChild("CloseButton") :: GuiButton

template.Visible = false

local IN_PROGRESS_SORT_OFFSET = 100 -- below every claimable row
local CLAIMED_SORT_OFFSET = 1000 -- claimed rows sink below everything else

local lastSnapshot: { [string]: any }? = nil
local rows: { [string]: CanvasGroup } = {}

local function numberOr(value: any, default: number): number
	return if typeof(value) == "number" and value == value then value else default
end

-- Build all rows once, in GameConfig.Quests (config) order.
for index, quest in GameConfig.Quests do
	local row = template:Clone()
	row.Name = quest.Id
	row.LayoutOrder = IN_PROGRESS_SORT_OFFSET + index
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
		claim.Visible = false -- shown by refresh() once the quest is completable
		local questId = quest.Id
		claim.Activated:Connect(function()
			if not claim.Visible then
				return
			end
			-- Optimistic juice; the server validates the claim and the row
			-- settles on the next DataSync snapshot either way.
			ClaimQuest:FireServer(questId)
			ClientEffects.sparkle(row)
			ClientEffects.playSound("Buy")
		end)
		ButtonFX.attach(claim)
	end

	local checkmark = row:FindFirstChild("Claimed")
	if checkmark and checkmark:IsA("GuiObject") then
		checkmark.Visible = false
	end

	row.Parent = items
	rows[quest.Id] = row
end

local function refresh(snapshot: { [string]: any }?)
	if not snapshot then
		return
	end
	local stats = if typeof(snapshot.Stats) == "table" then snapshot.Stats else {}
	local claimedQuests = if typeof(snapshot.ClaimedQuests) == "table" then snapshot.ClaimedQuests else {}

	for index, quest in GameConfig.Quests do
		local row = rows[quest.Id]
		if not row then
			continue
		end
		local progress = math.min(numberOr(stats[quest.Stat], 0), quest.Target)
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
		if checkmark and checkmark:IsA("GuiObject") then
			checkmark.Visible = claimed
		end

		row.GroupTransparency = if claimed then 0.45 else 0
		row.LayoutOrder = if canClaim
			then index
			elseif claimed then CLAIMED_SORT_OFFSET + index
			else IN_PROGRESS_SORT_OFFSET + index
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
		refresh(lastSnapshot)
		items.CanvasPosition = Vector2.zero -- claimable quests sit at the top
		bounceOpen()
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
