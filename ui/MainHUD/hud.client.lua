-- HUDController (LocalScript inside MainHUD) — v2
-- Wires (see ARCHITECTURE.md "UI contract"):
--   leaderstats.Cash -> CashPill.Amount (count-up tween + pill pop) + idle bouncing cash icon
--   DataSync         -> LevelPill.LevelLabel "Lv 7", XpBar.Fill / XpBar.Label "120 / 238 XP",
--                       RebirthPill.Label "x1.5"
--   SideButtons      -> toggle HustleGui / ShopGui / WorkersGui / RebirthGui / QuestsGui
--                       (one panel open at a time; panels looked up at click time)
--   HustleResult     -> moneyPopup + screenPop (manual earnings), comboPopup (Combo >= 2).
--                       Burst/Peak callouts belong to StationFeedbackController, NOT here.
--   LevelUp          -> ClientEffects.levelUp(newLevel, unlockedZoneId)
--   Toast            -> queued bottom-center toast pill colored by kind
-- The client only displays; the server owns every number shown here.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local gui = script.Parent

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local FormatNumber = require(Shared:WaitForChild("FormatNumber"))
local ButtonFX = require(Shared:WaitForChild("ButtonFX"))
local ClientEffects = require(Shared:WaitForChild("ClientEffects"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local DataSync = Remotes:WaitForChild("DataSync") :: RemoteEvent
local HustleResult = Remotes:WaitForChild("HustleResult") :: RemoteEvent
local LevelUpRemote = Remotes:WaitForChild("LevelUp") :: RemoteEvent
local ToastRemote = Remotes:WaitForChild("Toast") :: RemoteEvent

local topCenter = gui:WaitForChild("TopCenter")
local cashPill = topCenter:WaitForChild("CashPill")
local amountLabel = cashPill:WaitForChild("Amount") :: TextLabel
local cashIcon = cashPill:WaitForChild("CashIcon") :: ImageLabel
local cashPopScale = cashPill:WaitForChild("PopScale") :: UIScale

local levelRow = topCenter:WaitForChild("LevelRow")
local levelPill = levelRow:WaitForChild("LevelPill")
local levelLabel = levelPill:WaitForChild("LevelLabel") :: TextLabel
local levelPopScale = levelPill:WaitForChild("PopScale") :: UIScale
local xpBar = levelRow:WaitForChild("XpBar")
local xpFill = xpBar:WaitForChild("Fill") :: Frame
local xpLabel = xpBar:WaitForChild("Label") :: TextLabel

local rebirthPill = topCenter:WaitForChild("RebirthPill")
local rebirthLabel = rebirthPill:WaitForChild("Label") :: TextLabel

local sideButtons = gui:WaitForChild("SideButtons")

local toast = gui:WaitForChild("Toast") :: Frame
local toastMessage = toast:WaitForChild("Message") :: TextLabel
local toastScale = toast:WaitForChild("PopScale") :: UIScale

-- Panels render at DisplayOrder 5, above this HUD. Server toasts ("Not enough
-- cash!") arrive while a panel is open, so the toast lives on its own layer
-- above the panels. Same insets as the HUD, so its scale layout is unchanged.
local toastLayer = Instance.new("ScreenGui")
toastLayer.Name = "ToastLayer"
toastLayer.ResetOnSpawn = false
toastLayer.IgnoreGuiInset = gui.IgnoreGuiInset
toastLayer.ScreenInsets = gui.ScreenInsets
toastLayer.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
toastLayer.DisplayOrder = 20
toastLayer.Parent = gui.Parent
toast.Parent = toastLayer

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------

local POP_INFO = TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local function pop(scale: UIScale, peak: number)
	scale.Scale = peak
	TweenService:Create(scale, POP_INFO, { Scale = 1 }):Play()
end

-- 1 -> "1", 1.5 -> "1.5", 1.25 -> "1.25" (no float noise like 1.4999999)
local function formatMultiplier(mult: number): string
	if mult == math.floor(mult) then
		return tostring(math.floor(mult))
	end
	local text = string.format("%.2f", mult)
	text = text:gsub("0+$", "")
	text = text:gsub("%.$", "")
	return text
end

----------------------------------------------------------------------
-- Cash pill: animated count-up + 1.1 scale pop on increase
----------------------------------------------------------------------

-- NumberValue so TweenService can animate the displayed amount smoothly.
local displayedCash = Instance.new("NumberValue")
displayedCash.Name = "DisplayedCash"
displayedCash.Parent = script

local cashTween: Tween? = nil
local COUNT_INFO = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

displayedCash.Changed:Connect(function(value: number)
	amountLabel.Text = FormatNumber.money(math.floor(value + 0.5))
end)

local function onCashChanged(newValue: number)
	local current = cashTween
	if current then
		current:Cancel()
	end
	local increased = newValue > displayedCash.Value
	local tween = TweenService:Create(displayedCash, COUNT_INFO, { Value = newValue })
	cashTween = tween
	tween:Play()
	if increased then
		pop(cashPopScale, 1.1)
	end
end

local function bindCash()
	local leaderstats = player:WaitForChild("leaderstats")
	local cashStat = leaderstats:WaitForChild("Cash") :: IntValue
	displayedCash.Value = cashStat.Value
	amountLabel.Text = FormatNumber.money(cashStat.Value)
	cashStat.Changed:Connect(onCashChanged)
end
task.spawn(bindCash)

-- Gentle idle bounce on the cash icon (art guide: bouncing coin). Tweens from
-- the layout position so the spec stays the source of truth.
local cashIconBase = cashIcon.Position
TweenService:Create(
	cashIcon,
	TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
	{ Position = cashIconBase + UDim2.fromOffset(0, -5) }
):Play()

----------------------------------------------------------------------
-- Level pill + XP bar + rebirth pill (from DataSync snapshots)
----------------------------------------------------------------------

local FILL_INFO = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FILL_FAST_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local fillTween: Tween? = nil
local fillToken = 0
local lastLevel: number? = nil
local lastFraction = -1

local function fillSize(fraction: number): UDim2
	return UDim2.new(fraction, 0, 1, 0)
end

-- Tween the XP fill. On a level-up the bar runs to full, snaps empty, then
-- fills to the new progress so the player sees the bar "roll over".
local function setXpFill(fraction: number, levelledUp: boolean)
	fillToken += 1
	local token = fillToken
	local running = fillTween
	if running then
		running:Cancel()
	end
	if levelledUp then
		local toFull = TweenService:Create(xpFill, FILL_FAST_INFO, { Size = fillSize(1) })
		fillTween = toFull
		toFull.Completed:Once(function(state: Enum.PlaybackState)
			if token ~= fillToken or state ~= Enum.PlaybackState.Completed then
				return -- a newer snapshot already took over the bar
			end
			xpFill.Size = fillSize(0)
			local refill = TweenService:Create(xpFill, FILL_INFO, { Size = fillSize(fraction) })
			fillTween = refill
			refill:Play()
		end)
		toFull:Play()
	else
		local tween = TweenService:Create(xpFill, FILL_INFO, { Size = fillSize(fraction) })
		fillTween = tween
		tween:Play()
	end
end

local function onDataSync(snapshot: any)
	if typeof(snapshot) ~= "table" then
		return
	end
	local maxLevel = GameConfig.Levels.MaxLevel
	local level = math.clamp(math.floor(tonumber(snapshot.Level) or 1), 1, maxLevel)
	local xp = math.max(tonumber(snapshot.Xp) or 0, 0)
	local rebirths = math.max(tonumber(snapshot.Rebirths) or 0, 0)

	-- Level pill
	levelLabel.Text = "Lv " .. level
	local previousLevel = lastLevel
	local levelledUp = previousLevel ~= nil and level > previousLevel
	if levelledUp then
		pop(levelPopScale, 1.25)
	end

	-- XP bar
	local fraction: number
	if level >= maxLevel then
		fraction = 1
		xpLabel.Text = "MAX LEVEL"
	else
		local need = math.max(GameConfig.getXpForLevel(level), 1)
		fraction = math.clamp(xp / need, 0, 1)
		xpLabel.Text = FormatNumber.abbreviate(math.floor(xp)) .. " / " .. FormatNumber.abbreviate(need) .. " XP"
	end
	if previousLevel == nil then
		xpFill.Size = fillSize(fraction) -- first snapshot: no animation
	elseif levelledUp or math.abs(fraction - lastFraction) > 1e-4 then
		setXpFill(fraction, levelledUp)
	end
	lastFraction = fraction
	lastLevel = level

	-- Rebirth multiplier pill
	rebirthLabel.Text = "x" .. formatMultiplier(GameConfig.getRebirthCashMultiplier(rebirths))
end

-- Until the first snapshot arrives, show a fresh level-1 state instead of the
-- spec's preview placeholders ("120 / 238 XP", half-full bar).
levelLabel.Text = "Lv 1"
xpFill.Size = fillSize(0)
xpLabel.Text = "0 / " .. FormatNumber.abbreviate(GameConfig.getXpForLevel(1)) .. " XP"
rebirthLabel.Text = "x" .. formatMultiplier(GameConfig.getRebirthCashMultiplier(0))

DataSync.OnClientEvent:Connect(onDataSync)

----------------------------------------------------------------------
-- Side buttons: toggle panels, only one open at a time
----------------------------------------------------------------------

local PANEL_BY_BUTTON: { [string]: string } = {
	HustlesButton = "HustleGui",
	ShopButton = "ShopGui",
	WorkersButton = "WorkersGui",
	RebirthButton = "RebirthGui",
	QuestsButton = "QuestsGui",
}
local PANEL_NAMES = { "HustleGui", "ShopGui", "WorkersGui", "RebirthGui", "QuestsGui" }

local warnedMissing: { [string]: boolean } = {}

local function togglePanel(guiName: string)
	-- Look the panel up at click time: panels may load after the HUD.
	local target = playerGui:FindFirstChild(guiName)
	if not target or not target:IsA("ScreenGui") then
		if not warnedMissing[guiName] then
			warnedMissing[guiName] = true
			warn(("[HUDController] %s is not in PlayerGui yet"):format(guiName))
		end
		return
	end
	local shouldOpen = not target.Enabled
	for _, name in PANEL_NAMES do
		local panel = playerGui:FindFirstChild(name)
		if panel and panel:IsA("ScreenGui") then
			panel.Enabled = shouldOpen and name == guiName
		end
	end
end

for buttonName, guiName in PANEL_BY_BUTTON do
	task.spawn(function()
		local button = sideButtons:WaitForChild(buttonName, 10)
		if not button or not button:IsA("GuiButton") then
			warn(("[HUDController] side button %s missing"):format(buttonName))
			return
		end
		ButtonFX.attach(button)
		button.Activated:Connect(function()
			togglePanel(guiName)
		end)
	end)
end

----------------------------------------------------------------------
-- HustleResult: money popup + screen pop for manual earnings, combo popup.
-- Auto results are shown at the station by AutomationVisualsController;
-- Burst/Peak callouts are owned by StationFeedbackController.
----------------------------------------------------------------------

HustleResult.OnClientEvent:Connect(function(_zoneId: any, payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	local amount = tonumber(payload.Amount) or 0
	if amount > 0 and payload.Kind ~= "Auto" then
		ClientEffects.moneyPopup(amount) -- plays the Coin sound itself
		ClientEffects.screenPop()
	end
	local combo = tonumber(payload.Combo)
	if combo and combo >= 2 then
		ClientEffects.comboPopup(combo) -- plays the Combo sound itself
	end
end)

----------------------------------------------------------------------
-- LevelUp: banner + confetti (ClientEffects resolves a zone Id to its Name
-- and plays the LevelUp sound itself)
----------------------------------------------------------------------

LevelUpRemote.OnClientEvent:Connect(function(newLevel: any, unlockedZoneId: any)
	if typeof(newLevel) ~= "number" then
		return
	end
	local zoneId: string? = if typeof(unlockedZoneId) == "string" and unlockedZoneId ~= ""
		then unlockedZoneId
		else nil
	ClientEffects.levelUp(newLevel, zoneId)
end)

----------------------------------------------------------------------
-- Toast pill: queued server messages, 2.5s each, colored by kind.
-- A repeat of the message on screen restarts its timer instead of queueing.
----------------------------------------------------------------------

type ToastEntry = { message: string, kind: string }

local TOAST_SECONDS = 2.5
local MAX_QUEUED_TOASTS = 5
local TOAST_COLORS: { [string]: Color3 } = {
	error = Color3.fromRGB(247, 55, 92), -- #f7375c
	success = Color3.fromRGB(71, 198, 78), -- #47c64e
	info = Color3.fromRGB(47, 143, 216), -- #2f8fd8
}
local TOAST_IN = TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local TOAST_OUT = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local toastQueue: { ToastEntry } = {}
local currentToast: ToastEntry? = nil
local toastDeadline = 0
local toastRunning = false

local function presentToast(entry: ToastEntry)
	toastMessage.Text = entry.message
	toast.BackgroundColor3 = TOAST_COLORS[entry.kind] or TOAST_COLORS.info
	toast.Visible = true
	toastScale.Scale = 0.6
	TweenService:Create(toastScale, TOAST_IN, { Scale = 1 }):Play()
	if entry.kind == "error" then
		ClientEffects.playSound("Error")
	end
end

local function runToasts()
	if toastRunning then
		return
	end
	toastRunning = true
	task.spawn(function()
		while #toastQueue > 0 do
			local entry = table.remove(toastQueue, 1) :: ToastEntry
			currentToast = entry
			presentToast(entry)
			toastDeadline = os.clock() + TOAST_SECONDS
			while os.clock() < toastDeadline do
				task.wait(0.1)
			end
			currentToast = nil -- from here on, repeats queue up normally
			local out = TweenService:Create(toastScale, TOAST_OUT, { Scale = 0.6 })
			out:Play()
			task.wait(0.12)
			toast.Visible = false
			task.wait(0.1)
		end
		toastRunning = false
	end)
end

ToastRemote.OnClientEvent:Connect(function(message: any, kind: any)
	if typeof(message) ~= "string" or message == "" then
		return
	end
	local toastKind = if typeof(kind) == "string" and TOAST_COLORS[kind] then kind else "info"

	local showing = currentToast
	if showing and showing.message == message and showing.kind == toastKind then
		-- Same message again (e.g. spamming an unaffordable buy): keep it up.
		toastDeadline = os.clock() + TOAST_SECONDS
		pop(toastScale, 1.12)
		if toastKind == "error" then
			ClientEffects.playSound("Error")
		end
		return
	end
	local last = toastQueue[#toastQueue]
	if last and last.message == message and last.kind == toastKind then
		return -- already waiting in line
	end
	if #toastQueue >= MAX_QUEUED_TOASTS then
		table.remove(toastQueue, 1) -- drop the oldest, never grow unbounded
	end
	table.insert(toastQueue, { message = message, kind = toastKind })
	runToasts()
end)
