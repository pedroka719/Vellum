# Vellum Blox Fruits — Session Scratchpad

## Context

This session was dedicated to making island teleportation in the Blox Fruits Vellum module (`vellum/games/blox_fruits.lua`) reliable without triggering the game's anti-cheat. The project lives at `D:\roblox-executor-mcp\` — a local Roblox Executor MCP server. **No git was used.** All edits were made directly to the file on disk.

---

## Original Problem

The `tpToIsland(name)` function needed to teleport the player across the Blox Fruits Sea 1 map (islands up to 60K+ studs apart) without:

- **Rollback** — the server reverts the player's position
- **Kick** — the server disconnects the player
- **Fling-fix throttle** — BF's velocity guard zeroes velocity > ~750 studs/sec

---

## What We Tried (and Failed)

### 1. BodyVelocity at 700 studs/sec

**Attempted:** Use `BodyVelocity` to fly the player at 700 studs/sec (under the 750 fling-fix cap).

**Result:** Anti-cheat flagged sustained BodyVelocity use. Rollback + kick within seconds.

**Root cause:** BF's anti-cheat monitors `BodyVelocity` as unnatural movement. Even though each individual velocity value is under the fling-fix cap, the *sustained* use of BV is detected server-side.

---

### 2. Direct CFrame writes > ~10K studs

**Attempted:** Instant `hrp.CFrame = destinationCFrame` for long-distance teleports.

**Result:** Server position reconciliation triggered. Rollback.

**Root cause discovered:** BF's anti-cheat rejects CFrame changes where the delta exceeds ~10K studs. The server will not accept an instantaneous position change of that magnitude. However, deltas < ~10K studs are accepted.

---

### 3. Death teleport / LoadCharacter

**Attempted:** Kill the character and use `LoadCharacter` to respawn at a different location. Also tried `CommF_:InvokeServer("SetSpawnPoint")`.

**Result:** `SetSpawnPoint` returned `1` but didn't actually change the spawn. `LoadCharacter` always spawns at the default island. Death teleport results in respawning at the last valid spawn point — not the destination.

---

### 4. Invoking game remotes directly

**Attempted:**

- `RF/BoatCastleTeleporters:InvokeServer("UnderwaterCity")` and variants
- `RF/BoatCastleTeleporters:InvokeServer()` with no args
- `RE/TeleportPad:FireServer(entrancePart)` and variants
- `RF/SynchronizedTeleport:InvokeServer(cframe)`

**Result:** Either silent failure (FireServer) or timeout / hang (InvokeServer). The correct invocation pattern for these remotes is unknown; the game's teleporter scripts are obfuscated in `ReplicatedStorage.Controllers` and not directly readable.

---

### 5. Teleporter Pad Exploit (BROKEN — Critical Discovery)

**Attempted:** Exploit the game's built-in TeleportSpawn system:

1. Anchor all character parts
2. CFrame the character to the TeleportSpawn Entrance (4050, 3, -1814) — a 3.5K stud move, under the 10K anti-cheat threshold
3. Create an unanchored ball at the Entrance position to physically collide with the Entrance part
4. The game's server-side Touched handler would detect the collision and warp the player to the destination (Underwater City)

**Result:** Never worked. The ball either fell through or never triggered the teleporter.

**Root cause discovered (confirmed by measurement):** The Entrance part at `workspace.Map.TeleportSpawn.Entrance` is positioned at (4050, -2, -1814) with size **(250, 0.1, 250)** — a paper-thin 0.1-stud-tall pad. Any unanchored part dropped onto it from even 1 stud above reaches ~31 studs/sec by the time it hits the pad, moving ~0.5 studs per physics frame — 5× the pad's thickness. The part **tunnels through** without ever triggering Touched.

**Attempted mitigations that also failed:**
- Ball created at Y=30 → fell 32 studs, even worse tunneling
- Ball created at Y=-1.9 (0.1 stud above pad) → same tunneling
- Ball created at Y=-2 (inside the Entrance volume) → physics pushed it out but never triggered server-side Touched
- Large flat brick instead of ball → same issue
- Unanchored the entire character at the Entrance → character fell through too
- Ball parented to workspace instead of character → same result

**Conclusion:** The teleporter pad exploit is fundamentally broken due to physics tunneling through the 0.1-thick pad. BF would need a thicker pad for this to work. Abandoned.

---

### 6. Remote spy investigation

**Attempted:** Use Cobalt's remote spy to capture what remotes the game actually fires when a player walks onto the TeleportSpawn Entrance.

**Result:** The remote spy was loaded and functional but the game's teleporter Touched handler runs entirely server-side. The client never sees the remote call. The only teleport-related remotes visible are:
- `RF/SynchronizedTeleport` (server → client, for server-authorized teleport)
- `RF/BoatCastleTeleporters` (client → server, but unknown invocation pattern)
- `RE/TeleportPad` (client → server, but unknown invocation pattern)

---

## What Worked

### Multi-hop Segmented Tween

**Final approach:** Use `TweenService` to CFrame-tween the HumanoidRootPart in segments:

- **Single tween** for islands < 15K studs away: 350 studs/sec
- **Multi-hop tween** for islands > 15K studs away: 1500 studs/sec in ≤15K-stud hops with 0.3s pauses between hops
- **BodyPosition settle** after arrival (3-second hold, no CFrame writes)

**Verified:** Successfully teleported from the Entrance area (4050, 20, -1814) to Underwater City (61379, 6, 1473) — **57,500 studs in 4 hops** — with zero anti-cheat flags, rollbacks, or kicks.

**Why it works:**
- TweenService moves the HRP by writing `CFrame` each frame — the engine derives a velocity from the delta, but it's not a sustained `BodyVelocity` physics force
- Each hop is ≤15K studs, keeping individual deltas under the anti-cheat threshold
- The 0.3s pause between hops resets any "sustained unnatural movement" timer BF might maintain
- The approach speed (1500 studs/sec) isn't flagged because it's near-instant per hop (10 seconds max)

---

## Code Changes Made

### File: `vellum/games/blox_fruits.lua`

| Change | Lines | Description |
|--------|-------|-------------|
| **Removed** `TELEPORT_PADS` table | -5 | Deleted the hardcoded pad coordinates for Underwater City |
| **Removed** dead pad-trigger block | -30 | Deleted anchor+CFrame + ball creation + 15s wait loop |
| **Added** explanation comment | +3 | Documents why the pad approach was removed |
| **Fixed** variable scope | +1 line edit | Changed `dist = ...` to `local dist = ...` (was leaking to global) |

**Total: ~32 lines removed, ~3 lines added, ~1 line fixed.**

The function now goes straight from `_findClearLanding` → distance check → single tween or multi-hop tween, skipping the broken 15-second pad wait entirely.

---

## Game Structure Discoveries

### TeleportSpawn System

```
workspace.Map.TeleportSpawn
  Entrance (Part)     @ (4050,  -2, -1814) size (250, 0.1, 250)  -- trigger pad
  Exit (Part)         @ (61170, -2,  1953)                        -- return pad
  EntrancePoint (Part)@ (61164, 12,  1820)                        -- UC arrival point
  ExitPoint (Part)    @ (3865,   7, -1926)                        -- return arrival point
```

The Entrance/Exit pads are anchored, CanCollide=true, CanTouch=true. No scripts are parented to TeleportSpawn itself — the Touched handler lives in obfuscated scripts under `ReplicatedStorage.Controllers`.

### Underwater City (Fishmen Model)

```
workspace.Map.Fishmen (Model)
  ├── Above water (Y > 5):    488 parts  -- buildings, palace, walls
  ├── Sea level (Y 2-5):       34 parts
  ├── Shallow (Y -50 to 2):    18 parts
  ├── Deep (Y < -50):           0 parts
  ├── Dome @ (61379, 327, 1316) -- physical opaque dome at top of city
  └── Entrance @ (62104, -8, 1287) size (182, 197, 5) -- underwater barrier/trigger
```

The city is mostly above-water structures with a dome at the top. The "Entrance" part at Y=-8 below sea level suggests an underwater cave/entry point. No fully submerged city section exists below Y=-50.

### Anti-Cheat Parameters (Empirically Determined)

| Parameter | Threshold | Behavior |
|-----------|-----------|----------|
| Direct CFrame delta | ~10K studs | <10K: accepted. >10K: rollback |
| BodyVelocity sustained | ~a few seconds | Rollback + kick |
| TweenService CFrame | No limit found | Tested over 57K studs, no flags |
| Physics tunneling threshold | ~0.1 stud part thickness | Thinner parts let objects pass through |

---

## Session Timeline

1. **Investigation phase:** Identified that BodyVelocity and direct CFrame were failing. Discovered the 10K stud anti-cheat threshold.
2. **Teleporter pad exploit research:** Found the TeleportSpawn system, mapped Entrance/Exit coordinates, attempted multiple trigger methods.
3. **Remote analysis:** Mapped the game's remote structure, identified `RF/BoatCastleTeleporters`, `RE/TeleportPad`, `RF/SynchronizedTeleport`.
4. **Physics validation:** Confirmed the Entrance pad is 0.1 studs thick → physics tunneling → ball exploit broken.
5. **Multi-hop tween test:** Successfully teleported 57,500 studs to Underwater City via segmented tween.
6. **Code cleanup:** Removed dead pad code, cleaned up variable scoping.

---

## Remaining Unknowns

- Correct invocation pattern for `RF/BoatCastleTeleporters` (would need to sniff from a legitimate game interaction)
- Whether there's a second teleporter pair for the underwater-to-surface transit at the Fishmen Entrance
- The exact anti-cheat timeout window between hops (0.3s works, but minimum safe gap unknown)
