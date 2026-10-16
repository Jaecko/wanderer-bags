local ADDON, ns = ...
local L = ns.L

-- Your bags in Wanderer's window, in place of the game's: its keys, its bag
-- buttons, the merchant or the mailbox open this window while it is on.
-- Nothing of the game's is replaced: it opens and closes its own bags as
-- always, this window follows them, and the game's frames for your bags are
-- kept out of sight. Wanderer turned off, or this option: the game's bags,
-- as they were.

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
			add(ns.Action(window, L.SORT, function() Safe(C_Container.SortBags) end, L.SORT_DESC))
		end
		-- Away from the banker: the bank as you left it.
		window.bank = ns.Action(window, L.BANK_TITLE, function() ns.ToggleSavedBank() end, L.BANK_SEEN_DESC)
		add(window.bank)
		-- With Wanderer Auction: the shopping list, and how many items it still lacks.
		window.shop = ns.Action(window, L.SHOP_LINK, function()
			if type(WandererAuction) == "table" and WandererAuction.ToggleList then WandererAuction.ToggleList() end
		end, L.SHOP_LINK_DESC)
		add(window.shop)
	end,
	onRefresh = function(window)
		window.bank:SetShown(ns.HasSavedBank())
		ns.ShopLink(window)
	end,
	-- Opened or closed by itself (a link, its cross, Escape): the game's bags with it.
	onShow = function() if ns.GameBagsFollow then ns.GameBagsFollow(true) end end,
	onHide = function() if ns.GameBagsFollow then ns.GameBagsFollow(false) end end,
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
	if GameOpen() then bags.Open() else bags.Close() end
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
	if (W.API or 1) < 6 then return W.Print(L.NEEDS_WANDERER) end
	-- (a weight, what you play, your talents changed: the green arrows judged again at once)
	if W.OnComparisonChanged then W.OnComparisonChanged(function() if ns.RefreshAll then ns.RefreshAll() end end) end
	W.RegisterExtension({
		key = "bags",
		addon = ADDON,
		title = L.TITLE,
		news = L.NEWS_LINES,
		defaults = { enabled = true, bank = true, layout = "categories", byProfession = true, columns = 10, iconSize = 36, itemLevel = true,
			upgrade = true, junk = true },
		ranges = { ["bags.columns"] = { 6, 16, 1 }, ["bags.iconSize"] = { 28, 44, 2 } },
		refresh = function()
			ns.TuckGameBags()
			ns.RefreshAll()
		end,
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
			Sub(o.Button(L.OPEN_LABEL, L.OPEN, nil, function()
				o.CloseSettings()
				if OpenAllBags then OpenAllBags() else bags.Open() end
			end))
		end,
	})
	FollowBags()
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
