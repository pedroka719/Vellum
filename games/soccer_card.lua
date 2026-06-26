-- Vellum — game module: Spin a Soccer Card
-- PlaceId 112490729816320
--
-- Returns the module-protocol table the loader expects:
--   { name, placeIds, start(lib) }

-- TODO(skeleton):
-- 1. Migrate game-specific logic from spin_soccer_full.lua:
--    - require Networker, PlayerStore, CardConfig, RebirthConfig, PackConfig,
--      TournamentConfig, TournamentClock
--    - R table (game-specific remotes)
--    - cfg defaults + game-specific stats
--    - RARITY_WEIGHT, pity logic, packEV, enabledPacksByPriority
--    - all auto-loops (collect, buy, open, sell, rebirth, claims, equip, ...)
--    - canRebirth, ensureTournamentTeam5, pickTradeable, hopNow, trade handler
--    - tab UIs (Farm/Sell/Rebirth/Claims/Codes/Stats/Settings) built via lib.ui
--    - persistence (configs + autoload), webhook reporter
-- 2. Keep ONLY soccer-specific code here. Anything generic should call into lib/.

return {
	name = "Spin a Soccer Card",
	placeIds = { 112490729816320 },
	start = function(_lib)
		error("Vellum soccer_card module is empty — migration pending.")
	end,
}
