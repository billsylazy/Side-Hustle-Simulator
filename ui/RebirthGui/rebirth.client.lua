-- RebirthController (LocalScript inside RebirthGui) — v2 (level-gated)
-- Shows the current/next rebirth CASH multiplier and Level progress toward
-- GameConfig.Rebirth.RequiredLevel. The big button fires RequestRebirth; the
-- server (RebirthService) validates and answers with RebirthResult
--   "SUCCESS", newRebirths, cashMult   |   "INSUFFICIENT", requiredLevel
-- followed by a DataSync snapshot. The SUCCESS celebration is RebirthWatcher's
-- job; this panel shakes + plays "Error" on INSUFFICIENT.
-- See ARCHITECTURE.md "Rebirth (RebirthService)" and "UI contract".

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local ButtonFX = require(Shared:WaitForChild("ButtonFX"))
local ClientEffects = require(Shared:WaitForChild("ClientEffects"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local DataSync = Remotes:WaitForChild("DataSync") :: RemoteEvent
local RequestRebirth = Remotes:WaitForChild("RequestRebirth") :: RemoteEvent
local RebirthResult = Remotes:WaitForChild("RebirthResult") :: RemoteEvent

local gui = script.Parent :: ScreenGui
local main = gui:WaitForChild("Main") :: Frame
local panelScale = main:WaitForChild("PanelScale") :: UIScale
local panel = main:WaitForChild("Panel")
local mults = panel:WaitForChild("Mults")
local currentMult = mults:WaitForChild("CurrentBox"):WaitForChild("CurrentMult") :: TextLabel
local nextMult = mults:WaitForChild("NextBox"):WaitForChild("NextMult") :: TextLabel
local progressBack = panel:WaitForChild("ProgressBack")
local progressFill = progressBack:WaitForChild("ProgressFill") :: Frame
local progressLabel = progressBack:WaitForChild("ProgressLabel") :: TextLabel
local warningLabel = panel:WaitForChild("Warning") :: TextLabel
local rebirthButton = panel:WaitForChild("RebirthButton") :: TextButton
local buttonGrad = rebirthButton:WaitForChild("ButtonGrad") :: UIGradient
local closeButton = main:WaitForChild("CloseButton") :: GuiButton

local BASE_POSITION = main.Position
local WHITE = Color3.fromRGB(255, 255, 255)
local DISABLED_GRAY = Color3.fromRGB(150, 148, 158)
local WARNING_TEXT = "Resets cash, level, upgrades and perks. Keeps workers and quests!"
local NOTICE_SECONDS = 1.6

local lastSnapshot: { [string]: any }? = nil
local noticeUntil = 0 -- while > os.clock(), ProgressLabel shows the INSUFFICIENT notice

warningLabel.Text = WARNING_TEXT

local function numberOr(value: any, default: number): number
	return if typeof(value) == "number" and value == value then value else default
end

-- 1 -> "x1", 1.5 -> "x1.5", 2.25 -> "x2.25" (no float noise like 1.4999999)
local function multText(mult: number): string
	local text = string.format("%.2f", mult)
	text = text:gsub("0+$", ""):gsub("%.$", "")
	return "x" .. text
end

local rebirthReady = false -- level requirement met (and not maxed)

local function refresh(snapshot: { [string]: any }?)
	local data = snapshot or {}
	local rebirths = math.max(0, math.floor(numberOr(data.Rebirths, 0)))
	local level = math.max(1, math.floor(numberOr(data.Level, 1)))
	local requiredLevel = GameConfig.Rebirth.RequiredLevel
	local maxed = rebirths >= GameConfig.Rebirth.MaxRebirths

	currentMult.Text = multText(GameConfig.getRebirthCashMultiplier(rebirths))
	nextMult.Text = if maxed then "MAX" else multText(GameConfig.getRebirthCashMultiplier(rebirths + 1))

	local alpha = if requiredLevel > 0 then math.clamp(level / requiredLevel, 0, 1) else 1
	TweenService:Create(
		progressFill,
		TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = UDim2.new(alpha, 0, 1, 0) }
	):Play()
	if os.clock() >= noticeUntil then
		progressLabel.Text = "Level " .. math.min(level, requiredLevel) .. " / " .. requiredLevel
	end

	-- Visually disable the button until the level is reached. It stays
	-- Active so a tap still reaches the handler, which explains the refusal
	-- locally (shake + notice) instead of asking the server.
	local canRebirth = level >= requiredLevel and not maxed
	rebirthReady = canRebirth
	rebirthButton.AutoButtonColor = canRebirth
	buttonGrad.Enabled = canRebirth
	rebirthButton.BackgroundColor3 = if canRebirth then WHITE else DISABLED_GRAY
	rebirthButton.TextTransparency = if canRebirth then 0 else 0.3
end

local shaking = false
local function shakePanel()
	if shaking then
		return
	end
	shaking = true
	for i = 1, 5 do
		local offset = if i % 2 == 0 then 9 else -9
		local tween = TweenService:Create(
			main,
			TweenInfo.new(0.05, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Position = BASE_POSITION + UDim2.fromOffset(offset, 0) }
		)
		tween:Play()
		tween.Completed:Wait()
	end
	local settle = TweenService:Create(
		main,
		TweenInfo.new(0.06, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Position = BASE_POSITION }
	)
	settle:Play()
	settle.Completed:Wait()
	shaking = false
end

-- Briefly swap the progress text for "Reach Level 50 first!" after a refusal.
local function showNotice(text: string)
	noticeUntil = os.clock() + NOTICE_SECONDS
	progressLabel.Text = text
	task.delay(NOTICE_SECONDS + 0.05, function()
		if os.clock() >= noticeUntil then
			refresh(lastSnapshot)
		end
	end)
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

-- Refusal feedback: Error sound, shake, and a short notice on the bar.
-- RebirthService sends no Toast for INSUFFICIENT, so the panel owns this.
local function refuse(requiredLevel: number)
	ClientEffects.playSound("Error")
	local rebirths = numberOr(lastSnapshot and lastSnapshot.Rebirths, 0)
	if rebirths >= GameConfig.Rebirth.MaxRebirths then
		showNotice("Max rebirths reached!")
	else
		showNotice("Reach Level " .. requiredLevel .. " first!")
	end
	task.spawn(shakePanel)
end

RebirthResult.OnClientEvent:Connect(function(result: any, requiredLevel: any)
	if result == "INSUFFICIENT" and gui.Enabled then
		refuse(numberOr(requiredLevel, GameConfig.Rebirth.RequiredLevel))
	end
	-- "SUCCESS": RebirthWatcher celebrates; the panel refreshes from the
	-- DataSync snapshot that follows.
end)

rebirthButton.Activated:Connect(function()
	if not rebirthReady then
		refuse(GameConfig.Rebirth.RequiredLevel)
		return
	end
	RequestRebirth:FireServer()
end)
ButtonFX.attach(rebirthButton)

closeButton.Activated:Connect(function()
	gui.Enabled = false
end)
ButtonFX.attach(closeButton)

-- Never show the spec's placeholder numbers, even before the first DataSync.
refresh(lastSnapshot)
