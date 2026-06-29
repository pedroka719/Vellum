-- Vellum â€” Blox Fruits Bundle (self-contained, with fixes)
-- Execute this directly in your executor. No HTTP fetches needed.
local function embed(src)
	local fn, err = loadstring(src, "embed")
	if not fn then error("Bundle embed error: " .. tostring(err), 0) end
	return fn()
end
local Theme = embed([====[
-- Vellum — theme system
--
-- Semantic color tokens, 5 preset palettes, runtime theme swap.
-- One theme is "active" at a time across the whole UI; calling Theme.apply(name)
-- repaints every bound element in <1 frame.
--
-- Usage:
--   local Theme = require(script.Parent.theme)
--   Theme.bind(frame, "BackgroundColor3", "panel")     -- frame follows theme
--   Theme.bindCall(repaintCustomThing)                 -- callback re-fires on swap
--   Theme.apply("Midnight")                            -- swap
--   local c = Theme.token("accent")                    -- read current value

local rgb = Color3.fromRGB

local PRESETS = {
	Vellum = {  -- default: cream-on-ink, literary
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
	Midnight = {  -- deep navy + ice blue
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
	Ink = {  -- max contrast pure black + white
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
	Parchment = {  -- warm light, literary
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
	Matte = {  -- greyscale neutral
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

-- Live mutable copy of the active theme. UI reads from this so calls like
-- `Theme.token("panel")` always return the current value, not a snapshot.
local THEME = {}
for k, v in pairs(PRESETS.Vellum) do THEME[k] = v end

-- Each entry is {instance, prop, role} OR {callback, "_call", "_call"}
local _registry = {}

local Theme = {}

function Theme.token(role)
	return THEME[role]
end

function Theme.bind(inst, prop, role)
	inst[prop] = THEME[role]
	table.insert(_registry, {inst, prop, role})
	return inst
end

-- For compound paint functions whose color logic depends on multiple tokens
-- or on local state (e.g., toggle on/off coloring). The callback fires on apply.
function Theme.bindCall(fn)
	table.insert(_registry, {fn, "_call", "_call"})
end

function Theme.apply(name)
	local preset = PRESETS[name]
	if not preset then return false end
	for k, v in pairs(preset) do THEME[k] = v end
	for _, entry in ipairs(_registry) do
		local a, prop = entry[1], entry[2]
		if prop == "_call" then
			pcall(a)
		else
			-- a.Parent itself can throw "lacking capability Plugin" on Volt
			-- when the instance lives in gethui(), so the whole touch goes
			-- inside the pcall. A live-but-detached instance is a no-op —
			-- it'll get repainted next swap if it ever re-parents.
			pcall(function()
				if a.Parent then a[prop] = THEME[entry[3]] end
			end)
		end
	end
	return true
end

function Theme.presets()
	-- Return a shallow snapshot of names + their accent/panel/text for previews
	local out = {}
	for name, preset in pairs(PRESETS) do
		out[name] = {
			accent = preset.accent,
			panel  = preset.panel,
			text   = preset.text,
		}
	end
	return out
end

function Theme.presetNames()
	-- Stable order — match the order they appear in source above
	return { "Vellum", "Midnight", "Ink", "Parchment", "Matte" }
end

return Theme

]====])

local Helpers = embed([====[
-- Vellum — generic helpers shared across game modules.
--
-- Pure functions are exposed directly: Helpers.fmt(n) etc.
-- Stateful helpers (jwait, safe) are factories that close over cfg/tag so
-- callers can use them ergonomically without re-passing context every call.

local Helpers = {}

-- Human-readable big-number formatter. "$1.23M" / "$4.56B" / "$2.10T"
function Helpers.fmt(n)
	if not n then return "0" end
	if n >= 1e12 then return string.format("%.2fT", n / 1e12) end
	if n >= 1e9  then return string.format("%.2fB", n / 1e9)  end
	if n >= 1e6  then return string.format("%.2fM", n / 1e6)  end
	if n >= 1e3  then return string.format("%.2fK", n / 1e3)  end
	return tostring(math.floor(n))
end

-- Reverse of fmt — parses "$3.53M" / "24.92M" / "700K" / "$1.2B" into a number.
function Helpers.parseCash(text)
	if not text or text == "" then return 0 end
	local num = tonumber(text:match("([%d%.]+)"))
	if not num then return 0 end
	local suffix = text:upper():match("[KMBT]")
	if suffix == "K" then num = num * 1e3
	elseif suffix == "M" then num = num * 1e6
	elseif suffix == "B" then num = num * 1e9
	elseif suffix == "T" then num = num * 1e12
	end
	return num
end

-- "1h 23m 45s" duration formatter; drops leading zero units.
function Helpers.fmtDur(secs)
	secs = math.max(0, math.floor(secs))
	local h = math.floor(secs / 3600)
	local m = math.floor((secs % 3600) / 60)
	local s = secs % 60
	if h > 0 then return string.format("%dh %dm %ds", h, m, s) end
	if m > 0 then return string.format("%dm %ds", m, s) end
	return string.format("%ds", s)
end

-- Rate-per-hour formatter. Returns "—" before the first full minute so we
-- don't surface noisy startup numbers.
function Helpers.perHour(n, elapsedSecs)
	if elapsedSecs < 60 then return "—" end
	return Helpers.fmt(math.floor(n * 3600 / elapsedSecs))
end

-- Factory: returns a jittered task.wait bound to a cfg table.
-- Reads cfg.jitter and cfg.conservativeMode every call, so toggling them
-- from the UI takes effect immediately.
--
-- Conservative mode: 2.5× longer interval + ±40% spread instead of ±20%.
-- Cuts RPC rate ~75% to dodge Roblox Volt/LEASE_3506 crashes.
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

-- Factory: returns a pcall-wrapper that logs to the console with a tag prefix.
-- Use one per logical subsystem if you want clearer log filtering.
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

local Toast = embed([========[
-- Vellum — corner toast queue
--
-- Stacked top-right notifications. Slides in, auto-dismisses, dedupes
-- duplicate messages inside a 12s window. Surface colors follow the
-- active theme; kind-stripe colors are intentional brand-independent
-- accents for warn/success and the more colorful rare/epic/hop/trade.
--
-- Since modules load via HttpGet (not real ModuleScripts), dependencies
-- are passed explicitly through init() rather than required by path.
--
-- Usage:
--   local Toast = loadstring(...)()  -- the module table
--   Toast.init({ theme = Theme, enabled = function() return cfg.notifyInGame end })
--   Toast.show({ title = "Pulled Mythic", body = "Cruyff", kind = "rare" })

local TweenService = game:GetService("TweenService")
local CoreGui      = game:GetService("CoreGui")

local Toast = {}

local Theme  -- injected by Toast.init

local HOST           -- ScreenGui anchor
local HOLDER         -- stacking Frame
local _recent  = {}  -- { [key] = lastShownClock } for dedupe
local _enabled = function() return true end  -- predicate

-- 12s minimum gap between identical keys
local DEDUPE_WINDOW = 12

-- Stripe colors per kind. warn/success follow the active theme so they
-- feel "of the brand"; rare/epic/info/hop/trade are intentional accents
-- (a gold rare in Parchment mode still reads as a treasure).
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
	sg.ResetOnSpawn = false
	sg.IgnoreGuiInset = true
	-- One higher than the main panel (1000000) so notifications stay visible
	-- when the panel is open or transitioning.
	sg.DisplayOrder = 1000001
	sg.Parent = (gethui and gethui()) or CoreGui
	HOST = sg
	HOLDER = Instance.new("Frame", sg)
	HOLDER.Size = UDim2.new(0, 320, 1, -40)
	HOLDER.Position = UDim2.new(1, -340, 0, 20)
	HOLDER.BackgroundTransparency = 1
	local list = Instance.new("UIListLayout", HOLDER)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.VerticalAlignment = Enum.VerticalAlignment.Top
	list.Padding = UDim.new(0, 8)
	return sg
end

-- Configure once per session. Required — Toast.show is a no-op until init.
--   opts.theme   : the Theme module (required; toast colors surface bg + text)
--   opts.enabled : predicate function or boolean (default true)
function Toast.init(opts)
	opts = opts or {}
	if not opts.theme then
		error("Toast.init: 'theme' is required", 2)
	end
	Theme = opts.theme
	if opts.enabled ~= nil then
		if type(opts.enabled) == "function" then
			_enabled = opts.enabled
		else
			local v = opts.enabled
			_enabled = function() return v end
		end
	end
end

-- Show a toast. opts:
--   title    : header text (required-ish)
--   body     : sub-text (multi-line ok)
--   kind     : "info" | "success" | "warn" | "rare" | "epic" | "hop" | "trade"
--   key      : dedupe key; same key inside 12s window = silently dropped
--   duration : seconds before auto-dismiss (default 5)
function Toast.show(opts)
	if not Theme then return end  -- not initialized
	if not _enabled() then return end
	ensureHost()
	local key = opts.key or (tostring(opts.title or "") .. "|" .. tostring(opts.body or ""))
	local now = os.clock()
	if _recent[key] and now - _recent[key] < DEDUPE_WINDOW then return end
	_recent[key] = now

	local kind  = opts.kind or "info"
	local color = stripeColor(kind)

	local frame = Instance.new("Frame")
	frame.Size = UDim2.new(1, 0, 0, 64)
	Theme.bind(frame, "BackgroundColor3", "row")
	frame.BorderSizePixel = 0
	frame.BackgroundTransparency = 0.05
	frame.AnchorPoint = Vector2.new(0, 0)
	frame.Position = UDim2.new(1.4, 0, 0, 0)  -- start off-screen right
	Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)

	local stripe = Instance.new("Frame", frame)
	stripe.Size = UDim2.new(0, 4, 1, -10); stripe.Position = UDim2.fromOffset(6, 5)
	stripe.BackgroundColor3 = color; stripe.BorderSizePixel = 0
	Instance.new("UICorner", stripe).CornerRadius = UDim.new(0, 2)

	local titleLbl = Instance.new("TextLabel", frame)
	titleLbl.BackgroundTransparency = 1
	titleLbl.Position = UDim2.fromOffset(18, 6)
	titleLbl.Size = UDim2.new(1, -24, 0, 18)
	titleLbl.Font = Enum.Font.GothamBold; titleLbl.TextSize = 13
	titleLbl.TextColor3 = color  -- not theme-bound; stripe color is the semantic signal
	titleLbl.TextXAlignment = Enum.TextXAlignment.Left
	titleLbl.Text = tostring(opts.title or "")

	local bodyLbl = Instance.new("TextLabel", frame)
	bodyLbl.BackgroundTransparency = 1
	bodyLbl.Position = UDim2.fromOffset(18, 24)
	bodyLbl.Size = UDim2.new(1, -24, 0, 38)
	bodyLbl.Font = Enum.Font.Gotham; bodyLbl.TextSize = 12
	Theme.bind(bodyLbl, "TextColor3", "text")
	bodyLbl.TextXAlignment = Enum.TextXAlignment.Left
	bodyLbl.TextYAlignment = Enum.TextYAlignment.Top
	bodyLbl.TextWrapped = true
	bodyLbl.Text = tostring(opts.body or "")

	frame.Parent = HOLDER

	-- slide in
	TweenService:Create(
		frame,
		TweenInfo.new(0.35, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
		{ Position = UDim2.new(0, 0, 0, 0) }
	):Play()

	-- auto-dismiss
	task.delay(opts.duration or 5, function()
		if not frame.Parent then return end
		local fade = TweenService:Create(
			frame, TweenInfo.new(0.3),
			{ Position = UDim2.new(1.4, 0, 0, 0), BackgroundTransparency = 1 }
		)
		fade:Play()
		fade.Completed:Wait()
		if frame.Parent then frame:Destroy() end
	end)
end

-- Drop all visible toasts immediately. Useful on teardown / theme swap reset.
function Toast.dismissAll()
	if not HOLDER then return end
	for _, c in ipairs(HOLDER:GetChildren()) do
		if c:IsA("Frame") then c:Destroy() end
	end
end

return Toast

]========])

local UI = embed([========[
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

	-- minimize — caller wires click via ui.minBtn
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

	-- Dropdown row — proper menu, not inline list.
	-- Click the pill → a floating panel pops over the UI (parented to gui,
	-- not parent), with accent stroke, drop shadow, and a height tween on
	-- open/close. Selected option fills with accent. Click outside closes.
	--
	-- This is the "premium" dropdown. The row stays a fixed height; the
	-- float panel overlays content below it (sibling pages won't shift).
	function Builder.dropdownRow(parent, labelText, options, getF, setF)
		local r = Builder.row(parent, 30)

		local l = Instance.new("TextLabel", r)
		l.Size = UDim2.new(0.55, 0, 1, 0); l.Position = UDim2.fromOffset(12, 0)
		l.BackgroundTransparency = 1; l.Text = labelText
		l.Font = Enum.Font.Gotham; l.TextSize = 12
		Theme.bind(l, "TextColor3", "text"); l.TextXAlignment = Enum.TextXAlignment.Left

		-- The visible trigger pill — empty intrinsic Text so the default
		-- TextButton "Button" word doesn't leak under the value label.
		local pill = Instance.new("TextButton", r)
		pill.Size = UDim2.new(0.45, -20, 0, 22)
		pill.Position = UDim2.new(0.55, 0, 0.5, -11)
		Theme.bind(pill, "BackgroundColor3", "elev"); pill.AutoButtonColor = false
		pill.Text = ""
		Instance.new("UICorner", pill).CornerRadius = UDim.new(0, 5)
		local pillStroke = Instance.new("UIStroke", pill)
		Theme.bind(pillStroke, "Color", "stroke")
		pillStroke.Thickness = 1; pillStroke.Transparency = 0.5

		local valueLbl = Instance.new("TextLabel", pill)
		valueLbl.Size = UDim2.new(1, -22, 1, 0); valueLbl.Position = UDim2.fromOffset(10, 0)
		valueLbl.BackgroundTransparency = 1
		valueLbl.Font = Enum.Font.GothamMedium; valueLbl.TextSize = 11
		Theme.bind(valueLbl, "TextColor3", "text")
		valueLbl.TextXAlignment = Enum.TextXAlignment.Left
		valueLbl.Text = tostring(getF() or options[1] or "")

		local arrow = Instance.new("TextLabel", pill)
		arrow.Size = UDim2.fromOffset(14, 22)
		arrow.Position = UDim2.new(1, -16, 0, 0)
		arrow.BackgroundTransparency = 1
		arrow.Font = Enum.Font.Gotham; arrow.TextSize = 11
		Theme.bind(arrow, "TextColor3", "textDim")
		arrow.Text = "▾"

		-- pill hover affordance
		pill.MouseEnter:Connect(function()
			pillStroke.Transparency = 0.15
			arrow.TextColor3 = Theme.token("accent")
		end)
		pill.MouseLeave:Connect(function()
			pillStroke.Transparency = 0.5
			arrow.TextColor3 = Theme.token("textDim")
		end)

		-- Float-panel state
		local floatPanel
		local closeConn  -- click-outside-to-close listener
		local arrowRotConn

		local function close()
			if not floatPanel then return end
			local p = floatPanel
			floatPanel = nil
			if closeConn then closeConn:Disconnect(); closeConn = nil end
			arrow.Text = "▾"
			local fullSize = p.Size
			local closeTween = TweenService:Create(
				p, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{ Size = UDim2.new(fullSize.X.Scale, fullSize.X.Offset, 0, 0) }
			)
			closeTween:Play()
			closeTween.Completed:Connect(function() if p.Parent then p:Destroy() end end)
		end

		local function rebuildIfNeeded() end  -- forward-declared; defined below

		local function open()
			if floatPanel then return end
			arrow.Text = "▴"

			-- Compute the trigger's absolute screen coords so the float
			-- positions itself under the pill regardless of which scrolled
			-- page hosts the row.
			local pillAbs  = pill.AbsolutePosition
			local pillSize = pill.AbsoluteSize
			local guiAbs   = gui.AbsolutePosition or Vector2.new(0, 0)  -- ScreenGui top-left

			local panelW = math.max(pillSize.X, 120)
			local panelH = #options * 28 + 12

			local p = Instance.new("Frame")
			p.Name = "Vellum_Dropdown"
			p.AnchorPoint = Vector2.new(0, 0)
			p.Position = UDim2.fromOffset(pillAbs.X - guiAbs.X, pillAbs.Y - guiAbs.Y + pillSize.Y + 4)
			p.Size = UDim2.fromOffset(panelW, 0)  -- start collapsed for tween-in
			Theme.bind(p, "BackgroundColor3", "panel"); p.BorderSizePixel = 0
			p.ZIndex = 100; p.ClipsDescendants = true
			Instance.new("UICorner", p).CornerRadius = UDim.new(0, 6)

			-- Accent stroke = the premium feel
			local accentStroke = Instance.new("UIStroke", p)
			Theme.bind(accentStroke, "Color", "accent")
			accentStroke.Thickness = 1.4
			accentStroke.Transparency = 0.25

			-- Inner content gets padding so options don't kiss the corners
			local pad = Instance.new("UIPadding", p)
			pad.PaddingTop = UDim.new(0, 5); pad.PaddingBottom = UDim.new(0, 5)
			pad.PaddingLeft = UDim.new(0, 5); pad.PaddingRight = UDim.new(0, 5)

			local list = Instance.new("UIListLayout", p)
			list.Padding = UDim.new(0, 2)
			list.SortOrder = Enum.SortOrder.LayoutOrder

			local currentSelection = getF()

			for i, opt in ipairs(options) do
				local isSel = (opt == currentSelection)

				local optBtn = Instance.new("TextButton", p)
				optBtn.LayoutOrder = i
				optBtn.Size = UDim2.new(1, 0, 0, 26)
				optBtn.AutoButtonColor = false
				optBtn.Text = ""  -- label rendered by child for cleaner alignment
				optBtn.ZIndex = 101
				Instance.new("UICorner", optBtn).CornerRadius = UDim.new(0, 4)

				-- selected gets accent fill + check mark; others get row fill
				if isSel then
					optBtn.BackgroundColor3 = Theme.token("accent")
					optBtn.BackgroundTransparency = 0.15
				else
					Theme.bind(optBtn, "BackgroundColor3", "row")
					optBtn.BackgroundTransparency = 0.4
				end

				local optLbl = Instance.new("TextLabel", optBtn)
				optLbl.Size = UDim2.new(1, -28, 1, 0)
				optLbl.Position = UDim2.fromOffset(12, 0)
				optLbl.BackgroundTransparency = 1
				optLbl.Font = isSel and Enum.Font.GothamBold or Enum.Font.Gotham
				optLbl.TextSize = 11
				optLbl.TextXAlignment = Enum.TextXAlignment.Left
				optLbl.Text = opt
				optLbl.ZIndex = 102
				if isSel then
					optLbl.TextColor3 = Theme.token("accentText")
				else
					Theme.bind(optLbl, "TextColor3", "text")
				end

				-- subtle check-mark on selected
				if isSel then
					local check = Instance.new("TextLabel", optBtn)
					check.Size = UDim2.fromOffset(20, 26)
					check.Position = UDim2.new(1, -22, 0, 0)
					check.BackgroundTransparency = 1
					check.Font = Enum.Font.GothamBold; check.TextSize = 12
					check.TextColor3 = Theme.token("accentText")
					check.Text = "✓"
					check.ZIndex = 102
				end

				-- hover affordance for non-selected items
				if not isSel then
					optBtn.MouseEnter:Connect(function()
						optBtn.BackgroundColor3 = Theme.token("elev")
						optBtn.BackgroundTransparency = 0
					end)
					optBtn.MouseLeave:Connect(function()
						optBtn.BackgroundColor3 = Theme.token("row")
						optBtn.BackgroundTransparency = 0.4
					end)
				end

				optBtn.MouseButton1Click:Connect(function()
					setF(opt)
					valueLbl.Text = opt
					close()
				end)
			end

			p.Parent = gui  -- overlay on the root ScreenGui

			-- Tween-in: panel expands from height=0 down to full
			TweenService:Create(
				p, TweenInfo.new(0.18, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
				{ Size = UDim2.fromOffset(panelW, panelH) }
			):Play()

			floatPanel = p

			-- Click outside the float panel = close. Bind on the gui root.
			closeConn = UserInputService.InputBegan:Connect(function(input, processed)
				if processed then return end
				if input.UserInputType ~= Enum.UserInputType.MouseButton1
				   and input.UserInputType ~= Enum.UserInputType.Touch then return end
				local pos = UserInputService:GetMouseLocation()
				if not floatPanel then return end
				local abs, sz = floatPanel.AbsolutePosition, floatPanel.AbsoluteSize
				-- guard against null sizes during tween
				if sz.X <= 0 or sz.Y <= 0 then return end
				local insidePanel =
					pos.X >= abs.X and pos.X <= abs.X + sz.X and
					pos.Y >= abs.Y and pos.Y <= abs.Y + sz.Y
				local pillAb, pillSz = pill.AbsolutePosition, pill.AbsoluteSize
				local insidePill =
					pos.X >= pillAb.X and pos.X <= pillAb.X + pillSz.X and
					pos.Y >= pillAb.Y and pos.Y <= pillAb.Y + pillSz.Y
				if not insidePanel and not insidePill then close() end
			end)
		end

		pill.MouseButton1Click:Connect(function()
			if floatPanel then close() else open() end
		end)

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

]========])

local ESP = embed([====[
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

]====])
local lib = {
	theme   = Theme,
	helpers = Helpers,
	toast   = Toast,
	ui      = UI,
	esp     = ESP,
}
local Game = embed([========[
-- Vellum — Blox Fruits (v0.2)
--
-- PlaceId 2753915549. Single source of truth: this file. lib/ stays generic.
--
-- Combat protocol:
--   1. RegisterAttack:FireServer(damageMul)            -- 0.5 normal / 1.0 finisher
--   2. RegisterHit:FireServer(part, {}, nil, hash)     -- part is child of enemy
--   ~0.18s between swings is realistic and unflagged.
--
-- Hash is self-generated from UserId + thread ID (same formula BF's CombatUtil
-- uses internally). We fire its one-shot registration ourselves so the server
-- accepts our hits. No dependency on the game's broken CombatUtil coroutine.
--
-- Movement: NEVER raw CFrame TPs (detection vector). Always tween, capped
-- below the velocity guard's 1500 threshold (the StarterCharacter "Fling
-- and Underwater Glitching Fix" zeroes velocity past that).
--
-- Safe Farm: hover N studs above the target's HRP. Mobs can't reach, the
-- server validates the part exists at hit time, not line-of-sight.

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

	-- Forward-declare so the loop closures below capture this as an upvalue
	-- instead of a global nil. The assignment happens after UI.mount().
	local gui

	-- ═══════════════════════════ R TABLE ═══════════════════════════
	local Net = ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Net")
	local Remotes = ReplicatedStorage:WaitForChild("Remotes")

	local R = {
		RegisterAttack = Net:WaitForChild("RE/RegisterAttack"),
		RegisterHit    = Net:WaitForChild("RE/RegisterHit"),
		CommF_         = Remotes:WaitForChild("CommF_"),
		CommE          = Remotes:WaitForChild("CommE"),
	}

	-- ═══════════════════════════ CONFIG ═══════════════════════════
	local cfg = {
		-- master AFK
		afkMode = false,

		-- farm
		autoFarm = false,
		farmHeight = 10,            -- studs above target (safe farm)
		attackCadence = 0.25,       -- sec between RegisterAttack/Hit pairs
		damageMultiplier = 1.0,     -- 1.0 = always finisher hits
		farmLevelMin = 0,           -- only attack enemies within range
		farmLevelMax = 9999,
		farmTargetName = "",        -- "" = any enemy. Set to "Bandit" etc.
		aggressiveRange = false,    -- pull target under us each tick (ignores server range)
		mobBring = false,           -- pull all nearby enemies toward player
		mobBringRadius = 50,        -- max studs to pull enemies from

		-- auto farm level (replaces autoSea1)
		autoFarmLevel = false,       -- full quest lifecycle (accept → farm → detect done → re-accept)
		autoSea1 = false,            -- kept for backward compat, driven by autoFarmLevel

		-- weapon selection
		selectedWeapon = "",         -- name of weapon to auto-equip ("" = first available)

		-- ability rotation
		abilitySlots = { Z = false, X = false, C = false, V = false, F = false },
		abilityCadence = 2.0,        -- sec between ability activations

		-- island ESP
		espIslands = true,           -- billboard names over each island

		-- stat allocation
		autoStats = false,
		statPriority = "Melee",     -- "Melee" | "Defense" | "Sword" | "Gun" | "Demon Fruit"
		statBatchSize = 1,          -- points per AddPoint call

		-- anti-AFK (port from soccer)
		antiAfk = true,

		-- spy
		spyEnabled = true,
		spyBufferSize = 200,        -- rolling log size
		notifyInGame = true,        -- toast notifications
		keybindToggle = true,       -- RightShift toggles UI minimize
	}

	-- ═══════════════════════════ STATE ═══════════════════════════
	local stats = {
		sessionXP = 0,
		sessionBeli = 0,
		sessionKills = 0,
		sessionStart = os.clock(),
	}

	local jwait = Helpers.makeJwait(cfg)
	local safe = Helpers.makeSafe("Vellum BF")

	-- ═══════════════════════════ PERSISTENT SPY ═══════════════════════════
	-- Rolling log + persistent session hash store. The __namecall hook is
	-- installed once per Roblox session and writes captured hashes into
	-- getgenv().VellumBF.hash, where every future BF module boot reads from.
	getgenv().VellumBF = getgenv().VellumBF or {}
	local SPY = getgenv().VellumBF
	-- Ring buffer. O(1) push, no per-insert shift. If a prior boot left a
	-- different-shaped log behind, re-initialize.
	if type(SPY.log) ~= "table" or SPY.cap ~= cfg.spyBufferSize then
		SPY.log   = table.create(cfg.spyBufferSize)
		SPY.cap   = cfg.spyBufferSize
		SPY.head  = 1   -- next write slot
		SPY.count = 0   -- entries actually written, capped at cap
	end
	SPY.frozen = false

	-- Teleport-in-progress guard. Pauses autoFarm + flight while a TP runs
	-- so the hover loop doesn't fight the tween for HRP control.
	local _tpInProgress = false

	-- Master alive flag. Set to false when the GUI is closed so all spawned
	-- loops (autoFarm, autoFarmLevel, autoStats, progress) exit cleanly instead
	-- of running forever. Without this the loops depended on gui.Parent,
	-- which kills them when the ScreenGui is destroyed — but that means
	-- toggling auto-farm back ON after closing/reopening the GUI does
	-- nothing because the loop is already dead.
	local _running = true

	-- Self-generate and register a session hash using the same formula BF's
	-- CombatUtil uses internally (UserId chars 2-4 + thread hex chars 11-15).
	-- The server accepts any consistent 8-hex-char hash — we just have to fire
	-- the one-shot registration BEFORE using it in RegisterHit calls.
	local function generateHash()
		local prefix = tostring(LocalPlayer.UserId):sub(2, 4)
		local suffix = tostring(coroutine.running()):sub(11, 15)
		return prefix .. suffix
	end

	-- Register the hash with the server so RegisterHit:FireServer(..., hash)
	-- is accepted. Fire-and-forget — the server stores it per-session.
	local function registerHash(hash)
		if not hash then return end
		local ok, err = pcall(function() R.RegisterHit:FireServer(hash) end)
		if ok then
			warn("[Vellum BF] hash registered:", hash)
		else
			warn("[Vellum BF] hash registration failed:", err)
		end
	end

	-- Ensure we have a hash generated and registered. Called at boot and after
	-- respawn. Once registered, the hash is stored in SPY (getgenv) and reused
	-- across script reloads until the next CharacterAdded invalidates it.
	local function ensureHash()
		if SPY.hash then return SPY.hash end
		SPY.hash = generateHash()
		registerHash(SPY.hash)
		return SPY.hash
	end

	local function getHash() return SPY.hash end

	local function clearHash()
		SPY.hash = nil
		warn("[Vellum BF] session hash cleared — will regenerate on next tick")
	end

	local function spyPush(row)
		if SPY.frozen then return end
		SPY.log[SPY.head] = row
		SPY.head = (SPY.head % SPY.cap) + 1
		if SPY.count < SPY.cap then SPY.count = SPY.count + 1 end
	end

	-- Newest N entries in chronological order (oldest of the N → newest).
	-- Used by the spy-dump UI button. n defaults to SPY.count.
	local function spyTail(n)
		n = math.min(n or SPY.count, SPY.count)
		local out = table.create(n)
		for i = 1, n do
			local idx = ((SPY.head - (n - i) - 2) % SPY.cap) + 1
			out[i] = SPY.log[idx]
		end
		return out
	end

	-- ─── Hash self-generation ───
	-- We self-generate and register the session hash instead of extracting it
	-- from BF's CombatUtil (which doesn't initialize properly in executors).
	-- The hash formula matches the game's: UserId:sub(2,4) .. thread:sub(11,15).
	-- generateHash(), registerHash(), and ensureHash() defined above.

	-- BF rotates the hash every respawn. Generate a fresh one, register it,
	-- and resume farming on the new character.
	LocalPlayer.CharacterAdded:Connect(function()
		clearHash()
		-- Generate and register a new hash on the new character's thread
		task.spawn(function()
			task.wait(1.5)  -- let the character load
			ensureHash()
		end)
	end)

	-- Hooks DISABLED: suspected Hyperion delayed-crash trigger.
	-- Our attack loop fires FireServer directly with self-generated hash
	-- — no dependency on either hook. Keep dead code for easy re-enable
	-- during debugging sessions where spy capture is needed.
	if false then
		local POLL_NOISE = {
			getInventory = true, getFish = true, getRaceLevel = true,
			getInfo = true, getStarterPack = true, getRouletteData = true,
		}
		SPY.decim = 5
		SPY.decimN = 0
		local oldNC
		oldNC = hookmetamethod(game, "__namecall", function(self, ...)
			local m = getnamecallmethod()
			if m == "FireServer" or m == "InvokeServer" then
				local nm = self.Name
				local v = (select(1, ...))
				if not (type(v) == "string" and POLL_NOISE[v]) then
					SPY.decimN = (SPY.decimN % SPY.decim) + 1
					if SPY.decimN == 1 then
						spyPush({
							t = os.clock(),
							r = nm,
							m = m,
							v = type(v) == "string" and v or "<" .. type(v) .. ">",
						})
					end
				end
			end
			return oldNC(self, ...)
		end)
		SPY.hookInstalled = true
	end

	-- ─── Mouse.Hit / Mouse.Target substitution hook ───
	-- Persistent __index hook on game. When SPY._captureMode is on, any read
	-- of Mouse.Hit or Mouse.Target returns SPY._captureTarget.CFrame / the
	-- part itself, instead of whatever the user's real cursor is pointing at.
	--
	-- This is what lets a synthetic firesignal(Tool.Activated) actually land
	-- a hit — BF's combat handler reads Mouse.Hit at click time; without the
	-- hook it sees the user's actual cursor position (sky, ground, nothing),
	-- bails, and never fires RegisterHit. With the hook it sees the enemy
	-- HRP we chose, fires RegisterHit normally, and our __namecall spy above
	-- catches the hash from that call.
	--
	-- Critical safety: NEVER access self.Anything inside the hook — that
	-- would re-trigger __index and infinite-recurse. Use oldIdx(self, key)
	-- for any property read we need, and :IsA which goes through __namecall
	-- (a different metamethod) so it doesn't loop.
	if false then
		-- __index Mouse redirect DISABLED — same root cause as __namecall
		-- hook. Current attackOnce() fires FireServer directly, has no
		-- dependency on Mouse redirects. Keep dead code for re-enable.
		local oldIdx
		oldIdx = hookmetamethod(game, "__index", function(self, key)
			if SPY._captureMode and SPY._captureTarget then
				if typeof(self) == "Instance" and self:IsA("Mouse") then
					local target = SPY._captureTarget
					local targetCF = oldIdx(target, "CFrame")
					local targetPos = targetCF.Position
					if key == "Hit" then
						return targetCF
					elseif key == "Target" then
						return target
					elseif key == "Origin" then
						return oldIdx(workspace.CurrentCamera, "CFrame")
					elseif key == "UnitRay" then
						local camCF = oldIdx(workspace.CurrentCamera, "CFrame")
						return Ray.new(camCF.Position, (targetPos - camCF.Position).Unit)
					elseif key == "X" or key == "Y" then
						local vp = oldIdx(workspace.CurrentCamera, "ViewportSize")
						return key == "X" and vp.X * 0.5 or vp.Y * 0.5
					end
				end
			end
			return oldIdx(self, key)
		end)
		SPY.mouseHookInstalled = true
	end

	-- Punishment detection — if BF kicks us, surface the spy buffer.
	game:GetService("LogService").MessageOut:Connect(function(msg, mtype)
		if mtype ~= Enum.MessageType.MessageError then return end
		if msg:lower():find("kick") or msg:lower():find("ban") or msg:lower():find("disconnect") then
			SPY.frozen = true
			warn("[Vellum BF] PUNISHMENT DETECTED — spy buffer frozen with " ..
				tostring(SPY.count) .. " entries. Inspect getgenv().VellumBF.log")
		end
	end)

	-- ═══════════════════════════ COMBAT ═══════════════════════════
	local BODY_PARTS = {
		"UpperTorso", "Head", "LowerTorso",
		"LeftLowerLeg", "RightLowerLeg",
		"LeftUpperArm", "RightUpperArm",
	}

	local function pickPart(enemy)
		for _, name in ipairs(BODY_PARTS) do
			local p = enemy:FindFirstChild(name)
			if p and p:IsA("BasePart") then return p end
		end
		return enemy:FindFirstChildOfClass("MeshPart")
	end

	local function attackOnce(enemy)
		local part = pickPart(enemy)
		local hash = getHash()
		if not part or not hash then return false end
		safe(function() R.RegisterAttack:FireServer(cfg.damageMultiplier) end)
		safe(function() R.RegisterHit:FireServer(part, {}, nil, hash) end)
		return true
	end

	-- ═══════════════════════════ COMBAT ═══════════════════════════
	-- We use the standard RegisterAttack + RegisterHit protocol with a
	-- self-generated hash. The CombatFramework API path was removed in
	-- BF's internal refactor (no RigLib, no RigControllerEvent, no
	-- PlayerScripts.CombatFramework). The hash is the only gate.

	-- ═══════════════════════════ TARGETING ═══════════════════════════
	-- Score = inverse distance + level-fit. Closer + within range = higher.
	-- Filter values are a *preference*, not a hard gate. If nothing matches
	-- the name + level constraints, fall back to the closest alive enemy so
	-- auto-farm never gets stuck silent. Stale filters from a prior Auto
	-- Sea 1 quest tier were the worst offender here.
	local _scanStuckCount = 0  -- ticks without finding quest mob

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
				local score = 1000 - d  -- closer = higher

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

		-- When a quest mob target is set, prefer those enemies 100%.
		-- But if we scan for ~18s without finding one (e.g. wrong spawn
		-- area), any enemy is better than stalling — keeps XP flowing.
		if cfg.farmTargetName ~= "" then
			if bestFiltered then
				_scanStuckCount = 0
				return bestFiltered
			end
			_scanStuckCount = _scanStuckCount + 1
			if _scanStuckCount < 12 then  -- ~18s at 1.5s/scan
				return nil
			end
			dbg("pick-stuck", "quest mob '" .. cfg.farmTargetName .. "' not seen in " .. _scanStuckCount .. " scans, falling back")
		end
		return bestFiltered or bestAny
	end

	-- ═══════════════════════════ ISLAND MAP ═══════════════════════════
	-- Sea 1 destinations. Coordinates lifted from RoyxHub's verified set —
	-- their hub uses these exact CFrames and they survive BF's anti-cheat.
	-- An island with `portal = <name>` is reached through a BF portal pad
	-- (see PORTAL_PADS below) rather than a raw tween.
	local ISLANDS = {
		{ name = "Pirate Starter",  pos = Vector3.new(979.8, 16.5, 1429.0),    lvlRange = "Lv 1-9"     },
		{ name = "Marine Starter",  pos = Vector3.new(-2566.4, 6.9, 2045.3),   lvlRange = "Lv 1-9"     },
		{ name = "Middle Town",     pos = Vector3.new(-690.3, 15.1, 1582.2),   lvlRange = "Lv 10-14"   },
		{ name = "Jungle",          pos = Vector3.new(-1612.8, 36.9, 149.1),   lvlRange = "Lv 15-29"   },
		{ name = "Pirate Village",  pos = Vector3.new(-1181.3, 4.8, 3803.5),   lvlRange = "Lv 30-59"   },
		{ name = "Desert",          pos = Vector3.new(944.2, 20.9, 4373.3),    lvlRange = "Lv 60-89"   },
		{ name = "Frozen Village",  pos = Vector3.new(1347.8, 104.7, -1319.7), lvlRange = "Lv 90-119"  },
		{ name = "Marine Fortress", pos = Vector3.new(-4914.8, 51.0, 4281.0),  lvlRange = "Lv 120-149" },
		{ name = "Skylands",        pos = Vector3.new(-4607.0, 874.0, -1667.0),lvlRange = "Lv 150-249", portal = "Sky3Exit" },
		{ name = "Prison",          pos = Vector3.new(4875.3, 5.7, 734.9),     lvlRange = "Lv 250-324" },
		{ name = "Colosseum",       pos = Vector3.new(-11.3, 29.3, 2771.5),    lvlRange = "PvP"        },
		{ name = "Magma Village",   pos = Vector3.new(-5247.7, 12.9, 8504.9),  lvlRange = "Lv 325-449" },
		{ name = "Underwater City", pos = Vector3.new(61165.2, 0.2, 1897.4),   lvlRange = "Lv 450-624", portal = "UnderwaterExit" },
		{ name = "Fountain City",   pos = Vector3.new(5127.1, 59.5, 4105.4),   lvlRange = "Lv 625-749" },
	}

	local ISLAND_BY_NAME = {}
	for _, i in ipairs(ISLANDS) do ISLAND_BY_NAME[i.name] = i end

	-- BF portal pads. Stand on/near the pad position, fire CommF_:requestEntrance
	-- with that Vector3, and the server completes the warp through the linked
	-- portal — same path the Portal Fruit / Sea Portal uses. Server-authorized,
	-- no rollback. The pad is where the PLAYER must be; destination is the
	-- island's pos in ISLANDS above.
	local PORTAL_PADS = {
		UnderwaterExit = Vector3.new(4050, -1, -1814),    -- surface pad → Underwater City
		Sky3Exit       = Vector3.new(-4607, 874, -1667),  -- sky portal (Skylands variant)
	}

	-- Island TP — pisun-hub pattern, the one that actually works.
	--
	-- BF's anti-cheat watches HRP per-frame: it rolls back tweens that finish
	-- in under ~5 seconds (any distance) and any single CFrame delta past a
	-- modest threshold. The bypass:
	--   1. If destination Y differs by > Y_SNAP_THRESHOLD from current, snap
	--      Y first with a direct CFrame write, wait 0.5s for the server to
	--      reconcile. BF tolerates pure vertical jumps better than diagonals.
	--   2. Tween HRP CFrame to the destination at TP_TWEEN_SPEED studs/sec
	--      linear. 150 keeps duration well above the 5s detection floor for
	--      any non-trivial trip. Fallback at 80 for retries after rollback.
	--   3. Y delta is handled by the tween itself — no instant CFrame snap.
	--      BF's server velocity guard flags single-frame position jumps.
	--   4. For destinations behind a server-side portal (Underwater City),
	--      tween to the portal pad first, then fire CommF_:requestEntrance —
	--      the server completes the warp legitimately, no rollback risk.
	local TP_TWEEN_SPEED   = 150
	local Y_SNAP_THRESHOLD = 75
	local activeTween

	-- Forward-declared so tpToIsland can call _stopFlightFn. Some executors
	-- miscompile `local function` forward refs, so we assign into a pre-decl.
	local _stopFlightFn
	local _bringBPs = {}       -- enemy HRP -> BodyPosition for mob magnet

	_stopFlightFn = function()
		-- Cancel any active tween so toggle-off stops movement instantly
		-- instead of letting the tween complete and fly the character to
		-- the destination first.
		if activeTween then pcall(function() activeTween:Cancel() end); activeTween = nil end
		-- NOTE: flightConn is NEVER disconnected. The Heartbeat stays alive
		-- for the entire session and gates on hoverEnabled + cfg.autoFarm.
		-- Disconnect/reconnect is unreliable across executor environments.

		-- Aggressively disable and remove all Vellum force fields.
		-- Some executors block :Destroy() but allow property writes and
		-- Parent=nil — so we zero force/torque first, then detach, then
		-- destroy as a safety net. Without this the BP (MaxForce=math.huge)
		-- holds the character locked in place and the BG fights rotation,
		-- making jump/dodge impossible after toggle-off.
		-- Also sweep the HRP for any orphan Vellum_* instances left by
		-- interrupted tweens or partial cleanup from prior crashes.
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

		-- Restore collision on character parts
		local ch2 = LocalPlayer.Character
		if ch2 then
			for _, p in ipairs(ch2:GetDescendants()) do
				if p:IsA("BasePart") then
					p.CanCollide = true
				end
			end
		end
	end

	local function _tweenHRPTo(hrp, destPos, opts)
		opts = opts or {}
		local speed         = opts.speed         or TP_TWEEN_SPEED
		local fallbackSpeed = opts.fallbackSpeed  or 80
		local maxRetries    = opts.retries        or 2

		if activeTween then pcall(function() activeTween:Cancel() end) end

		local destCF = CFrame.new(destPos, destPos - Vector3.new(0, 0, 1))
		local dist = (destPos - hrp.Position).Magnitude
		if dist < 3 then return end

		for attempt = 1, maxRetries do
			local curSpeed = attempt == 1 and speed or fallbackSpeed
			local dur = math.max(0.1, dist / curSpeed)
			local tween = TweenService:Create(hrp, TweenInfo.new(dur, Enum.EasingStyle.Linear), { CFrame = destCF })
			activeTween = tween
			tween:Play()
			tween.Completed:Wait()
			if activeTween == tween then activeTween = nil end

			local arrived = (hrp.Position - destPos).Magnitude < 80
			if arrived then return end

			dist = (destPos - hrp.Position).Magnitude
			task.wait(0.3)
		end
	end

	local function tpToIsland(name)
		local island = ISLAND_BY_NAME[name]
		if not island then return false end
		local ch = LocalPlayer.Character
		local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
		if not hrp then return false end

		_tpInProgress = true
		local restoreAutoFarm = cfg.autoFarm
		local restoreAutoFL   = cfg.autoFarmLevel
		cfg.autoFarm = false
		cfg.autoFarmLevel = false
		_stopFlightFn()

		-- Portal-fronted destination: tween to the pad, fire requestEntrance,
		-- let the server finish the warp.
		if island.portal and PORTAL_PADS[island.portal] then
			local padPos = PORTAL_PADS[island.portal]
			_tweenHRPTo(hrp, padPos + Vector3.new(0, 4, 0))
			safe(function() R.CommF_:InvokeServer("requestEntrance", padPos) end)
			-- Bump up 50 studs so we don't immediately re-trigger the same pad
			hrp.CFrame = hrp.CFrame + Vector3.new(0, 50, 0)
			task.wait(1.5)  -- server completes portal warp
		else
			local landingPos = island.pos + Vector3.new(0, 4, 0)
			_tweenHRPTo(hrp, landingPos)
		end

		task.wait(0.3)
		_tpInProgress = false
		cfg.autoFarm = restoreAutoFarm
		cfg.autoFarmLevel = restoreAutoFL
		return true
	end

	-- ═══════════════════════════ QUEST ATLAS ═══════════════════════════
	-- Sea 1 quest progression with taskCount from the live Quests module.
	-- Faction-Specific note: BanditQuest1 works on Pirate Starter,
	-- MarineQuest works on Marine Starter. Both give the same XP.
	-- If a questId fires and the server ignores it (no-accept), we log it
	-- and the user adjusts the row.
	local SEA1_QUESTS = {
		{ lvlMin = 1,   lvlMax = 9,   island = "Pirate Starter",  questId = "BanditQuest1",  tier = 1, mob = "Bandit",          taskCount = 5 },
		{ lvlMin = 1,   lvlMax = 9,   island = "Marine Starter",  questId = "MarineQuest",   tier = 1, mob = "Trainee",         taskCount = 5 },
		{ lvlMin = 10,  lvlMax = 14,  island = "Middle Town",     questId = "MarineQuest",   tier = 1, mob = "Trainee",         taskCount = 5 },
		{ lvlMin = 15,  lvlMax = 19,  island = "Jungle",          questId = "JungleQuest",   tier = 1, mob = "Monkey",          taskCount = 6 },
		{ lvlMin = 20,  lvlMax = 29,  island = "Jungle",          questId = "JungleQuest",   tier = 2, mob = "Gorilla",         taskCount = 8 },
		{ lvlMin = 30,  lvlMax = 39,  island = "Pirate Village",  questId = "BuggyQuest1",   tier = 1, mob = "Pirate",          taskCount = 8 },
		{ lvlMin = 40,  lvlMax = 59,  island = "Pirate Village",  questId = "BuggyQuest1",   tier = 2, mob = "Brute",           taskCount = 8 },
		{ lvlMin = 60,  lvlMax = 74,  island = "Desert",          questId = "DesertQuest",   tier = 1, mob = "Desert Bandit",   taskCount = 8 },
		{ lvlMin = 75,  lvlMax = 89,  island = "Desert",          questId = "DesertQuest",   tier = 2, mob = "Desert Officer",  taskCount = 6 },
		{ lvlMin = 90,  lvlMax = 99,  island = "Frozen Village",  questId = "SnowQuest",     tier = 1, mob = "Snow Bandit",     taskCount = 7 },
		{ lvlMin = 100, lvlMax = 119, island = "Frozen Village",  questId = "SnowQuest",     tier = 2, mob = "Snowman",         taskCount = 8 },
		{ lvlMin = 120, lvlMax = 149, island = "Marine Fortress", questId = "MarineQuest2",  tier = 1, mob = "Chief Petty Officer", taskCount = 8 },
		{ lvlMin = 150, lvlMax = 174, island = "Skylands",        questId = "SkyQuest",      tier = 1, mob = "Sky Bandit",      taskCount = 7 },
		{ lvlMin = 175, lvlMax = 189, island = "Skylands",        questId = "SkyQuest",      tier = 2, mob = "Dark Master",     taskCount = 8 },
		{ lvlMin = 190, lvlMax = 219, island = "Skylands",        questId = "PrisonerQuest", tier = 1, mob = "Prisoner",        taskCount = 8 },
		{ lvlMin = 220, lvlMax = 249, island = "Skylands",        questId = "ImpelQuest",    tier = 1, mob = "Warden",          taskCount = 1 },
		{ lvlMin = 250, lvlMax = 274, island = "Prison",          questId = "ColosseumQuest",tier = 1, mob = "Toga Warrior",    taskCount = 7 },
		{ lvlMin = 275, lvlMax = 324, island = "Prison",          questId = "ColosseumQuest",tier = 2, mob = "Gladiator",       taskCount = 8 },
		{ lvlMin = 325, lvlMax = 374, island = "Magma Village",   questId = "MagmaQuest",    tier = 1, mob = "Military Soldier",taskCount = 7 },
		{ lvlMin = 375, lvlMax = 449, island = "Magma Village",   questId = "MagmaQuest",    tier = 2, mob = "Military Spy",    taskCount = 8 },
		{ lvlMin = 450, lvlMax = 524, island = "Underwater City", questId = "FishmanQuest",  tier = 1, mob = "Fishman Warrior", taskCount = 8 },
		{ lvlMin = 525, lvlMax = 624, island = "Underwater City", questId = "FishmanQuest",  tier = 2, mob = "Fishman Commando",taskCount = 7 },
		{ lvlMin = 625, lvlMax = 749, island = "Fountain City",   questId = "FountainQuest", tier = 1, mob = "Galley Pirate",   taskCount = 8 },
		{ lvlMin = 750, lvlMax = 999, island = "Fountain City",   questId = "FountainQuest", tier = 2, mob = "Galley Captain",  taskCount = 9 },
	}

	-- Picks the highest-level-fit quest for a given player level.
	-- Iterates from end so higher-level entries win (later rows = higher tier).
	local function pickQuest(level)
		local best
		for _, q in ipairs(SEA1_QUESTS) do
			if level >= q.lvlMin and level <= q.lvlMax then best = q end
		end
		return best
	end

	-- Are we close enough to the island to consider ourselves "there"?
	-- XZ-only distance — island.pos.Y is the bbox top, but the player
	-- stands on the ground far below, so a 3D check would always fail
	-- for tall/sky islands.
	local function atIsland(name)
		local island = ISLAND_BY_NAME[name]
		if not island then return false end
		local ch = LocalPlayer.Character
		local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
		if not hrp then return false end
		local dx = hrp.Position.X - island.pos.X
		local dz = hrp.Position.Z - island.pos.Z
		return math.sqrt(dx * dx + dz * dz) < 350
	end

	-- ═══════════════════════════ QUEST LIFECYCLE ═══════════════════════════
	-- Tracks the active quest, kill progress toward completion, and when
	-- the task count is met the autoFarmLevelLoop advances to the next tier.
	-- Kill counting happens inside autoFarmLoop (death event).

	-- Current quest state. Reset when quest completes or level changes.
	local Q = {
		current   = nil,       -- the active SEA1_QUESTS row
		kills     = 0,         -- kills of the quest mob this cycle
		accepted  = false,     -- whether we've fired StartQuest this cycle
		lastLevel = 0,         -- Data.Level on last tick
		key       = nil,       -- "questId|tier" composite key
	}

	-- Accept a quest via CommF_:StartQuest and reset the kill counter.
	local function acceptQuest(q)
		if not q then return end
		local key = q.questId .. "|" .. tostring(q.tier)
		if Q.key == key and Q.accepted then return end  -- already accepted

		safe(function() R.CommF_:InvokeServer("StartQuest", q.questId, q.tier) end)
		Q.current  = q
		Q.kills    = 0
		Q.accepted = true
		Q.key      = key
		Toast.show({
			title = "Quest accepted",
			body  = q.mob .. " x" .. q.taskCount .. " (Lv " .. q.lvlMin .. "-" .. q.lvlMax .. ")",
			kind  = "info", duration = 4,
			key   = "q:" .. key,
		})
	end

	-- Drive farm filters to match the quest target.
	local function applyQuestFilters(q)
		cfg.farmTargetName = q.mob
		cfg.farmLevelMin   = q.lvlMin
		cfg.farmLevelMax   = q.lvlMax + 5
	end

	-- Callback invoked from autoFarmLoop on each death. If the kill matches
	-- the quest mob, increment the counter.
	local function recordQuestKill(enemyName)
		if not Q.current then return end
		if enemyName == Q.current.mob then
			Q.kills = Q.kills + 1
		end
	end

	-- Returns true if the quest kill target has been met.
	local function questIsComplete()
		return Q.current and Q.kills >= Q.current.taskCount
	end

	-- ═══════════════════════════ ISLAND ESP ═══════════════════════════
	-- One billboard per island, group "islands". Re-anchored to a small
	-- invisible BasePart at the island's pos so the BillboardGui has
	-- something concrete to attach to (BillboardGui.Adornee needs a part).
	local espAnchors = {}  -- name → Part
	local function buildIslandESP()
		ESP.detachGroup("islands")
		for _, c in pairs(espAnchors) do if c.Parent then c:Destroy() end end
		espAnchors = {}
		if not cfg.espIslands then return end

		for _, island in ipairs(ISLANDS) do
			local anchor = Instance.new("Part")
			anchor.Name = "Vellum_IslandAnchor_" .. island.name
			anchor.Size = Vector3.new(1, 1, 1)
			anchor.Anchored = true
			anchor.CanCollide = false
			anchor.Transparency = 1
			anchor.Position = island.pos + Vector3.new(0, 60, 0)
			anchor.Parent = workspace
			espAnchors[island.name] = anchor
			ESP.billboard({
				adornee = anchor,
				text    = island.name,
				sub     = island.lvlRange,
				color   = Color3.fromRGB(220, 200, 140),
				group   = "islands",
				yOffset = 0,
			})
		end
	end

	-- ═══════════════════════════ LOOPS ═══════════════════════════

	-- One always-on flight connection while auto-farm is enabled. Picks
	-- the best target each frame, hovers above it, and when no target
	-- is in range, holds the last altitude (so we don't fall between kills).
	--
	-- Aggressive mode: instead of letting the server reject the hit on
	-- distance, we write the target's HRP to (player.X, target_original_Y,
	-- player.Z) — XZ tracks us, Y stays at ground. This breaks the
	-- "we hover above target, target snaps under us, hover Y rises forever"
	-- feedback loop the previous attempt had.
	local flightConn
	local currentTarget        -- shared with the attack loop
	local lastHoldY            -- Y to hold when no enemy in range
	local targetOriginalY      -- the Y the current target spawned at
	local hoverEnabled = false -- only run flight while auto-farm is on
	local _hoverBP             -- BodyPosition that holds us in the air
	local _hoverBG             -- BodyGyro to keep us upright
	-- _bringBPs declared above before _stopFlightFn

	local function startFlight()
		if _tpInProgress then return end  -- don't start during teleport

		-- Clean sweep: destroy any orphan Vellum_ BPs on HRP that
		-- _stopFlightFn() may have left parented (some executors block
		-- Destroy/Parent=nil). Duplicate BodyPositions fight each other
		-- for HRP control — hover drifts or locks up.
		local ch = LocalPlayer.Character
		local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
		if not hrp then return end
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

		-- Create/recreate BodyPosition if missing (destroyed by _stopFlightFn).
		if not _hoverBP or not _hoverBP.Parent then
			_hoverBP = Instance.new("BodyPosition")
			_hoverBP.Name = "Vellum_HoverBP"
			_hoverBP.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
			_hoverBP.P = 600    -- 5000 was applying insane force (5000N/stud) that
			_hoverBP.D = 80     -- the physics engine had to resolve against every
			                    -- enemy collision body — dropping 60→12 fps.
			_hoverBP.Position = hrp.Position
			_hoverBP.Parent = hrp
		end

		-- Create/recreate BodyGyro if missing.
		if not _hoverBG or not _hoverBG.Parent then
			_hoverBG = Instance.new("BodyGyro")
			_hoverBG.Name = "Vellum_HoverBG"
			_hoverBG.MaxTorque = Vector3.new(math.huge, math.huge, math.huge)
			_hoverBG.P = 1000
			_hoverBG.D = 300
			_hoverBG.CFrame = hrp.CFrame
			_hoverBG.Parent = hrp
		end

		-- Connect Heartbeat ONCE per session. Never disconnected/reconnected
		-- (see _stopFlightFn — it only cleans BPs, not the signal).
		if not flightConn then
			flightConn = RunService.Heartbeat:Connect(function()
				if not (hoverEnabled and cfg.autoFarm) then return end
				if _tpInProgress then return end

				local ch2 = LocalPlayer.Character
				local hrp2 = ch2 and ch2:FindFirstChild("HumanoidRootPart")
				if not hrp2 then return end
				if not _hoverBP or not _hoverBP.Parent then return end
				if not _hoverBG or not _hoverBG.Parent then return end

				-- Maintain noclip: Roblox re-enables CanCollide every physics step
				hrp2.CanCollide = false

				local enemy = (currentTarget and currentTarget.Parent) and currentTarget or nil

				if enemy then
					local ehrp = enemy:FindFirstChild("HumanoidRootPart")
					if ehrp then
						if not targetOriginalY then
							targetOriginalY = ehrp.Position.Y
						end
						local hoverY = targetOriginalY + cfg.farmHeight
						lastHoldY = hoverY
						_hoverBP.Position = Vector3.new(ehrp.Position.X, hoverY, ehrp.Position.Z)

						-- Aggressive range uses enemy CFrame — still technically
						-- detectable by BF. Left as user opt-in.
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
		hoverEnabled = true

		-- Noclip: disable collision on HRP and all body parts so we pass
		-- through buildings/walls when farming near structures.
		for _, p in ipairs(ch:GetDescendants()) do
			if p:IsA("BasePart") then
				p.CanCollide = false
			end
		end
	end

	local _islandGraceUntil = 0  -- tick() timestamp: skip atIsland TP until this expires
	local _islandGraceName  = "" -- which island the grace is for

	local function autoFarmLevelLoop()
		while _running do
			if _tpInProgress then jwait(1.0) continue end
			if not cfg.autoFarmLevel then
				jwait(1.0)
				continue
			end

			cfg.autoFarm = true

			local data = LocalPlayer:FindFirstChild("Data")
			local levelVal = data and data:FindFirstChild("Level")
			if not levelVal then jwait(3.0); continue end
			local level = levelVal.Value

			if level ~= Q.lastLevel then
				Q.lastLevel = level
				Q.accepted = false
				Q.kills = 0
				Q.current = nil
				Q.key = nil
				_islandGraceUntil = 0
				currentTarget = nil
				targetOriginalY = nil
			end

			local quest = pickQuest(level)
			if not quest then
				-- Level past the quest atlas. Auto-farm still runs (simple kill mode).
				if Q.current then
					Toast.show({
						title = "Sea 1 quests exhausted",
						body  = "Level " .. level .. " — continuing in simple kill mode.",
						kind  = "info", duration = 6,
						key   = "q:exhausted",
					})
					Q.current = nil
					Q.accepted = false
					Q.key = nil
				end
				jwait(5.0)
				continue
			end

			-- Quest complete: advance to next row (pickQuest will return the next
			-- row for the same level range, or the next tier).
			if questIsComplete() then
				Toast.show({
					title = "Quest complete",
					body  = quest.mob .. " done — moving to next tier.",
					kind  = "info", duration = 3,
					key   = "q:done",
				})
				Q.accepted = false
				Q.kills = 0
				Q.current = nil
				Q.key = nil
				_islandGraceUntil = 0
				currentTarget = nil
				targetOriginalY = nil
				jwait(0.5)
				continue
			end

			-- TP to the quest's island if we aren't there yet.
			-- Grace period: after arriving, skip the TP check for 60s so chasing
			-- enemies beyond the atIsland radius doesn't loop us back.
			local needsTP = not atIsland(quest.island)
				and not (_islandGraceName == quest.island and tick() < _islandGraceUntil)
			if needsTP then
				tpToIsland(quest.island)
				_islandGraceUntil = tick() + 60
				_islandGraceName = quest.island
				task.wait(0.8)
				Q.accepted = false
				continue
			end

			-- Arrived — start grace on first pass
			if _islandGraceName ~= quest.island or tick() >= _islandGraceUntil then
				_islandGraceUntil = tick() + 60
				_islandGraceName = quest.island
			end

			-- Accept quest if not yet accepted this cycle
			if not Q.accepted or Q.key ~= quest.questId .. "|" .. tostring(quest.tier) then
				acceptQuest(quest)
			end

			applyQuestFilters(quest)
			jwait(3.0)
		end
	end

	-- BF uses ToolTip property to classify weapon types: Melee, Sword, Gun, Blox Fruit.
	-- The hotbar (1/2/3/4) maps to these types. cfg.selectedWeapon stores the ToolTip
	-- value the user wants, and we find the first backpack tool with that ToolTip.
	local function ensureWeaponEquipped()
		local ch = LocalPlayer.Character
		if not ch then return nil end
		local hum = ch:FindFirstChildOfClass("Humanoid")
		local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
		if not hum then return nil end

		-- Check what's already in-hand
		local held = ch:FindFirstChildOfClass("Tool")
		if held then
			-- Already holding something — only re-equip if it doesn't match the selected style
			if cfg.selectedWeapon == "" or held.ToolTip == cfg.selectedWeapon then
				return held
			end
		end

		if not backpack then return nil end

		-- Try to equip a tool matching the selected style (by ToolTip)
		if cfg.selectedWeapon ~= "" then
			for _, tool in ipairs(backpack:GetChildren()) do
				if tool:IsA("Tool") and tool.ToolTip == cfg.selectedWeapon then
					safe(function() hum:EquipTool(tool) end)
					task.wait(0.15)
					return ch:FindFirstChildOfClass("Tool")
				end
			end
		end

		-- Fallback: try weapon types in priority order, then first tool
		local STYLE_PRIORITY = { "Melee", "Sword", "Gun", "Blox Fruit" }
		for _, style in ipairs(STYLE_PRIORITY) do
			for _, child in ipairs(backpack:GetChildren()) do
				if child:IsA("Tool") and child.ToolTip == style then
					safe(function() hum:EquipTool(child) end)
					task.wait(0.15)
					local equipped = ch:FindFirstChildOfClass("Tool")
					if equipped then return equipped end
					break
				end
			end
		end
		-- Absolute fallback: any tool
		local tool = backpack:FindFirstChildOfClass("Tool")
		if not tool then return nil end
		safe(function() hum:EquipTool(tool) end)
		task.wait(0.15)
		return ch:FindFirstChildOfClass("Tool")
	end

	-- Legacy alias used by autoFarmLoop
	local ensureToolEquipped = ensureWeaponEquipped

	-- Return available weapon STYLES (unique ToolTip values) from the backpack.
	-- e.g. {"Melee", "Sword", "Gun", "Blox Fruit"} depending on what the player owns.
	-- The "Blox Fruit" type maps to whatever fruit the player has equipped.
	local STYLE_ORDER = { Melee = 1, Sword = 2, Gun = 3, ["Blox Fruit"] = 4 }

	local function getWeaponOptions()
		local seen = {}
		-- Scan both backpack and character (equipped tool lives on character)
		local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
		if backpack then
			for _, child in ipairs(backpack:GetChildren()) do
				if child:IsA("Tool") and child.ToolTip and child.ToolTip ~= "" then
					seen[child.ToolTip] = true
				end
			end
		end
		local ch = LocalPlayer.Character
		if ch then
			for _, child in ipairs(ch:GetChildren()) do
				if child:IsA("Tool") and child.ToolTip and child.ToolTip ~= "" then
					seen[child.ToolTip] = true
				end
			end
		end
		local styles = {}
		for tip in pairs(seen) do table.insert(styles, tip) end
		table.sort(styles, function(a, b)
			local oa = STYLE_ORDER[a] or 99
			local ob = STYLE_ORDER[b] or 99
			if oa ~= ob then return oa < ob end
			return a < b
		end)
		return styles
	end

	-- ═══════════════════════════ ABILITY ROTATION ═══════════════════════════
	-- BF's ability protocol (from FruitClient decompiled source):
	--   1. tool.RemoteEvent:FireServer(true)      — signals "activation start"
	--   2. Write tool.MousePos.Value = targetPos   — target for position-based skills
	--   3. tool.RemoteEvent:FireServer(targetPos)  — sends Vector3 target
	-- OR for CFrame abilities:
	--   3. tool.RemoteEvent:FireServer(CFrame)     — sends Mouse.Hit CFrame
	-- The Holding BoolValue on the tool flags sustained activation.
	-- RemoteFunction on the tool is for M1 combat, NOT abilities.
	local SLOT_NAMES = { "Z", "X", "C", "V", "F" }

	local function abilityRotationTick()
		if not cfg.autoFarm then return end
		local ch = LocalPlayer.Character
		local tool = ch and ch:FindFirstChildOfClass("Tool")
		if not tool then return end

		local re = tool:FindFirstChild("RemoteEvent")
		if not re or not re:IsA("RemoteEvent") then return end
		if re.Name == "EquipEvent" then
			for _, c in ipairs(tool:GetChildren()) do
				if c:IsA("RemoteEvent") and c.Name ~= "EquipEvent" and c.Name ~= "LegacyRemoteEvent" then
					re = c
					break
				end
			end
		end

		local legacyRe = tool:FindFirstChild("LegacyRemoteEvent")
		local targetRe = legacyRe and legacyRe:IsA("RemoteEvent") and legacyRe or re

		local mousePosVal = tool:FindFirstChild("MousePos")
		local holdingVal = tool:FindFirstChild("Holding")

		local targetPos
		local enemy = currentTarget
		if enemy and enemy.Parent then
			local ehrp = enemy:FindFirstChild("HumanoidRootPart")
			targetPos = ehrp and ehrp.Position
		end
		if not targetPos then
			local hrp = ch:FindFirstChild("HumanoidRootPart")
			targetPos = hrp and (hrp.Position + (hrp.CFrame.LookVector * 50))
		end
		if not targetPos then return end

		local canFire = {}
		local pg = LocalPlayer:FindFirstChild("PlayerGui")
		local mainGui = pg and pg:FindFirstChild("Main")
		local skillsGui = mainGui and mainGui:FindFirstChild("Skills")
		local combatFrame = skillsGui and skillsGui:FindFirstChild("Combat")
		if combatFrame then
			for _, slot in ipairs(SLOT_NAMES) do
				if cfg.abilitySlots[slot] then
					local slotFrame = combatFrame:FindFirstChild(slot)
					if slotFrame then
						local cdFrame = slotFrame:FindFirstChild("Cooldown")
						if not cdFrame or not cdFrame.Visible then
							table.insert(canFire, slot)
						end
					else
						table.insert(canFire, slot)
					end
				end
			end
		else
			for _, slot in ipairs(SLOT_NAMES) do
				if cfg.abilitySlots[slot] then
					table.insert(canFire, slot)
				end
			end
		end

		for _, slot in ipairs(canFire) do
			safe(function()
				if mousePosVal and mousePosVal:IsA("Vector3Value") then
					mousePosVal.Value = targetPos
				end
				targetRe:FireServer(true)
				targetRe:FireServer(targetPos)
				if holdingVal and holdingVal:IsA("BoolValue") then
					holdingVal.Value = true
					task.delay(0.15, function() holdingVal.Value = false end)
				end
			end)
			task.wait(0.05)
		end
	end

	local function abilityRotationLoop()
		while _running do
			local anyOn = false
			for _, slot in ipairs(SLOT_NAMES) do
				if cfg.abilitySlots[slot] then anyOn = true; break end
			end
			if anyOn then
				safe(abilityRotationTick)
				jwait(cfg.abilityCadence)
			else
				jwait(1.0)
			end
		end
	end

	-- Diagnostics: toggle via executor:  getgenv().VellumBF.diag = true
	-- Prints loop state transitions to the Roblox developer console (F9).
	local DIAG = { lastState = "", lastTick = 0 }
	local function dbg(state, extra)
		local g = getgenv().VellumBF
		if not (g and g.diag) then return end
		local now = os.clock()
		if state ~= DIAG.lastState then
			print(string.format("[BF-diag] %.2f (+%.2f) %s %s", now, now - DIAG.lastTick, state, extra or ""))
			DIAG.lastState = state
			DIAG.lastTick = now
		end
	end

	-- ═══════════════════════════ MOB BRING ═══════════════════════════
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
					-- Pull toward player XZ — preserve enemy Y so we don't lift them
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

	local function autoFarmLoop()
		while _running do
			if _tpInProgress then jwait(1.0) continue end
			if not cfg.autoFarm then
				safe(_stopFlightFn)
				jwait(0.5)
				continue
			end

			if not flightConn or not _hoverBP or not _hoverBP.Parent then safe(startFlight) end
			safe(ensureToolEquipped)

			safe(function()
				local enemy = currentTarget
				if not enemy or not enemy.Parent then
					-- Actively pick the next target and tween to it.
					-- Without this, we'd jwait 0.3s doing nothing and rely on
					-- BodyPosition physics to slowly drag us — which BF's
					-- anticheat often removes, locking us in place.
					local newEnemy = pickEnemy()
					dbg("pick", newEnemy and newEnemy.Name or "none")
					if newEnemy then
						currentTarget = newEnemy
						local ch = LocalPlayer.Character
						local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
						local ehrp = newEnemy:FindFirstChild("HumanoidRootPart")
						if hrp and ehrp then
							local dist = (ehrp.Position - hrp.Position).Magnitude
							-- Only CFrame-tween for long distances (>100 studs).
							-- Normal combat transitions use BP physics movement
							-- (accelerates at ~12 m/s² with P=600). Writing HRP.CFrame
							-- through a dense field of 500+ enemy collision bodies
							-- forces the physics engine to rebuild spatial state
							-- every frame of the tween — massive fps drops.
							if dist > 100 then
								dbg("tween-start", newEnemy.Name .. " dist=" .. math.floor(dist))
								targetOriginalY = ehrp.Position.Y
								local hoverY = targetOriginalY + cfg.farmHeight
								local dest = Vector3.new(ehrp.Position.X, hoverY, ehrp.Position.Z)
								if _hoverBP and _hoverBP.Parent then
									_hoverBP.P, _hoverBP.D = 0, 0
									if _hoverBG and _hoverBG.Parent then
										_hoverBG.P = 0
									end
									_tweenHRPTo(hrp, dest)
									dbg("tween-done", newEnemy.Name)
									if _hoverBP and _hoverBP.Parent then
										_hoverBP.P, _hoverBP.D = 600, 80
										_hoverBP.Position = dest
									end
									if _hoverBG and _hoverBG.Parent then
										_hoverBG.P = 1000
									end
								else
									_tweenHRPTo(hrp, dest)
									dbg("tween-done", newEnemy.Name)
								end
							else
								-- Under 100 studs: BP physics movement only.
								dbg("bp-move", newEnemy.Name .. " dist=" .. math.floor(dist))
								local hoverY = (targetOriginalY or ehrp.Position.Y) + cfg.farmHeight
								if _hoverBP and _hoverBP.Parent then
									_hoverBP.Position = Vector3.new(ehrp.Position.X, hoverY, ehrp.Position.Z)
								end
							end
						end
						-- New target acquired — return immediately. Next loop
						-- iteration sees currentTarget is set and attacks.
						return
					end
					-- No enemies alive anywhere on the map. Throttle scan:
					-- waves respawn on a 5-10s timer, scanning faster just
					-- allocates wasted GetChildren tables.
					jwait(1.5)
					return
				end

				-- Standard RegisterAttack+RegisterHit protocol with self-generated hash.
				ensureHash()  -- generates + registers if not yet set
				local t0 = os.clock()
				local landed = attackOnce(enemy)
				local elapsed = os.clock() - t0
				if elapsed > 0.01 then
					dbg("attack-slow", enemy.Name .. " took=" .. string.format("%.4f", elapsed))
				end

				-- Clear currentTarget as SOON as the enemy dies (Health <= 0),
				-- not when BF removes the corpse from workspace.Enemies
				-- (which takes 1-3s). Without this we waste ticks attacking a
				-- dead enemy while pickEnemy() already switched to the next.
				local hum = enemy and enemy:FindFirstChild("Humanoid")
				if (enemy and not enemy.Parent) or (hum and hum.Health <= 0) then
					stats.sessionKills = stats.sessionKills + 1
					dbg("kill", enemy.Name)
					recordQuestKill(enemy.Name)
					currentTarget = nil
					targetOriginalY = nil
				end
			end)

			safe(_bringMobs)

			-- ±20% jitter so fixed-period swings stop being a fingerprint.
			jwait(cfg.attackCadence * (0.8 + math.random() * 0.4))
		end
	end

	local function autoStatsLoop()
		while _running do
			if cfg.autoStats then
				safe(function()
					local p = LocalPlayer.Data:FindFirstChild("Points")
					if p and p.Value > 0 then
						R.CommF_:InvokeServer("AddPoint", cfg.statPriority, cfg.statBatchSize)
						jwait(0.4)
					else
						jwait(2.0)
					end
				end)
			else
				jwait(1.5)
			end
		end
	end

	local function antiAfkLoop()
		LocalPlayer.Idled:Connect(function()
			if not cfg.antiAfk then return end
			VirtualUser:CaptureController()
			VirtualUser:ClickButton2(Vector2.new())
		end)
	end

	-- track XP / Beli gain for the stats panel. LocalPlayer.Data is populated
	-- by BF's server script after character spawn, so we WaitForChild before
	-- touching it. nil-safe inner reads for the (rare) case of mid-session
	-- data wipe on respawn.
	local function trackProgressLoop()
		local data = LocalPlayer:WaitForChild("Data", 30)
		if not data then return end
		local expVal = data:WaitForChild("Exp", 10)
		local beliVal = data:WaitForChild("Beli", 10)
		if not (expVal and beliVal) then return end

		local lastXP, lastBeli = expVal.Value, beliVal.Value
		while _running do
			task.wait(1)
			local xp = expVal.Value
			local beli = beliVal.Value
			if xp > lastXP then
				stats.sessionXP = stats.sessionXP + (xp - lastXP)
			end
			if beli > lastBeli then
				stats.sessionBeli = stats.sessionBeli + (beli - lastBeli)
			end
			lastXP, lastBeli = xp, beli
		end
	end

	-- ═══════════════════════════ UI ═══════════════════════════
	local ui = UI.mount({
		title    = "V E L L U M",
		subtitle = "blox fruits",
		size     = UDim2.fromOffset(560, 400),
		position = UDim2.fromOffset(80, 100),
		onClose  = function() _running = false end,
	})
	gui = ui.gui  -- now assignable, captured as upvalue by the loops above

	Toast.init({ theme = Theme, enabled = function() return cfg.notifyInGame end })

	-- ─── FARM LEVEL TAB ───
	local farm = ui.newPage("farm")
	ui.sectionLabel(farm, "AUTO FARM LEVEL")
	ui.toggleRow(farm, "Auto Farm Level (quest + kill cycle)",
		function() return cfg.autoFarmLevel end,
		function(v)
			cfg.autoFarmLevel = v
			if v then
				cfg.autoFarm = true
				-- Full restart: tear down any stale flight state first
				safe(_stopFlightFn)
				safe(ensureWeaponEquipped)
				safe(startFlight)
				if not getHash() then
					ensureHash()
					Toast.show({
						title = "Hash auto-generated",
						body  = "Quest lifecycle loop engaged.",
						kind  = "success", duration = 4,
					})
				end
			else
				cfg.autoFarm = false
				safe(_stopFlightFn)
			end
		end)
	ui.toggleRow(farm, "Simple Kill Mode (no quests)",
		function() return cfg.autoFarm and not cfg.autoFarmLevel end,
		function(v)
			if v then
				cfg.autoFarm = true
				cfg.autoFarmLevel = false
				safe(ensureWeaponEquipped)
				safe(startFlight)
				if not getHash() then
					ensureHash()
					Toast.show({
						title = "Hash auto-generated",
						body  = "Simple kill mode — hash registered.",
						kind  = "success", duration = 4,
					})
				end
			else
				cfg.autoFarm = false
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

	ui.sectionLabel(farm, "WEAPON STYLE")
	local weaponStyles = getWeaponOptions()
	table.insert(weaponStyles, 1, "Auto")
	ui.dropdownRow(farm, "Style priority",
		weaponStyles,
		function() return cfg.selectedWeapon ~= "" and cfg.selectedWeapon or "Auto" end,
		function(name)
			cfg.selectedWeapon = (name == "Auto") and "" or name
		end)

	ui.sectionLabel(farm, "ABILITIES")
	ui.toggleRow(farm, "Z",
		function() return cfg.abilitySlots.Z end,
		function(v) cfg.abilitySlots.Z = v end)
	ui.toggleRow(farm, "X",
		function() return cfg.abilitySlots.X end,
		function(v) cfg.abilitySlots.X = v end)
	ui.toggleRow(farm, "C",
		function() return cfg.abilitySlots.C end,
		function(v) cfg.abilitySlots.C = v end)
	ui.toggleRow(farm, "V",
		function() return cfg.abilitySlots.V end,
		function(v) cfg.abilitySlots.V = v end)
	ui.toggleRow(farm, "F",
		function() return cfg.abilitySlots.F end,
		function(v) cfg.abilitySlots.F = v end)
	ui.intervalRow(farm, "Ability cadence (sec)",
		function() return cfg.abilityCadence end,
		function(v) cfg.abilityCadence = v end,
		{ 1.0, 1.5, 2.0, 3.0, 5.0 })

	ui.sectionLabel(farm, "TARGET FILTER")
	ui.intervalRow(farm, "Min enemy level",
		function() return cfg.farmLevelMin end,
		function(v) cfg.farmLevelMin = v end,
		{ 0, 5, 10, 25, 50, 100 })
	ui.intervalRow(farm, "Max enemy level",
		function() return cfg.farmLevelMax end,
		function(v) cfg.farmLevelMax = v end,
		{ 25, 50, 100, 250, 500, 9999 })

	-- ─── SEA 1 TAB ───
	-- Kept for island ESP + manual TP. The old auto-progression toggle
	-- is superseded by Auto Farm Level on the Farm tab.
	local sea1 = ui.newPage("sea1")

	ui.sectionLabel(sea1, "ISLAND ESP")
	ui.toggleRow(sea1, "Show island markers",
		function() return cfg.espIslands end,
		function(v) cfg.espIslands = v; buildIslandESP() end)

	ui.sectionLabel(sea1, "MANUAL TP")
	local islandOptions = {}
	for _, island in ipairs(ISLANDS) do table.insert(islandOptions, island.name) end

	local lastTpDestination = "—"
	ui.dropdownRow(sea1, "Teleport to",
		islandOptions,
		function() return lastTpDestination end,
		function(name)
			lastTpDestination = name
			local wasAuto = cfg.autoFarmLevel
			if wasAuto then
				cfg.autoFarmLevel = false
				Q.accepted = false; Q.current = nil; Q.key = nil
			end
			local ok = tpToIsland(name)
			local island = ISLAND_BY_NAME[name]
			Toast.show({
				title = ok and "Teleported" or "TP failed",
				body  = name .. (island and ("  •  " .. island.lvlRange) or "") ..
				        (wasAuto and "  (Auto Farm Level paused)" or ""),
				kind  = ok and "success" or "warn", duration = 4,
				key   = "tp:" .. name,
			})
		end)

	-- ─── STATS TAB ───
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
	sessionLbl.BackgroundTransparency = 1
	sessionLbl.Font = Enum.Font.RobotoMono; sessionLbl.TextSize = 11
	Theme.bind(sessionLbl, "TextColor3", "text")
	sessionLbl.TextXAlignment = Enum.TextXAlignment.Left
	sessionLbl.TextYAlignment = Enum.TextYAlignment.Top
	sessionLbl.Text = "—"

	task.spawn(function()
		while _running do
			local elapsed = os.clock() - stats.sessionStart
			sessionLbl.Text = string.format(
				"  Kills:  %d\n" ..
				"  XP:     %s   (%s/hr)\n" ..
				"  Beli:   %s   (%s/hr)\n" ..
				"  Uptime: %s\n" ..
				"  Hash:   %s",
				stats.sessionKills,
				Helpers.fmt(stats.sessionXP), Helpers.perHour(stats.sessionXP, elapsed),
				Helpers.fmt(stats.sessionBeli), Helpers.perHour(stats.sessionBeli, elapsed),
				Helpers.fmtDur(elapsed),
				getHash() or "(auto-generated on first tick)"
			)
			task.wait(1)
		end
	end)

	-- ─── SETTINGS TAB ───
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
		Toast.show({
			title = "Hash reset",
			body  = "Will regenerate next tick on the current thread.",
			kind  = "info", duration = 4,
		})
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

	local function makeFloatingIcon()
		local icon = Instance.new("TextButton", ui.gui)
		icon.Size = UDim2.fromOffset(50, 50); icon.Position = UDim2.fromOffset(20, 100)
		Theme.bind(icon, "BackgroundColor3", "panel"); icon.AutoButtonColor = false
		icon.Text = "V"; icon.Font = Enum.Font.Antique; icon.TextSize = 22
		Theme.bind(icon, "TextColor3", "accent"); icon.Active = true; icon.Draggable = true
		Instance.new("UICorner", icon).CornerRadius = UDim.new(1, 0)
		local s = Instance.new("UIStroke", icon)
		Theme.bind(s, "Color", "accent"); s.Thickness = 1.4; s.Transparency = 0.35

		task.spawn(function()
			while icon.Parent do
				local fade = TweenService:Create(s,
					TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
					{ Transparency = 0.75, Thickness = 2.4 })
				fade:Play()
				while icon.Parent do task.wait(0.2) end
				fade:Cancel()
				s.Transparency = 0.35; s.Thickness = 1.4
			end
		end)

		icon.MouseButton1Click:Connect(function()
			ui.root.Visible = true
			icon:Destroy()
		end)
		return icon
	end

	ui.minBtn.MouseButton1Click:Connect(function()
		ui.root.Visible = false
		makeFloatingIcon()
	end)

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or not cfg.keybindToggle then return end
		if input.KeyCode == Enum.KeyCode.RightShift then
			if ui.root.Visible then
				ui.root.Visible = false
				if not ui.gui:FindFirstChildOfClass("TextButton") then makeFloatingIcon() end
			else
				ui.root.Visible = true
				for _, c in ipairs(ui.gui:GetChildren()) do
					if c:IsA("TextButton") then c:Destroy() end
				end
			end
		end
	end)

	-- Build island ESP if enabled at boot
	buildIslandESP()

	-- ═══════════════════════════ KICK OFF ═══════════════════════════
	task.spawn(autoFarmLoop)
	task.spawn(autoFarmLevelLoop)
	task.spawn(abilityRotationLoop)
	task.spawn(autoStatsLoop)
	task.spawn(trackProgressLoop)
	antiAfkLoop()

	Toast.show({
		title = "Vellum loaded",
		body  = "Auto Farm Level, weapons, and ability rotation ready.",
		kind  = "info", duration = 6,
	})

	print("[Vellum BF] module loaded.")
end

return Module

]========])

UI.init({ theme = Theme })
ESP.init({ theme = Theme })
local ok, err = xpcall(Game.start, debug.traceback, lib)
_G.VELLUM_OK = ok
_G.VELLUM_ERR = tostring(err)
if not ok then
	warn("[Vellum BUNDLE ERROR]", tostring(err))
	print("[Vellum BUNDLE ERROR]", tostring(err))
end