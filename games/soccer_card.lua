-- Vellum — game module: Spin a Soccer Card
-- PlaceId 112490729816320
--
-- Module protocol expected by the loader:
--   { name, placeIds, start(lib) }
--
-- The full game runs inside start(). lib bundles { theme, helpers, toast, ui }
-- from the shared modules.

local LOADER_URL = "https://raw.githubusercontent.com/Pekenz/vellum/main/loader.lua"

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

	-- ═══════════════════════════ EXPORT ═══════════════════════════
	-- Stash the locals we'll need from pass 5b's UI builders (tabs + buttons).
	-- 5b will pick up from here and wire tabs into ui.* widgets.
	local Internal = {
		cfg = cfg,
		stats = stats,
		R = R,
		ui = ui,
		gui = gui,
		safe = safe,
		jwait = jwait,
		getMe = getMe,
		fmt = fmt, fmtDur = fmtDur, perHour = perHour,
		cardIncome = cardIncome,
		cardRarity = cardRarity,
		ownedCardPool = ownedCardPool,
		canRebirth = canRebirth,
		hopNow = hopNow,
		setAllAuto = setAllAuto,
		fireTradeRequest = fireTradeRequest,
		resolveTradeTarget = resolveTradeTarget,
		tpToPlayer = tpToPlayer,
		tpToTargetByUsername = tpToTargetByUsername,
		setupCrashRecover = setupCrashRecover,
		setupTradeHandler = setupTradeHandler,
		RARITY_WEIGHT = RARITY_WEIGHT,
		LOADER_URL = LOADER_URL,
	}
	_G.__VellumSoccer = Internal  -- exposed for 5b sub-pass to wire UI; removed in final cleanup

	-- ═══════════════════════════ SPAWN LOOPS ═══════════════════════════
	-- All loops guard with `gui.Parent` so closing the UI destroys them.
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

	-- Apply the persisted theme before any UI mounts further widgets
	Theme.apply(cfg.themeName or "Vellum")

	-- NOTE: tabs + AFK card + persistence UI + theme picker + floating icon
	-- are populated in pass 5b. Until then the panel will be blank but the
	-- background auto-loops are live.
end

return Module
