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
