-- Vellum — theme system
-- Semantic color tokens, preset palettes, and runtime theme swapping.
--
-- Usage:
--   local Theme = require("lib.theme")
--   Theme.apply("Vellum")        -- swap to a preset
--   frame.BackgroundColor3 = Theme.token("panel")
--   Theme.bind(frame, "BackgroundColor3", "panel")  -- auto-updates on swap

-- TODO(skeleton):
-- 1. Move THEMES dictionary here (Vellum, Midnight, Ink, Parchment, Matte)
-- 2. Move THEME live table + themed() registry from spin_soccer_full.lua
-- 3. Move applyTheme() with _call support
-- 4. Expose as a clean module API: Theme.apply / Theme.bind / Theme.token / Theme.presets

return {
	apply = function(_name) end,
	bind  = function(_inst, _prop, _role) end,
	token = function(_role) return nil end,
	presets = function() return {} end,
}
