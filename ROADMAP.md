# Vellum Roadmap

Features discussed but deferred. Ordered by impact. Pick from the top.

## High value, ship soon

### Sea events + raids
`workspace.SeaEvents` and `workspace.SeaBeasts` folders exist but were empty during recon. When populated they hold Sea Beast spawns (50-200k XP scaling), Ghost Ship raids, Cursed Captain. Detect via ChildAdded; auto-engage if user opts in.

**Blocked on:** live probe of an active event to confirm model structure. Ping when one spawns.

### Auto-claim daily rewards
BF login chain: daily bonus, fortune wheel, premium menu, codes. Most are `CommF_:InvokeServer(...)` one-shots. Free XP/beli for users who reload daily. Hubs gate this behind paid tiers because it's pure passive value.

**Cost:** small. Need spy capture of each daily call (login once with spy on, see what fires).

### Sea 2 quest atlas extension
Current atlas covers Lv 1-749 (Sea 1 + into Sea 2). Past Lv 700, the script falls off. Atlas rows for ForgottenQuest (1425+), DeepForestIsland (1775+), HauntedQuest1/2 (1975/2025+), TikiQuest1/2/3 (2450-2575), SubmergedQuest1/2 (2600-2675), etc — all in `ReplicatedStorage.Quests` (already dumped during recon, see [project-vellum-bf](../../../Pekenz/.claude/projects/D--roblox-executor-mcp-roblox-executor-mcp/memory/project_vellum_bf.md)).

**Cost:** ~30 minutes. Mostly data entry + sub-zone verification per island.

## Medium value

### Auto Buy / Eat / Store fruit
Once Fruit Sniper grabs a fruit, what next? Options:
- Eat it (replace current fruit)
- Store via Fruit Storage NPC (max FruitCap, currently 1)
- Sell to dealer for beli
- Hold in backpack

Per-fruit policy: snipe-and-store the rares, snipe-and-sell the commons.

### Mastery farm mode
Equipped weapon/fruit gains mastery from kills. Some moves require mastery 200+ to unlock. A mode that picks easy XP mobs while keeping a specific weapon equipped would speed mastery grind.

### Auto-equip best weapon
When a better weapon enters Backpack (drop, purchase), auto-equip if user opts in. Useful in raids.

## Polish

### Settings save/load across reloads
Persist `cfg` to file (via `writefile`/`readfile` on executors that support it) or HttpService POST to a paste service. Restore on next boot.

### Hotkey rebinding
Currently RightShift toggles UI. Let users bind their own.

### Floating mini-status widget
Always-visible HP, level, XP/hr, current quest. Independent of main GUI minimize state.

### Theme customization
User-picked accent color → propagate through Theme.

## Skip — high risk, low reward

- **Server hop / auto-rejoin** — anti-cheat watches teleport remotes; one bad arg = kick
- **Walkspeed / JumpPower mods** — flagged instantly by BF, not worth it
- **Auto-block / auto-dodge PvP** — needs damage-event hooks; "unnatural defensive timing" is a known detection vector
- **Direct CFrame jumps to fruits** — what other hubs do for sniper, what gets users kicked. We use multi-hop tween instead.

## Notes on risky areas

Fruit pickup is **collision-only** — no remote firing required. Walk into the Handle. Any hub that fires a "pickup remote" is asking for a kick. We rely on the natural Touched event.

Sub-zone navigation patterns (verified safe):
- Multi-hop TweenService CFrame in ≤15K-stud hops, up to 60K total — survives anti-cheat
- Direct CFrame writes under ~1000 studs — fine
- Direct CFrame writes 1K-10K — usually fine but pause flight first (BodyPosition fights)
- Anything > 10K in one frame — rollback / kick
