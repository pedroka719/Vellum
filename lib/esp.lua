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
