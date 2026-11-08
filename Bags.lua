local ADDON, ns = ...
local L = ns.L

-- Your bags in Wanderer's window, in place of the game's: its keys, its bag
-- buttons, the merchant or the mailbox open this window while it is on
-- (unless Wanderer keeps the bags closed there: the window follows).
-- Nothing of the game's is replaced: it opens and closes its own bags as
-- always, this window follows them, and the game's frames for your bags are
-- kept out of sight. Wanderer turned off, or this option: the game's bags,
-- as they were.

local W = Wanderer
local U = W and W.Util
local Safe, Clean = U and U.Safe, U and U.Clean

-- Another bags addon (Baganator, Bagnon, AdiBags, ArkInventory, ElvUI's bags) has the bags: Wanderer Bags steps
-- aside, the game's bag windows stay that addon's (what you keep stays guarded at merchants).
local function Yielded() return W and W.Yields and W.Yields("bags") and true or false end
ns.Yielded = Yielded

local function On()
	local settings = ns.Settings()
	return settings and settings.enabled and not Yielded() and true or false
end
ns.On = On

local function Bags() return U.BagIDs() end

-- A link's words after its sign (the banker's, the auctioneer's), drawn in the line.
local BANK_SIGN, SHOP_SIGN = "Interface\\Minimap\\Tracking\\Banker", "Interface\\Minimap\\Tracking\\Auctioneer"
ns.BANK_SIGN = BANK_SIGN
function ns.WithSign(sign, words) return ("|T%s:14:14|t %s"):format(sign, words) end

local bags = ns.NewInventory({
	name = "WandererBagsWindow",
	title = L.TITLE,
	on = On,
	containers = Bags,
	nameOf = function(bag) return Clean(Safe(C_Container and C_Container.GetBagName, bag)) or BAG_NAME_BACKPACK end,
	point = { "BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -80, 120 },
	sounds = { "IG_BACKPACK_OPEN", "IG_BACKPACK_CLOSE" },
	canSell = true,
	selectable = true,
	markHint = true,
	help = L.HELP_TIP,
	settings = "ext:bags",
	-- The footer's Sort: the game's own sorting.
	sort = function() Safe(C_Container.SortBags) end,
	canSort = function() return C_Container ~= nil and C_Container.SortBags ~= nil end,
	-- In the heading, only what depends on where you are, each with its sign: the bank as you left it (away from
	-- the banker), the shopping list (with Wanderer Auction).
	actions = function(window, add)
		window.bank = W.Skin.SmallButton(window, ns.WithSign(BANK_SIGN, L.BANK_TITLE), function() ns.ToggleSavedBank() end, L.BANK_SEEN_DESC)
		add(window.bank)
		-- With Wanderer Auction: the shopping list, and how many items it still lacks.
		window.shop = W.Skin.SmallButton(window, ns.WithSign(SHOP_SIGN, L.SHOP_LINK), function()
			if type(WandererAuction) == "table" and WandererAuction.ToggleList then WandererAuction.ToggleList() end
		end, L.SHOP_LINK_DESC)
		add(window.shop)
	end,
	onRefresh = function(window)
		window.bank:SetShown(ns.HasSavedBank())
		ns.ShopLink(window)
	end,
	-- Opened or closed by itself (a link, its cross, Escape): the game's bags with it.
	onShow = function() ns.GameBagsFollow(true) end,
	onHide = function() ns.GameBagsFollow(false) end,
})
ns.Bags = bags

-- The shopping list's link: shown with Wanderer Auction, its count of items still missing.
local shopWindow
function ns.ShopLink(window)
	shopWindow = window or shopWindow
	local link = shopWindow and shopWindow.shop
	if not link then return end
	-- (Auction switched off: no link, as no list to open)
	local api = ns.Auction()
	if api and not api.ToggleList then api = nil end
	link:SetShown(api ~= nil)
	if not api then return end
	local lack = api.ShoppingLack and api.ShoppingLack() or 0
	link:SetLabel(ns.WithSign(SHOP_SIGN, lack > 0 and L.SHOP_LINK_COUNT:format(lack) or L.SHOP_LINK))
end

-- The list changed (Wanderer Auction says it): the link alone, the heading's links placed again.
function ns.ShopRefresh()
	if not (shopWindow and shopWindow:IsShown()) then return end
	ns.ShopLink()
	bags.ChainLinks()
end

-- Where an item may be sold (a merchant, the auction house): kept items are guarded there.
function ns.Guarding()
	return ns.auctionOpen or W.IsMerchantOpen() or false
end

-- The game's bags: Wanderer's window in their place --------------------------------------------

local function IsBag(id)
	id = tonumber(id)
	if not id then return false end
	for _, bag in ipairs(Bags()) do if bag == id then return true end end
	return false
end

-- The game's frames for your bags (all of them together, or one by one): kept under this hidden frame while
-- the window is on, back under their own parent when it is off. Another container stays the game's.
local hidden = CreateFrame("Frame")
hidden:Hide()
local parents = {} -- the game's frame -> its own parent
local function Tuck(frame)
	if type(frame) ~= "table" or not frame.SetParent then return end
	local mine = On() and (frame == _G.ContainerFrameCombinedBags or IsBag(frame.GetID and frame:GetID()))
	if mine and frame:GetParent() ~= hidden then
		parents[frame] = frame:GetParent()
		frame:SetParent(hidden)
	elseif not mine and parents[frame] then
		frame:SetParent(parents[frame])
		parents[frame] = nil
	end
end

local function GameFrames()
	local frames = { _G.ContainerFrameCombinedBags }
	for index = 1, NUM_CONTAINER_FRAMES or 13 do frames[#frames + 1] = _G["ContainerFrame" .. index] end
	return frames
end

-- The game says one of your bags is open (all together, or one of them).
local function GameOpen()
	local combined = _G.ContainerFrameCombinedBags
	if combined and combined:IsShown() then return true end
	for _, bag in ipairs(Bags()) do
		if IsBagOpen and IsBagOpen(bag) then return true end
	end
	return false
end

-- The window follows the game's bags; the game's follow the window (while one moves the other, nothing
-- answers back).
local following = false
local function FollowGame()
	if following or not On() then return end
	following = true
	if not GameOpen() then
		bags.Close()
	elseif not bags.IsShown() then
		bags.Open()
	else
		bags.Soon()
	end
	following = false
end

function ns.GameBagsFollow(shown)
	if following or not On() or GameOpen() == shown then return end
	following = true
	if shown then
		if OpenAllBags then OpenAllBags() end
	elseif CloseAllBags then
		CloseAllBags()
	end
	following = false
end

local function FollowBags()
	for _, name in ipairs({ "ToggleAllBags", "OpenAllBags", "CloseAllBags", "ToggleBackpack", "OpenBackpack", "CloseBackpack",
		"ToggleBag", "OpenBag", "CloseBag" }) do
		if type(_G[name]) == "function" then hooksecurefunc(name, FollowGame) end
	end
	for _, frame in pairs(GameFrames()) do
		Tuck(frame)
		frame:HookScript("OnShow", Tuck)
	end
end

-- The option turned on or off: the game's frames tucked away or given back.
function ns.TuckGameBags()
	for _, frame in pairs(GameFrames()) do Tuck(frame) end
end

-- Init ---------------------------------------------------------------------------------------

function ns.Init()
	if not (W and W.RegisterExtension) then return end
	-- An older Wanderer: said once, nothing taken.
	if (W.API or 1) < 17 then return W.Print(L.NEEDS_WANDERER) end
	-- (a weight, what you play, your talents changed: the green arrows judged again at once)
	W.OnComparisonChanged(function() ns.RefreshAll() end)
	W.RegisterExtension({
		key = "bags",
		addon = ADDON,
		slash = "/wbags",
		title = L.TITLE,
		news = L.NEWS_LINES,
		defaults = { enabled = true, bank = true, toBank = true, layout = "categories", byProfession = true, columns = 10, iconSize = 36, itemLevel = true,
			upgrade = true, junk = true, others = true, outfitSection = true, boe = true, newInPlace = false },
		ranges = { ["bags.columns"] = { 6, 16, 1 }, ["bags.iconSize"] = { 28, 44, 2 } },
		refresh = function()
			ns.TuckGameBags()
			ns.CoverJunk()
			ns.RefreshAll()
		end,
		-- (as every page: the switch, the essentials (the bank's window weighs as much as the bags'), the sorting, the
		-- look, what is done for you)
		options = function(o)
			local enabled = o.Checkbox("bags", "enabled", L.ENABLE, L.ENABLE_DESC, ns.RefreshAll)
			-- (greyed while another bags addon has the bags, with its name)
			o.Yield(enabled, "bags")
			local isOn = o.IsOn("bags", "enabled")
			local function on() return isOn() and not Yielded() end
			local function Sub(widget) o.Under(widget, enabled, on) end
			local function Check(key, label, desc)
				local row = o.Checkbox("bags", key, label, desc, ns.RefreshAll)
				Sub(row)
				return row
			end
			Sub(o.Button(L.OPEN_LABEL, L.OPEN, nil, function()
				o.CloseSettings()
				if OpenAllBags then OpenAllBags() else bags.Open() end
			end))
			Check("bank", L.BANK, L.BANK_DESC)

			o.Header(L.SECTION_SORTING)
			Sub(o.Dropdown("BAGS_LAYOUT", L.LAYOUT, L.LAYOUT_DESC, "categories",
				{ { "categories", L.MODE_CATEGORIES }, { "bags", L.MODE_BAGS } },
				function() return ns.Settings() and ns.Settings().layout or "categories" end,
				function(value) if ns.Settings() then ns.Settings().layout = value; ns.RefreshAll() end end))
			Check("byProfession", L.BY_PROFESSION, L.BY_PROFESSION_DESC)
			Check("outfitSection", L.OUTFIT_SECTION, L.OUTFIT_SECTION_DESC)
			Check("newInPlace", L.NEW_IN_PLACE, L.NEW_IN_PLACE_DESC)

			o.Header(L.SECTION_LOOK)
			Sub(o.Slider("BAGS_COLUMNS", L.COLUMNS, "bags.columns", "%d", ns.RefreshAll))
			Sub(o.Slider("BAGS_ICON_SIZE", L.ICON_SIZE, "bags.iconSize", "%d", ns.RefreshAll))
			Check("itemLevel", L.ITEM_LEVEL, L.ITEM_LEVEL_DESC)
			Check("boe", L.BOE_OPTION, L.BOE_OPTION_DESC)
			-- (the green arrow is Wanderer's comparison: greyed while it is off, saying so)
			local upgrade = Check("upgrade", L.UPGRADE, L.UPGRADE_DESC)
			o.Needs(upgrade, function() return W.ComparisonOn() and true or false end, L.TOOLTIPS_UPGRADE)
			Check("junk", L.JUNK, L.JUNK_DESC)

			-- Over an item: your other characters (greyed, with its name, while another addon says it).
			o.Header(L.SECTION_OVER_ITEMS)
			local others = Check("others", L.OTHERS, L.OTHERS_DESC)
			o.Yield(others, "altCounts")

			-- (on: the mark itself is your choice; Shift held at the banker skips it once)
			o.Header(L.SECTION_AUTOMATIONS)
			Check("toBank", L.TO_BANK, L.TO_BANK_DESC)
		end,
	})
	SLASH_WANDERERBAGS1 = "/wbags"
	SlashCmdList.WANDERERBAGS = function()
		if bags.IsShown() then return bags.Close() end
		if On() then return bags.Open() end
		-- (never a silent key: another bags addon has them, or the window is off)
		if Yielded() then return W.Print(L.MSG_COMPAT_LEFT:format(W.Yields("bags"), L.COMPAT_JOB_BAGS)) end
		W.Print(L.EXT_TURNED_OFF:format(L.TITLE))
	end
	FollowBags()
	ns.InitMarks()
	ns.InitBank()
	ns.InitOthers()
	local events = CreateFrame("Frame")
	for _, event in ipairs({ "BAG_UPDATE_DELAYED", "ITEM_LOCK_CHANGED", "BAG_UPDATE_COOLDOWN", "PLAYER_MONEY",
		"QUEST_ACCEPTED", "MERCHANT_SHOW", "MERCHANT_CLOSED", "PLAYER_EQUIPMENT_CHANGED",
		"BAG_NEW_ITEMS_UPDATED", "BANK_TABS_CHANGED", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "EQUIPMENT_SETS_CHANGED" }) do
		pcall(events.RegisterEvent, events, event)
	end
	-- (your quest log only, not every unit's)
	if events.RegisterUnitEvent then pcall(events.RegisterUnitEvent, events, "UNIT_QUEST_LOG_CHANGED", "player") end
	-- An item the game has not told about yet: asked once; the windows drawn again when its data comes.
	local askedItems, hearing = {}, false
	function ns.AskItem(id)
		if askedItems[id] ~= nil then return end
		askedItems[id] = true
		U.LoadItem(id)
		if not hearing then
			hearing = true
			pcall(events.RegisterEvent, events, "GET_ITEM_INFO_RECEIVED")
		end
	end
	-- The small events touch only what they change; the others draw the windows again.
	local LIGHT = {
		BAG_UPDATE_COOLDOWN = function(inventory) inventory.Cooldowns() end,
		ITEM_LOCK_CHANGED = function(inventory, bag, slot) inventory.Lock(bag, slot) end,
		PLAYER_MONEY = function(inventory) inventory.Money() end,
	}
	events:SetScript("OnEvent", function(_, event, ...)
		if event == "AUCTION_HOUSE_SHOW" then
			ns.auctionOpen = true
			ns.SyncAuctionator()
		elseif event == "AUCTION_HOUSE_CLOSED" then ns.auctionOpen = false end
		if event == "GET_ITEM_INFO_RECEIVED" then
			local id, success = ...
			if not askedItems[id] then return end
			if success == false then askedItems[id] = false else askedItems[id] = nil end
			local pending = false
			for _, state in pairs(askedItems) do if state then pending = true end end
			if not pending then
				hearing = false
				pcall(events.UnregisterEvent, events, "GET_ITEM_INFO_RECEIVED")
			end
		end
		if event == "BAG_UPDATE_DELAYED" then ns.NoteCarriedSoon() end
		-- (the game's outfits changed: their pieces read again)
		if event == "EQUIPMENT_SETS_CHANGED" then return ns.OutfitsChanged() end
		local light = LIGHT[event]
		for _, inventory in ipairs(ns.INVENTORIES) do
			if light then light(inventory, ...) else inventory.Soon() end
		end
	end)
end

-- (an older Wanderer, without it: said once)
if W and W.WhenLoaded then W.WhenLoaded(ADDON, ns.Init) elseif W and W.Print then W.Print(L.NEEDS_WANDERER) end
