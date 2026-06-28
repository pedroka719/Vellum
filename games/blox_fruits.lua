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

		-- auto sea progression
		autoSea1 = false,            -- pick best quest for level + TP + accept + farm

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
	-- Filter values are a *preference*, not a hard gate. If nothing matches
	-- the name + level constraints, fall back to the closest alive enemy so
	-- auto-farm never gets stuck silent. Stale filters from a prior Auto
	-- Sea 1 quest tier were the worst offender here.
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

		return bestFiltered or bestAny
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
		{ name = "Skylands",        pos = Vector3.new(-4607.0, 874.0, -1667.0),lvlRange = "Lv 150-249", portal = "Sky3Exit" },
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

	-- Island TP — pisun-hub pattern, the one that actually works.
	--
	-- BF's anti-cheat watches HRP per-frame: it rolls back tweens that finish
	-- in under ~5 seconds (any distance) and any single CFrame delta past a
	-- modest threshold. The bypass:
	--   1. If destination Y differs by > Y_SNAP_THRESHOLD from current, snap
	--      Y first with a direct CFrame write, wait 0.5s for the server to
	--      reconcile. BF tolerates pure vertical jumps better than diagonals.
	--   2. Tween HRP CFrame to the destination at TP_TWEEN_SPEED studs/sec
	--      linear. ~220 keeps duration well above the 5s detection floor for
	--      any non-trivial trip.
	--   3. For destinations behind a server-side portal (Underwater City),
	--      tween to the portal pad first, then fire CommF_:requestEntrance —
	--      the server completes the warp legitimately, no rollback risk.
	local TP_TWEEN_SPEED   = 220
	local Y_SNAP_THRESHOLD = 75
	local activeTween

	-- Forward-declared so tpToIsland can call _stopFlightFn. Some executors
	-- miscompile `local function` forward refs, so we assign into a pre-decl.
	local _stopFlightFn

	_stopFlightFn = function()
		-- Cancel any active tween so toggle-off stops movement instantly
		-- instead of letting the tween complete and fly the character to
		-- the destination first.
		if activeTween then pcall(function() activeTween:Cancel() end); activeTween = nil end
		if flightConn then flightConn:Disconnect(); flightConn = nil end
		if _hoverBP and _hoverBP.Parent then _hoverBP:Destroy() end
		if _hoverBG and _hoverBG.Parent then _hoverBG:Destroy() end
		_hoverBP = nil
		_hoverBG = nil
		currentTarget = nil
		targetOriginalY = nil
		hoverEnabled = false
	end

	local function _tweenHRPTo(hrp, destPos)
		if activeTween then pcall(function() activeTween:Cancel() end) end

		-- Y-snap pre-pass. Lifts/drops us to destination altitude first, so
		-- the main tween only has to cover horizontal distance.
		local yDelta = math.abs(destPos.Y - hrp.Position.Y)
		if yDelta > Y_SNAP_THRESHOLD then
			hrp.CFrame = CFrame.new(hrp.Position.X, destPos.Y, hrp.Position.Z)
			task.wait(0.5)
		end

		local destCF = CFrame.new(destPos, destPos - Vector3.new(0, 0, 1))
		local dist = (destPos - hrp.Position).Magnitude
		if dist < 3 then return end

		local dur = math.max(0.1, dist / TP_TWEEN_SPEED)
		local tween = TweenService:Create(hrp, TweenInfo.new(dur, Enum.EasingStyle.Linear), { CFrame = destCF })
		activeTween = tween
		tween:Play()
		tween.Completed:Wait()
		if activeTween == tween then activeTween = nil end
	end

	local function tpToIsland(name)
		local island = ISLAND_BY_NAME[name]
		if not island then return false end
		local ch = LocalPlayer.Character
		local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
		if not hrp then return false end

		_tpInProgress = true
		local restoreAutoFarm = cfg.autoFarm
		local restoreAutoSea1 = cfg.autoSea1
		cfg.autoFarm = false
		cfg.autoSea1 = false
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
		else
			local landingPos = island.pos + Vector3.new(0, 4, 0)
			_tweenHRPTo(hrp, landingPos)
		end

		task.wait(0.3)
		_tpInProgress = false
		cfg.autoFarm = restoreAutoFarm
		cfg.autoSea1 = restoreAutoSea1
		return true
	end

	-- ═══════════════════════════ QUEST ATLAS ═══════════════════════════
	-- Sea 1 quest progression. Each entry: level range, the island where
	-- the quest giver lives, the questId to fire via CommF_:StartQuest,
	-- the tier string, and the mob name(s) the quest credits.
	--
	-- IDs are community-documented BF quest names. If any fails (server
	-- returns nil / no quest accepts), the spy buffer will log it and we
	-- fix that single row. Captured for-real so-far: BanditQuest1 tier 1.
	local SEA1_QUESTS = {
		{ lvlMin = 1,   lvlMax = 9,   island = "Pirate Starter",  questId = "BanditQuest1",  tier = "1", mob = "Bandit"       },
		{ lvlMin = 10,  lvlMax = 14,  island = "Pirate Starter",  questId = "BanditQuest1",  tier = "2", mob = "Brute"        },
		{ lvlMin = 15,  lvlMax = 29,  island = "Jungle",          questId = "JungleQuest",   tier = "1", mob = "Monkey"       },
		{ lvlMin = 30,  lvlMax = 39,  island = "Jungle",          questId = "JungleQuest",   tier = "2", mob = "Gorilla"      },
		{ lvlMin = 40,  lvlMax = 59,  island = "Pirate Village",  questId = "BuggyQuest1",   tier = "1", mob = "Pirate"       },
		{ lvlMin = 60,  lvlMax = 74,  island = "Desert",          questId = "DesertQuest",   tier = "1", mob = "Desert Bandit" },
		{ lvlMin = 75,  lvlMax = 89,  island = "Desert",          questId = "DesertQuest",   tier = "2", mob = "Desert Officer"},
		{ lvlMin = 90,  lvlMax = 99,  island = "Frozen Village",  questId = "SnowQuest",     tier = "1", mob = "Snow Bandit"  },
		{ lvlMin = 100, lvlMax = 119, island = "Frozen Village",  questId = "SnowQuest",     tier = "2", mob = "Snowman"      },
		{ lvlMin = 120, lvlMax = 149, island = "Marine Fortress", questId = "MarineQuest2",  tier = "1", mob = "Chief Petty Officer" },
		{ lvlMin = 150, lvlMax = 174, island = "Skylands",        questId = "SkyQuest",      tier = "1", mob = "Sky Bandit"   },
		{ lvlMin = 175, lvlMax = 189, island = "Skylands",        questId = "SkyQuest",      tier = "2", mob = "Dark Master"  },
		{ lvlMin = 190, lvlMax = 249, island = "Skylands",        questId = "SkyQuest",      tier = "3", mob = "Prisoner"     },
		{ lvlMin = 250, lvlMax = 274, island = "Prison",          questId = "PrisonerQuest", tier = "1", mob = "Prisoner"     },
		{ lvlMin = 275, lvlMax = 299, island = "Prison",          questId = "PrisonerQuest", tier = "2", mob = "Dangerous Prisoner" },
		{ lvlMin = 300, lvlMax = 324, island = "Prison",          questId = "PrisonerQuest", tier = "3", mob = "Toga Warrior" },
		{ lvlMin = 325, lvlMax = 374, island = "Magma Village",   questId = "MagmaQuest",    tier = "1", mob = "Magma Ninja"  },
		{ lvlMin = 375, lvlMax = 449, island = "Magma Village",   questId = "MagmaQuest",    tier = "2", mob = "Military Soldier" },
		{ lvlMin = 450, lvlMax = 524, island = "Underwater City", questId = "FishmanQuest",  tier = "1", mob = "Fishman Warrior" },
		{ lvlMin = 525, lvlMax = 624, island = "Underwater City", questId = "FishmanQuest",  tier = "2", mob = "Fishman Commando" },
		{ lvlMin = 625, lvlMax = 699, island = "Fountain City",   questId = "SkyExp1Quest",  tier = "1", mob = "God's Guard"  },
		{ lvlMin = 700, lvlMax = 874, island = "Fountain City",   questId = "FountainQuest", tier = "1", mob = "Marine Lieutenant" },
		{ lvlMin = 875, lvlMax = 999, island = "Fountain City",   questId = "FountainQuest", tier = "2", mob = "Marine Captain" },
	}

	-- Picks the highest-level-fit quest for a given player level.
	local function pickQuest(level)
		for _, q in ipairs(SEA1_QUESTS) do
			if level >= q.lvlMin and level <= q.lvlMax then return q end
		end
		return nil
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
		return math.sqrt(dx * dx + dz * dz) < 350
	end

	-- ═══════════════════════════ AUTO SEA 1 ═══════════════════════════
	-- Single-toggle progression. Each tick:
	--   1. Look up the best quest for the current Data.Level
	--   2. If not on that island, TP there
	--   3. If no quest accepted, fire StartQuest
	--   4. Set the manual farm filters to match the quest mob + level range
	--   5. Existing flight/attack loop handles the killing
	--
	-- The script doesn't try to confirm quest-accepted from a server reply
	-- (the verb is fire-and-forget). We keep a soft state of "last accepted"
	-- and re-accept if the level outgrows the previous quest's range.
	local autoSeaState = { lastQuestKey = nil }

	local function autoSea1Tick()
		local data = LocalPlayer:FindFirstChild("Data")
		local levelVal = data and data:FindFirstChild("Level")
		if not levelVal then return end  -- Data not populated yet; try again next tick
		local level = levelVal.Value
		local quest = pickQuest(level)
		if not quest then
			-- Level past Sea 1's farmable range — turn off + notify
			cfg.autoSea1 = false
			Toast.show({
				title = "Sea 1 complete",
				body  = "Level " .. level .. " is past the Sea 1 quest atlas. Switch to Sea 2 (coming soon).",
				kind  = "success", duration = 12,
			})
			return
		end

		-- TP to the quest's island if we aren't there yet
		if not atIsland(quest.island) then
			tpToIsland(quest.island)
			task.wait(0.8)  -- let streaming catch up
			autoSeaState.lastQuestKey = nil  -- re-accept after TP
			return
		end

		-- Accept quest if we haven't yet (or moved to a new quest tier)
		local key = quest.questId .. "|" .. quest.tier
		if autoSeaState.lastQuestKey ~= key then
			safe(function() R.CommF_:InvokeServer("StartQuest", quest.questId, quest.tier) end)
			autoSeaState.lastQuestKey = key
			Toast.show({
				title = "Quest accepted",
				body  = quest.mob .. " (Lv " .. quest.lvlMin .. "-" .. quest.lvlMax .. ")",
				kind  = "info", duration = 4,
				key   = "quest:" .. key,
			})
		end

		-- Drive the existing farm filters
		cfg.farmTargetName = quest.mob
		cfg.farmLevelMin   = quest.lvlMin
		cfg.farmLevelMax   = quest.lvlMax + 5  -- small margin for tier overlap
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

	local function startFlight()
		if flightConn then return end
		if _tpInProgress then return end  -- don't start during teleport
		hoverEnabled = true

		-- BodyPosition + BodyGyro hover (no CFrame writes — those trip
		-- BF's anti-cheat rollback). Server treats it as legitimate physics.
		local ch = LocalPlayer.Character
		local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
		if not hrp then
			_stopFlightFn()
			return
		end

		_hoverBP = Instance.new("BodyPosition")
		_hoverBP.Name = "Vellum_HoverBP"
		_hoverBP.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
		_hoverBP.P = 600    -- 5000 was applying insane force (5000N/stud) that
		_hoverBP.D = 80     -- the physics engine had to resolve against every
		                    -- enemy collision body — dropping 60→12 fps.
		_hoverBP.Position = hrp.Position
		_hoverBP.Parent = hrp

		_hoverBG = Instance.new("BodyGyro")
		_hoverBG.Name = "Vellum_HoverBG"
		_hoverBG.MaxTorque = Vector3.new(math.huge, math.huge, math.huge)
		_hoverBG.P = 1000
		_hoverBG.D = 300
		_hoverBG.CFrame = hrp.CFrame
		_hoverBG.Parent = hrp

		flightConn = RunService.Heartbeat:Connect(function()
			if not (hoverEnabled and cfg.autoFarm) then _stopFlightFn(); return end
			if _tpInProgress then _stopFlightFn(); return end

			local ch2 = LocalPlayer.Character
			local hrp2 = ch2 and ch2:FindFirstChild("HumanoidRootPart")
			if not hrp2 then return end
			if not _hoverBP or not _hoverBP.Parent then _stopFlightFn(); return end
			if not _hoverBG or not _hoverBG.Parent then _stopFlightFn(); return end

			-- Follow the autoFarmLoop's target. No pickEnemy here — scanning
			-- ALL enemies 60x/sec was the main lag source. The farm loop
			-- calls pickEnemy itself when a target dies (~5x/sec).
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

	local function autoSea1Loop()
		while gui.Parent do
			if _tpInProgress then jwait(1.0) continue end
			if cfg.autoSea1 then
				safe(autoSea1Tick)
				-- auto-Sea-1 implies auto-farm; flip it on if user forgot
				cfg.autoFarm = true
			end
			jwait(3.0)  -- check every 3s; no need to thrash quest logic
		end
	end

	-- Equip the first Tool from the backpack if the character has none
	-- in hand. BF combat scripts gate their handlers on the equipped tool
	-- (Tool.Activated / Mouse listeners only attach once it's held), so an
	-- unequipped fresh spawn leaves us with no signal to fire.
	local function ensureToolEquipped()
		local ch = LocalPlayer.Character
		if not ch then return nil end
		local held = ch:FindFirstChildOfClass("Tool")
		if held then return held end
		local hum = ch:FindFirstChildOfClass("Humanoid")
		local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
		if not (hum and backpack) then return nil end
		local tool = backpack:FindFirstChildOfClass("Tool")
		if not tool then return nil end
		safe(function() hum:EquipTool(tool) end)
		task.wait(0.15)
		return ch:FindFirstChildOfClass("Tool")
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

	local function autoFarmLoop()
		while gui.Parent do
			if _tpInProgress then jwait(1.0) continue end
			if not cfg.autoFarm then
				_stopFlightFn()
				jwait(0.5)
				continue
			end

			if not flightConn then startFlight() end
			ensureToolEquipped()

			safe(function()
				local enemy = currentTarget
				if not enemy or not enemy.Parent then
					-- Actively pick the next target and tween to it.
					-- Without this, we'd jwait 0.3s doing nothing and rely on
					-- BodyPosition physics to slowly drag us — which BF's
					-- anticheat often removes, locking us in place.
					DEBUG.pickTime = os.clock()
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
					-- No enemies alive anywhere on the map. Throttle scan:
					-- waves respawn on a 5-10s timer, scanning faster just
					-- allocates wasted GetChildren tables.
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
					currentTarget = nil
					targetOriginalY = nil
				end
			end)

			-- ±20% jitter so fixed-period swings stop being a fingerprint.
			jwait(cfg.attackCadence * (0.8 + math.random() * 0.4))
		end
	end

	local function autoStatsLoop()
		while gui.Parent do
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
		while gui.Parent do
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
	})
	gui = ui.gui  -- now assignable, captured as upvalue by the loops above

	Toast.init({ theme = Theme, enabled = function() return cfg.notifyInGame end })

	-- ─── FARM TAB ───
	local farm = ui.newPage("farm")
	ui.sectionLabel(farm, "AUTO FARM")
	ui.toggleRow(farm, "Auto-farm enemies",
		function() return cfg.autoFarm end,
		function(v)
			cfg.autoFarm = v
			if v then
				ensureToolEquipped()
				if not getHash() then
					ensureHash()
					Toast.show({
						title = "Hash auto-generated",
						body  = "Session token generated and registered — auto-farm running.",
						kind  = "success", duration = 4,
					})
				end
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
	local sea1 = ui.newPage("sea1")
	ui.sectionLabel(sea1, "AUTO PROGRESSION")
	ui.toggleRow(sea1, "Auto Sea 1 (quest + island chain)",
		function() return cfg.autoSea1 end,
		function(v)
			cfg.autoSea1 = v
			if v then
				cfg.autoFarm = true  -- auto-farm is implied
				ensureToolEquipped()
				if not getHash() then
					ensureHash()
					Toast.show({
						title = "Hash auto-generated",
						body  = "Session token ready — Sea 1 loop driving itself.",
						kind  = "success", duration = 4,
					})
				end
			end
		end)

	ui.sectionLabel(sea1, "ISLAND ESP")
	ui.toggleRow(sea1, "Show island markers",
		function() return cfg.espIslands end,
		function(v) cfg.espIslands = v; buildIslandESP() end)

	ui.sectionLabel(sea1, "MANUAL TP")
	-- Single dropdown of every Sea 1 island. Picking one fires the TP
	-- and the toast shows the level range — same info as the old button
	-- grid but a fraction of the screen weight.
	local islandOptions = {}
	for _, island in ipairs(ISLANDS) do table.insert(islandOptions, island.name) end

	local lastTpDestination = "—"
	ui.dropdownRow(sea1, "Teleport to",
		islandOptions,
		function() return lastTpDestination end,
		function(name)
			lastTpDestination = name
			-- Manual override: if Auto Sea 1 was on it would yank us back
			-- on the next tick (3s loop). User clearly wants manual control.
			local wasAuto = cfg.autoSea1
			if wasAuto then
				cfg.autoSea1 = false
				autoSeaState.lastQuestKey = nil
			end
			local ok = tpToIsland(name)
			local island = ISLAND_BY_NAME[name]
			Toast.show({
				title = ok and "Teleported" or "TP failed",
				body  = name .. (island and ("  •  " .. island.lvlRange) or "") ..
				        (wasAuto and "  (Auto Sea 1 paused)" or ""),
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
		while gui.Parent do
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

	-- Build island ESP if enabled at boot
	buildIslandESP()

	-- ═══════════════════════════ KICK OFF ═══════════════════════════
	task.spawn(autoFarmLoop)
	task.spawn(autoSea1Loop)
	task.spawn(autoStatsLoop)
	task.spawn(trackProgressLoop)
	antiAfkLoop()

	Toast.show({
		title = "Vellum loaded",
		body = "Toggle Auto-farm — hash self-generates on first attack tick.",
		kind = "info", duration = 6,
	})

	print("[Vellum BF] module loaded.")
end

return Module
