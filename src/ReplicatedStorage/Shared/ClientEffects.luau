-- ClientEffects: client-only juice API (money popups, screen pop, sparkle,
-- sounds, rebirth celebration). See ARCHITECTURE.md "UI contract".
-- Required by UI LocalScripts and client controllers. Errors if required on the server.

local RunService = game:GetService("RunService")
if not RunService:IsClient() then
	error("ClientEffects is client-only and cannot be required on the server", 2)
end

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")
local GuiService = game:GetService("GuiService")

local GameConfig = require(script.Parent:WaitForChild("GameConfig"))
local FormatNumber = require(script.Parent:WaitForChild("FormatNumber"))

local player = Players.LocalPlayer

-- Style palette (art-feel-guide: chunky text, thick navy strokes, gold coins)
local NAVY = Color3.fromRGB(4, 4, 53) -- #040435
local GREEN = Color3.fromRGB(71, 198, 78) -- #47c64e
local GOLD = Color3.fromRGB(255, 200, 40)
local WHITE = Color3.fromRGB(255, 255, 255)

local CONFETTI_COLORS = {
	Color3.fromRGB(255, 212, 31),
	Color3.fromRGB(88, 190, 72),
	Color3.fromRGB(128, 115, 255),
	Color3.fromRGB(64, 200, 224),
	Color3.fromRGB(255, 123, 34),
	Color3.fromRGB(255, 92, 180),
	Color3.fromRGB(60, 130, 255),
	Color3.fromRGB(255, 255, 255),
}

local ClientEffects = {}

----------------------------------------------------------------------
-- EffectsGui (lazily created, survives respawn, draws above panels)
----------------------------------------------------------------------

local effectsGui: ScreenGui? = nil

local function getEffectsGui(): ScreenGui
	if effectsGui and effectsGui.Parent then
		return effectsGui :: ScreenGui
	end
	local playerGui = player:WaitForChild("PlayerGui")
	local existing = playerGui:FindFirstChild("EffectsGui")
	if existing and existing:IsA("ScreenGui") then
		effectsGui = existing
		return existing
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "EffectsGui"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 50
	gui.Parent = playerGui
	effectsGui = gui
	return gui
end

----------------------------------------------------------------------
-- Sounds: cached templates in SoundService, play clones so they overlap
----------------------------------------------------------------------

local soundCache: { [string]: Sound } = {}

function ClientEffects.playSound(name: string)
	local soundId = GameConfig.Sounds[name]
	if soundId == nil or soundId == "" then
		return -- placeholder not filled in yet; never play an empty id
	end
	local template = soundCache[name]
	if not template or not template.Parent then
		template = Instance.new("Sound")
		template.Name = "FX_" .. name
		template.SoundId = soundId
		template.Volume = 0.6
		template.Parent = SoundService
		soundCache[name] = template
	end
	local clone = (template :: Sound):Clone()
	clone.PlaybackSpeed = 0.95 + math.random() * 0.1 -- tiny variation keeps spam fresh
	clone.Parent = SoundService
	clone:Play()
	clone.Ended:Once(function()
		clone:Destroy()
	end)
	task.delay(10, function()
		clone:Destroy() -- safety net; Destroy is idempotent
	end)
end

----------------------------------------------------------------------
-- moneyPopup: chunky "+$1.2K!" springing up with a burst of coin dots
----------------------------------------------------------------------

function ClientEffects.moneyPopup(amount: number)
	local gui = getEffectsGui()

	-- Anchor the whole effect to one slightly-random point upper-middle screen.
	local container = Instance.new("Frame")
	container.Name = "MoneyPopup"
	container.AnchorPoint = Vector2.new(0.5, 0.5)
	container.Position = UDim2.fromScale(
		0.5 + (math.random() - 0.5) * 0.16,
		0.3 + (math.random() - 0.5) * 0.1
	)
	container.Size = UDim2.fromOffset(0, 0)
	container.BackgroundTransparency = 1
	container.Parent = gui

	-- Coin dot burst (behind the text)
	for _ = 1, math.random(5, 8) do
		local coin = Instance.new("Frame")
		local coinSize = math.random(10, 16)
		coin.Size = UDim2.fromOffset(coinSize, coinSize)
		coin.AnchorPoint = Vector2.new(0.5, 0.5)
		coin.Position = UDim2.fromOffset(0, 0)
		coin.BackgroundColor3 = GOLD
		coin.BorderSizePixel = 0
		coin.ZIndex = 1

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = coin

		local coinStroke = Instance.new("UIStroke")
		coinStroke.Color = NAVY
		coinStroke.Thickness = 2
		coinStroke.Parent = coin

		coin.Parent = container

		local angle = math.random() * math.pi * 2
		local distance = math.random(40, 110)
		local flyTime = 0.4 + math.random() * 0.3
		local flyInfo = TweenInfo.new(flyTime, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
		TweenService:Create(coin, flyInfo, {
			Position = UDim2.fromOffset(math.cos(angle) * distance, math.sin(angle) * distance - 20),
			BackgroundTransparency = 1,
		}):Play()
		TweenService:Create(coinStroke, flyInfo, { Transparency = 1 }):Play()
	end

	-- The "+$X!" label
	local label = Instance.new("TextLabel")
	label.Name = "Amount"
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromOffset(0, 0)
	label.Size = UDim2.fromOffset(160, 60)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.Text = "+" .. FormatNumber.money(amount) .. "!"
	label.TextScaled = true
	label.TextColor3 = GREEN
	label.Rotation = math.random(-8, 8)
	label.ZIndex = 2

	local stroke = Instance.new("UIStroke")
	stroke.Color = NAVY
	stroke.Thickness = 4
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Parent = label

	label.Parent = container

	-- Spring ~80px up, then fade out in the second half.
	TweenService:Create(label, TweenInfo.new(0.7, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Position = UDim2.fromOffset(0, -80),
	}):Play()
	task.delay(0.35, function()
		if not container.Parent then
			return
		end
		local fadeInfo = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		TweenService:Create(label, fadeInfo, { TextTransparency = 1 }):Play()
		TweenService:Create(stroke, fadeInfo, { Transparency = 1 }):Play()
	end)

	ClientEffects.playSound("Coin")

	task.delay(1, function()
		container:Destroy()
	end)
end

----------------------------------------------------------------------
-- screenPop: quick HUD punch on earnings
----------------------------------------------------------------------

function ClientEffects.screenPop()
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return
	end
	local hud = playerGui:FindFirstChild("MainHUD")
	if not hud or not hud:IsA("ScreenGui") then
		return -- no HUD yet; nothing to pop
	end
	local scale = hud:FindFirstChild("ScreenPopScale")
	if not scale or not scale:IsA("UIScale") then
		scale = Instance.new("UIScale")
		scale.Name = "ScreenPopScale"
		scale.Parent = hud
	end
	local up = TweenService:Create(
		scale,
		TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Scale = 1.035 }
	)
	up:Play()
	up.Completed:Once(function()
		TweenService:Create(
			scale,
			TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Scale = 1 }
		):Play()
	end)
end

----------------------------------------------------------------------
-- sparkle: little star dots popping off a GuiObject (upgrades, claims)
----------------------------------------------------------------------

function ClientEffects.sparkle(guiObject: GuiObject)
	if typeof(guiObject) ~= "Instance" or not guiObject:IsA("GuiObject") then
		return
	end
	local gui = getEffectsGui()

	-- EffectsGui ignores the gui inset, AbsolutePosition does not: convert.
	local inset = GuiService:GetGuiInset()
	local center = guiObject.AbsolutePosition + guiObject.AbsoluteSize / 2 + inset

	local container = Instance.new("Frame")
	container.Name = "Sparkle"
	container.AnchorPoint = Vector2.new(0.5, 0.5)
	container.Position = UDim2.fromOffset(center.X, center.Y)
	container.Size = UDim2.fromOffset(0, 0)
	container.BackgroundTransparency = 1
	container.Parent = gui

	local halfX = math.max(guiObject.AbsoluteSize.X / 2, 10)
	local halfY = math.max(guiObject.AbsoluteSize.Y / 2, 10)

	for _ = 1, math.random(6, 10) do
		local star = Instance.new("Frame")
		local starSize = math.random(6, 11)
		star.Size = UDim2.fromOffset(starSize, starSize)
		star.AnchorPoint = Vector2.new(0.5, 0.5)
		star.BackgroundColor3 = if math.random() < 0.5 then WHITE else GOLD
		star.BorderSizePixel = 0
		star.Rotation = math.random(0, 90)

		local angle = math.random() * math.pi * 2
		local startX = math.cos(angle) * halfX * 0.6
		local startY = math.sin(angle) * halfY * 0.6
		star.Position = UDim2.fromOffset(startX, startY)
		star.Parent = container

		local distance = math.random(25, 60)
		TweenService:Create(star, TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Position = UDim2.fromOffset(
				startX + math.cos(angle) * distance,
				startY + math.sin(angle) * distance
			),
			Rotation = star.Rotation + math.random(90, 270),
			BackgroundTransparency = 1,
		}):Play()
	end

	task.delay(0.7, function()
		container:Destroy()
	end)
end

----------------------------------------------------------------------
-- celebrate: BIG full-screen rebirth celebration (~3.5s)
----------------------------------------------------------------------

local activeCelebration: Frame? = nil

function ClientEffects.celebrate(rebirths: number)
	local gui = getEffectsGui()

	if activeCelebration then
		activeCelebration:Destroy()
		activeCelebration = nil
	end

	local overlay = Instance.new("Frame")
	overlay.Name = "RebirthCelebration"
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.BackgroundTransparency = 1
	overlay.ZIndex = 10
	overlay.ClipsDescendants = false
	overlay.Parent = gui
	activeCelebration = overlay

	ClientEffects.playSound("Rebirth")

	-- White flash
	local flash = Instance.new("Frame")
	flash.Name = "Flash"
	flash.Size = UDim2.fromScale(1, 1)
	flash.BackgroundColor3 = WHITE
	flash.BackgroundTransparency = 0
	flash.BorderSizePixel = 0
	flash.ZIndex = 11
	flash.Parent = overlay
	TweenService:Create(
		flash,
		TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ BackgroundTransparency = 1 }
	):Play()

	-- Confetti rain: 40-60 colored rotated frames tumbling down, staggered
	for _ = 1, math.random(40, 60) do
		task.delay(math.random() * 0.8, function()
			if not overlay.Parent then
				return
			end
			local piece = Instance.new("Frame")
			piece.Size = UDim2.fromOffset(math.random(8, 16), math.random(10, 22))
			piece.BackgroundColor3 = CONFETTI_COLORS[math.random(#CONFETTI_COLORS)]
			piece.BorderSizePixel = 0
			piece.AnchorPoint = Vector2.new(0.5, 0.5)
			local startX = math.random()
			piece.Position = UDim2.fromScale(startX, -0.08)
			piece.Rotation = math.random(0, 360)
			piece.ZIndex = 12
			piece.Parent = overlay

			local fallTime = 1.4 + math.random() * 1.3
			local drift = (math.random() - 0.5) * 0.25
			local spin = math.random(180, 720) * (if math.random() < 0.5 then -1 else 1)
			TweenService:Create(piece, TweenInfo.new(fallTime, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				Position = UDim2.fromScale(math.clamp(startX + drift, 0, 1), 1.12),
				Rotation = piece.Rotation + spin,
			}):Play()
		end)
	end

	-- Giant "REBIRTH!" slamming in
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.AnchorPoint = Vector2.new(0.5, 0.5)
	title.Position = UDim2.fromScale(0.5, 0.42)
	title.Size = UDim2.fromScale(0.85, 0.22)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.LuckiestGuy
	title.Text = "REBIRTH!"
	title.TextScaled = true
	title.TextColor3 = GOLD
	title.TextTransparency = 1
	title.Rotation = -4
	title.ZIndex = 13

	local titleStroke = Instance.new("UIStroke")
	titleStroke.Color = NAVY
	titleStroke.Thickness = 6
	titleStroke.LineJoinMode = Enum.LineJoinMode.Round
	titleStroke.Transparency = 1
	titleStroke.Parent = title

	local titleScale = Instance.new("UIScale")
	titleScale.Scale = 3
	titleScale.Parent = title

	title.Parent = overlay

	local slamInfo = TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	TweenService:Create(titleScale, slamInfo, { Scale = 1 }):Play()
	local appearInfo = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(title, appearInfo, { TextTransparency = 0 }):Play()
	TweenService:Create(titleStroke, appearInfo, { Transparency = 0 }):Play()

	-- Subtitle: new multiplier
	local multiplier = GameConfig.getRebirthMultiplier(rebirths)
	local subtitle = Instance.new("TextLabel")
	subtitle.Name = "Subtitle"
	subtitle.AnchorPoint = Vector2.new(0.5, 0.5)
	subtitle.Position = UDim2.fromScale(0.5, 0.62)
	subtitle.Size = UDim2.fromScale(0.6, 0.07)
	subtitle.BackgroundTransparency = 1
	subtitle.Font = Enum.Font.FredokaOne
	subtitle.Text = "You are now x" .. tostring(multiplier) .. " faster!"
	subtitle.TextScaled = true
	subtitle.TextColor3 = WHITE
	subtitle.TextTransparency = 1
	subtitle.ZIndex = 13

	local subtitleStroke = Instance.new("UIStroke")
	subtitleStroke.Color = NAVY
	subtitleStroke.Thickness = 4
	subtitleStroke.LineJoinMode = Enum.LineJoinMode.Round
	subtitleStroke.Transparency = 1
	subtitleStroke.Parent = subtitle

	subtitle.Parent = overlay

	task.delay(0.45, function()
		if not overlay.Parent then
			return
		end
		local inInfo = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		TweenService:Create(subtitle, inInfo, {
			Position = UDim2.fromScale(0.5, 0.58),
			TextTransparency = 0,
		}):Play()
		TweenService:Create(subtitleStroke, inInfo, { Transparency = 0 }):Play()
	end)

	-- Fade everything out, then clean up fully.
	task.delay(2.9, function()
		if not overlay.Parent then
			return
		end
		local outInfo = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		TweenService:Create(title, outInfo, { TextTransparency = 1 }):Play()
		TweenService:Create(titleStroke, outInfo, { Transparency = 1 }):Play()
		TweenService:Create(subtitle, outInfo, { TextTransparency = 1 }):Play()
		TweenService:Create(subtitleStroke, outInfo, { Transparency = 1 }):Play()
	end)

	task.delay(3.6, function()
		if activeCelebration == overlay then
			activeCelebration = nil
		end
		overlay:Destroy()
	end)
end

return ClientEffects
