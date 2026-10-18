--!nonstrict
-- MapKit: primitive part helpers + shared palette for the World builders
-- (MapBuilder, CityBuilder, ZoneDressing). Blocks / Balls / Cylinders /
-- Wedges / CornerWedges only: no meshes, no Toolbox, no asset ids. Every part
-- is Anchored, SmoothPlastic unless told otherwise, smooth surfaces.

local MapKit = {}

local RAD_90 = math.rad(90)
MapKit.RAD_90 = RAD_90

----------------------------------------------------------------------
-- Shared palette
----------------------------------------------------------------------

MapKit.NAVY = Color3.fromRGB(4, 4, 53)
MapKit.WHITE = Color3.fromRGB(248, 248, 244)
MapKit.CREAM = Color3.fromRGB(247, 238, 214)
MapKit.WOOD = Color3.fromRGB(133, 94, 62)
MapKit.DARK_WOOD = Color3.fromRGB(96, 66, 42)
MapKit.LEAF_GREEN = Color3.fromRGB(76, 160, 66)
MapKit.LAMP_WARM = Color3.fromRGB(255, 220, 160)
-- Cartoon slate blue, not near-black: dark hardware at eye level reads as
-- gritty next to the bright city (everything is SmoothPlastic, see applyCommon).
MapKit.METAL_DARK = Color3.fromRGB(78, 92, 140)
MapKit.WHEEL_DARK = Color3.fromRGB(38, 38, 42)
MapKit.NEON_WHITE = Color3.fromRGB(255, 255, 255) -- marquee frames around signature boards
-- Street hardware is toy-city cobalt, never gunmetal / near-black: poles,
-- arms, legs and posts in STREET_POLE, their foot plates in STREET_BASE.
MapKit.STREET_POLE = Color3.fromRGB(60, 96, 196)
MapKit.STREET_BASE = Color3.fromRGB(44, 72, 160)
-- Tree trunks: a warm cartoon brown (DARK_WOOD Wood rendered near-black in shade).
MapKit.TRUNK = Color3.fromRGB(150, 102, 64)
-- Stock Desk screens / backdrop / ticker pillars: a deep ticker green (a local
-- override of the zone's near-black AccentColor, which stays in GameConfig).
MapKit.STOCK_DEEP_GREEN = Color3.fromRGB(18, 84, 58)

-- Bright flower heads (plaza beds, planters, window boxes).
MapKit.FLOWER_COLORS = {
	Color3.fromRGB(255, 212, 31),
	Color3.fromRGB(255, 92, 180),
	Color3.fromRGB(64, 200, 224),
	Color3.fromRGB(255, 123, 34),
	Color3.fromRGB(180, 160, 255),
	Color3.fromRGB(250, 250, 255),
}

-- Face color for a zone's signature boards: the SignColor, except for a
-- near-white SignColor (Startup HQ) whose white text would vanish: then the
-- AccentColor.
function MapKit.zoneSignFace(zone): Color3
	local c = zone.SignColor
	local luminance = 0.299 * c.R + 0.587 * c.G + 0.114 * c.B
	return if luminance > 0.85 then zone.AccentColor else c
end

----------------------------------------------------------------------
-- Parts
----------------------------------------------------------------------

export type PartProps = {
	name: string?,
	parent: Instance,
	size: Vector3?,
	cframe: CFrame,
	color: Color3,
	material: Enum.Material?,
	transparency: number?,
	reflectance: number?,
	canCollide: boolean?,
	castShadow: boolean?, -- default true
	diameter: number?,
	height: number?,
	axis: string?, -- cylinders: "Y" (default), "X", "Z"
}

-- Art guide: "Mostly SmoothPlastic and Neon. Avoid realistic textures; they
-- clash with the style." Wood grain, brushed metal, marble etc. read as
-- realistic next to the cartoon city, so every other material falls back to
-- SmoothPlastic here (terrain materials are unaffected: they are not parts).
-- Keyed by name: EnumItem identity is not guaranteed outside Roblox (the
-- offline Lune check/render tools create a fresh EnumItem per access).
local STYLE_MATERIALS = {
	SmoothPlastic = true,
	Neon = true,
	Glass = true,
	ForceField = true,
}

local function applyCommon(part: BasePart, props: PartProps)
	part.Name = props.name or "Part"
	part.Color = props.color
	local material = props.material or Enum.Material.SmoothPlastic
	part.Material = if STYLE_MATERIALS[material.Name] then material else Enum.Material.SmoothPlastic
	part.Transparency = props.transparency or 0
	part.Reflectance = props.reflectance or 0
	part.CanCollide = if props.canCollide ~= nil then props.canCollide else true
	if props.castShadow == false then
		part.CastShadow = false
	end
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
end

function MapKit.makeBlock(props: PartProps): Part
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Block
	part.Size = props.size :: Vector3
	part.CFrame = props.cframe
	applyCommon(part, props)
	part.Parent = props.parent
	return part
end

-- Balls are always uniform (Roblox keeps Ball parts spherical); pass `diameter`
-- or a uniform `size`.
function MapKit.makeBall(props: PartProps): Part
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Ball
	local d = props.diameter or (props.size :: Vector3).X
	part.Size = Vector3.new(d, d, d)
	part.CFrame = props.cframe
	applyCommon(part, props)
	part.Parent = props.parent
	return part
end

-- Cylinder whose length axis is vertical ("Y", default), or along "X"/"Z".
function MapKit.makeCylinder(props: PartProps): Part
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Cylinder
	local diameter = props.diameter or 1
	local height = props.height or 1
	part.Size = Vector3.new(height, diameter, diameter)
	local axis = props.axis or "Y"
	if axis == "Y" then
		part.CFrame = props.cframe * CFrame.Angles(0, 0, RAD_90)
	elseif axis == "Z" then
		part.CFrame = props.cframe * CFrame.Angles(0, RAD_90, 0)
	else -- "X": native cylinder axis
		part.CFrame = props.cframe
	end
	applyCommon(part, props)
	part.Parent = props.parent
	return part
end

-- WedgePart: full height at local +Z (back face vertical), sloping down to -Z.
function MapKit.makeWedge(props: PartProps): WedgePart
	local part = Instance.new("WedgePart")
	part.Size = props.size :: Vector3
	part.CFrame = props.cframe
	applyCommon(part, props)
	part.Parent = props.parent
	return part
end

function MapKit.makeModel(name: string, parent: Instance): Model
	local model = Instance.new("Model")
	model.Name = name
	model.Parent = parent
	return model
end

-- Invisible, non-colliding, non-queryable anchor (FeedbackPart, AutoAnchor,
-- particle emitter volumes).
function MapKit.makeMarker(parent: Instance, name: string, cf: CFrame, size: Vector3?): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size or Vector3.new(1, 1, 1)
	part.CFrame = cf
	part.Transparency = 1
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Anchored = true
	part.Parent = parent
	return part
end

----------------------------------------------------------------------
-- Text + light
----------------------------------------------------------------------

function MapKit.makeTextLabel(
	parent: Instance,
	text: string,
	font: Enum.Font,
	textColor: Color3,
	position: UDim2,
	size: UDim2
): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Position = position
	label.Size = size
	label.Font = font
	label.Text = text
	label.TextColor3 = textColor
	label.TextScaled = true
	label.TextStrokeColor3 = MapKit.NAVY
	label.TextStrokeTransparency = 0
	-- Chunky navy outline (the art guide's sticker look) so light text reads
	-- on bright signature-colored boards from across the plaza. SurfaceGui
	-- labels scale it with the label's pixel height (labelPx = face height in
	-- studs x PixelsPerStud x the label's height scale, through any parent
	-- frames): clamp(round(0.055 * labelPx), 4, 9) px, so a big board's
	-- outline never goes sub-pixel at 150-200 studs. BillboardGui labels: 3 px.
	local surfaceGui = if parent:IsA("SurfaceGui") then parent else parent:FindFirstAncestorWhichIsA("SurfaceGui")
	local stroke = Instance.new("UIStroke")
	stroke.Color = MapKit.NAVY
	stroke.Thickness = 3
	if surfaceGui then
		local heightScale = size.Y.Scale
		local node: Instance? = parent
		while node and node ~= surfaceGui do
			if node:IsA("GuiObject") then
				heightScale *= (node :: GuiObject).Size.Y.Scale
			end
			node = node.Parent
		end
		local adornee = (surfaceGui :: SurfaceGui).Adornee or surfaceGui.Parent
		local faceHeight = 0
		if adornee and adornee:IsA("BasePart") then
			local _, h = MapKit.faceSize(adornee, (surfaceGui :: SurfaceGui).Face)
			faceHeight = h
		end
		local labelPx = faceHeight * (surfaceGui :: SurfaceGui).PixelsPerStud * heightScale
		stroke.Thickness = math.clamp(math.floor(0.055 * labelPx + 0.5), 4, 9)
	end
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Parent = label
	label.Parent = parent
	return label
end

-- Width / height (studs) of one face of a part as its SurfaceGui sees it
-- (Front/Back: X x Y, Left/Right: Z x Y, Top/Bottom: X x Z).
function MapKit.faceSize(part: BasePart, face: Enum.NormalId): (number, number)
	local s = part.Size
	if face == Enum.NormalId.Left or face == Enum.NormalId.Right then
		return s.Z, s.Y
	elseif face == Enum.NormalId.Top or face == Enum.NormalId.Bottom then
		return s.X, s.Z
	end
	return s.X, s.Y
end

-- Flat painted rectangle in a SurfaceGui (or a Frame): scale position /
-- size, borderless, optional transparency, rounded corners (UICorner scale)
-- and rotation (degrees).
export type GuiFrameProps = {
	name: string?,
	parent: Instance,
	position: UDim2,
	size: UDim2,
	color: Color3,
	anchor: Vector2?,
	transparency: number?,
	corner: number?, -- UICorner CornerRadius scale (0.5 = circle / pill)
	rotation: number?,
	zIndex: number?,
	clips: boolean?,
}

function MapKit.makeGuiFrame(props: GuiFrameProps): Frame
	local frame = Instance.new("Frame")
	frame.Name = props.name or "Frame"
	frame.AnchorPoint = props.anchor or Vector2.new(0, 0)
	frame.Position = props.position
	frame.Size = props.size
	frame.BackgroundColor3 = props.color
	frame.BackgroundTransparency = props.transparency or 0
	frame.BorderSizePixel = 0
	frame.Rotation = props.rotation or 0
	frame.ZIndex = props.zIndex or 1
	frame.ClipsDescendants = props.clips == true
	if props.corner then
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(props.corner, 0)
		corner.Parent = frame
	end
	frame.Parent = props.parent
	return frame
end

-- PAINTED window bands (zero parts) on one face of a building body whose
-- bottom sits on the ground: a lit SurfaceGui "Windows" (LightInfluence 1,
-- so the paint shades with its wall; 2 px/stud, no Face frame) with one
-- Frame per band (centered at height y studs above the body's bottom,
-- opts.width wide, opts.height (3.6) tall, opts.color), a 0.3-stud sill in
-- the band color 35% toward navy under each, and optional mullions
-- (opts.mullions = face-local x offsets from the center, opts.mullionWidth
-- 1.2, from opts.mullionBottom to the top band's top + 0.8, opts.body color)
-- painted over the bands. For faces seen only from >= 150 studs, where flat
-- paint reads exactly like the 0.6-stud part bands it replaces.
export type PaintBandOpts = {
	width: number,
	height: number?,
	color: Color3,
	mullions: { number }?,
	mullionWidth: number?,
	mullionBottom: number?,
	body: Color3?,
}

function MapKit.paintBands(part: BasePart, face: Enum.NormalId, rows: { number }, opts: PaintBandOpts): SurfaceGui
	local fw, fh = MapKit.faceSize(part, face)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Windows"
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 2
	gui.LightInfluence = 1
	gui.Brightness = 1
	local bandH = opts.height or 3.6
	local sill = opts.color:Lerp(MapKit.NAVY, 0.35)
	local topEdge = 0
	for _, y in rows do
		topEdge = math.max(topEdge, y + bandH / 2)
		MapKit.makeGuiFrame({
			name = "Band", parent = gui, anchor = Vector2.new(0.5, 0),
			position = UDim2.fromScale(0.5, (fh - y - bandH / 2) / fh),
			size = UDim2.fromScale(opts.width / fw, bandH / fh), color = opts.color, zIndex = 1,
		})
		MapKit.makeGuiFrame({
			name = "Sill", parent = gui, anchor = Vector2.new(0.5, 0),
			position = UDim2.fromScale(0.5, (fh - y + bandH / 2) / fh),
			size = UDim2.fromScale((opts.width + 0.6) / fw, 0.3 / fh), color = sill, zIndex = 1,
		})
	end
	if opts.mullions and #rows > 0 then
		local bottom = opts.mullionBottom or 9.5
		local top = topEdge + 0.8
		for _, x in opts.mullions do
			MapKit.makeGuiFrame({
				name = "Mullion", parent = gui, anchor = Vector2.new(0.5, 0),
				position = UDim2.fromScale(0.5 + x / fw, (fh - top) / fh),
				size = UDim2.fromScale((opts.mullionWidth or 1.2) / fw, (top - bottom) / fh),
				color = opts.body or MapKit.WHITE, zIndex = 2,
			})
		end
	end
	gui.Parent = part
	return gui
end

-- PAINTED ground deck (road markings, the spawn mat): an invisible, flat,
-- non-colliding, non-queryable part (Transparency 1, 0.05 thick) whose BACK
-- face points up and carries a SurfaceGui `guiName`. `cf` is a horizontal
-- frame at the deck's center (its Y = the deck's center height): the gui's
-- up runs along cf's -Z and its right along cf's +X. A side face is used on
-- purpose: Roblox orients side-face guis unambiguously (up = part +Y, Back
-- face right = part +X), so painted positions never depend on the Top-face
-- convention. Roblox renders SurfaceGuis on fully transparent parts.
-- Returns the part and the gui; place Frames with MapKit.deckPixel /
-- MapKit.deckRotation (pixels: divide by the gui's pixel size and use
-- UDim2 SCALE, since UDim offsets are whole pixels).
function MapKit.makeGroundDeck(
	parent: Instance,
	name: string,
	cf: CFrame,
	width: number,
	depth: number,
	pixelsPerStud: number,
	guiName: string,
	lightInfluence: number?,
	brightness: number?
): (Part, SurfaceGui)
	local part = Instance.new("Part")
	part.Name = name
	part.Shape = Enum.PartType.Block
	part.Size = Vector3.new(width, depth, 0.05)
	part.CFrame = cf * CFrame.Angles(-RAD_90, 0, 0)
	part.Transparency = 1
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Anchored = true
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	local gui = Instance.new("SurfaceGui")
	gui.Name = guiName
	gui.Face = Enum.NormalId.Back
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = pixelsPerStud
	gui.LightInfluence = lightInfluence or 1
	gui.Brightness = brightness or 1
	gui.Parent = part
	part.Parent = parent
	return part, gui
end

-- Gui pixel offset (x right, y down) of a world point on a ground deck made
-- from `cf` (width x depth studs at `pixelsPerStud`).
function MapKit.deckPixel(cf: CFrame, width: number, depth: number, pixelsPerStud: number, worldPos: Vector3): (number, number)
	local l = cf:PointToObjectSpace(worldPos)
	return (l.X + width / 2) * pixelsPerStud, (l.Z + depth / 2) * pixelsPerStud
end

-- Gui Rotation (degrees, clockwise on the deck) that lines a Frame's width
-- axis up with the world direction `dir` on a ground deck made from `cf`.
function MapKit.deckRotation(cf: CFrame, dir: Vector3): number
	local l = cf:VectorToObjectSpace(dir)
	return math.deg(math.atan2(l.Z, l.X))
end

-- SurfaceGui text on one face of a part. `pixelsPerStud` defaults to 30; big
-- far-away boards pass less to keep texture memory small.
-- `faceColor` (sign boards): a full-face Frame "Face" in that color under the
-- text. The gui is unlit (LightInfluence 0, Brightness 1.1), so the board
-- face shows its true color from every angle whatever the sun does: a sign
-- turned away from the sun never reads as a switched-off grey slab.
function MapKit.addSurfaceText(
	part: BasePart,
	text: string,
	font: Enum.Font,
	textColor: Color3,
	face: Enum.NormalId,
	pixelsPerStud: number?,
	faceColor: Color3?
): SurfaceGui
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = pixelsPerStud or 30
	gui.LightInfluence = 0
	if faceColor then
		gui.Brightness = 1.1
		local frame = Instance.new("Frame")
		frame.Name = "Face"
		frame.Size = UDim2.fromScale(1, 1)
		frame.BackgroundColor3 = faceColor
		frame.BackgroundTransparency = 0
		frame.BorderSizePixel = 0
		frame.ZIndex = 1
		frame.Parent = gui
	end
	gui.Parent = part
	local label = MapKit.makeTextLabel(gui, text, font, textColor, UDim2.fromScale(0.03, 0.05), UDim2.fromScale(0.94, 0.9))
	label.ZIndex = 2
	return gui
end

function MapKit.addPointLight(parent: BasePart, color: Color3, range: number, brightness: number): PointLight
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = range
	light.Brightness = brightness
	light.Shadows = false
	light.Parent = parent
	return light
end

----------------------------------------------------------------------
-- Layout + shared decor
----------------------------------------------------------------------

-- Position on a ring around the origin (XZ plane).
function MapKit.ringPos(radius: number, degrees: number, y: number?): Vector3
	local angle = math.rad(degrees)
	return Vector3.new(math.cos(angle) * radius, y or 0, math.sin(angle) * radius)
end

-- Plaza-style lamp post (collidable base + pole, neon bulb with a warm
-- PointLight); `cf` = base center on the ground. SmoothPlastic, cobalt by
-- default (STREET_POLE pole, STREET_BASE foot); the zone entrance lamps pass
-- their zone's colors.
function MapKit.buildLampPost(parent: Instance, cf: CFrame, poleColor: Color3?, baseColor: Color3?)
	MapKit.makeCylinder({
		name = "LampBase", parent = parent, diameter = 2, height = 0.5,
		cframe = cf * CFrame.new(0, 0.25, 0), color = baseColor or MapKit.STREET_BASE,
	})
	MapKit.makeCylinder({
		name = "LampPole", parent = parent, diameter = 0.7, height = 8,
		cframe = cf * CFrame.new(0, 4.25, 0), color = poleColor or MapKit.STREET_POLE,
	})
	local bulb = MapKit.makeBall({
		name = "LampBulb", parent = parent, diameter = 2.4,
		cframe = cf * CFrame.new(0, 8.9, 0), color = Color3.fromRGB(255, 232, 170),
		material = Enum.Material.Neon, canCollide = false,
	})
	MapKit.addPointLight(bulb, MapKit.LAMP_WARM, 18, 0.9)
end

-- Cartoon lollipop tree (3 sizes): trunk + one to three leaf puffs.
-- Leaves never collide; `noShadow` drops the shadow of the whole tree.
function MapKit.buildTree(parent: Instance, position: Vector3, scale: number, noShadow: boolean?)
	local cf = CFrame.new(position)
	local shadow = if noShadow then false else nil
	local leaf = MapKit.LEAF_GREEN
	MapKit.makeCylinder({
		name = "TreeTrunk", parent = parent, diameter = 1.6 * scale, height = 6 * scale,
		cframe = cf * CFrame.new(0, 3 * scale, 0), color = MapKit.TRUNK,
		castShadow = shadow,
	})
	if scale < 0.9 then
		MapKit.makeBall({
			name = "TreeLeaves", parent = parent, diameter = 5.6 * scale,
			cframe = cf * CFrame.new(0, 6.6 * scale, 0), color = leaf, canCollide = false, castShadow = shadow,
		})
	elseif scale < 1.5 then
		MapKit.makeBall({
			name = "TreeLeaves", parent = parent, diameter = 6 * scale,
			cframe = cf * CFrame.new(0, 6.5 * scale, 0), color = leaf, canCollide = false, castShadow = shadow,
		})
		MapKit.makeBall({
			name = "TreeLeaves", parent = parent, diameter = 4.6 * scale,
			cframe = cf * CFrame.new(1.2 * scale, 8 * scale, 0.8 * scale), color = Color3.fromRGB(88, 176, 74),
			canCollide = false, castShadow = shadow,
		})
		MapKit.makeBall({
			name = "TreeLeaves", parent = parent, diameter = 4 * scale,
			cframe = cf * CFrame.new(-1.4 * scale, 7.4 * scale, -0.6 * scale), color = Color3.fromRGB(96, 188, 80),
			canCollide = false, castShadow = shadow,
		})
	else
		MapKit.makeBall({
			name = "TreeLeaves", parent = parent, diameter = 7 * scale,
			cframe = cf * CFrame.new(0, 6.4 * scale, 0), color = leaf, canCollide = false, castShadow = shadow,
		})
		MapKit.makeBall({
			name = "TreeLeaves", parent = parent, diameter = 5.2 * scale,
			cframe = cf * CFrame.new(0, 9.4 * scale, 0), color = Color3.fromRGB(88, 176, 74),
			canCollide = false, castShadow = shadow,
		})
		MapKit.makeBall({
			name = "TreeLeaves", parent = parent, diameter = 3.6 * scale,
			cframe = cf * CFrame.new(0, 11.6 * scale, 0), color = Color3.fromRGB(96, 188, 80),
			canCollide = false, castShadow = shadow,
		})
	end
end

return MapKit
