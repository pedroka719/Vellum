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
