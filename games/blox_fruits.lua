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
		farmHeight = 10,            -- studs above target (safe farm)
		attackCadence = 0.25,       -- sec between RegisterAttack/Hit pairs
		damageMultiplier = 1.0,     -- 1.0 = always finisher hits
		farmLevelMin = 0,           -- only attack enemies within range
		farmLevelMax = 9999,
		farmTargetName = "",        -- "" = any enemy. Set to "Bandit" etc.
		aggressiveRange = false,    -- pull target under us each tick (ignores server range)
		mobBring = false,           -- pull all nearby enemies toward player
		mobBringRadius = 50,        -- max studs to pull enemies from

		-- auto farm level (replaces autoSea1)
		autoFarmLevel = false,       -- full quest lifecycle (accept → farm → detect done → re-accept)
		autoSea1 = false,            -- kept for backward compat, driven by autoFarmLevel
		skipBossQuests = true,       -- skip 1-kill boss quests (Warden, Chief Warden, etc) —
		                             -- ~5min spawn timers tank XP/hour vs regular mob quests

		-- weapon selection
		selectedWeapon = "",         -- name of weapon to auto-equip ("" = first available)

		-- ability rotation
		abilitySlots = { Z = false, X = false, C = false, V = false, F = false },
		abilityCadence = 2.0,        -- sec between ability activations
		abilityAimMobs   = true,     -- rotate HRP to face current mob before firing directional moves
		abilityAimPlayers = false,   -- enable BF's built-in player auto-aim (AAIM attribute)

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
		spyEnabled = true,
		spyBufferSize = 200,        -- rolling log size
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

	-- ═══════════════════════════ PERSISTENT SPY ═══════════════════════════
	-- Rolling log + persistent session hash store. The __namecall hook is
	-- installed once per Roblox session and writes captured hashes into
	-- getgenv().VellumBF.hash, where every future BF module boot reads from.
	getgenv().VellumBF = getgenv().VellumBF or {}
	local SPY = getgenv().VellumBF
	-- Ring buffer. O(1) push, no per-insert shift. If a prior boot left a
	-- different-shaped log behind, re-initialize.
	if type(SPY.log) ~= "table" or SPY.cap ~= cfg.spyBufferSize then
		SPY.log   = table.create(cfg.spyBufferSize)
		SPY.cap   = cfg.spyBufferSize
		SPY.head  = 1   -- next write slot
		SPY.count = 0   -- entries actually written, capped at cap
	end
	SPY.frozen = false

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

	local function spyPush(row)
		if SPY.frozen then return end
		SPY.log[SPY.head] = row
		SPY.head = (SPY.head % SPY.cap) + 1
		if SPY.count < SPY.cap then SPY.count = SPY.count + 1 end
	end

	-- Newest N entries in chronological order (oldest of the N → newest).
	-- Used by the spy-dump UI button. n defaults to SPY.count.
	local function spyTail(n)
		n = math.min(n or SPY.count, SPY.count)
		local out = table.create(n)
		for i = 1, n do
			local idx = ((SPY.head - (n - i) - 2) % SPY.cap) + 1
			out[i] = SPY.log[idx]
		end
		return out
	end

	-- ─── Hash self-generation ───
	-- We self-generate and register the session hash instead of extracting it
	-- from BF's CombatUtil (which doesn't initialize properly in executors).
	-- The hash formula matches the game's: UserId:sub(2,4) .. thread:sub(11,15).
	-- generateHash(), registerHash(), and ensureHash() defined above.

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

	-- Hooks DISABLED: suspected Hyperion delayed-crash trigger.
	-- Our attack loop fires FireServer directly with self-generated hash
	-- — no dependency on either hook. Keep dead code for easy re-enable
	-- during debugging sessions where spy capture is needed.
	if false then
		local POLL_NOISE = {
			getInventory = true, getFish = true, getRaceLevel = true,
			getInfo = true, getStarterPack = true, getRouletteData = true,
		}
		SPY.decim = 5
		SPY.decimN = 0
		local oldNC
		oldNC = hookmetamethod(game, "__namecall", function(self, ...)
			local m = getnamecallmethod()
			if m == "FireServer" or m == "InvokeServer" then
				local nm = self.Name
				local v = (select(1, ...))
				if not (type(v) == "string" and POLL_NOISE[v]) then
					SPY.decimN = (SPY.decimN % SPY.decim) + 1
					if SPY.decimN == 1 then
						spyPush({
							t = os.clock(),
							r = nm,
							m = m,
							v = type(v) == "string" and v or "<" .. type(v) .. ">",
						})
					end
				end
			end
			return oldNC(self, ...)
		end)
		SPY.hookInstalled = true
	end

	-- ─── Mouse.Hit / Mouse.Target substitution hook ───
	-- Persistent __index hook on game. When SPY._captureMode is on, any read
	-- of Mouse.Hit or Mouse.Target returns SPY._captureTarget.CFrame / the
	-- part itself, instead of whatever the user's real cursor is pointing at.
	--
	-- This is what lets a synthetic firesignal(Tool.Activated) actually land
	-- a hit — BF's combat handler reads Mouse.Hit at click time; without the
	-- hook it sees the user's actual cursor position (sky, ground, nothing),
	-- bails, and never fires RegisterHit. With the hook it sees the enemy
	-- HRP we chose, fires RegisterHit normally, and our __namecall spy above
	-- catches the hash from that call.
	--
	-- Critical safety: NEVER access self.Anything inside the hook — that
	-- would re-trigger __index and infinite-recurse. Use oldIdx(self, key)
	-- for any property read we need, and :IsA which goes through __namecall
	-- (a different metamethod) so it doesn't loop.
	if false then
		-- __index Mouse redirect DISABLED — same root cause as __namecall
		-- hook. Current attackOnce() fires FireServer directly, has no
		-- dependency on Mouse redirects. Keep dead code for re-enable.
		local oldIdx
		oldIdx = hookmetamethod(game, "__index", function(self, key)
			if SPY._captureMode and SPY._captureTarget then
				if typeof(self) == "Instance" and self:IsA("Mouse") then
					local target = SPY._captureTarget
					local targetCF = oldIdx(target, "CFrame")
					local targetPos = targetCF.Position
					if key == "Hit" then
						return targetCF
					elseif key == "Target" then
						return target
					elseif key == "Origin" then
						return oldIdx(workspace.CurrentCamera, "CFrame")
					elseif key == "UnitRay" then
						local camCF = oldIdx(workspace.CurrentCamera, "CFrame")
						return Ray.new(camCF.Position, (targetPos - camCF.Position).Unit)
					elseif key == "X" or key == "Y" then
						local vp = oldIdx(workspace.CurrentCamera, "ViewportSize")
						return key == "X" and vp.X * 0.5 or vp.Y * 0.5
					end
				end
			end
			return oldIdx(self, key)
		end)
		SPY.mouseHookInstalled = true
	end

	-- Punishment detection — if BF kicks us, surface the spy buffer.
	game:GetService("LogService").MessageOut:Connect(function(msg, mtype)
		if mtype ~= Enum.MessageType.MessageError then return end
		if msg:lower():find("kick") or msg:lower():find("ban") or msg:lower():find("disconnect") then
			SPY.frozen = true
			warn("[Vellum BF] PUNISHMENT DETECTED — spy buffer frozen with " ..
				tostring(SPY.count) .. " entries. Inspect getgenv().VellumBF.log")
		end
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

	-- Forward-declared. Populated late in the module (after all cfg/UI/etc
	-- are defined) so attackOnce can invoke it inline. Every M1 fire also
	-- gets a chance to fire Z/X/C/V/F — throttled by cfg.abilityCadence.
	-- This bypasses the separate abilityRotationLoop coroutine (which was
	-- silently dying on some reloads and never invoking tick even though the
	-- protocol was verified working).
	local _fireAbilitiesInline = nil
	local _lastAbilityFire     = 0

	local function attackOnce(enemy)
		local part = pickPart(enemy)
		local hash = getHash()
		if not part or not hash then return false end
		safe(function() R.RegisterAttack:FireServer(cfg.damageMultiplier) end)
		safe(function() R.RegisterHit:FireServer(part, {}, nil, hash) end)
		-- Ability rotation, throttled. Inlined into the M1 loop because the
		-- separate rotation coroutine wasn't reliably firing (external test
		-- showed manual tick invocation deals 588 dmg, but the internal loop
		-- somehow never ticks). This guarantees abilities fire during autofarm.
		if _fireAbilitiesInline and (os.clock() - _lastAbilityFire) >= (cfg.abilityCadence or 2) then
			_lastAbilityFire = os.clock()
			safe(function() _fireAbilitiesInline(enemy) end)
		end
		return true
	end

	-- ═══════════════════════════ COMBAT ═══════════════════════════
	-- We use the standard RegisterAttack + RegisterHit protocol with a
	-- self-generated hash. The CombatFramework API path was removed in
	-- BF's internal refactor (no RigLib, no RigControllerEvent, no
	-- PlayerScripts.CombatFramework). The hash is the only gate.

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
		{ name = "Underwater City", pos = Vector3.new(61165.2, 0.2, 1897.4),   lvlRange = "Lv 450-624" },
		{ name = "Fountain City",   pos = Vector3.new(5127.1, 59.5, 4105.4),   lvlRange = "Lv 625-749" },
	}

	local ISLAND_BY_NAME = {}
	for _, i in ipairs(ISLANDS) do ISLAND_BY_NAME[i.name] = i end

	-- BF's cross-sea portal lives at workspace.Map.TeleportSpawn — two paired
	-- BaseParts with server-side Touched handlers. Stepping on the entry part
	-- yanks the player to the exit part via SetPrimaryPartCFrame on the server,
	-- which the anti-cheat trusts because the *server* did the move. No remote
	-- to fire — touch is the protocol.
	-- The old code path fired CommF_:requestEntrance which never actually
	-- triggered the TP (verified via remote spy — that handler doesn't exist
	-- for this portal). Result: tween fell through to a 60K-stud cross-sea
	-- crawl that takes ~10 minutes.
	-- Coords are live-looked-up from workspace.Map.TeleportSpawn when present;
	-- the hardcoded fallbacks below were captured from a 2026-06 probe and act
	-- as a safety net if BF moves the parts.
	-- Naming is counterintuitive in the live game data:
	--   "Entrance"      = Sea 1 trigger Part   (HAS TouchInterest)
	--   "Exit"          = Sea 2 trigger Part   (HAS TouchInterest, doubles as the return portal)
	--   "EntrancePoint" = Sea 2 landing marker (NO TouchInterest, just a coord)
	--   "ExitPoint"     = Sea 1 landing marker (NO TouchInterest, just a coord)
	-- Verified via live probe — touching EntrancePoint/ExitPoint does nothing.
	local SEA_PORTAL_FALLBACK = {
		sea1to2 = { entry = Vector3.new(4050, -2, -1814), exit = Vector3.new(61163, 11, 1819) },
		sea2to1 = { entry = Vector3.new(61170, -2, 1952), exit = Vector3.new(3864, 6, -1927)  },
	}
	local function _liveSeaPortal()
		local tp = workspace:FindFirstChild("Map") and workspace.Map:FindFirstChild("TeleportSpawn")
		if not tp then return SEA_PORTAL_FALLBACK end
		local function pos(n) local p = tp:FindFirstChild(n); return p and p:IsA("BasePart") and p.Position end
		return {
			sea1to2 = { entry = pos("Entrance")      or SEA_PORTAL_FALLBACK.sea1to2.entry,
			            exit  = pos("EntrancePoint") or SEA_PORTAL_FALLBACK.sea1to2.exit  },
			sea2to1 = { entry = pos("Exit")          or SEA_PORTAL_FALLBACK.sea2to1.entry,
			            exit  = pos("ExitPoint")     or SEA_PORTAL_FALLBACK.sea2to1.exit  },
		}
	end
	-- Sea 1 lives roughly in |X| < 30000; Sea 2 (Underwater City + Sea 2 islands)
	-- sits at X ≈ 60000-62000. Z separates regions inside a sea but doesn't
	-- straddle the sea boundary, so X-magnitude is the safest discriminator.
	local function _whichSea(pos) return math.abs(pos.X) > 30000 and 2 or 1 end

	-- Intra-Sea-1 sub-zone portals (sky pathway etc). Kept on the old CommF_
	-- path because they're cheap to retry and the existing code handles
	-- Skylands sub-zone arrival correctly.
	local PORTAL_PADS = {
		Sky3Exit = Vector3.new(-4607, 874, -1667),  -- sky portal (Skylands variant)
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

	-- Portal-touch helper. Drops the character on the cross-sea trigger Part
	-- and spam-CFrames for ~1.5s (or until sea index flips). Verified live
	-- to cross in ~550ms when nothing else is moving HRP. Returns true on
	-- crossover.
	local function _crossSeaPortal(hrp, fromSea, toSea)
		local portals = _liveSeaPortal()
		local portal  = (fromSea == 1) and portals.sea1to2 or portals.sea2to1
		local ch = hrp.Parent

		-- Kill body movers so flight/dash residuals don't pull us off.
		for _, c in ipairs(hrp:GetChildren()) do
			if c:IsA("BodyMover") or c:IsA("BodyVelocity") or c:IsA("BodyPosition")
			   or c:IsA("BodyGyro") or c:IsA("LinearVelocity") or c:IsA("AlignPosition")
			   or c:IsA("VectorForce") then
				pcall(function() c:Destroy() end)
			end
		end
		local hum = ch and ch:FindFirstChildOfClass("Humanoid")
		if hum then hum.Sit = false; hum.PlatformStand = false end

		-- Spam-snap on the trigger Part for up to 1.5s.
		for _ = 1, 30 do
			pcall(function()
				hrp.CFrame = CFrame.new(portal.entry)
				hrp.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
			end)
			task.wait(0.05)
			if _whichSea(hrp.Position) == toSea then
				pcall(function() hrp.CFrame = hrp.CFrame + Vector3.new(0, 8, 0) end)
				return true
			end
		end
		-- Touched event sometimes lands between checks — final short poll.
		local t0 = tick()
		while tick() - t0 < 1.5 do
			task.wait(0.1)
			if _whichSea(hrp.Position) == toSea then
				pcall(function() hrp.CFrame = hrp.CFrame + Vector3.new(0, 8, 0) end)
				return true
			end
		end
		return false
	end

	local function _tweenHRPTo(hrp, destPos, opts)
		opts = opts or {}
		local speed         = opts.speed         or TP_TWEEN_SPEED
		local fallbackSpeed = opts.fallbackSpeed  or 80
		local maxRetries    = opts.retries        or 2

		if activeTween then pcall(function() activeTween:Cancel() end) end

		-- Cross-sea? Route through the touch portal first. Callers like
		-- the post-respawn return path and fruit sniper hit this whenever
		-- they need to cross the 60K-stud sea gap. Without this they'd
		-- segment-tween the full distance (~10 minutes); with it, they
		-- portal-jump in ~1s and the final tween handles the short hop.
		-- Skip the portal hop when caller explicitly disables it (already
		-- in a portal sequence, sub-zone snap, etc.).
		if not opts.skipPortal then
			local fromSea = _whichSea(hrp.Position)
			local toSea   = _whichSea(destPos)
			if fromSea ~= toSea then
				-- Get within ~800 studs of the portal first (anti-cheat tolerates
				-- short snaps; longer ones trip CheckTeleportGlitchFix).
				local portals = _liveSeaPortal()
				local entry = ((fromSea == 1) and portals.sea1to2 or portals.sea2to1).entry
				if (hrp.Position - entry).Magnitude > 800 then
					_tweenHRPTo(hrp, entry, { skipPortal = true, speed = speed, retries = 1 })
				end
				_crossSeaPortal(hrp, fromSea, toSea)
				-- Fall through to normal tween for the remaining distance.
			end
		end

		local destCF = CFrame.new(destPos, destPos - Vector3.new(0, 0, 1))
		local dist = (destPos - hrp.Position).Magnitude
		if dist < 3 then return end

		for attempt = 1, maxRetries do
			local curSpeed = attempt == 1 and speed or fallbackSpeed
			local dur = math.max(0.1, dist / curSpeed)
			local tween = TweenService:Create(hrp, TweenInfo.new(dur, Enum.EasingStyle.Linear), { CFrame = destCF })
			activeTween = tween
			tween:Play()
			tween.Completed:Wait()
			if activeTween == tween then activeTween = nil end

			local arrived = (hrp.Position - destPos).Magnitude < 80
			if arrived then return end

			dist = (destPos - hrp.Position).Magnitude
			task.wait(0.3)
		end
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

		-- Cross-sea? Tween to the touch portal in our current sea, let the
		-- server's Touched handler do the 60K-stud jump. ~1-2 seconds vs
		-- ~10 minutes for a direct cross-sea tween.
		--
		-- The portal protocol (verified via live probe 2026-06):
		--   1. Disable everything that moves HRP (farm/flight/sniper already
		--      off above; also need to kill BodyMovers because Touched needs
		--      our position to STICK on the trigger Part for a few frames).
		--   2. Tween near the portal entry.
		--   3. Spam-write hrp.CFrame to the trigger Part position for ~1.5s.
		--      A single CFrame gets rolled back by anti-cheat before the
		--      server sees us at the trigger; repeated writes force the
		--      position to replicate. (Single-snap test took 4s with no
		--      crossover; spammed test crossed in 552ms.)
		--   4. The server's :Touched handler fires, CFrames us to the exit
		--      landing marker on the other sea side.
		--   5. Poll for the sea-index flip to confirm.
		local playerSea = _whichSea(hrp.Position)
		local destSea   = _whichSea(island.pos)
		if playerSea ~= destSea then
			local portals = _liveSeaPortal()
			local portal  = (playerSea == 1) and portals.sea1to2 or portals.sea2to1

			-- Get us within ~800 studs first so the spam-snap doesn't
			-- trigger CheckTeleportGlitchFix.
			if (hrp.Position - portal.entry).Magnitude > 800 then
				_tweenHRPTo(hrp, portal.entry)
			end

			-- Kill BodyMovers so flight/dash residuals don't pull us off.
			for _, c in ipairs(hrp:GetChildren()) do
				if c:IsA("BodyMover") or c:IsA("BodyVelocity") or c:IsA("BodyPosition")
				   or c:IsA("BodyGyro") or c:IsA("LinearVelocity") or c:IsA("AlignPosition")
				   or c:IsA("VectorForce") then
					pcall(function() c:Destroy() end)
				end
			end
			local hum = ch:FindFirstChildOfClass("Humanoid")
			if hum then hum.Sit = false; hum.PlatformStand = false end

			-- Spam-snap on the trigger Part. Bail early on sea crossover.
			local crossed = false
			for i = 1, 30 do
				pcall(function()
					hrp.CFrame = CFrame.new(portal.entry)
					hrp.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
				end)
				task.wait(0.05)
				if _whichSea(hrp.Position) == destSea then crossed = true; break end
			end
			-- Final short poll if the snap loop finished without seeing the
			-- crossover (touched event may land between checks).
			if not crossed then
				local t0 = tick()
				while tick() - t0 < 1.5 do
					task.wait(0.1)
					if _whichSea(hrp.Position) == destSea then crossed = true; break end
				end
			end
			-- Bump up a few studs at the exit so we don't immediately walk back
			-- onto the return portal (Sea 2 trigger is ~70 studs from Sea 1 landing).
			if crossed then
				pcall(function() hrp.CFrame = hrp.CFrame + Vector3.new(0, 8, 0) end)
			end
		end

		-- Intra-sea sub-zone portal (Skylands sky pathway etc).
		if island.portal and PORTAL_PADS[island.portal] then
			local padPos = PORTAL_PADS[island.portal]
			_tweenHRPTo(hrp, padPos + Vector3.new(0, 4, 0))
			safe(function() R.CommF_:InvokeServer("requestEntrance", padPos) end)
			pcall(function() hrp.CFrame = hrp.CFrame + Vector3.new(0, 50, 0) end)
			task.wait(1.5)
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
		{ lvlMin = 1,   lvlMax = 9,   island = "Pirate Starter",  questId = "BanditQuest1",  tier = 1, mob = "Bandit",          taskCount = 5 },
		{ lvlMin = 1,   lvlMax = 9,   island = "Marine Starter",  questId = "MarineQuest",   tier = 1, mob = "Trainee",         taskCount = 5 },
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
	local function pickQuest(level)
		local best
		for _, q in ipairs(SEA1_QUESTS) do
			if level >= q.lvlMin and level <= q.lvlMax then
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
				if not q.boss and level >= q.lvlMin then
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
	-- Canonical NPC positions from ReplicatedStorage.NPCs.<name>.FloorPos
	-- (the attribute BF uses to position NPCs after the world loads).
	-- Hardcoded because StreamingEnabled hides distant NPCs from workspace
	-- — we can't find them via workspace scan unless we're already there.
	local NPC_LOCATIONS = {
		BloxFruitDealer       = Vector3.new(-921, 6, 1608),     -- Middle Town
		WeaponDealer          = Vector3.new(-699, 7, 1516),     -- Middle Town
		SwordDealer           = Vector3.new(-2538, 5, 2027),    -- Marine Starter
		SwordDealerWest       = Vector3.new(-1277, 12, 3985),   -- Pirate Village
		SwordDealerEast       = Vector3.new(1432, 86, -1388),   -- Frozen Village
		MasterSwordDealer     = Vector3.new(-4748, 716, -2654), -- Skylands
		AdvancedWeaponDealer  = Vector3.new(-5000, 40, 4402),   -- Marine Fortress
		Blacksmith            = Vector3.new(-1097, 14, 4009),   -- Pirate Village
		DarkStepTeacher       = Vector3.new(-984, 12, 3990),    -- Pirate Village
		WaterKungFuTeacher    = Vector3.new(61587, 20, 988),    -- Underwater City
		AbilityTeacher        = Vector3.new(1489, 36, -1413),   -- Frozen Village
		InstinctTeacher       = Vector3.new(-8037, 5755, -1929),-- Skylands tower top
		BoatDealer            = Vector3.new(-393, 1, 1546),     -- Middle Town
		LuxuryBoatDealer      = Vector3.new(-2534, 3, 1841),    -- Marine Starter
	}

	-- Pure remote purchase — no TP needed. Verified live: BuyItem works
	-- from anywhere in the world, the server doesn't check NPC proximity.
	-- Earlier probe bought Triple Katana from Magma while the Master
	-- Sword Dealer was at Skylands; the item still landed in the
	-- backpack. The NPC_LOCATIONS table stays around because some
	-- future shop calls (boats, certain fruit purchases) might require
	-- proximity — we'll re-add the TP wrapper if/when that turns out
	-- to be the case.
	--   npcKey   — kept in the signature for future-proofing / logging
	--   item     — exact item string the server expects ("Triple Katana")
	--   displayName — for the toast (defaults to item)
	-- Returns true on success (server returned 0 or 1).
	local function shopBuy(npcKey, item, displayName)
		Toast.show({
			title = "Buying", body = (displayName or item),
			kind = "info", duration = 2, key = "shop:" .. item,
		})
		local ok, res = pcall(function()
			return R.CommF_:InvokeServer("BuyItem", item)
		end)
		local resStr = tostring(res)
		local success = ok and (resStr == "0" or resStr == "1")
		Toast.show({
			title = success and "Bought" or "Buy failed",
			body  = (displayName or item) .. (success and "" or ("  •  code " .. resStr)),
			kind  = success and "success" or "warn", duration = 4,
			key   = "shop:done:" .. item,
		})
		return success
	end

	-- Fruit dealer auto-sniper. Polls GetFruits every 30s. When any fruit
	-- in cfg.dealerSnipeList enters the OnSale=true rotation, fires
	-- shopBuy via the BloxFruitDealer NPC. Only one buy per rotation
	-- (BF refreshes the rotation periodically and we don't want to
	-- ping-pong on the same fruit if BuyItem returns code 1).
	local _dealerLastRotation = ""
	task.spawn(function()
		while _running do
			task.wait(30)
			if cfg.dealerSniper and next(cfg.dealerSnipeList) then
				local ok, fruits = pcall(function()
					return R.CommF_:InvokeServer("GetFruits")
				end)
				if ok and type(fruits) == "table" then
					-- Build a rotation signature to avoid re-buying same slot
					local sig = ""
					for _, f in pairs(fruits) do
						if f.OnSale then sig = sig .. f.Name .. "|" end
					end
					if sig ~= _dealerLastRotation then
						_dealerLastRotation = sig
						for _, f in pairs(fruits) do
							if f.OnSale and cfg.dealerSnipeList[f.Name] then
								local price = tonumber(f.Price) or 0
								local beli = LocalPlayer.Data and LocalPlayer.Data.Beli and LocalPlayer.Data.Beli.Value or 0
								if beli >= price then
									shopBuy("BloxFruitDealer", f.Name, f.Name:gsub("-", " "))
									task.wait(2)  -- gap between back-to-back snipes
								end
							end
						end
					end
				end
			end
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

			-- Generic sub-zone snap: gate by distance to the NEAREST alive
			-- quest mob, not distance to the centroid. Centroid-gating broke
			-- on wide zones like Prison's Dangerous Prisoner area (mobs
			-- spread across 1000+ studs) — chasing the nearest mob put us
			-- 400+ studs from centroid, snap fired, teleported us back,
			-- pickEnemy reselected, infinite bumping cycle. Now: if there's
			-- ANY quest mob within 400 studs of us, we're in the right zone
			-- and don't snap. Only snap when we're stranded far from every
			-- spawn (wrong island corner, freshly portal'd, etc).
			local ch = LocalPlayer.Character
			local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
			if hrp then
				local enemies = workspace:FindFirstChild("Enemies")
				local nearestDist = math.huge
				if enemies then
					for _, e in ipairs(enemies:GetChildren()) do
						if e.Name == quest.mob then
							local eh = e:FindFirstChild("HumanoidRootPart")
							local h  = e:FindFirstChild("Humanoid")
							if eh and h and h.Health > 0 then
								local d = (eh.Position - hrp.Position).Magnitude
								if d < nearestDist then nearestDist = d end
							end
						end
					end
				end
				-- Snap to centroid only when we're > 400 studs from EVERY
				-- alive quest mob. Centroid is calculated from the same scan
				-- via discoverSubZone — only call it when we actually need it.
				if nearestDist > 400 then
					local centroid = discoverSubZone(quest.mob)
					if centroid then
						local dest = centroid + Vector3.new(0, 6, 0)
						local snapDist = (dest - hrp.Position).Magnitude
						if snapDist < 1000 then
							-- Short snap → direct CFrame. BP just gets its
							-- target updated on the new HRP position so it
							-- doesn't yank us back to the old enemy.
							hoverEnabled = false
							hrp.CFrame = CFrame.new(dest)
							task.wait(0.4)
							if _hoverBP and _hoverBP.Parent then
								_hoverBP.Position = hrp.Position
							end
							hoverEnabled = true
						else
							-- Long snap → tear down flight first, otherwise
							-- the BP (MaxForce=inf, Position=old enemy) fights
							-- the tween every frame and BF's anti-cheat
							-- rejects the resulting jitter (rollback to
							-- mid-sea). Same pattern tpToIsland uses for
							-- cross-island moves. Skip the island re-TP
							-- check while we're snapping by setting
							-- _tpInProgress so autoFarmLoop doesn't fight us.
							_tpInProgress = true
							local restoreAuto   = cfg.autoFarm
							local restoreAutoFL = cfg.autoFarmLevel
							cfg.autoFarm = false
							cfg.autoFarmLevel = false
							safe(_stopFlightFn)
							safe(function() _tweenHRPTo(hrp, dest) end)
							-- Refresh grace so the next autoFarmLevelLoop
							-- tick doesn't immediately re-TP us back to
							-- island.pos (which would defeat the whole
							-- point of snapping into the sub-zone).
							_islandGraceUntil = tick() + 60
							_islandGraceName  = quest.island
							cfg.autoFarm = restoreAuto
							cfg.autoFarmLevel = restoreAutoFL
							_tpInProgress = false
							safe(startFlight)
						end
					end
				end
			end

			applyQuestFilters(quest)
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
	-- BF binds Z/X/C/V/F to a ContextActionService handler defined in
	-- ReplicatedStorage.FruitClient ("casFunc"). It exposes the handler as
	-- _G.casFunc once a fruit is equipped — see FruitClient line 951.
	-- We invoke it the same way MobileUIController does (line 604):
	--   _G.casFunc("DevilFruit", Enum.UserInputState.Begin, fakeInput, KeyCode)
	-- This skips VirtualInputManager entirely (no UI-focus side effects, no
	-- Mouse.Hit dependency, no character teleport on Z-dash).
	--
	-- For directional aim:
	--   - mob target: rotate HRP to face current enemy BEFORE firing,
	--     so the look-vector points at the mob. Restore AutoRotate after.
	--   - player target: set LocalPlayer:SetAttribute("AAIM", true) — the
	--     game's own auto-aim picks the nearest player automatically.
	--
	-- Sword/race skills don't bind through casFunc; they use their own
	-- per-tool handlers. Auto-abilities here only covers fruit Z/X/C/V/F.
	local SLOT_NAMES = { "Z", "X", "C", "V", "F" }
	local KEYCODE = {
		Z = Enum.KeyCode.Z, X = Enum.KeyCode.X,
		C = Enum.KeyCode.C, V = Enum.KeyCode.V,
		F = Enum.KeyCode.F,
	}

	-- Fruit fire path: BF's mobile UI calls _G.casFunc("DevilFruit", Begin, input, kc).
	local function fireFruitAbility(slot)
		local fn = rawget(_G, "casFunc")
		if type(fn) ~= "function" then return false end
		local kc = KEYCODE[slot]
		if not kc then return false end
		local input = {
			UserInputState = Enum.UserInputState.Begin,
			UserInputType  = Enum.UserInputType.Keyboard,
			KeyCode        = kc,
		}
		return pcall(fn, "DevilFruit", Enum.UserInputState.Begin, input, kc)
	end

	-- Sword fire path — the FULL ritual matters. Verified via remote spy +
	-- live damage test 2026-06 (Bisento Z dealt 423 dmg → killed a Fishman
	-- Commando). The decompiled Bisento Tool LocalScript shows the move is
	-- gated by tool.Holding.Value — the server requires the Hold-spam-release
	-- sequence to register the swing, not just a one-shot FireServer+Invoke.
	--
	-- Sequence:
	--   1. Holding.Value = true       (signals "key down")
	--   2. MousePos.Value = target    (write target before position fires)
	--   3. FireServer(target) x5 at 50ms  (server needs multiple position frames
	--                                      to validate target — single fire gets
	--                                      ignored as "no charge time")
	--   4. Holding.Value = false      (signals "key released")
	--   5. InvokeServer(slot)         (the actual damage trigger)
	--   6. FireServer(false)          (cleanup signal — release follow-up)
	local function fireToolAbility(slot, targetPos)
		local ch = LocalPlayer.Character
		local tool = ch and ch:FindFirstChildOfClass("Tool")
		if not tool then return false end
		local re = tool:FindFirstChild("RemoteEvent")
		local rf = tool:FindFirstChild("RemoteFunction")
		local mp = tool:FindFirstChild("MousePos")
		local holding = tool:FindFirstChild("Holding")
		if not (re and re:IsA("RemoteEvent") and rf and rf:IsA("RemoteFunction")) then
			return false
		end
		if holding and holding:IsA("BoolValue") then holding.Value = true end
		if mp and mp:IsA("Vector3Value") and targetPos then mp.Value = targetPos end
		for _ = 1, 5 do
			pcall(function() re:FireServer(targetPos) end)
			task.wait(0.05)
		end
		if holding and holding:IsA("BoolValue") then holding.Value = false end
		pcall(function() rf:InvokeServer(slot) end)
		pcall(function() re:FireServer(false) end)
		return true
	end

	local function fireAbility(slot, targetPos)
		if fireFruitAbility(slot) then return true end
		return fireToolAbility(slot, targetPos)
	end

	local function abilityRotationTick()
		if not cfg.autoFarm then return end
		local ch = LocalPlayer.Character
		local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
		if not hrp then return end

		-- Sync player auto-aim with our config every tick so toggling the UI
		-- mirrors immediately. AAIM is the in-game flag the skill handler reads.
		LocalPlayer:SetAttribute("AAIM", cfg.abilityAimPlayers and true or false)

		-- Honor on-screen cooldown indicators when available. BF's skill UI lives
		-- under PlayerGui.Main.Skills.<ToolName> (e.g. "Bisento", "Dough"), NOT
		-- "Combat" — that's a template frame with Cooldown.Visible baked to true
		-- so reading Visible always returns "cooling". The real signal is
		-- Cooldown.Size.X.Scale: 0 = ready, >0 = cooling (BF animates the fill).
		-- We also keep a tool-name-agnostic fallback that lets every fire through
		-- when the UI isn't where we expect — the server enforces its own
		-- cooldown, so wasted fires are silent no-ops, not damage glitches.
		local canFire = {}
		local pg = LocalPlayer:FindFirstChild("PlayerGui")
		local mainGui = pg and pg:FindFirstChild("Main")
		local skillsGui = mainGui and mainGui:FindFirstChild("Skills")
		local tool = ch:FindFirstChildOfClass("Tool")
		local skillFrame = skillsGui and tool and skillsGui:FindFirstChild(tool.Name)
		for _, slot in ipairs(SLOT_NAMES) do
			if cfg.abilitySlots[slot] then
				local ready = true
				if skillFrame then
					local slotFrame = skillFrame:FindFirstChild(slot)
					local cdFrame   = slotFrame and slotFrame:FindFirstChild("Cooldown")
					if cdFrame and cdFrame.Size.X.Scale > 0.01 then ready = false end
				end
				if ready then table.insert(canFire, slot) end
			end
		end
		if #canFire == 0 then return end

		-- Resolve target position. The autoFarm pickEnemy + currentTarget pipeline
		-- isn't reliable for ability fires (timing gaps, hash respawn, ESP
		-- contention), so we do our OWN nearest-live-enemy scan here. Look-vector
		-- fallback is useless for sword slams — Bisento Z deposits AOE damage
		-- at the target position, so without a real Vector3 the swing lands in
		-- empty air and registers as a wasted fire. Verified via remote spy:
		-- our protocol replicates correctly but with a phantom target.
		local mob = currentTarget
		local mobHrp = mob and mob.Parent and mob:FindFirstChild("HumanoidRootPart")
		local mobHealthy = mob and mob.Parent and (function()
			local h = mob:FindFirstChild("Humanoid"); return h and h.Health > 0
		end)()
		if not (mobHrp and mobHealthy) then
			local enemies = workspace:FindFirstChild("Enemies")
			if enemies then
				local closest, cdist = nil, math.huge
				local self = hrp.Position
				for _, e in ipairs(enemies:GetChildren()) do
					local eh = e:FindFirstChild("HumanoidRootPart")
					local hum = e:FindFirstChild("Humanoid")
					if eh and hum and hum.Health > 0 then
						local d = (eh.Position - self).Magnitude
						if d < cdist and d < 200 then
							cdist = d; closest = eh; mob = e
						end
					end
				end
				mobHrp = closest
			end
		end
		local targetPos
		if mobHrp then
			targetPos = mobHrp.Position
		else
			-- No mob in range — skip this tick entirely rather than fire at air.
			-- The cooldown reservation is server-side; firing at nothing
			-- consumes the cooldown for no damage.
			return
		end

		local restoreAuto
		if cfg.abilityAimMobs and mobHrp then
			restoreAuto = true
			local hum = ch:FindFirstChildOfClass("Humanoid")
			if hum then hum.AutoRotate = false end
			local p = hrp.Position
			local t = Vector3.new(mobHrp.Position.X, p.Y, mobHrp.Position.Z)
			hrp.CFrame = CFrame.new(p, t)
		end

		for _, slot in ipairs(canFire) do
			safe(function() fireAbility(slot, targetPos) end)
			task.wait(0.05)
		end

		if restoreAuto then
			task.delay(0.2, function()
				local hum = ch:FindFirstChildOfClass("Humanoid")
				if hum then hum.AutoRotate = true end
			end)
		end
	end

	-- Wire the inline hook so attackOnce fires abilities during autofarm.
	_fireAbilitiesInline = abilityRotationTick

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

				-- Standard RegisterAttack+RegisterHit protocol with self-generated hash.
				ensureHash()  -- generates + registers if not yet set
				local t0 = os.clock()
				local landed = attackOnce(enemy)
				local elapsed = os.clock() - t0
				if elapsed > 0.01 then
					dbg("attack-slow", enemy.Name .. " took=" .. string.format("%.4f", elapsed))
				end

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
	ui.toggleRow(farm, "Aim at mobs (rotate to face)",
		function() return cfg.abilityAimMobs end,
		function(v) cfg.abilityAimMobs = v end)
	ui.toggleRow(farm, "Auto-aim players (PvP)",
		function() return cfg.abilityAimPlayers end,
		function(v) cfg.abilityAimPlayers = v end)

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
	local shopTab = ui.newPage("shop")

	-- Master cancel — stops every active auto-unlock at once. Farm
	-- settings (level range, target name, selected weapon) stay as
	-- the unlock left them — cancellation is intentionally minimal
	-- so the user can also tweak settings manually after canceling.
	ui.actionBtn(shopTab, "■ Cancel ALL active auto-unlocks", function()
		cancelAllUnlocks()
	end)

	-- Fruit Dealer — live rotation panel + per-fruit snipe checkboxes.
	-- Curated to the ~14 most-wanted fruits (Rarity 3+ + a few high-value
	-- Rarity 2). Full 41-fruit list would bloat the tab.
	ui.sectionLabel(shopTab, "FRUIT DEALER")
	ui.toggleRow(shopTab, "Auto-snipe selected fruits when on sale",
		function() return cfg.dealerSniper end,
		function(v) cfg.dealerSniper = v end)

	local rotationLbl = Instance.new("TextLabel", shopTab)
	rotationLbl.Size = UDim2.new(1, -16, 0, 64)
	rotationLbl.Position = UDim2.fromOffset(8, 0)
	rotationLbl.BackgroundTransparency = 1
	rotationLbl.Font = Enum.Font.RobotoMono; rotationLbl.TextSize = 11
	Theme.bind(rotationLbl, "TextColor3", "text")
	rotationLbl.TextXAlignment = Enum.TextXAlignment.Left
	rotationLbl.TextYAlignment = Enum.TextYAlignment.Top
	rotationLbl.Text = "  Loading dealer rotation..."
	task.spawn(function()
		while _running do
			local ok, fruits = pcall(function() return R.CommF_:InvokeServer("GetFruits") end)
			if ok and type(fruits) == "table" then
				local lines = { "  ON SALE NOW:" }
				for _, f in pairs(fruits) do
					if f.OnSale then
						table.insert(lines, string.format("    %s  •  %s Beli",
							f.Name:gsub("-", " "), Helpers.fmt(tonumber(f.Price) or 0)))
					end
				end
				rotationLbl.Text = table.concat(lines, "\n")
			end
			task.wait(30)
		end
	end)

	local SNIPE_FRUITS = {
		"Light-Light", "Magma-Magma", "Quake-Quake", "Buddha-Buddha",
		"Love-Love", "Phoenix-Phoenix", "Sound-Sound", "Portal-Portal",
		"Dough-Dough", "Shadow-Shadow", "Venom-Venom", "Spirit-Spirit",
		"Dragon-Dragon", "Kitsune-Kitsune",
	}
	for _, fid in ipairs(SNIPE_FRUITS) do
		ui.toggleRow(shopTab, "  Snipe " .. fid:gsub("-", " "),
			function() return cfg.dealerSnipeList[fid] == true end,
			function(v) cfg.dealerSnipeList[fid] = v or nil end)
	end

	-- Weapons section. Curated to the top swords/guns/melee + their
	-- assigned dealer. Pulled from BF wiki + WeaponData. Buy fires
	-- BuyItem with the in-game name (case-sensitive). Returns code 1
	-- if already owned, 0 on fresh purchase, 2 on failure.
	-- Shop item schema:
	--   item     — exact name BF expects in BuyItem
	--   npc      — NPC_LOCATIONS key (kept for future TP-required items)
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

	-- Boss → island mapping. Most named bosses live on the level-appropriate
	-- island; this lets us hop there and let the auto-farm engage them.
	local BOSS_ISLAND = {
		["Saber Expert"]    = "Pirate Village",
		["Fishman Lord"]    = "Underwater City",
		["Yeti"]            = "Frozen Village",
		["Magma Admiral"]   = "Magma Village",
		["Vice Admiral"]    = "Marine Fortress",
		["Warden"]          = "Prison",
		["Chief Warden"]    = "Prison",
		["Swan"]            = "Prison",
		["Don Swan"]        = "Magma Village",
		["Smoke Admiral"]   = "Marine Fortress",
		["Gorilla King"]    = "Jungle",
		["Chef"]            = "Pirate Village",
		-- Sea events stay nil — caught by the fallback toast
	}

	-- Polling task that retries BuyItem every 30s until success OR the user
	-- toggles the unlock off. _unlockPollers[item] is checked each iteration —
	-- setting it to nil cancels the poller within ~30s (one wait cycle).
	local _unlockPollers = {}
	local function _pollUntilBought(item, displayName)
		if _unlockPollers[item] then return end
		_unlockPollers[item] = true
		task.spawn(function()
			local deadline = tick() + 3600  -- 1hr max
			while tick() < deadline and _running do
				task.wait(30)
				if not _unlockPollers[item] then break end  -- cancelled
				if not cfg.autoFarm and not cfg.autoFarmLevel then break end
				local ok, res = pcall(function()
					return R.CommF_:InvokeServer("BuyItem", item)
				end)
				if ok and (tostring(res) == "0" or tostring(res) == "1") then
					Toast.show({
						title = "Unlocked!",
						body  = (displayName or item) .. " — auto-purchased",
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
				title = "Unlock cancelled",
				body  = (displayName or item) .. " — farm settings unchanged",
				kind  = "warn", duration = 4,
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

	-- Auto-unlock router. Branches on prereq.kind and dispatches to the
	-- right pipeline. All five paths spawn _pollUntilBought so the moment
	-- the server stops rejecting BuyItem, the item lands in the backpack
	-- without the user needing to manually re-click.
	local function startUnlock(item, displayName, prereq)
		if not prereq then return end
		local kind = prereq.kind

		-- LEVEL — set farmLevel range, engage autoFarmLevel, poll
		if kind == "level" then
			cfg.farmLevelMin   = math.max(0, (prereq.value or 0) - 25)
			cfg.farmLevelMax   = math.max(prereq.value or 0, 9999)
			cfg.skipBossQuests = true
			cfg.autoFarmLevel  = true
			cfg.autoFarm       = true
			Toast.show({
				title = "Auto-unlock engaged",
				body  = "Farming to Lv " .. tostring(prereq.value) .. " for " .. (displayName or item),
				kind  = "info", duration = 5,
				key   = "unlock:" .. item,
			})
			_pollUntilBought(item, displayName)
			return
		end

		-- BOSS — override farm target to the boss, TP to its island, retry buy
		if kind == "boss" then
			local boss = prereq.target
			local island = BOSS_ISLAND[boss]
			if not island then
				Toast.show({
					title = "Boss unlock — manual",
					body  = boss .. " spawns randomly (sea event). Watch for spawn.",
					kind  = "warn", duration = 6,
					key   = "unlock:manual:" .. item,
				})
				return
			end
			-- Simple farm mode targeting the boss specifically. The autoFarm
			-- loop will pick the boss as soon as it spawns in workspace.Enemies.
			cfg.autoFarmLevel  = false
			cfg.farmTargetName = boss
			cfg.farmLevelMin   = 1
			cfg.farmLevelMax   = 9999
			cfg.autoFarm       = true
			safe(function() tpToIsland(island) end)
			Toast.show({
				title = "Boss hunt engaged",
				body  = "Hunting " .. boss .. " on " .. island .. " for " .. (displayName or item),
				kind  = "info", duration = 6,
				key   = "unlock:" .. item,
			})
			_pollUntilBought(item, displayName)
			return
		end

		-- QUEST — already in our atlas (Pole = SkyQuest t2). Just engage
		-- autoFarmLevel; the existing pickQuest routes us to the right tier.
		if kind == "quest" then
			cfg.autoFarmLevel = true
			cfg.autoFarm      = true
			cfg.skipBossQuests = false  -- the quest itself might be the gate
			Toast.show({
				title = "Auto-quest engaged",
				body  = (displayName or item) .. "  •  " .. (prereq.hint or "running atlas"),
				kind  = "info", duration = 5,
				key   = "unlock:" .. item,
			})
			_pollUntilBought(item, displayName)
			return
		end

		-- MASTERY — server tracks mastery on the equipped Tool. To grow a
		-- specific style's mastery the user needs that style ACTIVE in
		-- combat. The script controls weapon TYPE (Melee/Sword/Gun/Fruit)
		-- via cfg.selectedWeapon, but fight-style names like "Black Leg"
		-- aren't weapon types — they're learned techniques bound to the
		-- Melee slot in BF's HUD. Mapping every fight style to "Melee"
		-- and pinning that would also override whatever the user picked
		-- on the Farm tab (the bug LO hit when clicking Superhuman with
		-- 'Sword' selected — selectedWeapon got overwritten with the
		-- gibberish string "all 4 base styles" which equipped nothing
		-- valid, falling to the Melee preference).
		--
		-- Safer behavior:
		--   1. ONLY pin selectedWeapon when prereq.target is exactly one
		--      of the 4 valid weapon types — respects the user's manual
		--      style choice for anything else.
		--   2. Always toast the manual guidance so the user knows what
		--      they need to do with their hotbar.
		--   3. Always engage autoFarm + poll buy — mastery grows
		--      passively from kills, and the poll catches the gate lift.
		if kind == "mastery" then
			local VALID_STYLES = { Melee=true, Sword=true, Gun=true, ["Blox Fruit"]=true }
			local target = prereq.target
			local pinned = false
			if VALID_STYLES[target] then
				cfg.selectedWeapon = target
				pinned = true
			end
			cfg.autoFarm = true
			Toast.show({
				title = pinned and "Mastery unlock engaged" or "Mastery unlock — manual",
				body  = pinned
					and ("Pinned " .. target .. " — auto-buy " .. (displayName or item) .. " when M" .. tostring(prereq.value or "?") .. " hits")
					or  ((displayName or item) .. "  •  " .. (prereq.hint or "")),
				kind  = pinned and "info" or "warn", duration = 7,
				key   = "unlock:" .. item,
			})
			_pollUntilBought(item, displayName)
			return
		end

		-- FRAGMENT — Fragments drop from raids + bosses + sea events. Our
		-- best automation today is to keep the user farming high-level
		-- quest mobs (which sometimes drop Fragments) and the boss-skip
		-- filter OFF so bosses become viable. Real fragment farming
		-- (raids, sea events) lands in a future commit.
		if kind == "fragment" then
			cfg.skipBossQuests = false
			cfg.autoFarmLevel  = true
			cfg.autoFarm       = true
			Toast.show({
				title = "Fragment grind engaged",
				body  = (displayName or item) .. "  •  Need " .. tostring(prereq.value) .. " Fragments. Bosses & sea events drop them.",
				kind  = "warn", duration = 7,
				key   = "unlock:" .. item,
			})
			_pollUntilBought(item, displayName)
			return
		end

		-- RACE — multi-stage chain (V1 → V2 → V3 → V4). Each stage is its
		-- own boss/quest sequence. Stubbed for now — race automation lands
		-- as its own dedicated tab once we have the recon for each stage.
		if kind == "race" then
			Toast.show({
				title = "Race unlock — manual",
				body  = "Race upgrades are multi-stage. Manual for now: " .. (prereq.hint or ""),
				kind  = "warn", duration = 7,
				key   = "unlock:manual:" .. item,
			})
			return
		end

		-- Unknown prereq — surface what we know so the user can act manually
		Toast.show({
			title = "Manual unlock",
			body  = (displayName or item) .. "  •  " .. (prereq.hint or "see BF wiki"),
			kind  = "warn", duration = 6,
			key   = "unlock:manual:" .. item,
		})
	end

	-- Render a shop section. Items split into BUY (no prereq) and LOCKED
	-- (gated). Each LOCKED row shows the gate inline + a toggle that
	-- starts the auto-unlock when ON and cancels it when OFF.
	local function renderShopSection(parent, title, verb, items)
		ui.sectionLabel(parent, title)
		local locked = {}
		for _, e in ipairs(items) do
			if e.prereq then
				table.insert(locked, e)
			else
				ui.actionBtn(parent, "  " .. verb .. " " .. e.item, function()
					tryShopBuy(e.npc, e.item, e.item, nil)
				end)
			end
		end
		if #locked > 0 then
			ui.sectionLabel(parent, title .. " — LOCKED")
			for _, e in ipairs(locked) do
				ui.actionBtn(parent, "  " .. verb .. " " .. e.item .. "  •  " .. e.prereq.hint, function()
					-- Try the buy first — server is the authority on lock state.
					-- If we're already past the gate, this succeeds.
					tryShopBuy(e.npc, e.item, e.item, e.prereq)
				end)
				-- Toggle: ON = unlock running, OFF = idle/cancelled. The
				-- ui.toggleRow polls the getF every UI refresh tick so the
				-- toggle visually flips to OFF on its own when the unlock
				-- finishes (poller success → _unlockPollers[item] = nil).
				ui.toggleRow(parent, "      Auto-unlock " .. e.item,
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

	renderShopSection(shopTab, "FIGHT STYLES", "Learn", {
		{ item = "Black Leg",       npc = "AbilityTeacher",     prereq = {kind="level",    value=30,  hint="Lv 30 + 50k Beli"} },
		{ item = "Dark Step",       npc = "DarkStepTeacher",    prereq = {kind="level",    value=75,  hint="Lv 75 + 50k Beli"} },
		{ item = "Electro",         npc = "AbilityTeacher",     prereq = {kind="fragment", value=350, hint="350 Fragments (Skylands)"} },
		{ item = "Fishman Karate",  npc = "AbilityTeacher",     prereq = {kind="level",    value=250, hint="Lv 250 + 750k Beli"} },
		{ item = "Dragon Claw",     npc = "AbilityTeacher",     prereq = {kind="quest",    target="random gacha", hint="Gacha unlock + 1.5k Fragments"} },
		{ item = "Death Step",      npc = "AbilityTeacher",     prereq = {kind="mastery",  target="Black Leg", value=400, hint="Black Leg M400 + 950k Beli"} },
		{ item = "Superhuman",      npc = "AbilityTeacher",     prereq = {kind="mastery",  target="all 4 base styles", hint="All base styles M400 + 1.5M Beli"} },
		{ item = "Sharkman Karate", npc = "WaterKungFuTeacher", prereq = {kind="mastery",  target="Fishman Karate", value=400, hint="Fishman Karate M400 + 2.5M Beli"} },
		{ item = "Water Kung-Fu",   npc = "WaterKungFuTeacher", prereq = {kind="level",    value=300, hint="Lv 300 + 2.5M Beli"} },
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
	ui.toggleRow(shopTab, "      Auto-unlock Buso Haki",
		function() return isUnlockActive("Buso") end,
		function(v)
			if v then startUnlock("Buso", "Buso Haki", {kind="level", value=300, hint="Lv 300"})
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
	ui.toggleRow(settings, "Persistent remote spy",
		function() return cfg.spyEnabled end,
		function(v) cfg.spyEnabled = v end)

	ui.actionBtn(settings, "Reset session hash (force regenerate)", function()
		clearHash()
		Toast.show({
			title = "Hash reset",
			body  = "Will regenerate next tick on the current thread.",
			kind  = "info", duration = 4,
		})
	end)

	ui.actionBtn(settings, "Dump spy buffer to console", function()
		print("=== Vellum BF spy buffer (" .. SPY.count .. " entries) ===")
		for _, r in ipairs(spyTail(60)) do
			print(string.format("[%.2f] %s %s %s", r.t, r.r, r.m, r.v))
		end
	end)

	ui.newTab("farm",     "Farm",     1)
	ui.newTab("sea1",     "Sea 1",    2)
	ui.newTab("visuals",  "Visuals",  3)
	ui.newTab("shop",     "Shop",     4)
	ui.newTab("stats",    "Stats",    5)
	ui.newTab("settings", "Settings", 6)
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

	-- ═══════════════════════════ KICK OFF ═══════════════════════════
	task.spawn(autoFarmLoop)
	task.spawn(autoFarmLevelLoop)
	task.spawn(abilityRotationLoop)
	task.spawn(autoStatsLoop)
	task.spawn(trackProgressLoop)
	task.spawn(bodyNoclipLoop)
	task.spawn(espScanLoop)
	antiAfkLoop()

	Toast.show({
		title = "Vellum loaded",
		body  = "Auto Farm Level, weapons, and ability rotation ready.",
		kind  = "info", duration = 6,
	})

	print("[Vellum BF] module loaded.")
end

return Module
