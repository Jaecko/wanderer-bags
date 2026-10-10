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

local function Bags()
	local list = {}
	for bag = 0, (NUM_BAG_SLOTS or 4) do list[#list + 1] = bag end
	-- The reagent bag, where the game has one.
	local reagent = Enum and Enum.BagIndex and Enum.BagIndex.ReagentBag
	if reagent and reagent > (NUM_BAG_SLOTS or 4) and ns.NumSlots(reagent) > 0 then
		list[#list + 1] = reagent
	end
	return list
end

local bags = ns.NewInventory({
	name = "WandererBags",
	title = L.TITLE,
	on = On,
	containers = Bags,
	nameOf = function(bag) return Clean(Safe(C_Container.GetBagName, bag)) or (BAG_NAME_BACKPACK or "Bag") end,
	point = { "BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -80, 120 },
	sounds = { "IG_BACKPACK_OPEN", "IG_BACKPACK_CLOSE" },
	actions = function(window, add)
		if C_Container and C_Container.SortBags then
			add(ns.TextButton(window, L.SORT, function() Safe(C_Container.SortBags) end, L.SORT_DESC))
		end
		-- Away from the banker: the bank as you left it.
		window.bank = ns.TextButton(window, L.BANK_TITLE, function() ns.ToggleSavedBank() end, L.BANK_SEEN_DESC)
		add(window.bank)
	end,
	onRefresh = function(window) window.bank:SetShown(ns.HasSavedBank()) end,
})
ns.Bags = bags

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
	W.RegisterExtension({
		key = "bags",
		title = L.TITLE,
		defaults = { enabled = true, bank = true, layout = "categories", columns = 10, iconSize = 36, itemLevel = true,
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
	if ns.InitBank then ns.InitBank() end
	local events = CreateFrame("Frame")
	for _, event in ipairs({ "BAG_UPDATE_DELAYED", "ITEM_LOCK_CHANGED", "BAG_UPDATE_COOLDOWN", "PLAYER_MONEY",
		"QUEST_ACCEPTED", "UNIT_QUEST_LOG_CHANGED", "MERCHANT_SHOW", "MERCHANT_CLOSED", "PLAYER_EQUIPMENT_CHANGED",
		"BAG_NEW_ITEMS_UPDATED", "BANK_TABS_CHANGED" }) do
		pcall(events.RegisterEvent, events, event)
	end
	events:SetScript("OnEvent", function()
		for _, inventory in ipairs(ns.INVENTORIES) do inventory.Soon() end
	end)
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, _, name)
	if name ~= ADDON then return end
	self:UnregisterEvent("ADDON_LOADED")
	ns.Init()
end)
