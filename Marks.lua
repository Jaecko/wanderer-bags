local _, ns = ...
local L = ns.L

-- Your own say over your items, for the whole account: kept (never offered
-- for sale), for the auction house (never sold to a merchant, first in
-- Auctionator's selling list), junk (sold with the junk, whatever its color),
-- or put in a section of yours (kept too). Alt+click on an item opens the choices, a
-- right click on the title of one of your sections renames or removes it.

local W = Wanderer
local U = W and W.Util

local function DB()
	WandererBagsDB = WandererBagsDB or {}
	local db = WandererBagsDB
	db.marks = db.marks or {} -- item id -> "keep", "auction" or "junk"
	db.sections = db.sections or {} -- your sections' names, in their order
	db.placed = db.placed or {} -- item id -> the name of its section
	db.folded = db.folded or {} -- section key -> folded
	return db
end
ns.MarksDB = DB

function ns.Mark(id)
	return id and DB().marks[id] or nil
end

-- The section of yours an item is in (one removed since: none).
function ns.Placed(id)
	local name = id and DB().placed[id]
	if not name then return nil end
	for _, section in ipairs(DB().sections) do
		if section == name then return name end
	end
	return nil
end

function ns.IsKept(id)
	return ns.Mark(id) == "keep" or ns.Placed(id) ~= nil
end

function ns.IsForAuction(id)
	return ns.Mark(id) == "auction"
end

-- An item one of your quests asks you to carry (Wanderer reads the log): { quest, have, need } or nil.
function ns.QuestNeed(id)
	return id and W and W.QuestNeed and W.QuestNeed(id) or nil
end

-- With Wanderer Auction: its shopping list (how many you want to carry is asked there).
local function Shop()
	return type(WandererAuction) == "table" and WandererAuction.AskShopping and WandererAuction or nil
end
-- keep: always on you (the line stays, filled up at each merchant), else once.
local function ShopAsk(item, keep) Shop().AskShopping(item.id, keep) end

-- What the auction house was seen asking for an item: its price (copper) and how many days ago. Wanderer
-- Auction's memory first, else Auctionator's.
function ns.AuctionPrice(link)
	if type(WandererAuction) == "table" and WandererAuction.Price and link then
		local price, age = WandererAuction.Price(link)
		if price then return price, age end
	end
	local api = type(Auctionator) == "table" and Auctionator.API and Auctionator.API.v1
	if not (api and api.GetAuctionPriceByItemLink and link) then return nil end
	local ok, price = pcall(api.GetAuctionPriceByItemLink, "Wanderer Bags", link)
	if not (ok and type(price) == "number" and price > 0) then return nil end
	local _, age = pcall(api.GetAuctionAgeByItemLink, "Wanderer Bags", link)
	return price, type(age) == "number" and age or nil
end

-- Auctionator (an auction house addon) has its own list of items hidden from its selling tab: what you keep
-- in your bags is put there, and taken out once freed (only what Wanderer Bags put there).
function ns.SyncAuctionator()
	local groups = type(Auctionator) == "table" and Auctionator.Groups
	if not (groups and groups.HideItemLink and groups.UnhideItemLink and groups.GetHiddenItemLinks) then return end
	local db = DB()
	db.auctionator = db.auctionator or {} -- item id -> the link hidden there
	db.auctionatorFirst = db.auctionatorFirst or {} -- item id -> the link put first there
	local hidden = {}
	for _, link in ipairs(groups.GetHiddenItemLinks() or {}) do hidden[link] = true end
	-- For the auction house: in Auctionator's first group, shown first when selling.
	local first = groups.GetGroupNameByIndex and groups.GetGroupNameByIndex(1)
	local ok, list = pcall(groups.GetGroupList, first)
	if not (first and ok and type(list) == "table") then list = nil end
	local changed = false
	local function Remove(link)
		for index = #list, 1, -1 do
			if list[index] == link then table.remove(list, index) changed = true end
		end
	end
	-- Freed: shown again, out of the first group.
	for id, link in pairs(db.auctionator) do
		if not ns.IsKept(id) then
			if hidden[link] then pcall(groups.UnhideItemLink, link) end
			db.auctionator[id] = nil
		end
	end
	if list then
		for id, link in pairs(db.auctionatorFirst) do
			if not ns.IsForAuction(id) then
				Remove(link)
				db.auctionatorFirst[id] = nil
			end
		end
	end
	-- Your bags: what you keep hidden, what is for the auction house first.
	U.EachBagItem(function(_, _, info)
		local id = U.Clean(info.itemID)
		local link = U.Clean(info.hyperlink)
		if link and ns.IsKept(id) and not hidden[db.auctionator[id] or link] then
			pcall(groups.HideItemLink, link)
			db.auctionator[id], hidden[link] = link, true
		elseif link and list and ns.IsForAuction(id) and not db.auctionatorFirst[id] then
			table.insert(list, link)
			db.auctionatorFirst[id], changed = link, true
		end
	end)
	local registry = groups.CallbackRegistry
	if changed and registry and registry.TriggerEvent then pcall(registry.TriggerEvent, registry, "Customise.EditMade") end
end

-- Your say changed: the windows drawn again, Auctionator told.
local function Changed()
	if ns.auctionOpen then ns.SyncAuctionator() end
	ns.RefreshAll()
end

-- Kept, for the auction house and junk exclude each other; the last two leave your section.
local function SetMark(id, mark)
	local db = DB()
	db.marks[id] = db.marks[id] ~= mark and mark or nil
	if db.marks[id] == "junk" or db.marks[id] == "auction" then db.placed[id] = nil end
	Changed()
end

local function Place(id, name)
	local db = DB()
	db.placed[id] = name
	if name and (db.marks[id] == "junk" or db.marks[id] == "auction") then db.marks[id] = nil end
	Changed()
end

-- Several items at once (the bags' selection): a mark set on all of them, or taken off when all have it.
function ns.MarkMany(ids, mark)
	local db = DB()
	local all = ids[1] ~= nil
	for _, id in ipairs(ids) do
		if db.marks[id] ~= mark then all = false end
	end
	for _, id in ipairs(ids) do
		db.marks[id] = not all and mark or nil
		if mark ~= "keep" and not all then db.placed[id] = nil end
	end
	Changed()
end

-- Put in one of your sections (nil: taken out).
function ns.PlaceMany(ids, name)
	local db = DB()
	for _, id in ipairs(ids) do
		db.placed[id] = name
		if name and (db.marks[id] == "junk" or db.marks[id] == "auction") then db.marks[id] = nil end
	end
	Changed()
end

-- Freed: no mark, no section of yours (back where its kind puts it).
function ns.FreeMany(ids)
	local db = DB()
	for _, id in ipairs(ids) do db.marks[id], db.placed[id] = nil, nil end
	Changed()
end

local function Exists(name)
	for _, section in ipairs(DB().sections) do
		if section:lower() == name:lower() then return true end
	end
	return false
end

-- A new section (an item put in it at once, when one was chosen). The name comes trimmed from AskText.
local function AddSection(name, id)
	if name == "" or Exists(name) then return end
	table.insert(DB().sections, name)
	if type(id) == "table" then
		ns.PlaceMany(id, name)
	elseif id then
		Place(id, name)
	else
		Changed()
	end
end

local function RenameSection(old, new)
	if new == "" or new == old or Exists(new) then return end
	local db = DB()
	for index, section in ipairs(db.sections) do
		if section == old then db.sections[index] = new end
	end
	for id, name in pairs(db.placed) do
		if name == old then db.placed[id] = new end
	end
	db.folded[ns.CUSTOM .. new], db.folded[ns.CUSTOM .. old] = db.folded[ns.CUSTOM .. old], nil
	Changed()
end

-- Removed: its items go back where they would be.
local function RemoveSection(old)
	local db = DB()
	for index = #db.sections, 1, -1 do
		if db.sections[index] == old then table.remove(db.sections, index) end
	end
	for id, name in pairs(db.placed) do
		if name == old then db.placed[id] = nil end
	end
	db.folded[ns.CUSTOM .. old] = nil
	Changed()
end

-- A section folded to its title, or open.
function ns.IsFolded(key) return DB().folded[key] and true or false end
function ns.ToggleFolded(key)
	local db = DB()
	db.folded[key] = not db.folded[key] or nil
	if U then U.PlaySound("IG_MAINMENU_OPTION_CHECKBOX_ON") end
	ns.RefreshAll()
end

-- The questions: a name to give (a new section, a section renamed), a section to remove, the junk sold.
local function NewSection(id)
	W.Skin.AskText(L.SECTION_NEW_PROMPT, "", function(text) AddSection(text, id) end)
end
local function RenameSectionAsk(name)
	W.Skin.AskText(L.SECTION_RENAME_PROMPT, name, function(text) RenameSection(name, text) end)
end
local function RemoveSectionAsk(name)
	W.Skin.Ask(L.SECTION_REMOVE_CONFIRM:format(name), function() RemoveSection(name) end)
end

-- Alt+click on an item: kept, for the auction house, junk, its section (once, however the click came).
local lastMenu = 0
function ns.ItemMenu(owner, item)
	local id = item and item.id
	if not id or GetTime() - lastMenu < 0.3 then return end
	lastMenu = GetTime()
	local shown = U.Menu(owner, function(_, root)
		root:CreateTitle(item.name ~= "" and item.name or L.TITLE)
		root:CreateCheckbox(L.MARK_KEEP, function() return ns.Mark(id) == "keep" end, function() SetMark(id, "keep") end)
		root:CreateCheckbox(L.MARK_AUCTION, function() return ns.Mark(id) == "auction" end, function() SetMark(id, "auction") end)
		root:CreateCheckbox(L.MARK_JUNK, function() return ns.Mark(id) == "junk" end, function() SetMark(id, "junk") end)
		root:CreateDivider()
		local sections = root:CreateButton(L.MARK_SECTION)
		for _, name in ipairs(DB().sections) do
			sections:CreateRadio(name, function() return ns.Placed(id) == name end, function() Place(id, name) end)
		end
		if DB().sections[1] then sections:CreateDivider() end
		sections:CreateButton(L.SECTION_NEW, function() NewSection(id) end)
		if ns.Placed(id) then
			root:CreateButton(L.SECTION_LEAVE, function() Place(id, nil) end)
		end
		-- With Wanderer Auction: to the shopping list (how many you want to carry), or off it.
		local shop = Shop()
		if shop then
			root:CreateDivider()
			root:CreateButton(L.SHOP_ADD, function() ShopAsk(item, false) end)
			root:CreateButton(L.SHOP_KEEP, function() ShopAsk(item, true) end)
			if shop.InShopping and shop.InShopping(id) and shop.RemoveFromShopping then
				root:CreateButton(L.SHOP_REMOVE, function() shop.RemoveFromShopping(id) end)
			end
		end
		-- At the auction house, with Wanderer Auction: its offers, searched at once.
		local frame = _G.AuctionHouseFrame
		if type(WandererAuction) == "table" and WandererAuction.Search and frame and frame:IsShown() and item.name ~= "" then
			root:CreateDivider()
			root:CreateButton(L.SEARCH_AUCTION, function() WandererAuction.Search(item.name) end)
		end
	end)
	if not shown then W.Print("Wanderer Bags: menus are missing in this client.") end
end

-- The selection's "Section": one of yours, a new one, or out of theirs (then done(), the selection cleared).
function ns.SectionsMenu(owner, ids, done)
	U.Menu(owner, function(_, root)
		root:CreateTitle(L.MARK_SECTION)
		for _, name in ipairs(DB().sections) do
			root:CreateButton(name, function() ns.PlaceMany(ids, name) done() end)
		end
		if DB().sections[1] then root:CreateDivider() end
		root:CreateButton(L.SECTION_NEW, function() NewSection(ids) done() end)
		root:CreateButton(L.SECTION_LEAVE, function() ns.PlaceMany(ids, nil) done() end)
	end)
end

-- A right click on the title of one of your sections.
function ns.SectionMenu(owner, name)
	U.Menu(owner, function(_, root)
		root:CreateTitle(name)
		root:CreateButton(L.SECTION_RENAME, function() RenameSectionAsk(name) end)
		root:CreateButton(L.SECTION_REMOVE, function() RemoveSectionAsk(name) end)
	end)
end

-- The game's "Sell all junk" button, while the bags are Wanderer's: the same, without what you keep.
local function TakeSellAllJunk()
	local button = _G.MerchantSellAllJunkButton
	if not (button and W.SellItems) then return end
	local original = button:GetScript("OnClick")
	button:SetScript("OnClick", function(...)
		if ns.On and ns.On() then return W.Skin.Ask(SELL_ALL_JUNK_ITEMS_POPUP or L.SELL, function() W.SellItems(W.FindJunk()) end) end
		if original then return original(...) end
	end)
end

function ns.InitMarks()
	-- For Wanderer Auction: what you keep, what you set aside for the auction house.
	WandererBagsMarks = { IsKept = ns.IsKept, IsForAuction = ns.IsForAuction, AuctionPrice = ns.AuctionPrice,
		Refresh = function() if ns.ShopRefresh then ns.ShopRefresh() end end }
	-- Your quests' items read again when the log changes: the marks with them.
	local quests = CreateFrame("Frame")
	pcall(quests.RegisterEvent, quests, "QUEST_LOG_UPDATE")
	quests:SetScript("OnEvent", U.Debounce(1, function() if ns.RefreshAll then ns.RefreshAll() end end))
	TakeSellAllJunk()
	-- The game's own modified click on an item also says it: Alt over one of our squares opens the menu.
	if hooksecurefunc and HandleModifiedItemClick then
		hooksecurefunc("HandleModifiedItemClick", function()
			if not IsAltKeyDown() then return end
			local focus = U.MouseFocus()
			if type(focus) == "table" and focus.wandererItem then ns.ItemMenu(focus, focus.wandererItem) end
		end)
	end
	-- Wanderer's sale of the junk at merchants follows these marks.
	if not (W and W.AddJunkRule) then return end
	W.AddJunkRule(function(id)
		if not (ns.On and ns.On()) then return nil end
		if ns.IsKept(id) or ns.IsForAuction(id) then return false end
		if ns.Mark(id) == "junk" then return true end
		return nil
	end)
end
