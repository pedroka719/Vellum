-- Vellum — loader (entrypoint)
--
-- The single URL users run via loadstring. Fetches lib/ modules + the
-- game module that matches the current PlaceId, wires dependencies,
-- and starts the game.
--
--   loadstring(game:HttpGet("<this file>"))()
--
-- DISTRIBUTION
--   While the repo is private, `game:HttpGet` cannot reach raw.github
--   (no auth headers). Three viable paths:
--
--   1. Mirror this file + every dep to a public gist. Set BASE to the
--      gist raw URL. Easy but manual sync.
--   2. Flip the repo public when launching. BASE stays as-is.
--   3. Build a tiny CF Worker proxy that auths to GitHub on your behalf.
--      Set BASE to the worker URL. Best for paid distribution.
--
--   For dev, swap BASE to a local override or use a single bundled file
--   (see TODO at bottom — bundler script not yet written).

local BASE = "https://raw.githubusercontent.com/Pekenz/vellum/main"

-- ─────────────── module fetching ───────────────
-- Each lib module returns a table. We HttpGet the source, loadstring it,
-- and call the resulting function. Cache so re-fetches are cheap.

local _moduleCache = {}

local function fetchModule(path)
	if _moduleCache[path] then return _moduleCache[path] end
	local url = BASE .. path
	local ok, body = pcall(function() return game:HttpGet(url) end)
	if not ok then
		error("Vellum loader: HttpGet failed for " .. url .. " — " .. tostring(body), 0)
	end
	local fn, parseErr = loadstring(body, path)
	if not fn then
		error("Vellum loader: parse error in " .. path .. " — " .. tostring(parseErr), 0)
	end
	local mod = fn()
	_moduleCache[path] = mod
	return mod
end

-- ─────────────── boot ───────────────

local function boot()
	-- lib: order matters for the deps that need init
	local Theme   = fetchModule("/lib/theme.lua")
	local Helpers = fetchModule("/lib/helpers.lua")
	local Toast   = fetchModule("/lib/toast.lua")
	local UI      = fetchModule("/lib/ui.lua")

	-- Toast + UI both need Theme injected. Notification predicate is
	-- left as default-on; game modules override via Toast.init again
	-- once their cfg.notifyInGame is wired.
	Toast.init({ theme = Theme })
	UI.init({ theme = Theme })

	-- The bundle passed to every game.start(lib)
	local lib = {
		theme   = Theme,
		helpers = Helpers,
		toast   = Toast,
		ui      = UI,
	}

	-- Game registry. Edit this when adding a new game module.
	-- Keys are PlaceIds; values are module paths under the repo root.
	local GAMES = {
		[112490729816320] = "/games/soccer_card.lua",
	}

	local modulePath = GAMES[game.PlaceId]
	if not modulePath then
		Toast.show({
			title    = "Vellum",
			body     = "This game isn't supported yet (PlaceId " ..
			           tostring(game.PlaceId) .. ").",
			kind     = "warn",
			duration = 10,
		})
		warn("[Vellum] no module registered for PlaceId " .. tostring(game.PlaceId))
		return
	end

	local Game = fetchModule(modulePath)
	if type(Game) ~= "table" or type(Game.start) ~= "function" then
		error("Vellum loader: module at " .. modulePath ..
		      " did not return {name, placeIds, start = function}", 0)
	end

	-- Confirmation toast before we hand off — useful for debugging since
	-- the game module is free to take a while spinning up its own UI.
	Toast.show({
		title    = "Vellum",
		body     = "Loaded " .. (Game.name or "unknown game"),
		kind     = "success",
		duration = 4,
	})

	Game.start(lib)
end

-- Wrap boot so any module fetch / parse / runtime error gets surfaced
-- cleanly to the developer console instead of going through Roblox's
-- silent script-error path.
local ok, err = xpcall(boot, debug.traceback)
if not ok then
	warn("[Vellum BOOT ERROR]\n" .. tostring(err))
end

-- TODO: companion bundler
--   When ready for distribution we'll add a `tools/bundle.lua` that
--   concatenates loader + every lib + a single game module into one
--   self-contained file. That bundle gets pushed to a public gist (or
--   the public-flipped repo) and users loadstring it directly without
--   any fanout HttpGets.
