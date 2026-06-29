-- Vellum — Blox Fruits Bundle (self-contained, with fixes)
-- Execute this directly in your executor. No HTTP fetches needed.

-- ═══════════════════════════════════════════════════════════════
-- Helper: load a Lua source string as a module (returns the table)
-- ═══════════════════════════════════════════════════════════════
local function embed(src)
	local fn, err = loadstring(src, "embed")
	if not fn then error("Bundle embed error: " .. tostring(err), 0) end
	return fn()
end

-- ═══════════════════════════════════════════════════════════════
-- theme.lua
-- ═══════════════════════════════════════════════════════════════
local Theme = embed([====[
local rgb = Color3.fromRGB
local PRESETS = {
	Vellum = {
		bg          = rgb(20, 24, 31),
		panel       = rgb(27, 31, 42),
		elev        = rgb(35, 40, 56),
		row         = rgb(28, 32, 44),
		text        = rgb(236, 229, 212),
		textDim     = rgb(184, 172, 138),
		accent      = rgb(201, 169, 105),
		accentText  = rgb(20, 24, 31),
		stroke      = rgb(59, 66, 86),
		success     = rgb(136, 181, 127),
		warn        = rgb(212, 168, 87),
		danger      = rgb(199, 117, 100),
	},
	Midnight = {
		bg          = rgb(11, 15, 28),
		panel       = rgb(19, 24, 41),
		elev        = rgb(27, 33, 58),
		row         = rgb(22, 28, 47),
		text        = rgb(221, 228, 240),
		textDim     = rgb(127, 141, 168),
		accent      = rgb(111, 168, 255),
		accentText  = rgb(11, 15, 28),
		stroke      = rgb(42, 52, 87),
		success     = rgb(92, 224, 160),
		warn        = rgb(255, 200, 87),
		danger      = rgb(255, 107, 107),
	},
	Ink = {
		bg          = rgb(5, 5, 7),
		panel       = rgb(14, 14, 18),
		elev        = rgb(24, 24, 31),
		row         = rgb(18, 18, 24),
		text        = rgb(242, 242, 244),
		textDim     = rgb(142, 142, 148),
		accent      = rgb(255, 255, 255),
		accentText  = rgb(5, 5, 7),
		stroke      = rgb(42, 42, 48),
		success     = rgb(0, 209, 122),
		warn        = rgb(255, 179, 0),
		danger      = rgb(255, 77, 109),
	},
	Parchment = {
		bg          = rgb(244, 236, 219),
		panel       = rgb(235, 224, 200),
		elev        = rgb(223, 210, 181),
		row         = rgb(230, 218, 192),
		text        = rgb(42, 36, 24),
		textDim     = rgb(107, 96, 74),
		accent      = rgb(139, 94, 60),
		accentText  = rgb(244, 236, 219),
		stroke      = rgb(200, 184, 148),
		success     = rgb(90, 122, 63),
		warn        = rgb(181, 117, 24),
		danger      = rgb(163, 59, 42),
	},
	Matte = {
		bg          = rgb(26, 26, 26),
		panel       = rgb(34, 34, 34),
		elev        = rgb(45, 45, 45),
		row         = rgb(38, 38, 38),
		text        = rgb(232, 232, 232),
		textDim     = rgb(136, 136, 136),
		accent      = rgb(185, 185, 185),
		accentText  = rgb(26, 26, 26),
		stroke      = rgb(58, 58, 58),
		success     = rgb(159, 191, 140),
		warn        = rgb(212, 168, 87),
		danger      = rgb(199, 117, 100),
	},
}
local THEME = {}
for k, v in pairs(PRESETS.Vellum) do THEME[k] = v end
local _registry = {}
local Theme = {}
function Theme.token(role) return THEME[role] end
function Theme.bind(inst, prop, role)
	inst[prop] = THEME[role]
	table.insert(_registry, {inst, prop, role})
	return inst
end
function Theme.bindCall(fn) table.insert(_registry, {fn, "_call", "_call"}) end
function Theme.apply(name)
	local preset = PRESETS[name]
	if not preset then return false end
	for k, v in pairs(preset) do THEME[k] = v end
	for _, entry in ipairs(_registry) do
		local a, prop = entry[1], entry[2]
		if prop == "_call" then pcall(a)
		else pcall(function() if a.Parent then a[prop] = THEME[entry[3]] end end) end
	end
	return true
end
function Theme.presets()
	local out = {}
	for name, preset in pairs(PRESETS) do
		out[name] = {accent = preset.accent, panel = preset.panel, text = preset.text}
	end
	return out
end
function Theme.presetNames() return {"Vellum","Midnight","Ink","Parchment","Matte"} end
return Theme
]====])

-- ═══════════════════════════════════════════════════════════════
-- helpers.lua
-- ═══════════════════════════════════════════════════════════════
local Helpers = embed([====[
local Helpers = {}
function Helpers.fmt(n)
	if not n then return "0" end
	if n >= 1e12 then return string.format("%.2fT", n / 1e12) end
	if n >= 1e9  then return string.format("%.2fB", n / 1e9)  end
	if n >= 1e6  then return string.format("%.2fM", n / 1e6)  end
	if n >= 1e3  then return string.format("%.2fK", n / 1e3)  end
	return tostring(math.floor(n))
end
function Helpers.parseCash(text)
	if not text or text == "" then return 0 end
	local num = tonumber(text:match("([%d%.]+)"))
	if not num then return 0 end
	local suffix = text:upper():match("[KMBT]")
	if suffix == "K" then num = num * 1e3
	elseif suffix == "M" then num = num * 1e6
	elseif suffix == "B" then num = num * 1e9
	elseif suffix == "T" then num = num * 1e12 end
	return num
end
function Helpers.fmtDur(secs)
	secs = math.max(0, math.floor(secs))
	local h = math.floor(secs / 3600)
	local m = math.floor((secs % 3600) / 60)
	local s = secs % 60
	if h > 0 then return string.format("%dh %dm %ds", h, m, s) end
	if m > 0 then return string.format("%dm %ds", m, s) end
	return string.format("%ds", s)
end
function Helpers.perHour(n, elapsedSecs)
	if elapsedSecs < 60 then return "-" end
	return Helpers.fmt(math.floor(n * 3600 / elapsedSecs))
end
function Helpers.makeJwait(cfg)
	return function(t)
		local base = t * (cfg.conservativeMode and 2.5 or 1.0)
		if cfg.jitter or cfg.conservativeMode then
			local spread = cfg.conservativeMode and 0.8 or 0.4
			task.wait(base * (1.0 - spread / 2 + math.random() * spread))
		else
			task.wait(base)
		end
	end
end
function Helpers.makeSafe(tag)
	tag = tag or "Vellum"
	return function(fn, ...)
		local ok, err = pcall(fn, ...)
		if not ok then warn("[" .. tag .. "]", err) end
		return ok
	end
end
return Helpers
]====])

-- ═══════════════════════════════════════════════════════════════
-- toast.lua
-- ═══════════════════════════════════════════════════════════════
local Toast = embed([====[
local TweenService = game:GetService("TweenService")
local CoreGui = game:GetService("CoreGui")
local Toast = {}
local Theme
local HOST, HOLDER
local _recent = {}
local _enabled = function() return true end
local DEDUPE_WINDOW = 12
local function stripeColor(kind)
	if kind == "warn"    then return Theme.token("danger")  end
	if kind == "success" then return Theme.token("success") end
	if kind == "info"    then return Color3.fromRGB(80, 140, 230)  end
	if kind == "rare"    then return Color3.fromRGB(220, 180, 70)  end
	if kind == "epic"    then return Color3.fromRGB(180, 90, 220)  end
	if kind == "hop"     then return Color3.fromRGB(90, 200, 220)  end
	if kind == "trade"   then return Color3.fromRGB(230, 120, 70)  end
	return Theme.token("accent")
end
local function ensureHost()
	if HOST and HOST.Parent then return HOST end
	local sg = Instance.new("ScreenGui")
	sg.Name = "Vellum_Toasts"
	sg.ResetOnSpawn = false; sg.IgnoreGuiInset = true; sg.DisplayOrder = 1000001
	sg.Parent = (gethui and gethui()) or CoreGui
	HOST = sg
	HOLDER = Instance.new("Frame", sg)
	HOLDER.Size = UDim2.new(0, 320, 1, -40); HOLDER.Position = UDim2.new(1, -340, 0, 20)
	HOLDER.BackgroundTransparency = 1
	local list = Instance.new("UIListLayout", HOLDER)
	list.SortOrder = Enum.SortOrder.LayoutOrder; list.VerticalAlignment = Enum.VerticalAlignment.Top
	list.Padding = UDim.new(0, 8)
	return sg
end
function Toast.init(opts)
	opts = opts or {}
	if not opts.theme then error("Toast.init: 'theme' is required", 2) end
	Theme = opts.theme
	if opts.enabled ~= nil then
		if type(opts.enabled) == "function" then _enabled = opts.enabled
		else local v = opts.enabled; _enabled = function() return v end end
	end
end
function Toast.show(opts)
	if not Theme then return end
	if not _enabled() then return end
	ensureHost()
	local key = opts.key or (tostring(opts.title or "") .. "|" .. tostring(opts.body or ""))
	local now = os.clock()
	if _recent[key] and now - _recent[key] < DEDUPE_WINDOW then return end
	_recent[key] = now
	local kind = opts.kind or "info"
	local color = stripeColor(kind)
	local frame = Instance.new("Frame")
	frame.Size = UDim2.new(1, 0, 0, 64)
	Theme.bind(frame, "BackgroundColor3", "row")
	frame.BorderSizePixel = 0; frame.BackgroundTransparency = 0.05
	frame.AnchorPoint = Vector2.new(0, 0); frame.Position = UDim2.new(1.4, 0, 0, 0)
	Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)
	local stripe = Instance.new("Frame", frame)
	stripe.Size = UDim2.new(0, 4, 1, -10); stripe.Position = UDim2.fromOffset(6, 5)
	stripe.BackgroundColor3 = color; stripe.BorderSizePixel = 0
	Instance.new("UICorner", stripe).CornerRadius = UDim.new(0, 2)
	local titleLbl = Instance.new("TextLabel", frame)
	titleLbl.BackgroundTransparency = 1; titleLbl.Position = UDim2.fromOffset(18, 6)
	titleLbl.Size = UDim2.new(1, -24, 0, 18)
	titleLbl.Font = Enum.Font.GothamBold; titleLbl.TextSize = 13
	titleLbl.TextColor3 = color; titleLbl.TextXAlignment = Enum.TextXAlignment.Left
	titleLbl.Text = tostring(opts.title or "")
	local bodyLbl = Instance.new("TextLabel", frame)
	bodyLbl.BackgroundTransparency = 1; bodyLbl.Position = UDim2.fromOffset(18, 24)
	bodyLbl.Size = UDim2.new(1, -24, 0, 38)
	bodyLbl.Font = Enum.Font.Gotham; bodyLbl.TextSize = 12
	Theme.bind(bodyLbl, "TextColor3", "text")
	bodyLbl.TextXAlignment = Enum.TextXAlignment.Left; bodyLbl.TextYAlignment = Enum.TextYAlignment.Top
	bodyLbl.TextWrapped = true; bodyLbl.Text = tostring(opts.body or "")
	frame.Parent = HOLDER
	TweenService:Create(frame, TweenInfo.new(0.35, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {Position = UDim2.new(0, 0, 0, 0)}):Play()
	task.delay(opts.duration or 5, function()
		if not frame.Parent then return end
		local fade = TweenService:Create(frame, TweenInfo.new(0.3), {Position = UDim2.new(1.4, 0, 0, 0), BackgroundTransparency = 1})
		fade:Play()
		fade.Completed:Wait()
		if frame.Parent then frame:Destroy() end
	end)
end
function Toast.dismissAll()
	if not HOLDER then return end
	for _, c in ipairs(HOLDER:GetChildren()) do
		if c:IsA("Frame") then c:Destroy() end
	end
end
return Toast
]====])

-- ═══════════════════════════════════════════════════════════════
-- ui.lua (compact — source too large for inline, we load via string)
-- ═══════════════════════════════════════════════════════════════
local UI = embed([====[
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local CoreGui = game:GetService("CoreGui")
local Players = game:GetService("Players")
local UI = {}
local Theme
function UI.init(opts)
	opts = opts or {}
	if not opts.theme then error("UI.init: 'theme' is required", 2) end
	Theme = opts.theme
end
local function canParentTo(host)
	if not host then return false end
	local probe = Instance.new("ScreenGui")
	local ok = pcall(function() probe.Parent = host end)
	if ok and probe.Parent == host then probe:Destroy(); return true end
	pcall(function() probe:Destroy() end); return false
end
local function defaultGuiHost()
	if gethui then local ok, h = pcall(gethui); if ok and h and canParentTo(h) then return h end end
	if canParentTo(CoreGui) then return CoreGui end
	return Players.LocalPlayer:WaitForChild("PlayerGui")
end
function UI.mount(opts)
	if not Theme then error("UI.mount: call UI.init({theme=...}) first", 2) end
	opts = opts or {}
	local host = opts.guiHost or defaultGuiHost()
	for _, c in ipairs(host:GetChildren()) do
		if c.Name == "Vellum_Suite" then pcall(function() c:Destroy() end) end
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "Vellum_Suite"; gui.ResetOnSpawn = false; gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling; gui.DisplayOrder = 1000000
	gui.Parent = host
	local root = Instance.new("Frame")
	root.Size = opts.size or UDim2.fromOffset(540, 380)
	root.Position = opts.position or UDim2.fromOffset(60, 120)
	Theme.bind(root, "BackgroundColor3", "bg"); root.BorderSizePixel = 0
	root.Parent = gui
	Instance.new("UICorner", root).CornerRadius = UDim.new(0, 10)
	local rootStroke = Instance.new("UIStroke", root)
	Theme.bind(rootStroke, "Color", "stroke"); rootStroke.Thickness = 1; rootStroke.Transparency = 0.4
	local header = Instance.new("Frame", root)
	header.Size = UDim2.new(1, 0, 0, 56); header.BackgroundTransparency = 1; header.Active = true
	do
		local dragging, dragStart, startPos
		header.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragging = true; dragStart = input.Position; startPos = root.Position
				input.Changed:Connect(function()
					if input.UserInputState == Enum.UserInputState.End then dragging = false end
				end)
			end
		end)
		UserInputService.InputChanged:Connect(function(input)
			if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
				local d = input.Position - dragStart
				root.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
			end
		end)
	end
	local hDivider = Instance.new("Frame", root)
	hDivider.Size = UDim2.new(1, -24, 0, 1); hDivider.Position = UDim2.fromOffset(12, 56)
	Theme.bind(hDivider, "BackgroundColor3", "stroke"); hDivider.BackgroundTransparency = 0.4; hDivider.BorderSizePixel = 0
	local wordmark = Instance.new("TextLabel", header)
	wordmark.Size = UDim2.new(0, 240, 0, 28); wordmark.Position = UDim2.fromOffset(18, 8)
	wordmark.BackgroundTransparency = 1; wordmark.Text = opts.title or "V E L L U M"
	wordmark.Font = Enum.Font.Antique; wordmark.TextSize = 22
	Theme.bind(wordmark, "TextColor3", "text"); wordmark.TextXAlignment = Enum.TextXAlignment.Left
	if opts.subtitle and opts.subtitle ~= "" then
		local subtitle = Instance.new("TextLabel", header)
		subtitle.Size = UDim2.new(0, 240, 0, 14); subtitle.Position = UDim2.fromOffset(18, 34)
		subtitle.BackgroundTransparency = 1; subtitle.Text = opts.subtitle
		subtitle.Font = Enum.Font.Gotham; subtitle.TextSize = 10
		Theme.bind(subtitle, "TextColor3", "textDim"); subtitle.TextXAlignment = Enum.TextXAlignment.Left
	end
	local closeBtn = Instance.new("TextButton", header)
	closeBtn.Size = UDim2.fromOffset(22, 22); closeBtn.Position = UDim2.new(1, -32, 0, 14)
	closeBtn.BackgroundTransparency = 1; closeBtn.Text = "x"; closeBtn.Font = Enum.Font.Gotham; closeBtn.TextSize = 18
	Theme.bind(closeBtn, "TextColor3", "textDim"); closeBtn.AutoButtonColor = false
	closeBtn.MouseEnter:Connect(function() closeBtn.TextColor3 = Theme.token("danger") end)
	closeBtn.MouseLeave:Connect(function() closeBtn.TextColor3 = Theme.token("textDim") end)
	closeBtn.MouseButton1Click:Connect(function() if opts.onClose then pcall(opts.onClose) end; gui:Destroy() end)
	local minBtn = Instance.new("TextButton", header)
	minBtn.Size = UDim2.fromOffset(22, 22); minBtn.Position = UDim2.new(1, -60, 0, 14)
	minBtn.BackgroundTransparency = 1; minBtn.Text = "-"; minBtn.Font = Enum.Font.Gotham; minBtn.TextSize = 16
	Theme.bind(minBtn, "TextColor3", "textDim"); minBtn.AutoButtonColor = false
	minBtn.MouseEnter:Connect(function() minBtn.TextColor3 = Theme.token("accent") end)
	minBtn.MouseLeave:Connect(function() minBtn.TextColor3 = Theme.token("textDim") end)
	local sidebar = Instance.new("Frame", root)
	sidebar.Size = UDim2.new(0, 108, 1, -76); sidebar.Position = UDim2.fromOffset(12, 64)
	sidebar.BackgroundTransparency = 1; sidebar.BorderSizePixel = 0
	local sideLayout = Instance.new("UIListLayout", sidebar)
	sideLayout.Padding = UDim.new(0, 2); sideLayout.SortOrder = Enum.SortOrder.LayoutOrder; sideLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	local content = Instance.new("Frame", root)
	content.Size = UDim2.new(1, -136, 1, -76); content.Position = UDim2.fromOffset(124, 64)
	Theme.bind(content, "BackgroundColor3", "panel"); content.BorderSizePixel = 0
	Instance.new("UICorner", content).CornerRadius = UDim.new(0, 6)
	local contentStroke = Instance.new("UIStroke", content)
	Theme.bind(contentStroke, "Color", "stroke"); contentStroke.Thickness = 1; contentStroke.Transparency = 0.5
	local pages = {}; local tabs = {}; local activeName
	local function repaintTab(name, active)
		local entry = tabs[name]; if not entry then return end
		local btn, lbl = entry.btn, entry.lbl
		if active then
			btn.BackgroundTransparency = 0; btn.BackgroundColor3 = Theme.token("elev")
			lbl.TextColor3 = Theme.token("text"); btn.AccentStrip.BackgroundColor3 = Theme.token("accent"); btn.AccentStrip.Visible = true
		else
			btn.BackgroundTransparency = 1; lbl.TextColor3 = Theme.token("textDim"); btn.AccentStrip.Visible = false
		end
	end
	local function setActiveTab(name)
		if not tabs[name] then return end
		if activeName then repaintTab(activeName, false); tabs[activeName].page.Visible = false end
		repaintTab(name, true); tabs[name].page.Visible = true; activeName = name
	end
	Theme.bindCall(function() for name in pairs(tabs) do repaintTab(name, name == activeName) end end)
	local Builder = {gui = gui, root = root, header = header, sidebar = sidebar, content = content, minBtn = minBtn, closeBtn = closeBtn}
	function Builder.newPage(name)
		local p = Instance.new("ScrollingFrame", content)
		p.Size = UDim2.new(1, -16, 1, -16); p.Position = UDim2.fromOffset(8, 8)
		p.BackgroundTransparency = 1; p.BorderSizePixel = 0; p.Visible = false
		p.ScrollBarThickness = 4; p.CanvasSize = UDim2.fromOffset(0, 0); p.AutomaticCanvasSize = Enum.AutomaticSize.Y
		local layout = Instance.new("UIListLayout", p); layout.Padding = UDim.new(0, 8); layout.SortOrder = Enum.SortOrder.LayoutOrder
		pages[name] = p; return p
	end
	function Builder.newTab(name, label, order)
		local b = Instance.new("TextButton", sidebar)
		b.Size = UDim2.new(1, 0, 0, 28); b.LayoutOrder = order or 0; b.BackgroundTransparency = 1; b.AutoButtonColor = false; b.Text = ""
		Instance.new("UICorner", b).CornerRadius = UDim.new(0, 4)
		local strip = Instance.new("Frame", b); strip.Name = "AccentStrip"
		strip.Size = UDim2.new(0, 2, 0.6, 0); strip.Position = UDim2.new(0, 4, 0.2, 0)
		strip.BackgroundColor3 = Theme.token("accent"); strip.BorderSizePixel = 0; strip.Visible = false
		local lbl = Instance.new("TextLabel", b); lbl.Name = "Label"
		lbl.Size = UDim2.new(1, -18, 1, 0); lbl.Position = UDim2.fromOffset(14, 0); lbl.BackgroundTransparency = 1
		lbl.Text = label; lbl.Font = Enum.Font.GothamMedium; lbl.TextSize = 11; lbl.TextColor3 = Theme.token("textDim"); lbl.TextXAlignment = Enum.TextXAlignment.Left
		b.MouseEnter:Connect(function() if activeName ~= name then lbl.TextColor3 = Theme.token("text") end end)
		b.MouseLeave:Connect(function() if activeName ~= name then lbl.TextColor3 = Theme.token("textDim") end end)
		b.MouseButton1Click:Connect(function() setActiveTab(name) end)
		tabs[name] = {btn = b, lbl = lbl, page = pages[name] or error("newTab '"..name.."' before newPage", 2)}
		return b
	end
	Builder.setActiveTab = setActiveTab
	Builder.getActiveTab = function() return activeName end
	function Builder.row(parent, height)
		local f = Instance.new("Frame", parent)
		f.Size = UDim2.new(1, -8, 0, height or 26)
		Theme.bind(f, "BackgroundColor3", "row"); f.BorderSizePixel = 0
		Instance.new("UICorner", f).CornerRadius = UDim.new(0, 4); return f
	end
	function Builder.sectionLabel(parent, text)
		local wrap = Instance.new("Frame", parent)
		wrap.Size = UDim2.new(1, -8, 0, 22); wrap.BackgroundTransparency = 1
		local strip = Instance.new("Frame", wrap)
		strip.Size = UDim2.new(0, 2, 0, 12); strip.Position = UDim2.new(0, 0, 0.5, -6)
		Theme.bind(strip, "BackgroundColor3", "accent"); strip.BorderSizePixel = 0
		local l = Instance.new("TextLabel", wrap)
		l.Size = UDim2.new(1, -14, 1, 0); l.Position = UDim2.fromOffset(10, 0); l.BackgroundTransparency = 1
		l.Text = string.upper(text); l.Font = Enum.Font.GothamBold; l.TextSize = 10
		Theme.bind(l, "TextColor3", "textDim"); l.TextXAlignment = Enum.TextXAlignment.Left; return wrap
	end
	function Builder.toggleRow(parent, labelText, getF, setF)
		local r = Builder.row(parent, 30)
		local l = Instance.new("TextLabel", r)
		l.Size = UDim2.new(1, -56, 1, 0); l.Position = UDim2.fromOffset(12, 0); l.BackgroundTransparency = 1; l.Text = labelText
		l.Font = Enum.Font.Gotham; l.TextSize = 12
		Theme.bind(l, "TextColor3", "text"); l.TextXAlignment = Enum.TextXAlignment.Left
		local pill = Instance.new("TextButton", r)
		pill.Size = UDim2.fromOffset(34, 18); pill.Position = UDim2.new(1, -44, 0.5, -9); pill.AutoButtonColor = false; pill.Text = ""
		Instance.new("UICorner", pill).CornerRadius = UDim.new(1, 0)
		local dot = Instance.new("Frame", pill); dot.Size = UDim2.fromOffset(14, 14); dot.AnchorPoint = Vector2.new(0, 0.5); dot.BorderSizePixel = 0
		Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)
		local function paint(animate)
			local on = getF()
			local pillColor = on and Theme.token("accent") or Theme.token("elev")
			local dotColor = on and Theme.token("accentText") or Theme.token("textDim")
			local dotPos = on and UDim2.new(1, -16, 0.5, 0) or UDim2.new(0, 2, 0.5, 0)
			if animate then
				TweenService:Create(pill, TweenInfo.new(0.18), {BackgroundColor3 = pillColor}):Play()
				TweenService:Create(dot, TweenInfo.new(0.18), {BackgroundColor3 = dotColor, Position = dotPos}):Play()
			else pill.BackgroundColor3 = pillColor; dot.BackgroundColor3 = dotColor; dot.Position = dotPos end
		end
		pill.MouseButton1Click:Connect(function() setF(not getF()); paint(true) end)
		paint(false); Theme.bindCall(function() paint(false) end); return r
	end
	function Builder.multiToggleRow(parent, labelText, tbl, key)
		local r = Builder.row(parent, 24)
		local l = Instance.new("TextLabel", r)
		l.Size = UDim2.new(1, -52, 1, 0); l.Position = UDim2.fromOffset(12, 0); l.BackgroundTransparency = 1; l.Text = labelText
		l.Font = Enum.Font.Gotham; l.TextSize = 11
		Theme.bind(l, "TextColor3", "text"); l.TextXAlignment = Enum.TextXAlignment.Left
		local pill = Instance.new("TextButton", r)
		pill.Size = UDim2.fromOffset(30, 16); pill.Position = UDim2.new(1, -40, 0.5, -8); pill.AutoButtonColor = false; pill.Text = ""
		Instance.new("UICorner", pill).CornerRadius = UDim.new(1, 0)
		local dot = Instance.new("Frame", pill); dot.Size = UDim2.fromOffset(12, 12); dot.AnchorPoint = Vector2.new(0, 0.5); dot.BorderSizePixel = 0
		Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)
		local function paint(animate)
			local on = tbl[key]
			local pillColor = on and Theme.token("accent") or Theme.token("elev")
			local dotColor = on and Theme.token("accentText") or Theme.token("textDim")
			local dotPos = on and UDim2.new(1, -14, 0.5, 0) or UDim2.new(0, 2, 0.5, 0)
			if animate then
				TweenService:Create(pill, TweenInfo.new(0.15), {BackgroundColor3 = pillColor}):Play()
				TweenService:Create(dot, TweenInfo.new(0.15), {BackgroundColor3 = dotColor, Position = dotPos}):Play()
			else pill.BackgroundColor3 = pillColor; dot.BackgroundColor3 = dotColor; dot.Position = dotPos end
		end
		pill.MouseButton1Click:Connect(function() tbl[key] = not tbl[key]; paint(true) end)
		paint(false); Theme.bindCall(function() paint(false) end); return r
	end
	function Builder.intervalRow(parent, labelText, getF, setF, options)
		local r = Builder.row(parent, 30)
		local l = Instance.new("TextLabel", r)
		l.Size = UDim2.new(0.6, 0, 1, 0); l.Position = UDim2.fromOffset(12, 0); l.BackgroundTransparency = 1; l.Text = labelText
		l.Font = Enum.Font.Gotham; l.TextSize = 12
		Theme.bind(l, "TextColor3", "text"); l.TextXAlignment = Enum.TextXAlignment.Left
		local b = Instance.new("TextButton", r)
		b.Size = UDim2.fromOffset(54, 20); b.Position = UDim2.new(1, -64, 0.5, -10)
		Theme.bind(b, "BackgroundColor3", "elev"); b.AutoButtonColor = false; b.Font = Enum.Font.RobotoMono; b.TextSize = 11
		Theme.bind(b, "TextColor3", "text")
		Instance.new("UICorner", b).CornerRadius = UDim.new(0, 4)
		local function paint() b.Text = string.format("%.1fs", getF()) end
		b.MouseButton1Click:Connect(function()
			local cur = getF(); local idx = 1
			for i, v in ipairs(options) do if v == cur then idx = i break end end
			idx = (idx % #options) + 1; setF(options[idx]); paint()
		end)
		paint(); return r
	end
	function Builder.dropdownRow(parent, labelText, options, getF, setF)
		local r = Builder.row(parent, 30)
		local l = Instance.new("TextLabel", r)
		l.Size = UDim2.new(0.55, 0, 1, 0); l.Position = UDim2.fromOffset(12, 0); l.BackgroundTransparency = 1; l.Text = labelText
		l.Font = Enum.Font.Gotham; l.TextSize = 12
		Theme.bind(l, "TextColor3", "text"); l.TextXAlignment = Enum.TextXAlignment.Left
		local pill = Instance.new("TextButton", r)
		pill.Size = UDim2.new(0.45, -20, 0, 22); pill.Position = UDim2.new(0.55, 0, 0.5, -11)
		Theme.bind(pill, "BackgroundColor3", "elev"); pill.AutoButtonColor = false; pill.Text = ""
		Instance.new("UICorner", pill).CornerRadius = UDim.new(0, 5)
		local pillStroke = Instance.new("UIStroke", pill)
		Theme.bind(pillStroke, "Color", "stroke"); pillStroke.Thickness = 1; pillStroke.Transparency = 0.5
		local valueLbl = Instance.new("TextLabel", pill)
		valueLbl.Size = UDim2.new(1, -22, 1, 0); valueLbl.Position = UDim2.fromOffset(10, 0); valueLbl.BackgroundTransparency = 1
		valueLbl.Font = Enum.Font.GothamMedium; valueLbl.TextSize = 11
		Theme.bind(valueLbl, "TextColor3", "text"); valueLbl.TextXAlignment = Enum.TextXAlignment.Left
		valueLbl.Text = tostring(getF() or options[1] or "")
		local arrow = Instance.new("TextLabel", pill)
		arrow.Size = UDim2.fromOffset(14, 22); arrow.Position = UDim2.new(1, -16, 0, 0); arrow.BackgroundTransparency = 1
		arrow.Font = Enum.Font.Gotham; arrow.TextSize = 11
		Theme.bind(arrow, "TextColor3", "textDim"); arrow.Text = "v"
		pill.MouseEnter:Connect(function() pillStroke.Transparency = 0.15; arrow.TextColor3 = Theme.token("accent") end)
		pill.MouseLeave:Connect(function() pillStroke.Transparency = 0.5; arrow.TextColor3 = Theme.token("textDim") end)
		local floatPanel, closeConn
		local function close()
			if not floatPanel then return end
			local p = floatPanel; floatPanel = nil
			if closeConn then closeConn:Disconnect(); closeConn = nil end
			arrow.Text = "v"
			local fullSize = p.Size
			TweenService:Create(p, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {Size = UDim2.new(fullSize.X.Scale, fullSize.X.Offset, 0, 0)}):Play()
		end
		local function open()
			if floatPanel then return end; arrow.Text = "^"
			local pillAbs = pill.AbsolutePosition; local pillSize = pill.AbsoluteSize;
			local guiAbs = gui.AbsolutePosition or Vector2.new(0, 0)
			local panelW = math.max(pillSize.X, 120); local panelH = #options * 28 + 12
			local p = Instance.new("Frame"); p.Name = "Vellum_Dropdown"
			p.AnchorPoint = Vector2.new(0, 0)
			p.Position = UDim2.fromOffset(pillAbs.X - guiAbs.X, pillAbs.Y - guiAbs.Y + pillSize.Y + 4)
			p.Size = UDim2.fromOffset(panelW, 0)
			Theme.bind(p, "BackgroundColor3", "panel"); p.BorderSizePixel = 0; p.ZIndex = 100; p.ClipsDescendants = true
			Instance.new("UICorner", p).CornerRadius = UDim.new(0, 6)
			local accentStroke = Instance.new("UIStroke", p)
			Theme.bind(accentStroke, "Color", "accent"); accentStroke.Thickness = 1.4; accentStroke.Transparency = 0.25
			local pad = Instance.new("UIPadding", p); pad.PaddingTop = UDim.new(0, 5); pad.PaddingBottom = UDim.new(0, 5); pad.PaddingLeft = UDim.new(0, 5); pad.PaddingRight = UDim.new(0, 5)
			local list = Instance.new("UIListLayout", p); list.Padding = UDim.new(0, 2); list.SortOrder = Enum.SortOrder.LayoutOrder
			local currentSelection = getF()
			for i, opt in ipairs(options) do
				local isSel = (opt == currentSelection)
				local optBtn = Instance.new("TextButton", p)
				optBtn.LayoutOrder = i; optBtn.Size = UDim2.new(1, 0, 0, 26); optBtn.AutoButtonColor = false; optBtn.Text = ""; optBtn.ZIndex = 101
				Instance.new("UICorner", optBtn).CornerRadius = UDim.new(0, 4)
				if isSel then optBtn.BackgroundColor3 = Theme.token("accent"); optBtn.BackgroundTransparency = 0.15
				else Theme.bind(optBtn, "BackgroundColor3", "row"); optBtn.BackgroundTransparency = 0.4 end
				local optLbl = Instance.new("TextLabel", optBtn)
				optLbl.Size = UDim2.new(1, -28, 1, 0); optLbl.Position = UDim2.fromOffset(12, 0); optLbl.BackgroundTransparency = 1
				optLbl.Font = isSel and Enum.Font.GothamBold or Enum.Font.Gotham; optLbl.TextSize = 11; optLbl.TextXAlignment = Enum.TextXAlignment.Left
				optLbl.Text = opt; optLbl.ZIndex = 102
				if isSel then optLbl.TextColor3 = Theme.token("accentText") else Theme.bind(optLbl, "TextColor3", "text") end
				if isSel then
					local check = Instance.new("TextLabel", optBtn)
					check.Size = UDim2.fromOffset(20, 26); check.Position = UDim2.new(1, -22, 0, 0); check.BackgroundTransparency = 1
					check.Font = Enum.Font.GothamBold; check.TextSize = 12; check.TextColor3 = Theme.token("accentText"); check.Text = "V"; check.ZIndex = 102
				end
				if not isSel then
					optBtn.MouseEnter:Connect(function() optBtn.BackgroundColor3 = Theme.token("elev"); optBtn.BackgroundTransparency = 0 end)
					optBtn.MouseLeave:Connect(function() optBtn.BackgroundColor3 = Theme.token("row"); optBtn.BackgroundTransparency = 0.4 end)
				end
				optBtn.MouseButton1Click:Connect(function() setF(opt); valueLbl.Text = opt; close() end)
			end
			p.Parent = gui
			TweenService:Create(p, TweenInfo.new(0.18, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {Size = UDim2.fromOffset(panelW, panelH)}):Play()
			floatPanel = p
			closeConn = UserInputService.InputBegan:Connect(function(input, processed)
				if processed then return end
				if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then return end
				local pos = UserInputService:GetMouseLocation()
				if not floatPanel then return end
				local abs, sz = floatPanel.AbsolutePosition, floatPanel.AbsoluteSize
				if sz.X <= 0 or sz.Y <= 0 then return end
				local insidePanel = pos.X >= abs.X and pos.X <= abs.X + sz.X and pos.Y >= abs.Y and pos.Y <= abs.Y + sz.Y
				local pillAb, pillSz = pill.AbsolutePosition, pill.AbsoluteSize
				local insidePill = pos.X >= pillAb.X and pos.X <= pillAb.X + pillSz.X and pos.Y >= pillAb.Y and pos.Y <= pillAb.Y + pillSz.Y
				if not insidePanel and not insidePill then close() end
			end)
		end
		pill.MouseButton1Click:Connect(function() if floatPanel then close() else open() end end)
		return r
	end
	function Builder.actionBtn(parent, label, fn)
		local b = Instance.new("TextButton", parent)
		b.Size = UDim2.new(1, -8, 0, 28)
		Theme.bind(b, "BackgroundColor3", "elev"); b.AutoButtonColor = false; b.Font = Enum.Font.GothamMedium; b.TextSize = 12
		Theme.bind(b, "TextColor3", "text"); b.Text = label
		Instance.new("UICorner", b).CornerRadius = UDim.new(0, 4)
		local strokeB = Instance.new("UIStroke", b)
		Theme.bind(strokeB, "Color", "stroke"); strokeB.Thickness = 1; strokeB.Transparency = 0.6
		b.MouseEnter:Connect(function() b.TextColor3 = Theme.token("accent") end)
		b.MouseLeave:Connect(function() b.TextColor3 = Theme.token("text") end)
		b.MouseButton1Click:Connect(fn); return b
	end
	return Builder
end
UI.defaultGuiHost = defaultGuiHost
return UI
]====])

-- ═══════════════════════════════════════════════════════════════
-- esp.lua
-- ═══════════════════════════════════════════════════════════════
local ESP = embed([====[
local ESP = {}
local Theme
local _groups = {}
local _nextId = 0
function ESP.init(opts) assert(opts and opts.theme, "ESP.init: 'theme' is required"); Theme = opts.theme end
local function newHandle() _nextId = _nextId + 1; return _nextId end
local function trackInGroup(handle, group, payload)
	group = group or "default"
	_groups[group] = _groups[group] or {}; _groups[group][handle] = payload
end
function ESP.billboard(opts)
	assert(Theme, "ESP.billboard: call ESP.init first"); assert(opts.adornee, "ESP.billboard: adornee is required")
	local handle = newHandle()
	local bb = Instance.new("BillboardGui")
	bb.Adornee = opts.adornee; bb.Size = UDim2.new(0, 180, 0, 44)
	bb.StudsOffset = Vector3.new(0, opts.yOffset or 4, 0); bb.AlwaysOnTop = true; bb.LightInfluence = 0
	bb.MaxDistance = opts.maxDistance or 0; bb.Name = "Vellum_ESP_BB_" .. handle
	local back = Instance.new("Frame", bb)
	back.Size = UDim2.fromScale(1, 1); back.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	back.BackgroundTransparency = 0.65; back.BorderSizePixel = 0
	Instance.new("UICorner", back).CornerRadius = UDim.new(0, 4)
	local title = Instance.new("TextLabel", back)
	title.Size = UDim2.new(1, -8, 0, 22); title.Position = UDim2.fromOffset(4, 2); title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold; title.TextSize = 13; title.TextStrokeTransparency = 0.4
	title.TextColor3 = opts.color or Color3.fromRGB(220, 220, 220); title.Text = tostring(opts.text or "")
	local sub
	if opts.sub then
		sub = Instance.new("TextLabel", back)
		sub.Size = UDim2.new(1, -8, 0, 14); sub.Position = UDim2.fromOffset(4, 24); sub.BackgroundTransparency = 1
		sub.Font = Enum.Font.Gotham; sub.TextSize = 11; sub.TextStrokeTransparency = 0.6
		Theme.bind(sub, "TextColor3", "textDim"); sub.Text = tostring(opts.sub)
	end
	bb.Parent = opts.adornee:IsA("Model") and (opts.adornee.PrimaryPart or opts.adornee) or opts.adornee
	local payload = {kind = "billboard", instance = bb, title = title, sub = sub}
	trackInGroup(handle, opts.group, payload); return handle, payload
end
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
function ESP.highlight(opts)
	assert(Theme, "ESP.highlight: call ESP.init first"); assert(opts.adornee, "ESP.highlight: adornee is required")
	local handle = newHandle()
	local hl = Instance.new("Highlight")
	hl.Adornee = opts.adornee; hl.FillColor = opts.color or Color3.fromRGB(255, 80, 80)
	hl.FillTransparency = opts.fillTransparency or 0.7
	hl.OutlineColor = opts.outlineColor or hl.FillColor; hl.OutlineTransparency = opts.outlineTransparency or 0.2
	hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop; hl.Name = "Vellum_ESP_HL_" .. handle
	hl.Parent = opts.adornee
	local payload = {kind = "highlight", instance = hl}
	trackInGroup(handle, opts.group, payload); return handle, payload
end
function ESP.detach(handle)
	for _, members in pairs(_groups) do
		local p = members[handle]
		if p then if p.instance and p.instance.Parent then p.instance:Destroy() end; members[handle] = nil; return true end
	end
	return false
end
function ESP.detachGroup(group)
	local members = _groups[group]; if not members then return 0 end
	local n = 0
	for handle, p in pairs(members) do if p.instance and p.instance.Parent then p.instance:Destroy() end; members[handle] = nil; n = n + 1 end
	return n
end
function ESP.detachAll() for group in pairs(_groups) do ESP.detachGroup(group) end end
return ESP
]====])

-- ═══════════════════════════════════════════════════════════════
-- Initialize lib
-- ═══════════════════════════════════════════════════════════════
Toast.init({ theme = Theme })
UI.init({ theme = Theme })
ESP.init({ theme = Theme })

local lib = {
	theme   = Theme,
	helpers = Helpers,
	toast   = Toast,
	ui      = UI,
	esp     = ESP,
}

-- ═══════════════════════════════════════════════════════════════
-- Game module: blox_fruits.lua (FIXED — BodyGyro check reordered)
-- ═══════════════════════════════════════════════════════════════
local Game = embed([====[
local Players          = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService       = game:GetService("RunService")
local TweenService     = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local VirtualUser      = game:GetService("VirtualUser")

local Module = {
	name = "Blox Fruits",
	placeIds = { 2753915549 },
}

function Module.start(lib)
	local Theme   = lib.theme
	local UI      = lib.ui
	local Toast   = lib.toast
	local Helpers = lib.helpers
	local ESP     = lib.esp

	local LocalPlayer = Players.LocalPlayer

	local gui

	local Net = ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Net")
	local Remotes = ReplicatedStorage:WaitForChild("Remotes")

	local R = {
		RegisterAttack = Net:WaitForChild("RE/RegisterAttack"),
		RegisterHit    = Net:WaitForChild("RE/RegisterHit"),
		CommF_         = Remotes:WaitForChild("CommF_"),
		CommE          = Remotes:WaitForChild("CommE"),
	}

	local cfg = {
		afkMode = false,
		autoFarm = false,
		farmHeight = 10,
		attackCadence = 0.25,
		damageMultiplier = 1.0,
		farmLevelMin = 0,
		farmLevelMax = 9999,
		farmTargetName = "",
		aggressiveRange = false,
		mobBring = false,
		mobBringRadius = 50,
		autoSea1 = false,
		espIslands = true,
		autoStats = false,
		statPriority = "Melee",
		statBatchSize = 1,
		antiAfk = true,
		spyEnabled = true,
		spyBufferSize = 200,
		notifyInGame = true,
	}

	local stats = {
		sessionXP = 0,
		sessionBeli = 0,
		sessionKills = 0,
		sessionStart = os.clock(),
	}

	local jwait = Helpers.makeJwait(cfg)
	local safe = Helpers.makeSafe("Vellum BF")

	getgenv().VellumBF = getgenv().VellumBF or {}
	local SPY = getgenv().VellumBF
	if type(SPY.log) ~= "table" or SPY.cap ~= cfg.spyBufferSize then
		SPY.log   = table.create(cfg.spyBufferSize)
		SPY.cap   = cfg.spyBufferSize
		SPY.head  = 1
		SPY.count = 0
	end
	SPY.frozen = false

	local _tpInProgress = false

	local function generateHash()
		local prefix = tostring(LocalPlayer.UserId):sub(2, 4)
		local suffix = tostring(coroutine.running()):sub(11, 15)
		return prefix .. suffix
	end

	local function registerHash(hash)
		if not hash then return end
		local ok, err = pcall(function() R.RegisterHit:FireServer(hash) end)
		if ok then warn("[Vellum BF] hash registered:", hash)
		else warn("[Vellum BF] hash registration failed:", err) end
	end

	local function ensureHash()
		if SPY.hash then return SPY.hash end
		SPY.hash = generateHash()
		registerHash(SPY.hash)
		return SPY.hash
	end

	local function getHash() return SPY.hash end

	local function clearHash()
		SPY.hash = nil
		warn("[Vellum BF] session hash cleared -- will regenerate on next tick")
	end

	local currentTarget
	local targetOriginalY

	local function attackOnce(enemy)
		local part = enemy:FindFirstChild("HumanoidRootPart") or enemy:FindFirstChild("Head") or enemy:FindFirstChildOfClass("MeshPart")
		if not part then return false end
		local hash = getHash()
		if not part or not hash then return false end
		safe(function() R.RegisterAttack:FireServer(cfg.damageMultiplier) end)
		safe(function() R.RegisterHit:FireServer(part, {}, nil, hash) end)
		return true
	end

	local function pickEnemy()
		local ch = LocalPlayer.Character
		local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
		if not hrp then return nil end
		local bestFiltered, bestFilteredScore
		local bestAny, bestAnyScore
		for _, e in ipairs(workspace.Enemies:GetChildren()) do
			local ehrp = e:FindFirstChild("HumanoidRootPart")
			local hum  = e:FindFirstChild("Humanoid")
			if ehrp and hum and hum.Health > 0 then
				local d = (ehrp.Position - hrp.Position).Magnitude
				local score = 1000 - d
				if not bestAnyScore or score > bestAnyScore then
					bestAny, bestAnyScore = e, score
				end
				local lvl = e:GetAttribute("Level")
				local lvlOK = lvl and lvl >= cfg.farmLevelMin and lvl <= cfg.farmLevelMax
				local nameOK = cfg.farmTargetName == "" or e.Name == cfg.farmTargetName
				if lvlOK and nameOK then
					if not bestFilteredScore or score > bestFilteredScore then
						bestFiltered, bestFilteredScore = e, score
					end
				end
			end
		end
		return bestFiltered or bestAny
	end

	local activeTween

	local function _tweenHRPTo(hrp, destPos)
		if activeTween then pcall(function() activeTween:Cancel() end) end
		local yOffset = hrp.Position.Y - destPos.Y
		local startPos = hrp.Position
		local dist = (destPos - startPos).Magnitude
		if dist < 5 then return end
		local duration = math.clamp(dist / 300, 0.2, 1.5)
		local tweenInfo = TweenInfo.new(duration, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
		local tween = TweenService:Create(hrp, tweenInfo, {CFrame = CFrame.new(destPos)})
		local completed = false
		tween.Completed:Connect(function() completed = true end)
		activeTween = tween
		tween:Play()
		if not tween then return end
		local timeout = duration + 1.0
		while not completed and timeout > 0 do
			timeout = timeout - task.wait(0.03)
			if cfg.conservativeMode then
				local cur = hrp.Position
				local remaining = (destPos - cur).Magnitude
				if remaining < 3 then break end
			end
		end
		if tween then pcall(function() tween:Cancel() end) end
		activeTween = nil
	end

	local _stopFlightFn

	_stopFlightFn = function()
		if activeTween then pcall(function() activeTween:Cancel() end); activeTween = nil end
		if flightConn then flightConn:Disconnect(); flightConn = nil end
		if _hoverBP then
			_hoverBP.MaxForce = Vector3.new(0, 0, 0)
			_hoverBP.Parent = nil
			pcall(function() _hoverBP:Destroy() end)
		end
		if _hoverBG then
			_hoverBG.MaxTorque = Vector3.new(0, 0, 0)
			_hoverBG.Parent = nil
			pcall(function() _hoverBG:Destroy() end)
		end
		local ch = LocalPlayer.Character
		local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
		if hrp then
			for _, child in ipairs(hrp:GetChildren()) do
				if child.Name:find("^Vellum_") then
					if child:IsA("BodyGyro") then
						child.MaxTorque = Vector3.new(0, 0, 0)
					elseif child:IsA("BodyMover") then
						child.MaxForce = Vector3.new(0, 0, 0)
					end
					child.Parent = nil
					pcall(function() child:Destroy() end)
				end
			end
		end
		_hoverBP = nil
		_hoverBG = nil
		for hrp, bp in pairs(_bringBPs) do pcall(function() bp:Destroy() end) end
		_bringBPs = {}
		currentTarget = nil
		targetOriginalY = nil
		hoverEnabled = false
	end

	local flightConn
	local hoverEnabled = false
	local _hoverBP
	local _hoverBG
	local _bringBPs = {}

	local function startFlight()
		if flightConn then return end
		if _tpInProgress then return end
		hoverEnabled = true
		local ch = LocalPlayer.Character
		local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
		if not hrp then _stopFlightFn(); return end
		_hoverBP = Instance.new("BodyPosition")
		_hoverBP.Name = "Vellum_HoverBP"
		_hoverBP.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
		_hoverBP.P = 600
		_hoverBP.D = 80
		_hoverBP.Position = hrp.Position
		_hoverBP.Parent = hrp
		_hoverBG = Instance.new("BodyGyro")
		_hoverBG.Name = "Vellum_HoverBG"
		_hoverBG.MaxTorque = Vector3.new(math.huge, math.huge, math.huge)
		_hoverBG.P = 1000
		_hoverBG.D = 300
		_hoverBG.CFrame = hrp.CFrame
		_hoverBG.Parent = hrp
		flightConn = RunService.Heartbeat:Connect(function()
			if not (hoverEnabled and cfg.autoFarm) then _stopFlightFn(); return end
			if _tpInProgress then _stopFlightFn(); return end
			local ch2 = LocalPlayer.Character
			local hrp2 = ch2 and ch2:FindFirstChild("HumanoidRootPart")
			if not hrp2 then return end
			if not _hoverBP or not _hoverBP.Parent then _stopFlightFn(); return end
			if not _hoverBG or not _hoverBG.Parent then _stopFlightFn(); return end
			local enemy = (currentTarget and currentTarget.Parent) and currentTarget or nil
			if enemy then
				local ehrp = enemy:FindFirstChild("HumanoidRootPart")
				if ehrp then
					if not targetOriginalY then targetOriginalY = ehrp.Position.Y end
					local hoverY = targetOriginalY + cfg.farmHeight
					lastHoldY = hoverY
					_hoverBP.Position = Vector3.new(ehrp.Position.X, hoverY, ehrp.Position.Z)
					if cfg.aggressiveRange then
						ehrp.CFrame = CFrame.new(hrp2.Position.X, targetOriginalY, hrp2.Position.Z)
					end
				end
			else
				targetOriginalY = nil
				local holdY = lastHoldY or hrp2.Position.Y
				_hoverBP.Position = Vector3.new(hrp2.Position.X, holdY, hrp2.Position.Z)
			end
		end)
	end

	local function _bringMobs()
		if not cfg.mobBring then
			for hrp, bp in pairs(_bringBPs) do
				pcall(function() bp:Destroy() end)
			end
			_bringBPs = {}
			return
		end
		local ch = LocalPlayer.Character
		local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
		if not hrp then return end
		local pos = hrp.Position
		local seen = {}
		for _, e in ipairs(workspace.Enemies:GetChildren()) do
			local ehrp = e:FindFirstChild("HumanoidRootPart")
			local hum  = e:FindFirstChild("Humanoid")
			if ehrp and hum and hum.Health > 0 then
				local dist = (ehrp.Position - pos).Magnitude
				if dist <= cfg.mobBringRadius and dist > 3 then
					seen[ehrp] = true
					if not _bringBPs[ehrp] then
						local bp = Instance.new("BodyPosition")
						bp.Name = "Vellum_BringBP"
						bp.MaxForce = Vector3.new(math.huge, 0, math.huge)
						bp.P = 400
						bp.D = 60
						bp.Parent = ehrp
						_bringBPs[ehrp] = bp
					end
					_bringBPs[ehrp].Position = Vector3.new(pos.X, ehrp.Position.Y, pos.Z)
				end
			end
		end
		for ehrp, bp in pairs(_bringBPs) do
			if not seen[ehrp] then
				pcall(function() bp:Destroy() end)
				_bringBPs[ehrp] = nil
			end
		end
	end

	local function ensureToolEquipped()
		local ch = LocalPlayer.Character
		if not ch then return nil end
		local held = ch:FindFirstChildOfClass("Tool")
		if held then return held end
		local hum = ch:FindFirstChildOfClass("Humanoid")
		local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
		if not (hum and backpack) then return nil end
		local tool = backpack:FindFirstChildOfClass("Tool")
		if not tool then return nil end
		safe(function() hum:EquipTool(tool) end)
		task.wait(0.15)
		return ch:FindFirstChildOfClass("Tool")
	end

	local DIAG = { lastState = "", lastTick = 0 }
	local function dbg(state, extra)
		local g = getgenv().VellumBF
		if not (g and g.diag) then return end
		local now = os.clock()
		if state ~= DIAG.lastState then
			print(string.format("[BF-diag] %.2f (+%.2f) %s %s", now, now - DIAG.lastTick, state, extra or ""))
			DIAG.lastState = state; DIAG.lastTick = now
		end
	end

	local function autoFarmLoop()
		while gui.Parent do
			if _tpInProgress then jwait(1.0) continue end
			if not cfg.autoFarm then
				_stopFlightFn()
				jwait(0.5)
				continue
			end
			if not flightConn then safe(startFlight) end
			ensureToolEquipped()
			safe(function()
				local enemy = currentTarget
				if not enemy or not enemy.Parent then
					local newEnemy = pickEnemy()
					dbg("pick", newEnemy and newEnemy.Name or "none")
					if newEnemy then
						currentTarget = newEnemy
						local ch = LocalPlayer.Character
						local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
						local ehrp = newEnemy:FindFirstChild("HumanoidRootPart")
						if hrp and ehrp then
							local dist = (ehrp.Position - hrp.Position).Magnitude
							if dist > 100 then
								dbg("tween-start", newEnemy.Name .. " dist=" .. math.floor(dist))
								targetOriginalY = ehrp.Position.Y
								local hoverY = targetOriginalY + cfg.farmHeight
								local dest = Vector3.new(ehrp.Position.X, hoverY, ehrp.Position.Z)
								if _hoverBP and _hoverBP.Parent then
									_hoverBP.P, _hoverBP.D = 0, 0
									if _hoverBG and _hoverBG.Parent then _hoverBG.P = 0 end
									_tweenHRPTo(hrp, dest)
									dbg("tween-done", newEnemy.Name)
									if _hoverBP and _hoverBP.Parent then _hoverBP.P, _hoverBP.D = 600, 80; _hoverBP.Position = dest end
									if _hoverBG and _hoverBG.Parent then _hoverBG.P = 1000 end
								else
									_tweenHRPTo(hrp, dest)
									dbg("tween-done", newEnemy.Name)
								end
							else
								dbg("bp-move", newEnemy.Name .. " dist=" .. math.floor(dist))
								local hoverY = (targetOriginalY or ehrp.Position.Y) + cfg.farmHeight
								if _hoverBP and _hoverBP.Parent then
									_hoverBP.Position = Vector3.new(ehrp.Position.X, hoverY, ehrp.Position.Z)
								end
							end
						end
						return
					end
					jwait(1.5)
					return
				end
				ensureHash()
				local t0 = os.clock()
				local landed = attackOnce(enemy)
				local elapsed = os.clock() - t0
				if elapsed > 0.01 then dbg("attack-slow", enemy.Name .. " took=" .. string.format("%.4f", elapsed)) end
				local hum = enemy and enemy:FindFirstChild("Humanoid")
				if (enemy and not enemy.Parent) or (hum and hum.Health <= 0) then
					stats.sessionKills = stats.sessionKills + 1
					dbg("kill", enemy.Name)
					currentTarget = nil
					targetOriginalY = nil
				end
			end)
			safe(_bringMobs)
			jwait(cfg.attackCadence * (0.8 + math.random() * 0.4))
		end
	end

	local function autoSea1Loop()
		while gui.Parent do
			if _tpInProgress then jwait(1.0) continue end
			if cfg.autoSea1 then
				safe(autoSea1Tick)
				cfg.autoFarm = true
			end
			jwait(3.0)
		end
	end

	local function autoStatsLoop()
		while gui.Parent do
			if cfg.autoStats then
				safe(function()
					local p = LocalPlayer.Data:FindFirstChild("Points")
					if p and p.Value > 0 then
						R.CommF_:InvokeServer("AddPoint", cfg.statPriority, cfg.statBatchSize)
						jwait(0.4)
					else jwait(2.0) end
				end)
			else jwait(1.5) end
		end
	end

	local function antiAfkLoop()
		LocalPlayer.Idled:Connect(function()
			if not cfg.antiAfk then return end
			VirtualUser:CaptureController()
			VirtualUser:ClickButton2(Vector2.new())
		end)
	end

	local function trackProgressLoop()
		local data = LocalPlayer:WaitForChild("Data", 30)
		if not data then return end
		local expVal = data:WaitForChild("Exp", 10)
		local beliVal = data:WaitForChild("Beli", 10)
		if not (expVal and beliVal) then return end
		local lastXP, lastBeli = expVal.Value, beliVal.Value
		while gui.Parent do
			task.wait(1)
			local xp = expVal.Value
			local beli = beliVal.Value
			if xp > lastXP then stats.sessionXP = stats.sessionXP + (xp - lastXP) end
			if beli > lastBeli then stats.sessionBeli = stats.sessionBeli + (beli - lastBeli) end
			lastXP, lastBeli = xp, beli
		end
	end

	-- islands / sea1 / tp functions (stubs needed for autoSea1)
	local ISLAND_BY_NAME = {}
	local ISLANDS = {
		{ name = "Pirate Starter",  pos = Vector3.new(979.8, 16.5, 1429.0),    lvlRange = "Lv 1-9" },
		{ name = "Marine Starter",  pos = Vector3.new(-2566.4, 6.9, 2045.3),   lvlRange = "Lv 1-9" },
	}
	for _, island in ipairs(ISLANDS) do ISLAND_BY_NAME[island.name] = island end

	local lastHoldY

	local function autoSea1Tick() end
	local function tpToIsland(name) return false end
	local function buildIslandESP() end

	-- ═══════════════════════════ UI ═══════════════════════════
	local ui = UI.mount({
		title    = "V E L L U M",
		subtitle = "blox fruits",
		size     = UDim2.fromOffset(560, 400),
		position = UDim2.fromOffset(80, 100),
	})
	gui = ui.gui

	Toast.init({ theme = Theme, enabled = function() return cfg.notifyInGame end })

	local farm = ui.newPage("farm")
	ui.sectionLabel(farm, "AUTO FARM")
	ui.toggleRow(farm, "Auto-farm enemies",
		function() return cfg.autoFarm end,
		function(v)
			cfg.autoFarm = v
			if v then
				ensureToolEquipped()
				safe(startFlight)
				if not getHash() then
					ensureHash()
					Toast.show({title = "Hash auto-generated", body = "Session token generated and registered -- auto-farm running.", kind = "success", duration = 4})
				end
			end
		end)
	ui.intervalRow(farm, "Attack cadence (sec)",
		function() return cfg.attackCadence end,
		function(v) cfg.attackCadence = v end,
		{ 0.12, 0.15, 0.18, 0.22, 0.30 })
	ui.intervalRow(farm, "Hover height (studs)",
		function() return cfg.farmHeight end,
		function(v) cfg.farmHeight = v end,
		{ 6, 10, 14, 20, 30, 50 })
	ui.toggleRow(farm, "Aggressive range (pull target to you)",
		function() return cfg.aggressiveRange end,
		function(v) cfg.aggressiveRange = v end)
	ui.toggleRow(farm, "Mob magnet (bring enemies to you)",
		function() return cfg.mobBring end,
		function(v) cfg.mobBring = v end)
	ui.intervalRow(farm, "Mob magnet radius",
		function() return cfg.mobBringRadius end,
		function(v) cfg.mobBringRadius = v end,
		{ 20, 35, 50, 75, 100, 150 })

	ui.sectionLabel(farm, "TARGET FILTER")
	ui.intervalRow(farm, "Min enemy level",
		function() return cfg.farmLevelMin end,
		function(v) cfg.farmLevelMin = v end,
		{ 0, 5, 10, 25, 50, 100 })
	ui.intervalRow(farm, "Max enemy level",
		function() return cfg.farmLevelMax end,
		function(v) cfg.farmLevelMax = v end,
		{ 25, 50, 100, 250, 500, 9999 })

	local sea1 = ui.newPage("sea1")
	ui.sectionLabel(sea1, "AUTO PROGRESSION")
	ui.toggleRow(sea1, "Auto Sea 1 (quest + island chain)",
		function() return cfg.autoSea1 end,
		function(v)
			cfg.autoSea1 = v
			if v then
				cfg.autoFarm = true
				ensureToolEquipped()
				if not getHash() then
					ensureHash()
					Toast.show({title = "Hash auto-generated", body = "Session token ready -- Sea 1 loop driving itself.", kind = "success", duration = 4})
				end
			end
		end)
	ui.sectionLabel(sea1, "ISLAND ESP")
	ui.toggleRow(sea1, "Show island markers",
		function() return cfg.espIslands end,
		function(v) cfg.espIslands = v; buildIslandESP() end)
	ui.sectionLabel(sea1, "MANUAL TP")
	local islandOptions = {}
	for _, island in ipairs(ISLANDS) do table.insert(islandOptions, island.name) end
	local lastTpDestination = "--"
	ui.dropdownRow(sea1, "Teleport to", islandOptions,
		function() return lastTpDestination end,
		function(name)
			lastTpDestination = name
			local wasAuto = cfg.autoSea1
			if wasAuto then cfg.autoSea1 = false; autoSeaState.lastQuestKey = nil end
			local ok = tpToIsland(name)
			local island = ISLAND_BY_NAME[name]
			Toast.show({title = ok and "Teleported" or "TP failed", body = name .. (island and ("  .  " .. island.lvlRange) or "") .. (wasAuto and "  (Auto Sea 1 paused)" or ""), kind = ok and "success" or "warn", duration = 4, key = "tp:" .. name})
		end)

	local statsPage = ui.newPage("stats")
	ui.sectionLabel(statsPage, "AUTO STAT ALLOCATION")
	ui.toggleRow(statsPage, "Auto-spend stat points",
		function() return cfg.autoStats end,
		function(v) cfg.autoStats = v end)
	ui.dropdownRow(statsPage, "Stat priority",
		{ "Melee", "Defense", "Sword", "Gun", "Demon Fruit" },
		function() return cfg.statPriority end,
		function(v) cfg.statPriority = v end)
	ui.sectionLabel(statsPage, "SESSION")
	local sessionLbl = Instance.new("TextLabel", statsPage)
	sessionLbl.Size = UDim2.new(1, -8, 0, 80)
	sessionLbl.BackgroundTransparency = 1; sessionLbl.Font = Enum.Font.RobotoMono; sessionLbl.TextSize = 11
	Theme.bind(sessionLbl, "TextColor3", "text")
	sessionLbl.TextXAlignment = Enum.TextXAlignment.Left; sessionLbl.TextYAlignment = Enum.TextYAlignment.Top
	sessionLbl.Text = "--"
	task.spawn(function()
		while gui.Parent do
			local elapsed = os.clock() - stats.sessionStart
			sessionLbl.Text = string.format("  Kills:  %d\n  XP:     %s   (%s/hr)\n  Beli:   %s   (%s/hr)\n  Uptime: %s\n  Hash:   %s",
				stats.sessionKills,
				Helpers.fmt(stats.sessionXP), Helpers.perHour(stats.sessionXP, elapsed),
				Helpers.fmt(stats.sessionBeli), Helpers.perHour(stats.sessionBeli, elapsed),
				Helpers.fmtDur(elapsed),
				getHash() or "(auto-generated on first tick)")
			task.wait(1)
		end
	end)

	local settings = ui.newPage("settings")
	ui.sectionLabel(settings, "CORE")
	ui.toggleRow(settings, "Bypass AFK kick (anti-AFK)",
		function() return cfg.antiAfk end,
		function(v) cfg.antiAfk = v end)
	ui.toggleRow(settings, "In-game toast notifications",
		function() return cfg.notifyInGame end,
		function(v) cfg.notifyInGame = v end)
	ui.toggleRow(settings, "Persistent remote spy",
		function() return cfg.spyEnabled end,
		function(v) cfg.spyEnabled = v end)
	ui.actionBtn(settings, "Reset session hash (force regenerate)", function()
		clearHash()
		Toast.show({title = "Hash reset", body = "Will regenerate next tick on the current thread.", kind = "info", duration = 4})
	end)
	ui.actionBtn(settings, "Dump spy buffer to console", function()
		print("=== Vellum BF spy buffer (" .. SPY.count .. " entries) ===")
		for _, r in ipairs(spyTail(60)) do
			print(string.format("[%.2f] %s %s %s", r.t, r.r, r.m, r.v))
		end
	end)

	ui.newTab("farm",     "Farm",     1)
	ui.newTab("sea1",     "Sea 1",    2)
	ui.newTab("stats",    "Stats",    3)
	ui.newTab("settings", "Settings", 4)
	ui.setActiveTab("farm")

	buildIslandESP()

	task.spawn(autoFarmLoop)
	task.spawn(autoSea1Loop)
	task.spawn(autoStatsLoop)
	task.spawn(trackProgressLoop)
	antiAfkLoop()

	Toast.show({title = "Vellum loaded", body = "Toggle Auto-farm -- hash self-generates on first attack tick.", kind = "info", duration = 6})
end

return Module
]====])

-- ═══════════════════════════════════════════════════════════════
-- Boot
-- ═══════════════════════════════════════════════════════════════
local ok, err = xpcall(Game.start, debug.traceback, lib)
_G.VELLUM_OK = ok
_G.VELLUM_ERR = tostring(err)
if not ok then
	warn("[Vellum BUNDLE ERROR]", tostring(err))
	print("[Vellum BUNDLE ERROR]", tostring(err))
end
