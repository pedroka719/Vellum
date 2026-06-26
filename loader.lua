-- Vellum — loader
-- Detects the current PlaceId and dispatches to the matching game module.
-- Single entrypoint: users only ever run this URL.

-- TODO(skeleton):
-- 1. require lib/{theme, ui, toast, helpers} once and bundle into `lib` table
-- 2. require each games/<module>.lua, collect into a registry keyed by PlaceId
-- 3. match game.PlaceId → dispatch start(lib)
-- 4. version check → toast "update available" if behind latest tag
-- 5. on no match: toast "Vellum doesn't support this game yet" and exit

return function()
	error("Vellum loader is empty — populate lib/ and games/ first.")
end
