-- HUDController (LocalScript inside MainHUD)
-- Wires: leaderstats.Cash -> cash pill (count-up + pop), DataSync -> rebirth
-- multiplier pill, side buttons -> panel toggles (one panel open at a time),
-- HustleResult -> money popup + screen pop, Toast remote -> queued toast pill.
-- See ARCHITECTURE.md "UI contract".

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
local DataSync = Remotes:WaitForChild("DataSync")
local HustleResult = Remotes:WaitForChild("HustleResult")
local ToastRemote = Remotes:WaitForChild("Toast")

local topCenter = gui:WaitForChild("TopCenter")
local cashPill = topCenter:WaitForChild("CashPill")
local amountLabel = cashPill:WaitForChild("Amount")
local cashIcon = cashPill:WaitForChild("CashIcon")
local popScale = cashPill:WaitForChild("PopScale")
local rebirthPill = topCenter:WaitForChild("RebirthPill")
local multiplierLabel = rebirthPill:WaitForChild("Multiplier")
local toast = topCenter:WaitForChild("Toast")
local toastMessage = toast:WaitForChild("Message")
local sideButtons = gui:WaitForChild("SideButtons")

----------------------------------------------------------------------
-- Cash pill: animated count-up + 1.1 scale pop on increase
----------------------------------------------------------------------

-- NumberValue so TweenService can animate the displayed amount smoothly.
local displayValue = Instance.new("NumberValue")
displayValue.Name = "DisplayedCash"
displayValue.Parent = script

local countTween: Tween? = nil

displayValue.Changed:Connect(function(value: number)
	amountLabel.Text = FormatNumber.money(math.floor(value + 0.5))
end)

local function popPill()
	popScale.Scale = 1.1
	TweenService:Create(
		popScale,
		TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = 1 }
	):Play()
end

local function bindCash()
	local leaderstats = player:WaitForChild("leaderstats")
	local cashStat = leaderstats:WaitForChild("Cash")
	displayValue.Value = cashStat.Value
	amountLabel.Text = FormatNumber.money(cashStat.Value)
	cashStat.Changed:Connect(function(newValue: number)
		if countTween then
			countTween:Cancel()
		end
		local increased = newValue > displayValue.Value
		countTween = TweenService:Create(
			displayValue,
			TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Value = newValue }
		)
		countTween:Play()
		if increased then
			popPill()
		end
	end)
end
task.spawn(bindCash)

-- Gentle idle bounce on the cash icon (art guide: bouncing coin).
local idleBounce = TweenService:Create(
	cashIcon,
	TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
	{ Position = UDim2.new(0, -14, 0.5, -5) }
)
idleBounce:Play()

----------------------------------------------------------------------
-- Rebirth multiplier pill (from DataSync snapshots)
----------------------------------------------------------------------

DataSync.OnClientEvent:Connect(function(snapshot)
	if typeof(snapshot) ~= "table" then
		return
	end
	local rebirths = tonumber(snapshot.Rebirths) or 0
	multiplierLabel.Text = "x" .. tostring(GameConfig.getRebirthMultiplier(rebirths))
end)

----------------------------------------------------------------------
-- Side buttons: toggle panels, only one open at a time
----------------------------------------------------------------------

local PANEL_BY_BUTTON: { [string]: string } = {
	ShopButton = "ShopGui",
	WorkersButton = "WorkersGui",
	RebirthButton = "RebirthGui",
	QuestsButton = "QuestsGui",
}
local PANEL_NAMES = { "ShopGui", "WorkersGui", "RebirthGui", "QuestsGui" }

local function togglePanel(guiName: string)
	local target = playerGui:FindFirstChild(guiName)
	if not target or not target:IsA("ScreenGui") then
		return -- panel not built/loaded yet
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
		local button = sideButtons:WaitForChild(buttonName)
		if not button:IsA("GuiButton") then
			return
		end
		ButtonFX.attach(button)
		button.Activated:Connect(function()
			togglePanel(guiName)
		end)
	end)
end

----------------------------------------------------------------------
-- HustleResult: money popup + screen pop
----------------------------------------------------------------------

HustleResult.OnClientEvent:Connect(function(_zoneId, amount)
	if typeof(amount) ~= "number" then
		return
	end
	ClientEffects.moneyPopup(amount)
	ClientEffects.screenPop()
end)

----------------------------------------------------------------------
-- Toast pill: queued server messages, 2.5s each, colored by kind
----------------------------------------------------------------------

local TOAST_COLORS: { [string]: Color3 } = {
	error = Color3.fromRGB(247, 55, 92), -- #f7375c
	success = Color3.fromRGB(71, 198, 78), -- #47c64e
	info = Color3.fromRGB(47, 143, 216), -- #2f8fd8
}
local MAX_QUEUED_TOASTS = 6

local toastQueue: { { message: string, kind: string } } = {}
local toastShowing = false

local function drainToasts()
	if toastShowing then
		return
	end
	toastShowing = true
	task.spawn(function()
		while #toastQueue > 0 do
			local entry = table.remove(toastQueue, 1)
			if entry then
				toastMessage.Text = entry.message
				toast.BackgroundColor3 = TOAST_COLORS[entry.kind] or TOAST_COLORS.info
				toast.Visible = true
				if entry.kind == "error" then
					ClientEffects.playSound("Error")
				end
				task.wait(2.5)
				toast.Visible = false
				task.wait(0.15)
			end
		end
		toastShowing = false
	end)
end

ToastRemote.OnClientEvent:Connect(function(message, kind)
	if typeof(message) ~= "string" or message == "" then
		return
	end
	if #toastQueue >= MAX_QUEUED_TOASTS then
		table.remove(toastQueue, 1) -- drop the oldest, never grow unbounded
	end
	table.insert(toastQueue, {
		message = message,
		kind = if typeof(kind) == "string" then kind else "info",
	})
	drainToasts()
end)
