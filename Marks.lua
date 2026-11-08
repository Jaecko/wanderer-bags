local _, ns = ...
local L = ns.L

-- Your own say over your items, for each character (each one its own): kept (never offered
-- for sale), for the auction house (never sold to a merchant, first in
-- Auctionator's selling list), junk (sold with the junk, whatever its color),
-- for the bank (put in it at your next visit, never sold), or put in a section
-- of yours (never sold to a merchant). Alt+click on an item opens a small card of choices beside it, a
-- right click on the title of one of your sections renames or removes it.

local W = Wanderer
local U = W and W.Util

-- This character's choices. Its first time: the choices made before they were each character's (once
-- shared by the whole account) as its start, then its own. Found once, read again when the saved table or the
-- character is another (no protected call each time: an item's marks are read many times a drawing).
local cached -- { root, choices, guid, db }
local function DB()
	local root = WandererBagsDB
	local guid = UnitGUID and U.Clean(UnitGUID("player"))
	if cached and cached.root == root and root and root.choices == cached.choices and cached.guid == guid then return cached.db end
	WandererBagsDB = WandererBagsDB or {}
	root = WandererBagsDB
	root.choices = type(root.choices) == "table" and root.choices or {}
	local who = U.Clean(U.Safe(UnitGUID, "player"))
	local db = who and root.choices[who]
	if not db then
		-- (the old shared choices, a month long after the first character took them)
		local now = time()
		root.sharedUntil = root.sharedUntil or now + 30 * 86400
		local seed = now <= root.sharedUntil and root or {}
		-- (each table copied, for a character's own start)
		db = {}
		for _, name in ipairs({ "marks", "sections", "placed", "folded", "auctionator", "auctionatorFirst" }) do
			db[name] = type(seed[name]) == "table" and U.Copy(seed[name]) or {}
		end
		-- (the character not known yet, at the very start: a passing copy, nothing kept)
		if who then root.choices[who] = db end
	end
	db.marks = db.marks or {} -- item id -> "keep", "auction", "junk" or "bank"
	db.sections = db.sections or {} -- your sections' names, in their order
	db.placed = db.placed or {} -- item id -> the name of its section
	db.folded = db.folded or {} -- section key -> folded
	db.order = type(db.order) == "table" and db.order or {} -- "bags" or "bank" -> section keys in your order
	db.pinned = type(db.pinned) == "table" and db.pinned or {} -- "bags" or "bank" -> section keys at the top, in order
	-- (kept only once the character is known: a passing copy is read again)
	cached = who and root.choices[who] == db and { root = root, choices = root.choices, guid = guid, db = db } or nil
	return db
end
ns.MarksDB = DB

function ns.Mark(id)
	return id and DB().marks[id] or nil
end

-- Your sections' names as a set, made again when the list is another table or changed (Changed below).
local sectionSet, sectionSetOf
local function SectionSet(db)
	if sectionSetOf ~= db.sections or not sectionSet then
		sectionSet, sectionSetOf = {}, db.sections
		for _, section in ipairs(db.sections) do sectionSet[section] = true end
	end
	return sectionSet
end

-- The section of yours an item is in (one removed since: none).
function ns.Placed(id)
	local db = DB()
	local name = id and db.placed[id]
	if not name then return nil end
	return SectionSet(db)[name] and name or nil
end

function ns.IsKept(id)
	return ns.Mark(id) == "keep" or ns.Placed(id) ~= nil
end

function ns.IsForAuction(id)
	return ns.Mark(id) == "auction"
end

-- For the bank: put in it at the next visit (Bank.lua); the mark stays on the item's kind.
function ns.IsForBank(id)
	return ns.Mark(id) == "bank"
end

-- A section of the bags that always goes into the bank at the banker (your choice, each section its own, off by
-- default): with what is marked for it (Shift held as the banker opens skips both). Not what just came, what is
-- for the bank already, the junk, nor a bag of the "by bag" arrangement.
local NOT_TO_BANK = { new = true, bank = true, junk = true, free = true }
function ns.CanSendSection(key)
	return type(key) == "string" and not NOT_TO_BANK[key] and key:find("bag:", 1, true) ~= 1
end
local function ToBankDB()
	local db = DB()
	db.toBank = type(db.toBank) == "table" and db.toBank or {}
	return db.toBank
end
function ns.SectionToBank(key) return key ~= nil and ns.CanSendSection(key) and ToBankDB()[key] == true or false end
function ns.AnySectionToBank() return next(ToBankDB()) ~= nil end
function ns.ToggleSectionToBank(key)
	if not ns.CanSendSection(key) then return end
	local list = ToBankDB()
	list[key] = not list[key] or nil
	ns.RefreshAll()
end

-- An item one of your quests asks you to carry (Wanderer reads the log): { quest, have, need } or nil.
function ns.QuestNeed(id)
	return id and W.QuestNeed(id) or nil
end

-- Never sold, whatever the bags' window: kept (or in a section of yours), for the auction house or the bank, asked
-- for by a quest, an outfit's piece. The one rule of the sale, the junk and the cheapest list.
function ns.NeverSold(id)
	if not id then return false end
	return ns.IsKept(id) or ns.IsForAuction(id) or ns.IsForBank(id) or ns.QuestNeed(id) ~= nil or ns.InOutfit(id) ~= nil
end

-- Not offered at the auction house: kept, or an outfit's piece (an item in a section of yours may be posted there).
-- The rule of the bags' squares there, of Auctionator's hidden list and of Wanderer Auction's Sell list.
function ns.AuctionGuarded(id)
	return id ~= nil and (ns.Mark(id) == "keep" or ns.InOutfit(id) ~= nil)
end

-- With Wanderer Auction: its shopping list (how many you want to carry is asked there).
local function Shop()
	local api = ns.Auction()
	return api and api.AskShopping and api or nil
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

-- Auctionator (an auction house addon) has its own list of items hidden from its selling tab: what is not offered
-- at the auction house (ns.AuctionGuarded) is put there, and taken out once freed (only what Wanderer Bags put there). Every call into it
-- guarded: a change of Auctionator never breaks the bags.
local function SyncAuctionator()
	local groups = type(Auctionator) == "table" and Auctionator.Groups
	if not (groups and groups.HideItemLink and groups.UnhideItemLink and groups.GetHiddenItemLinks) then return end
	local db = DB()
	db.auctionator = db.auctionator or {} -- item id -> the link hidden there
	db.auctionatorFirst = db.auctionatorFirst or {} -- item id -> the link put first there
	local hidden = {}
	local okHidden, links = pcall(groups.GetHiddenItemLinks)
	for _, link in ipairs(okHidden and type(links) == "table" and links or {}) do hidden[link] = true end
	-- For the auction house: in Auctionator's first group, shown first when selling.
	local okFirst, first = false, nil
	if groups.GetGroupNameByIndex then okFirst, first = pcall(groups.GetGroupNameByIndex, 1) end
	if not okFirst then first = nil end
	local ok, list = false, nil
	if first and groups.GetGroupList then ok, list = pcall(groups.GetGroupList, first) end
	if not (first and ok and type(list) == "table") then list = nil end
	local changed = false
	local function Remove(link)
		for index = #list, 1, -1 do
			if list[index] == link then table.remove(list, index) changed = true end
		end
	end
	-- Freed: shown again, out of the first group.
	for id, link in pairs(db.auctionator) do
		if not ns.AuctionGuarded(id) then
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
	-- Your bags: what you keep hidden (a guard: always), what is for the auction house first (while the bags are on).
	local putFirst = list and ns.On()
	U.EachBagItem(function(_, _, info)
		local id = U.Clean(info.itemID)
		local link = U.Clean(info.hyperlink)
		if link and ns.AuctionGuarded(id) and not hidden[db.auctionator[id] or link] then
			pcall(groups.HideItemLink, link)
			db.auctionator[id], hidden[link] = link, true
		elseif link and putFirst and ns.IsForAuction(id) and not db.auctionatorFirst[id] then
			table.insert(list, link)
			db.auctionatorFirst[id], changed = link, true
		end
	end)
	local registry = groups.CallbackRegistry
	if changed and registry and registry.TriggerEvent then pcall(registry.TriggerEvent, registry, "Customise.EditMade") end
end
function ns.SyncAuctionator() pcall(SyncAuctionator) end

-- Your say changed: the windows drawn again, Auctionator told.
local function Changed()
	sectionSet = nil
	if ns.auctionOpen then ns.SyncAuctionator() end
	ns.RefreshAll()
end

-- Kept, for the auction house, junk and for the bank exclude each other; junk and the auction house leave your
-- section (what goes to the bank stays in it).
local function Apply(db, id, mark)
	db.marks[id] = mark
	if mark == "junk" or mark == "auction" then db.placed[id] = nil end
end

-- One item given this mark (nil: none), never toggled (the Alt+click card says which one it ends with).
local function SetMarkTo(id, mark)
	Apply(DB(), id, mark)
	Changed()
end

local function Place(id, name) ns.PlaceMany({ id }, name) end

-- Several items at once (the bags' selection): a mark set on all of them, or taken off when all have it.
function ns.MarkMany(ids, mark)
	local db = DB()
	local all = ids[1] ~= nil
	for _, id in ipairs(ids) do
		if db.marks[id] ~= mark then all = false end
	end
	for _, id in ipairs(ids) do Apply(db, id, not all and mark or nil) end
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
	if Exists(name) then return end
	table.insert(DB().sections, name)
	if type(id) == "table" then
		ns.PlaceMany(id, name)
	elseif id then
		Place(id, name)
	else
		Changed()
	end
end

-- A section folded in the bags, or in the bank (its own keys: this, then the section's).
ns.BANK_FOLD = "bank:"
local FOLD_PREFIXES = { "", ns.BANK_FOLD }

local function RenameSection(old, new)
	if new == "" or new == old or Exists(new) then return end
	local db = DB()
	for index, section in ipairs(db.sections) do
		if section == old then db.sections[index] = new end
	end
	for id, name in pairs(db.placed) do
		if name == old then db.placed[id] = new end
	end
	for _, prefix in ipairs(FOLD_PREFIXES) do
		db.folded[prefix .. ns.CUSTOM .. new], db.folded[prefix .. ns.CUSTOM .. old] = db.folded[prefix .. ns.CUSTOM .. old], nil
	end
	local toBank = ToBankDB()
	toBank[ns.CUSTOM .. new], toBank[ns.CUSTOM .. old] = toBank[ns.CUSTOM .. old], nil
	-- (its place in your order kept under its new name)
	for _, lists in ipairs({ db.order, db.pinned }) do
		for _, list in pairs(lists) do
			for index, key in ipairs(list) do
				if key == ns.CUSTOM .. old then list[index] = ns.CUSTOM .. new end
			end
		end
	end
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
	for _, prefix in ipairs(FOLD_PREFIXES) do db.folded[prefix .. ns.CUSTOM .. old] = nil end
	ToBankDB()[ns.CUSTOM .. old] = nil
	for _, lists in ipairs({ db.order, db.pinned }) do
		for _, list in pairs(lists) do
			for index = #list, 1, -1 do
				if list[index] == ns.CUSTOM .. old then table.remove(list, index) end
			end
		end
	end
	Changed()
end

-- A section folded to its title, or open.
function ns.IsFolded(key) return DB().folded[key] and true or false end
function ns.ToggleFolded(key)
	local db = DB()
	db.folded[key] = not db.folded[key] or nil
	W.Skin.Play("click")
	ns.RefreshAll()
end

-- The questions: a name to give (a new section, a section renamed), a section to remove.
local function NewSection(id)
	W.Skin.AskText(L.SECTION_NEW_PROMPT, "", function(text) AddSection(text, id) end)
end
local function RenameSectionAsk(name)
	W.Skin.AskText(L.SECTION_RENAME_PROMPT, name, function(text) RenameSection(name, text) end)
end
local function RemoveSectionAsk(name)
	W.Skin.Ask(L.SECTION_REMOVE_CONFIRM:format(name), function() RemoveSection(name) end)
end

-- Your order of the sections ----------------------------------------------------------------------------------
-- Each window its own ("bags" or "bank"): the sections you pinned first, in the order pinned, then the others
-- in your order; a section never moved keeps its place after the one it followed by default.

local function Orders(where)
	local db = DB()
	db.order[where] = type(db.order[where]) == "table" and db.order[where] or {}
	db.pinned[where] = type(db.pinned[where]) == "table" and db.pinned[where] or {}
	return db.order[where], db.pinned[where]
end

local function IndexOf(list, key)
	for index, value in ipairs(list) do
		if value == key then return index end
	end
end

function ns.IsPinned(where, key) return IndexOf(select(2, Orders(where)), key) ~= nil end

-- The sections (keys, in their order by default) in your order.
function ns.ArrangeSections(where, keys)
	local order, pinned = Orders(where)
	local rank, weight, place = {}, {}, {}
	for index, key in ipairs(order) do rank[key] = index end
	local last, step = 0, 0
	for index, key in ipairs(keys) do
		place[key] = index
		if rank[key] then
			last, step = rank[key], 0
			weight[key] = last
		else
			step = step + 1
			weight[key] = last + step / 1000
		end
	end
	local rest, top = {}, {}
	for _, key in ipairs(keys) do
		if IndexOf(pinned, key) then top[#top + 1] = key else rest[#rest + 1] = key end
	end
	table.sort(top, function(a, b) return IndexOf(pinned, a) < IndexOf(pinned, b) end)
	table.sort(rest, function(a, b)
		if weight[a] ~= weight[b] then return weight[a] < weight[b] end
		return place[a] < place[b]
	end)
	for _, key in ipairs(rest) do top[#top + 1] = key end
	return top
end

-- A new order (seq) kept, the sections not shown now left where they were among the others.
local function Merge(seq, old)
	local result, has = {}, {}
	for _, key in ipairs(seq) do result[#result + 1], has[key] = key, true end
	local previous
	for _, key in ipairs(old) do
		if not has[key] then
			local at = previous and IndexOf(result, previous) or 0
			table.insert(result, at + 1, key)
			has[key] = true
		end
		previous = key
	end
	return result
end

-- Pinned at the top, or not any more.
function ns.PinSection(where, key)
	local _, pinned = Orders(where)
	local index = IndexOf(pinned, key)
	if index then table.remove(pinned, index) else pinned[#pinned + 1] = key end
	ns.RefreshAll()
end

-- One place up (delta -1) or down (1) among the sections shown (shown: their keys, in order), within the
-- pinned ones or within the others. Returns true when it moved.
function ns.MoveSection(where, key, delta, shown)
	local order, pinned = Orders(where)
	local isPinned = IndexOf(pinned, key) ~= nil
	local group = {}
	for _, other in ipairs(shown or {}) do
		if (IndexOf(pinned, other) ~= nil) == isPinned then group[#group + 1] = other end
	end
	local from = IndexOf(group, key)
	local to = from and from + delta
	if not (to and group[to]) then return false end
	group[from], group[to] = group[to], group[from]
	local db = DB()
	if isPinned then db.pinned[where] = Merge(group, pinned) else db.order[where] = Merge(group, order) end
	ns.RefreshAll()
	return true
end

-- Whether it can move one place that way (the first can not go up...).
function ns.CanMoveSection(where, key, delta, shown)
	local _, pinned = Orders(where)
	local isPinned = IndexOf(pinned, key) ~= nil
	local group = {}
	for _, other in ipairs(shown or {}) do
		if (IndexOf(pinned, other) ~= nil) == isPinned then group[#group + 1] = other end
	end
	local from = IndexOf(group, key)
	return from ~= nil and group[from + delta] ~= nil
end

-- Your outfits ----------------------------------------------------------------------------------------------------
-- Their pieces are never sold (as BetterBags does: an outfit's piece is not junk), and gather in their own section
-- (an option). Read from Wanderer Outfits when it is there (the game's sets and its own), else from the game's
-- equipment manager; once, again when the outfits change.

local outfits -- item id -> { outfit names }

local function ReadOutfits()
	local pieces = {}
	local api = type(WandererOutfits) == "table" and WandererOutfits.Pieces
	if type(api) == "function" then
		local ok, list = pcall(api)
		if ok and type(list) == "table" then return list end
	end
	local sets = C_EquipmentSet
	if not (sets and sets.GetEquipmentSetIDs and sets.GetEquipmentSetInfo and sets.GetItemIDs) then return pieces end
	for _, set in ipairs(U.Safe(sets.GetEquipmentSetIDs) or {}) do
		local name = U.Clean(U.Safe(sets.GetEquipmentSetInfo, set))
		local ids = U.Safe(sets.GetItemIDs, set)
		for _, id in pairs(type(ids) == "table" and ids or {}) do
			id = U.Clean(id)
			if name and type(id) == "number" and id > 0 then
				pieces[id] = pieces[id] or {}
				if not IndexOf(pieces[id], name) then table.insert(pieces[id], name) end
			end
		end
	end
	return pieces
end

-- The outfits an item belongs to ({ names }), nil when none.
function ns.InOutfit(id)
	if not id then return nil end
	outfits = outfits or ReadOutfits()
	local names = outfits[id]
	return type(names) == "table" and names[1] and names or nil
end

-- The outfits changed: read again at the next look, the windows drawn again.
function ns.OutfitsChanged()
	outfits = nil
	ns.RefreshAll()
end

-- Alt+click on an item: a small card beside it ------------------------------------------------------------
-- Its square and its name (in its quality's color), what it is marked now; five large tiles (keep, the auction
-- house, junk, the bank, none), the one now in gold, a sentence under the mouse, keys 1 to 5; then the rest in a
-- quiet list (a section of yours, chosen inside the card; the shopping list; the auction house's offers).

local TILES = {
	{ mark = "keep", label = "MARK_TILE_KEEP", tip = "MARK_KEEP_TIP" },
	{ mark = "auction", label = "MARK_TILE_AUCTION", tip = "MARK_AUCTION_TIP" },
	{ mark = "junk", label = "MARK_TILE_JUNK", tip = "MARK_JUNK_TIP" },
	{ mark = "bank", label = "MARK_TILE_BANK", tip = "MARK_BANK_TIP" },
	{ mark = false, label = "MARK_TILE_NONE", tip = "MARK_NONE_TIP" },
}
ns.MARK_TILES = TILES
-- (the game's junk coin, as on the squares; an older game: its loot roll's coin)
local JUNK_ATLAS, JUNK_FILE = "bags-junkcoin", "Interface\\Buttons\\UI-GroupLoot-Coin-Up"

local card -- the Alt+click card, made at its first use
local lastMenu = 0

-- Each tile's sign: the very one its mark puts in a square's corner (none: Wanderer's cross).
local function MarkSign(mark)
	if not mark then return { glyph = "close" } end
	if mark == "junk" then return { atlas = JUNK_ATLAS, file = JUNK_FILE } end
	return { file = (ns.MARK_SIGNS or {})[mark] }
end

-- What the card's list offers: the item's other choices, or (inSections) the sections to put it in.
local function Entries(item, inSections)
	local id, list = item.id, {}
	local function Close(fn) return function() card:Hide() fn() end end
	if inSections then
		list[1] = { text = L.MARK_SECTION, back = true, run = function() card.inSections = false ns.FillCard() end }
		for _, name in ipairs(DB().sections) do
			list[#list + 1] = { text = name, checked = ns.Placed(id) == name, run = Close(function() Place(id, name) end) }
		end
		list[#list + 1] = { text = L.SECTION_NEW, sign = "plus", run = Close(function() NewSection(id) end) }
		return list
	end
	if DB().sections[1] then
		list[#list + 1] = { text = L.MARK_SECTION, sign = "chevron", run = function() card.inSections = true ns.FillCard() end }
	end
	list[#list + 1] = { text = L.SECTION_NEW, sign = "plus", run = Close(function() NewSection(id) end) }
	if ns.Placed(id) then
		list[#list + 1] = { text = L.SECTION_LEAVE, run = Close(function() Place(id, nil) end) }
	end
	-- With Wanderer Auction: to the shopping list (how many you want to carry), or off it.
	local shop = Shop()
	if shop then
		list[#list + 1] = { text = L.SHOP_ADD, run = Close(function() ShopAsk(item, false) end) }
		list[#list + 1] = { text = L.SHOP_KEEP, run = Close(function() ShopAsk(item, true) end) }
		if shop.InShopping and shop.InShopping(id) and shop.RemoveFromShopping then
			list[#list + 1] = { text = L.SHOP_REMOVE, run = Close(function() shop.RemoveFromShopping(id) end) }
		end
	end
	-- At the auction house, with Wanderer Auction: its offers, searched at once.
	local frame = _G.AuctionHouseFrame
	local auction = ns.Auction()
	if auction and auction.Search and frame and frame:IsShown() and item.name ~= "" then
		list[#list + 1] = { text = L.SEARCH_AUCTION, run = Close(function() WandererAuction.Search(item.name) end) }
	end
	return list
end

local function Card()
	if card then return card end
	card = W.Skin.Card("WandererBagsMarkPicker", true)
	card.onHide = function(self) self.item, self.inSections = nil, false end
	return card
end

-- The card drawn for its item: the heading, the tiles, the list, its size.
function ns.FillCard()
	local item = card and card.item
	if not item then return end
	local mark, placed = ns.Mark(item.id), ns.Placed(item.id)
	local now = L.MARK_NONE_NOW
	for _, spec in ipairs(TILES) do
		if spec.mark and spec.mark == mark then now = L.MARK_NOW:format(L[spec.label]) end
	end
	if placed then now = now .. U.SEPARATOR .. L.MARK_IN_SECTION:format(placed) end
	-- (one of your outfits' pieces: said, it is never sold whatever its mark)
	local worn = ns.InOutfit(item.id)
	if worn then now = now .. U.SEPARATOR .. L.MARK_IN_OUTFIT:format(worn[1]) end
	local tiles = {}
	for index, spec in ipairs(TILES) do
		tiles[index] = { sign = MarkSign(spec.mark), label = L[spec.label], tip = L[spec.tip], on = spec.mark == (mark or false),
			run = function() SetMarkTo(item.id, spec.mark or nil) end }
	end
	card:Fill({ title = item.name ~= "" and item.name or U.LinkName(item.link) or L.TITLE, quality = item.quality or 1,
		icon = U.Clean(item.info and item.info.iconFileID) or U.Safe(C_Item and C_Item.GetItemIconByID, item.id),
		now = now, tiles = tiles, rows = Entries(item, card.inSections), keys = L.MARK_KEYS })
end

-- Alt+click on an item (once, however the click came): its card, or closed when it was already its card.
function ns.ItemMenu(owner, item)
	local id = item and item.id
	if not id or GetTime() - lastMenu < 0.3 then return end
	lastMenu = GetTime()
	Card()
	if card:IsShown() and card.owner == owner and card.item and card.item.id == id then
		card:Hide()
		return
	end
	card.item, card.inSections = item, false
	ns.MarkHintSeen()
	ns.FillCard()
	card:Present(owner)
end
ns.MarkCard = function() return card end -- (tests)

-- A right click on a section's title (or its "..."): its card ----------------------------------------------------
-- The section's name and what it holds; four tiles: pinned at the top, one place up, one place down, folded (the
-- state now in gold); below, what only this section offers: rename or remove one of yours, sell it all at a
-- merchant, the items just picked up seen. Up and down keep the card open (press them again).

local sectionCard

-- info: { key, title, count, value, where, shown (keys in order), byBag, folded, custom (its name), sell (fn),
-- seen (fn), deposit (fn: at the banker), toBank (it may always go to the bank), fold (fn), owner, reopen (key -> its
-- title's frame, once drawn again) }
local function FillSection(info)
	local key, where = info.key, info.where
	local pinned = ns.IsPinned(where, key)
	local function Moved(delta)
		return function()
			if ns.MoveSection(where, key, delta, info.shown()) and info.reopen then
				-- (drawn again: the card follows its section to its new place)
				local owner, again = info.reopen(key)
				if owner then ns.SectionCard(owner, again) else sectionCard:Hide() end
			end
		end
	end
	local byBag = info.byBag
	local tiles = {
		{ sign = { glyph = "up", bar = true }, label = pinned and L.CARD_PINNED or L.CARD_PIN, tip = byBag and L.CARD_BY_KIND_ONLY or L.CARD_PIN_TIP,
			on = pinned, disabled = byBag, run = function() ns.PinSection(where, key) end },
		{ sign = { glyph = "up" }, label = L.CARD_UP, tip = byBag and L.CARD_BY_KIND_ONLY or L.CARD_UP_TIP, stay = true,
			disabled = byBag or not ns.CanMoveSection(where, key, -1, info.shown()), run = Moved(-1) },
		{ sign = { glyph = "down" }, label = L.CARD_DOWN, tip = byBag and L.CARD_BY_KIND_ONLY or L.CARD_DOWN_TIP, stay = true,
			disabled = byBag or not ns.CanMoveSection(where, key, 1, info.shown()), run = Moved(1) },
		{ sign = { glyph = "chevron" }, label = info.folded and L.CARD_FOLDED or L.CARD_FOLD, tip = L.CARD_FOLD_TIP, on = info.folded,
			run = info.fold },
	}
	local rows = {}
	local function Close(fn) return function() sectionCard:Hide() fn() end end
	if info.sell then
		rows[#rows + 1] = { main = true, text = L.CARD_SELL_ALL:format(U.Coins(info.value or 0)), run = info.sell }
	end
	-- At the banker: the whole section into the bank, one click.
	if info.deposit then rows[#rows + 1] = { main = not info.sell, text = L.CARD_DEPOSIT, run = Close(info.deposit) } end
	-- Always into the bank at the banker (checked: on); the card stays, its check drawn again.
	if info.toBank then
		rows[#rows + 1] = { text = L.CARD_ALWAYS_BANK, checked = ns.SectionToBank(key), hint = L.CARD_ALWAYS_BANK_DESC, run = function()
			ns.ToggleSectionToBank(key)
			if sectionCard:IsShown() then FillSection(info) end
		end }
	end
	if info.seen then rows[#rows + 1] = { text = L.CARD_SEEN, run = Close(info.seen) } end
	if info.custom then
		rows[#rows + 1] = { text = L.CARD_RENAME, run = Close(function() RenameSectionAsk(info.custom) end) }
		rows[#rows + 1] = { text = L.CARD_REMOVE, role = "bad", run = Close(function() RemoveSectionAsk(info.custom) end) }
	end
	local now = L.CARD_ITEMS:format(info.count or 0)
	if (info.value or 0) > 0 then now = now .. U.SEPARATOR .. L.CARD_WORTH:format(U.Coins(info.value)) end
	sectionCard:Fill({ title = info.title, now = now, tiles = tiles, rows = rows, keys = L.CARD_KEYS })
end

-- Opened (or drawn again) beside a section's title.
function ns.SectionCard(owner, info)
	if not sectionCard then
		sectionCard = W.Skin.Card("WandererBagsSectionCard", false)
		sectionCard.onHide = function(self) self.key = nil end
	end
	sectionCard.key = info.key
	-- (its title showing another section, once drawn again: the card goes)
	sectionCard.valid = nil
	FillSection(info)
	sectionCard:Present(owner)
	sectionCard.valid = function() return owner.section ~= nil and owner.section.key == info.key end
end
-- The section's card open for this section (its title clicked again: closed).
function ns.SectionCardOpen(key) return sectionCard and sectionCard:IsShown() and sectionCard.key == key or false end
function ns.CloseSectionCard() if sectionCard then sectionCard:Hide() end end
ns.SectionCardFrame = function() return sectionCard end -- (tests)

-- The Alt+click line in the bags' footer: shown to a character who never marked anything, until seen once.
function ns.MarkHintShown()
	local db = DB()
	if db.markHintSeen then return false end
	if next(db.marks) or db.sections[1] then
		db.markHintSeen = true
		return false
	end
	return true
end
function ns.MarkHintSeen() DB().markHintSeen = true end

-- The selection's "Section": one of yours, a new one, or out of theirs (then done(), the selection cleared). A small
-- card beside the bar's button, as every choice of the bags.
function ns.SectionsMenu(owner, ids, done)
	local rows = {}
	for _, name in ipairs(DB().sections) do
		rows[#rows + 1] = { text = name, glyph = "chevron", onClick = function() ns.PlaceMany(ids, name) done() end }
	end
	rows[#rows + 1] = { text = L.SECTION_NEW, glyph = "plus", onClick = function() NewSection(ids) done() end }
	rows[#rows + 1] = { text = L.SECTION_LEAVE, glyph = "close", onClick = function() ns.PlaceMany(ids, nil) done() end }
	W.Skin.ActionCard(owner, { title = L.MARK_SECTION, rows = rows })
end

-- (kept in step with the option; nothing to do where the game has no such button)
function ns.CoverJunk() end

-- The game's "Sell all junk" button, while the bags are Wanderer's: left untouched, a button of ours lies over
-- it and does the same without what you keep (hovered, the game's own highlight and tooltip).
local function CoverSellAllJunk()
	local button = _G.MerchantSellAllJunkButton
	if not button then return end
	local cover = CreateFrame("Button", nil, button)
	cover:SetAllPoints()
	cover:SetFrameLevel(button:GetFrameLevel() + 2)
	cover:SetScript("OnClick", function()
		if button.IsEnabled and not button:IsEnabled() then return end
		W.Skin.Ask(SELL_ALL_JUNK_ITEMS_POPUP or L.SELL, function() W.SellItems(W.FindJunk()) end)
	end)
	cover:SetScript("OnEnter", function()
		if button.LockHighlight then button:LockHighlight() end
		local enter = button:GetScript("OnEnter")
		if enter then enter(button) end
	end)
	cover:SetScript("OnLeave", function()
		if button.UnlockHighlight then button:UnlockHighlight() end
		local leave = button:GetScript("OnLeave")
		if leave then leave(button) end
	end)
	-- (while the bags are Wanderer's, and whenever you marked something or made a section: the marks guard your items
	-- with another bags addon too, or the window off)
	local function Shown()
		local db = DB()
		cover:SetShown(ns.On() or next(db.marks) ~= nil or db.sections[1] ~= nil)
	end
	button:HookScript("OnShow", Shown)
	ns.CoverJunk = Shown
	Shown()
end

-- How many of an item your own bank held when last seen (0: none, or never seen).
local function BankHas(id)
	local counts = id and ns.SavedBankCounts and ns.SavedBankCounts() or {}
	return counts[id] or 0
end

function ns.InitMarks()
	-- For Wanderer Auction: what you keep, what you set aside for the auction house.
	-- (WandererBagsMarks: the older name of this very table, kept for Wanderer Auction)
	WandererBags = type(WandererBags) == "table" and WandererBags or {}
	WandererBags.Marks = { IsKept = ns.IsKept, IsForAuction = ns.IsForAuction, IsForBank = ns.IsForBank, AuctionPrice = ns.AuctionPrice,
		-- (never offered at the auction house: kept or an outfit's piece; a section's items may be posted)
		NotForAuction = ns.AuctionGuarded,
		-- (in one of your sections: Wanderer Auction leaves it aside when selling everything)
		InSection = function(id) return ns.Placed(id) ~= nil end,
		-- (marked junk now: what Wanderer Auction made junk stays so only while this mark does)
		IsJunk = function(id) return id ~= nil and ns.Mark(id) == "junk" end,
		Refresh = function() ns.ShopRefresh() end,
		-- (an item set aside for the auction house that brings more at a merchant: junk now, sold at the next one)
		ToJunk = function(id)
			if not (id and ns.IsForAuction(id)) then return false end
			SetMarkTo(id, "junk")
			return true
		end,
		-- For Wanderer Outfits: an outfit's piece (never sold), what your bank held.
		InOutfit = function(id) return ns.InOutfit(id) ~= nil end,
		BankHas = BankHas }
	WandererBagsMarks = WandererBags.Marks
	-- (Wanderer Outfits says when its outfits change; at the banker, it asks for an outfit's pieces)
	WandererBags.OutfitsChanged = function() ns.OutfitsChanged() end
	-- (Wanderer Auction's banker waits while the bags move items one by one)
	WandererBags.Moving = function() return ns.Moving and ns.Moving() or false end
	WandererBags.AtBank = function() return ns.AtBank and ns.AtBank() or false end
	WandererBags.TakeFromBank = function(wants) return ns.TakeFromBank and ns.TakeFromBank(wants) or false end
	CoverSellAllJunk()
	-- The game's own modified click on an item also says it: Alt over one of our squares opens the menu.
	if hooksecurefunc and HandleModifiedItemClick then
		hooksecurefunc("HandleModifiedItemClick", function()
			if not IsAltKeyDown() then return end
			local focus = U.MouseFocus()
			if type(focus) == "table" and focus.wandererItem then ns.ItemMenu(focus, focus.wandererItem) end
		end)
	end
	-- Wanderer's sale of the junk at merchants follows these marks.
	W.AddJunkRule(function(id)
		-- (kept, for the auction house or the bank, an outfit's piece: never sold, whatever the bags' window; junk:
		-- while it is on)
		if ns.NeverSold(id) then return false end
		if not ns.On() then return nil end
		if ns.Mark(id) == "junk" then return true end
		return nil
	end)
end
