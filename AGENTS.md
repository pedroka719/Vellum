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

## SESSION LOG — 2026-06-29

### Problem: Skylands auto farm level stuck in oscillation loop

**Symptom:** At level ~177-179 (Skylands Dark Master quest), the character oscillates between the tower entrance and Sky Bandits, never farming the correct Dark Master mob.

### Investigation via MCP Executor (Volt)

**Game remote API decompilation** (`ReplicatedStorage.DialoguesList.f11`):
- `CommF_:InvokeServer("StartQuest", questId, tier)` return values:
  - **0** = SUCCESS — "Quest accepted" (NOT failure as previous code assumed)
  - **1** = ERROR — "An error has occurred" (level/requirements not met)
  - **2** = DONE — "You already completed this quest"
- `GetQuestInfo` is NOT a valid verification call — always returns nil on the client; the game uses `QuestUpdate` RemoteEvent for quest state tracking
- `CommF` (no underscore) also exists — same behavior as `CommF_`

**Skylands NPC structure** (from ReplicatedStorage.NPCManager.NPCList):
- NPC named "Sky Adventurer" registered with `legacyRegisterNPC` — maps to `DialoguesList.SkyQuest`
- `ReplicatedStorage.Quests.SkyQuest` has two tiers:
  - Tier 1: LevelReq=150, "Sky Bandit", task 7
  - Tier 2: LevelReq=175, "Dark Master", task 8

**Skylands map geometry** (from in-game probe):
- **Tower entrance/exit** (portal): Y=874, (-4607, 874, -1667)
- **Main landmass** (NPCs/SHOP): Y=714, (-4840, 714, -2620) — QUEST part, Master Sword Dealer
- **Sky Bandit platform**: Y=277, (-4948, 277, -2984)
- **Dark Master platform**: Y=440, (-4948, 440, -2984)
- **Island center**: (-4750, 874, -2400), atRadius=900 (XZ only)
- No in-game teleport pads or internal portals found within Skylands for platform-to-platform travel
- Enemies folder has only 4 Sky Bandits — no Dark Masters spawn without active quest

**Quest acceptance flow** (current, after fix `64c1a47`):
1. `autoFarmLevelLoop` → `pickQuest(179)` → returns SkyQuest tier 2 (Dark Master)
2. `acceptQuest({"SkyQuest", tier=2})` → `StartQuest("SkyQuest", 2)` → returns 0 (success) → `Q.accepted = true`
3. `applyQuestFilters(quest)` → `cfg.farmTargetName = "Dark Master"`
4. `autoFarmLoop` → `pickEnemy()` → no Dark Master in workspace.Enemies → returns nil → no target

### Commits

| Commit | Change | Result |
|--------|--------|--------|
| `bc5e4b7` | Gate `applyQuestFilters` on `Q.accepted` | ❌ Wrong — broke core design; user rejected |
| `64c1a47` | **Fix StartQuest return logic** — 0=success, 1=error, 2=done | ✅ Quest acceptance works (StartQuest returns 0 now correctly handled) |
| `808e75f` | Sub-zone nav uses BodyPosition physics instead of TweenService/CFrame snap | ❌ Still blocked by anti-cheat — character can't reach Dark Master platform |

### Anti-Cheat Constraints (Blox Fruits)

The game blocks the following movement mechanisms:
- **TweenService** — full blocking (any direction)
- **CFrame snaps > ~75 studs** — upward AND likely downward
- **BodyPosition** — UNKNOWN if blocked for large distance; works for short combat movement (20-50 studs)

The following probably work (natural movements):
- Humanoid walking/running (MoveTo)
- Natural falling (gravity)
- Small incremental CFrame moves (< 40 studs)
- BodyVelocity with moderate force

### Remaining Problems

1. **Character can't reach Dark Master platform (Y=440) from tower (Y=874)**
   - All attempted mechanisms (CFrame snap, TweenService, BodyPosition) appear blocked by anti-cheat for this 434-stud vertical gap
   - No teleport pads exist within Skylands for platform travel
   - Need a reliable anti-cheat-proof descent mechanism

2. **Dark Masters don't spawn when character is at the wrong sub-zone**
   - Enemies folder shows 0 Dark Masters when character is at tower (Y=874)
   - Likely server only spawns quest mobs when player is near the correct enemy region

3. **Oscillation between tower and Sky Bandits**
   - tpToIsland puts character at tower; chase behavior takes them away; tpToIsland re-triggers
   - Root cause partially addressed by grace period but still happens when grace expires

### Investigated Dead Ends

- **NPC tween to Sky Adventurer** (removed in `b5c68d4`): Proximity to NPC doesn't affect StartQuest — it's a RemoteFunction
- **GetQuestInfo verification** (removed in `64c1a47`): Always returns nil, not a valid check
- **Tierless StartQuest fallback** (removed in `64c1a47`): `StartQuest("SkyQuest")` returns 1 (error); tier parameter is required
- **BodyPosition sub-zone nav** (`808e75f`): Physics-based movement still blocked by anti-cheat for large vertical distances
