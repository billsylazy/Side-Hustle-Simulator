-- RebirthController (LocalScript inside RebirthGui)
-- Shows current/next rebirth multiplier and CashThisLife progress toward the
-- requirement. The big button fires RequestRebirth; the server validates and
-- answers with RebirthResult ("SUCCESS" or "INSUFFICIENT") + a DataSync snapshot.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local FormatNumber = require(Shared:WaitForChild("FormatNumber"))
local ButtonFX = require(Shared:WaitForChild("ButtonFX"))
local ClientEffects = require(Shared:WaitForChild("ClientEffects"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local DataSync = Remotes:WaitForChild("DataSync")
local RequestRebirth = Remotes:WaitForChild("RequestRebirth")
local RebirthResult = Remotes:WaitForChild("RebirthResult")

local gui = script.Parent
local main = gui:WaitForChild("Main")
local panelScale = main:WaitForChild("PanelScale")
local panel = main:WaitForChild("Panel")
local mults = panel:WaitForChild("Mults")
local currentMult = mults:WaitForChild("CurrentBox"):WaitForChild("CurrentMult")
local nextMult = mults:WaitForChild("NextBox"):WaitForChild("NextMult")
local progressBack = panel:WaitForChild("ProgressBack")
local progressFill = progressBack:WaitForChild("ProgressFill")
local progressLabel = progressBack:WaitForChild("ProgressLabel")
local rebirthButton = panel:WaitForChild("RebirthButton")
local buttonGrad = rebirthButton:WaitForChild("ButtonGrad")
local closeButton = main:WaitForChild("CloseButton")

local BASE_POSITION = main.Position
local WHITE = Color3.fromRGB(255, 255, 255)
local DISABLED_GRAY = Color3.fromRGB(150, 148, 158)

local lastSnapshot: { [string]: any }? = nil

local function refresh(snapshot: { [string]: any }?)
	if not snapshot then
		return
	end
	local rebirths = snapshot.Rebirths or 0
	local cashThisLife = snapshot.CashThisLife or 0
	local requirement = GameConfig.getRebirthRequirement(rebirths)

	currentMult.Text = "x" .. tostring(GameConfig.getRebirthMultiplier(rebirths))
	nextMult.Text = "x" .. tostring(GameConfig.getRebirthMultiplier(rebirths + 1))

	local alpha = math.clamp(cashThisLife / requirement, 0, 1)
	TweenService:Create(
		progressFill,
		TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = UDim2.new(alpha, 0, 1, 0) }
	):Play()
	progressLabel.Text = FormatNumber.money(cashThisLife) .. " / " .. FormatNumber.money(requirement)

	-- Visually disable the button until the requirement is met. Active=false
	-- also stops .Activated from firing.
	local canRebirth = cashThisLife >= requirement
	rebirthButton.Active = canRebirth
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

RebirthResult.OnClientEvent:Connect(function(result: string)
	if result == "INSUFFICIENT" and gui.Enabled then
		ClientEffects.playSound("Error")
		task.spawn(shakePanel)
	end
	-- "SUCCESS" celebration is handled by RebirthWatcher; the panel just
	-- refreshes from the DataSync snapshot that follows.
end)

rebirthButton.Activated:Connect(function()
	RequestRebirth:FireServer()
end)
ButtonFX.attach(rebirthButton)

closeButton.Activated:Connect(function()
	gui.Enabled = false
end)
ButtonFX.attach(closeButton)
