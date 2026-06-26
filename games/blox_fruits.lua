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

	-- ═══════════════════════════ R TABLE ═══════════════════════════
	-- Resolved once. If any of these is nil at boot, the script aborts loudly
	-- — better than silent failure deep in a loop.
	local Net = ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Net")
	local Remotes = ReplicatedStorage:WaitForChild("Remotes")

	local R = {
		-- combat (verified)
		RegisterAttack = Net:WaitForChild("RE/RegisterAttack"),
		RegisterHit    = Net:WaitForChild("RE/RegisterHit"),
		EquipEvent     = Remotes:WaitForChild("EquipEvent"),
		-- dispatchers
		CommF_         = Remotes:WaitForChild("CommF_"),
		CommF          = Remotes:WaitForChild("CommF"),
		CommE          = Remotes:WaitForChild("CommE"),
		-- direct verbs (read by their dispatcher pattern, not InvokeServer)
		Stats          = Remotes:WaitForChild("Stats"),
		Combo          = Remotes:WaitForChild("Combo"),
		Raids          = Remotes:WaitForChild("Raids"),
		Leviathan      = Remotes:WaitForChild("Leviathan"),
		SegmentHit     = Remotes:WaitForChild("SegmentHit"),
		Redeem         = Remotes:WaitForChild("Redeem"),
		QuestUpdate    = Remotes:WaitForChild("QuestUpdate"),
		Chest          = Remotes:WaitForChild("Chest"),
	}

	-- ═══════════════════════════ CONFIG ═══════════════════════════
	local cfg = {
		-- master AFK
		afkMode = false,

		-- farm
		autoFarm = false,
		farmHeight = 8,             -- studs above target (safe farm)
		farmTweenSpeed = 350,       -- studs/sec; under the 1500 velocity cap
		attackCadence = 0.18,       -- sec between RegisterAttack/Hit pairs
		damageMultiplier = 1.0,     -- 1.0 = always finisher hits
		farmLevelMin = 0,           -- only attack enemies within range
		farmLevelMax = 9999,
		farmTargetName = "",        -- "" = any enemy. Set to "Bandit" etc.

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

	local SESSION_HASH = nil      -- captured from first real RegisterHit
	local jwait = Helpers.makeJwait(cfg)
	local safe = Helpers.makeSafe("Vellum BF")

	-- ═══════════════════════════ PERSISTENT SPY ═══════════════════════════
	-- Rolling log of last N remote calls. Captures the hash on first sight.
	-- Freezes on detected punishment so we can post-mortem.
	getgenv().VellumBF = getgenv().VellumBF or {}
	local SPY = getgenv().VellumBF
	SPY.log = SPY.log or {}
	SPY.frozen = false

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
					-- session hash auto-capture: first real RegisterHit
					if nm == "RE/RegisterHit" and not SESSION_HASH then
						local _, _, _, h = ...
						if type(h) == "string" and #h == 8 then
							SESSION_HASH = h
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
		if not part or not SESSION_HASH then return false end
		safe(function() R.RegisterAttack:FireServer(cfg.damageMultiplier) end)
		safe(function() R.RegisterHit:FireServer(part, {}, nil, SESSION_HASH) end)
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
	local function autoFarmLoop()
		while gui.Parent do
			if cfg.autoFarm and SESSION_HASH then
				safe(function()
					local enemy = pickEnemy()
					if not enemy then jwait(0.5); return end

					-- safe-farm position: N studs above target
					local target = enemy.HumanoidRootPart.CFrame * CFrame.new(0, cfg.farmHeight, 0)
					tweenTo(target)

					local guard = 0
					while enemy.Parent and cfg.autoFarm and guard < 100 do
						-- maintain hover even as target moves
						local ehrp = enemy:FindFirstChild("HumanoidRootPart")
						if not ehrp then break end
						local ch = LocalPlayer.Character
						local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
						if hrp then
							local desired = ehrp.CFrame * CFrame.new(0, cfg.farmHeight, 0)
							if (hrp.Position - desired.Position).Magnitude > 4 then
								-- nudge hover without full re-tween every tick
								hrp.CFrame = desired
							end
						end
						attackOnce(enemy)
						guard = guard + 1
						jwait(cfg.attackCadence)
					end

					if enemy and not enemy.Parent then
						stats.sessionKills = stats.sessionKills + 1
					end
				end)
			else
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
	local gui = ui.gui

	Toast.init({ theme = Theme, enabled = function() return cfg.notifyInGame end })

	-- ─── FARM TAB ───
	local farm = ui.newPage("farm")
	ui.sectionLabel(farm, "AUTO FARM")
	ui.toggleRow(farm, "Auto-farm enemies",
		function() return cfg.autoFarm end,
		function(v)
			cfg.autoFarm = v
			if v and not SESSION_HASH then
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
		{ 4, 6, 8, 10, 14 })
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

	local statBtn = ui.actionBtn(statsPage, "Stat priority: " .. cfg.statPriority, function() end)
	do
		local order = { "Melee", "Defense", "Sword", "Gun", "Demon Fruit" }
		statBtn.MouseButton1Click:Connect(function()
			local idx = 1
			for i, n in ipairs(order) do if n == cfg.statPriority then idx = i; break end end
			cfg.statPriority = order[(idx % #order) + 1]
			statBtn.Text = "Stat priority: " .. cfg.statPriority
		end)
	end

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
				SESSION_HASH or "(swing M1 once to capture)"
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
