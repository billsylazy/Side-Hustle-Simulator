-- HustleController (LocalScript inside HustleGui) — v2
-- LEFT : one tab per GameConfig.Zones entry (in Order), cloned once from the
--        hidden Tabs.HustleTabTemplate. Locked zones show a lock + "Lv N".
-- RIGHT: the selected zone's Detail pane (ZoneName, Tagline, Preview,
--        LockedNote) and one row per zone.Upgrades entry, cloned once from the
--        hidden Rows.UpgradeRowTemplate and re-filled when the zone changes.
--   open        -> select the zone nearest the character (Mechanics.nearestZoneId)
--   DataSync    -> cache the snapshot; refresh lock state, levels, prices, preview
--   BuyButton   -> BuyUpgrade(zoneId, upgradeId)  (UpgradeService validates all)
--   a level increase on the shown zone -> sparkle the row + "LevelUp" sound
-- The client only displays and asks. Unaffordable taps still fire so the
-- server's "Not enough cash" toast explains why nothing happened.
-- See ARCHITECTURE.md "UI contract" and "Earnings, XP and mechanics".

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local Mechanics = require(Shared:WaitForChild("Mechanics"))
local FormatNumber = require(Shared:WaitForChild("FormatNumber"))
local ButtonFX = require(Shared:WaitForChild("ButtonFX"))
local ClientEffects = require(Shared:WaitForChild("ClientEffects"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local DataSync = Remotes:WaitForChild("DataSync") :: RemoteEvent
local BuyUpgrade = Remotes:WaitForChild("BuyUpgrade") :: RemoteEvent

local player = Players.LocalPlayer
local gui = script.Parent :: ScreenGui
local main = gui:WaitForChild("Main")
local panelScale = main:WaitForChild("PanelScale") :: UIScale
local panel = main:WaitForChild("Panel")
local tabsFrame = panel:WaitForChild("Tabs") :: ScrollingFrame
local tabTemplate = tabsFrame:WaitForChild("HustleTabTemplate") :: TextButton
local detail = panel:WaitForChild("Detail")
local zoneNameLabel = detail:WaitForChild("ZoneName") :: TextLabel
local taglineLabel = detail:WaitForChild("Tagline") :: TextLabel
local previewLabel = detail:WaitForChild("Preview") :: TextLabel
local lockedNote = detail:WaitForChild("LockedNote") :: TextLabel
local rowsFrame = detail:WaitForChild("Rows")
local rowTemplate = rowsFrame:WaitForChild("UpgradeRowTemplate") :: Frame
local closeButton = main:WaitForChild("CloseButton") :: GuiButton
local cashAmount = main:WaitForChild("CashPill"):WaitForChild("Amount") :: TextLabel

tabTemplate.Visible = false
rowTemplate.Visible = false

----------------------------------------------------------------------
-- Look constants (match hustlegui.spec.json)
----------------------------------------------------------------------

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

local WHITE = rgb(255, 255, 255) -- gradients show at full strength
local UNAFFORDABLE = rgb(135, 135, 145) -- multiplies the gradient toward gray
local GOLD = rgb(255, 212, 31)
local DARK_TEXT = rgb(58, 49, 83)
local MUTED_TEXT = rgb(138, 127, 158)

local GREEN_SEQUENCE = ColorSequence.new(rgb(71, 198, 78), rgb(42, 147, 42)) -- #47c64e -> #2a932a
local GOLD_SEQUENCE = ColorSequence.new(rgb(255, 212, 31), rgb(255, 123, 34)) -- #ffd41f -> #ff7b22
local TAB_SEQUENCE = ColorSequence.new(rgb(251, 248, 255), rgb(228, 218, 243))
local TAB_SELECTED_SEQUENCE = ColorSequence.new(rgb(255, 246, 204), rgb(255, 216, 107))
local ROW_SEQUENCE = ColorSequence.new(WHITE, rgb(239, 232, 250))
local ROW_AUTO_SEQUENCE = ColorSequence.new(rgb(255, 248, 214), rgb(255, 223, 126))

local TAB_STROKE = 2.5
local TAB_SELECTED_STROKE = 3.5
local TAB_NAME_SIZE = UDim2.new(1, -23, 1, -8)
local TAB_NAME_SIZE_LOCKED = UDim2.new(1, -51, 1, -8) -- leaves room for the lock

-- Row icon per upgrade Effect. The double-brace icon tokens below are replaced
-- by build_ui.py with the uploaded asset id (rbxassetid://0 until the spec's
-- icon_ids are filled in).
local EFFECT_ICONS: { [string]: string } = {
	Earn = "{{icon:Currency/Cash/Green Cash 1st}}",
	Xp = "{{icon:Main/Star/Blue Star 1st}}",
	Speed = "{{icon:Main/Lighting/Lighting 1st}}",
	Auto = "{{icon:Main/Rebirth and Auto Open/Auto Open 1st}}",
}

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------

local function findLabel(parent: Instance, name: string): TextLabel?
	-- FindFirstChild on purpose: a child literally named "Name" is shadowed by
	-- the Instance.Name property under dot access.
	local child = parent:FindFirstChild(name)
	return if child and child:IsA("TextLabel") then child else nil
end

local function findGui(parent: Instance, name: string): GuiObject?
	local child = parent:FindFirstChild(name)
	return if child and child:IsA("GuiObject") then child else nil
end

local function findGradient(parent: Instance, name: string): UIGradient?
	local child = parent:FindFirstChild(name)
	return if child and child:IsA("UIGradient") then child else nil
end

local function numberOr(value: any, default: number): number
	return if typeof(value) == "number" and value == value then value else default
end

local function secondsText(seconds: number): string
	if seconds == math.floor(seconds) then
		return tostring(math.floor(seconds))
	end
	return string.format("%.1f", seconds)
end

----------------------------------------------------------------------
-- Zones in Order (GameConfig.Zones is already ordered; sort defensively)
----------------------------------------------------------------------

local zones = table.clone(GameConfig.Zones)
table.sort(zones, function(a, b)
	return a.Order < b.Order
end)

local maxUpgradeCount = 0
for _, zone in zones do
	maxUpgradeCount = math.max(maxUpgradeCount, #zone.Upgrades)
end

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------

local lastSnapshot: { [string]: any }? = nil
local selectedZoneId: string = GameConfig.StartingZoneId

type TabEntry = {
	button: TextButton,
	zone: any, -- GameConfig.ZoneDef
	index: number,
	stroke: UIStroke?,
	gradient: UIGradient?,
	nameLabel: TextLabel?,
	lockIcon: GuiObject?,
	lockLabel: TextLabel?,
}

type RowEntry = {
	frame: Frame,
	accent: GuiObject?,
	icon: ImageLabel?,
	nameLabel: TextLabel?,
	descLabel: TextLabel?,
	levelLabel: TextLabel?,
	rowGradient: UIGradient?,
	buyButton: TextButton,
	buyGradient: UIGradient?,
	price: TextLabel?,
	dim: GuiObject?,
	zoneId: string?,
	upgradeId: string?,
	canBuy: boolean,
}

local tabs: { [string]: TabEntry } = {}
local rows: { RowEntry } = {}

----------------------------------------------------------------------
-- Preview line: the contract's earnings formulas without the mechanic
-- multiplier, e.g. "$3 + 2 XP per Squeeze  -  0.6s | Auto: $1 every 2s"
----------------------------------------------------------------------

local function previewText(zone: any, upgrades: any, rebirths: number): string
	local effects = GameConfig.UpgradeEffects
	local earnLevel = GameConfig.getZoneEffectLevel(upgrades, zone.Id, "Earn")
	local xpLevel = GameConfig.getZoneEffectLevel(upgrades, zone.Id, "Xp")
	local autoLevel = GameConfig.getZoneEffectLevel(upgrades, zone.Id, "Auto")

	-- Round to nearest, exactly as HustleService pays.
	local cash = math.floor(
		zone.HustleEarn * (1 + effects.Earn.PerLevel * earnLevel) * GameConfig.getRebirthCashMultiplier(rebirths) + 0.5
	)
	local xp = math.floor(
		zone.XpPerHustle * (1 + effects.Xp.PerLevel * xpLevel) * GameConfig.getRebirthXpMultiplier(rebirths) + 0.5
	)
	local cooldown = Mechanics.cooldownFor(zone, upgrades)

	local text = string.format(
		"%s + %s XP per %s  -  %.1fs",
		FormatNumber.money(cash),
		FormatNumber.abbreviate(xp),
		zone.HustleVerb,
		cooldown
	)
	if autoLevel > 0 then
		local autoCash = math.floor(cash * Mechanics.autoPercent(autoLevel) + 0.5)
		text ..= " | Auto: " .. FormatNumber.money(autoCash) .. " every " .. secondsText(effects.Auto.Interval) .. "s"
	end
	return text
end

----------------------------------------------------------------------
-- Refresh everything from the cached snapshot (defaults before the first one)
----------------------------------------------------------------------

local function refresh()
	local snapshot = lastSnapshot or {}
	local level = numberOr(snapshot.Level, 1)
	local cash = numberOr(snapshot.Cash, 0)
	local rebirths = numberOr(snapshot.Rebirths, 0)
	local upgrades = snapshot.Upgrades -- any; GameConfig helpers tolerate nil/garbage

	cashAmount.Text = FormatNumber.money(cash)

	-- Tabs: lock badge + selection highlight.
	for zoneId, entry in tabs do
		local locked = level < entry.zone.UnlockLevel
		local selected = zoneId == selectedZoneId
		if entry.lockIcon then
			entry.lockIcon.Visible = locked
		end
		if entry.lockLabel then
			entry.lockLabel.Visible = locked
			entry.lockLabel.Text = "Lv " .. entry.zone.UnlockLevel
		end
		if entry.nameLabel then
			entry.nameLabel.Size = if locked then TAB_NAME_SIZE_LOCKED else TAB_NAME_SIZE
			entry.nameLabel.TextColor3 = if locked then MUTED_TEXT else DARK_TEXT
		end
		if entry.stroke then
			entry.stroke.Thickness = if selected then TAB_SELECTED_STROKE else TAB_STROKE
		end
		if entry.gradient then
			entry.gradient.Color = if selected then TAB_SELECTED_SEQUENCE else TAB_SEQUENCE
		end
	end

	-- Detail pane for the selected zone.
	local zone = GameConfig.getZone(selectedZoneId)
	if not zone then
		return
	end
	local locked = level < zone.UnlockLevel

	zoneNameLabel.Text = string.upper(zone.Name)
	zoneNameLabel.TextColor3 = zone.SignColor
	taglineLabel.Text = zone.Tagline
	previewLabel.Text = previewText(zone, upgrades, rebirths)
	lockedNote.Text = "Reach level " .. zone.UnlockLevel .. " to unlock"
	lockedNote.Visible = locked

	for index, entry in rows do
		local def = zone.Upgrades[index]
		if not def then
			entry.frame.Visible = false
			entry.zoneId = nil
			entry.upgradeId = nil
			entry.canBuy = false
			continue
		end
		entry.frame.Visible = true
		entry.zoneId = zone.Id
		entry.upgradeId = def.Id

		local isAuto = def.Effect == "Auto"
		if entry.nameLabel then
			entry.nameLabel.Text = def.Name
		end
		if entry.descLabel then
			entry.descLabel.Text = def.Description
		end
		if entry.icon then
			local image = EFFECT_ICONS[def.Effect]
			if image then
				entry.icon.Image = image
			end
		end
		if entry.accent then
			entry.accent.BackgroundColor3 = if isAuto then GOLD else zone.SignColor
		end
		if entry.rowGradient then
			entry.rowGradient.Color = if isAuto then ROW_AUTO_SEQUENCE else ROW_SEQUENCE
		end

		local upgradeLevel = GameConfig.getZoneUpgradeLevel(upgrades, zone.Id, def.Id)
		if entry.levelLabel then
			entry.levelLabel.Text = "Lv " .. upgradeLevel .. "/" .. def.MaxLevel
		end

		local cost = GameConfig.getZoneUpgradeCost(zone.Id, def.Id, upgradeLevel)
		local button = entry.buyButton
		if cost == nil then
			-- Maxed out: gold MAX button that no longer accepts taps.
			if entry.price then
				entry.price.Text = "MAX"
			end
			if entry.buyGradient then
				entry.buyGradient.Color = GOLD_SEQUENCE
			end
			button.BackgroundColor3 = WHITE
			entry.canBuy = false
		else
			if entry.price then
				entry.price.Text = FormatNumber.money(cost)
			end
			if entry.buyGradient then
				entry.buyGradient.Color = GREEN_SEQUENCE
			end
			button.BackgroundColor3 = if not locked and cash >= cost then WHITE else UNAFFORDABLE
			entry.canBuy = not locked
		end
		button.Active = entry.canBuy
		button.AutoButtonColor = entry.canBuy

		-- Locked zone: the whole row sits under a cream veil, buttons inactive.
		if entry.dim then
			entry.dim.Visible = locked
		end
	end
end

----------------------------------------------------------------------
-- Build tabs + rows once
----------------------------------------------------------------------

local function selectZone(zoneId: string)
	if not GameConfig.getZone(zoneId) then
		return
	end
	selectedZoneId = zoneId
	refresh()
end

for index, zone in zones do
	local button = tabTemplate:Clone()
	button.Name = zone.Id
	button.LayoutOrder = zone.Order
	button.Visible = true

	local stripe = findGui(button, "Stripe")
	if stripe then
		stripe.BackgroundColor3 = zone.SignColor
	end
	local nameLabel = findLabel(button, "Name")
	if nameLabel then
		nameLabel.Text = zone.Name
	end
	local lockLabel = findLabel(button, "LockLabel")
	if lockLabel then
		lockLabel.Text = "Lv " .. zone.UnlockLevel
	end
	local strokeChild = button:FindFirstChild("Stroke")

	tabs[zone.Id] = {
		button = button,
		zone = zone,
		index = index,
		stroke = if strokeChild and strokeChild:IsA("UIStroke") then strokeChild else nil,
		gradient = findGradient(button, "Grad"),
		nameLabel = nameLabel,
		lockIcon = findGui(button, "LockIcon"),
		lockLabel = lockLabel,
	}

	local zoneId = zone.Id
	button.Activated:Connect(function()
		selectZone(zoneId)
	end)
	ButtonFX.attach(button)
	button.Parent = tabsFrame
end

for index = 1, maxUpgradeCount do
	local frame = rowTemplate:Clone()
	frame.Name = "UpgradeRow" .. index
	frame.LayoutOrder = index
	frame.Visible = true

	local buyButton = frame:WaitForChild("BuyButton") :: TextButton
	local icon = frame:FindFirstChild("Icon")
	local entry: RowEntry = {
		frame = frame,
		accent = findGui(frame, "Accent"),
		icon = if icon and icon:IsA("ImageLabel") then icon else nil,
		nameLabel = findLabel(frame, "Name"),
		descLabel = findLabel(frame, "Desc"),
		levelLabel = findLabel(frame, "Level"),
		rowGradient = findGradient(frame, "Grad"),
		buyButton = buyButton,
		buyGradient = findGradient(buyButton, "Grad"),
		price = findLabel(buyButton, "Price"),
		dim = findGui(frame, "Dim"),
		zoneId = nil,
		upgradeId = nil,
		canBuy = false,
	}
	rows[index] = entry

	buyButton.Activated:Connect(function()
		-- Locked / maxed rows ignore taps (Active=false too); the server
		-- re-validates level, unlock and cash regardless.
		local zoneId, upgradeId = entry.zoneId, entry.upgradeId
		if not entry.canBuy or not zoneId or not upgradeId then
			return
		end
		BuyUpgrade:FireServer(zoneId, upgradeId)
	end)
	ButtonFX.attach(buyButton)
	frame.Parent = rowsFrame
end

----------------------------------------------------------------------
-- Open: nearest zone, scroll its tab into view, refresh, bounce
----------------------------------------------------------------------

local function nearestZoneId(): string
	local character = player.Character
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	if root and root:IsA("BasePart") then
		local zoneId = Mechanics.nearestZoneId(root.Position)
		if GameConfig.getZone(zoneId) then
			return zoneId
		end
	end
	return GameConfig.StartingZoneId
end

local function scrollTabIntoView(zoneId: string)
	local entry = tabs[zoneId]
	if not entry then
		return
	end
	-- Offsets from the spec (tab height + list padding); keep one tab of
	-- context above the selected one. The ScrollingFrame clamps the rest.
	local layout = tabsFrame:FindFirstChildOfClass("UIListLayout")
	local step = tabTemplate.Size.Y.Offset + (if layout then layout.Padding.Offset else 0)
	tabsFrame.CanvasPosition = Vector2.new(0, math.max(0, (entry.index - 2) * step))
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
		selectedZoneId = nearestZoneId()
		refresh()
		scrollTabIntoView(selectedZoneId)
		bounceOpen()
	end
end)

----------------------------------------------------------------------
-- DataSync: cache, refresh while open, juice level increases on the shown zone
----------------------------------------------------------------------

DataSync.OnClientEvent:Connect(function(snapshot: any)
	if typeof(snapshot) ~= "table" then
		return
	end
	local previous = lastSnapshot
	lastSnapshot = snapshot
	if not gui.Enabled then
		return
	end
	refresh()

	-- Compare consecutive snapshots (not "last shown") so switching tabs never
	-- fakes a level-up, and a rebirth reset (levels drop) stays quiet.
	local zone = GameConfig.getZone(selectedZoneId)
	if not previous or not zone then
		return
	end
	local leveled = false
	for index, def in zone.Upgrades do
		local before = GameConfig.getZoneUpgradeLevel(previous.Upgrades, zone.Id, def.Id)
		local after = GameConfig.getZoneUpgradeLevel(snapshot.Upgrades, zone.Id, def.Id)
		if after > before then
			leveled = true
			local entry = rows[index]
			if entry then
				ClientEffects.sparkle(entry.frame)
			end
		end
	end
	if leveled then
		ClientEffects.playSound("LevelUp")
	end
end)

----------------------------------------------------------------------
-- Close
----------------------------------------------------------------------

closeButton.Activated:Connect(function()
	gui.Enabled = false
end)
ButtonFX.attach(closeButton)

-- Never show template placeholder text, even if opened before the first DataSync.
refresh()
