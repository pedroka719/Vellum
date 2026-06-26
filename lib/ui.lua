-- Vellum — UI builders
--
-- One mount() call builds the root window (header + sidebar + content panel
-- + drag handler). The returned table exposes the widget factories that
-- parent into pages, plus references to the gui/root for game-specific
-- additions like a hero AFK card.
--
-- Modules load via HttpGet, so Theme is injected through UI.init().
--
-- Usage:
--   local UI = loadstring(...)()
--   UI.init({ theme = Theme })
--   local ui = UI.mount({ title = "VELLUM", subtitle = "spin a soccer card" })
--
--   local farm = ui.newPage("farm")
--   ui.newTab("farm", "Farm", 1)
--   ui.sectionLabel(farm, "AUTO COLLECT")
--   ui.toggleRow(farm, "Auto-collect", function() return cfg.autoCollect end,
--                                       function(v) cfg.autoCollect = v end)
--   ui.actionBtn(farm, "Test", function() ... end)
--   ui.setActiveTab("farm")

local UserInputService = game:GetService("UserInputService")
local TweenService     = game:GetService("TweenService")
local CoreGui          = game:GetService("CoreGui")
local Players          = game:GetService("Players")

local UI = {}

local Theme  -- injected

function UI.init(opts)
	opts = opts or {}
	if not opts.theme then
		error("UI.init: 'theme' is required", 2)
	end
	Theme = opts.theme
end

-- ─────────────────── host selection ───────────────────
-- CoreGui requires Plugin capability on modern Roblox — only some executors
-- expose it, and the capability can vary per-thread. Probe each candidate by
-- actually parenting a test ScreenGui (same op the real UI will need).
local function canParentTo(host)
	if not host then return false end
	local probe = Instance.new("ScreenGui")
	local ok = pcall(function() probe.Parent = host end)
	if ok and probe.Parent == host then
		probe:Destroy()
		return true
	end
	pcall(function() probe:Destroy() end)
	return false
end

local function defaultGuiHost()
	if gethui then
		local ok, h = pcall(gethui)
		if ok and h and canParentTo(h) then return h end
	end
	if canParentTo(CoreGui) then return CoreGui end
	return Players.LocalPlayer:WaitForChild("PlayerGui")
end

-- ─────────────────── mount ───────────────────
function UI.mount(opts)
	if not Theme then
		error("UI.mount: call UI.init({theme=...}) first", 2)
	end
	opts = opts or {}

	-- nuke any leftover GUI from a prior run so re-execs don't double-stack
	local host = opts.guiHost or defaultGuiHost()
	for _, c in ipairs(host:GetChildren()) do
		if c.Name == "Vellum_Suite" then pcall(function() c:Destroy() end) end
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "Vellum_Suite"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	-- Render above the game's own UI. Most games stack between 0-1000; we
	-- pick well past that so Vellum stays clickable. Toasts go one higher.
	gui.DisplayOrder = 1000000
	gui.Parent = host

	local root = Instance.new("Frame")
	root.Size = opts.size or UDim2.fromOffset(540, 380)
	root.Position = opts.position or UDim2.fromOffset(60, 120)
	Theme.bind(root, "BackgroundColor3", "bg")
	root.BorderSizePixel = 0
	root.Parent = gui
	Instance.new("UICorner", root).CornerRadius = UDim.new(0, 10)
	local rootStroke = Instance.new("UIStroke", root)
	Theme.bind(rootStroke, "Color", "stroke")
	rootStroke.Thickness = 1; rootStroke.Transparency = 0.4

	-- ─── header (also drag handle) ───
	local header = Instance.new("Frame", root)
	header.Size = UDim2.new(1, 0, 0, 56); header.BackgroundTransparency = 1
	header.Active = true

	do
		-- header-only drag: avoids capturing scroll input inside content frames
		local dragging, dragStart, startPos
		header.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
			   or input.UserInputType == Enum.UserInputType.Touch then
				dragging = true; dragStart = input.Position; startPos = root.Position
				input.Changed:Connect(function()
					if input.UserInputState == Enum.UserInputState.End then dragging = false end
				end)
			end
		end)
		UserInputService.InputChanged:Connect(function(input)
			if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
			                  or input.UserInputType == Enum.UserInputType.Touch) then
				local d = input.Position - dragStart
				root.Position = UDim2.new(
					startPos.X.Scale, startPos.X.Offset + d.X,
					startPos.Y.Scale, startPos.Y.Offset + d.Y
				)
			end
		end)
	end

	local hDivider = Instance.new("Frame", root)
	hDivider.Size = UDim2.new(1, -24, 0, 1); hDivider.Position = UDim2.fromOffset(12, 56)
	Theme.bind(hDivider, "BackgroundColor3", "stroke")
	hDivider.BackgroundTransparency = 0.4; hDivider.BorderSizePixel = 0

	-- serif wordmark + dim subtitle
	local wordmark = Instance.new("TextLabel", header)
	wordmark.Size = UDim2.new(0, 240, 0, 28); wordmark.Position = UDim2.fromOffset(18, 8)
	wordmark.BackgroundTransparency = 1
	wordmark.Text = opts.title or "V E L L U M"
	wordmark.Font = Enum.Font.Antique; wordmark.TextSize = 22
	Theme.bind(wordmark, "TextColor3", "text")
	wordmark.TextXAlignment = Enum.TextXAlignment.Left

	if opts.subtitle and opts.subtitle ~= "" then
		local subtitle = Instance.new("TextLabel", header)
		subtitle.Size = UDim2.new(0, 240, 0, 14); subtitle.Position = UDim2.fromOffset(18, 34)
		subtitle.BackgroundTransparency = 1
		subtitle.Text = opts.subtitle
		subtitle.Font = Enum.Font.Gotham; subtitle.TextSize = 10
		Theme.bind(subtitle, "TextColor3", "textDim")
		subtitle.TextXAlignment = Enum.TextXAlignment.Left
	end

	-- close × — fires opts.onClose() if provided, then destroys
	local closeBtn = Instance.new("TextButton", header)
	closeBtn.Size = UDim2.fromOffset(22, 22); closeBtn.Position = UDim2.new(1, -32, 0, 14)
	closeBtn.BackgroundTransparency = 1; closeBtn.Text = "×"
	closeBtn.Font = Enum.Font.Gotham; closeBtn.TextSize = 18
	Theme.bind(closeBtn, "TextColor3", "textDim"); closeBtn.AutoButtonColor = false
	closeBtn.MouseEnter:Connect(function() closeBtn.TextColor3 = Theme.token("danger") end)
	closeBtn.MouseLeave:Connect(function() closeBtn.TextColor3 = Theme.token("textDim") end)
	closeBtn.MouseButton1Click:Connect(function()
		if opts.onClose then pcall(opts.onClose) end
		gui:Destroy()
	end)

	-- minimize – (caller wires the visibility-toggle behavior)
	local minBtn = Instance.new("TextButton", header)
	minBtn.Size = UDim2.fromOffset(22, 22); minBtn.Position = UDim2.new(1, -60, 0, 14)
	minBtn.BackgroundTransparency = 1; minBtn.Text = "–"
	minBtn.Font = Enum.Font.Gotham; minBtn.TextSize = 16
	Theme.bind(minBtn, "TextColor3", "textDim"); minBtn.AutoButtonColor = false
	minBtn.MouseEnter:Connect(function() minBtn.TextColor3 = Theme.token("accent") end)
	minBtn.MouseLeave:Connect(function() minBtn.TextColor3 = Theme.token("textDim") end)

	-- ─── sidebar (flat list, accent strip marks active) ───
	local sidebar = Instance.new("Frame", root)
	sidebar.Size = UDim2.new(0, 108, 1, -76); sidebar.Position = UDim2.fromOffset(12, 64)
	sidebar.BackgroundTransparency = 1; sidebar.BorderSizePixel = 0
	local sideLayout = Instance.new("UIListLayout", sidebar)
	sideLayout.Padding = UDim.new(0, 2); sideLayout.SortOrder = Enum.SortOrder.LayoutOrder
	sideLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left

	-- ─── content panel ───
	local content = Instance.new("Frame", root)
	content.Size = UDim2.new(1, -136, 1, -76); content.Position = UDim2.fromOffset(124, 64)
	Theme.bind(content, "BackgroundColor3", "panel")
	content.BorderSizePixel = 0
	Instance.new("UICorner", content).CornerRadius = UDim.new(0, 6)
	local contentStroke = Instance.new("UIStroke", content)
	Theme.bind(contentStroke, "Color", "stroke")
	contentStroke.Thickness = 1; contentStroke.Transparency = 0.5

	-- ─── pages + tabs ───
	local pages = {}
	local tabs = {}  -- name -> {btn, page}
	local activeName

	local function repaintTab(name, active)
		local entry = tabs[name]
		if not entry then return end
		local btn, lbl = entry.btn, entry.lbl
		if active then
			btn.BackgroundTransparency = 0
			btn.BackgroundColor3 = Theme.token("elev")
			lbl.TextColor3 = Theme.token("text")
			btn.AccentStrip.BackgroundColor3 = Theme.token("accent")
			btn.AccentStrip.Visible = true
		else
			btn.BackgroundTransparency = 1
			lbl.TextColor3 = Theme.token("textDim")
			btn.AccentStrip.Visible = false
		end
	end

	local function setActiveTab(name)
		if not tabs[name] then return end
		if activeName then
			repaintTab(activeName, false)
			tabs[activeName].page.Visible = false
		end
		repaintTab(name, true)
		tabs[name].page.Visible = true
		activeName = name
	end

	-- Re-paint tabs whenever the theme swaps
	Theme.bindCall(function()
		for name in pairs(tabs) do
			repaintTab(name, name == activeName)
		end
	end)

	-- ─────────────── widget factories ───────────────
	local Builder = {
		gui = gui,
		root = root,
		header = header,
		sidebar = sidebar,
		content = content,
		minBtn = minBtn,
		closeBtn = closeBtn,
	}

	function Builder.newPage(name)
		local p = Instance.new("ScrollingFrame", content)
		p.Size = UDim2.new(1, -16, 1, -16); p.Position = UDim2.fromOffset(8, 8)
		p.BackgroundTransparency = 1; p.BorderSizePixel = 0; p.Visible = false
		p.ScrollBarThickness = 4; p.CanvasSize = UDim2.fromOffset(0, 0)
		p.AutomaticCanvasSize = Enum.AutomaticSize.Y
		local layout = Instance.new("UIListLayout", p)
		layout.Padding = UDim.new(0, 8); layout.SortOrder = Enum.SortOrder.LayoutOrder
		pages[name] = p
		return p
	end

	function Builder.newTab(name, label, order)
		-- Structure: TextButton frame (click target, empty intrinsic text)
		--   ├── AccentStrip Frame at x=4 (active-only)
		--   └── TextLabel  at x=14 (the label; clicks pass through to button)
		-- Avoids the UIPadding-shifts-strip-onto-text bug: UIPadding offsets
		-- every child by PaddingLeft, so a strip at x=4 lands at x=18 (over text).
		local b = Instance.new("TextButton", sidebar)
		b.Size = UDim2.new(1, 0, 0, 28); b.LayoutOrder = order or 0
		b.BackgroundTransparency = 1; b.AutoButtonColor = false
		b.Text = ""  -- label rendered by child TextLabel instead
		Instance.new("UICorner", b).CornerRadius = UDim.new(0, 4)

		local strip = Instance.new("Frame", b)
		strip.Name = "AccentStrip"
		strip.Size = UDim2.new(0, 2, 0.6, 0); strip.Position = UDim2.new(0, 4, 0.2, 0)
		strip.BackgroundColor3 = Theme.token("accent"); strip.BorderSizePixel = 0
		strip.Visible = false

		local lbl = Instance.new("TextLabel", b)
		lbl.Name = "Label"
		lbl.Size = UDim2.new(1, -18, 1, 0); lbl.Position = UDim2.fromOffset(14, 0)
		lbl.BackgroundTransparency = 1
		lbl.Text = label; lbl.Font = Enum.Font.GothamMedium; lbl.TextSize = 11
		lbl.TextColor3 = Theme.token("textDim")
		lbl.TextXAlignment = Enum.TextXAlignment.Left

		b.MouseEnter:Connect(function()
			if activeName == name then return end
			lbl.TextColor3 = Theme.token("text")
		end)
		b.MouseLeave:Connect(function()
			if activeName == name then return end
			lbl.TextColor3 = Theme.token("textDim")
		end)
		b.MouseButton1Click:Connect(function() setActiveTab(name) end)

		tabs[name] = { btn = b, lbl = lbl, page = pages[name] or error("newTab '"..name.."' before newPage", 2) }
		return b
	end

	Builder.setActiveTab = setActiveTab
	Builder.getActiveTab = function() return activeName end

	-- row container, base of every settings row
	function Builder.row(parent, height)
		local f = Instance.new("Frame", parent)
		f.Size = UDim2.new(1, -8, 0, height or 26)
		Theme.bind(f, "BackgroundColor3", "row"); f.BorderSizePixel = 0
		Instance.new("UICorner", f).CornerRadius = UDim.new(0, 4)
		return f
	end

	function Builder.sectionLabel(parent, text)
		local wrap = Instance.new("Frame", parent)
		wrap.Size = UDim2.new(1, -8, 0, 22); wrap.BackgroundTransparency = 1
		local strip = Instance.new("Frame", wrap)
		strip.Size = UDim2.new(0, 2, 0, 12); strip.Position = UDim2.new(0, 0, 0.5, -6)
		Theme.bind(strip, "BackgroundColor3", "accent"); strip.BorderSizePixel = 0
		local l = Instance.new("TextLabel", wrap)
		l.Size = UDim2.new(1, -14, 1, 0); l.Position = UDim2.fromOffset(10, 0)
		l.BackgroundTransparency = 1
		l.Text = string.upper(text); l.Font = Enum.Font.GothamBold; l.TextSize = 10
		Theme.bind(l, "TextColor3", "textDim"); l.TextXAlignment = Enum.TextXAlignment.Left
		return wrap
	end

	-- Animated iOS-style toggle. getF/setF read+write the underlying state.
	function Builder.toggleRow(parent, labelText, getF, setF)
		local r = Builder.row(parent, 30)
		local l = Instance.new("TextLabel", r)
		l.Size = UDim2.new(1, -56, 1, 0); l.Position = UDim2.fromOffset(12, 0)
		l.BackgroundTransparency = 1; l.Text = labelText
		l.Font = Enum.Font.Gotham; l.TextSize = 12
		Theme.bind(l, "TextColor3", "text"); l.TextXAlignment = Enum.TextXAlignment.Left
		local pill = Instance.new("TextButton", r)
		pill.Size = UDim2.fromOffset(34, 18); pill.Position = UDim2.new(1, -44, 0.5, -9)
		pill.AutoButtonColor = false; pill.Text = ""
		Instance.new("UICorner", pill).CornerRadius = UDim.new(1, 0)
		local dot = Instance.new("Frame", pill)
		dot.Size = UDim2.fromOffset(14, 14); dot.AnchorPoint = Vector2.new(0, 0.5)
		dot.BorderSizePixel = 0
		Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)
		local function paint(animate)
			local on = getF()
			local pillColor = on and Theme.token("accent") or Theme.token("elev")
			local dotColor  = on and Theme.token("accentText") or Theme.token("textDim")
			local dotPos    = on and UDim2.new(1, -16, 0.5, 0) or UDim2.new(0, 2, 0.5, 0)
			if animate then
				TweenService:Create(pill, TweenInfo.new(0.18), {BackgroundColor3 = pillColor}):Play()
				TweenService:Create(dot,  TweenInfo.new(0.18), {BackgroundColor3 = dotColor, Position = dotPos}):Play()
			else
				pill.BackgroundColor3 = pillColor
				dot.BackgroundColor3  = dotColor
				dot.Position = dotPos
			end
		end
		pill.MouseButton1Click:Connect(function() setF(not getF()); paint(true) end)
		paint(false)
		Theme.bindCall(function() paint(false) end)  -- repaint on theme swap
		return r
	end

	-- Compact YES/no toggle for matrix-style choices (rarity picker etc.)
	function Builder.multiToggleRow(parent, labelText, tbl, key)
		local r = Builder.row(parent, 24)
		local l = Instance.new("TextLabel", r)
		l.Size = UDim2.new(1, -52, 1, 0); l.Position = UDim2.fromOffset(12, 0)
		l.BackgroundTransparency = 1; l.Text = labelText
		l.Font = Enum.Font.Gotham; l.TextSize = 11
		Theme.bind(l, "TextColor3", "text"); l.TextXAlignment = Enum.TextXAlignment.Left
		local pill = Instance.new("TextButton", r)
		pill.Size = UDim2.fromOffset(30, 16); pill.Position = UDim2.new(1, -40, 0.5, -8)
		pill.AutoButtonColor = false; pill.Text = ""
		Instance.new("UICorner", pill).CornerRadius = UDim.new(1, 0)
		local dot = Instance.new("Frame", pill)
		dot.Size = UDim2.fromOffset(12, 12); dot.AnchorPoint = Vector2.new(0, 0.5)
		dot.BorderSizePixel = 0
		Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)
		local function paint(animate)
			local on = tbl[key]
			local pillColor = on and Theme.token("accent") or Theme.token("elev")
			local dotColor  = on and Theme.token("accentText") or Theme.token("textDim")
			local dotPos    = on and UDim2.new(1, -14, 0.5, 0) or UDim2.new(0, 2, 0.5, 0)
			if animate then
				TweenService:Create(pill, TweenInfo.new(0.15), {BackgroundColor3 = pillColor}):Play()
				TweenService:Create(dot,  TweenInfo.new(0.15), {BackgroundColor3 = dotColor, Position = dotPos}):Play()
			else
				pill.BackgroundColor3 = pillColor
				dot.BackgroundColor3 = dotColor; dot.Position = dotPos
			end
		end
		pill.MouseButton1Click:Connect(function() tbl[key] = not tbl[key]; paint(true) end)
		paint(false)
		Theme.bindCall(function() paint(false) end)
		return r
	end

	-- Cycles through a fixed set of numeric options. Display in seconds.
	function Builder.intervalRow(parent, labelText, getF, setF, options)
		local r = Builder.row(parent, 30)
		local l = Instance.new("TextLabel", r)
		l.Size = UDim2.new(0.6, 0, 1, 0); l.Position = UDim2.fromOffset(12, 0)
		l.BackgroundTransparency = 1; l.Text = labelText
		l.Font = Enum.Font.Gotham; l.TextSize = 12
		Theme.bind(l, "TextColor3", "text"); l.TextXAlignment = Enum.TextXAlignment.Left
		local b = Instance.new("TextButton", r)
		b.Size = UDim2.fromOffset(54, 20); b.Position = UDim2.new(1, -64, 0.5, -10)
		Theme.bind(b, "BackgroundColor3", "elev"); b.AutoButtonColor = false
		b.Font = Enum.Font.RobotoMono; b.TextSize = 11
		Theme.bind(b, "TextColor3", "text")
		Instance.new("UICorner", b).CornerRadius = UDim.new(0, 4)
		local function paint() b.Text = string.format("%.1fs", getF()) end
		b.MouseButton1Click:Connect(function()
			local cur = getF()
			local idx = 1
			for i, v in ipairs(options) do if v == cur then idx = i break end end
			idx = (idx % #options) + 1
			setF(options[idx]); paint()
		end)
		paint()
		return r
	end

	function Builder.actionBtn(parent, label, fn)
		local b = Instance.new("TextButton", parent)
		b.Size = UDim2.new(1, -8, 0, 28)
		Theme.bind(b, "BackgroundColor3", "elev"); b.AutoButtonColor = false
		b.Font = Enum.Font.GothamMedium; b.TextSize = 12
		Theme.bind(b, "TextColor3", "text"); b.Text = label
		Instance.new("UICorner", b).CornerRadius = UDim.new(0, 4)
		local strokeB = Instance.new("UIStroke", b)
		Theme.bind(strokeB, "Color", "stroke")
		strokeB.Thickness = 1; strokeB.Transparency = 0.6
		b.MouseEnter:Connect(function() b.TextColor3 = Theme.token("accent") end)
		b.MouseLeave:Connect(function() b.TextColor3 = Theme.token("text") end)
		b.MouseButton1Click:Connect(fn)
		return b
	end

	return Builder
end

-- Expose the host probe for game modules that need their own ScreenGui
-- (e.g., a floating minimized icon outside the main panel).
UI.defaultGuiHost = defaultGuiHost

return UI
