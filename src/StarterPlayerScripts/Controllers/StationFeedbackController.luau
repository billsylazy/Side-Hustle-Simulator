-- StationFeedbackController: per-zone BillboardGui on HustleStation.FeedbackPart
-- showing the mechanic's live feedback:
--   Tap    - combo counter "x3" (shows at combo >= 2, fades after ComboWindow)
--   Hold   - the zone's verb hint ("Hold to Walk")
--   Timing - live hype meter: needle = Mechanics.marketFactor(zone, serverTime),
--            green PEAK region on the right where marketMult >= PeakThreshold
--   Charge - ChargeMax-segment charge bar lit per HustleResult Charge; all
--            segments flash on a Burst
-- Also fires ClientEffects.callout on Burst ("VIRAL!"/"FUNDED!") and Peak
-- ("PEAK FLIP!"/"PEAK TRADE!") results.
--
-- Performance: only the zone nearest the player plus zones with a manual
-- HustleResult in the last 3s are rendered (BillboardGui.Enabled); needles
-- update only while rendered. Zones may stream in late (WaitForChild timeouts).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(sharedFolder:WaitForChild("GameConfig"))
local Mechanics = require(sharedFolder:WaitForChild("Mechanics"))
local ClientEffects = require(sharedFolder:WaitForChild("ClientEffects"))

local player = Players.LocalPlayer

-- Palette (UI contract: cream panels, #040435 strokes)
local NAVY = Color3.fromRGB(4, 4, 53)
local WHITE = Color3.fromRGB(255, 255, 255)
local GREEN = Color3.fromRGB(71, 198, 78)
local GOLD = Color3.fromRGB(255, 200, 40)
local RED = Color3.fromRGB(240, 48, 48)
local DIM = Color3.fromRGB(28, 28, 60)

local RECENT_WINDOW = 3 -- seconds a zone stays rendered after a manual result
local COMBO_WINDOW = GameConfig.Mechanics.Tap.ComboWindow
local COMBO_MAX = GameConfig.Mechanics.Tap.ComboMax
local TIMING = GameConfig.Mechanics.Timing
-- Needle factor at which marketMult reaches PeakThreshold (0.85 with defaults).
local PEAK_START = math.clamp(
	(TIMING.PeakThreshold - TIMING.MinMult) / math.max(TIMING.MaxMult - TIMING.MinMult, 1e-6),
	0,
	1
)

local BURST_TEXT: { [string]: string } = { ContentCreator = "VIRAL!", StartupHQ = "FUNDED!" }
local PEAK_TEXT: { [string]: string } = { SneakerFlipping = "PEAK FLIP!", StockDesk = "PEAK TRADE!" }
local METER_TITLE: { [string]: string } = { StockDesk = "MARKET", SneakerFlipping = "HYPE" }
local CHARGE_TITLE: { [string]: string } = { StartupHQ = "FUNDING", ContentCreator = "HYPE" }

type Station = {
	zoneId: string,
	zone: GameConfig.ZoneDef,
	mechanic: string,
	gui: BillboardGui,
	enabled: boolean,
	-- Tap
	comboLabel: TextLabel?,
	comboStroke: UIStroke?,
	comboScale: UIScale?,
	hintLabel: TextLabel?,
	hintStroke: UIStroke?,
	comboVisible: boolean,
	comboUntil: number,
	-- Timing
	needle: Frame?,
	meterTitle: TextLabel?,
	inPeak: boolean,
	-- Charge
	segments: { Frame },
	lit: number,
	flashing: boolean,
	pendingCharge: number?, -- charge that arrived during a burst flash
}

local stations: { [string]: Station } = {}
local registering: { [string]: boolean } = {}
local warnedZones: { [string]: boolean } = {}
local lastResultAt: { [string]: number } = {}
local currentHrp: BasePart? = nil
local started = false

local StationFeedbackController = {}

----------------------------------------------------------------------
-- GUI builders
----------------------------------------------------------------------

local function makeLabel(
	parent: Instance,
	name: string,
	text: string,
	font: Enum.Font,
	color: Color3,
	position: UDim2,
	size: UDim2,
	strokeThickness: number
): (TextLabel, UIStroke)
	local label = Instance.new("TextLabel")
	label.Name = name
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = position
	label.Size = size
	label.BackgroundTransparency = 1
	label.Font = font
	label.Text = text
	label.TextScaled = true
	label.TextColor3 = color
	label.ZIndex = 3

	local stroke = Instance.new("UIStroke")
	stroke.Color = NAVY
	stroke.Thickness = strokeThickness
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Parent = label

	label.Parent = parent
	return label, stroke
end

local function roundify(frame: GuiObject, radiusScale: number, strokeColor: Color3?, strokeThickness: number?)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(radiusScale, 0)
	corner.Parent = frame
	if strokeColor then
		local stroke = Instance.new("UIStroke")
		stroke.Color = strokeColor
		stroke.Thickness = strokeThickness or 2
		stroke.Parent = frame
	end
end

-- A color readable on its own in world space: near-white sign colors (Startup
-- HQ) fall back to the zone accent.
local function zoneBrightColor(zone: GameConfig.ZoneDef): Color3
	local c = zone.SignColor
	local luminance = 0.299 * c.R + 0.587 * c.G + 0.114 * c.B
	return if luminance > 0.9 then zone.AccentColor else c
end

local function buildTap(station: Station, root: Frame)
	local zone = station.zone
	local combo, comboStroke = makeLabel(
		root, "Combo", "x2", Enum.Font.LuckiestGuy, zoneBrightColor(zone),
		UDim2.fromScale(0.5, 0.4), UDim2.fromScale(1, 0.72), 4
	)
	combo.TextTransparency = 1
	comboStroke.Transparency = 1
	local scale = Instance.new("UIScale")
	scale.Parent = combo

	local hint, hintStroke = makeLabel(
		root, "Hint", ("Mash %s!"):format(zone.HustleVerb:upper()), Enum.Font.FredokaOne, WHITE,
		UDim2.fromScale(0.5, 0.84), UDim2.fromScale(1, 0.3), 2.5
	)

	station.comboLabel = combo
	station.comboStroke = comboStroke
	station.comboScale = scale
	station.hintLabel = hint
	station.hintStroke = hintStroke
end

local function buildHold(station: Station, root: Frame)
	local zone = station.zone
	local hint = makeLabel(
		root, "Hint", ("Hold to %s"):format(zone.HustleVerb), Enum.Font.FredokaOne, WHITE,
		UDim2.fromScale(0.5, 0.5), UDim2.fromScale(1, 0.5), 3
	)
	-- Gentle breathing pulse: one looping tween, zero per-frame cost.
	local scale = Instance.new("UIScale")
	scale.Parent = hint
	TweenService:Create(
		scale,
		TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Scale = 1.07 }
	):Play()
	station.hintLabel = hint
end

local function buildTiming(station: Station, root: Frame)
	local zone = station.zone
	local bright = zoneBrightColor(zone)

	local title = makeLabel(
		root, "Title", METER_TITLE[zone.Id] or "HYPE", Enum.Font.LuckiestGuy, WHITE,
		UDim2.fromScale(0.36, 0.18), UDim2.fromScale(0.7, 0.3), 2.5
	)
	makeLabel(
		root, "PeakLabel", "PEAK", Enum.Font.LuckiestGuy, GREEN,
		UDim2.fromScale(0.86, 0.18), UDim2.fromScale(0.26, 0.26), 2
	)

	-- Track in zone colors (accent -> sign gradient) with a navy stroke
	local meter = Instance.new("Frame")
	meter.Name = "Meter"
	meter.AnchorPoint = Vector2.new(0.5, 0.5)
	meter.Position = UDim2.fromScale(0.5, 0.64)
	meter.Size = UDim2.fromScale(0.96, 0.34)
	meter.BackgroundColor3 = WHITE
	meter.BorderSizePixel = 0
	meter.ZIndex = 1
	roundify(meter, 0.5, NAVY, 2.5)
	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, zone.AccentColor),
		ColorSequenceKeypoint.new(1, zone.SignColor),
	})
	gradient.Parent = meter
	meter.Parent = root

	-- Green PEAK region on the right end
	local peak = Instance.new("Frame")
	peak.Name = "PeakZone"
	peak.AnchorPoint = Vector2.new(1, 0.5)
	peak.Position = UDim2.fromScale(1, 0.5)
	peak.Size = UDim2.fromScale(1 - PEAK_START, 1)
	peak.BackgroundColor3 = GREEN
	peak.BorderSizePixel = 0
	peak.ZIndex = 2
	roundify(peak, 0.5)
	peak.Parent = meter

	-- Needle
	local needle = Instance.new("Frame")
	needle.Name = "Needle"
	needle.AnchorPoint = Vector2.new(0.5, 0.5)
	needle.Position = UDim2.fromScale(0, 0.5)
	needle.Size = UDim2.fromScale(0.05, 1.6)
	needle.BackgroundColor3 = WHITE
	needle.BorderSizePixel = 0
	needle.ZIndex = 4
	roundify(needle, 0.4, NAVY, 2)
	needle.Parent = meter

	station.needle = needle
	station.meterTitle = title
	station.inPeak = false
	title.TextColor3 = bright
end

local function buildCharge(station: Station, root: Frame)
	local zone = station.zone
	local count = math.max(math.floor(zone.ChargeMax), 1)

	makeLabel(
		root, "Title", CHARGE_TITLE[zone.Id] or "CHARGE", Enum.Font.LuckiestGuy, zoneBrightColor(zone),
		UDim2.fromScale(0.5, 0.18), UDim2.fromScale(1, 0.3), 2.5
	)

	local row = Instance.new("Frame")
	row.Name = "Segments"
	row.AnchorPoint = Vector2.new(0.5, 0.5)
	row.Position = UDim2.fromScale(0.5, 0.64)
	row.Size = UDim2.fromScale(0.96, 0.36)
	row.BackgroundTransparency = 1
	row.Parent = root

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0.025, 0)
	layout.Parent = row

	local gap = 0.025
	local width = (1 - gap * (count - 1)) / count
	for index = 1, count do
		local segment = Instance.new("Frame")
		segment.Name = "Segment" .. tostring(index)
		segment.LayoutOrder = index
		segment.Size = UDim2.fromScale(width, 1)
		segment.BackgroundColor3 = DIM
		segment.BackgroundTransparency = 0.35
		segment.BorderSizePixel = 0
		roundify(segment, 0.3, NAVY, 2)
		local scale = Instance.new("UIScale")
		scale.Parent = segment
		segment.Parent = row
		table.insert(station.segments, segment)
	end
end

local function buildStationGui(station: Station, feedbackPart: BasePart)
	local gui = Instance.new("BillboardGui")
	gui.Name = "StationFeedback"
	gui.Adornee = feedbackPart
	gui.Size = UDim2.new(6, 0, 2, 0) -- studs
	gui.AlwaysOnTop = false
	gui.MaxDistance = 120
	gui.LightInfluence = 0
	gui.Enabled = false
	gui.ResetOnSpawn = false

	local root = Instance.new("Frame")
	root.Name = "Root"
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundTransparency = 1
	root.Parent = gui

	local mechanic = station.mechanic
	if mechanic == "Tap" then
		buildTap(station, root)
	elseif mechanic == "Hold" then
		buildHold(station, root)
	elseif mechanic == "Timing" then
		buildTiming(station, root)
	elseif mechanic == "Charge" then
		buildCharge(station, root)
	else
		makeLabel(
			root, "Hint", station.zone.HustleVerb .. "!", Enum.Font.FredokaOne, WHITE,
			UDim2.fromScale(0.5, 0.5), UDim2.fromScale(1, 0.5), 3
		)
	end

	gui.Parent = feedbackPart
	station.gui = gui
end

----------------------------------------------------------------------
-- Per-mechanic updates
----------------------------------------------------------------------

local function showCombo(station: Station, combo: number, now: number)
	local label = station.comboLabel
	local stroke = station.comboStroke
	local scale = station.comboScale
	if not label or not stroke or not scale then
		return
	end
	local heat = math.clamp((combo - 2) / math.max(COMBO_MAX - 2, 1), 0, 1)
	label.Text = ("x%d"):format(math.floor(combo))
	label.TextColor3 = zoneBrightColor(station.zone):Lerp(RED, heat * 0.8)
	label.TextTransparency = 0
	stroke.Transparency = 0
	scale.Scale = 1.5
	TweenService:Create(scale, TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Scale = 1,
	}):Play()
	if station.hintLabel and station.hintStroke then
		station.hintLabel.TextTransparency = 1
		station.hintStroke.Transparency = 1
	end
	station.comboVisible = true
	station.comboUntil = now + COMBO_WINDOW
end

local function hideCombo(station: Station)
	if not station.comboVisible then
		return
	end
	station.comboVisible = false
	local label = station.comboLabel
	local stroke = station.comboStroke
	if label and stroke then
		local info = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		TweenService:Create(label, info, { TextTransparency = 1 }):Play()
		TweenService:Create(stroke, info, { Transparency = 1 }):Play()
	end
	if station.hintLabel and station.hintStroke then
		local info = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		TweenService:Create(station.hintLabel, info, { TextTransparency = 0 }):Play()
		TweenService:Create(station.hintStroke, info, { Transparency = 0 }):Play()
	end
end

local function updateNeedle(station: Station, serverNow: number)
	local needle = station.needle
	if not needle then
		return
	end
	local factor = Mechanics.marketFactor(station.zone, serverNow)
	needle.Position = UDim2.fromScale(factor, 0.5)

	local inPeak = factor >= PEAK_START
	if inPeak ~= station.inPeak then
		station.inPeak = inPeak
		needle.BackgroundColor3 = if inPeak then GOLD else WHITE
		local title = station.meterTitle
		if title then
			if inPeak then
				title.Text = ("%s NOW!"):format(station.zone.HustleVerb:upper())
				title.TextColor3 = GOLD
			else
				title.Text = METER_TITLE[station.zoneId] or "HYPE"
				title.TextColor3 = zoneBrightColor(station.zone)
			end
		end
	end
end

local function setSegmentLit(station: Station, segment: Frame, lit: boolean, pop: boolean)
	segment.BackgroundColor3 = if lit then station.zone.SignColor else DIM
	segment.BackgroundTransparency = if lit then 0 else 0.35
	if pop then
		local scale = segment:FindFirstChildOfClass("UIScale")
		if scale then
			scale.Scale = 1.35
			TweenService:Create(scale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
				Scale = 1,
			}):Play()
		end
	end
end

local function setCharge(station: Station, charge: number)
	if station.flashing then
		-- A hit can land mid-flash (charge cooldown < flash length): keep it
		-- and apply it when the flash ends instead of dropping it.
		station.pendingCharge = charge
		return
	end
	local target = math.clamp(math.floor(charge), 0, #station.segments)
	for index, segment in station.segments do
		local lit = index <= target
		setSegmentLit(station, segment, lit, lit and index > station.lit)
	end
	station.lit = target
end

local function flashBurst(station: Station)
	if #station.segments == 0 then
		return
	end
	station.flashing = true
	for _, segment in station.segments do
		segment.BackgroundColor3 = station.zone.SignColor
		segment.BackgroundTransparency = 0
		TweenService:Create(segment, TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			BackgroundColor3 = WHITE,
		}):Play()
	end
	task.delay(0.45, function()
		if station.gui.Parent == nil then
			return
		end
		local fades: { Tween } = {}
		for _, segment in station.segments do
			local fade = TweenService:Create(segment, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				BackgroundColor3 = DIM,
				BackgroundTransparency = 0.35,
			})
			fade:Play()
			table.insert(fades, fade)
		end
		station.lit = 0
		task.delay(0.35, function()
			-- Stop the fades first: a fade finishing a frame later would paint
			-- the replayed pending segment back to dim.
			for _, fade in fades do
				fade:Cancel()
			end
			for _, segment in station.segments do
				segment.BackgroundColor3 = DIM
				segment.BackgroundTransparency = 0.35
			end
			station.flashing = false
			local pending = station.pendingCharge
			station.pendingCharge = nil
			if pending then
				setCharge(station, pending)
			end
		end)
	end)
end

----------------------------------------------------------------------
-- HustleResult -> feedback + callouts
----------------------------------------------------------------------

local function onHustleResult(zoneId: any, result: any)
	if type(zoneId) ~= "string" or type(result) ~= "table" then
		return
	end
	local zone = GameConfig.getZone(zoneId)
	if not zone then
		return
	end
	local kind = result.Kind
	local now = os.clock()

	-- Auto payouts are not player actions: they neither keep the station
	-- rendered nor touch the combo/charge displays.
	if kind == "Auto" then
		return
	end
	lastResultAt[zoneId] = now

	if kind == "Burst" then
		ClientEffects.callout(BURST_TEXT[zoneId] or "BURST!", zoneBrightColor(zone))
	elseif kind == "Peak" then
		ClientEffects.callout(PEAK_TEXT[zoneId] or "PEAK!", zoneBrightColor(zone))
	end

	local station = stations[zoneId]
	if not station or station.gui.Parent == nil then
		return
	end

	if station.mechanic == "Tap" then
		local combo = result.Combo
		if type(combo) == "number" and combo >= 2 then
			showCombo(station, combo, now)
		else
			hideCombo(station)
		end
	elseif station.mechanic == "Charge" then
		if kind == "Burst" then
			flashBurst(station)
		else
			local charge = result.Charge
			setCharge(station, if type(charge) == "number" then charge else 0)
		end
	end
end

----------------------------------------------------------------------
-- Heartbeat: render only the nearest zone + recently hustled zones
----------------------------------------------------------------------

local function onHeartbeat()
	local now = os.clock()
	local nearestId: string? = nil
	local hrp = currentHrp
	if hrp and hrp.Parent ~= nil then
		nearestId = Mechanics.nearestZoneId(hrp.Position)
	end
	local serverNow = workspace:GetServerTimeNow()

	for zoneId, station in stations do
		if station.gui.Parent == nil then
			continue -- streamed out; re-registered when the zone returns
		end
		local lastAt = lastResultAt[zoneId]
		local recent = lastAt ~= nil and now - lastAt < RECENT_WINDOW
		local active = zoneId == nearestId or recent
		if active ~= station.enabled then
			station.enabled = active
			station.gui.Enabled = active
		end
		if not active then
			continue
		end
		if station.mechanic == "Timing" then
			updateNeedle(station, serverNow)
		elseif station.mechanic == "Tap" then
			if station.comboVisible and now >= station.comboUntil then
				hideCombo(station)
			end
		end
	end
end

----------------------------------------------------------------------
-- Zone registration (WaitForChild with timeouts; zones may stream in late)
----------------------------------------------------------------------

local function warnOnce(zoneId: string, message: string)
	if warnedZones[zoneId] then
		return
	end
	warnedZones[zoneId] = true
	warn(("[StationFeedbackController] %s: %s"):format(zoneId, message))
end

local function registerZone(zoneModel: Instance)
	local zoneId = zoneModel.Name
	local zone = GameConfig.getZone(zoneId)
	if not zone then
		return -- not a zone model
	end
	local existing = stations[zoneId]
	if existing and existing.gui.Parent ~= nil then
		return -- alive already
	end
	if registering[zoneId] then
		return
	end
	registering[zoneId] = true

	local stationModel = zoneModel:WaitForChild("HustleStation", 20)
	local feedbackPart = if stationModel then stationModel:WaitForChild("FeedbackPart", 20) else nil
	registering[zoneId] = nil
	if not feedbackPart or not feedbackPart:IsA("BasePart") then
		warnOnce(zoneId, "HustleStation has no FeedbackPart")
		return
	end
	if zoneModel.Parent == nil then
		return -- streamed out while we waited; ChildAdded re-registers
	end

	if existing then
		existing.gui:Destroy()
		stations[zoneId] = nil
	end

	local station: Station = {
		zoneId = zoneId,
		zone = zone,
		mechanic = zone.Mechanic,
		gui = nil :: any, -- set by buildStationGui
		enabled = false,
		comboLabel = nil,
		comboStroke = nil,
		comboScale = nil,
		hintLabel = nil,
		hintStroke = nil,
		comboVisible = false,
		comboUntil = 0,
		needle = nil,
		meterTitle = nil,
		inPeak = false,
		segments = {},
		lit = 0,
		flashing = false,
	}
	buildStationGui(station, feedbackPart)
	stations[zoneId] = station
end

----------------------------------------------------------------------
-- Character tracking (nearest-zone test needs the HRP)
----------------------------------------------------------------------

local function onCharacterAdded(character: Model)
	currentHrp = nil
	task.spawn(function()
		local hrp = character:WaitForChild("HumanoidRootPart", 30)
		if hrp and hrp:IsA("BasePart") and character.Parent ~= nil and player.Character == character then
			currentHrp = hrp
		end
	end)
end

----------------------------------------------------------------------
-- Entry point
----------------------------------------------------------------------

function StationFeedbackController.start(): ()
	if started then
		return
	end
	started = true

	player.CharacterAdded:Connect(onCharacterAdded)
	player.CharacterRemoving:Connect(function()
		currentHrp = nil
	end)
	if player.Character then
		onCharacterAdded(player.Character)
	end

	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("Remotes")
		local hustleResult = remotes:WaitForChild("HustleResult")
		hustleResult.OnClientEvent:Connect(onHustleResult)
	end)

	task.spawn(function()
		local map = workspace:WaitForChild("SideHustleMap", 60)
		if not map then
			warn("[StationFeedbackController] Workspace.SideHustleMap never appeared")
			return
		end
		local zonesFolder = map:WaitForChild("Zones", 30)
		if not zonesFolder then
			warn("[StationFeedbackController] SideHustleMap.Zones never appeared")
			return
		end
		zonesFolder.ChildAdded:Connect(function(child)
			task.spawn(registerZone, child)
		end)
		for _, child in zonesFolder:GetChildren() do
			task.spawn(registerZone, child)
		end
	end)

	RunService.Heartbeat:Connect(onHeartbeat)
end

return StationFeedbackController
