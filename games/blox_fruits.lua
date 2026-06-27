-- Vellum — Blox Fruits (v0.1)
--
-- PlaceId 2753915549. Single source of truth: this file. lib/ stays generic.
--
-- Combat protocol (verified by recon, see scratchpad/bf_recon/07_gates_passed.md):
--   1. RegisterAttack:FireServer(damageMul)            -- 0.5 normal / 1.0 finisher
--   2. RegisterHit:FireServer(meshPart, {}, nil, hash) -- meshPart is child of enemy
--   ~0.18s between swings is realistic and unflagged.
--
-- Hash is per-player session-stable. Captured by snooping the first real
-- RegisterHit call, then reused for the whole session.
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
	-- Resolved once. Optional remotes resolve via FindFirstChild — events like
	-- Leviathan/SegmentHit aren't always live at boot, and EquipEvent is a
	-- per-tool child, NOT a global remote. WaitForChild on those hangs forever.
	local Net = ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Net")
	local Remotes = ReplicatedStorage:WaitForChild("Remotes")

	local R = {
		-- combat (verified, REQUIRED)
		RegisterAttack = Net:WaitForChild("RE/RegisterAttack"),
		RegisterHit    = Net:WaitForChild("RE/RegisterHit"),
		-- dispatchers (REQUIRED)
		CommF_         = Remotes:WaitForChild("CommF_"),
		CommF          = Remotes:FindFirstChild("CommF"),
		CommE          = Remotes:WaitForChild("CommE"),
		-- direct verbs (optional — present-when-relevant)
		Stats          = Remotes:FindFirstChild("Stats"),
		Combo          = Remotes:FindFirstChild("Combo"),
		Raids          = Remotes:FindFirstChild("Raids"),
		Leviathan      = Remotes:FindFirstChild("Leviathan"),
		SegmentHit     = Remotes:FindFirstChild("SegmentHit"),
		Redeem         = Remotes:FindFirstChild("Redeem"),
		QuestUpdate    = Remotes:FindFirstChild("QuestUpdate"),
		Chest          = Remotes:FindFirstChild("Chest"),
	}

	-- ═══════════════════════════ CONFIG ═══════════════════════════
	local cfg = {
		-- master AFK
		afkMode = false,

		-- farm
		autoFarm = false,
		farmHeight = 10,            -- studs above target (safe farm)
		farmTweenSpeed = 350,       -- studs/sec; under the 1500 velocity cap
		attackCadence = 0.18,       -- sec between RegisterAttack/Hit pairs
		damageMultiplier = 1.0,     -- 1.0 = always finisher hits
		farmLevelMin = 0,           -- only attack enemies within range
		farmLevelMax = 9999,
		farmTargetName = "",        -- "" = any enemy. Set to "Bandit" etc.
		aggressiveRange = false,    -- pull target under us each tick (ignores server range)

		-- auto sea progression
		autoSea1 = false,            -- pick best quest for level + TP + accept + farm
		-- auto-island progression toggle (drives autoSea1's TP behavior)

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

	-- The session hash lives in getgenv so script reloads inherit a hash
	-- captured on a previous boot — user only swings M1 once per Roblox
	-- session, not once per `loadstring` call.
	local jwait = Helpers.makeJwait(cfg)
	local safe = Helpers.makeSafe("Vellum BF")

	-- ═══════════════════════════ PERSISTENT SPY ═══════════════════════════
	-- Rolling log + persistent session hash store. The __namecall hook is
	-- installed once per Roblox session and writes captured hashes into
	-- getgenv().VellumBF.hash, where every future BF module boot reads from.
	getgenv().VellumBF = getgenv().VellumBF or {}
	local SPY = getgenv().VellumBF
	SPY.log = SPY.log or {}
	SPY.frozen = false

	-- read current hash (may be set from a prior boot)
	local function getHash() return SPY.hash end

	-- expose a way to wipe the hash (called from a UI button + on respawn,
	-- since BF rotates the hash when the character respawns)
	local function clearHash()
		SPY.hash = nil
		warn("[Vellum BF] session hash cleared — swing M1 to re-capture")
	end

	local function spyPush(row)
		if SPY.frozen then return end
		table.insert(SPY.log, row)
		while #SPY.log > cfg.spyBufferSize do table.remove(SPY.log, 1) end
	end

	if cfg.spyEnabled and not SPY.hookInstalled then
		local POLL_NOISE = {
			getInventory = true, getFish = true, getRaceLevel = true,
			getInfo = true, getStarterPack = true, getRouletteData = true,
		}
		local oldNC
		oldNC = hookmetamethod(game, "__namecall", function(self, ...)
			local m = getnamecallmethod()
			if m == "FireServer" or m == "InvokeServer" then
				local nm = self.Name
				local v = (select(1, ...))
				if not (type(v) == "string" and POLL_NOISE[v]) then
					-- Hash capture: any real RegisterHit with a valid 8-hex
					-- 4th arg. Stored in getgenv so reloads pick it up.
					if nm == "RE/RegisterHit" and not SPY.hash then
						local _, _, _, h = ...
						if type(h) == "string" and #h == 8 then
							SPY.hash = h
							warn("[Vellum BF] session hash captured:", h)
						end
					end
					spyPush({
						t = os.clock(),
						r = nm,
						m = m,
						v = type(v) == "string" and v or "<" .. type(v) .. ">",
					})
				end
			end
			return oldNC(self, ...)
		end)
		SPY.hookInstalled = true
	end

	-- BF appears to keep the same hash across respawns in the same session,
	-- but if that ever changes we'll observe it here and add a CharacterAdded
	-- handler to clear. Left as a noted hook for now.

	-- Punishment detection — if BF kicks us, surface the spy buffer.
	game:GetService("LogService").MessageOut:Connect(function(msg, mtype)
		if mtype ~= Enum.MessageType.MessageError then return end
		if msg:lower():find("kick") or msg:lower():find("ban") or msg:lower():find("disconnect") then
			SPY.frozen = true
			warn("[Vellum BF] PUNISHMENT DETECTED — spy buffer frozen with " ..
				tostring(#SPY.log) .. " entries. Inspect getgenv().VellumBF.log")
		end
	end)

	-- ═══════════════════════════ MOVEMENT (TWEEN ONLY) ═══════════════════════════
	-- The velocity guard zeroes >1500 mag. ~350 studs/sec is fast travel and safe.
	-- Returns the tween so callers can :Wait()/:Cancel().
	local activeTween
	local function tweenTo(targetCF)
		local ch = LocalPlayer.Character
		local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
		if not hrp then return nil end

		if activeTween then pcall(function() activeTween:Cancel() end) end

		local dist = (targetCF.Position - hrp.Position).Magnitude
		local duration = math.max(0.05, dist / cfg.farmTweenSpeed)
		activeTween = TweenService:Create(
			hrp,
			TweenInfo.new(duration, Enum.EasingStyle.Linear),
			{ CFrame = targetCF }
		)
		activeTween:Play()
		return activeTween
	end

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

	-- ═══════════════════════════ TARGETING ═══════════════════════════
	-- Score = inverse distance + level-fit. Closer + within range = higher.
	local function pickEnemy()
		local ch = LocalPlayer.Character
		local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
		if not hrp then return nil end

		local best, bestScore
		for _, e in ipairs(workspace.Enemies:GetChildren()) do
			local lvl = e:GetAttribute("Level")
			if lvl and lvl >= cfg.farmLevelMin and lvl <= cfg.farmLevelMax then
				if cfg.farmTargetName == "" or e.Name == cfg.farmTargetName then
					local ehrp = e:FindFirstChild("HumanoidRootPart")
					local hum = e:FindFirstChild("Humanoid")
					if ehrp and hum and hum.Health > 0 then
						local d = (ehrp.Position - hrp.Position).Magnitude
						local score = 1000 - d  -- closer = higher
						if not bestScore or score > bestScore then
							best, bestScore = e, score
						end
					end
				end
			end
		end
		return best
	end

	-- ═══════════════════════════ ISLAND MAP ═══════════════════════════
	-- Sea 1 destinations. Coordinates come from the game's own Locations
	-- folder CFrames (workspace._WorldOrigin.Locations.<island>.CFrame) —
	-- these are the literal positions BF uses to register "you're at this
	-- island". They sit at sea-level for ground islands and at the actual
	-- altitude for sky islands.
	--
	-- We lift Y by 6 in the tween so the player lands ON the dock, not
	-- under the water. Surface-finding via raycast was abandoned because
	-- the post-tween CFrame jump triggered BF's server rollback.
	local ISLANDS = {
		{ name = "Pirate Starter",  pos = Vector3.new(1014, 16,  1462),  lvlRange = "Lv 1-9"     },
		{ name = "Marine Starter",  pos = Vector3.new(-2921, -4,  2111), lvlRange = "Lv 1-9"     },
		{ name = "Middle Town",     pos = Vector3.new(-833, 3,    1628), lvlRange = "Lv 10-14"   },
		{ name = "Jungle",          pos = Vector3.new(-1419, 3,   -76),  lvlRange = "Lv 15-29"   },
		{ name = "Pirate Village",  pos = Vector3.new(-1133, 3,   4176), lvlRange = "Lv 30-59"   },
		{ name = "Desert",          pos = Vector3.new(1193, -7,   4430), lvlRange = "Lv 60-89"   },
		{ name = "Frozen Village",  pos = Vector3.new(1276, -7,  -1472), lvlRange = "Lv 90-119"  },
		{ name = "Marine Fortress", pos = Vector3.new(-4935, -7,  4318), lvlRange = "Lv 120-149" },
		{ name = "Skylands",        pos = Vector3.new(-4622, 837, -1817),lvlRange = "Lv 150-249" },
		{ name = "Prison",          pos = Vector3.new(5277, -7,    743), lvlRange = "Lv 250-324" },
		{ name = "Colosseum",       pos = Vector3.new(-1685, -7, -3200), lvlRange = "PvP"        },
		{ name = "Magma Village",   pos = Vector3.new(-5528, -7,  8691), lvlRange = "Lv 325-449" },
		{ name = "Underwater City", pos = Vector3.new(61379, -7,  1473), lvlRange = "Lv 450-624" },
		{ name = "Fountain City",   pos = Vector3.new(5717, -7,   4356), lvlRange = "Lv 625-749" },
	}

	local ISLAND_BY_NAME = {}
	for _, i in ipairs(ISLANDS) do ISLAND_BY_NAME[i.name] = i end

	-- Island TP via BodyVelocity-driven physics motion. Decoded by capturing
	-- Ronix Hub's behavior: their 2,277 BodyVelocity instances during normal
	-- play, vs zero metamethod hits on hrp.CFrame writes, told us they
	-- don't teleport — they fly the player there via physics.
	--
	-- Why physics wins over CFrame writes:
	--   * `hrp.CFrame = ...` and `Model:PivotTo()` both ask the server to
	--     accept an instant position change. After the first kick the
	--     server gets strict and rolls them back to LastSpawnPoint.
	--   * Continuous CFrame writes (TweenService) get the engine to derive
	--     velocity from CFrame deltas; the fling-fix script throttles any
	--     velocity above 750 to mag 100; tween desyncs.
	--   * BodyVelocity sets a real physics velocity. The engine integrates
	--     it normally. Server treats motion as legitimate physical movement
	--     — same path used by every other physics-based ability in BF
	--     (dash, jump, double jump). No rollback even from inside an
	--     anti-cheat-strict zone like Underwater City.
	--
	-- Speed capped at 700 studs/sec to stay under the fling-fix's 750
	-- velocity-mag throttle. 60K-stud trips (UC ↔ start area) take ~90s
	-- which is still better than getting rolled back forever.
	local TP_BV_SPEED = 700
	local activeTpBV
	local function tpToIsland(name)
		local island = ISLAND_BY_NAME[name]
		if not island then return false end
		local ch = LocalPlayer.Character
		local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
		if not hrp then return false end

		-- Cancel any in-flight BV from a previous TP
		if activeTpBV and activeTpBV.Parent then activeTpBV:Destroy() end

		local restoreAutoFarm = cfg.autoFarm
		local restoreAutoSea1 = cfg.autoSea1
		cfg.autoFarm = false
		cfg.autoSea1 = false

		local dest = island.pos + Vector3.new(0, 6, 0)
		local direction = (dest - hrp.Position)
		if direction.Magnitude < 1 then
			cfg.autoFarm = restoreAutoFarm
			cfg.autoSea1 = restoreAutoSea1
			return true
		end
		direction = direction.Unit

		local bv = Instance.new("BodyVelocity")
		bv.Name = "Vellum_TP_BV"
		bv.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
		bv.Velocity = direction * TP_BV_SPEED
		bv.Parent = hrp
		activeTpBV = bv

		-- Steering loop — re-aim each frame in case the player drifts,
		-- and clean up when we arrive (within 50 studs).
		task.spawn(function()
			local t0 = os.clock()
			while bv.Parent and (os.clock() - t0) < 180 do
				local d = (hrp.Position - dest).Magnitude
				if d < 50 then break end
				-- Re-aim each cycle. Small overshoots get corrected.
				bv.Velocity = (dest - hrp.Position).Unit * TP_BV_SPEED
				task.wait(0.15)
			end
			if bv.Parent then bv:Destroy() end
			if activeTpBV == bv then activeTpBV = nil end
			-- After arrival, restore the auto-loops
			task.wait(0.3)
			cfg.autoFarm = restoreAutoFarm
			cfg.autoSea1 = restoreAutoSea1
		end)
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
		local level = LocalPlayer.Data.Level.Value
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

	local function stopFlight()
		hoverEnabled = false
		if flightConn then flightConn:Disconnect(); flightConn = nil end
		currentTarget = nil
		targetOriginalY = nil
	end

	local function startFlight()
		if flightConn then return end
		hoverEnabled = true
		flightConn = RunService.Heartbeat:Connect(function(dt)
			if not (hoverEnabled and cfg.autoFarm) then stopFlight(); return end

			local ch = LocalPlayer.Character
			local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
			if not hrp then return end

			-- Kill any residual velocity so gravity can't accumulate downward
			-- drift between heartbeats. We're CFrame-driven now.
			hrp.AssemblyLinearVelocity = Vector3.new(0, 0, 0)

			-- Pick target each frame; lets us seamlessly switch when one dies
			local enemy = (currentTarget and currentTarget.Parent) and currentTarget or pickEnemy()
			currentTarget = enemy

			local desired
			if enemy then
				local ehrp = enemy:FindFirstChild("HumanoidRootPart")
				if ehrp then
					if not targetOriginalY then
						targetOriginalY = ehrp.Position.Y
					end
					-- Hover at a FIXED altitude (target's original Y + height)
					-- so the aggressive pull can't push us into orbit
					local hoverY = targetOriginalY + cfg.farmHeight
					lastHoldY = hoverY
					desired = CFrame.new(ehrp.Position.X, hoverY, ehrp.Position.Z)

					-- Aggressive: pull target's HRP to (player.X, original_Y,
					-- player.Z). XZ tracks us, Y locked at ground. No drift.
					if cfg.aggressiveRange then
						ehrp.CFrame = CFrame.new(hrp.Position.X, targetOriginalY, hrp.Position.Z)
					end
				end
			else
				-- No enemy in range: just hold altitude where we were
				targetOriginalY = nil
				local holdY = lastHoldY or hrp.Position.Y
				desired = CFrame.new(hrp.Position.X, holdY, hrp.Position.Z)
			end

			if desired then
				hrp.CFrame = hrp.CFrame:Lerp(desired, math.min(1, dt * 10))
			end
		end)
	end

	local function autoSea1Loop()
		while gui.Parent do
			if cfg.autoSea1 then
				safe(autoSea1Tick)
				-- auto-Sea-1 implies auto-farm; flip it on if user forgot
				cfg.autoFarm = true
			end
			jwait(3.0)  -- check every 3s; no need to thrash quest logic
		end
	end

	local function autoFarmLoop()
		while gui.Parent do
			if cfg.autoFarm and getHash() then
				if not flightConn then startFlight() end

				safe(function()
					-- Wait until flight has acquired a target
					local enemy = currentTarget
					if not enemy or not enemy.Parent then
						jwait(0.3); return
					end

					-- Attack until target dies. Flight loop keeps repositioning
					-- and switching targets independently.
					local guard = 0
					while enemy.Parent and cfg.autoFarm and guard < 200 do
						attackOnce(enemy)
						guard = guard + 1
						jwait(cfg.attackCadence)
					end

					if enemy and not enemy.Parent then
						stats.sessionKills = stats.sessionKills + 1
						-- Reset target memory so flight picks the next enemy
						currentTarget = nil
						targetOriginalY = nil
					end
				end)
			else
				stopFlight()
				jwait(0.5)
			end
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

	-- track XP / Beli gain for the stats panel
	local function trackProgressLoop()
		local lastXP = LocalPlayer.Data.Exp.Value
		local lastBeli = LocalPlayer.Data.Beli.Value
		while gui.Parent do
			task.wait(1)
			local xp = LocalPlayer.Data.Exp.Value
			local beli = LocalPlayer.Data.Beli.Value
			if xp > lastXP then
				stats.sessionXP = stats.sessionXP + (xp - lastXP)
			elseif xp < lastXP then
				-- level up reset
			end
			if beli > lastBeli then
				stats.sessionBeli = stats.sessionBeli + (beli - lastBeli)
			end
			lastXP = xp
			lastBeli = beli
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
			if v and not getHash() then
				Toast.show({
					title = "Hash not captured yet",
					body = "Take one M1 swing on any enemy so we can sniff the session hash, then re-enable.",
					kind = "warn", duration = 8,
				})
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
	ui.intervalRow(farm, "Tween speed (studs/sec)",
		function() return cfg.farmTweenSpeed end,
		function(v) cfg.farmTweenSpeed = v end,
		{ 200, 300, 350, 500, 800 })

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
				if not getHash() then
					Toast.show({
						title = "Hash not captured",
						body  = "M1 once on any enemy first, then re-enable.",
						kind = "warn", duration = 8,
					})
				end
				cfg.autoFarm = true  -- auto-farm is implied
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
				getHash() or "(swing M1 once to capture)"
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

	ui.actionBtn(settings, "Forget session hash (force re-capture)", function()
		clearHash()
		Toast.show({
			title = "Hash cleared",
			body = "Swing M1 once on any enemy to capture a fresh hash.",
			kind = "info", duration = 6,
		})
	end)

	ui.actionBtn(settings, "Dump spy buffer to console", function()
		print("=== Vellum BF spy buffer (" .. #SPY.log .. " entries) ===")
		for i = math.max(1, #SPY.log - 60), #SPY.log do
			local r = SPY.log[i]
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
		body = "Swing M1 once on any enemy to capture your session hash, then toggle Auto-farm.",
		kind = "info", duration = 8,
	})

	print("[Vellum BF] module loaded.")
end

return Module
