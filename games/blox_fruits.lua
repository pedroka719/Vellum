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
	ui.newTab("stats",    "Stats",    2)
	ui.newTab("settings", "Settings", 3)
	ui.setActiveTab("farm")

	-- ═══════════════════════════ KICK OFF ═══════════════════════════
	task.spawn(autoFarmLoop)
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
