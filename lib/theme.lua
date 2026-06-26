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
