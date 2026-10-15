local ADDON, ns = ...
local L = ns.L

-- Your bags in Wanderer's window, in place of the game's: its keys, its bag
-- buttons, the merchant or the mailbox open this window while it is on.
-- Wanderer turned off, or this option: the game's bags, as they were.

local W = Wanderer
local U = W and W.Util
local Safe, Clean = U and U.Safe, U and U.Clean

local function On()
	local settings = ns.Settings()
	return settings and settings.enabled and true or false
end
ns.On = On

local function Bags() return U.BagIDs() end

local bags = ns.NewInventory({
	name = "WandererBags",
	title = L.TITLE,
	on = On,
	containers = Bags,
	nameOf = function(bag) return Clean(Safe(C_Container and C_Container.GetBagName, bag)) or (BAG_NAME_BACKPACK or "Bag") end,
	point = { "BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -80, 120 },
	sounds = { "IG_BACKPACK_OPEN", "IG_BACKPACK_CLOSE" },
	canSell = true,
	selectable = true,
	-- Read left to right: the bank, the sorting, how they are shown, the help (beside the cross).
	actions = function(window, add, mode)
		-- What can be done here, said once.
		local help = W.Skin.CreateLink(window, "?", nil, L.HELP_TIP)
		add(help)
		add(mode)
		if C_Container and C_Container.SortBags then
			add(W.Skin.CreateLink(window, L.SORT, function() Safe(C_Container.SortBags) end, L.SORT_DESC))
		end
		-- Away from the banker: the bank as you left it.
		window.bank = W.Skin.CreateLink(window, L.BANK_TITLE, function() ns.ToggleSavedBank() end, L.BANK_SEEN_DESC)
		add(window.bank)
		-- With Wanderer Auction: the shopping list, and how many items it still lacks.
		window.shop = W.Skin.CreateLink(window, L.SHOP_LINK, function()
			if type(WandererAuction) == "table" and WandererAuction.ToggleList then WandererAuction.ToggleList() end
		end, L.SHOP_LINK_DESC)
		add(window.shop)
	end,
	onRefresh = function(window)
		window.bank:SetShown(ns.HasSavedBank())
		ns.ShopLink(window)
	end,
})
ns.Bags = bags

-- The shopping list's link: shown with Wanderer Auction, its count of items still missing.
local shopWindow
function ns.ShopLink(window)
	shopWindow = window or shopWindow
	local link = shopWindow and shopWindow.shop
	if not link then return end
	local api = type(WandererAuction) == "table" and WandererAuction.ToggleList and WandererAuction or nil
	link:SetShown(api ~= nil)
	if not api then return end
	local lack = api.ShoppingLack and api.ShoppingLack() or 0
	link:SetLabel(lack > 0 and L.SHOP_LINK_COUNT:format(lack) or L.SHOP_LINK)
end

-- The list changed (Wanderer Auction says it): the link alone, the heading's links placed again.
function ns.ShopRefresh()
	if not (shopWindow and shopWindow:IsShown()) then return end
	ns.ShopLink()
	bags.ChainLinks()
end

-- Where an item may be sold (a merchant, the auction house): kept items are guarded there.
function ns.Guarding()
	return ns.auctionOpen or (W and W.IsMerchantOpen and W.IsMerchantOpen()) or false
end

-- The game's bags: Wanderer's window in their place --------------------------------------------

local original = {}

local function IsBag(id)
	id = tonumber(id)
	if not id then return false end
	for _, bag in ipairs(Bags()) do if bag == id then return true end end
	return false
end

-- A game function answered by the window while it is on (for one bag: only ours).
local function Take(name, replacement, oneBag)
	original[name] = _G[name]
	_G[name] = function(id, ...)
		if On() and (not oneBag or IsBag(id)) then return replacement() end
		if original[name] then return original[name](id, ...) end
	end
end

local function TakeBags()
	Take("ToggleAllBags", bags.Toggle)
	Take("OpenAllBags", bags.Open)
	Take("CloseAllBags", bags.Close)
	Take("ToggleBackpack", bags.Toggle)
	Take("OpenBackpack", bags.Open)
	Take("CloseBackpack", bags.Close)
	-- One bag asked: the window (another container stays the game's).
	Take("ToggleBag", bags.Toggle, true)
	Take("OpenBag", bags.Open, true)
	Take("CloseBag", bags.Close, true)
end

-- Init ---------------------------------------------------------------------------------------

function ns.Init()
	if not (W and W.RegisterExtension) then return end
	-- An older Wanderer: said once, nothing taken.
	if (W.API or 1) < 4 then return W.Print(L.NEEDS_WANDERER) end
	W.RegisterExtension({
		key = "bags",
		title = L.TITLE,
		defaults = { enabled = true, bank = true, layout = "categories", byProfession = true, columns = 10, iconSize = 36, itemLevel = true,
			upgrade = true, junk = true },
		ranges = { ["bags.columns"] = { 6, 16, 1 }, ["bags.iconSize"] = { 28, 44, 2 } },
		refresh = ns.RefreshAll,
		options = function(o)
			o.Header(L.TITLE)
			local enabled = o.Checkbox("bags", "enabled", L.ENABLE, L.ENABLE_DESC, ns.RefreshAll)
			local on = o.IsOn("bags", "enabled")
			local function Sub(widget) o.Under(widget, enabled, on) end
			local function Check(key, label, desc) Sub(o.Checkbox("bags", key, label, desc, ns.RefreshAll)) end
			Check("bank", L.BANK, L.BANK_DESC)
			Sub(o.Dropdown("BAGS_LAYOUT", L.LAYOUT, L.LAYOUT_DESC, "categories",
				{ { "categories", L.MODE_CATEGORIES }, { "bags", L.MODE_BAGS } },
				function() return ns.Settings() and ns.Settings().layout or "categories" end,
				function(value) if ns.Settings() then ns.Settings().layout = value; ns.RefreshAll() end end))
			Check("byProfession", L.BY_PROFESSION, L.BY_PROFESSION_DESC)
			Sub(o.Slider("BAGS_COLUMNS", L.COLUMNS, "bags.columns", "%d", ns.RefreshAll))
			Sub(o.Slider("BAGS_ICON_SIZE", L.ICON_SIZE, "bags.iconSize", "%d", ns.RefreshAll))
			Check("itemLevel", L.ITEM_LEVEL, L.ITEM_LEVEL_DESC)
			Check("upgrade", L.UPGRADE, L.UPGRADE_DESC)
			Check("junk", L.JUNK, L.JUNK_DESC)
			Sub(o.Button(L.OPEN, L.OPEN_BUTTON, nil, function()
				o.CloseSettings()
				bags.Open()
			end))
		end,
	})
	TakeBags()
	if ns.InitMarks then ns.InitMarks() end
	if ns.InitBank then ns.InitBank() end
	local events = CreateFrame("Frame")
	for _, event in ipairs({ "BAG_UPDATE_DELAYED", "ITEM_LOCK_CHANGED", "BAG_UPDATE_COOLDOWN", "PLAYER_MONEY",
		"QUEST_ACCEPTED", "MERCHANT_SHOW", "MERCHANT_CLOSED", "PLAYER_EQUIPMENT_CHANGED",
		"BAG_NEW_ITEMS_UPDATED", "BANK_TABS_CHANGED", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED" }) do
		pcall(events.RegisterEvent, events, event)
	end
	-- (your quest log only, not every unit's)
	if events.RegisterUnitEvent then pcall(events.RegisterUnitEvent, events, "UNIT_QUEST_LOG_CHANGED", "player") end
	-- The small events touch only what they change; the others draw the windows again.
	local LIGHT = {
		BAG_UPDATE_COOLDOWN = function(inventory) inventory.Cooldowns() end,
		ITEM_LOCK_CHANGED = function(inventory, bag, slot) inventory.Lock(bag, slot) end,
		PLAYER_MONEY = function(inventory) inventory.Money() end,
	}
	events:SetScript("OnEvent", function(_, event, ...)
		if event == "AUCTION_HOUSE_SHOW" then
			ns.auctionOpen = true
			if ns.SyncAuctionator then ns.SyncAuctionator() end
		elseif event == "AUCTION_HOUSE_CLOSED" then ns.auctionOpen = false end
		local light = LIGHT[event]
		for _, inventory in ipairs(ns.INVENTORIES) do
			if light then light(inventory, ...) else inventory.Soon() end
		end
	end)
end

-- (an older Wanderer, without it: said once)
if W and W.WhenLoaded then W.WhenLoaded(ADDON, ns.Init) elseif W and W.Print then W.Print(L.NEEDS_WANDERER) end
