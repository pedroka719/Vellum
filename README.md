# Vellum

Private Roblox script hub.

## Layout

```
loader.lua              entrypoint — detects game.PlaceId and runs the right module
lib/
  theme.lua             color tokens, preset themes, runtime swap
  ui.lua                widget factories: newTab, toggleRow, intervalRow, actionBtn, ...
  toast.lua             corner notification queue
  helpers.lua           fmt, jwait, safe, getMe, ownedCardPool, ...
games/
  soccer_card.lua       Spin a Soccer Card — first game module
```

## How loading will work

```lua
loadstring(game:HttpGet("<distribution URL>"))()
```

While the repo is private, `<distribution URL>` is a gist mirror that we keep
in sync manually. When the hub goes public for distribution, the URL becomes
either the raw GitHub path or a CF Worker proxy depending on whether we want
auth gating.

## Game modules

Each `games/<name>.lua` returns a table:

```lua
return {
  name = "Display Name",
  placeIds = { 112490729816320, ... },
  start = function(lib) ... end,  -- lib is the shared module bundle
}
```

The loader collects every module, matches `game.PlaceId` against `placeIds`,
and calls `start(lib)`. If no module matches, the loader toasts a polite
"not supported yet" message and exits.

## Versioning

Tags follow semver: `v0.1.0`, `v1.0.0`. The loader checks for the latest tag
at startup and shows an "update available" toast if the user is behind.
