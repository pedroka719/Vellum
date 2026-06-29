# VELLUM KNOWLEDGE BASE

## OVERVIEW
Lua/Luau automation framework for Roblox game clients, primarily targeting Blox Fruits.

## STRUCTURE
- `games/` — Game-specific logic (blox_fruits.lua, soccer_card.lua)
- `lib/` — Shared modules (ui.lua, esp.lua, theme.lua, toast.lua)
- `bundle_fixed.lua` — Monolithic build for direct execution
- `loader.lua` — Dynamic HttpGet-based module loader
- (No build script currently — bundle is hand-assembled)

## WHERE TO LOOK
| Task | Location |
|------|----------|
| Add game feature | `games/<game_name>.lua` |
| Modify UI/Theme | `lib/ui.lua` or `lib/theme.lua` |
| Fix ESP/Visuals | `lib/esp.lua` |
| Rebuild bundle | Assemble modules with embed() long-strings |

## CONVENTIONS
- **Lua 5.1/Luau**: Standard Roblox environment constraints.
- **Embedding**: Modules are wrapped in `[=[ ... ]=]` long-strings for bundling.
- **Theme Pattern**: Centralized `lib/theme.lua` for all UI colors and styles.
- **Global Registry**: Uses `getgenv()` for cross-script state persistence.
- **Task Scheduling**: Heavy use of `task.spawn` and `task.wait` over `spawn/wait`.
- **Signal Pattern**: Custom signal implementation for event-driven UI updates.

## ANTI-PATTERNS
- No `require(assetid)` — Use local `lib/` modules or the loader.
- No hardcoded colors — Reference `theme.lua`.
- No `wait()` — Use `task.wait()` for better scheduler integration.
- No direct `game:GetService` in loops — Cache services at top-level.
- Avoid `_G` — Use `getgenv()` for executor-level globals.
