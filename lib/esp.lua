-- Vellum — ESP (highlights + billboards, theme-aware, group-managed)
--
-- One source of truth for visual overlays. Game modules call attach() to
-- mark something on screen and detach() when they no longer care. Groups
-- let you mass-toggle ("hide all island markers") without tracking handles.
--
-- The colors that *should* follow the theme (textDim labels) bind via
-- Theme.bind so they swap on theme change. Per-entity tier colors (red
-- for hostiles, gold for fruits) stay literal — they communicate semantic
-- meaning, not brand.
--
-- Usage:
--   local ESP = loadstring(...)()
--   ESP.init({ theme = Theme })
--
--   local h = ESP.billboard({
--     adornee = somePart,
--     text    = "Pirate Village",
--     sub     = "Lv 30-59",
--     color   = Color3.fromRGB(180, 180, 180),
--     group   = "islands",
--   })
--
--   ESP.detach(h)
--   ESP.detachGroup("islands")
--
--   local hl = ESP.highlight({
--     adornee = someModel, color = Color3.fromRGB(255, 80, 80), group = "players",
--   })

local ESP = {}

local Theme  -- injected
local _groups = {}  -- { [groupName] = { [handle] = true } }
local _nextId = 0

function ESP.init(opts)
	assert(opts and opts.theme, "ESP.init: 'theme' is required")
	Theme = opts.theme
end

local function newHandle()
	_nextId = _nextId + 1
	return _nextId
end

local function trackInGroup(handle, group, payload)
	group = group or "default"
	_groups[group] = _groups[group] or {}
	_groups[group][handle] = payload
end

-- Billboard with a primary line + optional secondary line. Always renders
-- on top via AlwaysOnTop. Vertical anchor is above the adornee.
function ESP.billboard(opts)
	assert(Theme, "ESP.billboard: call ESP.init first")
	assert(opts.adornee, "ESP.billboard: adornee is required")

	local handle = newHandle()
	local bb = Instance.new("BillboardGui")
	bb.Adornee = opts.adornee
	bb.Size = UDim2.new(0, 180, 0, 44)
	bb.StudsOffset = Vector3.new(0, opts.yOffset or 4, 0)
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.MaxDistance = opts.maxDistance or 0  -- 0 = always visible
	bb.Name = "Vellum_ESP_BB_" .. handle

	-- subtle backdrop for legibility against bright skies / snow
	local back = Instance.new("Frame", bb)
	back.Size = UDim2.fromScale(1, 1)
	back.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	back.BackgroundTransparency = 0.65
	back.BorderSizePixel = 0
	Instance.new("UICorner", back).CornerRadius = UDim.new(0, 4)

	-- primary line: big-ish, colored
	local title = Instance.new("TextLabel", back)
	title.Size = UDim2.new(1, -8, 0, 22)
	title.Position = UDim2.fromOffset(4, 2)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 13
	title.TextStrokeTransparency = 0.4
	title.TextColor3 = opts.color or Color3.fromRGB(220, 220, 220)
	title.Text = tostring(opts.text or "")

	-- secondary line (level range, distance, etc) — theme-bound dim text
	local sub
	if opts.sub then
		sub = Instance.new("TextLabel", back)
		sub.Size = UDim2.new(1, -8, 0, 14)
		sub.Position = UDim2.fromOffset(4, 24)
		sub.BackgroundTransparency = 1
		sub.Font = Enum.Font.Gotham
		sub.TextSize = 11
		sub.TextStrokeTransparency = 0.6
		Theme.bind(sub, "TextColor3", "textDim")
		sub.Text = tostring(opts.sub)
	end

	bb.Parent = opts.adornee:IsA("Model") and (opts.adornee.PrimaryPart or opts.adornee) or opts.adornee

	local payload = {
		kind = "billboard",
		instance = bb,
		title = title,
		sub = sub,
	}
	trackInGroup(handle, opts.group, payload)
	return handle, payload
end

-- Update the text of a live billboard. Used by per-frame trackers
-- ("distance to this island = 542 studs").
function ESP.setBillboardText(handle, text, sub)
	for _, members in pairs(_groups) do
		local p = members[handle]
		if p and p.kind == "billboard" then
			if text ~= nil and p.title then p.title.Text = tostring(text) end
			if sub ~= nil and p.sub then p.sub.Text = tostring(sub) end
			return true
		end
	end
	return false
end

-- Highlight wraps a Model with the Roblox Highlight instance. Cheap to
-- render (it's a built-in selection effect). Color is literal-tier, not
-- theme-bound — red means hostile regardless of brand palette.
function ESP.highlight(opts)
	assert(Theme, "ESP.highlight: call ESP.init first")
	assert(opts.adornee, "ESP.highlight: adornee is required")

	local handle = newHandle()
	local hl = Instance.new("Highlight")
	hl.Adornee = opts.adornee
	hl.FillColor = opts.color or Color3.fromRGB(255, 80, 80)
	hl.FillTransparency = opts.fillTransparency or 0.7
	hl.OutlineColor = opts.outlineColor or hl.FillColor
	hl.OutlineTransparency = opts.outlineTransparency or 0.2
	hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	hl.Name = "Vellum_ESP_HL_" .. handle
	hl.Parent = opts.adornee

	local payload = { kind = "highlight", instance = hl }
	trackInGroup(handle, opts.group, payload)
	return handle, payload
end

-- ═══════════════════════════════ CARDS ═══════════════════════════════
-- Premium-styled ESP layout: dark rounded backdrop with an accent UIStroke
-- border, up to three text lines (title / subtitle / caption), and an
-- optional HP bar with gradient fill that lerps green → yellow → red as
-- the value drops. Used for players, bosses, fruits — anywhere a plain
-- billboard would feel anemic.
--
-- Usage:
--   local handle, p = ESP.card({
--     adornee = ehrp,
--     accent  = Color3.fromRGB(255, 90, 90),
--     group   = "players",
--     title   = "PythonicProgram   Lv 603",
--     subtitle = "Human • Buddha-Buddha",
--     caption = "142 studs",
--     bar = { current = 720, max = 890 },
--   })
--   p.setLines("Name", "Race · Fruit", "100 studs")
--   p.setBar(450, 890)
--   p.setAccent(Color3.fromRGB(120, 220, 120))  -- e.g. ally turned hostile

-- Lerp green → yellow → red based on HP percentage (0..1). Two-segment
-- lerp so the midpoint is a clean yellow rather than muddy chartreuse.
local function _hpColor(pct)
	if pct < 0 then pct = 0 end
	if pct > 1 then pct = 1 end
	local green  = Color3.fromRGB( 80, 220, 120)
	local yellow = Color3.fromRGB(240, 200,  80)
	local red    = Color3.fromRGB(240,  80,  80)
	if pct > 0.5 then
		return yellow:Lerp(green, (pct - 0.5) * 2)
	end
	return red:Lerp(yellow, pct * 2)
end

function ESP.card(opts)
	assert(Theme, "ESP.card: call ESP.init first")
	assert(opts.adornee, "ESP.card: adornee is required")

	local handle = newHandle()
	local hasBar = opts.bar ~= nil
	local lineCount = (opts.title and 1 or 0) + (opts.subtitle and 1 or 0) + (opts.caption and 1 or 0)
	-- Layout: 4px pad top/bottom, ~14px per line, 6px bar
	local height = 8 + (lineCount * 14) + (hasBar and 8 or 0)

	local bb = Instance.new("BillboardGui")
	bb.Adornee = opts.adornee
	bb.Size = opts.size or UDim2.new(0, 240, 0, height)
	bb.StudsOffset = Vector3.new(0, opts.yOffset or 4.5, 0)
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.MaxDistance = opts.maxDistance or 0
	bb.Name = "Vellum_ESP_Card_" .. handle

	local back = Instance.new("Frame", bb)
	back.Size = UDim2.fromScale(1, 1)
	back.BackgroundColor3 = Color3.fromRGB(12, 12, 16)
	back.BackgroundTransparency = 0.28
	back.BorderSizePixel = 0
	Instance.new("UICorner", back).CornerRadius = UDim.new(0, 5)

	local accent = opts.accent or Color3.fromRGB(220, 200, 140)
	local stroke = Instance.new("UIStroke", back)
	stroke.Color = accent
	stroke.Thickness = 1.2
	stroke.Transparency = 0.25
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border

	-- Inner padding so text doesn't hug the stroke
	local pad = Instance.new("UIPadding", back)
	pad.PaddingTop    = UDim.new(0, 4)
	pad.PaddingBottom = UDim.new(0, 4)
	pad.PaddingLeft   = UDim.new(0, 8)
	pad.PaddingRight  = UDim.new(0, 8)

	local list = Instance.new("UIListLayout", back)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 0)
	list.HorizontalAlignment = Enum.HorizontalAlignment.Left

	local function makeLine(text, weight)
		local lbl = Instance.new("TextLabel", back)
		lbl.Size = UDim2.new(1, 0, 0, 14)
		lbl.BackgroundTransparency = 1
		lbl.Font = weight == "title" and Enum.Font.GothamBold or Enum.Font.Gotham
		lbl.TextSize = weight == "title" and 13 or 11
		lbl.TextStrokeTransparency = 0.5
		lbl.TextXAlignment = Enum.TextXAlignment.Left
		lbl.TextYAlignment = Enum.TextYAlignment.Center
		lbl.Text = tostring(text or "")
		if weight == "title" then
			lbl.TextColor3 = accent
		else
			Theme.bind(lbl, "TextColor3", weight == "caption" and "textDim" or "text")
		end
		return lbl
	end

	local titleLbl    = opts.title    and makeLine(opts.title, "title")
	local subtitleLbl = opts.subtitle and makeLine(opts.subtitle, "sub")
	local captionLbl  = opts.caption  and makeLine(opts.caption, "caption")

	local barBack, barFill, barText
	if hasBar then
		barBack = Instance.new("Frame", back)
		barBack.Size = UDim2.new(1, 0, 0, 6)
		barBack.BackgroundColor3 = Color3.fromRGB(28, 28, 34)
		barBack.BackgroundTransparency = 0.2
		barBack.BorderSizePixel = 0
		Instance.new("UICorner", barBack).CornerRadius = UDim.new(0, 3)

		barFill = Instance.new("Frame", barBack)
		barFill.Size = UDim2.fromScale(1, 1)
		barFill.BackgroundColor3 = _hpColor(1)
		barFill.BorderSizePixel = 0
		Instance.new("UICorner", barFill).CornerRadius = UDim.new(0, 3)

		-- Inline HP numbers, overlaid on the bar
		barText = Instance.new("TextLabel", barBack)
		barText.Size = UDim2.fromScale(1, 1)
		barText.BackgroundTransparency = 1
		barText.Font = Enum.Font.GothamBold
		barText.TextSize = 10
		barText.TextColor3 = Color3.fromRGB(245, 245, 245)
		barText.TextStrokeTransparency = 0.2
		barText.Text = ""
	end

	bb.Parent = opts.adornee:IsA("Model") and (opts.adornee.PrimaryPart or opts.adornee) or opts.adornee

	local payload = {
		kind = "card",
		instance = bb,
		setLines = function(title, subtitle, caption)
			if title    ~= nil and titleLbl    then titleLbl.Text    = tostring(title)    end
			if subtitle ~= nil and subtitleLbl then subtitleLbl.Text = tostring(subtitle) end
			if caption  ~= nil and captionLbl  then captionLbl.Text  = tostring(caption)  end
		end,
		setBar = function(current, max)
			if not barFill then return end
			local m = math.max(max or 1, 1)
			local c = math.max(math.min(current or 0, m), 0)
			local pct = c / m
			barFill.Size = UDim2.fromScale(pct, 1)
			barFill.BackgroundColor3 = _hpColor(pct)
			if barText then
				-- Format big numbers compactly (8.2k / 12k vs 8200 / 12000)
				local function fmt(n)
					if n >= 10000 then return string.format("%.1fk", n / 1000):gsub("%.0k", "k") end
					return tostring(math.floor(n))
				end
				barText.Text = fmt(c) .. " / " .. fmt(m)
			end
		end,
		setAccent = function(color)
			if not color then return end
			accent = color
			stroke.Color = color
			if titleLbl then titleLbl.TextColor3 = color end
		end,
	}
	if hasBar then payload.setBar(opts.bar.current, opts.bar.max) end

	trackInGroup(handle, opts.group, payload)
	return handle, payload
end

function ESP.detach(handle)
	for _, members in pairs(_groups) do
		local p = members[handle]
		if p then
			if p.instance and p.instance.Parent then p.instance:Destroy() end
			members[handle] = nil
			return true
		end
	end
	return false
end

function ESP.detachGroup(group)
	local members = _groups[group]
	if not members then return 0 end
	local n = 0
	for handle, p in pairs(members) do
		if p.instance and p.instance.Parent then p.instance:Destroy() end
		members[handle] = nil
		n = n + 1
	end
	return n
end

function ESP.detachAll()
	for group in pairs(_groups) do ESP.detachGroup(group) end
end

return ESP
