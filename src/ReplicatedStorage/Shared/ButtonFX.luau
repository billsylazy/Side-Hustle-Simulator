-- ButtonFX: press/hover bounce for every GuiButton (hud_example pattern).
-- Client-only: errors if required on the server. Idempotent per button.

local RunService = game:GetService("RunService")
if not RunService:IsClient() then
	error("ButtonFX is client-only and cannot be required on the server", 2)
end

local TweenService = game:GetService("TweenService")

local ClientEffects = require(script.Parent:WaitForChild("ClientEffects"))

local ATTACHED_ATTRIBUTE = "ButtonFXAttached"
local SCALE_NAME = "ButtonFXScale"

local HOVER_INFO = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS_INFO = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local SPRING_INFO = TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local ButtonFX = {}

function ButtonFX.attach(button: GuiButton)
	if typeof(button) ~= "Instance" or not button:IsA("GuiButton") then
		return
	end
	if button:GetAttribute(ATTACHED_ATTRIBUTE) then
		return -- already wired up
	end
	button:SetAttribute(ATTACHED_ATTRIBUTE, true)

	local scale = button:FindFirstChild(SCALE_NAME)
	if not scale or not scale:IsA("UIScale") then
		scale = Instance.new("UIScale")
		scale.Name = SCALE_NAME
		scale.Parent = button
	end

	local function tweenTo(target: number, info: TweenInfo)
		TweenService:Create(scale, info, { Scale = target }):Play()
	end

	button.MouseEnter:Connect(function()
		tweenTo(1.06, HOVER_INFO)
	end)
	button.MouseButton1Down:Connect(function()
		tweenTo(0.9, PRESS_INFO)
	end)
	button.MouseButton1Up:Connect(function()
		tweenTo(1, SPRING_INFO)
	end)
	button.MouseLeave:Connect(function()
		tweenTo(1, SPRING_INFO)
	end)
	button.Activated:Connect(function()
		ClientEffects.playSound("Click")
	end)
end

return ButtonFX
