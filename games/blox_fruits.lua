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

		-- island ESP
		espIslands = true,           -- billboard names over each island

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

	local function attackOnce(enemy)
		local part = pickPart(enemy)
		local hash = getHash()
		if not part or not hash then return false end
		safe(function() R.RegisterAttack:FireServer(cfg.damageMultiplier) end)
		safe(function() R.RegisterHit:FireServer(part, {}, nil, hash) end)
		return true
	end

	-- ═══════════════════════════ COMBAT ═══════════════════════════
	-- We use the standard RegisterAttack + RegisterHit protocol with a
	-- self-generated hash. The CombatFramework API path was removed in
	-- BF's internal refactor (no RigLib, no RigControllerEvent, no
	-- PlayerScripts.CombatFramework). The hash is the only gate.

	-- ═══════════════════════════ TARGETING ═══════════════════════════
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
		{ lvlMin = 300, lvlMax = 324, island = "Magma Village",   questId = "MagmaQuest",    tier = 1, mob = "Mil. Soldier",    taskCount = 7 },
		{ lvlMin = 325, lvlMax = 349, island = "Magma Village",   questId = "MagmaQuest",    tier = 2, mob = "Mil. Spy",        taskCount = 8 },
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

	-- True if the HUD-displayed quest matches our target quest. Substring
	-- match against quest.mob — the HUD pluralizes ("Prisoners" contains
	-- "Prisoner", "Dark Masters" contains "Dark Master"), so a 1:1 string
	-- match would fail. We can't rely on taskCount alone because multiple
	-- quests share the same count (Prisoner=8, Dark Master=8, Bandit=...).
	local function hudIsQuest(srv, quest)
		if not srv or not quest then return false end
		return srv.raw:find(quest.mob, 1, true) ~= nil
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
	-- BF's ability protocol (from FruitClient decompiled source):
	--   1. tool.RemoteEvent:FireServer(true)      — signals "activation start"
	--   2. Write tool.MousePos.Value = targetPos   — target for position-based skills
	--   3. tool.RemoteEvent:FireServer(targetPos)  — sends Vector3 target
	-- OR for CFrame abilities:
	--   3. tool.RemoteEvent:FireServer(CFrame)     — sends Mouse.Hit CFrame
	-- The Holding BoolValue on the tool flags sustained activation.
	-- RemoteFunction on the tool is for M1 combat, NOT abilities.
	local SLOT_NAMES = { "Z", "X", "C", "V", "F" }

	local function abilityRotationTick()
		if not cfg.autoFarm then return end
		local ch = LocalPlayer.Character
		local tool = ch and ch:FindFirstChildOfClass("Tool")
		if not tool then return end

		local re = tool:FindFirstChild("RemoteEvent")
		if not re or not re:IsA("RemoteEvent") then return end
		if re.Name == "EquipEvent" then
			for _, c in ipairs(tool:GetChildren()) do
				if c:IsA("RemoteEvent") and c.Name ~= "EquipEvent" and c.Name ~= "LegacyRemoteEvent" then
					re = c
					break
				end
			end
		end

		local legacyRe = tool:FindFirstChild("LegacyRemoteEvent")
		local targetRe = legacyRe and legacyRe:IsA("RemoteEvent") and legacyRe or re

		local mousePosVal = tool:FindFirstChild("MousePos")
		local holdingVal = tool:FindFirstChild("Holding")

		local targetPos
		local enemy = currentTarget
		if enemy and enemy.Parent then
			local ehrp = enemy:FindFirstChild("HumanoidRootPart")
			targetPos = ehrp and ehrp.Position
		end
		if not targetPos then
			local hrp = ch:FindFirstChild("HumanoidRootPart")
			targetPos = hrp and (hrp.Position + (hrp.CFrame.LookVector * 50))
		end
		if not targetPos then return end

		local canFire = {}
		local pg = LocalPlayer:FindFirstChild("PlayerGui")
		local mainGui = pg and pg:FindFirstChild("Main")
		local skillsGui = mainGui and mainGui:FindFirstChild("Skills")
		local combatFrame = skillsGui and skillsGui:FindFirstChild("Combat")
		if combatFrame then
			for _, slot in ipairs(SLOT_NAMES) do
				if cfg.abilitySlots[slot] then
					local slotFrame = combatFrame:FindFirstChild(slot)
					if slotFrame then
						local cdFrame = slotFrame:FindFirstChild("Cooldown")
						if not cdFrame or not cdFrame.Visible then
							table.insert(canFire, slot)
						end
					else
						table.insert(canFire, slot)
					end
				end
			end
		else
			for _, slot in ipairs(SLOT_NAMES) do
				if cfg.abilitySlots[slot] then
					table.insert(canFire, slot)
				end
			end
		end

		for _, slot in ipairs(canFire) do
			safe(function()
				if mousePosVal and mousePosVal:IsA("Vector3Value") then
					mousePosVal.Value = targetPos
				end
				targetRe:FireServer(true)
				targetRe:FireServer(targetPos)
				if holdingVal and holdingVal:IsA("BoolValue") then
					holdingVal.Value = true
					task.delay(0.15, function() holdingVal.Value = false end)
				end
			end)
			task.wait(0.05)
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
	ui.intervalRow(farm, "Attack cadence (sec)",
		function() return cfg.attackCadence end,
		function(v) cfg.attackCadence = v end,
		{ 0.12, 0.15, 0.18, 0.22, 0.30 })
	ui.intervalRow(farm, "Hover height (studs)",
		function() return cfg.farmHeight end,
		function(v) cfg.farmHeight = v end,
		{ 6, 10, 14, 20, 30, 50 })
	ui.toggleRow(farm, "Aggressive range (pull target to you)",
		function() return cfg.aggressiveRange end,
		function(v) cfg.aggressiveRange = v end)
	ui.toggleRow(farm, "Mob magnet (bring enemies to you)",
		function() return cfg.mobBring end,
		function(v) cfg.mobBring = v end)
	ui.intervalRow(farm, "Mob magnet radius",
		function() return cfg.mobBringRadius end,
		function(v) cfg.mobBringRadius = v end,
		{ 20, 35, 50, 75, 100, 150 })

	ui.sectionLabel(farm, "WEAPON STYLE")
	local weaponStyles = getWeaponOptions()
	table.insert(weaponStyles, 1, "Auto")
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
	ui.intervalRow(farm, "Ability cadence (sec)",
		function() return cfg.abilityCadence end,
		function(v) cfg.abilityCadence = v end,
		{ 1.0, 1.5, 2.0, 3.0, 5.0 })

	ui.sectionLabel(farm, "TARGET FILTER")
	ui.intervalRow(farm, "Min enemy level",
		function() return cfg.farmLevelMin end,
		function(v) cfg.farmLevelMin = v end,
		{ 0, 5, 10, 25, 50, 100 })
	ui.intervalRow(farm, "Max enemy level",
		function() return cfg.farmLevelMax end,
		function(v) cfg.farmLevelMax = v end,
		{ 25, 50, 100, 250, 500, 9999 })

	-- ─── SEA 1 TAB ───
	-- Kept for island ESP + manual TP. The old auto-progression toggle
	-- is superseded by Auto Farm Level on the Farm tab.
	local sea1 = ui.newPage("sea1")

	ui.sectionLabel(sea1, "ISLAND ESP")
	ui.toggleRow(sea1, "Show island markers",
		function() return cfg.espIslands end,
		function(v) cfg.espIslands = v; buildIslandESP() end)

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
	ui.newTab("stats",    "Stats",    3)
	ui.newTab("settings", "Settings", 4)
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
	antiAfkLoop()

	Toast.show({
		title = "Vellum loaded",
		body  = "Auto Farm Level, weapons, and ability rotation ready.",
		kind  = "info", duration = 6,
	})

	print("[Vellum BF] module loaded.")
end

return Module
