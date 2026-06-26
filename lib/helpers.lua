-- Vellum — generic helpers shared across game modules
-- Anything that's not specific to a single game lives here.

-- TODO(skeleton):
-- 1. Move from spin_soccer_full.lua:
--    - fmt(n)            human-format big numbers ($1.23M, $4.56B)
--    - parseCash(text)   reverse of fmt for parsing labels
--    - jwait(t)          jittered task.wait (anti-pattern + conservative mode)
--    - safe(fn, ...)     pcall-wrap with [Vellum] warn on error
--    - fmtDur(secs)      "1h 23m 45s" duration formatter
--    - perHour(n, elap)  rate-per-hour formatter
-- 2. Optional: extract getGuiHost (CoreGui fallback) — used by both UI and Toast

return {
	fmt = function(_n) return "" end,
	parseCash = function(_t) return 0 end,
	jwait = function(_t) end,
	safe = function(_f, ...) end,
	fmtDur = function(_s) return "" end,
	perHour = function(_n, _e) return "" end,
}
