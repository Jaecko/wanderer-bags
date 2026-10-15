local _, ns = ...
local L = ns.L

-- The bank in Wanderer's window: opened at the banker beside your bags,
-- closed with them. Your character's tabs, and the account's when the game
-- shows them, one at a time (a link switches). A right click moves an item
-- between the bags and the bank, as in the game. The game's own bank window
-- stays open but out of sight: the game needs it to keep the bank open, and
-- a link brings it back (to buy a tab, to set one).
-- Away from the banker, a link of the bags shows the bank as you left it:
-- to look, to link an item, nothing to move.

local W = Wanderer
local U = W and W.Util
local Safe, Clean = U and U.Safe, U and U.Clean

local bankType -- the bank shown: the character's or the account's
local atBank = false -- at the banker: the bank at hand, not as it was
local gameShown = false -- the player asked for the game's window

local function Types() return Enum and Enum.BankType or {} end

local function On()
	return ns.On() and ns.Settings().bank and true or false
end

-- The tabs bought of a bank, each with its container and its name.
local function EachTab(kind, fn)
	local tabs = kind and C_Bank and Safe(C_Bank.FetchPurchasedBankTabData, kind)
	for index, tab in ipairs(type(tabs) == "table" and tabs or {}) do
		local id = Clean(tab.ID)
		if id then fn(id, Clean(tab.name), index) end
	end
end

local function CanView(kind)
	return kind and C_Bank and Clean(Safe(C_Bank.CanViewBank, kind)) and true or false
end

-- The bank as it was ---------------------------------------------------------------------------
-- Kept by character (the account's for all of them): its tabs, their items, when.

local function Shelf(kind, store)
	local db = WandererBagsDB
	if not (db and kind) then return nil end
	if kind == Types().Account then
		if store then db.account = store end
		return db.account
	end
	local who = Clean(Safe(UnitGUID, "player")) or "player"
	db.characters = db.characters or {}
	if store then db.characters[who] = store end
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
		money = kind == Types().Account and C_Bank and Clean(Safe(C_Bank.FetchDepositedMoney, kind)) or nil }
	EachTab(kind, function(id, name, index)
		local tab = { id = id, name = (name and name ~= "") and name or L.BANK_TAB:format(index), slots = ns.NumSlots(id),
			items = {} }
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
	if store.tabs[1] then Shelf(kind, store) end
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

-- A bank that can be shown: at hand, or seen before.
local function Viewable(kind)
	if atBank then return CanView(kind) end
	return Shelf(kind) ~= nil
end

-- The game's bank window: in sight only when asked for.
local function HideGameBank()
	U.HideOffScreen(_G.BankFrame, On() and not gameShown)
end
ns.RefreshBankFrame = HideGameBank

local function Sort()
	local container, types = C_Container or {}, Types()
	if container.SortBank then
		Safe(container.SortBank, bankType)
	elseif bankType == types.Account then
		Safe(container.SortAccountBankBags)
	else
		Safe(container.SortBankBags)
	end
end

local bank
bank = ns.NewInventory({
	name = "WandererBank",
	title = L.BANK_TITLE,
	on = On,
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
		local tab = SavedTab(bag)
		return tab and tab.name or L.BANK_TAB:format(bag)
	end,
	point = { "TOPLEFT", UIParent, "TOPLEFT", 40, -120 },
	sounds = { "IG_MAINMENU_OPEN", "IG_MAINMENU_CLOSE" },
	-- The bank's own money where the game keeps some (the account's).
	money = function()
		if bankType ~= Types().Account then return nil end
		if atBank then return C_Bank and Clean(Safe(C_Bank.FetchDepositedMoney, bankType)) end
		local store = Shelf(bankType)
		return store and store.money
	end,
	actions = function(window, add)
		-- The character's or the account's.
		window.switch = W.Skin.CreateLink(window, L.BANK_ACCOUNT, function()
			local types = Types()
			bankType = bankType == types.Account and types.Character or types.Account
			if atBank and BankFrame and BankFrame.SetTab and BankFrame.GetTabIDForBankType then
				pcall(BankFrame.SetTab, BankFrame, BankFrame:GetTabIDForBankType(bankType))
			end
			bank.Refresh()
		end)
		add(window.switch)
		local container = C_Container or {}
		if container.SortBank or container.SortBankBags then
			window.sort = W.Skin.CreateLink(window, L.SORT, Sort, L.BANK_SORT_DESC)
			add(window.sort)
		end
		if C_Bank and C_Bank.AutoDepositItemsIntoBank then
			window.deposit = W.Skin.CreateLink(window, L.BANK_DEPOSIT, function()
				Safe(C_Bank.AutoDepositItemsIntoBank, bankType or Types().Character)
			end, L.BANK_DEPOSIT_DESC)
			add(window.deposit)
		end
		-- The game's window, for what only it does (buy a tab, set one).
		window.game = W.Skin.CreateLink(window, L.BANK_GAME, function()
			gameShown = true
			HideGameBank()
		end, L.BANK_GAME_DESC)
		add(window.game)
	end,
	onRefresh = function(window, total, items)
		local types = Types()
		local account = bankType == types.Account
		window.titleText:SetText(account and L.BANK_ACCOUNT_TITLE or L.BANK_TITLE)
		window.switch:SetLabel(account and L.BANK_CHARACTER or L.BANK_ACCOUNT)
		window.switch:SetShown(Viewable(types.Account) and Viewable(types.Character))
		-- Away from the banker: only to look.
		for _, key in ipairs({ "sort", "deposit", "game" }) do
			if window[key] then window[key]:SetShown(atBank) end
		end
		if not atBank then
			local store = Shelf(bankType)
			window.freeText:SetText(store and L.BANK_SEEN:format(U.Ago(time() - (store.time or time())))
 or "")
			return
		end
		ns.KeepSoon(bankType, items)
		-- No tab yet: the game's window says how to buy one.
		if total == 0 and not gameShown then
			gameShown = true
			HideGameBank()
		end
	end,
	-- Closed here at the banker: the bank closes, as when you walk away.
	onHide = function()
		if atBank and C_Bank and C_Bank.CloseBankFrame then Safe(C_Bank.CloseBankFrame) end
	end,
})
ns.Bank = bank

-- At the banker (what is chosen in the bags can go into the bank).
function ns.AtBank() return atBank end

-- The bank as it was, from the bags: there is one to show, and showing it.
function ns.HasSavedBank()
	local types = Types()
	return not atBank and On() and (Shelf(types.Character) or Shelf(types.Account)) and true or false
end

function ns.ToggleSavedBank()
	if atBank then return end
	if bank.IsShown() then return bank.Close() end
	local types = Types()
	bankType = Shelf(types.Character) and types.Character or types.Account
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
	if not On() then return end
	atBank, gameShown = true, false
	local types = Types()
	bankType = CanView(types.Character) and types.Character or (CanView(types.Account) and types.Account) or types.Character
	-- Both banks kept as they are now (the one not shown too).
	Snapshot(types.Character)
	Snapshot(types.Account)
	HideGameBank()
	bank.Open()
	ns.Bags.Open()
end

local function Closed()
	ns.KeepSoon()
	atBank, gameShown = false, false
	bank.Close()
	HideGameBank()
	ns.Bags.Soon()
end

function ns.InitBank()
	WandererBagsDB = WandererBagsDB or {}
	local events = CreateFrame("Frame")
	pcall(events.RegisterEvent, events, "BANKFRAME_OPENED")
	pcall(events.RegisterEvent, events, "BANKFRAME_CLOSED")
	events:SetScript("OnEvent", function(_, event)
		if event == "BANKFRAME_OPENED" then
			-- After the game has shown its own window (then put out of sight).
			C_Timer.After(0, Opened)
		else
			Closed()
		end
	end)
	-- The game shows its window again and again (tabs, layout): out of sight each time.
	if BankFrame and BankFrame.HookScript then BankFrame:HookScript("OnShow", function() HideGameBank() end) end
end
