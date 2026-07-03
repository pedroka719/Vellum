-- Vellum — game module: Spin a Soccer Card
-- PlaceId 112490729816320
--
-- Module protocol expected by the loader:
--   { name, placeIds, start(lib) }
--
-- The full game runs inside start(). lib bundles { theme, helpers, toast, ui }
-- from the shared modules.

local LOADER_URL = "https://raw.githubusercontent.com/pedroka719/Vellum/main/loader.lua"

local Module = {
	name = "Spin a Soccer Card",
	placeIds = { 112490729816320 },
}

function Module.start(lib)
	-- ═══════════════════════════ services ═══════════════════════════
	local Players          = game:GetService("Players")
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local UserInputService = game:GetService("UserInputService")
	local VirtualUser      = game:GetService("VirtualUser")
	local HttpService      = game:GetService("HttpService")
	local TeleportService  = game:GetService("TeleportService")
	local TweenService     = game:GetService("TweenService")
	local RunService       = game:GetService("RunService")
	local LocalPlayer      = Players.LocalPlayer

	-- ═══════════════════════════ game requires ═══════════════════════════
	local Networker         = require(ReplicatedStorage.Source.Shared.Networker)
	local PlayerStore       = require(ReplicatedStorage.Source.Shared.State.PlayerStore)
	local CardConfig        = require(ReplicatedStorage.Source.Shared.Configs.CardConfig)
	local RebirthConfig     = require(ReplicatedStorage.Source.Shared.Configs.RebirthConfig)
	local PackConfig        = require(ReplicatedStorage.Source.Shared.Configs.PackConfig)
	local TournamentConfig  = require(ReplicatedStorage.Source.Shared.Configs.TournamentConfig)
	local TournamentClock   = require(ReplicatedStorage.Source.Shared.Helpers.TournamentClock)
	local MutationConfig    = require(ReplicatedStorage.Source.Shared.Configs.MutationConfig)

	-- ═══════════════════════════ lib bundle ═══════════════════════════
	local Theme   = lib.theme
	local Helpers = lib.helpers
	local Toast   = lib.toast
	local UI      = lib.ui

	local fmt       = Helpers.fmt
	local fmtDur    = Helpers.fmtDur
	local perHour   = Helpers.perHour
	local parseCash = Helpers.parseCash
	local toast     = Toast.show

	-- ═══════════════════════════ remotes ═══════════════════════════
	local R = {
		CollectSlot       = Networker.get_remote("CollectSlot"),
		BuyPack           = Networker.get_remote("BuyPack"),
		SetAutoBuy        = Networker.get_remote("SetAutoBuy"),
		OpenPack          = Networker.get_remote("OpenPack"),
		SellCards         = Networker.get_remote("SellCards"),
		UpdateAutoSell    = Networker.get_remote("UpdateAutoSell"),
		Rebirth           = Networker.get_remote("Rebirth"),
		LockCard          = Networker.get_remote("LockCard"),
		RedeemCode        = Networker.get_remote("RedeemCode"),
		DailyReward       = Networker.get_remote("DailyReward"),
		OfflineReward     = Networker.get_remote("OfflineReward"),
		LeaveReward       = Networker.get_remote("LeaveReward"),
		SpinWheel         = Networker.get_remote("SpinWheel"),
		AttemptThrone     = Networker.get_remote("AttemptThrone"),
		ClaimAllIndexGems = Networker.get_remote("ClaimAllIndexGems"),
		UpdateSetting     = Networker.get_remote("UpdateSetting"),
		CraftTrophy       = Networker.get_remote("CraftTrophy"),
		ApplyTrophy       = Networker.get_remote("ApplyTrophy"),
		EquipCard         = Networker.get_remote("EquipCard"),
		UnequipCard       = Networker.get_remote("UnequipCard"),
		SpinWheelData     = Networker.get_remotefunction("SpinWheelData"),
		Tournament        = Networker.get_remote("Tournament"),
		TournamentState   = Networker.get_remotefunction("TournamentState"),
	}

	-- ═══════════════════════════ config + stats ═══════════════════════════
	local cfg = {
		autoCollect       = false,
		autoCollectInt    = 1.0,
		autoBuy           = false,
		autoBuyInt        = 2.0,
		autoBuyPacks      = { Bronze=true, Silver=true, Gold=true },
		buyTopN           = 5,
		pitySniper        = true,
		pitySnipeWithin   = 3,
		evSort            = false,
		autoOpen          = false,
		autoOpenInt       = 1.5,
		antiAfk           = true,
		autoSell          = false,
		autoSellInt       = 5.0,
		autoSellRarities  = { Bronze=true, Silver=true, Gold=true },
		rebirthSafe       = true,
		mutationKeep      = 2,
		keepWithTrophy    = true,
		autoRebirth       = true,
		autoEquipBest     = true,
		autoEquipInt      = 8.0,
		autoDaily         = true,
		autoOffline       = true,
		autoLeave         = true,
		autoSpin          = true,
		autoThrone        = false,
		autoIndexGems     = true,
		autoTournament    = true,
		jitter            = true,
		webhookUrl        = "",
		webhookIntMin     = 10,
		keybindToggle     = true,
		conservativeMode  = true,
		lowDetail         = true,
		crashRecover      = true,
		serverHop         = false,
		serverHopOnBadPing = false,
		pingHopThreshold  = 350,
		hopOnLowFps       = false,
		fpsHopThreshold   = 12,
		-- trading
		tradeTarget               = "",
		tradeAutoAcceptFromTarget = true,
		tradeAutoFillOnOpen       = true,
		tradeAutoSendLoop         = false,
		tradeMaxCards             = 9,
		tradeIntervalSec          = 180,
		tradeAutoTpBeforeRequest  = true,
		-- notifications
		notifyInGame              = true,
		notifyMinRarityWeight     = 100,
		notifyMutationMin         = 1,
		-- presentation
		themeName                 = "Vellum",
		afkMode                   = false,
	}

	local stats = {
		sessionStart      = os.clock(),
		sessionCash       = 0,
		sessionSells      = 0,
		sessionPacks      = 0,
		sessionRebirths   = 0,
		serverHops        = 0,
		tournamentsJoined = 0,
		tradesCompleted   = 0,
		bestRarity        = nil,
		bestRarityWeight  = 0,
		bestMutationCount = 0,
	}

	-- Wire Toast's "show?" predicate to our cfg now that it exists
	Toast.init({ theme = Theme, enabled = function() return cfg.notifyInGame end })

	-- ═══════════════════════════ helpers ═══════════════════════════
	local jwait = Helpers.makeJwait(cfg)
	local safe  = Helpers.makeSafe("Vellum")

	local function getMe()
		local s = PlayerStore()
		if not s or not s.players then return nil end
		return s.players[tostring(LocalPlayer.UserId)]
	end

	local slotCashCache = setmetatable({}, { __mode = "k" })
	local function findCashLabel(slot)
		local cached = slotCashCache[slot]
		if cached and cached.Parent then return cached end
		for _, d in ipairs(slot:GetDescendants()) do
			if d:IsA("TextLabel") and d.Name == "CashText" then
				slotCashCache[slot] = d
				return d
			end
		end
	end

	local function cardIncome(card)
		local def = CardConfig.Cards[card.id]
		if not def then return 0 end
		local base = (MutationConfig and MutationConfig.calculateIncome)
			and MutationConfig.calculateIncome(def.IncomeRate or 0, card.mutations or {})
			or (def.IncomeRate or 0)
		return base
	end

	local function cardRarity(card)
		local def = CardConfig.Cards[card.id]
		return def and def.Rarity or "Unknown"
	end

	-- All cards the player owns: inventory + equipped slots. Both count
	-- for rebirth requirements and tournament team picks.
	local function ownedCardPool(me)
		local pool = {}
		for _, c in ipairs(me and me.inventory or {}) do table.insert(pool, c) end
		if me and me.slots then
			for _, s in pairs(me.slots) do
				if type(s) == "table" and s.card and s.card.id then
					table.insert(pool, s.card)
				end
			end
		end
		return pool
	end

	-- RebirthConfig only exposes functions (.GetRebirth, .GetMaxRebirth).
	-- Reserves cards needed for the NEXT rebirth tier only.
	local function buildRebirthReservation()
		local me = getMe()
		local current = me and me.rebirth or 0
		local exact, rarities = {}, {}
		local tier = RebirthConfig.GetRebirth(current + 1)
		if not tier then return exact, rarities end
		for _, req in ipairs(tier.RequiredCards or {}) do
			if req:sub(1, 4) == "any:" then
				local r = req:sub(5)
				rarities[r] = (rarities[r] or 0) + 1
			else
				exact[req] = (exact[req] or 0) + 1
			end
		end
		return exact, rarities
	end

	local function getEquippedUuids()
		local me = getMe()
		local set = {}
		if not me or not me.slots then return set end
		for _, slot in pairs(me.slots) do
			if type(slot) == "table" and slot.card and slot.card.uuid then
				set[slot.card.uuid] = true
			end
		end
		return set
	end

	-- Returns array of UUIDs eligible to sell from the picked rarities, respecting rebirth-safe.
	local function pickSellable(picked, rebirthSafe)
		local me = getMe()
		if not me or not me.inventory then return {} end
		local equipped = getEquippedUuids()
		local exact, rarities = buildRebirthReservation()
		local exactLeft, rarityLeft = {}, {}
		for k, v in pairs(exact) do exactLeft[k] = v end
		for k, v in pairs(rarities) do rarityLeft[k] = v end

		-- sort by income ascending so we sacrifice low earners first
		local sorted = {}
		for _, c in ipairs(me.inventory) do table.insert(sorted, c) end
		table.sort(sorted, function(a, b) return cardIncome(a) < cardIncome(b) end)

		local reservedSet = {}
		if rebirthSafe then
			for _, c in ipairs(sorted) do
				if exactLeft[c.id] and exactLeft[c.id] > 0 then
					reservedSet[c.uuid] = true
					exactLeft[c.id] = exactLeft[c.id] - 1
				end
			end
			for _, c in ipairs(sorted) do
				if not reservedSet[c.uuid] then
					local r = cardRarity(c)
					if rarityLeft[r] and rarityLeft[r] > 0 then
						reservedSet[c.uuid] = true
						rarityLeft[r] = rarityLeft[r] - 1
					end
				end
			end
		end

		local out = {}
		for _, c in ipairs(me.inventory) do
			local r = cardRarity(c)
			local mutCount = c.mutations and #c.mutations or 0
			local keepMut = cfg.mutationKeep > 0 and mutCount >= cfg.mutationKeep
			local keepTrophy = cfg.keepWithTrophy and c.trophy ~= nil
			if picked[r]
			   and not reservedSet[c.uuid]
			   and not equipped[c.uuid]
			   and not c.locked
			   and not c.throneCard
			   and not keepMut
			   and not keepTrophy
			   and c.id ~= "OwnerVulnone"
			   and c.id ~= "LocalCard"
			then
				table.insert(out, c.uuid)
			end
		end
		return out
	end

	-- ═══════════════════════════ pack EV + buy logic ═══════════════════════════
	local PACK_QUEUE_CAP = 25
	local inFlight = {}

	local RARITY_WEIGHT = {
		Bronze = 1, Silver = 3, Gold = 10, Legendary = 30, Mythic = 100,
		["Azure Zenith"] = 300, ["Crimson Zenith"] = 600, Divine = 1200,
		Primordial = 4000, Oblivion = 8000, Eternity = 15000, Astral = 25000,
		Sovereign = 40000, Vandal = 60000, Verdant = 80000, Lunar = 100000, Nether = 150000,
	}

	-- Pity counters live in two places: packPityCounts (mid-tier) and me.shop.pity (top-tier)
	local function pityBuysRemaining(packName, packDef)
		local def = packDef or PackConfig.Packs[packName]
		if not def or not def.Pity or not def.Pity.every then return math.huge end
		local me = getMe(); if not me then return math.huge end
		local counter = (me.packPityCounts and me.packPityCounts[packName])
			or (me.shop and me.shop.pity and me.shop.pity[packName])
			or 0
		counter = counter + (inFlight and inFlight[packName] or 0)
		return math.max(0, def.Pity.every - counter)
	end

	-- EV per dollar: sum(rarity_weight * drop_rate) / price, applying me.shop.boost to HiddenRewards.
	local function packEV(def, boost)
		if not def or (def.Price or 0) <= 0 then return 0 end
		local sum = 0
		for r, pct in pairs(def.Rewards or {}) do
			sum = sum + (RARITY_WEIGHT[r] or 0) * (pct / 100)
		end
		local boostMult = 1 + (boost or 0)
		for r, pct in pairs(def.HiddenRewards or {}) do
			sum = sum + (RARITY_WEIGHT[r] or 0) * (pct / 100) * boostMult
		end
		return sum / def.Price
	end

	-- Returns enabled cash-buyable packs sorted by LayoutOrder (default) or EV (if cfg.evSort).
	local function enabledPacksByPriority()
		local list = {}
		for packName, enabled in pairs(cfg.autoBuyPacks) do
			if enabled then
				local def = PackConfig.Packs[packName]
				if def
				   and (def.Currency == "Cash" or not def.Currency)
				   and (def.Price or 0) > 0 then
					table.insert(list, { name = packName, def = def, order = def.LayoutOrder or 0 })
				end
			end
		end
		if cfg.evSort then
			local me = getMe()
			local boost = (me and me.shop and me.shop.boost) or 0
			for _, e in ipairs(list) do e.ev = packEV(e.def, boost) end
			table.sort(list, function(a, b) return a.ev > b.ev end)
		else
			table.sort(list, function(a, b) return a.order > b.order end)
		end
		return list
	end

	-- In-flight buy tracker — server stock lags ~1-2s behind our FireServer.
	-- Decays after 3s.
	local function reserveBuy(packName)
		inFlight[packName] = (inFlight[packName] or 0) + 1
		task.delay(3, function()
			inFlight[packName] = math.max(0, (inFlight[packName] or 0) - 1)
		end)
	end

	-- ═══════════════════════════ canRebirth ═══════════════════════════
	local function canRebirth()
		local me = getMe()
		if not me then return false, "no_state" end
		local cur = me.rebirth or 0
		local tier = RebirthConfig.GetRebirth(cur + 1)
		if not tier then return false, "max_rebirth" end
		if (me.cash or 0) < (tier.CashRequired or 0) then
			return false, string.format("need $%s more cash",
				fmt((tier.CashRequired or 0) - (me.cash or 0)))
		end
		if tier.GemsRequired and (me.gems or 0) < tier.GemsRequired then
			return false, string.format("need %d more gems",
				tier.GemsRequired - (me.gems or 0))
		end
		local exactLeft, rarityLeft = {}, {}
		for _, req in ipairs(tier.RequiredCards or {}) do
			if req:sub(1, 4) == "any:" then
				rarityLeft[req:sub(5)] = (rarityLeft[req:sub(5)] or 0) + 1
			else
				exactLeft[req] = (exactLeft[req] or 0) + 1
			end
		end
		for _, c in ipairs(ownedCardPool(me)) do
			if exactLeft[c.id] and exactLeft[c.id] > 0 then
				exactLeft[c.id] = exactLeft[c.id] - 1
			else
				local r = cardRarity(c)
				if rarityLeft[r] and rarityLeft[r] > 0 then
					rarityLeft[r] = rarityLeft[r] - 1
				end
			end
		end
		for name, n in pairs(exactLeft) do
			if n > 0 then return false, string.format("missing card: %s (need %d)", name, n) end
		end
		for rarity, n in pairs(rarityLeft) do
			if n > 0 then return false, string.format("missing rarity: %s (need %d)", rarity, n) end
		end
		return true, "ready"
	end

	-- ═══════════════════════════ UI mount ═══════════════════════════
	-- Mount the chrome NOW so the loops can guard with `ui.gui.Parent`.
	-- Tabs + content are populated in pass 5b.
	local ui = UI.mount({
		title    = "V E L L U M",
		subtitle = "spin a soccer card",
		onClose  = function() end,
	})
	local gui = ui.gui  -- alias for loop teardown checks

	-- ═══════════════════════════ AUTO LOOPS ═══════════════════════════
	local function autoCollectLoop()
		while gui.Parent do
			if cfg.autoCollect then
				safe(function()
					local plotId = LocalPlayer:GetAttribute("AssignedPlot")
					if not plotId then return end
					local plots = workspace:FindFirstChild("Plots")
					local plot = plots and plots:FindFirstChild(tostring(plotId))
					local slots = plot and plot:FindFirstChild("Slots")
					if not slots then return end
					for _, slot in ipairs(slots:GetChildren()) do
						local n = tonumber(slot.Name)
						if n then
							local lbl = findCashLabel(slot)
							local cash = lbl and parseCash(lbl.Text or "") or 0
							if cash > 0 then
								R.CollectSlot:FireServer(n)
								stats.sessionCash = stats.sessionCash + cash
							end
						end
					end
				end)
			end
			jwait(cfg.autoCollectInt)
		end
	end

	local function autoBuyLoop()
		while gui.Parent do
			if cfg.autoBuy then
				safe(function()
					local me = getMe(); if not me then return end
					local queue = me.packs or {}
					local stocks = (me.shop and me.shop.stocks) or {}
					local cashBudget = me.cash or 0
					local list = enabledPacksByPriority()
					local topN = cfg.buyTopN or 0

					local function tryBuy(entry)
						local def = entry.def
						local owned = tonumber(queue[entry.name]) or 0
						local effectiveStock = (tonumber(stocks[entry.name]) or 0) - (inFlight[entry.name] or 0)
						if effectiveStock > 0
						   and owned < PACK_QUEUE_CAP
						   and cashBudget >= (def.Price or 0)
						   and (me.rebirth or 0) >= (def.RebirthReq or 0) then
							R.BuyPack:FireServer(entry.name)
							reserveBuy(entry.name)
							stats.sessionPacks = stats.sessionPacks + 1
							cashBudget = cashBudget - (def.Price or 0)
							return true
						end
						return false
					end

					-- Pity-snipe pass: any pack within pitySnipeWithin of guaranteed pity gets bought first
					local snipeFired = 0
					if cfg.pitySniper then
						local sniped = {}
						for _, entry in ipairs(list) do
							local remaining = pityBuysRemaining(entry.name, entry.def)
							if remaining > 0 and remaining <= cfg.pitySnipeWithin then
								table.insert(sniped, { entry = entry, remaining = remaining })
							end
						end
						table.sort(sniped, function(a, b) return a.remaining < b.remaining end)
						for _, s in ipairs(sniped) do
							if tryBuy(s.entry) then snipeFired = snipeFired + 1 end
						end
					end

					local fired = snipeFired
					for i, entry in ipairs(list) do
						if topN > 0 and i > topN then break end
						if tryBuy(entry) then fired = fired + 1 end
					end
					-- Fallback: if nothing fired in primaries, try the rest
					if fired == 0 and topN > 0 then
						for i, entry in ipairs(list) do
							if i > topN then tryBuy(entry) end
						end
					end
				end)
			end
			jwait(cfg.autoBuyInt)
		end
	end

	local function autoOpenLoop()
		while gui.Parent do
			if cfg.autoOpen then
				safe(function()
					local me = getMe()
					if not me or not me.packs then return end
					-- open ONE of each pack type per tick — drains all queues in parallel
					local pending = {}
					for packName, count in pairs(me.packs) do
						if type(count) == "number" and count > 0 then
							local def = PackConfig.Packs[packName]
							table.insert(pending, { name = packName, order = (def and def.LayoutOrder) or 0 })
						end
					end
					table.sort(pending, function(a, b) return a.order > b.order end)
					for _, entry in ipairs(pending) do
						R.OpenPack:FireServer(entry.name)
					end
				end)
			end
			jwait(cfg.autoOpenInt)
		end
	end

	local function autoSellLoop()
		while gui.Parent do
			if cfg.autoSell then
				safe(function()
					local uuids = pickSellable(cfg.autoSellRarities, cfg.rebirthSafe)
					if #uuids > 0 then
						R.SellCards:FireServer(uuids)
						stats.sessionSells = stats.sessionSells + #uuids
					end
				end)
			end
			jwait(cfg.autoSellInt)
		end
	end

	local _rebirthLastWhy, _rebirthLastWhyToastAt = nil, 0
	local function autoRebirthLoop()
		while gui.Parent do
			if cfg.autoRebirth then
				safe(function()
					local ok, why = canRebirth()
					if ok then
						R.Rebirth:FireServer()
						stats.sessionRebirths = stats.sessionRebirths + 1
						toast({ title = "Rebirth!", body = "Auto-rebirth fired.", kind = "success", duration = 6 })
						task.wait(5)
					else
						-- Surface persistent block reasons every 5 min (skip cash/gems noise)
						if why ~= _rebirthLastWhy then
							_rebirthLastWhy = why
							_rebirthLastWhyToastAt = 0
						end
						if os.clock() - _rebirthLastWhyToastAt > 300 then
							_rebirthLastWhyToastAt = os.clock()
							if not (tostring(why):find("cash") or tostring(why):find("gems")) then
								toast({ title = "Auto-rebirth blocked", body = tostring(why), kind = "warn", duration = 8 })
							end
						end
					end
				end)
			end
			task.wait(3)
		end
	end

	local function autoClaimsLoop()
		while gui.Parent do
			safe(function()
				if cfg.autoDaily then pcall(function() R.DailyReward:FireServer() end) end
				if cfg.autoOffline then pcall(function() R.OfflineReward:FireServer() end) end
				if cfg.autoLeave then pcall(function() R.LeaveReward:FireServer() end) end
				if cfg.autoThrone then pcall(function() R.AttemptThrone:FireServer() end) end
				if cfg.autoSpin then
					pcall(function()
						local data = R.SpinWheelData:InvokeServer()
						if not data then return end
						if data.canClaimFree then
							R.SpinWheel:FireServer("claim_free")
						elseif (data.spins or 0) > 0 then
							R.SpinWheel:FireServer("spin")
						end
					end)
				end
			end)
			task.wait(30)
		end
	end

	-- Auto-equip best: top N owned cards (inventory + slots) by income → N unlocked slots
	local function autoEquipBestLoop()
		while gui.Parent do
			if cfg.autoEquipBest then
				safe(function()
					local me = getMe()
					if not me or not me.unlockedSlots or not me.slots then return end

					local candidates = {}
					for _, c in ipairs(me.inventory or {}) do
						if c.uuid and c.id ~= "LocalCard" and c.id ~= "OwnerVulnone" then
							table.insert(candidates, c)
						end
					end
					for _, slot in pairs(me.slots) do
						if slot and slot.card and slot.card.uuid then
							table.insert(candidates, slot.card)
						end
					end
					if #candidates == 0 then return end

					table.sort(candidates, function(a, b) return cardIncome(a) > cardIncome(b) end)

					local slotNums = {}
					for k in pairs(me.unlockedSlots) do
						local n = tonumber(k); if n then table.insert(slotNums, n) end
					end
					table.sort(slotNums)

					for i, slotNum in ipairs(slotNums) do
						local pick = candidates[i]
						if not pick then break end
						local current = me.slots[tostring(slotNum)]
						local currentUuid = current and current.card and current.card.uuid
						if currentUuid ~= pick.uuid then
							pcall(function() R.EquipCard:FireServer(pick.uuid, slotNum) end)
							task.wait(0.15)
						end
					end
				end)
			end
			jwait(cfg.autoEquipInt)
		end
	end

	local function antiAfkLoop()
		LocalPlayer.Idled:Connect(function()
			if cfg.antiAfk then
				pcall(function()
					VirtualUser:CaptureController()
					VirtualUser:ClickButton2(Vector2.new())
				end)
			end
		end)
	end

	-- ═══════════════════════════ LOW DETAIL ═══════════════════════════
	local _lowDetailApplied = false
	local function applyLowDetail(on)
		pcall(function() R.UpdateSetting:FireServer("lowDetailMode", on) end)
		pcall(function() R.UpdateSetting:FireServer("CardAnimations", not on) end)
		_lowDetailApplied = on
	end
	local function lowDetailLoop()
		while gui.Parent do
			if cfg.lowDetail and not _lowDetailApplied then
				applyLowDetail(true)
			elseif not cfg.lowDetail and _lowDetailApplied then
				applyLowDetail(false)
			end
			task.wait(15)
		end
	end

	-- ═══════════════════════════ CRASH RECOVERY ═══════════════════════════
	local _crashRecoverQueued = false
	local function setupCrashRecover()
		if _crashRecoverQueued then return end
		if not cfg.crashRecover then return end
		local q = (syn and syn.queue_on_teleport)
			or queue_on_teleport
			or (fluxus and fluxus.queue_on_teleport)
		if not q then
			warn("[Vellum crash-recover] executor lacks queue_on_teleport — skipping")
			return
		end
		pcall(function()
			q(string.format('loadstring(game:HttpGet("%s"))()', LOADER_URL))
			_crashRecoverQueued = true
		end)
	end

	-- ═══════════════════════════ SERVER HOP ═══════════════════════════
	local function fetchPublicServers(cursor)
		local url = string.format(
			"https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100%s",
			game.PlaceId,
			cursor and ("&cursor=" .. cursor) or ""
		)
		local ok, body = pcall(function() return game:HttpGet(url) end)
		if not ok then return nil end
		local ok2, data = pcall(function() return HttpService:JSONDecode(body) end)
		if not ok2 then return nil end
		return data
	end

	local function scoreServer(s)
		-- Lower is better. Want low ping, not full, not empty.
		local fillRatio = (s.playing or 0) / math.max(1, s.maxPlayers or 1)
		local fillPenalty = fillRatio > 0.9 and 200 or 0
		local emptyPenalty = (s.playing or 0) == 0 and 150 or 0
		local ping = tonumber(s.ping) or 250
		return ping + fillPenalty + emptyPenalty
	end

	local function pickBestServer()
		local page = fetchPublicServers()
		if not page or not page.data then return nil end
		local best, bestScore
		for _, s in ipairs(page.data) do
			if s.id ~= game.JobId
			   and (s.playing or 0) < (s.maxPlayers or 0) then
				local score = scoreServer(s)
				if not best or score < bestScore then
					best, bestScore = s, score
				end
			end
		end
		return best
	end

	local function hopNow()
		local s = pickBestServer()
		if not s then
			warn("[Vellum hop] no server found")
			return false
		end
		warn(string.format("[Vellum hop] → jobId=%s (%d/%d)",
			s.id, s.playing or 0, s.maxPlayers or 0))
		stats.serverHops = stats.serverHops + 1
		toast({
			title = "Server hop",
			body  = string.format("→ %dms · %d/%d", s.ping or 0, s.playing or 0, s.maxPlayers or 0),
			kind  = "hop",
			duration = 4,
		})
		pcall(function()
			TeleportService:TeleportToPlaceInstance(game.PlaceId, s.id, LocalPlayer)
		end)
		return true
	end

	local function serverHopLoop()
		local Stats = game:GetService("Stats")
		local badPingSince, badFpsSince = nil, nil
		local frameTimes, frameIdx = {}, 1
		RunService.RenderStepped:Connect(function(dt)
			frameTimes[frameIdx] = dt
			frameIdx = (frameIdx % 60) + 1
		end)
		while gui.Parent do
			if cfg.serverHop and cfg.serverHopOnBadPing then
				local ok, ping = pcall(function()
					return Stats.Network.ServerStatsItem["Data Ping"]:GetValue()
				end)
				if ok and ping and ping > (cfg.pingHopThreshold or 350) then
					badPingSince = badPingSince or os.clock()
					if os.clock() - badPingSince > 30 then
						warn(string.format("[Vellum hop] ping %.0fms > %dms for 30s, hopping",
							ping, cfg.pingHopThreshold))
						if hopNow() then return end
					end
				else
					badPingSince = nil
				end
			end
			if cfg.serverHop and cfg.hopOnLowFps then
				local sum, n = 0, 0
				for _, t in pairs(frameTimes) do sum, n = sum + t, n + 1 end
				local fps = n > 0 and (n / sum) or 60
				if fps < (cfg.fpsHopThreshold or 12) then
					badFpsSince = badFpsSince or os.clock()
					if os.clock() - badFpsSince > 30 then
						warn(string.format("[Vellum hop] fps %.1f for 30s, hopping", fps))
						if hopNow() then return end
					end
				else
					badFpsSince = nil
				end
			end
			task.wait(10)
		end
	end

	-- ═══════════════════════════ INVENTORY WATCHER ═══════════════════════════
	-- Detects new cards added to inventory, fires toasts for rare pulls,
	-- updates session bests.
	local _seenUuids = nil
	local function inventoryWatchLoop()
		while gui.Parent do
			safe(function()
				local me = getMe()
				if not me or not me.inventory then return end
				if _seenUuids == nil then
					_seenUuids = {}
					for _, c in ipairs(me.inventory) do _seenUuids[c.uuid] = true end
					return
				end
				for _, c in ipairs(me.inventory) do
					if not _seenUuids[c.uuid] then
						_seenUuids[c.uuid] = true
						local r = cardRarity(c)
						local w = RARITY_WEIGHT[r] or 0
						if w > (stats.bestRarityWeight or 0) then
							stats.bestRarityWeight = w
							stats.bestRarity = r
							toast({
								title = "★ New best rarity",
								body  = string.format("%s — %s", r, c.id or "?"),
								kind  = w >= 1000 and "epic" or "rare",
								key   = "bestRarity:" .. r,
								duration = 7,
							})
						end
						if w >= (cfg.notifyMinRarityWeight or 100) then
							toast({
								title = "Pulled " .. tostring(r),
								body  = tostring(c.id or "?"),
								kind  = w >= 1000 and "epic" or "rare",
								key   = "pull:" .. tostring(c.id),
								duration = 5,
							})
						end
						local mutCount = c.mutations and #c.mutations or 0
						if mutCount > (stats.bestMutationCount or 0) then
							stats.bestMutationCount = mutCount
						end
						if mutCount >= (cfg.notifyMutationMin or 1) then
							toast({
								title = string.format("✨ %dx mutation", mutCount),
								body  = string.format("%s (%s)", c.id or "?", r),
								kind  = mutCount >= 3 and "epic" or "rare",
								key   = "mut:" .. tostring(c.uuid),
								duration = 8,
							})
						end
					end
				end
			end)
			task.wait(2)
		end
	end

	-- ═══════════════════════════ TOURNAMENT ═══════════════════════════
	local function ensureTournamentTeam5()
		local me = getMe()
		if not me then return false, "no_player_data" end
		local team = (me.tournament and me.tournament.team) or {}
		local inTeam = {}
		for _, uuid in ipairs(team) do inTeam[uuid] = true end
		if #team >= 5 then return true end

		local seen, candidates = {}, {}
		for _, c in ipairs(ownedCardPool(me)) do
			if c.uuid and not seen[c.uuid] then
				seen[c.uuid] = true
				table.insert(candidates, c)
			end
		end
		table.sort(candidates, function(a, b) return (cardIncome(a) or 0) > (cardIncome(b) or 0) end)

		local added = 0
		for _, c in ipairs(candidates) do
			if #team + added >= 5 then break end
			if not inTeam[c.uuid] then
				pcall(function() R.Tournament:FireServer("team_add", c.uuid) end)
				inTeam[c.uuid] = true
				added = added + 1
				task.wait(0.15)
			end
		end
		if (#team + added) < 5 then
			return false, string.format("not_enough_cards(%d/%d)", #team + added, 5)
		end
		return true
	end

	local _lastJoinAt = 0
	local function autoTournamentLoop()
		while gui.Parent do
			if cfg.autoTournament then
				local ok, err = pcall(function()
					local me = getMe()
					if not me then return end

					local queued = me.tournament and me.tournament.queue ~= nil
					if queued then return end
					if LocalPlayer:GetAttribute("TournamentSessionActive") == true then return end

					local minRB = (TournamentConfig and TournamentConfig.MinRebirth) or 1
					if (me.rebirth or 0) < minRB then return end

					local phase = TournamentClock.derivePhase(workspace:GetServerTimeNow())
					if phase ~= "join_window" then return end

					if os.clock() - _lastJoinAt < 8 then return end
					_lastJoinAt = os.clock()

					local teamOk, teamErr = ensureTournamentTeam5()
					if not teamOk then
						warn("[Vellum tournament] team-fill blocked: " .. tostring(teamErr))
						toast({
							title = "Tournament skipped",
							body = "Need 5 cards: " .. tostring(teamErr),
							kind = "warn", duration = 6,
						})
						return
					end
					task.wait(0.4)

					R.Tournament:FireServer("join")
					stats.tournamentsJoined = stats.tournamentsJoined + 1
					warn("[Vellum] Tournament join fired (team=5)")
					toast({ title = "Tournament joined", body = "Queue locked in.", kind = "success", duration = 6 })
				end)
				if not ok then warn("[Vellum tournament] " .. tostring(err)) end
			end
			local phase = "countdown"
			pcall(function() phase = TournamentClock.derivePhase(workspace:GetServerTimeNow()) end)
			task.wait(phase == "join_window" and 3 or 15)
		end
	end

	-- ═══════════════════════════ INDEX GEMS ═══════════════════════════
	local function autoIndexGemsLoop()
		while gui.Parent do
			if cfg.autoIndexGems then
				pcall(function() R.ClaimAllIndexGems:FireServer() end)
			end
			task.wait(60)
		end
	end

	-- ═══════════════════════════ TRADING ═══════════════════════════
	local _tradeTargetCache = { username = nil, userId = nil }
	local function resolveTradeTarget()
		local name = (cfg.tradeTarget or ""):gsub("^%s+", ""):gsub("%s+$", "")
		if name == "" then return nil end
		if _tradeTargetCache.username == name and _tradeTargetCache.userId then
			return _tradeTargetCache.userId
		end
		local ok, uid = pcall(function() return Players:GetUserIdFromNameAsync(name) end)
		if ok and uid then
			_tradeTargetCache.username = name
			_tradeTargetCache.userId = uid
			return uid
		end
		return nil
	end

	-- Pick the N worst safe-to-trade cards, sorted income asc
	local function pickTradeable(maxCount)
		local picked = {}
		for _, rarity in ipairs({
			"Bronze","Silver","Gold","Platinum","Diamond","Ruby",
			"Emerald","Sapphire","Amethyst","Onyx","Nether",
		}) do
			picked[rarity] = true
		end
		local uuids = pickSellable(picked, true)
		local me = getMe()
		if not me or not me.inventory then return {} end
		local invByUuid = {}
		for _, c in ipairs(me.inventory) do invByUuid[c.uuid] = c end
		table.sort(uuids, function(a, b)
			local ca, cb = invByUuid[a], invByUuid[b]
			return cardIncome(ca or {}) < cardIncome(cb or {})
		end)
		local out = {}
		for i = 1, math.min(maxCount or cfg.tradeMaxCards, #uuids) do
			out[i] = uuids[i]
		end
		return out
	end

	local _tradeState = { inTrade = false, ourReady = false, lastSendAt = 0, lastRequestAt = 0 }
	local TRADE_REQUEST_COOLDOWN_SEC = 65

	local function canFireTradeRequest()
		return os.clock() - _tradeState.lastRequestAt >= TRADE_REQUEST_COOLDOWN_SEC
	end
	local function fireTradeRequest(userId)
		if not canFireTradeRequest() then
			local wait_s = math.ceil(TRADE_REQUEST_COOLDOWN_SEC - (os.clock() - _tradeState.lastRequestAt))
			warn(string.format("[Vellum trade] request blocked — cooldown %ds remaining", wait_s))
			return false
		end
		_tradeState.lastRequestAt = os.clock()
		pcall(function() R.Tournament:FireServer("request", userId) end)
		-- NOTE: above should fire on R.Trade — we don't have it as a remote alias yet.
		-- See post-pass-5a fix list.
		return true
	end

	-- TP next to a target player so trade requests with proximity gating succeed
	local function tpToPlayer(targetPlayer)
		if not targetPlayer then return false, "no_target" end
		local char = targetPlayer.Character
		local theirHRP = char and char:FindFirstChild("HumanoidRootPart")
		if not theirHRP then return false, "no_char" end
		local myChar = LocalPlayer.Character
		local myHRP = myChar and myChar:FindFirstChild("HumanoidRootPart")
		if not myHRP then return false, "no_my_char" end
		local offset = theirHRP.CFrame.LookVector * -5
		pcall(function() myHRP.CFrame = theirHRP.CFrame + offset end)
		return true
	end

	local function tpToTargetByUsername()
		local id = resolveTradeTarget()
		if not id then return false, "no_id" end
		local p = Players:GetPlayerByUserId(id)
		if not p then return false, "not_in_server" end
		return tpToPlayer(p)
	end

	-- Trade remote alias (TODO: add to R table above on next pass)
	local TradeRemote = Networker.get_remote("Trade")

	local function tradeAutoFill()
		if not cfg.tradeAutoFillOnOpen then return end
		local cards = pickTradeable(cfg.tradeMaxCards)
		if #cards == 0 then
			warn("[Vellum trade] no safe cards to send, cancelling")
			pcall(function() TradeRemote:FireServer("cancel") end)
			return
		end
		for i, uuid in ipairs(cards) do
			pcall(function() TradeRemote:FireServer("add_card", uuid) end)
			task.wait(0.25 + math.random() * 0.15)
		end
		task.wait(1.0)
		pcall(function() TradeRemote:FireServer("ready") end)
		_tradeState.ourReady = true
		warn(string.format("[Vellum trade] filled %d cards, ready fired", #cards))
	end

	local function setupTradeHandler()
		TradeRemote.OnClientEvent:Connect(function(payload)
			if type(payload) ~= "table" then return end
			local action = payload.action

			if action == "request_incoming" then
				if not cfg.tradeAutoAcceptFromTarget then return end
				local targetId = resolveTradeTarget()
				local senderId = payload.senderId or payload.userId
				if targetId and senderId == targetId then
					task.wait(0.4)
					pcall(function() TradeRemote:FireServer("accept", targetId) end)
					warn("[Vellum trade] auto-accepted from " .. tostring(targetId))
				end

			elseif action == "trade_started" then
				_tradeState.inTrade = true
				_tradeState.ourReady = false
				task.delay(1.5, tradeAutoFill)

			elseif action == "trade_complete" or action == "trade_failed"
			    or action == "trade_cancelled" then
				_tradeState.inTrade = false
				_tradeState.ourReady = false
				_tradeState.lastSendAt = os.clock()
				if action == "trade_complete" then
					stats.tradesCompleted = stats.tradesCompleted + 1
					toast({ title = "Trade complete", body = "Sent " .. tostring(cfg.tradeMaxCards) .. " card slot(s)", kind = "trade" })
				elseif action == "trade_failed" then
					toast({ title = "Trade failed", body = tostring(payload.reason or "unknown"), kind = "warn" })
				elseif action == "trade_cancelled" then
					toast({ title = "Trade cancelled", body = "", kind = "warn" })
				end
			end
		end)
	end

	-- Fix the fireTradeRequest to use the right remote
	function fireTradeRequest(userId)  -- redefine: now we have TradeRemote
		if not canFireTradeRequest() then
			local wait_s = math.ceil(TRADE_REQUEST_COOLDOWN_SEC - (os.clock() - _tradeState.lastRequestAt))
			warn(string.format("[Vellum trade] request blocked — cooldown %ds remaining", wait_s))
			return false
		end
		_tradeState.lastRequestAt = os.clock()
		pcall(function() TradeRemote:FireServer("request", userId) end)
		return true
	end

	local function tradeAutoSendLoop()
		while gui.Parent do
			task.wait(15)
			if not cfg.tradeAutoSendLoop then continue end
			if _tradeState.inTrade then continue end
			if os.clock() - _tradeState.lastSendAt < (cfg.tradeIntervalSec or 180) then
				continue
			end
			local targetId = resolveTradeTarget()
			if not targetId then continue end
			local targetPlayer = Players:GetPlayerByUserId(targetId)
			if not targetPlayer then continue end
			local cards = pickTradeable(1)
			if #cards == 0 then continue end
			if not canFireTradeRequest() then continue end
			_tradeState.lastSendAt = os.clock()
			if cfg.tradeAutoTpBeforeRequest then
				tpToPlayer(targetPlayer)
				task.wait(0.6)
			end
			if fireTradeRequest(targetId) then
				warn("[Vellum trade] sent trade request to " .. targetPlayer.Name)
			end
		end
	end

	-- ═══════════════════════════ WEBHOOK ═══════════════════════════
	local httpRequest = (syn and syn.request)
		or (http and http.request)
		or http_request
		or (fluxus and fluxus.request)
		or request

	local function postWebhook(content, embedFields)
		if not cfg.webhookUrl or cfg.webhookUrl == "" or not httpRequest then return end
		local body = {
			username = "Vellum · Spin a Soccer Card",
			content = content,
		}
		if embedFields then
			body.embeds = {{
				title  = "Session report",
				color  = 0x6FA8FF,
				fields = embedFields,
				footer = { text = "Vellum · " .. os.date("%H:%M:%S") },
			}}
		end
		pcall(function()
			httpRequest({
				Url     = cfg.webhookUrl,
				Method  = "POST",
				Headers = { ["Content-Type"] = "application/json" },
				Body    = HttpService:JSONEncode(body),
			})
		end)
	end

	local function webhookLoop()
		task.wait(5)
		postWebhook("🌙 Vellum booted — AFK mode " .. (cfg.afkMode and "**ON**" or "off"))
		while gui.Parent do
			task.wait(math.max(1, cfg.webhookIntMin) * 60)
			if cfg.webhookUrl and cfg.webhookUrl ~= "" then
				local me = getMe()
				if me then
					postWebhook(nil, {
						{ name = "💵 Cash",     value = "$" .. fmt(me.cash or 0), inline = true },
						{ name = "💎 Gems",     value = tostring(me.gems or 0),   inline = true },
						{ name = "♻️ Rebirth",  value = "R" .. (me.rebirth or 0),  inline = true },
						{ name = "📦 Session packs", value = tostring(stats.sessionPacks), inline = true },
						{ name = "🃏 Session sells", value = tostring(stats.sessionSells), inline = true },
						{ name = "♻️ Rebirths",  value = tostring(stats.sessionRebirths), inline = true },
						{ name = "💵 Collected", value = "$" .. fmt(stats.sessionCash), inline = true },
					})
				end
			end
		end
	end

	-- ═══════════════════════════ SET-ALL-AUTO ═══════════════════════════
	-- One-tap AFK button flips every auto switch + applies safe defaults.
	-- Server-side auto-sell rarities get synced to whatever's protected for
	-- the next rebirth (so the game's own auto-sell can't eat rebirth fodder).
	local function setAllAuto(on)
		cfg.autoCollect    = on
		cfg.autoCollectInt = on and 0.5 or cfg.autoCollectInt
		cfg.autoBuy        = on
		cfg.autoBuyInt     = on and 2.0 or cfg.autoBuyInt
		cfg.autoOpen       = on
		cfg.autoOpenInt    = on and 1.0 or cfg.autoOpenInt
		cfg.antiAfk        = on or cfg.antiAfk
		cfg.autoSell       = on
		cfg.autoSellInt    = on and 2.0 or cfg.autoSellInt
		cfg.rebirthSafe    = true
		cfg.autoRebirth    = on
		cfg.autoEquipBest  = on
		cfg.pitySniper     = on or cfg.pitySniper
		cfg.conservativeMode = on or cfg.conservativeMode
		cfg.autoDaily      = on or cfg.autoDaily
		cfg.autoOffline    = on or cfg.autoOffline
		cfg.autoLeave      = on or cfg.autoLeave
		cfg.autoSpin       = on or cfg.autoSpin
		cfg.autoThrone     = on
		cfg.lowDetail      = on or cfg.lowDetail
		cfg.crashRecover   = on or cfg.crashRecover
		-- serverHop NOT auto-toggled — teleporting unexpectedly would be hostile

		if on then
			-- Sync server-side auto-sell rarities with rebirth-required protection
			local me = getMe()
			local rb = me and me.rebirth or 0
			local protectedRarities = {}
			local nextTier = RebirthConfig.GetRebirth(rb + 1)
			if nextTier then
				for _, req in ipairs(nextTier.RequiredCards or {}) do
					if req:sub(1, 4) == "any:" then
						protectedRarities[req:sub(5)] = true
					else
						local def = CardConfig.Cards[req]
						if def and def.Rarity then
							protectedRarities[def.Rarity] = true
						end
					end
				end
			end
			-- Tell server to auto-sell our picked rarities, EXCEPT protected ones
			for _, r in ipairs({ "Bronze","Silver","Gold","Legendary","Mythic",
			                     "Azure Zenith","Crimson Zenith","Divine","Primordial",
			                     "Oblivion","Eternity","Astral","Sovereign","Vandal",
			                     "Verdant","Lunar","Nether" }) do
				local enable = (cfg.autoSellRarities[r] == true) and not protectedRarities[r]
				pcall(function() R.UpdateAutoSell:FireServer(r, enable) end)
			end
		end
	end

	-- ═══════════════════════════ PERSISTENCE ═══════════════════════════
	local CFG_DIR       = "Vellum_SoccerCard/configs"
	local AUTOLOAD_FILE = "Vellum_SoccerCard/autoload.txt"

	local function ensureDir()
		if makefolder then
			if not (isfolder and isfolder("Vellum_SoccerCard")) then pcall(makefolder, "Vellum_SoccerCard") end
			if not (isfolder and isfolder(CFG_DIR)) then pcall(makefolder, CFG_DIR) end
		end
	end

	local function listConfigs()
		ensureDir()
		if not listfiles then return {} end
		local ok, files = pcall(listfiles, CFG_DIR)
		if not ok or not files then return {} end
		local out = {}
		for _, f in ipairs(files) do
			local name = tostring(f):match("([^/\\]+)%.json$")
			if name then table.insert(out, name) end
		end
		table.sort(out)
		return out
	end

	local function configPath(name) return CFG_DIR .. "/" .. name .. ".json" end

	local function saveConfig(name)
		ensureDir()
		if not writefile then return false, "executor missing writefile" end
		local snap = {}
		for k, v in pairs(cfg) do
			if type(v) == "table" then
				snap[k] = {}
				for kk, vv in pairs(v) do snap[k][kk] = vv end
			else
				snap[k] = v
			end
		end
		local ok, err = pcall(function() writefile(configPath(name), HttpService:JSONEncode(snap)) end)
		return ok, err
	end

	local function loadConfigInto(name)
		if not isfile or not isfile(configPath(name)) then return false, "not found" end
		local ok, data = pcall(function() return HttpService:JSONDecode(readfile(configPath(name))) end)
		if not ok then return false, "decode failed" end
		for k, v in pairs(data) do
			if type(cfg[k]) == "table" and type(v) == "table" then
				for kk, vv in pairs(v) do cfg[k][kk] = vv end
			else
				cfg[k] = v
			end
		end
		return true
	end

	local function deleteConfigFile(name)
		if delfile and isfile and isfile(configPath(name)) then pcall(delfile, configPath(name)) end
	end

	local function getAutoloadName()
		if isfile and isfile(AUTOLOAD_FILE) then
			local ok, txt = pcall(readfile, AUTOLOAD_FILE)
			if ok and txt and txt ~= "" then return txt end
		end
		return nil
	end

	local function setAutoloadName(name)
		if writefile then pcall(writefile, AUTOLOAD_FILE, name or "") end
	end

	-- ═══════════════════════════ PRESETS ═══════════════════════════
	local PRESETS = {
		Conservative = {
			autoCollect = true, autoCollectInt = 2.0,
			autoBuy = true, autoBuyInt = 5.0,
			autoOpen = true, autoOpenInt = 2.0,
			autoSell = true, autoSellInt = 8.0,
			rebirthSafe = true, mutationKeep = 2, keepWithTrophy = true,
			autoRebirth = false,
			autoBuyPacks = { Bronze = true, Silver = true, Gold = true },
			autoSellRarities = { Bronze = true, Silver = true },
		},
		Aggressive = {
			autoCollect = true, autoCollectInt = 0.5,
			autoBuy = true, autoBuyInt = 1.0,
			autoOpen = true, autoOpenInt = 0.5,
			autoSell = true, autoSellInt = 2.0,
			rebirthSafe = true, mutationKeep = 3, keepWithTrophy = true,
			autoRebirth = true,
			autoBuyPacks = (function() local t = {} for n in pairs(PackConfig.Packs) do t[n] = true end return t end)(),
			autoSellRarities = {
				Bronze = true, Silver = true, Gold = true, Legendary = true, Mythic = true,
				["Azure Zenith"] = true, ["Crimson Zenith"] = true, Divine = true, Primordial = true,
			},
		},
		["Rebirth Push"] = {
			autoCollect = true, autoCollectInt = 0.5,
			autoBuy = true, autoBuyInt = 1.5,
			autoOpen = true, autoOpenInt = 0.8,
			autoSell = true, autoSellInt = 3.0,
			rebirthSafe = true, mutationKeep = 1, keepWithTrophy = true,
			autoRebirth = true,
			autoBuyPacks = (function() local t = {} for n in pairs(PackConfig.Packs) do t[n] = true end return t end)(),
			autoSellRarities = { Bronze = true, Silver = true, Gold = true },
		},
	}
	local function applyPreset(name)
		local p = PRESETS[name]
		if not p then return end
		for k, v in pairs(p) do
			if type(cfg[k]) == "table" and type(v) == "table" then
				cfg[k] = {}
				for kk, vv in pairs(v) do cfg[k][kk] = vv end
			else
				cfg[k] = v
			end
		end
	end

	-- ═══════════════════════════ PAGES ═══════════════════════════
	-- Pages must exist before their tab buttons reference them.
	local farm     = ui.newPage("farm")
	local sell     = ui.newPage("sell")
	local rebirth  = ui.newPage("rebirth")
	local claims   = ui.newPage("claims")
	local codes    = ui.newPage("codes")
	local statsPg  = ui.newPage("stats")
	local settings = ui.newPage("settings")

	-- forward-declared so AUTOLOAD section can write to it once Settings tab builds it
	local autoloadStatus

	-- ═══════════════════════════ FARM TAB ═══════════════════════════
	-- Hero AFK card — only colored element (intentionally draws the eye)
	local afkCard = Instance.new("Frame", farm)
	afkCard.Size = UDim2.new(1, -8, 0, 64)
	Theme.bind(afkCard, "BackgroundColor3", "row"); afkCard.BorderSizePixel = 0
	Instance.new("UICorner", afkCard).CornerRadius = UDim.new(0, 6)
	local afkStroke = Instance.new("UIStroke", afkCard)
	Theme.bind(afkStroke, "Color", "accent")
	afkStroke.Thickness = 1; afkStroke.Transparency = 0.55

	local afkBtn = Instance.new("TextButton", afkCard)
	afkBtn.Size = UDim2.new(1, -16, 0, 36); afkBtn.Position = UDim2.fromOffset(8, 8)
	Theme.bind(afkBtn, "BackgroundColor3", "elev"); afkBtn.AutoButtonColor = false
	afkBtn.Font = Enum.Font.GothamBold; afkBtn.TextSize = 13
	Theme.bind(afkBtn, "TextColor3", "textDim"); afkBtn.Text = "ONE-TAP AFK  ·  OFF"
	Instance.new("UICorner", afkBtn).CornerRadius = UDim.new(0, 4)

	local afkHint = Instance.new("TextLabel", afkCard)
	afkHint.Size = UDim2.new(1, -16, 0, 14); afkHint.Position = UDim2.fromOffset(8, 46)
	afkHint.BackgroundTransparency = 1
	afkHint.Text = "collects · buys · opens · sells (rebirth-safe) · rebirths · claims"
	afkHint.Font = Enum.Font.Gotham; afkHint.TextSize = 10
	Theme.bind(afkHint, "TextColor3", "textDim"); afkHint.TextXAlignment = Enum.TextXAlignment.Left

	local function paintAfk()
		if cfg.afkMode then
			afkBtn.BackgroundColor3 = Theme.token("accent")
			afkBtn.TextColor3 = Theme.token("accentText")
			afkBtn.Text = "ONE-TAP AFK  ·  ON"
			afkStroke.Transparency = 0.2
		else
			afkBtn.BackgroundColor3 = Theme.token("elev")
			afkBtn.TextColor3 = Theme.token("textDim")
			afkBtn.Text = "ONE-TAP AFK  ·  OFF"
			afkStroke.Transparency = 0.55
		end
	end
	afkBtn.MouseButton1Click:Connect(function()
		cfg.afkMode = not cfg.afkMode
		setAllAuto(cfg.afkMode)
		paintAfk()
	end)
	Theme.bindCall(paintAfk)  -- repaint on theme swap
	paintAfk()

	ui.sectionLabel(farm, "AUTO COLLECT").Parent = farm
	ui.toggleRow(farm, "Auto-collect plot slots",
		function() return cfg.autoCollect end,
		function(v) cfg.autoCollect = v end)
	ui.intervalRow(farm, "Sweep interval",
		function() return cfg.autoCollectInt end,
		function(v) cfg.autoCollectInt = v end,
		{ 0.5, 1.0, 2.0, 5.0 })

	ui.sectionLabel(farm, "AUTO BUY PACKS").Parent = farm
	ui.toggleRow(farm, "Auto-buy packs",
		function() return cfg.autoBuy end,
		function(v) cfg.autoBuy = v end)
	ui.intervalRow(farm, "Buy interval",
		function() return cfg.autoBuyInt end,
		function(v) cfg.autoBuyInt = v end,
		{ 1.0, 2.0, 5.0, 10.0 })

	-- buy-top-N cycle row: 3 / 5 / 7 / all (0)
	do
		local r = ui.row(farm, 30)
		local l = Instance.new("TextLabel", r)
		l.Size = UDim2.new(1, -80, 1, 0); l.Position = UDim2.fromOffset(12, 0)
		l.BackgroundTransparency = 1; l.Text = "Only buy top N packs"
		l.Font = Enum.Font.Gotham; l.TextSize = 12
		Theme.bind(l, "TextColor3", "text"); l.TextXAlignment = Enum.TextXAlignment.Left
		local b = Instance.new("TextButton", r)
		b.Size = UDim2.fromOffset(64, 20); b.Position = UDim2.new(1, -74, 0.5, -10)
		Theme.bind(b, "BackgroundColor3", "elev"); b.AutoButtonColor = false
		b.Font = Enum.Font.RobotoMono; b.TextSize = 11
		Theme.bind(b, "TextColor3", "text")
		Instance.new("UICorner", b).CornerRadius = UDim.new(0, 4)
		local opts = { 3, 5, 7, 0 }
		local function paint() b.Text = cfg.buyTopN == 0 and "all" or ("top " .. cfg.buyTopN) end
		b.MouseButton1Click:Connect(function()
			local idx = 1
			for i, v in ipairs(opts) do if v == cfg.buyTopN then idx = i; break end end
			idx = (idx % #opts) + 1
			cfg.buyTopN = opts[idx]
			paint()
		end)
		paint()
	end

	for _, pn in ipairs({
		"Bronze","Silver","Gold","Diamond","Platinum","Toxic","Shadow",
		"Infernal","Corrupted","Cosmic","Eclipse",
	}) do
		if PackConfig.Packs[pn] then
			ui.multiToggleRow(farm,
				"  " .. pn .. "  ($" .. fmt(PackConfig.Packs[pn].Price or 0) .. ")",
				cfg.autoBuyPacks, pn)
		end
	end

	ui.sectionLabel(farm, "AUTO OPEN PACKS").Parent = farm
	ui.toggleRow(farm, "Auto-open pending packs",
		function() return cfg.autoOpen end,
		function(v) cfg.autoOpen = v end)
	ui.intervalRow(farm, "Open interval",
		function() return cfg.autoOpenInt end,
		function(v) cfg.autoOpenInt = v end,
		{ 0.5, 1.0, 2.0, 5.0 })

	ui.sectionLabel(farm, "AUTO PLACE BEST").Parent = farm
	ui.toggleRow(farm, "Auto-equip best cards in slots",
		function() return cfg.autoEquipBest end,
		function(v) cfg.autoEquipBest = v end)
	ui.intervalRow(farm, "Equip check interval",
		function() return cfg.autoEquipInt end,
		function(v) cfg.autoEquipInt = v end,
		{ 5.0, 8.0, 15.0, 30.0 })

	ui.sectionLabel(farm, "ANTI-AFK").Parent = farm
	ui.toggleRow(farm, "Bypass 20-min AFK kick",
		function() return cfg.antiAfk end,
		function(v) cfg.antiAfk = v end)

	-- ═══════════════════════════ SELL TAB ═══════════════════════════
	ui.sectionLabel(sell, "AUTO SELL").Parent = sell
	ui.toggleRow(sell, "Auto-sell cards",
		function() return cfg.autoSell end,
		function(v) cfg.autoSell = v end)
	ui.intervalRow(sell, "Sell interval",
		function() return cfg.autoSellInt end,
		function(v) cfg.autoSellInt = v end,
		{ 2.0, 5.0, 10.0, 30.0 })
	ui.toggleRow(sell, "Rebirth-safe (protect required cards)",
		function() return cfg.rebirthSafe end,
		function(v) cfg.rebirthSafe = v end)

	local ALL_RARITIES = {
		"Bronze","Silver","Gold","Legendary","Mythic",
		"Azure Zenith","Crimson Zenith","Divine","Primordial","Oblivion",
		"Eternity","Astral","Sovereign","Vandal","Verdant","Lunar","Nether",
	}
	ui.sectionLabel(sell, "RARITIES TO SELL").Parent = sell
	for _, r in ipairs(ALL_RARITIES) do
		ui.multiToggleRow(sell, "  " .. r, cfg.autoSellRarities, r)
	end

	ui.sectionLabel(sell, "ACTIONS").Parent = sell
	ui.actionBtn(sell, "Sell Now (respect picks above)", function()
		local uuids = pickSellable(cfg.autoSellRarities, cfg.rebirthSafe)
		if #uuids > 0 then
			R.SellCards:FireServer(uuids)
			stats.sessionSells = stats.sessionSells + #uuids
		end
	end)
	ui.actionBtn(sell, "Lock all rebirth-required cards", function()
		local me = getMe(); if not me or not me.inventory then return end
		local exact, rarities = buildRebirthReservation()
		local exactLeft, rarityLeft = {}, {}
		for k, v in pairs(exact) do exactLeft[k] = v end
		for k, v in pairs(rarities) do rarityLeft[k] = v end
		local sorted = {}
		for _, c in ipairs(me.inventory) do table.insert(sorted, c) end
		table.sort(sorted, function(a, b) return cardIncome(a) < cardIncome(b) end)
		for _, c in ipairs(sorted) do
			local locked = false
			if exactLeft[c.id] and exactLeft[c.id] > 0 then
				exactLeft[c.id] = exactLeft[c.id] - 1; locked = true
			else
				local r = cardRarity(c)
				if rarityLeft[r] and rarityLeft[r] > 0 then
					rarityLeft[r] = rarityLeft[r] - 1; locked = true
				end
			end
			if locked and not c.locked then
				pcall(function() R.LockCard:FireServer(c.uuid) end)
			end
		end
	end)
	ui.actionBtn(sell, "Sync server auto-sell with picks", function()
		for _, r in ipairs(ALL_RARITIES) do
			pcall(function() R.UpdateAutoSell:FireServer(r, cfg.autoSellRarities[r] == true) end)
		end
	end)

	-- ═══════════════════════════ REBIRTH TAB ═══════════════════════════
	local rebirthInfo = Instance.new("TextLabel", rebirth)
	rebirthInfo.Size = UDim2.new(1, -8, 0, 200)
	Theme.bind(rebirthInfo, "BackgroundColor3", "row")
	rebirthInfo.BorderSizePixel = 0; rebirthInfo.Font = Enum.Font.Code; rebirthInfo.TextSize = 12
	Theme.bind(rebirthInfo, "TextColor3", "text"); rebirthInfo.Text = "..."
	rebirthInfo.TextXAlignment = Enum.TextXAlignment.Left
	rebirthInfo.TextYAlignment = Enum.TextYAlignment.Top
	rebirthInfo.TextWrapped = true
	Instance.new("UICorner", rebirthInfo).CornerRadius = UDim.new(0, 6)
	do
		local pad = Instance.new("UIPadding", rebirthInfo)
		pad.PaddingLeft = UDim.new(0, 10); pad.PaddingTop = UDim.new(0, 8); pad.PaddingRight = UDim.new(0, 10)
	end

	ui.toggleRow(rebirth, "Auto-rebirth when ready",
		function() return cfg.autoRebirth end,
		function(v) cfg.autoRebirth = v end)
	ui.actionBtn(rebirth, "Rebirth Now", function()
		local ok, why = canRebirth()
		if ok then
			R.Rebirth:FireServer()
			stats.sessionRebirths = stats.sessionRebirths + 1
			toast({ title = "Rebirth fired", body = "Server ack pending.", kind = "success" })
		else
			warn("[Vellum] cannot rebirth: " .. tostring(why))
			toast({ title = "Can't rebirth", body = tostring(why), kind = "warn", duration = 7 })
		end
	end)
	ui.actionBtn(rebirth, "Force rebirth (skip checks)", function()
		pcall(function() R.Rebirth:FireServer() end)
		toast({ title = "Force-rebirth fired", body = "Server may reject if not ready.", kind = "warn" })
	end)

	local function refreshRebirthInfo()
		local me = getMe()
		if not me then rebirthInfo.Text = "loading..."; return end
		local cur = me.rebirth or 0
		local tier = RebirthConfig.GetRebirth(cur + 1)
		if not tier then rebirthInfo.Text = string.format("Max rebirth reached (%d).", cur); return end

		local exactLeft, rarityLeft = {}, {}
		for _, req in ipairs(tier.RequiredCards or {}) do
			if req:sub(1, 4) == "any:" then
				rarityLeft[req:sub(5)] = (rarityLeft[req:sub(5)] or 0) + 1
			else
				exactLeft[req] = (exactLeft[req] or 0) + 1
			end
		end
		for _, c in ipairs(ownedCardPool(me)) do
			if exactLeft[c.id] and exactLeft[c.id] > 0 then
				exactLeft[c.id] = exactLeft[c.id] - 1
			else
				local r = cardRarity(c)
				if rarityLeft[r] and rarityLeft[r] > 0 then
					rarityLeft[r] = rarityLeft[r] - 1
				end
			end
		end

		local lines = { string.format("Current: R%d  →  Next: R%d", cur, cur + 1) }
		local cashOk = (me.cash or 0) >= (tier.CashRequired or 0)
		table.insert(lines, string.format("%s Cash:  $%s / $%s",
			cashOk and "✓" or "✗", fmt(me.cash or 0), fmt(tier.CashRequired or 0)))
		if tier.GemsRequired then
			local gemsOk = (me.gems or 0) >= tier.GemsRequired
			table.insert(lines, string.format("%s Gems:  %d / %d",
				gemsOk and "✓" or "✗", me.gems or 0, tier.GemsRequired))
		end
		table.insert(lines, "")
		local need = {}
		for _, req in ipairs(tier.RequiredCards or {}) do table.insert(need, req) end
		local seen = {}
		for _, req in ipairs(need) do
			if req:sub(1, 4) == "any:" then
				local r = req:sub(5)
				local key = "any:" .. r
				seen[key] = (seen[key] or 0) + 1
				local stillNeed = rarityLeft[r] or 0
				if seen[key] == 1 then
					local totalReq = 0
					for _, r2 in ipairs(need) do if r2 == req then totalReq = totalReq + 1 end end
					local have = totalReq - stillNeed
					table.insert(lines, string.format("%s %d× any %s  (have %d)",
						stillNeed == 0 and "✓" or "✗", totalReq, r, have))
				end
			else
				local have = (exactLeft[req] or 0) == 0
				table.insert(lines, string.format("%s %s", have and "✓" or "✗", req))
			end
		end
		local ok = canRebirth()
		table.insert(lines, "")
		table.insert(lines, ok and "★ READY TO REBIRTH ★" or "(waiting for missing items)")
		rebirthInfo.Text = table.concat(lines, "\n")
	end

	-- ═══════════════════════════ CLAIMS TAB ═══════════════════════════
	ui.sectionLabel(claims, "AUTO CLAIMS (every 30s)").Parent = claims
	ui.toggleRow(claims, "Daily Reward",
		function() return cfg.autoDaily end, function(v) cfg.autoDaily = v end)
	ui.toggleRow(claims, "Offline Reward",
		function() return cfg.autoOffline end, function(v) cfg.autoOffline = v end)
	ui.toggleRow(claims, "Leave Reward",
		function() return cfg.autoLeave end, function(v) cfg.autoLeave = v end)
	ui.toggleRow(claims, "Spin Wheel (free)",
		function() return cfg.autoSpin end, function(v) cfg.autoSpin = v end)
	ui.toggleRow(claims, "Throne Attempt",
		function() return cfg.autoThrone end, function(v) cfg.autoThrone = v end)
	ui.sectionLabel(claims, "ONE-SHOT CLAIMS").Parent = claims
	ui.actionBtn(claims, "Claim Daily Now",   function() pcall(function() R.DailyReward:FireServer()   end) end)
	ui.actionBtn(claims, "Claim Offline Now", function() pcall(function() R.OfflineReward:FireServer() end) end)
	ui.actionBtn(claims, "Claim Leave Reward Now", function() pcall(function() R.LeaveReward:FireServer() end) end)
	ui.actionBtn(claims, "Spin Wheel Now", function()
		pcall(function()
			local data = R.SpinWheelData:InvokeServer()
			if data and data.canClaimFree then
				R.SpinWheel:FireServer("claim_free")
			elseif data and (data.spins or 0) > 0 then
				R.SpinWheel:FireServer("spin")
			end
		end)
	end)
	ui.actionBtn(claims, "Attempt Throne Now", function() pcall(function() R.AttemptThrone:FireServer() end) end)

	-- ═══════════════════════════ CODES TAB ═══════════════════════════
	ui.sectionLabel(codes, "REDEEM CODES (one per line or comma-separated)").Parent = codes
	local codeBox = Instance.new("TextBox", codes)
	codeBox.Size = UDim2.new(1, -8, 0, 120)
	Theme.bind(codeBox, "BackgroundColor3", "row")
	codeBox.BorderSizePixel = 0; codeBox.Font = Enum.Font.Code; codeBox.TextSize = 12
	Theme.bind(codeBox, "TextColor3", "text"); codeBox.PlaceholderText = "HAPPY, LUCKYGOAL, GOLDEN-STRIKE..."
	codeBox.Text = ""; codeBox.MultiLine = true; codeBox.ClearTextOnFocus = false
	codeBox.TextXAlignment = Enum.TextXAlignment.Left
	codeBox.TextYAlignment = Enum.TextYAlignment.Top
	Instance.new("UICorner", codeBox).CornerRadius = UDim.new(0, 6)
	do
		local pad = Instance.new("UIPadding", codeBox)
		pad.PaddingLeft = UDim.new(0, 8); pad.PaddingTop = UDim.new(0, 6)
	end
	local codeStatus = Instance.new("TextLabel", codes)
	codeStatus.Size = UDim2.new(1, -8, 0, 20); codeStatus.BackgroundTransparency = 1
	codeStatus.Text = ""; codeStatus.Font = Enum.Font.Gotham; codeStatus.TextSize = 11
	Theme.bind(codeStatus, "TextColor3", "textDim"); codeStatus.TextXAlignment = Enum.TextXAlignment.Left
	ui.actionBtn(codes, "Redeem All", function()
		local raw = codeBox.Text
		local found = 0
		for code in raw:gmatch("[%w%-_]+") do
			if #code >= 3 then
				pcall(function() R.RedeemCode:FireServer(code) end)
				found = found + 1
				task.wait(0.3)
			end
		end
		codeStatus.Text = "Fired " .. found .. " code(s)"
	end)

	-- ═══════════════════════════ STATS TAB ═══════════════════════════
	local statsLbl = Instance.new("TextLabel", statsPg)
	statsLbl.Size = UDim2.new(1, -8, 0, 480)
	Theme.bind(statsLbl, "BackgroundColor3", "row")
	statsLbl.BorderSizePixel = 0; statsLbl.Font = Enum.Font.Code; statsLbl.TextSize = 12
	Theme.bind(statsLbl, "TextColor3", "text"); statsLbl.Text = "loading..."
	statsLbl.TextXAlignment = Enum.TextXAlignment.Left
	statsLbl.TextYAlignment = Enum.TextYAlignment.Top
	statsLbl.TextWrapped = false
	Instance.new("UICorner", statsLbl).CornerRadius = UDim.new(0, 6)
	do
		local pad = Instance.new("UIPadding", statsLbl)
		pad.PaddingLeft = UDim.new(0, 10); pad.PaddingTop = UDim.new(0, 8); pad.PaddingRight = UDim.new(0, 10)
	end

	local function rebirthEtaText(me, cashPerHour)
		if not me then return "—" end
		local nextTier = RebirthConfig.GetRebirth((me.rebirth or 0) + 1)
		if not nextTier then return "max rebirth" end
		local cost = nextTier.Cost or 0
		if cost == 0 then return "—" end
		local need = cost - (me.cash or 0)
		if need <= 0 then return "ready now ✓" end
		if cashPerHour <= 0 then return "—" end
		return fmtDur(need / cashPerHour * 3600) .. " (need $" .. fmt(need) .. ")"
	end

	local function inventoryValue(me)
		if not me or not me.inventory then return 0 end
		local total = 0
		for _, c in ipairs(me.inventory) do total = total + (cardIncome(c) or 0) end
		return total
	end

	local function refreshStats()
		local me = getMe()
		if not me then statsLbl.Text = "Waiting for sync..."; return end
		local elapsed = os.clock() - (stats.sessionStart or os.clock())
		local cashPerHrNum = elapsed >= 60 and (stats.sessionCash * 3600 / elapsed) or 0

		local rarityCount = {}
		for _, c in ipairs(me.inventory or {}) do
			local r = cardRarity(c)
			rarityCount[r] = (rarityCount[r] or 0) + 1
		end
		local rarityByWeight = {}
		for r, n in pairs(rarityCount) do
			table.insert(rarityByWeight, { r = r, n = n, w = RARITY_WEIGHT[r] or 0 })
		end
		table.sort(rarityByWeight, function(a, b) return a.w > b.w end)
		local rarityLines = {}
		for _, x in ipairs(rarityByWeight) do
			table.insert(rarityLines, string.format("  %-18s %d", x.r, x.n))
		end

		statsLbl.Text = string.format([[
SESSION  (uptime %s)
  Cash collected:  $%s   (%s/hr)
  Cards sold:      %d    (%s/hr)
  Packs opened:    %d    (%s/hr)
  Rebirths:        %d
  Server hops:     %d
  Tournaments:     %d
  Trades:          %d
  Best rarity:     %s
  Best mutation:   %dx

PLAYER
  Cash:            $%s
  Gems:            %d
  Rebirth:         R%d
  Inventory:       %d cards  (≈$%s/sec)
  Next rebirth in: %s

INVENTORY BY RARITY
%s]],
			fmtDur(elapsed),
			fmt(stats.sessionCash),  perHour(stats.sessionCash, elapsed),
			stats.sessionSells,      perHour(stats.sessionSells, elapsed),
			stats.sessionPacks,      perHour(stats.sessionPacks, elapsed),
			stats.sessionRebirths,
			stats.serverHops,
			stats.tournamentsJoined,
			stats.tradesCompleted,
			tostring(stats.bestRarity or "—"),
			stats.bestMutationCount or 0,
			fmt(me.cash or 0), me.gems or 0, me.rebirth or 0,
			#(me.inventory or {}), fmt(math.floor(inventoryValue(me))),
			rebirthEtaText(me, cashPerHrNum),
			table.concat(rarityLines, "\n")
		)
	end

	-- ═══════════════════════════ SETTINGS TAB ═══════════════════════════
	ui.sectionLabel(settings, "PRESETS").Parent = settings
	for _, presetName in ipairs({ "Conservative", "Aggressive", "Rebirth Push" }) do
		ui.actionBtn(settings, "Apply: " .. presetName, function()
			applyPreset(presetName)
			if autoloadStatus then autoloadStatus.Text = "Applied preset: " .. presetName end
		end)
	end

	-- mutation/trophy keeper
	ui.sectionLabel(settings, "MUTATION / TROPHY KEEPER").Parent = settings
	do
		local r = ui.row(settings, 30)
		local l = Instance.new("TextLabel", r)
		l.Size = UDim2.new(1, -70, 1, 0); l.Position = UDim2.fromOffset(12, 0)
		l.BackgroundTransparency = 1; l.Font = Enum.Font.Gotham; l.TextSize = 12
		Theme.bind(l, "TextColor3", "text"); l.TextXAlignment = Enum.TextXAlignment.Left
		l.Text = "Min mutations to keep (tap to cycle)"
		local b = Instance.new("TextButton", r)
		b.Size = UDim2.fromOffset(54, 20); b.Position = UDim2.new(1, -64, 0.5, -10)
		Theme.bind(b, "BackgroundColor3", "elev"); b.AutoButtonColor = false
		b.Font = Enum.Font.RobotoMono; b.TextSize = 11
		Theme.bind(b, "TextColor3", "text")
		Instance.new("UICorner", b).CornerRadius = UDim.new(0, 4)
		local function paint() b.Text = cfg.mutationKeep == 0 and "off" or (cfg.mutationKeep .. "+") end
		b.MouseButton1Click:Connect(function()
			cfg.mutationKeep = (cfg.mutationKeep + 1) % 5
			paint()
		end)
		paint()
	end
	ui.toggleRow(settings, "Never sell card with trophy",
		function() return cfg.keepWithTrophy end,
		function(v) cfg.keepWithTrophy = v end)

	-- discord webhook
	ui.sectionLabel(settings, "DISCORD WEBHOOK").Parent = settings
	do
		local whRow = Instance.new("Frame", settings)
		whRow.Size = UDim2.new(1, -8, 0, 30); whRow.BackgroundTransparency = 1
		local whBox = Instance.new("TextBox", whRow)
		whBox.Size = UDim2.new(1, -100, 1, 0)
		Theme.bind(whBox, "BackgroundColor3", "row")
		whBox.BorderSizePixel = 0; whBox.Font = Enum.Font.Code; whBox.TextSize = 11
		Theme.bind(whBox, "TextColor3", "text")
		whBox.PlaceholderText = "https://discord.com/api/webhooks/..."
		whBox.Text = cfg.webhookUrl or ""; whBox.ClearTextOnFocus = false
		whBox.TextXAlignment = Enum.TextXAlignment.Left
		Instance.new("UICorner", whBox).CornerRadius = UDim.new(0, 6)
		local pad = Instance.new("UIPadding", whBox); pad.PaddingLeft = UDim.new(0, 10)
		local whSave = Instance.new("TextButton", whRow)
		whSave.Size = UDim2.fromOffset(94, 30); whSave.Position = UDim2.new(1, -94, 0, 0)
		Theme.bind(whSave, "BackgroundColor3", "accent"); whSave.AutoButtonColor = false
		whSave.Font = Enum.Font.GothamBold; whSave.TextSize = 12
		Theme.bind(whSave, "TextColor3", "accentText"); whSave.Text = "SET"
		Instance.new("UICorner", whSave).CornerRadius = UDim.new(0, 6)
		whSave.MouseButton1Click:Connect(function()
			cfg.webhookUrl = whBox.Text or ""
			postWebhook("✅ Webhook configured for Vellum")
		end)
	end
	ui.actionBtn(settings, "Send test webhook ping", function()
		postWebhook("🧪 Test ping from Vellum")
	end)

	-- exploits / advantage
	ui.sectionLabel(settings, "EXPLOITS / ADVANTAGE").Parent = settings
	ui.toggleRow(settings, "Pity Sniper (override priority near pity)",
		function() return cfg.pitySniper end,
		function(v) cfg.pitySniper = v end)
	do
		local r = ui.row(settings, 30)
		local l = Instance.new("TextLabel", r)
		l.Size = UDim2.new(1, -70, 1, 0); l.Position = UDim2.fromOffset(12, 0)
		l.BackgroundTransparency = 1; l.Text = "Snipe when buys-to-pity ≤"
		l.Font = Enum.Font.Gotham; l.TextSize = 12
		Theme.bind(l, "TextColor3", "text"); l.TextXAlignment = Enum.TextXAlignment.Left
		local b = Instance.new("TextButton", r)
		b.Size = UDim2.fromOffset(54, 20); b.Position = UDim2.new(1, -64, 0.5, -10)
		Theme.bind(b, "BackgroundColor3", "elev"); b.AutoButtonColor = false
		b.Font = Enum.Font.RobotoMono; b.TextSize = 11
		Theme.bind(b, "TextColor3", "text")
		Instance.new("UICorner", b).CornerRadius = UDim.new(0, 4)
		local opts = { 1, 2, 3, 5 }
		local function paint() b.Text = tostring(cfg.pitySnipeWithin) end
		b.MouseButton1Click:Connect(function()
			local idx = 1
			for i, v in ipairs(opts) do if v == cfg.pitySnipeWithin then idx = i; break end end
			idx = (idx % #opts) + 1
			cfg.pitySnipeWithin = opts[idx]
			paint()
		end)
		paint()
	end
	ui.toggleRow(settings, "Sort packs by EV (math-optimal)",
		function() return cfg.evSort end,
		function(v) cfg.evSort = v end)
	ui.actionBtn(settings, "Live: show pity status", function()
		local me = getMe()
		if not me then
			if autoloadStatus then autoloadStatus.Text = "no state" end
			return
		end
		local lines = {}
		for name, def in pairs(PackConfig.Packs) do
			if def.Pity and def.Pity.every then
				local remaining = pityBuysRemaining(name, def)
				if remaining ~= math.huge and remaining <= 50 then
					table.insert(lines, string.format("%s: %d to pity → %s", name, remaining, def.Pity.rarity))
				end
			end
		end
		table.sort(lines)
		if autoloadStatus then
			autoloadStatus.Text = #lines > 0 and table.concat(lines, " · "):sub(1, 200) or "no nearby pity hits"
		end
	end)

	-- stability
	ui.sectionLabel(settings, "STABILITY").Parent = settings
	ui.toggleRow(settings, "Conservative network mode (recommended)",
		function() return cfg.conservativeMode end,
		function(v) cfg.conservativeMode = v end)
	do
		local note = Instance.new("TextLabel", settings)
		note.Size = UDim2.new(1, -8, 0, 30); note.BackgroundTransparency = 1
		note.Text = "2.5× longer intervals + heavier jitter. Drops RPC rate ~75% to prevent Roblox LEASE_3506 crashes. Farm efficiency barely changes (server is the bottleneck)."
		note.Font = Enum.Font.Gotham; note.TextSize = 10
		Theme.bind(note, "TextColor3", "textDim"); note.TextXAlignment = Enum.TextXAlignment.Left
		note.TextWrapped = true
		local pad = Instance.new("UIPadding", note); pad.PaddingLeft = UDim.new(0, 10)
	end

	-- appearance — theme picker
	ui.sectionLabel(settings, "APPEARANCE").Parent = settings
	do
		local order = Theme.presetNames()
		local descriptions = {
			Vellum    = "warm cream on deep ink",
			Midnight  = "ice blue on navy",
			Ink       = "pure black + white",
			Parchment = "warm light, literary",
			Matte     = "greyscale neutral",
		}
		local picker = Instance.new("Frame", settings)
		picker.Size = UDim2.new(1, -8, 0, 56)
		Theme.bind(picker, "BackgroundColor3", "row"); picker.BorderSizePixel = 0
		Instance.new("UICorner", picker).CornerRadius = UDim.new(0, 4)
		local swatchesRow = Instance.new("Frame", picker)
		swatchesRow.Size = UDim2.new(1, -16, 0, 32); swatchesRow.Position = UDim2.fromOffset(8, 6)
		swatchesRow.BackgroundTransparency = 1
		local layout = Instance.new("UIListLayout", swatchesRow)
		layout.FillDirection = Enum.FillDirection.Horizontal
		layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
		layout.VerticalAlignment = Enum.VerticalAlignment.Center
		layout.Padding = UDim.new(0, 6)

		local descLabel = Instance.new("TextLabel", picker)
		descLabel.Size = UDim2.new(1, -16, 0, 14); descLabel.Position = UDim2.fromOffset(8, 40)
		descLabel.BackgroundTransparency = 1
		descLabel.Font = Enum.Font.Gotham; descLabel.TextSize = 10
		Theme.bind(descLabel, "TextColor3", "textDim")
		descLabel.TextXAlignment = Enum.TextXAlignment.Left
		descLabel.Text = (descriptions[cfg.themeName] or "")

		local presetPreviews = Theme.presets()
		local _swatches = {}
		local function paintActive()
			for name, sw in pairs(_swatches) do
				sw.stroke.Transparency = (name == cfg.themeName) and 0 or 0.7
				sw.stroke.Thickness = (name == cfg.themeName) and 1.5 or 1
			end
			descLabel.Text = (descriptions[cfg.themeName] or "")
		end
		for i, name in ipairs(order) do
			local preset = presetPreviews[name]
			local sw = Instance.new("TextButton", swatchesRow)
			sw.Size = UDim2.fromOffset(72, 32); sw.LayoutOrder = i
			sw.BackgroundColor3 = preset.panel; sw.AutoButtonColor = false
			sw.Text = ""
			Instance.new("UICorner", sw).CornerRadius = UDim.new(0, 4)
			local s = Instance.new("UIStroke", sw)
			s.Color = preset.accent; s.Thickness = 1; s.Transparency = 0.7

			local dot = Instance.new("Frame", sw)
			dot.Size = UDim2.fromOffset(8, 8); dot.AnchorPoint = Vector2.new(0, 0.5)
			dot.Position = UDim2.new(0, 8, 0.5, 0)
			dot.BackgroundColor3 = preset.accent; dot.BorderSizePixel = 0
			Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)

			local lbl = Instance.new("TextLabel", sw)
			lbl.Size = UDim2.new(1, -22, 1, 0); lbl.Position = UDim2.fromOffset(20, 0)
			lbl.BackgroundTransparency = 1; lbl.Text = name
			lbl.Font = Enum.Font.GothamMedium; lbl.TextSize = 10
			lbl.TextColor3 = preset.text; lbl.TextXAlignment = Enum.TextXAlignment.Left

			sw.MouseButton1Click:Connect(function()
				cfg.themeName = name
				Theme.apply(name)
				paintActive()
			end)
			_swatches[name] = { btn = sw, stroke = s }
		end
		paintActive()
	end

	-- extras
	ui.sectionLabel(settings, "EXTRAS").Parent = settings
	ui.toggleRow(settings, "Jitter intervals (anti-pattern)",
		function() return cfg.jitter end, function(v) cfg.jitter = v end)
	ui.toggleRow(settings, "RightShift toggles UI",
		function() return cfg.keybindToggle end, function(v) cfg.keybindToggle = v end)
	ui.toggleRow(settings, "Auto-claim index gems",
		function() return cfg.autoIndexGems end, function(v) cfg.autoIndexGems = v end)
	ui.toggleRow(settings, "Auto-join tournament",
		function() return cfg.autoTournament end, function(v) cfg.autoTournament = v end)
	ui.toggleRow(settings, "In-game toast notifications",
		function() return cfg.notifyInGame end, function(v) cfg.notifyInGame = v end)

	-- afk survivability
	ui.sectionLabel(settings, "AFK SURVIVABILITY").Parent = settings
	ui.toggleRow(settings, "Low detail mode (less GPU, less crash)",
		function() return cfg.lowDetail end, function(v) cfg.lowDetail = v end)
	ui.toggleRow(settings, "Crash recovery (re-runs script on rejoin)",
		function() return cfg.crashRecover end,
		function(v) cfg.crashRecover = v; if v then setupCrashRecover() end end)

	-- server hopping
	ui.sectionLabel(settings, "SERVER HOPPING").Parent = settings
	ui.toggleRow(settings, "Enable server hop features",
		function() return cfg.serverHop end, function(v) cfg.serverHop = v end)
	ui.toggleRow(settings, "  Auto-hop on bad ping (>" .. tostring(cfg.pingHopThreshold) .. "ms for 30s)",
		function() return cfg.serverHopOnBadPing end, function(v) cfg.serverHopOnBadPing = v end)
	ui.toggleRow(settings, "  Auto-hop on low FPS (<" .. tostring(cfg.fpsHopThreshold) .. " for 30s)",
		function() return cfg.hopOnLowFps end, function(v) cfg.hopOnLowFps = v end)
	ui.actionBtn(settings, "Hop to fresh server NOW", function() task.spawn(hopNow) end)

	-- trading
	ui.sectionLabel(settings, "TRADING").Parent = settings
	do
		local trgBox = Instance.new("TextBox", settings)
		trgBox.Size = UDim2.new(1, -8, 0, 30)
		Theme.bind(trgBox, "BackgroundColor3", "row")
		trgBox.BorderSizePixel = 0; trgBox.Font = Enum.Font.Gotham; trgBox.TextSize = 12
		Theme.bind(trgBox, "TextColor3", "text")
		trgBox.PlaceholderText = "Target username (friend / alt)"
		trgBox.Text = cfg.tradeTarget or ""; trgBox.ClearTextOnFocus = false
		Instance.new("UICorner", trgBox).CornerRadius = UDim.new(0, 6)
		local pad = Instance.new("UIPadding", trgBox); pad.PaddingLeft = UDim.new(0, 10)
		trgBox.FocusLost:Connect(function()
			cfg.tradeTarget = trgBox.Text
			_tradeTargetCache.username, _tradeTargetCache.userId = nil, nil
		end)
	end
	ui.toggleRow(settings, "Auto-accept trade from target",
		function() return cfg.tradeAutoAcceptFromTarget end, function(v) cfg.tradeAutoAcceptFromTarget = v end)
	ui.toggleRow(settings, "Auto-fill + auto-ready when trade opens",
		function() return cfg.tradeAutoFillOnOpen end, function(v) cfg.tradeAutoFillOnOpen = v end)
	ui.toggleRow(settings, "Auto-request trade from target (loop)",
		function() return cfg.tradeAutoSendLoop end, function(v) cfg.tradeAutoSendLoop = v end)
	ui.toggleRow(settings, "  TP next to target before request",
		function() return cfg.tradeAutoTpBeforeRequest end, function(v) cfg.tradeAutoTpBeforeRequest = v end)
	ui.actionBtn(settings, "TP to target", function()
		task.spawn(function()
			local ok, why = tpToTargetByUsername()
			warn("[Vellum trade] TP result: " .. tostring(ok) .. " / " .. tostring(why))
		end)
	end)
	ui.actionBtn(settings, "TP to target + send request", function()
		task.spawn(function()
			local id = resolveTradeTarget()
			if not id then warn("[Vellum trade] target not resolvable") return end
			local p = Players:GetPlayerByUserId(id)
			if not p then warn("[Vellum trade] target not in server") return end
			tpToPlayer(p)
			task.wait(0.6)
			if fireTradeRequest(id) then
				warn("[Vellum trade] tp+request fired to " .. tostring(id))
			end
		end)
	end)
	ui.actionBtn(settings, "Send request only (no TP)", function()
		task.spawn(function()
			local id = resolveTradeTarget()
			if not id then warn("[Vellum trade] target not resolvable") return end
			if fireTradeRequest(id) then
				warn("[Vellum trade] manual request fired to " .. tostring(id))
			end
		end)
	end)

	-- autoload status
	ui.sectionLabel(settings, "AUTOLOAD").Parent = settings
	autoloadStatus = Instance.new("TextLabel", settings)
	autoloadStatus.Size = UDim2.new(1, -8, 0, 22)
	Theme.bind(autoloadStatus, "BackgroundColor3", "row")
	autoloadStatus.BorderSizePixel = 0; autoloadStatus.Font = Enum.Font.GothamSemibold; autoloadStatus.TextSize = 11
	Theme.bind(autoloadStatus, "TextColor3", "text"); autoloadStatus.TextXAlignment = Enum.TextXAlignment.Left
	autoloadStatus.Text = ""
	Instance.new("UICorner", autoloadStatus).CornerRadius = UDim.new(0, 6)
	do
		local pad = Instance.new("UIPadding", autoloadStatus); pad.PaddingLeft = UDim.new(0, 10)
	end

	-- save-new
	ui.sectionLabel(settings, "SAVE CURRENT CONFIG").Parent = settings
	local saveBox
	do
		local r = Instance.new("Frame", settings)
		r.Size = UDim2.new(1, -8, 0, 30); r.BackgroundTransparency = 1
		saveBox = Instance.new("TextBox", r)
		saveBox.Size = UDim2.new(1, -100, 1, 0)
		Theme.bind(saveBox, "BackgroundColor3", "row")
		saveBox.BorderSizePixel = 0; saveBox.Font = Enum.Font.Gotham; saveBox.TextSize = 12
		Theme.bind(saveBox, "TextColor3", "text"); saveBox.PlaceholderText = "config name..."
		saveBox.Text = ""; saveBox.ClearTextOnFocus = false
		saveBox.TextXAlignment = Enum.TextXAlignment.Left
		Instance.new("UICorner", saveBox).CornerRadius = UDim.new(0, 6)
		local pad = Instance.new("UIPadding", saveBox); pad.PaddingLeft = UDim.new(0, 10)
		local b = Instance.new("TextButton", r)
		b.Size = UDim2.fromOffset(94, 30); b.Position = UDim2.new(1, -94, 0, 0)
		Theme.bind(b, "BackgroundColor3", "accent"); b.AutoButtonColor = false
		b.Font = Enum.Font.GothamBold; b.TextSize = 12
		Theme.bind(b, "TextColor3", "accentText"); b.Text = "SAVE"
		Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
		b.MouseButton1Click:Connect(function()
			local name = saveBox.Text:gsub("[^%w%-_ ]", ""):gsub("^%s+", ""):gsub("%s+$", "")
			if name == "" then autoloadStatus.Text = "Name can't be empty"; return end
			local ok, err = saveConfig(name)
			autoloadStatus.Text = ok and ("Saved: " .. name) or ("Save failed: " .. tostring(err))
			saveBox.Text = ""
			refreshSettingsList()  -- forward-declared just below
		end)
	end

	-- saved-configs list
	ui.sectionLabel(settings, "SAVED CONFIGS").Parent = settings
	local listHolder = Instance.new("Frame", settings)
	listHolder.Size = UDim2.new(1, -8, 0, 0); listHolder.BackgroundTransparency = 1
	listHolder.AutomaticSize = Enum.AutomaticSize.Y
	local listLayout = Instance.new("UIListLayout", listHolder)
	listLayout.Padding = UDim.new(0, 4); listLayout.SortOrder = Enum.SortOrder.LayoutOrder

	local refreshSettingsList  -- forward-declared above as local

	local function configRow(name, isAutoload)
		local r = ui.row(listHolder, 32)
		local nameLbl = Instance.new("TextLabel", r)
		nameLbl.Size = UDim2.new(1, -260, 1, 0); nameLbl.Position = UDim2.fromOffset(12, 0)
		nameLbl.BackgroundTransparency = 1
		nameLbl.Text = (isAutoload and "★ " or "") .. name
		nameLbl.Font = Enum.Font.GothamMedium; nameLbl.TextSize = 12
		nameLbl.TextColor3 = isAutoload and Theme.token("warn") or Theme.token("text")
		nameLbl.TextXAlignment = Enum.TextXAlignment.Left

		local function mkBtn(text, color, txtColor, xOffset, width)
			local b = Instance.new("TextButton", r)
			b.Size = UDim2.fromOffset(width or 48, 22)
			b.Position = UDim2.new(1, xOffset, 0.5, -11)
			b.BackgroundColor3 = color; b.TextColor3 = txtColor
			b.AutoButtonColor = false; b.Font = Enum.Font.GothamBold; b.TextSize = 10
			b.Text = text
			Instance.new("UICorner", b).CornerRadius = UDim.new(0, 4)
			return b
		end

		local loadBtn = mkBtn("LOAD", Theme.token("elev"),  Theme.token("text"),      -250, 48)
		local sBtn    = mkBtn("SAVE", Theme.token("accent"), Theme.token("accentText"), -198, 48)
		local autoBtn = mkBtn(isAutoload and "AUTO ★" or "AUTO",
			isAutoload and Theme.token("warn") or Theme.token("elev"),
			isAutoload and Theme.token("accentText") or Theme.token("textDim"),
			-146, 60)
		local delBtn  = mkBtn("✕", Theme.token("elev"), Theme.token("danger"),  -82, 28)

		loadBtn.MouseButton1Click:Connect(function()
			local ok, err = loadConfigInto(name)
			autoloadStatus.Text = ok and ("Loaded: " .. name) or ("Load failed: " .. tostring(err))
		end)
		sBtn.MouseButton1Click:Connect(function()
			local ok, err = saveConfig(name)
			autoloadStatus.Text = ok and ("Overwrote: " .. name) or ("Save failed: " .. tostring(err))
		end)
		autoBtn.MouseButton1Click:Connect(function()
			local current = getAutoloadName()
			if current == name then setAutoloadName(nil)
			else setAutoloadName(name) end
			refreshSettingsList()
		end)
		delBtn.MouseButton1Click:Connect(function()
			deleteConfigFile(name)
			if getAutoloadName() == name then setAutoloadName(nil) end
			refreshSettingsList()
		end)
	end

	refreshSettingsList = function()
		for _, c in ipairs(listHolder:GetChildren()) do
			if c:IsA("Frame") then c:Destroy() end
		end
		local autoload = getAutoloadName()
		autoloadStatus.Text = autoload and ("Will auto-load on script run: " .. autoload) or "No autoload set"
		autoloadStatus.TextColor3 = autoload and Theme.token("warn") or Theme.token("textDim")
		for _, name in ipairs(listConfigs()) do
			configRow(name, name == autoload)
		end
	end
	refreshSettingsList()

	-- ═══════════════════════════ TABS (after all pages are populated) ═══════════════════════════
	ui.newTab("farm",     "Farm",     1)
	ui.newTab("sell",     "Sell",     2)
	ui.newTab("rebirth",  "Rebirth",  3)
	ui.newTab("claims",   "Claims",   4)
	ui.newTab("codes",    "Codes",    5)
	ui.newTab("stats",    "Stats",    6)
	ui.newTab("settings", "Settings", 7)
	ui.setActiveTab("farm")

	-- ═══════════════════════════ MINIMIZE + KEYBIND ═══════════════════════════
	local function makeFloatingIcon()
		local icon = Instance.new("TextButton", ui.gui)
		icon.Size = UDim2.fromOffset(50, 50); icon.Position = UDim2.fromOffset(20, 100)
		Theme.bind(icon, "BackgroundColor3", "panel"); icon.AutoButtonColor = false
		icon.Text = "V"; icon.Font = Enum.Font.Antique; icon.TextSize = 22
		Theme.bind(icon, "TextColor3", "accent"); icon.Active = true; icon.Draggable = true
		Instance.new("UICorner", icon).CornerRadius = UDim.new(1, 0)
		local s = Instance.new("UIStroke", icon)
		Theme.bind(s, "Color", "accent"); s.Thickness = 1.4; s.Transparency = 0.35

		-- pulse the stroke when AFK is active so you can tell the script's alive
		task.spawn(function()
			while icon.Parent do
				if cfg.afkMode then
					local fade = TweenService:Create(s,
						TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
						{ Transparency = 0.75, Thickness = 2.4 })
					fade:Play()
					while icon.Parent and cfg.afkMode do task.wait(0.2) end
					fade:Cancel()
					s.Transparency = 0.3; s.Thickness = 1.6
				else
					task.wait(0.3)
				end
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

	-- RightShift toggles UI visibility
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

	-- ═══════════════════════════ AUTOLOAD ═══════════════════════════
	do
		local autoName = getAutoloadName()
		if autoName then
			local ok, err = loadConfigInto(autoName)
			if ok then
				print("[Vellum] Auto-loaded config:", autoName)
				if cfg.afkMode then
					setAllAuto(true)
					paintAfk()
				end
			else
				warn("[Vellum] Autoload failed: " .. tostring(err))
			end
		end
	end

	-- Apply the persisted theme after autoload (might have loaded a different one)
	Theme.apply(cfg.themeName or "Vellum")

	-- ═══════════════════════════ SPAWN LOOPS ═══════════════════════════
	-- All loops guard with `gui.Parent` so closing the UI tears them down.
	task.spawn(autoCollectLoop)
	task.spawn(autoBuyLoop)
	task.spawn(autoOpenLoop)
	task.spawn(autoSellLoop)
	task.spawn(autoRebirthLoop)
	task.spawn(autoClaimsLoop)
	task.spawn(autoEquipBestLoop)
	task.spawn(autoIndexGemsLoop)
	task.spawn(autoTournamentLoop)
	task.spawn(lowDetailLoop)
	task.spawn(serverHopLoop)
	task.spawn(tradeAutoSendLoop)
	task.spawn(inventoryWatchLoop)
	task.spawn(webhookLoop)
	antiAfkLoop()
	setupCrashRecover()
	setupTradeHandler()

	-- ═══════════════════════════ LIVE REFRESH ═══════════════════════════
	task.spawn(function()
		while gui.Parent do
			safe(refreshRebirthInfo)
			safe(refreshStats)
			task.wait(1)
		end
	end)

	print("[Vellum] Soccer module loaded.")
end

return Module
