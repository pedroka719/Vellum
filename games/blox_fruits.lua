-- Vellum — Blox Fruits (v0.2)
--
-- PlaceId 2753915549. Single source of truth: this file. lib/ stays generic.
--
-- Combat protocol:
--   1. RegisterAttack:FireServer(damageMul)            -- 0.5 normal / 1.0 finisher
--   2. RegisterHit:FireServer(part, {}, nil, hash)     -- part is child of enemy
--   ~0.18s between swings is realistic and unflagged.
--
-- Hash is self-generated from UserId + thread ID (same formula BF's CombatUtil
-- uses internally). We fire its one-shot registration ourselves so the server
-- accepts our hits. No dependency on the game's broken CombatUtil coroutine.
--
-- Movement: NEVER raw CFrame TPs (detection vector). Always tween, capped
-- below the velocity guard's 1500 threshold (the StarterCharacter "Fling
-- and Underwater Glitching Fix" zeroes velocity past that).
--
-- Safe Farm: hover N studs above the target's HRP. Mobs can't reach, the
-- server validates the part exists at hit time, not line-of-sight.

local Players          = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService       = game:GetService("RunService")
local TweenService     = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local VirtualUser      = game:GetService("VirtualUser")

local Module = {
	name = "Blox Fruits",
	placeIds = { 2753915549 },
}

function Module.start(lib)
	local Theme   = lib.theme
	local UI      = lib.ui
	local Toast   = lib.toast
	local Helpers = lib.helpers
	local ESP     = lib.esp

	local LocalPlayer = Players.LocalPlayer

	-- Forward-declare so the loop closures below capture this as an upvalue
	-- instead of a global nil. The assignment happens after UI.mount().
	local gui

	-- ═══════════════════════════ R TABLE ═══════════════════════════
	local Net = ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Net")
	local Remotes = ReplicatedStorage:WaitForChild("Remotes")

	local R = {
		RegisterAttack = Net:WaitForChild("RE/RegisterAttack"),
		RegisterHit    = Net:WaitForChild("RE/RegisterHit"),
		CommF_         = Remotes:WaitForChild("CommF_"),
		CommE          = Remotes:WaitForChild("CommE"),
	}

	-- ═══════════════════════════ CONFIG ═══════════════════════════
	local cfg = {
		-- master AFK
		afkMode = false,

		-- farm
		autoFarm = false,
		farmHeight = 50,            -- studs above target — full damage through ~55, out of the mob's own reach
		attackCadence = 0.25,       -- sec between RegisterAttack/Hit pairs
		damageMultiplier = 1.0,     -- 1.0 = always finisher hits
		farmLevelMin = 0,           -- only attack enemies within range
		farmLevelMax = 9999,
		farmTargetName = "",        -- "" = any enemy. Set to "Bandit" etc.
		aggressiveRange = false,    -- pull target under us each tick (ignores server range)
		mobBring = false,           -- pull all nearby enemies toward player
		mobBringRadius = 50,        -- max studs to pull enemies from
		killAura = false,           -- standalone loop: sweep every mob within reach each tick.
		                            -- Works alone (pair with Mob magnet) or on top of Auto Farm Level.

		-- auto farm level
		autoFarmLevel = false,       -- full quest lifecycle (accept → farm → detect done → re-accept)
		skipBossQuests = true,       -- skip 1-kill boss quests (Warden, Chief Warden, etc) —
		                             -- ~5min spawn timers tank XP/hour vs regular mob quests

		-- weapon selection
		selectedWeapon = "",         -- name of weapon to auto-equip ("" = first available)

		-- ability rotation
		abilitySlots = { Z = false, X = false, C = false, V = false, F = false },
		abilityCadence = 2.0,        -- sec between ability activations

		-- combat
		aimbot         = false,      -- master aimbot switch
		aimbotMode     = "Kill Aura",-- "Kill Aura" (auto-hit nearest) or "Silent Aim" (hit on YOUR shot)
		aimbotGunsOnly = false,      -- optional: restrict the aura to only fire while a gun is equipped
		aimbotRange    = 800,        -- max stud distance to a target
		infiniteEnergy = false,      -- top the energy/stamina bar back up

		-- fruit sniper — auto-tween to dropped devil fruits and let
		-- natural collision pickup grab them. Pure passive collection,
		-- no remote firing (BF pickup is collision-only via Tool.Handle).
		fruitSniper      = false,    -- master switch
		snipeMaxDist     = 5000,     -- don't fly past this for a fruit
		snipeSkipCommons = true,     -- ignore Bomb/Spike/Spring/etc

		-- shop — auto-buy from Blox Fruit Dealer when a sniped fruit
		-- enters the on-sale rotation. Manual buy buttons cover weapons,
		-- styles, haki, boats (one-click TP-to-NPC + BuyItem + TP back).
		dealerSniper     = false,    -- master switch for dealer auto-buy
		dealerSnipeList  = {},       -- { ["Mera-Mera"] = true, ... }
		shopRequireConfirm = true,   -- toast confirm before any buy fires

		-- visuals / ESP
		espIslands   = true,         -- billboard names over each island
		espPlayers   = false,        -- card with name·lv / race·fruit / HP bar
		espChests    = false,        -- Silver/Gold/Diamond chest markers
		espFruits    = false,        -- spawned devil fruits in workspace.Characters
		espBosses    = false,        -- mini-bosses + named bosses, amber outline + HP
		espQuestMob  = false,        -- current quest mob — green highlight
		espTracers   = false,        -- Drawing.Line from screen-center to ESP targets
		espMaxDist   = 0,            -- 0 = unlimited; otherwise hide beyond N studs

		-- stat allocation
		autoStats = false,
		statPriority = "Melee",     -- "Melee" | "Defense" | "Sword" | "Gun" | "Demon Fruit"
		statBatchSize = 1,          -- points per AddPoint call

		-- anti-AFK (port from soccer)
		antiAfk = true,

		-- spy
		notifyInGame = true,        -- toast notifications
		keybindToggle = true,       -- RightShift toggles UI minimize
	}

	-- ═══════════════════════════ STATE ═══════════════════════════
	local stats = {
		sessionXP = 0,
		sessionBeli = 0,
		sessionKills = 0,
		sessionStart = os.clock(),
	}

	local jwait = Helpers.makeJwait(cfg)
	local safe = Helpers.makeSafe("Vellum BF")

	-- ═══════════════════════════ SESSION HASH ═══════════════════════════
	-- Persistent per-session hash store in getgenv, so a reload keeps the
	-- registered hash instead of re-registering it.
	getgenv().VellumBF = getgenv().VellumBF or {}
	local SPY = getgenv().VellumBF
	SPY.cfg = cfg  -- expose live for probing / tuning toggles from the executor

	-- Teleport-in-progress guard. Pauses autoFarm + flight while a TP runs
	-- so the hover loop doesn't fight the tween for HRP control.
	local _tpInProgress = false
	local _questFailAt = 0  -- tick() when quest acceptance last failed; retry after 60s

	-- Master alive flag. Set to false when the GUI is closed so all spawned
	-- loops (autoFarm, autoFarmLevel, autoStats, progress) exit cleanly instead
	-- of running forever. Without this the loops depended on gui.Parent,
	-- which kills them when the ScreenGui is destroyed — but that means
	-- toggling auto-farm back ON after closing/reopening the GUI does
	-- nothing because the loop is already dead.
	local _running = true

	-- Self-generate and register a session hash using the same formula BF's
	-- CombatUtil uses internally (UserId chars 2-4 + thread hex chars 11-15).
	-- The server accepts any consistent 8-hex-char hash — we just have to fire
	-- the one-shot registration BEFORE using it in RegisterHit calls.
	local function generateHash()
		local prefix = tostring(LocalPlayer.UserId):sub(2, 4)
		local suffix = tostring(coroutine.running()):sub(11, 15)
		return prefix .. suffix
	end

	-- Register the hash with the server so RegisterHit:FireServer(..., hash)
	-- is accepted. Fire-and-forget — the server stores it per-session.
	local function registerHash(hash)
		if not hash then return end
		local ok, err = pcall(function() R.RegisterHit:FireServer(hash) end)
		if ok then
			warn("[Vellum BF] hash registered:", hash)
		else
			warn("[Vellum BF] hash registration failed:", err)
		end
	end

	-- Ensure we have a hash generated and registered. Called at boot and after
	-- respawn. Once registered, the hash is stored in SPY (getgenv) and reused
	-- across script reloads until the next CharacterAdded invalidates it.
	local function ensureHash()
		if SPY.hash then return SPY.hash end
		SPY.hash = generateHash()
		registerHash(SPY.hash)
		return SPY.hash
	end

	local function getHash() return SPY.hash end

	local function clearHash()
		SPY.hash = nil
		warn("[Vellum BF] session hash cleared — will regenerate on next tick")
	end


	-- BF rotates the hash every respawn. Generate a fresh one, register it,
	-- and resume farming on the new character.
	LocalPlayer.CharacterAdded:Connect(function()
		clearHash()
		-- Generate and register a new hash on the new character's thread
		task.spawn(function()
			task.wait(1.5)  -- let the character load
			ensureHash()
		end)
	end)

	-- ═══════════════════════════ COMBAT ═══════════════════════════
	local BODY_PARTS = {
		"UpperTorso", "Head", "LowerTorso",
		"LeftLowerLeg", "RightLowerLeg",
		"LeftUpperArm", "RightUpperArm",
	}

	local function pickPart(enemy)
		for _, name in ipairs(BODY_PARTS) do
			local p = enemy:FindFirstChild(name)
			if p and p:IsA("BasePart") then return p end
		end
		return enemy:FindFirstChildOfClass("MeshPart")
	end

	local function attackOnce(enemy)
		local part = pickPart(enemy)
		local hash = getHash()
		if not part or not hash then return false end
		safe(function() R.RegisterAttack:FireServer(cfg.damageMultiplier) end)
		safe(function() R.RegisterHit:FireServer(part, {}, nil, hash) end)
		return true
	end

	-- ── Damage via the game's own hit pipeline ──────────────────────────
	-- RE/RegisterHit is a *virtual* remote: the event name is XOR-encoded and
	-- rides a "carrier" remote that reparents itself between random folders,
	-- and the server validates that carrier's identity. Firing the raw
	-- RE/RegisterHit (what attackOnce does) is silently dropped — that's the
	-- real reason the hash path deals 0 damage, not the hash itself.
	-- CombatUtil registers a per-session hash inside its own coroutine and
	-- leaves _G.SendHitsToServer(part, hits) as the gateway that flushes a hit
	-- through that coroutine with the valid hash + correct channel. It lives in
	-- the GAME's global env, not the executor's, so we reach it via getrenv()._G.
	-- The server range-checks from our position and needs a weapon equipped —
	-- verified live 2026-07-03: Combat equipped + hover 40–55 studs = full
	-- damage, zero damage taken; beyond ~80 studs it drops to 0.
	local _gameEnv
	local function gameHits()
		if _gameEnv and _gameEnv.SendHitsToServer then return _gameEnv.SendHitsToServer end
		local ok, g = pcall(function() return getrenv()._G end)
		if ok and type(g) == "table" and type(g.SendHitsToServer) == "function" then
			_gameEnv = g
			return g.SendHitsToServer
		end
		return nil
	end

	-- Server-side melee reach for a registered hit. ~55 studs is the measured
	-- edge (full damage through the low 40s, gone by the mid 80s).
	local MELEE_REACH = 55

	-- One hit on a single enemy through the game pipeline. Used by Silent Aim.
	local function sendHit(enemy)
		local send = gameHits()
		if not send then return false end
		local part = enemy and (enemy:FindFirstChild("HumanoidRootPart") or pickPart(enemy))
		if not part then return false end
		safe(function() R.RegisterAttack:FireServer(cfg.damageMultiplier) end)
		safe(function() send(part, {}) end)
		return true
	end

	-- Aura: one swing, whole pack. BF flushes a melee hit as
	-- FireServer(firstPart, {{mob, part}, ...}, nil, hash) — a primary target
	-- plus a batch of extras in the second arg. Firing one SendHitsToServer per
	-- mob does NOT stack: the server credits ~one target per swing (attack-speed
	-- gate), so separate calls just re-hit the first mob. Packing every in-reach
	-- mob into that batch is what lands damage on all of them at once (verified
	-- live: two mobs, 73 damage each, from a single call). `filter` (a mob name,
	-- "" / nil for any) keeps quest mode from crediting the wrong mob.
	local function attackAura(filter)
		filter = filter or ""
		local send = gameHits()
		if not send then return end
		local ch = LocalPlayer.Character
		local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
		local ef = workspace:FindFirstChild("Enemies")
		if not (hrp and ef) then return end
		local origin = hrp.Position
		local first, rest = nil, {}
		for _, e in ipairs(ef:GetChildren()) do
			if filter == "" or e.Name == filter then
				local eh = e:FindFirstChild("HumanoidRootPart")
				local hum = eh and e:FindFirstChildOfClass("Humanoid")
				if eh and hum and hum.Health > 0 and (eh.Position - origin).Magnitude <= MELEE_REACH then
					if not first then first = eh else rest[#rest + 1] = { e, eh } end
				end
			end
		end
		if not first then return end
		safe(function() R.RegisterAttack:FireServer(cfg.damageMultiplier) end)
		safe(function() send(first, rest) end)
	end

	-- ═══════════════════════════ COMBAT ═══════════════════════════
	-- Damage goes through the game's own hit pipeline (attackAura / sendHit
	-- above). attackOnce + the self-generated hash below are the dead
	-- raw-remote path, kept only for reference — the server ignores the raw
	-- RE/RegisterHit, so they deal 0 damage. Nothing calls them anymore.

	-- ═══════════════════════════ TARGETING ═══════════════════════════
	-- Logia immunity: tracked behaviorally because BF doesn't expose the
	-- player's Buso ownership client-side. Starts unknown — flips false
	-- on first 'Enemy is immune to physical attacks' notification, flips
	-- true if we ever observe HP damage on a Logia enemy.
	local _hasBuso = nil  -- nil = unknown, false = confirmed missing, true = confirmed have

	-- Score = inverse distance + level-fit. Closer + within range = higher.
	-- When autoFarmLevel sets farmTargetName (quest mode), ONLY return enemies
	-- matching that name. Falling back to wrong enemies means kills don't count
	-- toward the quest and the cycle stalls on the same tier forever.
	local function pickEnemy()
		local ch = LocalPlayer.Character
		local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
		if not hrp then return nil end

		local bestFiltered, bestFilteredScore
		local bestAny, bestAnyScore

		for _, e in ipairs(workspace.Enemies:GetChildren()) do
			local ehrp = e:FindFirstChild("HumanoidRootPart")
			local hum  = e:FindFirstChild("Humanoid")
			if ehrp and hum and hum.Health > 0 then
				-- Logia guard: Logia-fruit enemies are physically immune
				-- without Buso Haki. If we've confirmed we lack Buso (via
				-- the notification scanner), skip them — attacking just
				-- wastes attack ticks and risks suicide on bosses. Bypass
				-- when _hasBuso is nil (unknown) so the first attempt
				-- can produce the notification we use to detect.
				local fruitType = e:GetAttribute("FruitType")
				local busoNeeded = e:GetAttribute("BusoEnabled")
				if fruitType == "Logia" and busoNeeded and _hasBuso == false then
					-- skip — can't damage this enemy
				else
				local d = (ehrp.Position - hrp.Position).Magnitude
				local score = 1000 - d  -- closer = higher

				if not bestAnyScore or score > bestAnyScore then
					bestAny, bestAnyScore = e, score
				end

				local lvl = e:GetAttribute("Level")
				local lvlOK = lvl and lvl >= cfg.farmLevelMin and lvl <= cfg.farmLevelMax
				local nameOK = cfg.farmTargetName == "" or e.Name == cfg.farmTargetName
				if lvlOK and nameOK then
					if not bestFilteredScore or score > bestFilteredScore then
						bestFiltered, bestFilteredScore = e, score
					end
				end
				end
			end
		end

		-- When autoFarmLevel set farmTargetName, ONLY return matching enemies.
		-- Falling back to bestAny kills wrong mobs — quest kills never count,
		-- and the quest cycle stalls forever on the same tier.
		if cfg.farmTargetName ~= "" then
			if not bestFiltered and bestAny then
				warn("[Vellum BF] no '" .. cfg.farmTargetName .. "' in workspace.Enemies — " ..
				      bestAny.Name .. " is nearest but quest needs " .. cfg.farmTargetName)
			end
			return bestFiltered
		end
		return bestAny
	end

	-- ═══════════════════════════ ISLAND MAP ═══════════════════════════
	-- Sea 1 destinations. Coordinates lifted from RoyxHub's verified set —
	-- their hub uses these exact CFrames and they survive BF's anti-cheat.
	-- An island with `portal = <name>` is reached through a BF portal pad
	-- (see PORTAL_PADS below) rather than a raw tween.
	local ISLANDS = {
		{ name = "Pirate Starter",  pos = Vector3.new(979.8, 16.5, 1429.0),    lvlRange = "Lv 1-9"     },
		{ name = "Marine Starter",  pos = Vector3.new(-2566.4, 6.9, 2045.3),   lvlRange = "Lv 1-9"     },
		{ name = "Middle Town",     pos = Vector3.new(-690.3, 15.1, 1582.2),   lvlRange = "Lv 10-14"   },
		{ name = "Jungle",          pos = Vector3.new(-1612.8, 36.9, 149.1),   lvlRange = "Lv 15-29"   },
		{ name = "Pirate Village",  pos = Vector3.new(-1181.3, 4.8, 3803.5),   lvlRange = "Lv 30-59"   },
		{ name = "Desert",          pos = Vector3.new(944.2, 20.9, 4373.3),    lvlRange = "Lv 60-89"   },
		{ name = "Frozen Village",  pos = Vector3.new(1347.8, 104.7, -1319.7), lvlRange = "Lv 90-119"  },
		{ name = "Marine Fortress", pos = Vector3.new(-4914.8, 51.0, 4281.0),  lvlRange = "Lv 120-149" },
		{ name = "Skylands",        pos = Vector3.new(-4750.0, 874.0, -2400.0),lvlRange = "Lv 150-249", portal = "Sky3Exit", atRadius = 900 },
		{ name = "Prison",          pos = Vector3.new(4875.3, 5.7, 734.9),     lvlRange = "Lv 250-324" },
		{ name = "Colosseum",       pos = Vector3.new(-11.3, 29.3, 2771.5),    lvlRange = "PvP"        },
		{ name = "Magma Village",   pos = Vector3.new(-5247.7, 12.9, 8504.9),  lvlRange = "Lv 325-449" },
		{ name = "Underwater City", pos = Vector3.new(61165.2, 0.2, 1897.4),   lvlRange = "Lv 450-624", portal = "UnderwaterExit" },
		{ name = "Fountain City",   pos = Vector3.new(5127.1, 59.5, 4105.4),   lvlRange = "Lv 625-749" },
	}

	local ISLAND_BY_NAME = {}
	for _, i in ipairs(ISLANDS) do ISLAND_BY_NAME[i.name] = i end

	-- BF portal pads. Stand on/near the pad position, fire CommF_:requestEntrance
	-- with that Vector3, and the server completes the warp through the linked
	-- portal — same path the Portal Fruit / Sea Portal uses. Server-authorized,
	-- no rollback. The pad is where the PLAYER must be; destination is the
	-- island's pos in ISLANDS above.
	local PORTAL_PADS = {
		UnderwaterExit = Vector3.new(4050, -1, -1814),    -- surface pad → Underwater City
		Sky3Exit       = Vector3.new(-4607, 874, -1667),  -- sky portal (Skylands variant)
	}

	-- Generic sub-zone discovery: returns the spawn centroid for a mob.
	-- Two-pass search so this handles BOTH:
	--   (a) "We're already there" — alive mobs in workspace.Enemies → take
	--       the centroid of live ones. Tracks mob drift through the zone.
	--   (b) "We just TP'd in and mobs haven't spawned yet" — BF only spawns
	--       enemies when a player is near the spawn anchor. Without alive
	--       mobs there's no centroid to navigate to, so we fall back to
	--       _WorldOrigin.EnemySpawns, BF's static spawn-anchor folder.
	--       Names are like "Toga Warrior [Lv. 250]" — match by prefix.
	-- This solves the Toga Warrior bug (and any future quest where the
	-- mob's sub-zone is far from the island.pos): atlas says island="Prison"
	-- but real Toga Warriors live at (-1800, 7, -2800) in the Colosseum
	-- sub-island. We tp to Prison.pos, find 0 alive Togas, then this
	-- function returns the EnemySpawns centroid (-1900, 7, -2750) and the
	-- caller snaps us into spawn range.
	-- True if we're within radius studs of ANY live quest mob OR static
	-- spawn anchor for the given mob. This is the "are we at the right
	-- place to be farming" check — replaces the coarse atIsland(name)
	-- which uses island.pos (Prison main is 8000+ studs from the
	-- Colosseum spawn zone where Toga Warriors actually live).
	local function nearQuestSpawn(mobName, hrp, radius)
		if not mobName or not hrp then return false end
		radius = radius or 600
		local r2 = radius * radius
		-- Live mobs (combat-state proximity)
		local enemies = workspace:FindFirstChild("Enemies")
		if enemies then
			for _, e in ipairs(enemies:GetChildren()) do
				if e.Name == mobName then
					local eh = e:FindFirstChild("HumanoidRootPart")
					local h  = e:FindFirstChild("Humanoid")
					if eh and h and h.Health > 0 then
						local dx, dy, dz = eh.Position.X - hrp.Position.X, eh.Position.Y - hrp.Position.Y, eh.Position.Z - hrp.Position.Z
						if dx*dx + dy*dy + dz*dz < r2 then return true end
					end
				end
			end
		end
		-- Static spawn anchors (between-respawn proximity)
		local origin = workspace:FindFirstChild("_WorldOrigin")
		local spawns = origin and origin:FindFirstChild("EnemySpawns")
		if spawns then
			local prefix = mobName .. " [Lv."
			for _, p in ipairs(spawns:GetChildren()) do
				if p:IsA("BasePart") and p.Name:sub(1, #prefix) == prefix then
					local dx, dy, dz = p.Position.X - hrp.Position.X, p.Position.Y - hrp.Position.Y, p.Position.Z - hrp.Position.Z
					if dx*dx + dy*dy + dz*dz < r2 then return true end
				end
			end
		end
		return false
	end

	local function discoverSubZone(mobName)
		-- Pass A: live mobs (fast path — most common during steady-state farm)
		local enemies = workspace:FindFirstChild("Enemies")
		if enemies then
			local sx, sy, sz, n = 0, 0, 0, 0
			for _, e in ipairs(enemies:GetChildren()) do
				if e.Name == mobName then
					local eh = e:FindFirstChild("HumanoidRootPart")
					local h  = e:FindFirstChild("Humanoid")
					if eh and h and h.Health > 0 then
						sx = sx + eh.Position.X
						sy = sy + eh.Position.Y
						sz = sz + eh.Position.Z
						n  = n + 1
					end
				end
			end
			if n > 0 then return Vector3.new(sx / n, sy / n, sz / n) end
		end

		-- Pass B: static spawn anchors. BF stores these at
		-- workspace._WorldOrigin.EnemySpawns with names of the form
		-- "<mob name> [Lv. NNN]". We strip the suffix and match by mob.
		local origin = workspace:FindFirstChild("_WorldOrigin")
		local spawns = origin and origin:FindFirstChild("EnemySpawns")
		if not spawns then return nil end
		local sx, sy, sz, n = 0, 0, 0, 0
		local prefix = mobName .. " [Lv."
		for _, p in ipairs(spawns:GetChildren()) do
			if p:IsA("BasePart") and p.Name:sub(1, #prefix) == prefix then
				sx = sx + p.Position.X
				sy = sy + p.Position.Y
				sz = sz + p.Position.Z
				n  = n + 1
			end
		end
		if n == 0 then return nil end
		return Vector3.new(sx / n, sy / n, sz / n)
	end

	-- Ordered list of a mob's static spawn anchors (cached — anchors never
	-- move). Powers the "walk the spawnpoints" farm behaviour: when the quest
	-- mob isn't spawned we visit each of ITS anchors in turn (BF only spawns a
	-- mob when a player is near its anchor), so we sweep the zone until one
	-- appears and never wander onto a boss or another species. Sorted by X then
	-- Z so the sweep is a clean pass across the zone, not random hops.
	local _anchorCache = {}
	local function spawnAnchorList(mobName)
		local cached = _anchorCache[mobName]
		if cached then return cached end
		local out = {}
		local origin = workspace:FindFirstChild("_WorldOrigin")
		local spawns = origin and origin:FindFirstChild("EnemySpawns")
		if spawns then
			local prefix = mobName .. " [Lv."
			for _, p in ipairs(spawns:GetChildren()) do
				if p:IsA("BasePart") and p.Name:sub(1, #prefix) == prefix then
					out[#out + 1] = p.Position
				end
			end
			table.sort(out, function(a, b)
				if a.X ~= b.X then return a.X < b.X end
				return a.Z < b.Z
			end)
		end
		-- Only cache once the spawns folder has actually streamed in, so an
		-- early empty read doesn't stick.
		if #out > 0 then _anchorCache[mobName] = out end
		return out
	end

	-- Island TP — pisun-hub pattern, the one that actually works.
	--
	-- BF's anti-cheat watches HRP per-frame: it rolls back tweens that finish
	-- in under ~5 seconds (any distance) and any single CFrame delta past a
	-- modest threshold. The bypass:
	--   1. If destination Y differs by > Y_SNAP_THRESHOLD from current, snap
	--      Y first with a direct CFrame write, wait 0.5s for the server to
	--      reconcile. BF tolerates pure vertical jumps better than diagonals.
	--   2. Tween HRP CFrame to the destination at TP_TWEEN_SPEED studs/sec
	--      linear. 150 keeps duration well above the 5s detection floor for
	--      any non-trivial trip. Fallback at 80 for retries after rollback.
	--   3. Y delta is handled by the tween itself — no instant CFrame snap.
	--      BF's server velocity guard flags single-frame position jumps.
	--   4. For destinations behind a server-side portal (Underwater City),
	--      tween to the portal pad first, then fire CommF_:requestEntrance —
	--      the server completes the warp legitimately, no rollback risk.
	local TP_TWEEN_SPEED   = 150
	local Y_SNAP_THRESHOLD = 75
	local activeTween

	-- Forward-declared so tpToIsland can call _stopFlightFn. Some executors
	-- miscompile `local function` forward refs, so we assign into a pre-decl.
	local _stopFlightFn
	local _bringBPs = {}       -- enemy HRP -> BodyPosition for mob magnet

	_stopFlightFn = function()
		-- Cancel any active tween so toggle-off stops movement instantly
		-- instead of letting the tween complete and fly the character to
		-- the destination first.
		if activeTween then pcall(function() activeTween:Cancel() end); activeTween = nil end
		-- NOTE: flightConn is NEVER disconnected. The Heartbeat stays alive
		-- for the entire session and gates on hoverEnabled + cfg.autoFarm.
		-- Disconnect/reconnect is unreliable across executor environments.

		-- Aggressively disable and remove all Vellum force fields.
		-- Some executors block :Destroy() but allow property writes and
		-- Parent=nil — so we zero force/torque first, then detach, then
		-- destroy as a safety net. Without this the BP (MaxForce=math.huge)
		-- holds the character locked in place and the BG fights rotation,
		-- making jump/dodge impossible after toggle-off.
		-- Also sweep the HRP for any orphan Vellum_* instances left by
		-- interrupted tweens or partial cleanup from prior crashes.
		if _hoverBP then
			_hoverBP.MaxForce = Vector3.new(0, 0, 0)
			_hoverBP.Parent = nil
			pcall(function() _hoverBP:Destroy() end)
		end
		if _hoverBG then
			_hoverBG.MaxTorque = Vector3.new(0, 0, 0)
			_hoverBG.Parent = nil
			pcall(function() _hoverBG:Destroy() end)
		end
		local ch = LocalPlayer.Character
		local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
		if hrp then
			for _, child in ipairs(hrp:GetChildren()) do
				if child.Name:find("^Vellum_") then
				if child:IsA("BodyGyro") then
					child.MaxTorque = Vector3.new(0, 0, 0)
				elseif child:IsA("BodyMover") then
					child.MaxForce = Vector3.new(0, 0, 0)
				end
				child.Parent = nil
				pcall(function() child:Destroy() end)
			end
		end
		end
		_hoverBP = nil
		_hoverBG = nil
		for hrp, bp in pairs(_bringBPs) do pcall(function() bp:Destroy() end) end
		_bringBPs = {}
		
		currentTarget = nil
		targetOriginalY = nil
		hoverEnabled = false

		-- Restore collision on character parts
		local ch2 = LocalPlayer.Character
		if ch2 then
			for _, p in ipairs(ch2:GetDescendants()) do
				if p:IsA("BasePart") then
					p.CanCollide = true
				end
			end
		end
	end

	local function _tweenHRPTo(hrp, destPos, opts)
		opts = opts or {}
		local speed         = opts.speed         or TP_TWEEN_SPEED
		local fallbackSpeed = opts.fallbackSpeed  or 80
		local maxRetries    = opts.retries        or 2

		if activeTween then pcall(function() activeTween:Cancel() end) end

		local destCF = CFrame.new(destPos, destPos - Vector3.new(0, 0, 1))
		local dist = (destPos - hrp.Position).Magnitude
		if dist < 3 then return end

		-- Hold the whole body non-collidable for the entire tween. tpToIsland
		-- (and the long sub-zone snap) deliberately drop flight and re-enable
		-- CanCollide before calling us — so without this the CFrame tween drags
		-- a SOLID character through island geometry, the physics engine shoves
		-- back, and BF rolls us back (or wedges us under the island at sea
		-- level). BF re-enables CanCollide on its own the moment we stop forcing
		-- it, so there's nothing to restore afterward.
		local ch = hrp.Parent
		local parts = {}
		if ch then
			for _, p in ipairs(ch:GetDescendants()) do
				if p:IsA("BasePart") then parts[#parts + 1] = p end
			end
		end
		local noclipping = true
		task.spawn(function()
			while noclipping do
				for _, p in ipairs(parts) do
					if p.CanCollide then p.CanCollide = false end
				end
				RunService.Heartbeat:Wait()
			end
		end)

		for attempt = 1, maxRetries do
			local curSpeed = attempt == 1 and speed or fallbackSpeed
			local dur = math.max(0.1, dist / curSpeed)
			local tween = TweenService:Create(hrp, TweenInfo.new(dur, Enum.EasingStyle.Linear), { CFrame = destCF })
			activeTween = tween
			tween:Play()
			tween.Completed:Wait()
			if activeTween == tween then activeTween = nil end

			if (hrp.Position - destPos).Magnitude < 80 then break end  -- arrived

			dist = (destPos - hrp.Position).Magnitude
			task.wait(0.3)
		end
		noclipping = false
	end

	local function tpToIsland(name)
		local island = ISLAND_BY_NAME[name]
		if not island then return false end
		local ch = LocalPlayer.Character
		local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
		if not hrp then return false end

		_tpInProgress = true
		local restoreAutoFarm = cfg.autoFarm
		local restoreAutoFL   = cfg.autoFarmLevel
		cfg.autoFarm = false
		cfg.autoFarmLevel = false
		_stopFlightFn()

		-- Portal-fronted destination: tween to the pad, fire requestEntrance,
		-- let the server finish the warp.
		if island.portal and PORTAL_PADS[island.portal] then
			local padPos = PORTAL_PADS[island.portal]
			_tweenHRPTo(hrp, padPos + Vector3.new(0, 4, 0))
			safe(function() R.CommF_:InvokeServer("requestEntrance", padPos) end)
			-- Bump up 50 studs so we don't immediately re-trigger the same pad
			hrp.CFrame = hrp.CFrame + Vector3.new(0, 50, 0)
			task.wait(1.5)  -- server completes portal warp

			-- Post-portal sub-zone discovery is handled by autoFarmLevelLoop
			-- (which knows the active quest mob). tpToIsland only places us at
			-- the portal exit; the next farm tick scans live spawns and snaps.
		else
			local landingPos = island.pos + Vector3.new(0, 4, 0)
			_tweenHRPTo(hrp, landingPos)
		end

		task.wait(0.3)
		_tpInProgress = false
		cfg.autoFarm = restoreAutoFarm
		cfg.autoFarmLevel = restoreAutoFL
		return true
	end

	-- ═══════════════════════════ QUEST ATLAS ═══════════════════════════
	-- Sea 1 quest progression with taskCount from the live Quests module.
	-- Faction-Specific note: BanditQuest1 works on Pirate Starter,
	-- MarineQuest works on Marine Starter. Both give the same XP.
	-- If a questId fires and the server ignores it (no-accept), we log it
	-- and the user adjusts the row.
	-- Atlas synced against ReplicatedStorage.Quests live data — captures
	-- every tier including tier-3 boss rounds that the original atlas
	-- missed (Swan, Gorilla King, Chef, Yeti, Vice Admiral, Magma Admiral,
	-- Fishman Lord, Cyborg). LevelReq values from the game's quest module
	-- are the MINIMUM accept level — lvlMax in each row is set to (next
	-- tier's lvlMin - 1) so pickQuest's forward scan walks naturally.
	local SEA1_QUESTS = {
		{ lvlMin = 1,   lvlMax = 9,   island = "Pirate Starter",  questId = "BanditQuest1",  tier = 1, mob = "Bandit",          taskCount = 5, faction = "Pirates" },
		{ lvlMin = 1,   lvlMax = 9,   island = "Marine Starter",  questId = "MarineQuest",   tier = 1, mob = "Trainee",         taskCount = 5, faction = "Marines" },
		{ lvlMin = 10,  lvlMax = 14,  island = "Jungle",          questId = "JungleQuest",   tier = 1, mob = "Monkey",          taskCount = 6 },
		{ lvlMin = 15,  lvlMax = 19,  island = "Jungle",          questId = "JungleQuest",   tier = 2, mob = "Gorilla",         taskCount = 8 },
		{ lvlMin = 20,  lvlMax = 29,  island = "Jungle",          questId = "JungleQuest",   tier = 3, mob = "Gorilla King",    taskCount = 1, boss = true },
		{ lvlMin = 30,  lvlMax = 39,  island = "Pirate Village",  questId = "BuggyQuest1",   tier = 1, mob = "Pirate",          taskCount = 8 },
		{ lvlMin = 40,  lvlMax = 54,  island = "Pirate Village",  questId = "BuggyQuest1",   tier = 2, mob = "Brute",           taskCount = 8 },
		{ lvlMin = 55,  lvlMax = 59,  island = "Pirate Village",  questId = "BuggyQuest1",   tier = 3, mob = "Chef",            taskCount = 1, boss = true },
		{ lvlMin = 60,  lvlMax = 74,  island = "Desert",          questId = "DesertQuest",   tier = 1, mob = "Desert Bandit",   taskCount = 8 },
		{ lvlMin = 75,  lvlMax = 89,  island = "Desert",          questId = "DesertQuest",   tier = 2, mob = "Desert Officer",  taskCount = 6 },
		{ lvlMin = 90,  lvlMax = 99,  island = "Frozen Village",  questId = "SnowQuest",     tier = 1, mob = "Snow Bandit",     taskCount = 7 },
		{ lvlMin = 100, lvlMax = 104, island = "Frozen Village",  questId = "SnowQuest",     tier = 2, mob = "Snowman",         taskCount = 8 },
		{ lvlMin = 105, lvlMax = 119, island = "Frozen Village",  questId = "SnowQuest",     tier = 3, mob = "Yeti",            taskCount = 1, boss = true },
		{ lvlMin = 120, lvlMax = 129, island = "Marine Fortress", questId = "MarineQuest2",  tier = 1, mob = "Chief Petty Officer", taskCount = 8 },
		{ lvlMin = 130, lvlMax = 149, island = "Marine Fortress", questId = "MarineQuest2",  tier = 2, mob = "Vice Admiral",    taskCount = 1, boss = true },
		{ lvlMin = 150, lvlMax = 174, island = "Skylands",        questId = "SkyQuest",      tier = 1, mob = "Sky Bandit",      taskCount = 7 },
		{ lvlMin = 175, lvlMax = 189, island = "Skylands",        questId = "SkyQuest",      tier = 2, mob = "Dark Master",     taskCount = 8 },
		{ lvlMin = 190, lvlMax = 209, island = "Prison",          questId = "PrisonerQuest", tier = 1, mob = "Prisoner",          taskCount = 8 },
		{ lvlMin = 210, lvlMax = 219, island = "Prison",          questId = "PrisonerQuest", tier = 2, mob = "Dangerous Prisoner", taskCount = 8 },
		{ lvlMin = 220, lvlMax = 229, island = "Prison",          questId = "ImpelQuest",    tier = 1, mob = "Warden",            taskCount = 1, boss = true },
		{ lvlMin = 230, lvlMax = 239, island = "Prison",          questId = "ImpelQuest",    tier = 2, mob = "Chief Warden",      taskCount = 1, boss = true },
		{ lvlMin = 240, lvlMax = 249, island = "Prison",          questId = "ImpelQuest",    tier = 3, mob = "Swan",              taskCount = 1, boss = true },
		{ lvlMin = 250, lvlMax = 274, island = "Prison",          questId = "ColosseumQuest",tier = 1, mob = "Toga Warrior",    taskCount = 7 },
		{ lvlMin = 275, lvlMax = 299, island = "Prison",          questId = "ColosseumQuest",tier = 2, mob = "Gladiator",       taskCount = 8 },
		{ lvlMin = 300, lvlMax = 324, island = "Magma Village",   questId = "MagmaQuest",    tier = 1, mob = "Military Soldier", taskCount = 7 },
		{ lvlMin = 325, lvlMax = 349, island = "Magma Village",   questId = "MagmaQuest",    tier = 2, mob = "Military Spy",     taskCount = 8 },
		{ lvlMin = 350, lvlMax = 374, island = "Magma Village",   questId = "MagmaQuest",    tier = 3, mob = "Magma Admiral",   taskCount = 1, boss = true },
		{ lvlMin = 375, lvlMax = 399, island = "Underwater City", questId = "FishmanQuest",  tier = 1, mob = "Fishman Warrior", taskCount = 8 },
		{ lvlMin = 400, lvlMax = 424, island = "Underwater City", questId = "FishmanQuest",  tier = 2, mob = "Fishman Commando",taskCount = 7 },
		{ lvlMin = 425, lvlMax = 624, island = "Underwater City", questId = "FishmanQuest",  tier = 3, mob = "Fishman Lord",    taskCount = 1, boss = true },
		{ lvlMin = 625, lvlMax = 649, island = "Fountain City",   questId = "FountainQuest", tier = 1, mob = "Galley Pirate",   taskCount = 8 },
		{ lvlMin = 650, lvlMax = 674, island = "Fountain City",   questId = "FountainQuest", tier = 2, mob = "Galley Captain",  taskCount = 9 },
		{ lvlMin = 675, lvlMax = 999, island = "Fountain City",   questId = "FountainQuest", tier = 3, mob = "Cyborg",          taskCount = 1, boss = true },
	}

	-- Picks the highest-level-fit quest for a given player level.
	-- Iterates forward so higher-tier rows (later in the atlas) win when
	-- multiple match. With cfg.skipBossQuests on, boss rows are filtered:
	-- the user prefers to keep grinding regular mob quests (~5-9 mobs per
	-- cycle, fast XP) over Warden / Chief Warden quests (1 boss kill but
	-- ~5min spawn timer per the user's estimate). When the current level
	-- range is ALL boss, fall back to the highest-lvlMin non-boss row our
	-- level still qualifies for — so at Lv 220-249 we keep farming
	-- Dangerous Prisoners (lvlMin=210) instead of idling for Wardens.
	-- Skip a quest whose faction doesn't match ours. The Lv 1-9 starter
	-- quests are faction-locked: a Pirate can only take the Bandit quest at
	-- Pirate Starter, a Marine only the Trainee quest at Marine Starter.
	-- Without this the forward scan always lands on Trainee (it's the later
	-- row) and a fresh Pirate gets dragged 3.7K studs to Marine Starter for a
	-- quest the NPC won't give. Team.Name is the source of truth ("Pirates" /
	-- "Marines"); if it's momentarily nil we don't filter (old behaviour).
	local function _wrongFaction(q)
		if not q.faction then return false end
		local t = LocalPlayer.Team
		return t ~= nil and t.Name ~= q.faction
	end

	local function pickQuest(level)
		local best
		for _, q in ipairs(SEA1_QUESTS) do
			if level >= q.lvlMin and level <= q.lvlMax and not _wrongFaction(q) then
				if not (cfg.skipBossQuests and q.boss) then
					best = q
				end
			end
		end
		-- Filtered out the only in-range row(s) — walk backward for the
		-- nearest non-boss quest whose minimum level we exceed. ipairs
		-- order is the atlas order (low → high level), so iterating from
		-- the end gives us the highest-level non-boss tier we qualify for.
		if not best and cfg.skipBossQuests then
			for i = #SEA1_QUESTS, 1, -1 do
				local q = SEA1_QUESTS[i]
				if not q.boss and level >= q.lvlMin and not _wrongFaction(q) then
					best = q
					break
				end
			end
		end
		return best
	end

	-- Are we close enough to the island to consider ourselves "there"?
	-- XZ-only distance — island.pos.Y is the bbox top, but the player
	-- stands on the ground far below, so a 3D check would always fail
	-- for tall/sky islands.
	local function atIsland(name)
		local island = ISLAND_BY_NAME[name]
		if not island then return false end
		local ch = LocalPlayer.Character
		local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
		if not hrp then return false end
		local dx = hrp.Position.X - island.pos.X
		local dz = hrp.Position.Z - island.pos.Z
		local radius = island.atRadius or 350
		return math.sqrt(dx * dx + dz * dz) < radius
	end

	-- ═══════════════════════════ QUEST LIFECYCLE ═══════════════════════════
	-- Tracks the active quest, kill progress toward completion, and when
	-- the task count is met the autoFarmLevelLoop advances to the next tier.
	-- Kill counting happens inside autoFarmLoop (death event).

	-- Current quest state. Reset when quest completes or level changes.
	local Q = {
		current   = nil,       -- the active SEA1_QUESTS row
		kills     = 0,         -- kills of the quest mob this cycle
		accepted  = false,     -- whether we've fired StartQuest this cycle
		lastLevel = 0,         -- Data.Level on last tick
		key       = nil,       -- "questId|tier" composite key
	}

	-- Accept a quest via CommF_:StartQuest and reset the kill counter.
	-- The game's StartQuest remote returns:
	--   0 = SUCCESS  — "Quest accepted"
	--   1 = ERROR    — "An error has occurred" (level/req not met)
	--   2 = DONE     — "You already completed this quest" (advance to next tier)
	-- GetQuestInfo is NOT a valid verification (always returns nil — the game
	-- uses QuestUpdate RemoteEvent for quest state). We trust the return code.
	-- Returns: true if quest was accepted, false otherwise.
	local function acceptQuest(q)
		if not q then return false end
		local key = q.questId .. "|" .. tostring(q.tier)
		if Q.key == key and Q.accepted then return true end  -- already accepted

		local ok, res = pcall(function()
			return R.CommF_:InvokeServer("StartQuest", q.questId, q.tier)
		end)

		if not ok then
			warn("[Vellum BF] StartQuest pcall error for " .. q.questId .. ": " .. tostring(res))
			Q.accepted = false
			Q.key      = nil
			_questFailAt = tick()
			return false
		end

		if res == 0 then
			Q.current   = q
			Q.kills     = 0
			Q.accepted  = true
			Q.key       = key
			_questFailAt = 0
			Toast.show({
				title = "Quest accepted",
				body  = q.mob .. " x" .. q.taskCount .. " (Lv " .. q.lvlMin .. "-" .. q.lvlMax .. ")",
				kind  = "info", duration = 4,
				key   = "q:" .. key,
			})
			return true
		elseif res == 2 then
			Q.current   = q
			Q.kills     = q.taskCount
			Q.accepted  = true
			Q.key       = key
			_questFailAt = 0
			return true
		else
			Q.accepted  = false
			Q.key       = nil
			_questFailAt = tick()
			return false
		end
	end

	-- Drive farm filters to match the quest target.
	local function applyQuestFilters(q)
		cfg.farmTargetName = q.mob
		cfg.farmLevelMin   = q.lvlMin
		cfg.farmLevelMax   = q.lvlMax + 5
	end

	-- Read the server's authoritative quest state from the Quest HUD.
	-- The HUD frame at PlayerGui.Main.Quest has Visible=true ONLY when a
	-- quest is currently active on the server. The Title.Text *persists*
	-- with the last-shown value even after the quest ends (verified live:
	-- after quest completion, Visible flipped to false but Title.Text
	-- still read "Defeat 8 Prisoners (7/8)"). So we MUST gate on Visible,
	-- not on whether the text parses.
	--
	-- Returns:
	--   {current=N, target=M, raw=text} — quest active and parsed
	--   nil — no quest active OR HUD structure unreadable
	local function readServerQuest()
		local pgui = LocalPlayer:FindFirstChild("PlayerGui")
		local main = pgui and pgui:FindFirstChild("Main")
		local quest = main and main:FindFirstChild("Quest")
		if not quest or not quest.Visible then return nil end
		local cont  = quest:FindFirstChild("Container")
		local qt    = cont and cont:FindFirstChild("QuestTitle")
		local title = qt and qt:FindFirstChild("Title")
		if not title or not title:IsA("TextLabel") then return nil end
		local text = title.Text
		if not text or text == "" then return nil end
		local cur, tgt = text:match("%((%d+)%s*/%s*(%d+)%)")
		if not cur then return nil end
		return { current = tonumber(cur), target = tonumber(tgt), raw = text }
	end

	-- True if the HUD-displayed quest matches our target quest. We match
	-- on the LAST WORD of quest.mob to tolerate BF's two name conventions:
	--   workspace.Enemies model name: "Military Soldier"
	--   HUD quest text:               "Defeat 7 Mil. Soldiers (0/7)"
	-- Substring of full quest.mob would miss because HUD abbreviates
	-- ("Mil." vs "Military"). Last-word match works because the trailing
	-- noun ("Soldier", "Prisoner", "Master", "Bandit") is what BF
	-- pluralizes in the HUD, never abbreviates. Level-range gating in
	-- pickQuest prevents ambiguous trailing words (Snow Bandit + Desert
	-- Bandit are never both active simultaneously).
	local function hudIsQuest(srv, quest)
		if not srv or not quest then return false end
		local mob = quest.mob or ""
		-- Pull the last word — split on space, take rightmost
		local lastWord = mob:match("(%S+)$") or mob
		return srv.raw:find(lastWord, 1, true) ~= nil
	end

	-- Kill-counter update. We keep Q.kills as a local mirror but the SERVER is
	-- the source of truth (read via readServerQuest). The local counter is only
	-- used as a fast fallback if the HUD probe fails.
	local function recordQuestKill(enemyName)
		if not Q.current then return end
		if enemyName == Q.current.mob then
			Q.kills = Q.kills + 1
		end
	end

	-- Quest "complete and turned in" — used by autoFarmLevelLoop to know
	-- when to re-accept. Two completion signals:
	--   (a) HUD shows our quest at N >= M (caught the last frame before BF
	--       hides the HUD — rare but possible)
	--   (b) HUD is hidden AND we had a non-trivial kill count locally
	--       (BF auto-completes and hides the HUD; the persistent text is
	--       stale, so we trust local Q.kills as the post-mortem signal)
	local function questIsComplete()
		if not Q.current then return false end
		local srv = readServerQuest()
		if srv and hudIsQuest(srv, Q.current) then
			return srv.current >= srv.target
		end
		-- HUD hidden / unrelated quest showing — fall back to local count.
		-- Only fires if recordQuestKill actually counted some of our kills.
		return Q.kills >= Q.current.taskCount
	end

	-- ═══════════════════════════ ISLAND ESP ═══════════════════════════
	-- One billboard per island, group "islands". Re-anchored to a small
	-- invisible BasePart at the island's pos so the BillboardGui has
	-- something concrete to attach to (BillboardGui.Adornee needs a part).
	local espAnchors = {}  -- name → Part
	local function buildIslandESP()
		ESP.detachGroup("islands")
		for _, c in pairs(espAnchors) do if c.Parent then c:Destroy() end end
		espAnchors = {}
		if not cfg.espIslands then return end

		for _, island in ipairs(ISLANDS) do
			local anchor = Instance.new("Part")
			anchor.Name = "Vellum_IslandAnchor_" .. island.name
			anchor.Size = Vector3.new(1, 1, 1)
			anchor.Anchored = true
			anchor.CanCollide = false
			anchor.Transparency = 1
			anchor.Position = island.pos + Vector3.new(0, 60, 0)
			anchor.Parent = workspace
			espAnchors[island.name] = anchor
			ESP.billboard({
				adornee = anchor,
				text    = island.name,
				sub     = island.lvlRange,
				color   = Color3.fromRGB(220, 200, 140),
				group   = "islands",
				yOffset = 0,
			})
		end
	end

	-- ═══════════════════════════ DYNAMIC ESP ═══════════════════════════
	-- Per-group tracker registries. Each scanner maintains its own table
	-- of { [instanceKey] = entry } where entry holds handles + cached
	-- payload functions so we can update the card in place instead of
	-- rebuilding it every tick (cheap text/bar refreshes, expensive
	-- BillboardGui instantiation).
	local _espTrackers = {}

	local function _espGet(group)
		_espTrackers[group] = _espTrackers[group] or {}
		return _espTrackers[group]
	end

	local function _espDetachEntry(group, key)
		local t = _espGet(group)
		local entry = t[key]
		if not entry then return end
		if entry.cardHandle then ESP.detach(entry.cardHandle) end
		if entry.hlHandle   then ESP.detach(entry.hlHandle)   end
		t[key] = nil
	end

	local function _espDetachAll(group)
		local t = _espGet(group)
		for key in pairs(t) do _espDetachEntry(group, key) end
	end

	-- Squared distance from LocalPlayer HRP. nil if no character.
	local function _distFromMe(part)
		local ch = LocalPlayer.Character
		local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
		if not hrp or not part then return nil end
		return (part.Position - hrp.Position).Magnitude
	end

	-- ─── PLAYER ESP ───
	-- Card per other player. Reads Data.Race + Data.DevilFruit + Level
	-- from the player's public Data folder (verified — the server
	-- mirrors these to every client). Team color: same-team green,
	-- hostile red. Skips LocalPlayer.
	local function _playerColor(plr)
		if plr.Team and LocalPlayer.Team and plr.Team == LocalPlayer.Team then
			return Color3.fromRGB(120, 220, 120)
		end
		return Color3.fromRGB(255, 90, 90)
	end

	local function _playerLine(plr, dist)
		local data = plr:FindFirstChild("Data")
		local lvl  = data and data:FindFirstChild("Level") and data.Level.Value or "?"
		local race = data and data:FindFirstChild("Race") and tostring(data.Race.Value) or ""
		local fruit = data and data:FindFirstChild("DevilFruit") and tostring(data.DevilFruit.Value) or ""
		local title = string.format("%s   Lv %s", plr.DisplayName or plr.Name, tostring(lvl))
		local sub
		if race ~= "" and fruit ~= "" then sub = race .. " • " .. fruit
		elseif fruit ~= "" then sub = fruit
		elseif race ~= "" then sub = race
		else sub = "—" end
		local caption = string.format("%d studs", dist or 0)
		return title, sub, caption
	end

	local function scanPlayerESP()
		local t = _espGet("players")
		if not cfg.espPlayers then _espDetachAll("players"); return end
		local Players = game:GetService("Players")
		local seen = {}
		for _, plr in ipairs(Players:GetPlayers()) do
			if plr ~= LocalPlayer then
				local ch = plr.Character
				local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
				local hum = ch and ch:FindFirstChild("Humanoid")
				if hrp and hum and hum.Health > 0 then
					local dist = _distFromMe(hrp) or 0
					if cfg.espMaxDist > 0 and dist > cfg.espMaxDist then
						_espDetachEntry("players", plr)
					else
						seen[plr] = true
						local color = _playerColor(plr)
						local title, sub, caption = _playerLine(plr, dist)
						local entry = t[plr]
						if not entry or entry.char ~= ch then
							-- New player OR character rebuilt → tear down + rebuild
							if entry then _espDetachEntry("players", plr) end
							local cardH, cardP = ESP.card({
								adornee = hrp, accent = color, group = "players",
								title = title, subtitle = sub, caption = caption,
								bar = { current = hum.Health, max = hum.MaxHealth },
							})
							local hlH = ESP.highlight({
								adornee = ch, color = color,
								fillTransparency = 0.85, outlineTransparency = 0.05,
								group = "players",
							})
							t[plr] = { cardHandle = cardH, hlHandle = hlH, card = cardP, char = ch }
						else
							entry.card.setLines(title, sub, caption)
							entry.card.setBar(hum.Health, hum.MaxHealth)
						end
					end
				end
			end
		end
		for key in pairs(t) do if not seen[key] then _espDetachEntry("players", key) end end
	end

	-- ─── CHEST ESP ───
	-- workspace.ChestModels — Silver / Gold / Diamond drop on server timer.
	-- Simpler card (no HP, no level). Tier-colored.
	local function _chestColor(name)
		if name:find("Diamond") then return Color3.fromRGB(120, 230, 255) end
		if name:find("Gold")    then return Color3.fromRGB(255, 215,  80) end
		return Color3.fromRGB(220, 220, 220) -- silver / default
	end

	local function _chestLabel(name)
		-- "SilverChest" → "Silver Chest"
		return (name:gsub("(%l)(%u)", "%1 %2"))
	end

	local function scanChestESP()
		local t = _espGet("chests")
		if not cfg.espChests then _espDetachAll("chests"); return end
		local container = workspace:FindFirstChild("ChestModels")
		if not container then return end
		local seen = {}
		for _, c in ipairs(container:GetChildren()) do
			local part = c:IsA("BasePart") and c or c:FindFirstChildWhichIsA("BasePart")
			if part then
				local dist = _distFromMe(part) or 0
				if cfg.espMaxDist > 0 and dist > cfg.espMaxDist then
					_espDetachEntry("chests", c)
				else
					seen[c] = true
					local entry = t[c]
					if not entry then
						local color = _chestColor(c.Name)
						local cardH, cardP = ESP.card({
							adornee = part, accent = color, group = "chests",
							title = _chestLabel(c.Name),
							caption = string.format("%d studs", dist),
						})
						t[c] = { cardHandle = cardH, card = cardP }
					else
						entry.card.setLines(nil, nil, string.format("%d studs", dist))
					end
				end
			end
		end
		for key in pairs(t) do if not seen[key] then _espDetachEntry("chests", key) end end
	end

	-- ─── BOSS ESP ───
	-- High-HP enemies + named bosses. Amber accent, HP bar.
	local BOSS_NAMES = {
		["Yeti"]=true, ["Mr. Officer"]=true, ["Tide Keeper"]=true,
		["Magma Admiral"]=true, ["Cursed Captain"]=true, ["Greybeard"]=true,
		["Diamond"]=true, ["Smoke Admiral"]=true, ["Awakened Ice Admiral"]=true,
		["Mihawk"]=true, ["Don Swan"]=true, ["Cyborg"]=true, ["Stone"]=true,
		["Royal Pirate Captain"]=true, ["King Red Head"]=true, ["Bobby"]=true,
		["Saber Expert"]=true, ["Warden"]=true, ["Chief Warden"]=true,
		["Swan"]=true, ["Vice Admiral"]=true, ["Fishman Lord"]=true,
		["Wysper"]=true, ["Thunder God"]=true, ["Cyborg V2"]=true,
		["Soul Reaper"]=true, ["Gorilla King"]=true, ["Chef"]=true,
		["Ship Steerer"]=true, ["rip_indra True Form"]=true,
	}

	local function _isBoss(e, hum)
		if BOSS_NAMES[e.Name] then return true end
		if hum and hum.MaxHealth > 5000 then return true end
		return false
	end

	local function scanBossESP()
		local t = _espGet("bosses")
		if not cfg.espBosses then _espDetachAll("bosses"); return end
		local enemies = workspace:FindFirstChild("Enemies")
		if not enemies then return end
		local seen = {}
		local AMBER = Color3.fromRGB(255, 170, 60)
		for _, e in ipairs(enemies:GetChildren()) do
			local hum = e:FindFirstChild("Humanoid")
			local hrp = e:FindFirstChild("HumanoidRootPart")
			if hrp and hum and hum.Health > 0 and _isBoss(e, hum) then
				local dist = _distFromMe(hrp) or 0
				if cfg.espMaxDist > 0 and dist > cfg.espMaxDist then
					_espDetachEntry("bosses", e)
				else
					seen[e] = true
					local lvl = e:GetAttribute("Level") or "?"
					local sub = string.format("Lv %s • %d studs", tostring(lvl), dist)
					local entry = t[e]
					if not entry then
						local cardH, cardP = ESP.card({
							adornee = hrp, accent = AMBER, group = "bosses",
							title = e.Name, subtitle = sub,
							bar = { current = hum.Health, max = hum.MaxHealth },
						})
						local hlH = ESP.highlight({
							adornee = e, color = AMBER,
							fillTransparency = 0.75, outlineTransparency = 0.05,
							group = "bosses",
						})
						t[e] = { cardHandle = cardH, hlHandle = hlH, card = cardP }
					else
						entry.card.setLines(nil, sub, nil)
						entry.card.setBar(hum.Health, hum.MaxHealth)
					end
				end
			end
		end
		for key in pairs(t) do if not seen[key] then _espDetachEntry("bosses", key) end end
	end

	-- ─── DEVIL FRUIT ESP ───
	-- Dropped fruits live in workspace.Characters as models named
	-- "bloxfruit<spawnerID>". The actual fruit ID is on the inner Tool
	-- (e.g. "Mera-Mera" or "Buddha-Buddha"). We display the fruit ID
	-- so the user can hunt the specific one they want. Pink accent.
	local function _fruitName(model)
		-- Look for the Tool inside the model; its Name is the fruit ID.
		for _, c in ipairs(model:GetChildren()) do
			if c:IsA("Tool") and c.Name:find("-") then
				-- "Mera-Mera" → "Mera Mera" (more readable)
				return (c.Name:gsub("-", " "))
			end
		end
		-- Fallback: attribute lookup (BF may stash it as an attr on the model)
		local attr = model:GetAttribute("FruitName") or model:GetAttribute("Fruit")
		if attr and tostring(attr) ~= "" then return tostring(attr) end
		return "Devil Fruit"
	end

	local function scanFruitESP()
		local t = _espGet("fruits")
		if not cfg.espFruits then _espDetachAll("fruits"); return end
		local container = workspace:FindFirstChild("Characters")
		if not container then return end
		local PINK = Color3.fromRGB(255, 130, 230)
		local seen = {}
		for _, c in ipairs(container:GetChildren()) do
			if c.Name:sub(1, 9):lower() == "bloxfruit" then
				local part = c:FindFirstChild("Handle") or c:FindFirstChildWhichIsA("BasePart")
				if part then
					local dist = _distFromMe(part) or 0
					if cfg.espMaxDist > 0 and dist > cfg.espMaxDist then
						_espDetachEntry("fruits", c)
					else
						seen[c] = true
						local entry = t[c]
						if not entry then
							local cardH, cardP = ESP.card({
								adornee = part, accent = PINK, group = "fruits",
								title = _fruitName(c),
								caption = string.format("%d studs", dist),
							})
							local hlH = ESP.highlight({
								adornee = c, color = PINK,
								fillTransparency = 0.65, outlineTransparency = 0.0,
								group = "fruits",
							})
							t[c] = { cardHandle = cardH, hlHandle = hlH, card = cardP }
						else
							entry.card.setLines(nil, nil, string.format("%d studs", dist))
						end
					end
				end
			end
		end
		for key in pairs(t) do if not seen[key] then _espDetachEntry("fruits", key) end end
	end

	-- ─── TRACERS ───
	-- Drawing.Line from screen-center to each ESP target. Color matches
	-- the target's group: red player, amber boss, green quest mob, pink
	-- fruit, cyan chest. Auto-hides for offscreen targets. Per-frame
	-- update via Heartbeat — Drawing API is GPU-accelerated, cheap.
	local _tracers = {} -- adornee -> Drawing.Line
	local _tracerConn

	local function _tracerColor(group)
		if group == "players"  then return Color3.fromRGB(255,  90,  90) end
		if group == "bosses"   then return Color3.fromRGB(255, 170,  60) end
		if group == "questmob" then return Color3.fromRGB(120, 255, 140) end
		if group == "fruits"   then return Color3.fromRGB(255, 130, 230) end
		if group == "chests"   then return Color3.fromRGB(120, 230, 255) end
		return Color3.fromRGB(220, 220, 220)
	end

	local function _detachAllTracers()
		for k, line in pairs(_tracers) do
			pcall(function() line.Visible = false; line:Remove() end)
			_tracers[k] = nil
		end
	end

	local function _tracerFrame()
		if not cfg.espTracers then _detachAllTracers(); return end
		if type(Drawing) ~= "table" or type(Drawing.new) ~= "function" then return end
		local camera = workspace.CurrentCamera
		if not camera then return end
		local viewSize = camera.ViewportSize
		local origin = Vector2.new(viewSize.X * 0.5, viewSize.Y)
		local seen = {}

		-- Walk every active ESP tracker group that has a worldspace adornee
		for groupName, members in pairs(_espTrackers) do
			for key, entry in pairs(members) do
				local card = entry.card and entry.card.instance
				local adornee = card and card.Adornee
				if adornee and adornee:IsA("BasePart") then
					local screen, onScreen = camera:WorldToViewportPoint(adornee.Position)
					if onScreen then
						seen[adornee] = true
						local line = _tracers[adornee]
						if not line then
							line = Drawing.new("Line")
							line.Thickness = 1.5
							line.Transparency = 0.85
							_tracers[adornee] = line
						end
						line.From = origin
						line.To = Vector2.new(screen.X, screen.Y)
						line.Color = _tracerColor(groupName)
						line.Visible = true
					end
				end
			end
		end

		-- Hide tracers for adornees that aren't tracked this frame
		for key, line in pairs(_tracers) do
			if not seen[key] then line.Visible = false end
		end
	end

	-- ─── QUEST MOB ESP ───
	-- Pure highlight, no card — would clutter combat. Bright green outline
	-- on every alive instance of Q.current.mob.
	local function scanQuestMobESP()
		local t = _espGet("questmob")
		if not cfg.espQuestMob or not Q.current then _espDetachAll("questmob"); return end
		local mobName = Q.current.mob
		local enemies = workspace:FindFirstChild("Enemies")
		if not enemies then return end
		local GREEN = Color3.fromRGB(120, 255, 140)
		local seen = {}
		for _, e in ipairs(enemies:GetChildren()) do
			if e.Name == mobName then
				local hum = e:FindFirstChild("Humanoid")
				if hum and hum.Health > 0 then
					seen[e] = true
					if not t[e] then
						local hlH = ESP.highlight({
							adornee = e, color = GREEN,
							fillTransparency = 0.8, outlineTransparency = 0.0,
							group = "questmob",
						})
						t[e] = { hlHandle = hlH }
					end
				end
			end
		end
		for key in pairs(t) do if not seen[key] then _espDetachEntry("questmob", key) end end
	end

	-- Single 1Hz scan thread. Fans out to every ESP scanner. Each scanner
	-- short-circuits on its own cfg flag, so leaving them all off costs
	-- only a handful of function calls per second.
	local function espScanLoop()
		while _running do
			safe(scanPlayerESP)
			safe(scanChestESP)
			safe(scanBossESP)
			safe(scanFruitESP)
			safe(scanQuestMobESP)
			task.wait(1.0)
		end
	end

	-- Tracers run per-frame (Heartbeat) because lines need to track the
	-- camera, not the once-a-second scan tick. _tracerFrame internally
	-- short-circuits when cfg.espTracers is off and the Drawing API is
	-- missing — connecting once at module init is safe.
	RunService.Heartbeat:Connect(function() safe(_tracerFrame) end)

	-- ═══════════════════════════ FRUIT SNIPER ═══════════════════════════
	-- Watches workspace.Characters for new bloxfruit* models. When one
	-- matches the user's snipe criteria, pauses auto-farm, multi-hop tweens
	-- to the Handle, lets natural collision pickup grab it, resumes farm.
	--
	-- Safety:
	--   - Pickup is collision-only — we never fire a remote. BF's natural
	--     Tool.Handle.Touched moves the Tool into our Backpack server-side.
	--     Hubs that fire pickup remotes get users kicked; we don't.
	--   - Movement uses _tweenHRPTo's segmented tween (verified survives
	--     anti-cheat up to 60K studs). Same path tpToIsland uses.
	--   - cfg.snipeMaxDist gates extreme cross-server flights.
	--   - Pauses autoFarm (sets _tpInProgress) so the farm loop doesn't
	--     fight us mid-snipe. Restores on completion or timeout.
	--   - Single-flight queue: only one snipe in progress at a time. New
	--     fruits during a snipe queue behind the current one.

	-- Common fruits worth skipping. Inventory junk that slows down rare
	-- pickups when FruitCap=1 and we'd have to drop them anyway.
	local COMMON_FRUITS = {
		["Bomb-Bomb"] = true, ["Spike-Spike"] = true, ["Spring-Spring"] = true,
		["Chop-Chop"] = true, ["Smoke-Smoke"] = true, ["Spin-Spin"] = true,
		["Flame-Flame"] = true, ["Bird-Bird"] = true, ["Kilo-Kilo"] = true,
		["Rocket-Rocket"] = true, ["Wolf-Wolf"] = true,
	}

	-- Extract the fruit ID from a workspace.Characters model. The Tool
	-- inside is named like "Mera-Mera" / "Buddha-Buddha". Returns nil if
	-- the model isn't a fruit (or hasn't loaded yet).
	local function _fruitIdOf(model)
		for _, c in ipairs(model:GetChildren()) do
			if c:IsA("Tool") and c.Name:find("-") then
				return c.Name
			end
		end
		return nil
	end

	-- Should the sniper bite this one? Gates on master toggle, common
	-- filter, and distance.
	local function _shouldSnipe(model)
		if not cfg.fruitSniper then return false end
		local fid = _fruitIdOf(model)
		if not fid then return false end
		if cfg.snipeSkipCommons and COMMON_FRUITS[fid] then return false end
		local handle = model:FindFirstChild("Handle") or model:FindFirstChildWhichIsA("BasePart")
		if not handle then return false end
		local dist = _distFromMe(handle)
		if not dist then return false end
		if cfg.snipeMaxDist > 0 and dist > cfg.snipeMaxDist then return false end
		return true, fid, handle
	end

	local _snipeBusy = false
	local _snipeQueue = {}

	local function _runSnipe(model, fid, handle)
		_snipeBusy = true
		local ch = LocalPlayer.Character
		local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
		if not hrp then _snipeBusy = false; return end

		Toast.show({
			title = "Sniping",
			body  = fid:gsub("-", " ") .. "  •  " .. math.floor(_distFromMe(handle) or 0) .. " studs",
			kind  = "info", duration = 3,
			key   = "snipe:" .. fid,
		})

		-- Pause autoFarm and tear down flight, mirroring tpToIsland's setup.
		-- Without this the BodyPosition fights the tween → BF rolls back the
		-- character → kick risk. This is the lesson from the Colosseum bug.
		local restoreAutoFarm = cfg.autoFarm
		local restoreAutoFL   = cfg.autoFarmLevel
		_tpInProgress = true
		cfg.autoFarm = false
		cfg.autoFarmLevel = false
		safe(_stopFlightFn)

		-- Target the Handle's CURRENT position each hop (fruits can drift
		-- slightly via physics if BF doesn't anchor them perfectly).
		local arrived = false
		for attempt = 1, 3 do
			if not handle or not handle.Parent then break end
			if not model or not model.Parent then break end  -- already picked up
			local dest = handle.Position + Vector3.new(0, 2, 0)
			safe(function() _tweenHRPTo(hrp, dest) end)
			-- Give Tool.Handle.Touched a moment to fire server-side
			task.wait(0.4)
			if not model.Parent then arrived = true; break end
			-- Still in workspace? Maybe we landed just outside the touch
			-- radius. Try a tiny nudge directly onto the Handle.
			if hrp and handle and handle.Parent then
				local d = (handle.Position - hrp.Position).Magnitude
				if d > 8 then
					-- Far miss — retry tween next loop
				else
					-- Close — nudge directly to the Handle
					hrp.CFrame = CFrame.new(handle.Position + Vector3.new(0, 1, 0))
					task.wait(0.5)
					if not model.Parent then arrived = true; break end
				end
			end
		end

		_tpInProgress = false
		cfg.autoFarm = restoreAutoFarm
		cfg.autoFarmLevel = restoreAutoFL
		safe(startFlight)

		if arrived then
			Toast.show({
				title = "Grabbed",
				body  = fid:gsub("-", " "),
				kind  = "success", duration = 4,
				key   = "snipe:grab:" .. fid,
			})
		end
		_snipeBusy = false
	end

	local function _trySnipe(model)
		if _snipeBusy then table.insert(_snipeQueue, model); return end
		local ok, fid, handle = _shouldSnipe(model)
		if ok then _runSnipe(model, fid, handle) end
	end

	-- Drain the queue after each snipe completes.
	task.spawn(function()
		while _running do
			if not _snipeBusy and #_snipeQueue > 0 then
				local model = table.remove(_snipeQueue, 1)
				if model and model.Parent then
					local ok, fid, handle = _shouldSnipe(model)
					if ok then _runSnipe(model, fid, handle) end
				end
			end
			task.wait(0.5)
		end
	end)

	-- ChildAdded fires the moment BF parents a new fruit. Cheaper and
	-- more responsive than scanning every tick. We also do a one-shot
	-- pass at script load for any fruits already on the ground.
	local charactersFolder = workspace:FindFirstChild("Characters")
	if charactersFolder then
		charactersFolder.ChildAdded:Connect(function(model)
			-- BF parents the Model first, then populates children. Wait a
			-- bit so _fruitIdOf can find the inner Tool.
			task.wait(0.6)
			if model.Parent and model.Name:sub(1, 9):lower() == "bloxfruit" then
				_trySnipe(model)
			end
		end)
		-- Initial sweep
		task.spawn(function()
			task.wait(2)
			for _, m in ipairs(charactersFolder:GetChildren()) do
				if m.Name:sub(1, 9):lower() == "bloxfruit" then _trySnipe(m) end
			end
		end)
	end

	-- ═══════════════════════════ IMMUNITY DETECTOR ═══════════════════════════
	-- BF hides Buso ownership from the client — no Data.Buso, no attribute,
	-- no remote that returns it. The only reliable signal is the in-game
	-- notification BF pops when we try to physically attack a Logia user
	-- without Buso: 'Enemy is immune to physical attacks!'. We hook the
	-- notification folder for that string, flip _hasBuso=false, drop the
	-- current target, and let pickEnemy's Logia guard route us elsewhere.
	--
	-- Conversely: if we ever observe HP damage on a Logia target, we flip
	-- _hasBuso=true (proven we can hurt them). Done in attackOnce's kill
	-- detection — wired separately.
	local notifFolder = LocalPlayer:WaitForChild("PlayerGui"):FindFirstChild("Notifications")
	if notifFolder then
		notifFolder.ChildAdded:Connect(function(template)
			-- Text may be set after the child is parented — small wait
			task.wait(0.05)
			if not template or not template:IsA("TextLabel") then return end
			local text = (template.Text or ""):lower()
			if text:find("immune to physical") or (text:find("aura") and text:find("purchase")) then
				_hasBuso = false
				if currentTarget then
					-- Drop the Logia target we were attacking; pickEnemy
					-- will route us to a non-Logia or wait at the spawn.
					currentTarget = nil
				end
				Toast.show({
					title = "Buso required",
					body  = "Skipping physical-immune enemies. Unlock Aura/Buso Haki on the Shop tab.",
					kind  = "warn", duration = 6,
					key   = "immune:warn",  -- toast key dedupes, fires once
				})
			end
		end)
	end

	-- ═══════════════════════════ SHOP ═══════════════════════════

	-- Pure remote purchase — no TP needed. Verified live: BuyItem works
	-- from anywhere in the world, the server doesn't check NPC proximity.
	-- Earlier probe bought Triple Katana from Magma while the Master
	-- Sword Dealer was at Skylands; the item still landed in the
	-- backpack.
	--   item     — exact item string the server expects ("Triple Katana")
	--   displayName — for the toast (defaults to item)
	-- Returns true once the item is owned (server code 1 = bought, 2 = already own).
	-- Player level — lets the resolver tell a level gate from a price gate.
	local function _playerLevel()
		local data = LocalPlayer:FindFirstChild("Data")
		local lvl = data and data:FindFirstChild("Level")
		return lvl and lvl.Value or nil
	end

	-- ─── purchase dispatcher ───────────────────────────────────────────────
	-- BF does NOT buy everything through BuyItem. Verified live via the shop
	-- dialogues + the CommF_ check variant:
	--   weapons / fruits / cosmetics → BuyItem(name)    1 bought · 0 broke · 2 own
	--   Haki                          → BuyHaki(name)    (same codes)
	--   boats                         → BuyBoat(name)    (same codes)
	--   fighting styles               → Buy<Style>()     one remote per style;
	--       Buy<Style>(true) is a NON-destructive ownership check (1 = own).
	-- BuyItem returns a GARBAGE "2 (already own)" for style names it doesn't
	-- handle — which is exactly why buying / auto-unlocking a fight style used to
	-- report a false "Already owned". Names below are the ones whose Buy<Style>
	-- remote actually answered live; everything else falls through to BuyItem.
	local BUY_SPECS = {
		["Black Leg"]       = { style = "BuyBlackLeg" },
		["Electro"]         = { style = "BuyElectro" },
		["Fishman Karate"]  = { style = "BuyFishmanKarate" },
		["Dragon Talon"]    = { style = "BuyDragonTalon" },
		["Death Step"]      = { style = "BuyDeathStep" },
		["Sharkman Karate"] = { style = "BuySharkmanKarate" },
		["Electric Claw"]   = { style = "BuyElectricClaw" },
		["Superhuman"]      = { style = "BuySuperhuman" },
		["Godhuman"]        = { style = "BuyGodhuman" },
		["Sanguine Art"]    = { style = "BuySanguineArt" },
		["Buso"]            = { haki = "Buso" },
		["Observation"]     = { haki = "Observation" },
		["Rowboat"]  = { boat = true }, ["Plank Raft"]  = { boat = true },
		["Brigade"]  = { boat = true }, ["Lantern Boat"] = { boat = true },
		["The Swan"] = { boat = true },
	}

	-- Non-destructive check: does the player already know this fighting style?
	local function _styleOwned(cmd)
		local ok, res = pcall(function() return R.CommF_:InvokeServer(cmd, true) end)
		return ok and res == 1
	end

	-- Try to acquire `item` through the right remote. This WILL purchase when
	-- eligible — that's the point. Returns: "owned" | "bought" | "broke" |
	-- "locked" | "err".
	local function _purchase(item)
		local b = BUY_SPECS[item]
		if b and b.style then
			if _styleOwned(b.style) then return "owned" end
			local ok, res = pcall(function() return R.CommF_:InvokeServer(b.style) end)
			if not ok then return "err" end
			if _styleOwned(b.style) then return "bought" end
			return (tonumber(res) == 0) and "broke" or "locked"
		end
		local cmd, arg
		if b and b.haki then cmd, arg = "BuyHaki", b.haki
		elseif b and b.boat then cmd, arg = "BuyBoat", item
		else cmd, arg = "BuyItem", item end
		local ok, res = pcall(function() return R.CommF_:InvokeServer(cmd, arg) end)
		if not ok then return "err" end
		res = tonumber(res)
		if res == 1 then return "bought"
		elseif res == 2 then return "owned"
		elseif res == 0 then return "broke"
		else return "locked" end
	end

	local function shopBuy(npcKey, item, displayName)
		local name = displayName or item
		Toast.show({ title = "Buying", body = name, kind = "info", duration = 2, key = "shop:" .. item })
		local r = _purchase(item)
		local ok = (r == "bought" or r == "owned")
		local tail = (r == "owned") and "  •  already owned"
			or (r == "broke") and "  •  not enough Beli"
			or (r == "locked") and "  •  requirements not met"
			or (r == "err") and "  •  couldn't reach the shop" or ""
		Toast.show({
			title = ok and "Bought" or "Buy failed",
			body  = name .. tail,
			kind  = ok and "success" or "warn", duration = 4, key = "shop:done:" .. item,
		})
		return ok
	end

	-- Live dealer poll — deliberately FAST (~2s) so a snipe fires the instant a
	-- chosen fruit hits the rotation; the whole server races for the same fruit.
	-- ONE loop feeds both the auto-snipe buyer AND the Shop tab's "On Sale Now"
	-- list, so we only hit GetFruits once per tick. The display callback is
	-- wired by the shop UI. The buyer only sweeps when the rotation actually
	-- changes and never re-grabs a fruit it already bought this cycle.
	local _dealerOnSaleCb        -- function(onSaleList) — assigned by the Shop UI
	local _dealerSig = ""
	local _dealerSniped = {}
	task.spawn(function()
		while _running do
			local ok, fruits = pcall(function() return R.CommF_:InvokeServer("GetFruits") end)
			if ok and type(fruits) == "table" then
				local onSale, sig = {}, ""
				for _, f in pairs(fruits) do
					if type(f) == "table" and f.OnSale and f.Name then
						onSale[#onSale + 1] = f
						sig = sig .. f.Name .. "|"
					end
				end
				if sig ~= _dealerSig then
					_dealerSig = sig
					_dealerSniped = {}
					if _dealerOnSaleCb then pcall(_dealerOnSaleCb, onSale) end
				end
				if cfg.dealerSniper and next(cfg.dealerSnipeList) then
					for _, f in ipairs(onSale) do
						if cfg.dealerSnipeList[f.Name] and not _dealerSniped[f.Name] then
							local price = tonumber(f.Price) or 0
							local beli = (LocalPlayer.Data and LocalPlayer.Data.Beli and LocalPlayer.Data.Beli.Value) or 0
							if beli >= price and shopBuy("BloxFruitDealer", f.Name, f.Name:gsub("-", " ")) then
								_dealerSniped[f.Name] = true
							end
						end
					end
				end
			end
			task.wait(2)
		end
	end)

	-- ═══════════════════════════ LOOPS ═══════════════════════════

	-- One always-on flight connection while auto-farm is enabled. Picks
	-- the best target each frame, hovers above it, and when no target
	-- is in range, holds the last altitude (so we don't fall between kills).
	--
	-- Aggressive mode: instead of letting the server reject the hit on
	-- distance, we write the target's HRP to (player.X, target_original_Y,
	-- player.Z) — XZ tracks us, Y stays at ground. This breaks the
	-- "we hover above target, target snaps under us, hover Y rises forever"
	-- feedback loop the previous attempt had.
	local flightConn
	local currentTarget        -- shared with the attack loop
	local lastHoldY            -- Y to hold when no enemy in range
	local targetOriginalY      -- the Y the current target spawned at
	local hoverEnabled = false -- only run flight while auto-farm is on
	local _hoverBP             -- BodyPosition that holds us in the air
	local _hoverBG             -- BodyGyro to keep us upright
	-- _bringBPs declared above before _stopFlightFn

	local function startFlight()
		if _tpInProgress then return end  -- don't start during teleport

		-- Clean sweep: destroy any orphan Vellum_ BPs on HRP that
		-- _stopFlightFn() may have left parented (some executors block
		-- Destroy/Parent=nil). Duplicate BodyPositions fight each other
		-- for HRP control — hover drifts or locks up.
		local ch = LocalPlayer.Character
		local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
		if not hrp then return end
		for _, child in ipairs(hrp:GetChildren()) do
			if child.Name:find("^Vellum_") then
				if child:IsA("BodyGyro") then
					child.MaxTorque = Vector3.new(0, 0, 0)
				elseif child:IsA("BodyMover") then
					child.MaxForce = Vector3.new(0, 0, 0)
				end
				child.Parent = nil
				pcall(function() child:Destroy() end)
			end
		end

		-- Create/recreate BodyPosition if missing (destroyed by _stopFlightFn).
		if not _hoverBP or not _hoverBP.Parent then
			_hoverBP = Instance.new("BodyPosition")
			_hoverBP.Name = "Vellum_HoverBP"
			_hoverBP.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
			_hoverBP.P = 600    -- 5000 was applying insane force (5000N/stud) that
			_hoverBP.D = 80     -- the physics engine had to resolve against every
			                    -- enemy collision body — dropping 60→12 fps.
			_hoverBP.Position = hrp.Position
			_hoverBP.Parent = hrp
		end

		-- Create/recreate BodyGyro if missing.
		if not _hoverBG or not _hoverBG.Parent then
			_hoverBG = Instance.new("BodyGyro")
			_hoverBG.Name = "Vellum_HoverBG"
			_hoverBG.MaxTorque = Vector3.new(math.huge, math.huge, math.huge)
			_hoverBG.P = 1000
			_hoverBG.D = 300
			_hoverBG.CFrame = hrp.CFrame
			_hoverBG.Parent = hrp
		end

		-- Connect Heartbeat ONCE per session. Never disconnected/reconnected
		-- (see _stopFlightFn — it only cleans BPs, not the signal).
		if not flightConn then
			flightConn = RunService.Heartbeat:Connect(function()
				if not (hoverEnabled and cfg.autoFarm) then return end
				if _tpInProgress then return end

				local ch2 = LocalPlayer.Character
				local hrp2 = ch2 and ch2:FindFirstChild("HumanoidRootPart")
				if not hrp2 then return end
				if not _hoverBP or not _hoverBP.Parent then return end
				if not _hoverBG or not _hoverBG.Parent then return end

				-- Maintain noclip: Roblox re-enables CanCollide every physics step
				hrp2.CanCollide = false

				local enemy = (currentTarget and currentTarget.Parent) and currentTarget or nil

				if enemy then
					local ehrp = enemy:FindFirstChild("HumanoidRootPart")
					if ehrp then
						if not targetOriginalY then
							targetOriginalY = ehrp.Position.Y
						end
						local hoverY = targetOriginalY + cfg.farmHeight
						lastHoldY = hoverY
						_hoverBP.Position = Vector3.new(ehrp.Position.X, hoverY, ehrp.Position.Z)

						-- Aggressive range uses enemy CFrame — still technically
						-- detectable by BF. Left as user opt-in.
						if cfg.aggressiveRange then
							ehrp.CFrame = CFrame.new(hrp2.Position.X, targetOriginalY, hrp2.Position.Z)
						end
					end
				else
					targetOriginalY = nil
					local holdY = lastHoldY or hrp2.Position.Y
					_hoverBP.Position = Vector3.new(hrp2.Position.X, holdY, hrp2.Position.Z)
				end
			end)
		end
		hoverEnabled = true

		-- Noclip: disable collision on HRP and all body parts so we pass
		-- through buildings/walls when farming near structures.
		for _, p in ipairs(ch:GetDescendants()) do
			if p:IsA("BasePart") then
				p.CanCollide = false
			end
		end
	end

	local _islandGraceUntil = 0  -- tick() timestamp: skip atIsland TP until this expires
	local _islandGraceName  = "" -- which island the grace is for

	local function autoFarmLevelLoop()
		while _running do
			if _tpInProgress then jwait(1.0) continue end
			if not cfg.autoFarmLevel then
				jwait(1.0)
				continue
			end

			cfg.autoFarm = true

			local data = LocalPlayer:FindFirstChild("Data")
			local levelVal = data and data:FindFirstChild("Level")
			if not levelVal then jwait(3.0); continue end
			local level = levelVal.Value
			Q.lastLevel = level

			local quest = pickQuest(level)

			-- Reset Q only when the QUEST itself changes (different questId+tier),
			-- not on every level change. Killing the quest mob gives XP and often
			-- triggers a level-up mid-quest; the previous code wiped Q.accepted on
			-- every level change, causing the next loop tick to fire StartQuest
			-- again, which the server interprets as "accept this quest from
			-- scratch" — RESETTING the kill counter server-side. That's why we
			-- never finished quests: we kept overwriting our own progress.
			local newKey = quest and (quest.questId .. "|" .. tostring(quest.tier)) or nil
			if Q.key and Q.key ~= newKey then
				Q.accepted = false
				Q.kills    = 0
				Q.current  = nil
				Q.key      = nil
				Q.walkIdx  = nil
				_islandGraceUntil = 0
				currentTarget = nil
				targetOriginalY = nil
			end
			if not quest then
				-- Level past the quest atlas. Auto-farm still runs (simple kill mode).
				if Q.current then
					Toast.show({
						title = "Sea 1 quests exhausted",
						body  = "Level " .. level .. " — continuing in simple kill mode.",
						kind  = "info", duration = 6,
						key   = "q:exhausted",
					})
					Q.current = nil
					Q.accepted = false
					Q.key = nil
				end
				jwait(5.0)
				continue
			end

			-- Lock the enemy filter to THIS quest's mob RIGHT NOW — before any of
			-- the TP/continue branches below. applyQuestFilters used to live at
			-- the very bottom of the loop, which left a window where autoFarm was
			-- already on but farmTargetName was still "" (fresh) or a stale mob.
			-- In that window pickEnemy falls back to the nearest enemy, and at a
			-- shared sub-zone (Fountain City = Galley Captains + the Cyborg boss)
			-- that means flying off to fight a boss the user told us to skip.
			applyQuestFilters(quest)

			-- Quest completion is handled below in the HUD state machine.
			-- The old block here used questIsComplete() which read the HUD,
			-- but it ran BEFORE adopt and nil'd Q.current on every cycle —
			-- which prevented re-accepting the same quest. Re-accept of the
			-- same row is exactly what we want to keep grinding XP.

			-- TP only when we're far from BOTH the island AND any quest mob
			-- spawn. atIsland alone is too coarse — Toga Warriors live in
			-- the Colosseum (~8K studs from Prison.pos) but their quest
			-- island is "Prison". Without the nearQuestSpawn check, the
			-- loop yanked us back to Prison every 60s when grace expired,
			-- even though we WERE farming Togas perfectly fine at their
			-- actual spawn zone.
			local ch = LocalPlayer.Character
			local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
			local atZone = hrp and (atIsland(quest.island) or nearQuestSpawn(quest.mob, hrp, 800))
			local needsTP = not atZone
				and not (_islandGraceName == quest.island and tick() < _islandGraceUntil)
			if needsTP then
				tpToIsland(quest.island)
				_islandGraceUntil = tick() + 60
				_islandGraceName = quest.island
				task.wait(0.8)
				-- NOTE: do NOT clear Q.accepted here. Travelling doesn't
				-- invalidate server-side quest acceptance — clearing it
				-- fires StartQuest twice and resets the server kill counter.
				continue
			end

			-- Arrived — start grace on first pass
			if _islandGraceName ~= quest.island or tick() >= _islandGraceUntil then
				_islandGraceUntil = tick() + 60
				_islandGraceName = quest.island
			end

			-- HUD-first quest state machine. The server's truth is one of:
			--   (a) HUD visible, mob name matches → quest active, sync N
			--   (b) HUD visible, mob name doesn't match → wrong quest, overwrite
			--   (c) HUD hidden → no quest active, accept
			-- We ADOPT (a) into Q regardless of what acceptQuest told us last
			-- time. This is critical because acceptQuest returns 1 when the
			-- quest is already on the server, leaving Q.current=nil — which
			-- then broke kill counting and completion detection.
			local srv = readServerQuest()
			local mine = hudIsQuest(srv, quest)

			if mine then
				Q.current  = quest
				Q.key      = quest.questId .. "|" .. tostring(quest.tier)
				Q.accepted = true
				Q.kills    = srv.current
			end

			-- Completion path A: HUD visible at N/N. Reset accepted so the
			-- next tick re-accepts the SAME quest (pickQuest returns the
			-- same row if level hasn't crossed a boundary — we chain the
			-- same quest for XP until we out-level it).
			if mine and srv.current >= srv.target then
				Toast.show({
					title = "Quest complete",
					body  = quest.mob .. " " .. srv.current .. "/" .. srv.target .. " — re-accepting.",
					kind  = "info", duration = 3,
					key   = "q:done:" .. Q.key,
				})
				Q.accepted = false
				Q.kills    = 0
				-- Keep Q.current / Q.key so the next tick knows what we
				-- were doing. acceptQuest will set them fresh on re-fire.
				jwait(1.0)
				continue
			end

			-- Completion path B: HUD hidden but we counted enough local
			-- kills. BF auto-hides the HUD on turn-in; if we miss the
			-- N/N frame, the local counter is the only signal we have.
			if (not mine) and Q.current and Q.kills >= Q.current.taskCount then
				Toast.show({
					title = "Quest complete",
					body  = Q.current.mob .. " x" .. Q.kills .. " — re-accepting.",
					kind  = "info", duration = 3,
					key   = "q:done-local:" .. tostring(Q.key),
				})
				Q.accepted = false
				Q.kills    = 0
				jwait(0.5)
				continue
			end

			-- Accept when HUD doesn't show our quest. 5s backoff after a
			-- failed accept to absorb the brief window between completion
			-- and the HUD reappearing. Was 60s — way too long; we'd idle
			-- for a full minute every cycle.
			local needAccept = (srv == nil) or (not mine)
			if needAccept and tick() >= _questFailAt + 5 then
				local gotQuest = acceptQuest(quest)
				if not gotQuest then
					_questFailAt = tick()
				end
			end

			-- Walk the quest mob's spawnpoints (agreed design): only ever go to
			-- the QUEST mob, never the nearest ANY enemy. If it isn't spawned yet,
			-- sweep its own spawn anchors one at a time until one appears (BF only
			-- spawns a mob when a player is near its anchor), so we sweep the zone
			-- until it shows and never drift onto the Cyborg boss (or any other
			-- species) that shares the island. Replaces the old centroid-snap,
			-- which parked us at one averaged point that could sit between anchors,
			-- out of every spawn's trigger radius.
			local ch = LocalPlayer.Character
			local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
			if hrp then
				-- Any quest mob alive anywhere? pickEnemy has no distance cap, so
				-- if one exists autoFarmLoop will chase and kill it.
				local enemies = workspace:FindFirstChild("Enemies")
				local anyAlive = false
				if enemies then
					for _, e in ipairs(enemies:GetChildren()) do
						if e.Name == quest.mob then
							local h = e:FindFirstChild("Humanoid")
							if h and h.Health > 0 then anyAlive = true break end
						end
					end
				end

				if anyAlive then
					-- Farm loop handles the kill; pause the walk cursor.
					Q.walkIdx = nil
				else
					-- Nothing spawned: step through this mob's anchors, pausing a
					-- few seconds at each for the server to spawn a wave.
					local anchors = spawnAnchorList(quest.mob)
					if #anchors > 0 then
						if not Q.walkIdx or Q.walkIdx > #anchors then Q.walkIdx = 1 end
						local dest = anchors[Q.walkIdx] + Vector3.new(0, 6, 0)
						local distToDest = (dest - hrp.Position).Magnitude
						if distToDest > 60 then
							-- Travel to this anchor via the same server-accepted noclip
							-- tween tpToIsland uses (no rollback). _tpInProgress pauses
							-- autoFarmLoop so the two loops don't fight over the HRP.
							_tpInProgress = true
							local restoreAuto   = cfg.autoFarm
							local restoreAutoFL = cfg.autoFarmLevel
							cfg.autoFarm = false
							cfg.autoFarmLevel = false
							safe(_stopFlightFn)
							if distToDest < 100 then
								hrp.CFrame = CFrame.new(dest)
							else
								safe(function() _tweenHRPTo(hrp, dest) end)
							end
							-- Hold island grace so the next tick doesn't yank us back to
							-- island.pos mid-sweep.
							_islandGraceUntil = tick() + 60
							_islandGraceName  = quest.island
							cfg.autoFarm = restoreAuto
							cfg.autoFarmLevel = restoreAutoFL
							_tpInProgress = false
							safe(startFlight)
							Q.walkArrivedAt = tick()
						elseif tick() - (Q.walkArrivedAt or 0) > 4 then
							-- Sat here ~4s with no spawn -> next anchor (wrap around).
							Q.walkIdx = (Q.walkIdx % #anchors) + 1
						end
					end
				end
			end
			jwait(3.0)
		end
	end

	-- BF uses ToolTip property to classify weapon types: Melee, Sword, Gun, Blox Fruit.
	-- The hotbar (1/2/3/4) maps to these types. cfg.selectedWeapon stores the ToolTip
	-- value the user wants, and we find the first backpack tool with that ToolTip.

	-- A "tool" is actually equippable if it has a Handle (or explicitly opts
	-- out via RequiresHandle=false) AND a non-empty ToolTip. BF ships an
	-- empty "Tool" placeholder in the backpack (no Handle, no ToolTip,
	-- RequiresHandle=false) that EquipTool silently no-ops on — picking it
	-- as the fallback left the character empty-handed after every respawn.
	local function _isEquippableWeapon(t)
		if not t:IsA("Tool") then return false end
		if not t.ToolTip or t.ToolTip == "" then return false end
		if not t:FindFirstChild("Handle") and t.RequiresHandle then return false end
		return true
	end

	local function ensureWeaponEquipped()
		local ch = LocalPlayer.Character
		if not ch then return nil end
		local hum = ch:FindFirstChildOfClass("Humanoid")
		local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
		if not hum or hum.Health <= 0 then return nil end  -- skip while dead

		-- Already holding something equippable that matches? Done.
		local held = ch:FindFirstChildOfClass("Tool")
		if held and _isEquippableWeapon(held) then
			if cfg.selectedWeapon == "" or held.ToolTip == cfg.selectedWeapon then
				return held
			end
		end

		if not backpack then return nil end

		-- Style-specific match (e.g. "Melee", "Sword", "Gun", "Blox Fruit")
		if cfg.selectedWeapon ~= "" then
			for _, tool in ipairs(backpack:GetChildren()) do
				if _isEquippableWeapon(tool) and tool.ToolTip == cfg.selectedWeapon then
					safe(function() hum:EquipTool(tool) end)
					task.wait(0.15)
					return ch:FindFirstChildOfClass("Tool")
				end
			end
		end

		-- Fallback: walk a Melee → Sword → Gun → Blox Fruit preference so
		-- we always land on a real weapon. Previously this was
		-- FindFirstChildOfClass("Tool") which returned BF's empty no-Handle
		-- placeholder and EquipTool silently no-op'd — character ended every
		-- respawn empty-handed and unable to attack.
		for _, want in ipairs({ "Melee", "Sword", "Gun", "Blox Fruit" }) do
			for _, tool in ipairs(backpack:GetChildren()) do
				if _isEquippableWeapon(tool) and tool.ToolTip == want then
					safe(function() hum:EquipTool(tool) end)
					task.wait(0.15)
					return ch:FindFirstChildOfClass("Tool")
				end
			end
		end
		-- Last resort: any tool with a Handle + ToolTip (custom style)
		for _, tool in ipairs(backpack:GetChildren()) do
			if _isEquippableWeapon(tool) then
				safe(function() hum:EquipTool(tool) end)
				task.wait(0.15)
				return ch:FindFirstChildOfClass("Tool")
			end
		end
		return nil
	end

	-- Legacy alias used by autoFarmLoop
	local ensureToolEquipped = ensureWeaponEquipped

	-- Return available weapon STYLES (unique ToolTip values) from the backpack.
	-- e.g. {"Melee", "Sword", "Gun", "Blox Fruit"} depending on what the player owns.
	-- The "Blox Fruit" type maps to whatever fruit the player has equipped.
	local STYLE_ORDER = { Melee = 1, Sword = 2, Gun = 3, ["Blox Fruit"] = 4 }

	local function getWeaponOptions()
		local seen = {}
		-- Scan both backpack and character (equipped tool lives on character)
		local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
		if backpack then
			for _, child in ipairs(backpack:GetChildren()) do
				if child:IsA("Tool") and child.ToolTip and child.ToolTip ~= "" then
					seen[child.ToolTip] = true
				end
			end
		end
		local ch = LocalPlayer.Character
		if ch then
			for _, child in ipairs(ch:GetChildren()) do
				if child:IsA("Tool") and child.ToolTip and child.ToolTip ~= "" then
					seen[child.ToolTip] = true
				end
			end
		end
		local styles = {}
		for tip in pairs(seen) do table.insert(styles, tip) end
		table.sort(styles, function(a, b)
			local oa = STYLE_ORDER[a] or 99
			local ob = STYLE_ORDER[b] or 99
			if oa ~= ob then return oa < ob end
			return a < b
		end)
		return styles
	end

	-- ═══════════════════════════ ABILITY ROTATION ═══════════════════════════
	-- Auto-cast the weapon's Z/X/C/V/F skills. Reverse-engineering the remotes
	-- was a dead end: proven live, a bare tool.RemoteFunction:InvokeServer(key)
	-- — even wrapped in the full Holding + repeated RemoteEvent charge — dealt
	-- ZERO damage and played no animation. The server only accepts a skill
	-- through the tool's OWN key handler, so we trigger it the way a real player
	-- does: a VirtualInputManager key press. Aim comes from the game's Mouse
	-- module (ReplicatedStorage.Mouse) — its `.Hit` is a settable CFrame the
	-- handler re-reads each frame, so we pin it onto the target for the cast.
	-- Verified live: this casts Wind Breaker / Quake Sphere and killed a Galley
	-- Captain from a farm hover, no anti-cheat kick. (If kicks ever show up,
	-- this is the block to revert — the remote path never worked anyway.)
	local SLOT_NAMES = { "Z", "X", "C", "V", "F" }
	local VIM = game:GetService("VirtualInputManager")
	local _mouseMod
	local function getMouse()
		if _mouseMod == nil then
			local mod = game:GetService("ReplicatedStorage"):FindFirstChild("Mouse")
			local ok, m = pcall(require, mod)
			_mouseMod = (ok and m) or false
		end
		return _mouseMod or nil
	end

	-- Real M1 via VIM. BF's current combat ignores a bare RegisterAttack /
	-- RegisterHit FireServer (the self-generated-hash trick is patched dead);
	-- only a genuine input click lands damage, and the server does the hit
	-- detection from our position. So we pin the Mouse module on the target to
	-- aim the swing and let VIM fire the click — the caller keeps us in melee
	-- range (low farmHeight). Verified live: bare RegisterAttack = 0 dmg even
	-- point-blank; this VIM click = real damage.
	local function meleeM1At(mouse, enemy)
		if not enemy then return end
		local part = enemy:FindFirstChild("HumanoidRootPart") or pickPart(enemy)
		local cam = workspace.CurrentCamera
		if not part or not cam then return end
		if mouse then mouse.Hit = CFrame.new(part.Position) end
		local svp = cam:WorldToViewportPoint(part.Position)
		local sx, sy
		if svp.Z > 0 then sx, sy = svp.X, svp.Y
		else sx, sy = cam.ViewportSize.X / 2, cam.ViewportSize.Y / 2 end
		VIM:SendMouseButtonEvent(sx, sy, 0, true, game, 0)
		task.wait(0.05)
		VIM:SendMouseButtonEvent(sx, sy, 0, false, game, 0)
	end

	-- Aim target: the live farm target if we have one, else the closest
	-- breathing enemy in reach. Returns the enemy HRP (not a static point) so
	-- the aim tracks it as it moves, or nil when there's nothing to hit — no
	-- casting into empty water and burning cooldowns.
	local function abilityTargetPart(ch)
		local enemy = currentTarget
		if enemy and enemy.Parent then
			local ehrp = enemy:FindFirstChild("HumanoidRootPart")
			if ehrp then return ehrp end
		end
		local hrp = ch:FindFirstChild("HumanoidRootPart")
		local enemies = workspace:FindFirstChild("Enemies")
		if not (hrp and enemies) then return nil end
		local bestPart, bestD
		for _, m in ipairs(enemies:GetChildren()) do
			local ehrp = m:FindFirstChild("HumanoidRootPart")
			local hum = m:FindFirstChildOfClass("Humanoid")
			if ehrp and hum and hum.Health > 0 then
				local d = (ehrp.Position - hrp.Position).Magnitude
				if d <= 250 and (not bestD or d < bestD) then bestD = d; bestPart = ehrp end
			end
		end
		return bestPart
	end

	-- One cast: aim at the target, then invoke the weapon's own skill remote.
	-- Every BF weapon carries a RemoteFunction whose InvokeServer(slot) is the
	-- real skill trigger — the same call the tool's LocalScript makes on release
	-- (verified live: Combat "Z" InvokeServer = full skill damage). The server
	-- reads aim from the tool's MousePos value + the shared Mouse, so we pin
	-- both first. This replaces the old VIM key-tap, which the flight state ate
	-- the same way it ate the melee M1. Weapons without a RemoteFunction (rare)
	-- fall back to the key press. Spawned so a yielding InvokeServer never
	-- stalls the rotation loop.
	local function castSkill(mouse, slot, targetPart)
		local ch = LocalPlayer.Character
		local tool = ch and ch:FindFirstChildOfClass("Tool")
		if not tool then return end
		if targetPart and targetPart.Parent then
			local pos = targetPart.Position
			if mouse then mouse.Hit = CFrame.new(pos) end
			local mp = tool:FindFirstChild("MousePos")
			if mp and mp:IsA("Vector3Value") then mp.Value = pos end
		end
		local rf = tool:FindFirstChild("RemoteFunction")
		if rf and rf:IsA("RemoteFunction") then
			task.spawn(function() safe(function() rf:InvokeServer(slot) end) end)
		else
			VIM:SendKeyEvent(true, Enum.KeyCode[slot], false, game)
			task.wait(0.06)
			VIM:SendKeyEvent(false, Enum.KeyCode[slot], false, game)
		end
	end

	local function abilityRotationTick()
		local ch = LocalPlayer.Character
		local tool = ch and ch:FindFirstChildOfClass("Tool")
		if not tool then return end
		local mouse = getMouse()
		if not mouse then return end

		local targetPart = abilityTargetPart(ch)
		if not targetPart then return end

		-- Only cast slots this weapon actually HAS. BF lists a weapon's real
		-- moves under PlayerGui.Main.Skills.<toolName> (verified live: Bisento →
		-- Z, X). So all five toggles on a two-skill weapon won't tap keys that do
		-- nothing. No frame found (odd weapon / HUD not built) → cast whatever's
		-- enabled.
		local hasSlot
		local pg = LocalPlayer:FindFirstChild("PlayerGui")
		local main = pg and pg:FindFirstChild("Main")
		local skills = main and main:FindFirstChild("Skills")
		local weaponFrame = skills and skills:FindFirstChild(tool.Name)
		if weaponFrame then
			hasSlot = {}
			for _, c in ipairs(weaponFrame:GetChildren()) do
				if c:IsA("GuiObject") and #c.Name == 1 then hasSlot[c.Name] = true end
			end
		end

		-- Cast sequentially — each key press drives the tool's own handler
		-- (animation + charge + release). On-cooldown taps are harmless no-ops;
		-- the .Cooldown HUD isn't a readable signal, so we let the game gate it.
		for _, slot in ipairs(SLOT_NAMES) do
			if cfg.abilitySlots[slot] and (not hasSlot or hasSlot[slot]) then
				safe(function() castSkill(mouse, slot, targetPart) end)
			end
		end
	end

	local function abilityRotationLoop()
		while _running do
			local anyOn = false
			for _, slot in ipairs(SLOT_NAMES) do
				if cfg.abilitySlots[slot] then anyOn = true; break end
			end
			if anyOn then
				safe(abilityRotationTick)
				jwait(cfg.abilityCadence)
			else
				jwait(1.0)
			end
		end
	end

	-- Diagnostics: toggle via executor:  getgenv().VellumBF.diag = true
	-- Prints loop state transitions to the Roblox developer console (F9).
	local DIAG = { lastState = "", lastTick = 0 }
	local function dbg(state, extra)
		local g = getgenv().VellumBF
		if not (g and g.diag) then return end
		local now = os.clock()
		if state ~= DIAG.lastState then
			print(string.format("[BF-diag] %.2f (+%.2f) %s %s", now, now - DIAG.lastTick, state, extra or ""))
			DIAG.lastState = state
			DIAG.lastTick = now
		end
	end

	-- ═══════════════════════════ MOB BRING ═══════════════════════════
	local function _bringMobs()
		if not cfg.mobBring then
			for hrp, bp in pairs(_bringBPs) do
				pcall(function() bp:Destroy() end)
			end
			_bringBPs = {}
			return
		end

		local ch = LocalPlayer.Character
		local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
		if not hrp then return end
		local pos = hrp.Position

		local seen = {}

		for _, e in ipairs(workspace.Enemies:GetChildren()) do
			local ehrp = e:FindFirstChild("HumanoidRootPart")
			local hum  = e:FindFirstChild("Humanoid")
			if ehrp and hum and hum.Health > 0 then
				local dist = (ehrp.Position - pos).Magnitude
				if dist <= cfg.mobBringRadius and dist > 3 then
					seen[ehrp] = true
					if not _bringBPs[ehrp] then
						local bp = Instance.new("BodyPosition")
						bp.Name = "Vellum_BringBP"
						bp.MaxForce = Vector3.new(math.huge, 0, math.huge)
						bp.P = 400
						bp.D = 60
						bp.Parent = ehrp
						_bringBPs[ehrp] = bp
					end
					-- Pull toward player XZ — preserve enemy Y so we don't lift them
					_bringBPs[ehrp].Position = Vector3.new(pos.X, ehrp.Position.Y, pos.Z)
				end
			end
		end

		for ehrp, bp in pairs(_bringBPs) do
			if not seen[ehrp] then
				pcall(function() bp:Destroy() end)
				_bringBPs[ehrp] = nil
			end
		end
	end

	local function autoFarmLoop()
		while _running do
			if _tpInProgress then jwait(1.0) continue end
			if not cfg.autoFarm then
				safe(_stopFlightFn)
				jwait(0.5)
				continue
			end

			if not flightConn or not _hoverBP or not _hoverBP.Parent then safe(startFlight) end
			safe(ensureToolEquipped)

			safe(function()
				local enemy = currentTarget
				-- Drop a stale or wrong-species target before committing to it.
				-- Without the name guard a currentTarget left over from a
				-- filter-less tick — e.g. the Cyborg boss that shares Fountain
				-- City with the Galley Captains — sticks, and we hammer a boss we
				-- can't damage (and drift toward it) instead of re-picking the
				-- quest mob. pickEnemy already honors the filter; force a re-pick.
				if enemy and enemy.Parent and cfg.farmTargetName ~= ""
				   and enemy.Name ~= cfg.farmTargetName then
					enemy = nil
					currentTarget = nil
				end
				if not enemy or not enemy.Parent then
					-- Actively pick the next target and tween to it.
					-- Without this, we'd jwait 0.3s doing nothing and rely on
					-- BodyPosition physics to slowly drag us — which BF's
					-- anticheat often removes, locking us in place.
					local newEnemy = pickEnemy()
					dbg("pick", newEnemy and newEnemy.Name or "none")
					if newEnemy then
						currentTarget = newEnemy
						local ch = LocalPlayer.Character
						local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
						local ehrp = newEnemy:FindFirstChild("HumanoidRootPart")
						if hrp and ehrp then
							local dist = (ehrp.Position - hrp.Position).Magnitude
							-- Only CFrame-tween for long distances (>100 studs).
							-- Normal combat transitions use BP physics movement
							-- (accelerates at ~12 m/s² with P=600). Writing HRP.CFrame
							-- through a dense field of 500+ enemy collision bodies
							-- forces the physics engine to rebuild spatial state
							-- every frame of the tween — massive fps drops.
							if dist > 100 then
								dbg("tween-start", newEnemy.Name .. " dist=" .. math.floor(dist))
								targetOriginalY = ehrp.Position.Y
								local hoverY = targetOriginalY + cfg.farmHeight
								local dest = Vector3.new(ehrp.Position.X, hoverY, ehrp.Position.Z)
								if _hoverBP and _hoverBP.Parent then
									_hoverBP.P, _hoverBP.D = 0, 0
									if _hoverBG and _hoverBG.Parent then
										_hoverBG.P = 0
									end
									_tweenHRPTo(hrp, dest)
									dbg("tween-done", newEnemy.Name)
									if _hoverBP and _hoverBP.Parent then
										_hoverBP.P, _hoverBP.D = 600, 80
										_hoverBP.Position = dest
									end
									if _hoverBG and _hoverBG.Parent then
										_hoverBG.P = 1000
									end
								else
									_tweenHRPTo(hrp, dest)
									dbg("tween-done", newEnemy.Name)
								end
							else
								-- Under 100 studs: BP physics movement only.
								dbg("bp-move", newEnemy.Name .. " dist=" .. math.floor(dist))
								local hoverY = (targetOriginalY or ehrp.Position.Y) + cfg.farmHeight
								if _hoverBP and _hoverBP.Parent then
									_hoverBP.Position = Vector3.new(ehrp.Position.X, hoverY, ehrp.Position.Z)
								end
							end
						end
						-- New target acquired — return immediately. Next loop
						-- iteration sees currentTarget is set and attacks.
						return
					end
					-- No quest mob alive right now. Strict policy: STAY PUT
					-- at the quest spawn and wait for respawns. BF respawns
					-- mobs on a 5-10s wave timer; the server only spawns
					-- them when a player is near the anchor — so as long
					-- as we're sitting at the spawn zone, mobs WILL come.
					--
					-- The only reason to move is if we've actually drifted
					-- away from the spawn (PvP knockback, fall, etc). In
					-- that case, snap back. Never go hunting elsewhere —
					-- the previous "fallback-hunt → fallback-tp to island"
					-- behavior pulled us back to Prison every 6 seconds
					-- when waves were briefly empty, undoing the Colosseum
					-- sub-zone snap.
					_noTargetTicks = (_noTargetTicks or 0) + 1
					if _noTargetTicks > 4 and Q.current and Q.current.mob then
						_noTargetTicks = 0
						local mobName = Q.current.mob
						local ch2 = LocalPlayer.Character
						local hrp2 = ch2 and ch2:FindFirstChild("HumanoidRootPart")
						if hrp2 and not nearQuestSpawn(mobName, hrp2, 800) then
							-- Drifted away. Snap back to the spawn centroid.
							-- discoverSubZone returns the EnemySpawns anchor
							-- when no live mobs exist (Pass B).
							local sub = discoverSubZone(mobName)
							if sub then
								dbg("fallback-resync", mobName)
								local dest = sub + Vector3.new(0, cfg.farmHeight, 0)
								if _hoverBP and _hoverBP.Parent then
									_hoverBP.P, _hoverBP.D = 0, 0
								end
								_tweenHRPTo(hrp2, dest)
								if _hoverBP and _hoverBP.Parent then
									_hoverBP.P, _hoverBP.D = 600, 80
									_hoverBP.Position = dest
								end
							end
						end
						-- nearQuestSpawn == true → just wait, server is
						-- about to spawn the next wave. No movement.
					end
					jwait(1.5)
					return
				end

				-- Damage through the game's own hit pipeline (_G.SendHitsToServer
				-- via getrenv). The raw RE/RegisterHit is a virtual remote the
				-- server ignores, so the old hash/VIM paths dealt 0. Single target
				-- on the quest mob; the standalone Kill Aura loop handles pack
				-- sweeping, so it works whether or not the farm is running.
				sendHit(enemy)

				-- Clear currentTarget as SOON as the enemy dies (Health <= 0),
				-- not when BF removes the corpse from workspace.Enemies
				-- (which takes 1-3s). Without this we waste ticks attacking a
				-- dead enemy while pickEnemy() already switched to the next.
				local hum = enemy and enemy:FindFirstChild("Humanoid")
				if (enemy and not enemy.Parent) or (hum and hum.Health <= 0) then
					stats.sessionKills = stats.sessionKills + 1
					dbg("kill", enemy.Name)
					recordQuestKill(enemy.Name)
					-- If we just killed a Logia enemy, we have Buso — flip
					-- the flag so the Logia guard stops skipping them.
					if enemy and enemy:GetAttribute("FruitType") == "Logia" then
						_hasBuso = true
					end
					currentTarget = nil
					targetOriginalY = nil
				end
			end)

			safe(_bringMobs)

			-- ±20% jitter so fixed-period swings stop being a fingerprint.
			jwait(cfg.attackCadence * (0.8 + math.random() * 0.4))
		end
	end

	local function autoStatsLoop()
		while _running do
			if cfg.autoStats then
				safe(function()
					local p = LocalPlayer.Data:FindFirstChild("Points")
					if p and p.Value > 0 then
						R.CommF_:InvokeServer("AddPoint", cfg.statPriority, cfg.statBatchSize)
						jwait(0.4)
					else
						jwait(2.0)
					end
				end)
			else
				jwait(1.5)
			end
		end
	end

	local function antiAfkLoop()
		LocalPlayer.Idled:Connect(function()
			if not cfg.antiAfk then return end
			VirtualUser:CaptureController()
			VirtualUser:ClickButton2(Vector2.new())
		end)
	end

	-- track XP / Beli gain for the stats panel. LocalPlayer.Data is populated
	-- by BF's server script after character spawn, so we WaitForChild before
	-- touching it. nil-safe inner reads for the (rare) case of mid-session
	-- data wipe on respawn.
	local function trackProgressLoop()
		local data = LocalPlayer:WaitForChild("Data", 30)
		if not data then return end
		local expVal = data:WaitForChild("Exp", 10)
		local beliVal = data:WaitForChild("Beli", 10)
		if not (expVal and beliVal) then return end

		local lastXP, lastBeli = expVal.Value, beliVal.Value
		while _running do
			task.wait(1)
			local xp = expVal.Value
			local beli = beliVal.Value
			if xp > lastXP then
				stats.sessionXP = stats.sessionXP + (xp - lastXP)
			end
			if beli > lastBeli then
				stats.sessionBeli = stats.sessionBeli + (beli - lastBeli)
			end
			lastXP, lastBeli = xp, beli
		end
	end

	-- ═══════════════════════════ UI ═══════════════════════════
	local ui = UI.mount({
		title    = "V E L L U M",
		subtitle = "blox fruits",
		size     = UDim2.fromOffset(560, 400),
		position = UDim2.fromOffset(80, 100),
		onClose  = function() _running = false end,
	})
	gui = ui.gui  -- now assignable, captured as upvalue by the loops above

	Toast.init({ theme = Theme, enabled = function() return cfg.notifyInGame end })

	-- ─── FARM LEVEL TAB ───
	local farm = ui.newPage("farm")
	ui.sectionLabel(farm, "AUTO FARM LEVEL")
	ui.toggleRow(farm, "Auto Farm Level (quest + kill cycle)",
		function() return cfg.autoFarmLevel end,
		function(v)
			cfg.autoFarmLevel = v
			if v then
				cfg.autoFarm = true
				-- Full restart: tear down any stale flight state first
				safe(_stopFlightFn)
				safe(ensureWeaponEquipped)
				safe(startFlight)
				if not getHash() then
					ensureHash()
					Toast.show({
						title = "Hash auto-generated",
						body  = "Quest lifecycle loop engaged.",
						kind  = "success", duration = 4,
					})
				end
			else
				cfg.autoFarm = false
				safe(_stopFlightFn)
			end
		end)
	ui.toggleRow(farm, "Skip boss quests (Warden, etc — slow spawn)",
		function() return cfg.skipBossQuests end,
		function(v)
			cfg.skipBossQuests = v
			-- Force re-pick on next loop tick by clearing the current key.
			-- Without this, an already-accepted boss quest stays active
			-- until the player levels past its range.
			if v and Q.current and Q.current.boss then
				Q.accepted = false
				Q.key      = nil
			end
		end)
	ui.toggleRow(farm, "Simple Kill Mode (no quests)",
		function() return cfg.autoFarm and not cfg.autoFarmLevel end,
		function(v)
			if v then
				cfg.autoFarm = true
				cfg.autoFarmLevel = false
				safe(ensureWeaponEquipped)
				safe(startFlight)
				if not getHash() then
					ensureHash()
					Toast.show({
						title = "Hash auto-generated",
						body  = "Simple kill mode — hash registered.",
						kind  = "success", duration = 4,
					})
				end
			else
				cfg.autoFarm = false
			end
		end)
	ui.sliderRow(farm, "Attack cadence (sec)",
		function() return cfg.attackCadence end,
		function(v) cfg.attackCadence = v end,
		{ min = 0.05, max = 1.0, step = 0.01,
		  format = function(v) return string.format("%.2fs", v) end })
	ui.sliderRow(farm, "Hover height (studs)",
		function() return cfg.farmHeight end,
		function(v) cfg.farmHeight = v end,
		{ min = 0, max = 100, step = 1 })
	ui.toggleRow(farm, "Aggressive range (pull target to you)",
		function() return cfg.aggressiveRange end,
		function(v) cfg.aggressiveRange = v end)
	ui.toggleRow(farm, "Mob magnet (bring enemies to you)",
		function() return cfg.mobBring end,
		function(v) cfg.mobBring = v end)
	ui.sliderRow(farm, "Mob magnet radius",
		function() return cfg.mobBringRadius end,
		function(v) cfg.mobBringRadius = v end,
		{ min = 10, max = 250, step = 5, suffix = " st" })
	ui.toggleRow(farm, "Kill Aura | Mob Aura (hit all nearby)",
		function() return cfg.killAura end,
		function(v) cfg.killAura = v end)

	ui.sectionLabel(farm, "WEAPON STYLE")
	-- Static list of BF's four weapon style categories. Used to be
	-- getWeaponOptions() which scanned the live backpack — but at UI
	-- build time the character often hasn't loaded yet and the scan
	-- returns empty, leaving only "Auto" visible. The categories never
	-- change, so just hardcode them and let the user set a priority
	-- even before they own a weapon of that type (future-proof).
	local weaponStyles = { "Auto", "Melee", "Sword", "Gun", "Blox Fruit" }
	ui.dropdownRow(farm, "Style priority",
		weaponStyles,
		function() return cfg.selectedWeapon ~= "" and cfg.selectedWeapon or "Auto" end,
		function(name)
			cfg.selectedWeapon = (name == "Auto") and "" or name
		end)

	ui.sectionLabel(farm, "ABILITIES")
	ui.toggleRow(farm, "Z",
		function() return cfg.abilitySlots.Z end,
		function(v) cfg.abilitySlots.Z = v end)
	ui.toggleRow(farm, "X",
		function() return cfg.abilitySlots.X end,
		function(v) cfg.abilitySlots.X = v end)
	ui.toggleRow(farm, "C",
		function() return cfg.abilitySlots.C end,
		function(v) cfg.abilitySlots.C = v end)
	ui.toggleRow(farm, "V",
		function() return cfg.abilitySlots.V end,
		function(v) cfg.abilitySlots.V = v end)
	ui.toggleRow(farm, "F",
		function() return cfg.abilitySlots.F end,
		function(v) cfg.abilitySlots.F = v end)
	ui.sliderRow(farm, "Ability cadence (sec)",
		function() return cfg.abilityCadence end,
		function(v) cfg.abilityCadence = v end,
		{ min = 0.5, max = 10, step = 0.1,
		  format = function(v) return string.format("%.1fs", v) end })

	ui.sectionLabel(farm, "TARGET FILTER")
	ui.sliderRow(farm, "Min enemy level",
		function() return cfg.farmLevelMin end,
		function(v) cfg.farmLevelMin = v end,
		{ min = 0, max = 9999, step = 1 })
	ui.sliderRow(farm, "Max enemy level",
		function() return cfg.farmLevelMax end,
		function(v) cfg.farmLevelMax = v end,
		{ min = 0, max = 9999, step = 1 })

	-- ─── SEA 1 TAB ───
	-- Manual TP only. ESP toggles live on the Visuals tab.
	local sea1 = ui.newPage("sea1")

	ui.sectionLabel(sea1, "MANUAL TP")
	local islandOptions = {}
	for _, island in ipairs(ISLANDS) do table.insert(islandOptions, island.name) end

	local lastTpDestination = "—"
	ui.dropdownRow(sea1, "Teleport to",
		islandOptions,
		function() return lastTpDestination end,
		function(name)
			lastTpDestination = name
			local wasAuto = cfg.autoFarmLevel
			if wasAuto then
				cfg.autoFarmLevel = false
				Q.accepted = false; Q.current = nil; Q.key = nil
			end
			local ok = tpToIsland(name)
			local island = ISLAND_BY_NAME[name]
			Toast.show({
				title = ok and "Teleported" or "TP failed",
				body  = name .. (island and ("  •  " .. island.lvlRange) or "") ..
				        (wasAuto and "  (Auto Farm Level paused)" or ""),
				kind  = ok and "success" or "warn", duration = 4,
				key   = "tp:" .. name,
			})
		end)

	-- ─── VISUALS TAB ───
	-- All ESP toggles. Each one short-circuits its own scan loop, so
	-- flipping a group off detaches its billboards/highlights instantly.
	local visuals = ui.newPage("visuals")

	ui.sectionLabel(visuals, "WORLD MARKERS")
	ui.toggleRow(visuals, "Island markers",
		function() return cfg.espIslands end,
		function(v) cfg.espIslands = v; buildIslandESP() end)
	ui.toggleRow(visuals, "Chests (Silver / Gold / Diamond)",
		function() return cfg.espChests end,
		function(v) cfg.espChests = v end)
	ui.toggleRow(visuals, "Devil fruits on the ground",
		function() return cfg.espFruits end,
		function(v) cfg.espFruits = v end)

	ui.sectionLabel(visuals, "ENTITIES")
	ui.toggleRow(visuals, "Players (name·lv · race·fruit · HP bar)",
		function() return cfg.espPlayers end,
		function(v) cfg.espPlayers = v end)
	ui.toggleRow(visuals, "Bosses (mini + named, HP bar)",
		function() return cfg.espBosses end,
		function(v) cfg.espBosses = v end)
	ui.toggleRow(visuals, "Current quest mob (green outline)",
		function() return cfg.espQuestMob end,
		function(v) cfg.espQuestMob = v end)

	ui.sectionLabel(visuals, "FRUIT SNIPER")
	ui.toggleRow(visuals, "Auto-grab dropped fruits",
		function() return cfg.fruitSniper end,
		function(v) cfg.fruitSniper = v end)
	ui.toggleRow(visuals, "Skip common fruits (Bomb, Spike, Smoke, etc)",
		function() return cfg.snipeSkipCommons end,
		function(v) cfg.snipeSkipCommons = v end)
	ui.sliderRow(visuals, "Snipe max distance",
		function() return cfg.snipeMaxDist end,
		function(v) cfg.snipeMaxDist = v end,
		{ min = 500, max = 10000, step = 100, suffix = " st" })

	ui.sectionLabel(visuals, "EXTRAS")
	ui.toggleRow(visuals, "Tracer lines from screen-center",
		function() return cfg.espTracers end,
		function(v) cfg.espTracers = v end)
	ui.sliderRow(visuals, "Max distance",
		function() return cfg.espMaxDist end,
		function(v) cfg.espMaxDist = v end,
		{ min = 0, max = 5000, step = 50,
		  format = function(v) return v == 0 and "off" or (tostring(v) .. " st") end })

	-- ─── SHOP TAB ───
	-- One-click TP-buy-TP from any NPC in the game without ever leaving
	-- the auto-farm spot. shopBuy handles the safe segmented tween +
	-- flight teardown + restore pattern under the hood.
	-- ─── COMBAT TAB ───
	local combat = ui.newPage("combat")
	ui.sectionLabel(combat, "AIMBOT")
	ui.toggleRow(combat, "Aimbot",
		function() return cfg.aimbot end,
		function(v) cfg.aimbot = v end)
	ui.dropdownRow(combat, "Mode",
		{ "Kill Aura", "Silent Aim" },
		function() return cfg.aimbotMode end,
		function(v) cfg.aimbotMode = v end)
	ui.sliderRow(combat, "Range",
		function() return cfg.aimbotRange end,
		function(v) cfg.aimbotRange = v end,
		{ min = 100, max = 3000, step = 50, suffix = " st" })
	ui.toggleRow(combat, "Only while a gun is equipped",
		function() return cfg.aimbotGunsOnly end,
		function(v) cfg.aimbotGunsOnly = v end)

	ui.sectionLabel(combat, "SUSTAIN")
	ui.toggleRow(combat, "Infinite energy / stamina",
		function() return cfg.infiniteEnergy end,
		function(v) cfg.infiniteEnergy = v end)

	local shopTab = ui.newPage("shop")

	-- Master cancel — stops every active auto-unlock at once. Farm
	-- settings (level range, target name, selected weapon) stay as
	-- the unlock left them — cancellation is intentionally minimal
	-- so the user can also tweak settings manually after canceling.
	ui.actionBtn(shopTab, "■ Cancel ALL active auto-unlocks", function()
		cancelAllUnlocks()
	end)

	-- Fruit Dealer — a multi-select snipe picker + the live "on sale" rotation.
	ui.sectionLabel(shopTab, "FRUIT DEALER")

	-- Pull the live 41-fruit catalogue once so the picker lists REAL fruits,
	-- ordered rarity-then-price (the good stuff floats to the top). Falls back
	-- to a curated list if the dealer remote is unavailable at build time.
	local FRUIT_NAMES = {}
	do
		local ok, fruits = pcall(function() return R.CommF_:InvokeServer("GetFruits") end)
		if ok and type(fruits) == "table" then
			local arr = {}
			for _, f in pairs(fruits) do if type(f) == "table" and f.Name then arr[#arr + 1] = f end end
			table.sort(arr, function(a, b)
				if (a.Rarity or 0) ~= (b.Rarity or 0) then return (a.Rarity or 0) > (b.Rarity or 0) end
				return (tonumber(a.Price) or 0) > (tonumber(b.Price) or 0)
			end)
			for _, f in ipairs(arr) do FRUIT_NAMES[#FRUIT_NAMES + 1] = (f.Name:gsub("-", " ")) end
		end
		if #FRUIT_NAMES == 0 then
			for _, n in ipairs({ "Kitsune Kitsune", "Dragon Dragon", "Leopard Leopard", "Dough Dough",
				"Venom Venom", "Shadow Shadow", "Control Control", "Spirit Spirit", "Portal Portal",
				"Buddha Buddha", "Sound Sound", "Phoenix Phoenix", "Love Love", "Quake Quake",
				"Magma Magma", "Light Light" }) do FRUIT_NAMES[#FRUIT_NAMES + 1] = n end
		end
	end
	-- dealerSnipeList is keyed by the raw dealer name ("Light-Light"); the picker
	-- shows the pretty "Light Light". Convert between the two forms here.
	local function snipeKey(display) return (display:gsub(" ", "-")) end

	ui.toggleRow(shopTab, "Auto-snipe selected fruits on sale",
		function() return cfg.dealerSniper end,
		function(v) cfg.dealerSniper = v end)

	ui.multiDropdownRow(shopTab, "Fruits to snipe", FRUIT_NAMES,
		function(display) return cfg.dealerSnipeList[snipeKey(display)] == true end,
		function(display)
			local k = snipeKey(display)
			cfg.dealerSnipeList[k] = (not cfg.dealerSnipeList[k]) or nil
		end,
		{ emptyText = "Pick fruits…" })

	-- ON SALE NOW — one buyable row per fruit in the rotation. Lives in a
	-- self-sizing holder so the page scrolls when the rotation is long; the old
	-- fixed 64px label just clipped the extras.
	ui.sectionLabel(shopTab, "ON SALE NOW")
	local saleHolder = Instance.new("Frame", shopTab)
	saleHolder.Size = UDim2.new(1, -8, 0, 0); saleHolder.BackgroundTransparency = 1
	saleHolder.AutomaticSize = Enum.AutomaticSize.Y
	local saleLayout = Instance.new("UIListLayout", saleHolder)
	saleLayout.Padding = UDim.new(0, 4); saleLayout.SortOrder = Enum.SortOrder.LayoutOrder

	local saleEmpty = Instance.new("TextLabel", saleHolder)
	saleEmpty.Size = UDim2.new(1, 0, 0, 24); saleEmpty.BackgroundTransparency = 1
	saleEmpty.Font = Enum.Font.Gotham; saleEmpty.TextSize = 12
	Theme.bind(saleEmpty, "TextColor3", "textDim"); saleEmpty.TextXAlignment = Enum.TextXAlignment.Left
	saleEmpty.Text = "  Loading rotation…"

	local function renderSaleRow(display, price)
		local row = Instance.new("Frame", saleHolder)
		row.Size = UDim2.new(1, 0, 0, 30)
		Theme.bind(row, "BackgroundColor3", "row"); row.BorderSizePixel = 0
		Instance.new("UICorner", row).CornerRadius = UDim.new(0, 5)
		local nm = Instance.new("TextLabel", row)
		nm.Size = UDim2.new(1, -160, 1, 0); nm.Position = UDim2.fromOffset(12, 0)
		nm.BackgroundTransparency = 1; nm.Text = display
		nm.Font = Enum.Font.GothamMedium; nm.TextSize = 13
		Theme.bind(nm, "TextColor3", "text"); nm.TextXAlignment = Enum.TextXAlignment.Left
		local pr = Instance.new("TextLabel", row)
		pr.Size = UDim2.fromOffset(96, 30); pr.Position = UDim2.new(1, -152, 0, 0)
		pr.BackgroundTransparency = 1; pr.Text = Helpers.fmt(price) .. " Beli"
		pr.Font = Enum.Font.RobotoMono; pr.TextSize = 11
		Theme.bind(pr, "TextColor3", "textDim"); pr.TextXAlignment = Enum.TextXAlignment.Right
		local buy = Instance.new("TextButton", row)
		buy.Size = UDim2.fromOffset(48, 20); buy.Position = UDim2.new(1, -54, 0.5, -10)
		Theme.bind(buy, "BackgroundColor3", "accent"); buy.AutoButtonColor = false
		buy.Font = Enum.Font.GothamBold; buy.TextSize = 11; buy.Text = "Buy"
		buy.TextColor3 = Theme.token("accentText")
		Instance.new("UICorner", buy).CornerRadius = UDim.new(0, 4)
		buy.MouseButton1Click:Connect(function()
			shopBuy("BloxFruitDealer", (display:gsub(" ", "-")), display)
		end)
	end

	-- The fast dealer poll (top of the file) calls this the moment the rotation
	-- changes, so the display stays in lockstep with what the sniper sees.
	_dealerOnSaleCb = function(onSale)
		for _, c in ipairs(saleHolder:GetChildren()) do
			if c:IsA("Frame") then c:Destroy() end
		end
		table.sort(onSale, function(a, b) return (tonumber(a.Price) or 0) < (tonumber(b.Price) or 0) end)
		saleEmpty.Visible = (#onSale == 0)
		saleEmpty.Text = (#onSale == 0) and "  Nothing on sale right now." or ""
		for _, f in ipairs(onSale) do
			renderSaleRow(f.Name:gsub("-", " "), tonumber(f.Price) or 0)
		end
	end

	-- Weapons section. Curated to the top swords/guns/melee + their
	-- assigned dealer. Pulled from BF wiki + WeaponData. Buy fires
	-- BuyItem with the in-game name (case-sensitive). Server codes:
	-- 1 = bought, 0 = not enough Beli, 2 = already own.
	-- Shop item schema:
	--   item     — exact name BF expects in BuyItem
	--   npc      — label only; the server needs no NPC proximity
	--   prereq   — nil for buy-anywhere, or table with:
	--     kind    — "level" | "boss" | "mastery" | "race" | "fragment" | "quest"
	--     value   — number for level/fragment/mastery
	--     target  — string for boss / race / quest name
	--     hint    — human-readable label for UI + toast
	-- Items with no prereq go in the regular section; gated items go in
	-- the QUEST-GATED section with an Unlock button instead of Buy.
	-- Levels lifted from BF wiki (verified against in-game tooltips for the
	-- ones we have access to).

	local function tryShopBuy(npc, item, displayName, prereq)
		local ok = shopBuy(npc, item, displayName)
		if not ok and prereq and prereq.hint then
			Toast.show({
				title = "Locked",
				body  = (displayName or item) .. "  •  " .. prereq.hint,
				kind  = "warn", duration = 5,
				key   = "shop:locked:" .. item,
			})
		end
	end

	-- Polling task that retries BuyItem every 30s until success OR the user
	-- toggles the unlock off. _unlockPollers[item] is checked each iteration —
	-- setting it to nil cancels the poller within ~30s (one wait cycle).
	local _unlockPollers = {}
	local function _pollUntilBought(item, displayName)
		if _unlockPollers[item] then return end
		_unlockPollers[item] = true
		task.spawn(function()
			local deadline = tick() + 86400  -- 24h safety net; a Lv 1→100+ grind can run for hours
			local gap = 0                   -- first attempt fires immediately
			while tick() < deadline and _running do
				if gap > 0 then task.wait(gap) end
				gap = 30
				if not _unlockPollers[item] then break end  -- cancelled
				local r = _purchase(item)
				if r == "bought" or r == "owned" then
					Toast.show({
						title = "Unlocked!",
						body  = (displayName or item) .. (r == "owned" and " — already owned" or " — auto-purchased"),
						kind  = "success", duration = 6,
						key   = "unlock:done:" .. item,
					})
					break
				end
			end
			_unlockPollers[item] = nil
		end)
	end

	local function isUnlockActive(item)
		return _unlockPollers[item] == true
	end

	local function cancelUnlock(item, displayName)
		if _unlockPollers[item] then
			_unlockPollers[item] = nil
			Toast.show({
				title = "Auto-buy stopped",
				body  = (displayName or item),
				kind  = "warn", duration = 3,
				key   = "unlock:cancel:" .. item,
			})
		end
	end

	local function cancelAllUnlocks()
		local n = 0
		for k in pairs(_unlockPollers) do
			_unlockPollers[k] = nil
			n = n + 1
		end
		Toast.show({
			title = "All unlocks cancelled",
			body  = n == 0 and "Nothing was running" or (tostring(n) .. " unlock(s) stopped"),
			kind  = "warn", duration = 4,
			key   = "unlock:cancelall",
		})
	end

	-- Auto-unlock resolver — the ACTIVE kind. Flip it on and Vellum drops what
	-- it's doing and works the item's requirements until the purchase goes
	-- through. We try to buy first (already own / can afford → done, no farm
	-- churn). Otherwise we point the farm at the gate and poll BuyItem: the
	-- server only lets it through once you actually qualify, so the poll is a
	-- reliable "done" signal for every gate kind. One goal at a time — starting
	-- an unlock clears any other in flight so the farm isn't torn in two.
	local function startUnlock(item, displayName, prereq)
		local r = _purchase(item)
		if r == "bought" or r == "owned" then
			Toast.show({ title = r == "owned" and "Already owned" or "Purchased!",
				body = displayName or item, kind = "success", duration = 4,
				key = "unlock:done:" .. item })
			return
		end

		for k in pairs(_unlockPollers) do
			if k ~= item then _unlockPollers[k] = nil end
		end

		-- Clean slate before pointing the farm at this goal. autoFarmLevel
		-- walks the quest ladder for our CURRENT level, so any leftover level
		-- or name filter would strand us: a Lv-100 unlock used to set
		-- farmLevelMin = 75, which at Lv 1 filters out every reachable mob and
		-- the farm just sits idle. Let the quest progression do the leveling —
		-- the server's own gate lets the buy through the moment we qualify.
		cfg.farmLevelMin   = 0
		cfg.farmLevelMax   = 9999
		cfg.farmTargetName = ""

		local kind = prereq and prereq.kind
		if kind == "level" then
			cfg.skipBossQuests = true
			cfg.autoFarmLevel  = true
			cfg.autoFarm       = true
		elseif kind == "mastery" then
			-- Grow mastery: the style has to be the one swinging. We can only pin
			-- the 4 weapon TYPES (Melee/Sword/Gun/Blox Fruit); named techniques
			-- (Black Leg, etc.) the user picks on their hotbar themselves.
			local VALID = { Melee = true, Sword = true, Gun = true, ["Blox Fruit"] = true }
			if prereq.target and VALID[prereq.target] then cfg.selectedWeapon = prereq.target end
			cfg.skipBossQuests = true
			cfg.autoFarmLevel  = true
			cfg.autoFarm       = true
		elseif kind == "fragment" or kind == "quest" or kind == "boss" then
			cfg.skipBossQuests = false  -- bosses/quests are where these come from
			cfg.autoFarmLevel  = true
			cfg.autoFarm       = true
		else
			-- No named gate (or a plain Beli price): farm the quest ladder,
			-- which levels us AND earns Beli, and let the poll buy the moment we
			-- can afford it. autoFarmLevel beats simple-kill mode — it always has
			-- a valid target (the current quest mob) instead of hunting blind.
			cfg.skipBossQuests = true
			cfg.autoFarmLevel  = true
			cfg.autoFarm       = true
		end

		Toast.show({
			title = "Auto-unlock engaged",
			body  = (displayName or item) .. "  •  " .. ((prereq and prereq.hint) or "working the requirements")
			        .. " — buying the moment you qualify",
			kind  = "info", duration = 6, key = "unlock:" .. item,
		})
		_pollUntilBought(item, displayName)
	end

	-- Render a shop section. Un-gated items get a plain Buy/Learn button. Gated
	-- items show the requirement inline on the button (a one-shot "try it now")
	-- PLUS an Auto-unlock toggle — flip it on and the resolver takes over the
	-- farm to work that item's requirements until it can buy it.
	local function renderShopSection(parent, title, verb, items)
		ui.sectionLabel(parent, title)
		for _, e in ipairs(items) do
			if not e.prereq then
				ui.actionBtn(parent, verb .. "  " .. e.item, function()
					tryShopBuy(e.npc, e.item, e.item, nil)
				end)
			else
				ui.actionBtn(parent, verb .. "  " .. e.item .. "   ·   " .. e.prereq.hint, function()
					tryShopBuy(e.npc, e.item, e.item, e.prereq)
				end)
				ui.toggleRow(parent, "    Auto-unlock " .. e.item,
					function() return isUnlockActive(e.item) end,
					function(v)
						if v then startUnlock(e.item, e.item, e.prereq)
						else      cancelUnlock(e.item, e.item) end
					end)
			end
		end
	end

	renderShopSection(shopTab, "SWORDS", "Buy", {
		{ item = "Cutlass",       npc = "SwordDealer"        },
		{ item = "Katana",        npc = "SwordDealer"        },
		{ item = "Iron Mace",     npc = "SwordDealer",       prereq = {kind="level", value=10,  hint="Lv 10"} },
		{ item = "Dual Katana",   npc = "SwordDealerWest",   prereq = {kind="level", value=50,  hint="Lv 50"} },
		{ item = "Triple Katana", npc = "SwordDealerEast",   prereq = {kind="level", value=100, hint="Lv 100"} },
		{ item = "Bisento",       npc = "MasterSwordDealer", prereq = {kind="level", value=120, hint="Lv 120"} },
		{ item = "Pole",          npc = "MasterSwordDealer", prereq = {kind="quest", target="SkyQuest tier 2",   hint="Skylands → Dark Master quest"} },
		{ item = "Soul Cane",     npc = "MasterSwordDealer", prereq = {kind="boss",  target="Cursed Captain",     hint="Defeat Cursed Captain (Sea Event)"} },
		{ item = "Saber",         npc = "MasterSwordDealer", prereq = {kind="boss",  target="Saber Expert",       hint="Defeat Saber Expert"} },
	})

	renderShopSection(shopTab, "GUNS", "Buy", {
		{ item = "Slingshot",         npc = "WeaponDealer"         },
		{ item = "Musket",            npc = "WeaponDealer",         prereq = {kind="level", value=50,  hint="Lv 50"} },
		{ item = "Flintlock",         npc = "WeaponDealer",         prereq = {kind="level", value=30,  hint="Lv 30"} },
		{ item = "Refined Slingshot", npc = "WeaponDealer",         prereq = {kind="level", value=90,  hint="Lv 90"} },
		{ item = "Refined Flintlock", npc = "WeaponDealer",         prereq = {kind="level", value=150, hint="Lv 150"} },
		{ item = "Cannon",            npc = "AdvancedWeaponDealer", prereq = {kind="level", value=200, hint="Lv 200"} },
		{ item = "Bazooka",           npc = "AdvancedWeaponDealer", prereq = {kind="level", value=250, hint="Lv 250"} },
		{ item = "Acidum Rifle",      npc = "AdvancedWeaponDealer", prereq = {kind="boss",  target="Fishman Lord", hint="Defeat Fishman Lord"} },
	})

	-- Names MUST match BUY_SPECS (they double as the Buy<Style> remote key).
	-- Base styles are level/Beli gates; advanced ones gate on mastery — the
	-- resolver pins Melee and grinds, and the server's own check lets the buy
	-- through only when you truly qualify (so no false "unlocked").
	renderShopSection(shopTab, "FIGHT STYLES", "Learn", {
		{ item = "Black Leg",       npc = "AbilityTeacher", prereq = {kind="level",   value=30, hint="Lv 30 + 50k Beli"} },
		{ item = "Electro",         npc = "AbilityTeacher", prereq = {kind="level",   value=1,  hint="500k Beli (Jungle)"} },
		{ item = "Fishman Karate",  npc = "AbilityTeacher", prereq = {kind="level",   value=1,  hint="750k Beli (Underwater)"} },
		{ item = "Dragon Talon",    npc = "AbilityTeacher", prereq = {kind="mastery", target="Melee", value=400, hint="Death Step + Superhuman M400"} },
		{ item = "Death Step",      npc = "AbilityTeacher", prereq = {kind="mastery", target="Melee", value=400, hint="Black Leg M400 + 950k Beli"} },
		{ item = "Electric Claw",   npc = "AbilityTeacher", prereq = {kind="mastery", target="Melee", value=400, hint="Electro M400 + 1.8M Beli"} },
		{ item = "Sharkman Karate", npc = "AbilityTeacher", prereq = {kind="mastery", target="Melee", value=400, hint="Fishman Karate M400 + 2.5M Beli"} },
		{ item = "Superhuman",      npc = "AbilityTeacher", prereq = {kind="mastery", target="Melee", value=400, hint="4 base styles M400 + 3M Beli"} },
		{ item = "Godhuman",        npc = "AbilityTeacher", prereq = {kind="mastery", target="Melee", value=400, hint="4 advanced styles M400 + 20M Beli"} },
		{ item = "Sanguine Art",    npc = "AbilityTeacher", prereq = {kind="mastery", target="Melee", value=400, hint="Godhuman + CDK M400 + 25M Beli"} },
	})

	ui.sectionLabel(shopTab, "HAKI")
	ui.actionBtn(shopTab, "  Learn Observation Haki  •  Defeat Saber Expert + 750k Beli", function()
		tryShopBuy("InstinctTeacher", "Observation", "Observation Haki",
			{kind="boss", target="Saber Expert", hint="Defeat Saber Expert + 750k Beli"})
	end)
	ui.actionBtn(shopTab, "  Learn Buso Haki  •  Lv 300 + 5M Beli", function()
		tryShopBuy("AbilityTeacher", "Buso", "Buso Haki",
			{kind="level", value=300, hint="Lv 300 + 5M Beli"})
	end)
	ui.toggleRow(shopTab, "    Auto-unlock Buso Haki",
		function() return isUnlockActive("Buso") end,
		function(v)
			if v then startUnlock("Buso", "Buso Haki", {kind="level", value=300, hint="Lv 300 + 5M Beli"})
			else      cancelUnlock("Buso", "Buso Haki") end
		end)

	renderShopSection(shopTab, "BOATS", "Buy", {
		{ item = "Rowboat",      npc = "BoatDealer"        },
		{ item = "Plank Raft",   npc = "BoatDealer"        },
		{ item = "Brigade",      npc = "LuxuryBoatDealer", prereq = {kind="level", value=80,  hint="Lv 80"} },
		{ item = "Lantern Boat", npc = "LuxuryBoatDealer", prereq = {kind="level", value=250, hint="Lv 250"} },
		{ item = "The Swan",     npc = "LuxuryBoatDealer", prereq = {kind="level", value=500, hint="Lv 500"} },
	})

	-- ─── STATS TAB ───
	local statsPage = ui.newPage("stats")
	ui.sectionLabel(statsPage, "AUTO STAT ALLOCATION")
	ui.toggleRow(statsPage, "Auto-spend stat points",
		function() return cfg.autoStats end,
		function(v) cfg.autoStats = v end)

	ui.dropdownRow(statsPage, "Stat priority",
		{ "Melee", "Defense", "Sword", "Gun", "Demon Fruit" },
		function() return cfg.statPriority end,
		function(v) cfg.statPriority = v end)

	ui.sectionLabel(statsPage, "SESSION")
	local sessionLbl = Instance.new("TextLabel", statsPage)
	sessionLbl.Size = UDim2.new(1, -8, 0, 80)
	sessionLbl.BackgroundTransparency = 1
	sessionLbl.Font = Enum.Font.RobotoMono; sessionLbl.TextSize = 11
	Theme.bind(sessionLbl, "TextColor3", "text")
	sessionLbl.TextXAlignment = Enum.TextXAlignment.Left
	sessionLbl.TextYAlignment = Enum.TextYAlignment.Top
	sessionLbl.Text = "—"

	task.spawn(function()
		while _running do
			local elapsed = os.clock() - stats.sessionStart
			sessionLbl.Text = string.format(
				"  Kills:  %d\n" ..
				"  XP:     %s   (%s/hr)\n" ..
				"  Beli:   %s   (%s/hr)\n" ..
				"  Uptime: %s\n" ..
				"  Hash:   %s",
				stats.sessionKills,
				Helpers.fmt(stats.sessionXP), Helpers.perHour(stats.sessionXP, elapsed),
				Helpers.fmt(stats.sessionBeli), Helpers.perHour(stats.sessionBeli, elapsed),
				Helpers.fmtDur(elapsed),
				getHash() or "(auto-generated on first tick)"
			)
			task.wait(1)
		end
	end)

	-- ─── SETTINGS TAB ───
	local settings = ui.newPage("settings")
	ui.sectionLabel(settings, "CORE")
	ui.toggleRow(settings, "Bypass AFK kick (anti-AFK)",
		function() return cfg.antiAfk end,
		function(v) cfg.antiAfk = v end)
	ui.toggleRow(settings, "In-game toast notifications",
		function() return cfg.notifyInGame end,
		function(v) cfg.notifyInGame = v end)

	ui.actionBtn(settings, "Reset session hash (force regenerate)", function()
		clearHash()
		Toast.show({
			title = "Hash reset",
			body  = "Will regenerate next tick on the current thread.",
			kind  = "info", duration = 4,
		})
	end)


	ui.newTab("farm",     "Farm",     1)
	ui.newTab("combat",   "Combat",   2)
	ui.newTab("sea1",     "Sea 1",    3)
	ui.newTab("visuals",  "Visuals",  4)
	ui.newTab("shop",     "Shop",     5)
	ui.newTab("stats",    "Stats",    6)
	ui.newTab("settings", "Settings", 7)
	ui.setActiveTab("farm")

	local function makeFloatingIcon()
		local icon = Instance.new("TextButton", ui.gui)
		icon.Size = UDim2.fromOffset(50, 50); icon.Position = UDim2.fromOffset(20, 100)
		Theme.bind(icon, "BackgroundColor3", "panel"); icon.AutoButtonColor = false
		icon.Text = "V"; icon.Font = Enum.Font.Antique; icon.TextSize = 22
		Theme.bind(icon, "TextColor3", "accent"); icon.Active = true; icon.Draggable = true
		Instance.new("UICorner", icon).CornerRadius = UDim.new(1, 0)
		local s = Instance.new("UIStroke", icon)
		Theme.bind(s, "Color", "accent"); s.Thickness = 1.4; s.Transparency = 0.35

		task.spawn(function()
			while icon.Parent do
				local fade = TweenService:Create(s,
					TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
					{ Transparency = 0.75, Thickness = 2.4 })
				fade:Play()
				while icon.Parent do task.wait(0.2) end
				fade:Cancel()
				s.Transparency = 0.35; s.Thickness = 1.4
			end
		end)

		icon.MouseButton1Click:Connect(function()
			ui.root.Visible = true
			icon:Destroy()
		end)
		return icon
	end

	ui.minBtn.MouseButton1Click:Connect(function()
		ui.root.Visible = false
		makeFloatingIcon()
	end)

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or not cfg.keybindToggle then return end
		if input.KeyCode == Enum.KeyCode.RightShift then
			if ui.root.Visible then
				ui.root.Visible = false
				if not ui.gui:FindFirstChildOfClass("TextButton") then makeFloatingIcon() end
			else
				ui.root.Visible = true
				for _, c in ipairs(ui.gui:GetChildren()) do
					if c:IsA("TextButton") then c:Destroy() end
				end
			end
		end
	end)

	-- Build island ESP if enabled at boot
	buildIslandESP()

	-- Body-wide noclip refresh loop. The flight Heartbeat already keeps
	-- HRP non-collidable each frame, but Roblox restores CanCollide on
	-- every other BasePart (arms, legs, torso, etc), which makes the
	-- character get wedged between a wall and an enemy during a chase.
	-- Doing this at 60Hz removes ALL contact resistance and confused the
	-- BP enough to thrash target selection — so we run at ~3Hz instead.
	-- 333ms of contact between refreshes is enough for physics to settle,
	-- and stuck recovery still happens within a second. Only runs while
	-- auto-farm is on so toggle-off restores normal collision.
	local function bodyNoclipLoop()
		while _running do
			if cfg.autoFarm and not _tpInProgress then
				local ch = LocalPlayer.Character
				if ch then
					for _, p in ipairs(ch:GetDescendants()) do
						if p:IsA("BasePart") and p.CanCollide then
							p.CanCollide = false
						end
					end
				end
			end
			task.wait(0.33)
		end
	end

	-- ═══════════════════════════ COMBAT ═══════════════════════════
	-- Aimbot: guns (and every Mouse.Hit-based skill) fire at the cursor, so
	-- ═══════════════════════════ AIMBOT ═══════════════════════════
	-- The damage path depends on the equipped weapon — reverse-engineered live:
	--   • Melee / Sword — the hash M1 (attackOnce → RegisterAttack + RegisterHit,
	--     the same call the farm uses to drop mobs). Infinite range, auto-hit.
	--   • Gun — the hash M1 does ZERO damage while a gun is held (the server
	--     validates the equipped weapon). A real gun shot fires TWO remotes per
	--     click: Validator2(token, seq) then ShootGunEvent(aimPos, {}). The
	--     Validator2 token is an anti-cheat nonce we can't forge, so instead we
	--     let the GAME fire the shot for us: a VirtualInputManager click with
	--     the Mouse module pinned on the target. The click just triggers; aim
	--     comes from the pin (verified — ShootGunEvent used our pinned pos).
	-- Two modes:
	--   • Kill Aura  — auto-fires at the nearest mob every cadence (AFK; this is
	--     what grinds gun mastery hands-free).
	--   • Silent Aim — snaps your own shot onto the crosshair target when YOU
	--     click. No metamethod hook (this codebase disables __namecall/__index
	--     over Hyperion crash risk); melee injects a hash hit, gun re-pins the
	--     Mouse so the game's own shot lands on aim.
	-- Bosses are hash-immune (Cyborg took 0), so we skip them.
	local _BOSS_NAMES = {}
	for _, q in ipairs(SEA1_QUESTS) do if q.boss then _BOSS_NAMES[q.mob] = true end end

	local function _gunEquipped(ch)
		local tool = ch and ch:FindFirstChildOfClass("Tool")
		if not tool then return false end
		-- BF classifies weapons by ToolTip (Melee/Sword/Gun/Blox Fruit); some
		-- forks also stamp a WeaponType attribute. Accept either.
		return tool.ToolTip == "Gun" or tool:GetAttribute("WeaponType") == "Gun"
	end

	-- Nearest breathing, non-boss mob to a world position, within range.
	local function _nearestMob(fromPos)
		local enemies = workspace:FindFirstChild("Enemies")
		if not enemies then return nil end
		local best, bestD
		for _, m in ipairs(enemies:GetChildren()) do
			if not _BOSS_NAMES[m.Name] then
				local eh  = m:FindFirstChild("HumanoidRootPart")
				local hum = m:FindFirstChildOfClass("Humanoid")
				if eh and hum and hum.Health > 0 then
					local d = (eh.Position - fromPos).Magnitude
					if d <= cfg.aimbotRange and (not bestD or d < bestD) then bestD = d; best = m end
				end
			end
		end
		return best
	end

	-- Target closest to the camera's aim ray (smallest angular deviation),
	-- within range and roughly in front. Considers mobs AND other players so
	-- Silent Aim can be pointed at a PvP target.
	local function _crosshairTarget()
		local cam = workspace.CurrentCamera
		local ch  = LocalPlayer.Character
		if not cam or not ch then return nil end
		local origin = cam.CFrame.Position
		local look   = cam.CFrame.LookVector
		local best, bestAng
		local function consider(model)
			if model == ch then return end
			local eh  = model:FindFirstChild("HumanoidRootPart")
			local hum = model:FindFirstChildOfClass("Humanoid")
			if not (eh and hum and hum.Health > 0) then return end
			local to   = eh.Position - origin
			local dist = to.Magnitude
			if dist < 1 or dist > cfg.aimbotRange then return end
			local ang = math.acos(math.clamp(look:Dot(to.Unit), -1, 1))
			if ang > 0.6 then return end  -- ~34°: must be in front of the crosshair
			if not bestAng or ang < bestAng then bestAng = ang; best = model end
		end
		local enemies = workspace:FindFirstChild("Enemies")
		if enemies then
			for _, m in ipairs(enemies:GetChildren()) do
				if not _BOSS_NAMES[m.Name] then consider(m) end
			end
		end
		for _, pl in ipairs(Players:GetPlayers()) do
			if pl ~= LocalPlayer and pl.Character then consider(pl.Character) end
		end
		return best
	end

	-- Fire the equipped GUN at a target: pin the Mouse module on it (that's
	-- what ShootGunEvent reads for aim) and let VIM trigger a real click so the
	-- game emits the valid Validator2 + ShootGunEvent pair. The screen position
	-- of the click only needs to be on-screen — aim is the pin, not the click.
	local function fireGunAt(mouse, target)
		local th = target:FindFirstChild("HumanoidRootPart") or pickPart(target)
		if not th then return end
		local cam = workspace.CurrentCamera
		if not cam then return end
		local firing = true
		task.spawn(function()
			while firing do
				if th and th.Parent then mouse.Hit = CFrame.new(th.Position) end
				RunService.Heartbeat:Wait()
			end
		end)
		local svp = cam:WorldToViewportPoint(th.Position)
		local sx, sy
		if svp.Z > 0 then sx, sy = svp.X, svp.Y
		else sx, sy = cam.ViewportSize.X / 2, cam.ViewportSize.Y / 2 end
		VIM:SendMouseButtonEvent(sx, sy, 0, true, game, 0)
		task.wait(0.05)
		VIM:SendMouseButtonEvent(sx, sy, 0, false, game, 0)
		task.wait(0.05)
		firing = false
	end

	-- Kill Aura — auto-attack loop. Dispatches on the equipped weapon.
	task.spawn(function()
		while _running do
			if cfg.aimbot and cfg.aimbotMode == "Kill Aura" then
				local ch  = LocalPlayer.Character
				local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
				local gun = _gunEquipped(ch)
				if hrp and (not cfg.aimbotGunsOnly or gun) then
					local mob = _nearestMob(hrp.Position)
					if mob then
						if gun then
							local mouse = getMouse()
							if mouse then safe(function() fireGunAt(mouse, mob) end) end
						else
							attackAura(nil)  -- melee aura: every mob within reach
						end
					end
				end
			end
			task.wait(cfg.attackCadence)
		end
	end)

	-- Kill Aura | Mob Aura (Main-tab toggle) — standalone pack clearing on its
	-- own thread, so it works with OR without the farm: pair it with Mob magnet
	-- (enemies come to you, no movement needed) or a dungeon/open map, or let
	-- the farm's hover carry it. safe() around the sweep so one bad frame can't
	-- kill the loop and silently disable the toggle.
	task.spawn(function()
		while _running do
			if cfg.killAura then
				safe(ensureWeaponEquipped)
				safe(function() attackAura(nil) end)
				jwait(cfg.attackCadence)
			else
				jwait(0.4)
			end
		end
	end)

	-- Silent Aim — snap YOUR shot onto the crosshair target on click.
	-- processed==true means the click landed on UI/chat, not the world.
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then return end
		if not (cfg.aimbot and cfg.aimbotMode == "Silent Aim") then return end
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
		local ch = LocalPlayer.Character
		local gun = _gunEquipped(ch)
		if cfg.aimbotGunsOnly and not gun then return end
		local target = _crosshairTarget()
		if not target then return end
		if gun then
			-- Re-pin the Mouse onto the target for the shot window so the
			-- game's own gun fire (which you triggered) lands on it.
			local mouse = getMouse()
			local th = target:FindFirstChild("HumanoidRootPart")
			if not (mouse and th) then return end
			task.spawn(function()
				local t0 = os.clock()
				while os.clock() - t0 < 0.25 and th.Parent do
					mouse.Hit = CFrame.new(th.Position)
					RunService.Heartbeat:Wait()
				end
			end)
		else
			safe(function() sendHit(target) end)
		end
	end)

	-- Infinite energy / stamina — keep the bar topped up to the highest value
	-- we've seen. Best-effort (the server may re-assert), but enough for the
	-- client-side gates on dodge / dash / flash.
	local _maxEnergy = 0
	local function infiniteEnergyLoop()
		while _running do
			if cfg.infiniteEnergy then
				local ch = LocalPlayer.Character
				local e = (ch and ch:FindFirstChild("Energy"))
					or (LocalPlayer:FindFirstChild("Data") and LocalPlayer.Data:FindFirstChild("Energy"))
				if e and e:IsA("ValueBase") then
					if e.Value > _maxEnergy then _maxEnergy = e.Value end
					if _maxEnergy > 0 and e.Value < _maxEnergy then e.Value = _maxEnergy end
				end
			end
			task.wait(0.3)
		end
	end

	-- ═══════════════════════════ KICK OFF ═══════════════════════════
	task.spawn(autoFarmLoop)
	task.spawn(autoFarmLevelLoop)
	task.spawn(abilityRotationLoop)
	task.spawn(autoStatsLoop)
	task.spawn(trackProgressLoop)
	task.spawn(bodyNoclipLoop)
	task.spawn(espScanLoop)
	task.spawn(infiniteEnergyLoop)
	antiAfkLoop()

	Toast.show({
		title = "Vellum loaded",
		body  = "Auto Farm Level, weapons, and ability rotation ready.",
		kind  = "info", duration = 6,
	})

	print("[Vellum BF] module loaded.")
end

return Module
