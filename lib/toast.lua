-- Vellum — corner toast queue
-- Stacked notifications with kind-specific colored stripes, slide-in animation,
-- 12s dedupe window per key, and auto-dismiss.

-- TODO(skeleton):
-- 1. Move from spin_soccer_full.lua:
--    - getToastHost() with CoreGui / gethui / PlayerGui fallback
--    - TOAST_COLORS table (info/success/rare/epic/hop/trade/warn)
--    - toast({title, body, kind, key, duration}) main entry
-- 2. Accept theme reference so toast surfaces follow the active theme
-- 3. Expose: Toast.show(opts), Toast.dismiss_all()

return {
	show = function(_opts) end,
	dismiss_all = function() end,
}
