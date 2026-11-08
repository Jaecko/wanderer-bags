local _, ns = ...
local L = ns.L

-- The bank in Wanderer's window: opened at the banker beside your bags,
-- closed with them, drawn like them (the same sections, the same squares,
-- the search, the marks). Your character's tabs, and the account's when the
-- game shows them, one at a time (a link switches); a bank of the older kind
-- (one container and its bags) the same way. A right click moves an item
-- between the bags and the bank, as in the game. The game's own bank window
-- stays open but out of sight: the game needs it to keep the bank open, and
-- a link brings it back (to buy a tab or a bag slot, to set one).
-- Away from the banker, a link of the bags shows the bank as you left it:
-- to look, to link an item, nothing to move.
-- What you marked for the bank goes into it as you arrive (an option, Shift
-- held skips it), or with a link of the bank's window.

local W = Wanderer
local U = W and W.Util
local Safe, Clean = U and U.Safe, U and U.Clean

local STEP = 0.15 -- one item moved at a time (the game refuses moves sent too fast)
local WAIT_STEPS = 20 -- the cursor busy that many steps: the deposit given up
local DEPOSIT_DELAY = 0.4 -- after the bank is open and read
local EMPTY_CHECK = 1 -- no slot shown that long after the banker opened: the game's window

local bankType -- the bank shown: the character's or the account's
local atBank = false -- at the banker, the window in use: the bank at hand, not as it was
local bankerOpen = false -- at the banker (the window in use or not)
local gameShown = false -- the player asked for the game's window
local lastTotal -- the slots the window showed last, at the banker

-- The kinds of bank (the game's numbers; an older client without them: names of ours).
local function Types() return Enum and Enum.BankType or {} end
local function CharacterKind() return Types().Character or "character" end
local function AccountKind() return Types().Account or "account" end

local function On()
	return ns.On() and ns.Settings().bank and true or false
end

-- A bank the game tells about by tabs (yours, the account's).
local function HasTabs()
	local types = Types()
	return U.BankTabs(types.Character)[1] ~= nil or U.BankTabs(types.Account)[1] ~= nil
end

-- A bank's containers: its tabs bought; a bank of the older kind (no tab told), the character's: its own
-- container and its bags, each a tab here.
local function TabsOf(kind)
	local tabs = U.BankTabs(kind)
	if tabs[1] or kind ~= CharacterKind() or HasTabs() then return tabs end
	local list = {}
	for index, id in ipairs(U.BankIDs()) do
		local name = id == (BANK_CONTAINER or -1) and L.BANK_TITLE or Clean(Safe(C_Container.GetBagName, id))
		list[#list + 1] = { id = id, name = name or L.BANK_TAB:format(index) }
	end
	return list
end

-- The tabs of a bank, each with its container and its name.
local lastTabs = {} -- kind -> the tabs read at the banker: { { id, name, slots } }, for after he is gone
local function EachTab(kind, fn)
	local list, any = {}, false
	for _, tab in ipairs(TabsOf(kind)) do
		local slots = ns.NumSlots(tab.id)
		local known = lastTabs[kind]
		-- (its size as the game says it, else as it was seen at the banker)
		if slots == 0 and known then
			for _, old in ipairs(known) do if old[1] == tab.id then slots = old[3] or 0 end end
		end
		if slots > 0 then any = true end
		list[#list + 1] = { tab.id, tab.name, slots }
	end
	if any then lastTabs[kind] = list else list = lastTabs[kind] or list end
	for index, tab in ipairs(list) do fn(tab[1], tab[2], index, tab[3]) end
end

local function CanView(kind)
	return kind and C_Bank and Clean(Safe(C_Bank.CanViewBank, kind)) and true or false
end

-- The bank as it was ---------------------------------------------------------------------------
-- Kept by character (the account's for all of them): its tabs, their items, when.

local function Shelf(kind, store)
	local db = WandererBagsDB
	if not (db and kind) then return nil end
	if kind == AccountKind() then
		if store then db.account = store end
		return db.account
	end
	local who = Clean(Safe(UnitGUID, "player")) or "player"
	db.characters = db.characters or {}
	if store then
		db.characters[who] = store
		ns.countsCache = nil
	end
	return db.characters[who]
end

local function Snapshot(kind, items)
	local read
	if items then
		read = {}
		for _, item in ipairs(items) do
			read[item.bag] = read[item.bag] or {}
			read[item.bag][item.slot] = item.info
		end
	end
	local store = { time = time(), tabs = {},
		money = kind == AccountKind() and C_Bank and Clean(Safe(C_Bank.FetchDepositedMoney, kind)) or nil }
	local any = false
	EachTab(kind, function(id, name, index, slots)
		local tab = { id = id, name = (name and name ~= "") and name or L.BANK_TAB:format(index), slots = slots or 0, items = {} }
		if tab.slots > 0 then any = true end
		for slot = 1, tab.slots do
			local info
			if read then info = read[id] and read[id][slot] else info = Safe(C_Container.GetContainerItemInfo, id, slot) end
			local link = type(info) == "table" and Clean(info.hyperlink)
			if link then
				tab.items[slot] = { itemID = Clean(info.itemID), quality = Clean(info.quality), iconFileID = Clean(info.iconFileID),
					stackCount = Clean(info.stackCount), hasNoValue = Clean(info.hasNoValue), hyperlink = link }
			end
		end
		store.tabs[#store.tabs + 1] = tab
	end)
	if store.tabs[1] and any then
		Shelf(kind, store)
		ns.NoteCarriedSoon()
	end
end

local function SavedTab(bag)
	local store = Shelf(bankType)
	for _, tab in ipairs(store and store.tabs or {}) do
		if tab.id == bag then return tab end
	end
end

local function SavedInfo(bag, slot)
	local tab = SavedTab(bag)
	return tab and tab.items[slot]
end

-- An older bank's counts, kept by earlier versions (before it had its window): read until it is seen again.
local function OldBank()
	local db = WandererBagsDB
	local saved = db and type(db.oldBank) == "table" and db.oldBank[Clean(Safe(UnitGUID, "player")) or "player"]
	return type(saved) == "table" and type(saved.counts) == "table" and saved.counts or nil
end

-- This character's own bank as last seen, counted by item (for what your characters carry, an outfit's pieces):
-- counted once, again when the bank is kept anew. Read only.
function ns.SavedBankCounts()
	local cache = ns.countsCache
	if cache and cache.db == WandererBagsDB then return cache.counts end
	local counts = {}
	ns.countsCache = { db = WandererBagsDB, counts = counts }
	local store = Shelf(CharacterKind())
	-- (never seen since: the older bank's counts, when read)
	if not (store and store.tabs and store.tabs[1]) then
		for id, count in pairs(OldBank() or {}) do counts[id] = count end
		return counts
	end
	for _, tab in ipairs(store.tabs) do
		for _, item in pairs(type(tab.items) == "table" and tab.items or {}) do
			local id = tonumber(item.itemID)
			if id then counts[id] = (counts[id] or 0) + (tonumber(item.stackCount) or 1) end
		end
	end
	return counts
end

-- A bank that can be shown: at hand, or seen before.
local function Viewable(kind)
	if atBank then return CanView(kind) end
	return Shelf(kind) ~= nil
end

-- The game's bank window: in sight only when asked for.
local function HideGameBank()
	U.HideOffScreen(_G.BankFrame, On() and bankerOpen and not gameShown)
end
ns.RefreshBankFrame = HideGameBank

local function ShowGameBank()
	gameShown = true
	HideGameBank()
end

local function Sort()
	local container = C_Container or {}
	if container.SortBank then
		Safe(container.SortBank, bankType)
	elseif bankType == AccountKind() then
		Safe(container.SortAccountBankBags)
	else
		Safe(container.SortBankBags)
	end
end

-- What is marked for the bank ----------------------------------------------------------------------

-- What your bags hold marked for the bank, or in a section that always goes there: { { bag, slot, id, count } }.
-- What a quest asks you to carry, and what Wanderer Auction's shopping list wants on you, stays in the bags.
-- (Wanderer Auction turned off: its list holds nothing back)
function ns.MarkedInBags()
	local list = {}
	local auction = ns.Auction()
	local shop = auction and auction.InShopping
	-- (each item's section read only when one of them goes to the bank)
	local sections = ns.AnySectionToBank and ns.AnySectionToBank()
	U.EachBagItem(function(bag, slot, info)
		local id = Clean(info.itemID)
		local wanted = id and (ns.IsForBank(id) or sections and ns.SectionToBank(ns.SectionOf(bag, slot)))
		if wanted and not Clean(info.isLocked) and not ns.QuestNeed(id) and not (shop and Safe(shop, id)) then
			list[#list + 1] = { bag = bag, slot = slot, id = id, count = Clean(info.stackCount) or 1 }
		end
	end)
	return list
end

-- How many of an item one slot holds.
local function MaxStack(id)
	local max = C_Item and C_Item.GetItemMaxStackSizeByID and Clean(Safe(C_Item.GetItemMaxStackSizeByID, id))
	if not max then max = Clean(select(8, Safe(C_Item and C_Item.GetItemInfo or GetItemInfo, id))) end
	return tonumber(max) or 1
end

-- A bag of the bank that takes only some items (a herb bag...): this one or not.
local function Fits(bag, id)
	local family = ns.BagFamily(bag)
	if family == 0 then return true end
	local own = Clean(Safe(C_Item and C_Item.GetItemFamily or _G.GetItemFamily, id)) or 0
	return bit and bit.band and bit.band(own, family) ~= 0 or false
end

-- Where an item goes in the bank: a stack of it with room for all of it, else an empty slot (the character's
-- bank first; the account's only when the character has none). taken: the slots already given this run.
local function Target(entry, taken)
	local containers = {}
	EachTab(CharacterKind(), function(id) containers[#containers + 1] = id end)
	if not containers[1] then EachTab(AccountKind(), function(id) containers[#containers + 1] = id end) end
	local max, empty = MaxStack(entry.id), nil
	for _, bag in ipairs(containers) do
		local fits = Fits(bag, entry.id)
		for slot = 1, ns.NumSlots(bag) do
			if not taken[bag .. ":" .. slot] then
				local info = Safe(C_Container.GetContainerItemInfo, bag, slot)
				if type(info) ~= "table" then
					if fits and not empty then empty = { bag, slot } end
				elseif Clean(info.itemID) == entry.id and not Clean(info.isLocked) and (Clean(info.stackCount) or 1) + entry.count <= max then
					return bag, slot
				end
			end
		end
	end
	if empty then return empty[1], empty[2] end
end

-- One item at a time ---------------------------------------------------------------------------------------
-- Every move of the bags' and the bank's items made for you (what is marked, the selection, an outfit's pieces):
-- one item, then the next a moment later (the game refuses moves sent too fast); at the banker only, never in a
-- fight, never while the cursor holds something (waited for a moment, then given up). One run at a time.
-- move(entry, job) -> "moved", "sent" (asked of the game: counted once it really left its place, a moment later;
-- still there as it was, the bank is full), "full" (the rest stays: the bank is full) or nil (that one skipped);
-- done(job) once over: { moved, left, done (the entries moved) }. Returns true when it started.

local moving -- the run going on
local CHECKS = 4 -- steps a move sent waits for the game's answer before it is judged refused

local function MoveOneByOne(list, move, done)
	if moving or not (bankerOpen and list and list[1]) or InCombatLockdown() or GetCursorInfo() then return false end
	local job = { list = list, index = 0, moved = 0, left = 0, waits = 0, taken = {}, done = {} }
	moving = job
	local function Moved(entry)
		job.moved = job.moved + 1
		job.done[#job.done + 1] = entry
	end
	-- The move sent last: gone (or on its way, locked), counted, false; still there as it was: refused, true (nil:
	-- the game's answer waited for a step more). final: judged now.
	local function Refused(final)
		local sent = job.sent
		if not sent then return false end
		local info = Safe(C_Container.GetContainerItemInfo, sent.entry.bag, sent.entry.slot)
		local still = type(info) == "table" and Clean(info.itemID) == sent.entry.id and not Clean(info.isLocked)
			and (Clean(info.stackCount) or 1) == sent.count
		if still and not final and sent.checks < CHECKS then
			sent.checks = sent.checks + 1
			return nil
		end
		job.sent = nil
		if still then return true end
		Moved(sent.entry)
		return false
	end
	local function Finish()
		if moving ~= job then return end
		Refused(true)
		moving = nil
		if done then done(job) end
		ns.RefreshAll()
	end
	local function Step()
		if moving ~= job then return end
		if not bankerOpen or InCombatLockdown() then
			-- (the move sent last still waits for the game's answer: waited for, nothing more sent)
			if Refused(false) == nil then return C_Timer.After(STEP, Step) end
			return Finish()
		end
		local refused = Refused(false)
		if refused == nil then return C_Timer.After(STEP, Step) end
		if refused then
			job.left = #list - job.index + 1
			return Finish()
		end
		if GetCursorInfo() then
			job.waits = job.waits + 1
			if job.waits > WAIT_STEPS then return Finish() end
			return C_Timer.After(STEP, Step)
		end
		job.index = job.index + 1
		local entry = list[job.index]
		if not entry then return Finish() end
		local result = move(entry, job)
		if result == "moved" then
			Moved(entry)
		elseif result == "sent" then
			job.sent = { entry = entry, count = entry.count or 1, checks = 0 }
		elseif result == "full" then
			job.left = #list - job.index + 1
			return Finish()
		end
		C_Timer.After(STEP, Step)
	end
	Step()
	return true
end
ns.MoveOneByOne = MoveOneByOne
function ns.Moving() return moving ~= nil end

-- The item still there as it was read (the same item, not held): its info.
local function StillThere(entry)
	local info = Safe(C_Container.GetContainerItemInfo, entry.bag, entry.slot)
	if type(info) == "table" and Clean(info.itemID) == entry.id and not Clean(info.isLocked) then return info end
end

-- (an item taken or put down by the cursor, whichever name the client gives it)
local function Pickup() return C_Container.PickupContainerItem or _G.PickupContainerItem end

-- Into the bank: a stack of it with room, else an empty slot (Target).
local function IntoBank(entry, job)
	local info = StillThere(entry)
	if not info then return nil end
	entry.count = Clean(info.stackCount) or entry.count
	local bag, slot = Target(entry, job.taken)
	if not bag then return "full" end
	job.taken[bag .. ":" .. slot] = true
	Safe(Pickup(), entry.bag, entry.slot)
	local what, held = GetCursorInfo()
	if what == "item" and held == entry.id then
		Safe(Pickup(), bag, slot)
		-- (refused: the item back where it was)
		if not GetCursorInfo() then return "moved" end
		ClearCursor()
	elseif what then
		ClearCursor()
	end
	return nil
end

-- Said once, quietly: how many went in, how many stayed for want of room.
local function SayDeposited(job)
	if job.moved > 0 then W.Print(L.TO_BANK_DONE:format(job.moved)) end
	if job.left > 0 then W.Print(L.TO_BANK_FULL:format(job.left)) end
end

-- What is marked for the bank, out of your bags into it (at the banker). Returns true when it started.
function ns.DepositMarked()
	return MoveOneByOne(ns.MarkedInBags(), IntoBank, SayDeposited)
end

-- The bags' selection into the bank shown (yours or the account's), one after another; counted only once it
-- really went in (a full bank: said once, the rest stays). done(moved) once over, with the entries that went in
-- ({ bag, slot, id }). Returns true when it started.
function ns.DepositChosen(items, done)
	local list = {}
	for _, item in ipairs(items or {}) do
		if item.id then list[#list + 1] = { bag = item.bag, slot = item.slot, id = item.id } end
	end
	return MoveOneByOne(list, function(entry)
		local info = StillThere(entry)
		if not info then return nil end
		entry.count = Clean(info.stackCount) or 1
		-- (a right click's move: into the tab shown; an older bank has but one)
		Safe(C_Container.UseContainerItem, entry.bag, entry.slot, nil, type(bankType) == "number" and bankType or nil)
		return "sent"
	end, function(job)
		SayDeposited(job)
		if done then done(job.done) end
	end)
end

-- An outfit's pieces out of the bank ------------------------------------------------------------------------
-- With Wanderer Outfits: at the banker, the pieces an outfit lacks that wait in the bank come into your bags in
-- one click, one after another, as the deposit goes (never in a fight).

-- The bank's containers at the banker: the character's (an older bank: its own and its bags), then the account's.
local function BankContainers()
	local list = {}
	EachTab(CharacterKind(), function(id) list[#list + 1] = id end)
	if HasTabs() then EachTab(AccountKind(), function(id) list[#list + 1] = id end) end
	return list
end

-- The bank's items at hand, read once: { { bag, slot, id } } (what the cursor holds aside).
local function BankItems()
	local list = {}
	for _, bag in ipairs(BankContainers()) do
		for slot = 1, ns.NumSlots(bag) do
			local info = Safe(C_Container.GetContainerItemInfo, bag, slot)
			local id = type(info) == "table" and Clean(info.itemID)
			if id and not Clean(info.isLocked) then list[#list + 1] = { bag = bag, slot = slot, id = id } end
		end
	end
	return list
end

-- The bank's slots holding what is wanted ({ [item id] = how many }), a slot for each one wanted: { { bag, slot, id } }.
local function Wanted(wants, items)
	local left, list = {}, {}
	for id, count in pairs(wants) do left[id] = count end
	for _, item in ipairs(items or BankItems()) do
		if (left[item.id] or 0) > 0 then
			list[#list + 1] = item
			left[item.id] = left[item.id] - 1
		end
	end
	return list
end

-- wants: { [item id] = how many }. Returns true when it started.
function ns.TakeFromBank(wants)
	if type(wants) ~= "table" or not bankerOpen then return false end
	return MoveOneByOne(Wanted(wants), function(entry)
		local info = StillThere(entry)
		if not info then return nil end
		entry.count = Clean(info.stackCount) or 1
		-- (a right click on a bank's item: into your bags, as in the game; counted once it really came, full
		-- bags: the rest stays)
		Safe(C_Container.UseContainerItem, entry.bag, entry.slot)
		return "sent"
	end, function(job)
		if job.moved > 0 then W.Print(L.TAKEN_FROM_BANK:format(job.moved)) end
	end)
end

-- The first outfit (Wanderer Outfits' order) whose missing pieces wait in this bank: { name, wants, count }.
local function OutfitInBank()
	local api = type(WandererOutfits) == "table" and WandererOutfits.BankPieces
	if not (atBank and type(api) == "function") then return nil end
	local ok, list = pcall(api)
	if not (ok and type(list) == "table" and list[1]) then return nil end
	local items = BankItems()
	for _, outfit in ipairs(list) do
		local wants = type(outfit) == "table" and type(outfit.ids) == "table" and outfit.ids or {}
		local count = #Wanted(wants, items)
		if count > 0 and outfit.name then return { name = outfit.name, wants = wants, count = count } end
	end
end

-- The bank's heading: "Take "Raid" (2)", shown while an outfit's pieces wait here (nothing read while items move:
-- hidden then, drawn again once the run is over).
function ns.PaintOutfitButton(window)
	if moving then
		window.outfitFound = nil
		window.outfit:Hide()
		return
	end
	local found = OutfitInBank()
	window.outfitFound = found
	window.outfit:SetShown(found ~= nil)
	if found then
		window.outfit:SetLabel(ns.WithSign(ns.BANK_SIGN, L.TAKE_OUTFIT:format(found.name, found.count)))
	end
end
function ns.TakeOutfit()
	local found = ns.Bank.window and ns.Bank.window.outfitFound
	if found and ns.TakeFromBank(found.wants) then ns.Bank.window.outfit:Hide() end
end
function ns.OutfitTip()
	local found = ns.Bank.window and ns.Bank.window.outfitFound
	return found and { L.TAKE_OUTFIT_TITLE, { L.TAKE_OUTFIT_DESC:format(found.name), 0.9, 0.88, 0.82 } } or nil
end

-- The window ---------------------------------------------------------------------------------

local bank
bank = ns.NewInventory({
	name = "WandererBagsBank",
	title = L.BANK_TITLE,
	on = On,
	bank = true,
	containers = function()
		local list = {}
		if atBank then
			EachTab(bankType, function(id) list[#list + 1] = id end)
		else
			local store = Shelf(bankType)
			for _, tab in ipairs(store and store.tabs or {}) do list[#list + 1] = tab.id end
		end
		return list
	end,
	source = function() return not atBank and SavedInfo or nil end,
	numSlots = function(bag)
		if atBank then return ns.NumSlots(bag) end
		local tab = SavedTab(bag)
		return tab and tab.slots or 0
	end,
	nameOf = function(bag)
		-- (at the banker: its name as the game says it now)
		local name
		if atBank then EachTab(bankType, function(id, tabName) if id == bag then name = tabName end end) end
		if name and name ~= "" then return name end
		local tab = SavedTab(bag)
		if tab then return tab.name end
		-- (a tab bought while at the banker, not kept yet: its place among the tabs)
		local place = 0
		EachTab(bankType, function(id, _, index) if id == bag then place = index end end)
		return L.BANK_TAB:format(place)
	end,
	point = { "TOPLEFT", UIParent, "TOPLEFT", 40, -120 },
	sounds = { "IG_MAINMENU_OPEN", "IG_MAINMENU_CLOSE" },
	-- The bank's own money where the game keeps some (the account's).
	money = function()
		if bankType ~= AccountKind() then return nil end
		if atBank then return C_Bank and Clean(Safe(C_Bank.FetchDepositedMoney, bankType)) end
		local store = Shelf(bankType)
		return store and store.money
	end,
	settings = "ext:bags",
	-- The footer's Sort: the game's sorting of the bank shown, at the banker.
	sort = Sort,
	sortTip = L.BANK_SORT_DESC,
	canSort = function()
		local container = C_Container or {}
		return atBank and (container.SortBank or container.SortBankBags) ~= nil
	end,
	-- The heading: what depends on where you are (an outfit's pieces here, which bank).
	actions = function(window, add)
		-- At the banker, an outfit's pieces left in the bank (with Wanderer Outfits): taken in one click (a quiet link,
		-- as the bags' own: the window's one gold call is the footer's).
		window.outfit = W.Skin.SmallButton(window, "", function() ns.TakeOutfit() end, function() return ns.OutfitTip() end, 22)
		add(window.outfit)
		-- The character's or the account's: both words, the one shown in gold.
		window.switch = W.Skin.Choices(window, { { "character", L.BANK_CHARACTER }, { "account", L.BANK_ACCOUNT } }, function(key)
			local kind = key == "account" and AccountKind() or CharacterKind()
			if kind == bankType then return end
			bankType = kind
			if atBank and BankFrame and BankFrame.SetTab and BankFrame.GetTabIDForBankType then
				pcall(BankFrame.SetTab, BankFrame, BankFrame:GetTabIDForBankType(bankType))
			end
			bank.Refresh()
		end, 22)
		add(window.switch)
	end,
	-- The footer, after Sort (at the banker): what you marked for the bank, the game's deposit of reagents, the game's window (to buy a tab or a bag
	-- slot, set one). The arrangement stays the bags' footer's, beside it.
	footTools = function(window, add)
		-- What you marked for the bank, put in it now (shown while some wait in your bags): the window's main action.
		window.marked = W.Skin.Button(window, L.BANK_DEPOSIT_MARKED:format(0), function() ns.DepositMarked() end, "main")
		window.marked:SetHeight(22)
		W.Skin.Tooltip(window.marked, L.BANK_DEPOSIT_MARKED_DESC)
		add(window.marked)
		if C_Bank and C_Bank.AutoDepositItemsIntoBank then
			window.deposit = W.Skin.SmallButton(window, L.BANK_DEPOSIT, function()
				Safe(C_Bank.AutoDepositItemsIntoBank, bankType)
			end, L.BANK_DEPOSIT_DESC, 22)
			add(window.deposit)
		end
		window.game = W.Skin.SmallButton(window, L.BANK_GAME, ShowGameBank, L.BANK_GAME_DESC, 22)
		add(window.game)
	end,
	onRefresh = function(window, total, items)
		local account = bankType == AccountKind()
		window.titleText:SetText(account and L.BANK_ACCOUNT_TITLE or L.BANK_TITLE)
		window.switch:Select(account and "account" or "character")
		window.switch:SetShown(Viewable(AccountKind()) and Viewable(CharacterKind()))
		-- Away from the banker: only to look.
		for _, key in ipairs({ "deposit", "game" }) do
			if window[key] then window[key]:SetShown(atBank) end
		end
		ns.PaintOutfitButton(window)
		local marked = atBank and not ns.Moving() and #ns.MarkedInBags() or 0
		if marked > 0 then
			window.marked:SetText(L.BANK_DEPOSIT_MARKED:format(marked))
			window.marked:Fit()
		end
		window.marked:SetShown(marked > 0)
		if not atBank then
			local store = Shelf(bankType)
			local seconds = time() - (store and store.time or time())
			window.freeText:SetText(store and L.BANK_SEEN:format(U.AgoWords(seconds)) or "")
			return
		end
		lastTotal = total
		ns.KeepSoon(bankType, items)
	end,
	-- Closed here at the banker: the bank closes, as when you walk away.
	onHide = function()
		if not atBank then return end
		if C_Bank and C_Bank.CloseBankFrame then
			Safe(C_Bank.CloseBankFrame)
		elseif _G.CloseBankFrame then
			Safe(_G.CloseBankFrame)
		end
	end,
})
ns.Bank = bank

-- At the banker (what is chosen in the bags can go into the bank).
function ns.AtBank() return atBank end

-- The bank as it was, from the bags: there is one to show, and showing it.
function ns.HasSavedBank()
	return not atBank and On() and (Shelf(CharacterKind()) or Shelf(AccountKind())) and true or false
end

function ns.ToggleSavedBank()
	if atBank then return end
	if bank.IsShown() then return bank.Close() end
	bankType = Shelf(CharacterKind()) and CharacterKind() or AccountKind()
	bank.Open()
end

-- The bank kept at most once a moment (each change at the banker draws it again): the last one read;
-- at once when another bank is shown or the banker left.
local keeping
function ns.KeepSoon(kind, items)
	if keeping and (kind == nil or keeping.kind ~= kind) then
		Snapshot(keeping.kind, keeping.items)
		keeping = nil
	end
	if kind == nil then return end
	local first = not keeping
	keeping = { kind = kind, items = items }
	if first then
		C_Timer.After(1, function()
			if keeping then
				Snapshot(keeping.kind, keeping.items)
				keeping = nil
			end
		end)
	end
end

local function Opened()
	if not (bankerOpen and On()) then return end
	if BankFrame and BankFrame.IsShown and not BankFrame:IsShown() then return end
	atBank, gameShown, lastTotal = true, false, nil
	local character, account = CharacterKind(), AccountKind()
	bankType = CanView(character) and character or (CanView(account) and account) or character
	-- Both banks kept as they are now (the one not shown too).
	Snapshot(character)
	if HasTabs() then Snapshot(account) end
	HideGameBank()
	bank.Open()
	ns.Bags.Open()
	-- Nothing to show a moment later (no tab bought, the game slow to tell): the game's window says what to do.
	C_Timer.After(EMPTY_CHECK, function()
		if atBank and (lastTotal or 0) == 0 and not gameShown then ShowGameBank() end
	end)
end

local function Closed()
	ns.KeepSoon()
	atBank, gameShown, lastTotal = false, false, nil
	bank.Close()
	HideGameBank()
	ns.Bags.Soon()
end

-- At the banker: what is marked goes in by itself (the option on, Shift not held as he opened).
local skipping = false
local function Arrived()
	local settings = ns.Settings()
	if skipping or not (bankerOpen and ns.On() and settings and settings.toBank) then return end
	ns.DepositMarked()
end

function ns.InitBank()
	WandererBagsDB = WandererBagsDB or {}
	local events = CreateFrame("Frame")
	for _, event in ipairs({ "BANKFRAME_OPENED", "BANKFRAME_CLOSED", "PLAYERBANKSLOTS_CHANGED", "PLAYERBANKBAGSLOTS_CHANGED" }) do
		pcall(events.RegisterEvent, events, event)
	end
	events:SetScript("OnEvent", function(_, event)
		if event == "BANKFRAME_OPENED" then
			bankerOpen, skipping = true, U.IsSkipping() and true or false
			HideGameBank()
			-- After the game has shown its own window (then put out of sight).
			C_Timer.After(0, Opened)
			C_Timer.After(DEPOSIT_DELAY, Arrived)
		elseif event == "BANKFRAME_CLOSED" then
			bankerOpen = false
			Closed()
		else
			-- (the older bank's own container, and its bag slots, tell their changes apart)
			bank.Soon()
		end
	end)
	-- The game shows its window again and again (tabs, layout): out of sight each time.
	if BankFrame and BankFrame.HookScript then BankFrame:HookScript("OnShow", function() HideGameBank() end) end
end
