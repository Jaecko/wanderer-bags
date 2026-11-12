local _, ns = ...
local L = ns.L

-- The engine shared by the bags and the bank: one window drawn by Wanderer's
-- engine (its style, its profiles), the items of a list of containers sorted
-- by kind (gear, consumables, crafting, quests, the rest, what goes to the bank, junk and what you keep at the end) or
-- container by container. The squares are the game's own item buttons: a
-- right click uses (or moves between bags and bank), a drag moves, the
-- tooltip, the cooldowns and the new items glow as in the game. Gear better
-- for the branch you play wears Wanderer's green arrow.
-- The heading says what it is and holds only what depends on where you are (the bank seen before, the shopping
-- list); the footer strip holds the sorting and the arrangement (the one shown in gold), the free slots and the
-- money. Each section's title folds it; its right click (or its "...") opens its card: pinned, moved, folded,
-- sold. The window is widened by its corner, a whole row of squares at a time.

local W = Wanderer
local U = W and W.Util
local Safe, Clean = U and U.Safe, U and U.Clean
local Upper = U and U.Upper -- capitals in every language
local Fold = U and U.Fold or string.lower -- a search's words: accents and capitals aside

local GAP = 4
local SECTION_GAP = 8
local HEADER_HEIGHT = 20
local HEADER_ROOM = HEADER_HEIGHT + 4 -- a section's title and the gap under it
local TOP_ROOM = 64 -- heading, search
local BOTTOM_ROOM = 28 -- the footer strip: sorting, arrangement, free slots, gold
local MIN_COLUMNS, MAX_COLUMNS = 6, 16 -- (as the option's slider)
-- (a title's "..." at its right end, the kit's room kept for it: asked when drawn, never as an older Wanderer loads)
local function MoreRoom() return W.Skin.ROW_MORE + 4 end
local REFRESH_DELAY = 0.05 -- many updates at once: one drawing

local SHARED_KINDS = { quest = "QUESTS", gear = "GEAR", auction = "FOR_AUCTION" }
local CATEGORY_ORDER = { "new", "outfits", "custom", "gear", "consumable", "professions", "alts", "trade", "quest", "other", "auction",
	"bank", "others", "junk", "kept" }
local PROFESSION = "profession:" -- a section of one of your professions: this, then its name
ns.CUSTOM = "custom:" -- a section of yours: this, then its name
local SELLABLE = { junk = true, others = true } -- what a merchant may take, a link away
local BUYBACK = 12 -- what a merchant buys back: the last twelve sold
local DEAR = 3 -- a reagent the auction house pays that many times the merchant: left aside when selling "for other professions"
local BIND_ON_EQUIP = 2 -- (the game's bind type: when equipped)
local RESORT_TIME = 2 -- after Sort: ranked anew that long (the game moves the items a while)
local LOCK_MARK = "Interface\\PetBattles\\PetBattle-LockIcon"
local AUCTION_MARK = "Interface\\Minimap\\Tracking\\Auctioneer"
local QUEST_MARK = "Interface\\GossipFrame\\ActiveQuestIcon"
local BANK_MARK = "Interface\\Minimap\\Tracking\\Banker"
-- An outfit's piece: the game's hanger (its transmogrification cursor), else the transmogrifier's sign.
local OUTFIT_ATLAS, OUTFIT_FILE = "Crosshair_Transmogrify_32", "Interface\\Minimap\\Tracking\\Transmogrifier"
local MARK_SIZE = 15
-- (the same signs on the Alt+click card's tiles: what a tile puts on the item is what it shows)
ns.MARK_SIGNS = { keep = LOCK_MARK, auction = AUCTION_MARK, bank = BANK_MARK }
-- Your say over an item, the first that holds wins (is(id) -> its value: a section's name, an outfit's names): its
-- corner sign, its tooltip line, the words when a click is refused at a merchant (each a text key).
local MARKS = {
	{ is = function(id) return ns.Mark(id) == "keep" end, sign = LOCK_MARK, tip = "KEPT_TIP", blocked = "KEPT_BLOCKED" },
	{ is = function(id) return ns.Placed(id) end, sign = LOCK_MARK, tip = "SECTION_BLOCKED", blocked = "SECTION_BLOCKED" },
	{ is = function(id) return ns.IsForAuction(id) end, sign = AUCTION_MARK, tip = "AUCTION_TIP", blocked = "AUCTION_BLOCKED" },
	{ is = function(id) return ns.IsForBank(id) end, sign = BANK_MARK, tip = "BANK_MARK_TIP", blocked = "BANK_BLOCKED" },
	{ is = function(id) return ns.InOutfit(id) end, sign = OUTFIT_FILE, blocked = "OUTFIT_BLOCKED" },
	{ is = function(id) return ns.Mark(id) == "junk" end, tip = "JUNK_TIP" },
}
local function MarkOf(id)
	if not id then return nil end
	for _, mark in ipairs(MARKS) do
		local value = mark.is(id)
		if value then return mark, value end
	end
end
-- A text key's words, its pad variant (<KEY>_PAD: the left button, not Alt+click) under the pad.
local function PadWords(key)
	if not key then return nil end
	return (U and U.UsingPad and U.UsingPad() and L[key .. "_PAD"]) or L[key]
end
-- A mark's words (key: "tip" or "blocked"), its section's name put in.
local function MarkWords(mark, value, key)
	local words = mark and PadWords(mark[key])
	if words and mark[key] == "SECTION_BLOCKED" then words = words:format(value) end
	return words
end
local AUCTION_VALUE = { auction = true, others = true } -- what the auction house would pay (Auctionator's prices)
local TRADE = { [3] = true, [5] = true, [7] = true, [9] = true } -- gems, reagents, trade goods, recipes
local CONSUMABLE = { [0] = true, [6] = true } -- consumables, projectiles
local WEAPON, ARMOR, QUEST = 2, 4, 12
local POOR = 0

-- The slots of a container (none when it is not there).
function ns.NumSlots(bag)
	return Clean(Safe(C_Container.GetContainerNumSlots, bag)) or 0
end

-- A bag that takes only some items (a quiver, an ammo pouch, a soul bag, a profession's bag): its family (0: any item).
function ns.BagFamily(bag)
	local _, family = Safe(C_Container.GetContainerNumFreeSlots, bag)
	return Clean(family) or 0
end

ns.INVENTORIES = {}

local function KindName(kind)
	if kind:find(PROFESSION, 1, true) == 1 then return kind:sub(#PROFESSION + 1) end
	if kind:find(ns.CUSTOM, 1, true) == 1 then return kind:sub(#ns.CUSTOM + 1) end
	-- (three of them are words every addon shares)
	return L[SHARED_KINDS[kind] or ("CAT_" .. kind:upper())]
end

-- A crafting reagent's section, from what Wanderer knows of the professions using it: the one of yours with the most
-- recipes using it, else your other characters', else the other professions'; plain crafting when none is known.
local function CraftingGroup(id)
	local settings = ns.Settings()
	if not (id and settings and settings.byProfession) then return "trade" end
	local best, alt, any
	for _, use in ipairs(W.ReagentUses(id)) do
		any = true
		if use.mine and (not best or use.count > best.count) then best = use end
		if use.alt then alt = true end
	end
	if best then return PROFESSION .. best.name end
	if alt then return "alts" end
	return any and "others" or "trade"
end

-- An outfit's pieces gathered in their own section (an option, on unless turned off).
local function OutfitSection()
	local settings = ns.Settings()
	return settings and settings.outfitSection ~= false
end

-- Where an item goes: its kind's section, crafting by profession, then your say over it (your section, an outfit
-- of yours, junk, for the auction house, for the bank, or kept: their own section, at the bottom). In the bank
-- (inBank), what is for the bank is home: its kind's section.
function ns.Group(kind, id, inBank)
	local group = kind == "trade" and CraftingGroup(id) or kind
	local placed = ns.Placed(id)
	if placed then return ns.CUSTOM .. placed end
	if ns.InOutfit and ns.InOutfit(id) and OutfitSection() then return "outfits" end
	local mark = ns.Mark(id)
	if mark == "junk" then return "junk" end
	if mark == "auction" then return "auction" end
	if mark == "bank" then return inBank and group or "bank" end
	-- Kept: together at the bottom, out of the way (they never move).
	if mark == "keep" then return "kept" end
	return group
end

function ns.Settings()
	return W.Settings("bags")
end

-- Wanderer Auction, loaded and switched on: its table, else nil (an older one without IsOn: on).
function ns.Auction()
	local api = type(WandererAuction) == "table" and WandererAuction or nil
	if api and api.IsOn and not api.IsOn() then return nil end
	return api
end

local function LiveInfo(bag, slot) return Safe(C_Container.GetContainerItemInfo, bag, slot) end

-- One item of a slot: what to sort it by and where it goes. Read in the bags,
-- or from a source (a bank seen before), where nothing is new or for a quest; inBank: an item of the bank.
local function Read(bag, slot, source, inBank)
	local info = (source or LiveInfo)(bag, slot)
	if type(info) ~= "table" then return nil end
	local id = Clean(info.itemID)
	local link = Clean(info.hyperlink)
	local quality = Clean(info.quality) or 1
	local _, _, _, equip, _, class = U.ItemInstant(id or 0)
	equip, class = Clean(equip), Clean(class)
	local quest = not source and Safe(C_Container.GetContainerItemQuestInfo, bag, slot) or nil
	local isQuest = type(quest) == "table" and (Clean(quest.isQuestItem) or Clean(quest.questID)) and true or false
	local kind
	if isQuest or class == QUEST then
		kind = "quest"
	elseif quality == POOR and not Clean(info.hasNoValue) then
		kind = "junk"
	elseif class == WEAPON or class == ARMOR or (equip and equip ~= "" and equip ~= "INVTYPE_NON_EQUIP_IGNORE") then
		kind = "gear"
	elseif class and CONSUMABLE[class] then
		kind = "consumable"
	elseif class and TRADE[class] then
		kind = "trade"
	else
		kind = "other"
	end
	if id and not link then ns.AskItem(id) end
	local name = U.LinkName(link) or ""
	local level = kind == "gear" and link and Clean(Safe(C_Item and C_Item.GetDetailedItemLevelInfo, link)) or 0
	-- (gear that binds when equipped and is not bound yet: in the bags only, a bank seen before does not say)
	local boe = false
	if kind == "gear" and link and not source and not Clean(info.isBound) then
		boe = Clean((select(14, Safe(C_Item and C_Item.GetItemInfo or GetItemInfo, link)))) == BIND_ON_EQUIP
	end
	return { bag = bag, slot = slot, id = id, link = link, kind = kind, quality = quality, name = name, level = level,
		equip = equip, boe = boe, live = not source, count = Clean(info.stackCount) or 1, info = info, quest = quest,
		fresh = not source and C_NewItems and Clean(Safe(C_NewItems.IsNewItem, bag, slot)) and true or false,
		group = ns.Group(kind, id, inBank) }
end

-- The section by kind of an item in your bags (the one it is drawn in, "just picked up" aside).
function ns.SectionOf(bag, slot)
	local item = Read(bag, slot)
	return item and item.group
end

-- Better first: rarer, higher level, then by name and by stack.
local function Before(a, b)
	if a.quality ~= b.quality then return a.quality > b.quality end
	if a.level ~= b.level then return a.level > b.level end
	if a.name ~= b.name then return a.name < b.name end
	if a.count ~= b.count then return a.count > b.count end
	if a.bag ~= b.bag then return a.bag < b.bag end
	return a.slot < b.slot
end

-- The search ---------------------------------------------------------------------------------------------------
-- Words that must all be found (spaces between them), "|" between choices, "!" before a word: without it. A word is
-- found in the name, the kind or the section, a quality ("rare"), "BoE" (binds when equipped), an equip slot
-- ("head"), a level (">40", "<20", "30-40"); else, last of all, in the item's tooltip.

local qualityWords -- quality -> its name in the game's words (folded)
local function QualityWord(quality)
	if not qualityWords then
		qualityWords = {}
		for index = 0, 8 do
			local word = _G["ITEM_QUALITY" .. index .. "_DESC"]
			if type(word) == "string" then qualityWords[index] = Fold(word) end
		end
	end
	return qualityWords[quality]
end

-- An item's tooltip, its words folded (read once by link; nothing kept while the game has not told it).
local tipTexts, tipCount = {}, 0
local TIP_KEPT = 400
local function TooltipText(item)
	local key = item.link
	if not key then return "" end
	if tipTexts[key] then return tipTexts[key] end
	local tips, data = C_TooltipInfo, nil
	if tips and item.live and tips.GetBagItem then
		data = Safe(tips.GetBagItem, item.bag, item.slot)
	elseif tips and tips.GetHyperlink then
		data = Safe(tips.GetHyperlink, key)
	end
	local words = {}
	for _, line in ipairs(U.TooltipLines(type(data) == "table" and data.lines or nil)) do words[#words + 1] = line.text end
	if not words[1] then return "" end
	if tipCount >= TIP_KEPT then tipTexts, tipCount = {}, 0 end
	tipTexts[key], tipCount = Fold(table.concat(words, "\n")), tipCount + 1
	return tipTexts[key]
end

-- A query in its parts: its choices, each a list of words { word, negate } (a level's: { low, high } too).
local compiled, compiledCount = {}, 0
local function Compile(query)
	if compiled[query] then return compiled[query] end
	local choices = {}
	for choice in (query .. "|"):gmatch("(.-)|") do
		local words = {}
		for word in choice:gmatch("%S+") do
			local negate = word:sub(1, 1) == "!"
			if negate then word = word:sub(2) end
			local entry = { word = word, negate = negate }
			local sign, equal, number = word:match("^([<>])(=?)(%d+)$")
			local from, to = word:match("^(%d+)%-(%d+)$")
			if sign then
				number = tonumber(number)
				if sign == ">" then
					entry.low, entry.high = equal == "=" and number or number + 1, math.huge
				else
					entry.low, entry.high = 0, equal == "=" and number or number - 1
				end
			elseif from then
				from, to = tonumber(from), tonumber(to)
				entry.low, entry.high = math.min(from, to), math.max(from, to)
			end
			if word ~= "" then words[#words + 1] = entry end
		end
		if words[1] then choices[#choices + 1] = words end
	end
	if compiledCount >= 50 then compiled, compiledCount = {}, 0 end
	compiled[query], compiledCount = choices, compiledCount + 1
	return choices
end

-- A plain search (no level, no sign): what your other characters carry may be said for it.
local function Plain(query) return not query:find("[|!<>]") and not query:find("%d%-%d") end

local function Found(item, entry)
	if entry.low then
		local level = item.level or 0
		return level > 0 and level >= entry.low and level <= entry.high
	end
	local word = entry.word
	if Fold(item.name):find(word, 1, true) then return true end
	if Fold(KindName(item.kind)):find(word, 1, true) or Fold(KindName(item.group)):find(word, 1, true) then return true end
	local quality = #word >= 3 and QualityWord(item.quality)
	if quality and quality:find(word, 1, true) == 1 then return true end
	if item.boe and (word == "boe" or word == Fold(L.BOE)) then return true end
	local slot = item.equip and item.equip ~= "" and _G[item.equip]
	if type(slot) == "string" and Fold(slot):find(word, 1, true) then return true end
	-- (last of all, the tooltip: three letters at least)
	return #word >= 3 and TooltipText(item):find(word, 1, true) ~= nil
end

-- An item found by the search (query: folded already).
local function Matches(item, query)
	if query == "" then return true end
	local choices = Compile(query)
	if not choices[1] then return true end
	for _, words in ipairs(choices) do
		local all = true
		for _, entry in ipairs(words) do
			if Found(item, entry) == entry.negate then
				all = false
				break
			end
		end
		if all then return true end
	end
	return false
end
ns.Matches = Matches

-- The search: what does not match steps back.
local function Dim(button, query)
	local item = button.wandererItem
	local match = not item or Matches(item, query)
	if button.SetMatchesSearch then button:SetMatchesSearch(match) else button:SetAlpha(match and 1 or 0.25) end
end

-- A corner's sign: a file, or the outfit's hanger (an atlas when the game has it).
local function SetSign(texture, file)
	if file == OUTFIT_FILE and C_Texture and C_Texture.GetAtlasInfo and Clean(Safe(C_Texture.GetAtlasInfo, OUTFIT_ATLAS)) then
		texture:SetAtlas(OUTFIT_ATLAS)
		return
	end
	texture:SetTexture(file)
	texture:SetTexCoord(0, 1, 0, 1)
end

-- An inventory window ------------------------------------------------------------------------
-- spec: name (of its frame), title, on() (in use), containers() -> { bag ids }, nameOf(bag)
-- (its section title by container), point (where it first opens), sounds,
-- money() (the copper shown, the player's by default; nil: none), actions(window, add) to put links
-- in its heading (what depends on where you are), onRefresh(window, total, items) (the items just read), onShow(),
-- onHide(); source() (items read elsewhere than in the bags: (bag, slot) -> info) and numSlots(bag) for what is not
-- at hand; canSell (a merchant may take its items), selectable (its selection's bar: the bags) and bank (the bank's
-- window: its folded sections and its order its own, what is for the bank in its kind's section); markHint (the
-- Alt+click line in its footer, once); help (the "?" by its cross); sort() and canSort() (the footer's Sort);
-- footTools(window, add): buttons of its own in the footer after Sort, in place of the arrangement (the bank's: the
-- bags beside it show the arrangement); settings (its page in Wanderer's settings, a cog in its heading when
-- Wanderer draws one).

-- Bags nearly full (a tenth of their slots free, or two): the cheapest things you carry, worth least to a
-- merchant, what is never sold aside (ns.NeverSold, quest items). { { link, name, count, value } }, the cheapest first.
local ROOM_SHARE, ROOM_LEAST, ROOM_NAMED = 0.1, 2, 3
function ns.NearlyFull(free, total) return total > 0 and free <= math.max(ROOM_LEAST, math.floor(total * ROOM_SHARE)) end
function ns.Cheapest(items)
	local found = {}
	for _, item in ipairs(items) do
		local each = item.link and U.SellPrice(item.link) or 0
		if each > 0 and item.kind ~= "quest" and not ns.NeverSold(item.id) then
			found[#found + 1] = { link = item.link, name = item.name, count = item.count, value = each * item.count }
		end
	end
	table.sort(found, function(a, b) return a.value < b.value end)
	while #found > ROOM_NAMED do table.remove(found) end
	return found
end

-- A window's heading, with a cog to its settings page.
local function Heading(window, title, settings)
	return W.Skin.Header(window, "Wanderer", title, settings and { settings = settings } or nil)
end

-- A question with a box under its words (the sale's "sell them too"): words(on) drawn again as the box changes,
-- accept(on) on yes; no, Escape or the cross let it go. Wanderer's own question from its API 21 (its box), else
-- one made here of Wanderer's pieces.
local boxAsk
function ns.AskWithBox(words, label, accept)
	if (W.API or 1) >= 21 then
		local on = false
		local check
		local function Yes() accept(on) end
		check = { label = label, get = function() return on end, set = function(value)
			on = value and true or false
			-- (asked again in its place, the same box: the words follow it)
			W.Skin.Ask(words(on), Yes, { check = check })
		end }
		return W.Skin.Ask(words(false), Yes, { check = check })
	end
	local frame = boxAsk
	if not frame then
		frame = W.Skin.CreateWindow("WandererBagsAsk", "DIALOG")
		if W.Skin.PadWindow then W.Skin.PadWindow(frame) end
		frame:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
		frame:EnableMouse(true)
		frame.words = W.Skin.Text(frame, "GameTooltipText", "text")
		frame.words:SetJustifyH("CENTER")
		frame.words:SetWidth(340)
		frame.words:SetSpacing(2)
		frame.check = W.Skin.Check(frame, "", function() return frame.on end, function(on)
			frame.on = on and true or false
			frame.Draw()
		end)
		local function Answer(yes)
			local run, on = frame.accept, frame.on
			frame.accept = nil
			frame:Hide()
			if yes and run then run(on) end
		end
		frame.yes = W.Skin.Button(frame, YES or "Yes", function() Answer(true) end, "main", 110)
		frame.no = W.Skin.Button(frame, NO or "No", function() Answer(false) end, nil, 110)
		frame.no:SetHeight(36)
		W.Skin.CloseButton(frame, function() Answer(false) end)
		if UISpecialFrames then table.insert(UISpecialFrames, "WandererBagsAsk") end
		frame:HookScript("OnShow", function(self) self:SetScale(W.Skin.Scale()) end)
		frame:HookScript("OnHide", function(self) self.accept = nil end)
		function frame.Draw()
			local margin = W.Skin.Margin() + 10
			frame.words:SetText(frame.wordsOf(frame.on))
			local height = U.Measure(frame.words, "GetStringHeight", 14)
			frame:SetSize(340 + margin * 2, margin + height + 12 + 18 + 14 + 36 + margin)
			frame.words:ClearAllPoints()
			frame.words:SetPoint("TOP", frame, "TOP", 0, -margin)
			frame.check:ClearAllPoints()
			frame.check:SetPoint("TOP", frame.words, "BOTTOM", 0, -12)
			frame.check:Refresh()
			frame.yes:ClearAllPoints()
			frame.no:ClearAllPoints()
			frame.yes:SetPoint("TOPRIGHT", frame.check, "BOTTOM", -6, -14)
			frame.no:SetPoint("TOPLEFT", frame.check, "BOTTOM", 6, -14)
			W.Skin.Get(frame):Layout()
		end
		boxAsk = frame
	end
	frame.wordsOf, frame.accept, frame.on = words, accept, false
	frame.check:SetLabel(label)
	frame.Draw()
	if frame:IsShown() then if frame.Raise then frame:Raise() end else frame:Show() end
	return frame
end
function ns.BoxAsk() return boxAsk end -- (tests)

function ns.NewInventory(spec)
	local self = {}
	local window, content, searchBox, freeText, moneyText, countText, layoutPair, sortButton, rowsText
	local hintText, hintShown -- the Alt+click line over the footer (spec.markHint), shown at least once
	local roomTip -- the free slots' tooltip, bags nearly full
	local elsewhereShown = false -- the free slots' line saying what your other characters have (a search)
	local bagFrames, headers, links = {}, {}, {}
	-- The game's squares for what is at hand, plain ones for what is only seen.
	local pools = { live = {}, saved = {} }
	local buttons = pools.live
	local NumSlots = spec.numSlots or ns.NumSlots
	-- The selection (spec.selectable): a click chooses an item instead of using it, the bar acts on all chosen.
	local selecting, picked, shown, lastPicked = false, {}, {}, nil
	local selectButton, bar
	local function Key(item) return item.bag .. ":" .. item.slot end
	-- Its sections folded and ordered on their own: the bank's apart from the bags'.
	self.foldPrefix = spec.bank and ns.BANK_FOLD or ""
	self.where = spec.bank and "bank" or "bags"
	local function FoldKey(key) return key and self.foldPrefix .. key end
	self.shownKeys = {} -- the sections drawn, in their order (the free slots aside)

	local function BagFrame(bag)
		local frame = bagFrames[bag]
		if frame then return frame end
		frame = CreateFrame("Frame", nil, content)
		frame:SetAllPoints(content)
		frame:SetID(bag)
		bagFrames[bag] = frame
		return frame
	end

	-- Alt and a click (a modified one: nothing taken, nothing used) opens your say over the item.
	local function AltMenu(square)
		if IsAltKeyDown() and square.wandererItem then
			ns.ItemMenu(square, square.wandererItem)
			return true
		end
	end

	-- A square of what is only seen: its tooltip and its link, nothing to move.
	local function SavedButton()
		local button = CreateFrame("ItemButton", nil, content)
		W.Skin.ItemTooltip(button, function(square) return square.wandererLink end, "ANCHOR_RIGHT")
		button:SetScript("OnClick", function(square)
			if AltMenu(square) then return end
			if square.wandererLink and HandleModifiedItemClick then HandleModifiedItemClick(square.wandererLink) end
		end)
		return button
	end

	-- Kept, an outfit's piece, a quest's: said in the item's tooltip, with how to free it.
	local function AddWords(square)
		local item = square.wandererItem
		if not item then return end
		local need = ns.QuestNeed(item.id)
		local outfit = ns.InOutfit(item.id)
		local lines = {}
		local mark, value = MarkOf(item.id)
		lines[#lines + 1] = MarkWords(mark, value, "tip")
		-- (an outfit's piece: said whatever its mark, it is never sold)
		if outfit then lines[#lines + 1] = L.OUTFIT_TIP:format(table.concat(outfit, ", ")) end
		if not lines[1] and need then lines[1] = L.QUEST_NEED_TIP:format(need.quest, need.have, need.need) end
		local blue = W.Skin.COLORS.blue
		for _, line in ipairs(lines) do GameTooltip:AddLine(line, blue[1], blue[2], blue[3], true) end
		-- (shown again only without the game's coins in it: an addon-asked showing breaks their widths)
		if lines[1] then W.Util.ShowTooltipAgain(GameTooltip) end
	end

	local wordsFollow = false
	if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum.TooltipDataType then
		wordsFollow = true
		TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip)
			if tooltip ~= GameTooltip then return end
			local owner = tooltip.GetOwner and tooltip:GetOwner()
			if type(owner) == "table" and owner.wandererOurWords == spec.name and owner.wandererItem then AddWords(owner) end
		end)
	end

	local function Button(bag, slot)
		buttons[bag] = buttons[bag] or {}
		local button = buttons[bag][slot]
		if button then return button end
		if buttons == pools.saved then
			button = SavedButton()
		else
			local ok, made = pcall(CreateFrame, "ItemButton", ("%sItem%d_%d"):format(spec.name, bag + 10, slot),
				BagFrame(bag), "ContainerFrameItemButtonTemplate")
			button = ok and made or CreateFrame("Button", nil, BagFrame(bag))
			button:HookScript("OnMouseUp", function(square)
				if AltMenu(square) then return end
				-- Kept, where it could be sold: the click is refused, and said why (at the auction house: kept, or an
				-- outfit's piece).
				if square.wandererGuarded and UIErrorsFrame then
					local item = square.wandererItem
					local mark, value = MarkOf(item and item.id)
					local words = W.IsMerchantOpen() and (MarkWords(mark, value, "blocked")
						or (item and ns.QuestNeed(item.id) and L.QUEST_BLOCKED))
						or (ns.Mark(item and item.id) == "keep" and PadWords("KEPT_BLOCKED") or L.OUTFIT_BLOCKED)
					UIErrorsFrame:AddMessage(words or PadWords("KEPT_BLOCKED"), 1, 0.1, 0.1)
				end
			end)
			-- Kept: said in its tooltip, with how to free it.
			button:HookScript("OnEnter", function(square)
				local item = square.wandererItem
				-- (a special bag's free square: which bag, how many)
				if not item and square.wandererFreeTip then return W.Skin.ShowTip(square, square.wandererFreeTip, "ANCHOR_RIGHT") end
				-- (the older bank's own container: the game reads its tooltip as one of your inventory's slots)
				if item and item.bag == (BANK_CONTAINER or -1) and type(_G.BankButtonIDToInvSlotID) == "function"
					and not (GameTooltip:IsOwned(square) and GameTooltip:NumLines() > 0) then
					GameTooltip:SetOwner(square, "ANCHOR_RIGHT")
					Safe(GameTooltip.SetInventoryItem, GameTooltip, "player", _G.BankButtonIDToInvSlotID(item.slot))
				end
				if not (item and GameTooltip:IsOwned(square)) then return end
				-- (the game writes the tooltip again while it is shown: with its post call, the words come back each time)
				if not wordsFollow then AddWords(square) end
			end)
			button.wandererOurWords = spec.name
			-- (a controller: the bottom button uses the item, the top one takes it in hand, said under the window)
			if ok then
				button.padPrimary, button.padSecondary, button.padSecondaryWord = "RightButton", "LeftButton", L.PAD_IN_HAND
			end
		end
		button:SetID(slot)
		-- (a controller: its left button opens the item's choices, as Alt + click)
		button.padAlt = function(square) if square.wandererItem then ns.ItemMenu(square, square.wandererItem) end end
		-- An empty square still looks like a slot of a bag.
		local ground = button:CreateTexture(nil, "BACKGROUND", nil, -6)
		ground:SetAllPoints()
		if not (ground.SetAtlas and pcall(ground.SetAtlas, ground, "bags-item-slot64")) then
			ground:SetTexture("Interface\\Buttons\\UI-EmptySlot-Disabled")
			ground:SetTexCoord(0.14, 0.86, 0.14, 0.86)
		end
		-- One sign per corner: the game's arrow or coin at the top left, your mark at the top right (a padlock, the
		-- auction house's, the banker's, an outfit's hanger or a quest's; a soft shadow keeps it read over a bright
		-- icon), the item level at the bottom left, the game's count at the bottom right.
		button.wandererShadow = button:CreateTexture(nil, "OVERLAY", nil, 1)
		button.wandererShadow:SetSize(MARK_SIZE, MARK_SIZE)
		button.wandererShadow:SetPoint("TOPRIGHT", button, "TOPRIGHT", 0, -2)
		button.wandererShadow:SetVertexColor(0, 0, 0, 0.7)
		button.wandererShadow:Hide()
		button.wandererLock = button:CreateTexture(nil, "OVERLAY", nil, 2)
		button.wandererLock:SetSize(MARK_SIZE, MARK_SIZE)
		button.wandererLock:SetPoint("TOPRIGHT", button, "TOPRIGHT", -1, -1)
		button.wandererLock:SetTexture(LOCK_MARK)
		button.wandererLock:Hide()
		button.wandererLevel = button:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
		button.wandererLevel:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 2, 2)
		-- (binds when equipped: a few quiet letters over the level, no glow)
		button.wandererBoe = button:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
		button.wandererBoe:SetTextColor(Wanderer.Skin.COLORS.soft[1], Wanderer.Skin.COLORS.soft[2], Wanderer.Skin.COLORS.soft[3])
		-- (the free slots' square: how many, in its middle)
		button.wandererFree = W.Skin.Text(button, "GameTooltipText", "soft")
		button.wandererFree:SetPoint("CENTER", button, "CENTER", 0, 0)
		button.wandererFree:Hide()
		buttons[bag][slot] = button
		return button
	end

	-- Over a square while selecting: a click chooses it (Shift: every item from the last one chosen), its tooltip
	-- still there; chosen, a light gold veil and a check.
	local function Pick(button)
		if button.wandererPick then return button.wandererPick end
		local pick = CreateFrame("Button", nil, button)
		pick:SetAllPoints()
		pick:SetFrameLevel(button:GetFrameLevel() + 10)
		pick:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		pick.veil = pick:CreateTexture(nil, "OVERLAY")
		pick.veil:SetAllPoints()
		local gold = W.Skin.COLORS.gold
		pick.veil:SetColorTexture(gold[1], gold[2], gold[3], 0.22)
		pick.edges = W.Skin.Edges(pick, gold[1], gold[2], gold[3], 0.9)
		pick.check = pick:CreateTexture(nil, "OVERLAY", nil, 2)
		pick.check:SetSize(16, 16)
		pick.check:SetPoint("BOTTOMRIGHT", pick, "BOTTOMRIGHT", 2, -2)
		W.Skin.GlyphOn(pick.check, "check")
		pick:SetScript("OnClick", function(frame) self.TogglePick(frame:GetParent().wandererItem, IsShiftKeyDown()) end)
		W.Skin.ItemTooltip(pick, function(frame) return frame:GetParent().wandererLink end, "ANCHOR_RIGHT")
		button.wandererPick = pick
		return pick
	end

	local function PaintPick(button, item)
		-- (a controller reaches the veil over the square, never the square under it: a click there would use the item)
		button.padPass = selecting and item ~= nil or nil
		if not (selecting and item) then
			if button.wandererPick then button.wandererPick:Hide() end
			return
		end
		local pick = Pick(button)
		local chosen = picked[Key(item)] ~= nil
		pick.veil:SetShown(chosen)
		pick.check:SetShown(chosen)
		for _, edge in ipairs(pick.edges) do edge:SetShown(chosen) end
		pick:Show()
	end

	-- free: the free slots' square (how many it stands for).
	local function Paint(button, item, settings, query, free)
		PaintPick(button, item)
		local info = item and item.info
		button.wandererLink = item and item.link
		button.wandererItem = item
		local mark = MarkOf(item and item.id)
		-- Asked by one of your quests (an ordinary item: the game marks its own quest items).
		local needed = not (mark and mark.sign) and item and item.kind ~= "quest" and ns.QuestNeed(item.id) and true or false
		-- (one sign: kept, your section, the auction house, the bank, an outfit, then a quest)
		local sign = mark and mark.sign or needed and QUEST_MARK or nil
		button.wandererLock:SetShown(sign ~= nil)
		button.wandererShadow:SetShown(sign ~= nil)
		if sign and button.wandererSign ~= sign then
			button.wandererSign = sign
			SetSign(button.wandererLock, sign)
			SetSign(button.wandererShadow, sign)
			button.wandererShadow:SetVertexColor(0, 0, 0, 0.7)
		end
		-- At a merchant, what is never sold takes no click nor drag (no sale by mistake): Alt+click changes it first. At
		-- the auction house, only what you keep and an outfit's pieces (a section of yours is yours to post there).
		if spec.canSell and buttons == pools.live then
			local guarded = item and ((W.IsMerchantOpen() and ns.NeverSold(item.id))
				or (ns.Guarding() and ns.AuctionGuarded(item.id))) or false
			if guarded ~= (button.wandererGuarded or false) then
				button.wandererGuarded = guarded
				if guarded then
					button:RegisterForClicks()
					button:RegisterForDrag()
				else
					button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
					button:RegisterForDrag("LeftButton")
				end
			end
		end
		if SetItemButtonTexture then SetItemButtonTexture(button, info and Clean(info.iconFileID)) end
		if SetItemButtonCount then SetItemButtonCount(button, info and Clean(info.stackCount) or 0) end
		if SetItemButtonDesaturated then SetItemButtonDesaturated(button, info and Clean(info.isLocked) and true or false) end
		if SetItemButtonQuality then SetItemButtonQuality(button, item and item.quality, item and item.link) end
		if button.UpdateCooldown then pcall(button.UpdateCooldown, button, item ~= nil) end
		if button.UpdateNewItem and item then
			pcall(button.UpdateNewItem, button, item.quality)
		elseif type(button.NewItemTexture) == "table" then
			-- (an emptied slot: no glow left of what was there)
			button.NewItemTexture:Hide()
			if type(button.flashAnim) == "table" and button.flashAnim.Stop then button.flashAnim:Stop() end
			if type(button.newitemglowAnim) == "table" and button.newitemglowAnim.Stop then button.newitemglowAnim:Stop() end
		end
		if button.UpdateQuestItem then
			local quest = item and type(item.quest) == "table" and item.quest
			pcall(button.UpdateQuestItem, button, quest and Clean(quest.isQuestItem), quest and Clean(quest.questID),
				quest and Clean(quest.isActive))
		end
		if button.SetReadable then button:SetReadable(info and Clean(info.isReadable)) end
		if type(button.JunkIcon) == "table" then button.JunkIcon:SetShown(item and settings.junk and item.group == "junk" or false) end
		if type(button.UpgradeIcon) == "table" then
			button.UpgradeIcon:SetShown(item and settings.upgrade and item.kind == "gear" and W.IsUpgrade(item.link) or false)
		end
		local level = item and settings.itemLevel and item.kind == "gear" and item.level > 1 and item.level
		button.wandererLevel:SetText(level and tostring(level) or "")
		if level then button.wandererLevel:SetTextColor(U.QualityColor(item.quality)) end
		local boe = item and item.boe and settings.boe ~= false
		button.wandererBoe:SetText(boe and L.BOE or "")
		if boe then
			button.wandererBoe:ClearAllPoints()
			button.wandererBoe:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 2, level and 13 or 2)
		end
		button.wandererFree:SetShown(free ~= nil)
		if free then button.wandererFree:SetText(tostring(free)) end
		-- (a special bag's free square, drawn last time: its bag's faint icon and its tooltip gone)
		button.wandererFreeTip = nil
		if button.wandererFaint then
			button.wandererFaint = nil
			if type(button.icon) == "table" and button.icon.SetAlpha then button.icon:SetAlpha(1) end
		end
		Dim(button, query)
		button:Show()
	end

	-- Items sold at the merchant, one by one (Wanderer does it); what is never sold left aside (ns.NeverSold), said
	-- once the sale is accepted. The merchant buys back only the last twelve: more than that go in lots of twelve, a
	-- click each (gray junk all at once), the question says so. dear: the reagents the auction house pays well (three
	-- times the merchant, its price remembered) left aside and named, a box to sell them too. done(lot): after the yes,
	-- with what was sold (a "no" keeps the selection).
	local function Sell(items, done, dear)
		local list, costly, aside = {}, {}, 0
		for _, item in ipairs(items) do
			if ns.NeverSold(item.id) then
				aside = aside + 1
			else
				local each = U.SellPrice(item.link or item.id) or 0
				local entry = { bag = item.bag, slot = item.slot, id = item.id, name = item.name, quality = item.quality,
					worth = each * (item.count or 1) }
				local auction = dear and each > 0 and ns.AuctionPrice(item.link)
				if auction and auction > each * DEAR then costly[#costly + 1] = entry else list[#list + 1] = entry end
			end
		end
		-- What one click sells (with the dear ones or not): the lot, its worth, how many in all.
		local function Lot(withCostly)
			local all = {}
			for _, entry in ipairs(list) do all[#all + 1] = entry end
			if withCostly then for _, entry in ipairs(costly) do all[#all + 1] = entry end end
			local gray = true
			for _, entry in ipairs(all) do if entry.quality ~= POOR then gray = false end end
			local lot = {}
			for index, entry in ipairs(all) do
				if gray or index <= BUYBACK then lot[#lot + 1] = entry end
			end
			local worth = 0
			for _, entry in ipairs(lot) do worth = worth + entry.worth end
			return lot, worth, #all
		end
		local function Words(withCostly)
			local lot, worth, total = Lot(withCostly)
			local words
			local names = {}
			for _, entry in ipairs(costly) do names[#names + 1] = entry.name ~= "" and entry.name or tostring(entry.id) end
			if total == 0 then return L.SELL_DEAR_ONLY:format(table.concat(names, ", ")) end
			if #lot < total then
				words = L.SELL_CONFIRM_LOT:format(#lot, total, U.Coins(worth), BUYBACK)
			elseif total > BUYBACK then
				words = L.SELL_CONFIRM_MANY:format(total, U.Coins(worth), BUYBACK)
			else
				words = L.SELL_CONFIRM:format(total, U.Coins(worth))
			end
			if costly[1] and not withCostly then
				words = words .. "\n\n" .. L.SELL_DEAR:format(table.concat(names, ", "))
			end
			return words
		end
		local function Accept(withCostly)
			local lot = Lot(withCostly)
			if not lot[1] then return end
			-- (the merchant gone since the question: nothing sold, the selection kept as it was)
			if W.SellItems(lot) == false then return end
			if aside > 0 then W.Print(L.SKIPPED:format(aside)) end
			if done then done(lot) end
		end
		if not (list[1] or costly[1]) then
			if aside > 0 then W.Print(L.SKIPPED:format(aside)) end
			return
		end
		if costly[1] then return ns.AskWithBox(Words, L.SELL_DEAR_INCLUDE, Accept) end
		W.Skin.Ask(Words(false), function() Accept(false) end)
	end
	self.Sell = Sell -- (tests)

	-- A section's card: what it offers, read again each time it is drawn.
	local SectionInfo
	local function HeaderOf(key)
		for _, header in ipairs(headers) do
			if header:IsShown() and header.section and header.section.key == key then return header end
		end
	end
	SectionInfo = function(section)
		local key = section.key
		local settings = ns.Settings() or {}
		local custom = key:find(ns.CUSTOM, 1, true) == 1 and key:sub(#ns.CUSTOM + 1) or nil
		local items = section.items or {}
		local byBag = settings.layout == "bags"
		return {
			key = key, title = section.title, count = section.count or #section.buttons, value = section.value, where = self.where,
			shown = function() return self.shownKeys end, byBag = byBag, folded = ns.IsFolded(FoldKey(key)),
			custom = custom,
			fold = function() ns.ToggleFolded(FoldKey(key)) end,
			-- (at a merchant, a section a merchant may take: all of it, what you keep left aside)
			sell = section.sellable and W.IsMerchantOpen() and (section.value or 0) > 0 and function() Sell(items, nil, key == "others") end or nil,
			-- (at the banker, from the bags: the whole section into the bank shown, one click)
			deposit = self.where == "bags" and ns.AtBank() and items[1] and function() ns.DepositChosen(items) end or nil,
			-- (from the bags, a section of a kind: always into the bank at the banker, or not)
			toBank = self.where == "bags" and not byBag and ns.CanSendSection(key) or nil,
			-- (just picked up: seen, each in its own section)
			seen = key == "new" and function()
				for _, item in ipairs(items) do Safe(C_NewItems and C_NewItems.RemoveNewItem, item.bag, item.slot) end
				self.Refresh()
			end or nil,
			reopen = function(moved)
				local header = HeaderOf(moved)
				return header, header and SectionInfo(header.section)
			end,
		}
	end
	local function OpenCard(header)
		local section = header.section
		if not (section and section.key) then return end
		if ns.SectionCardOpen(section.key) then return ns.CloseSectionCard() end
		ns.SectionCard(header, SectionInfo(section))
	end

	-- A section's title: a chevron (open or folded), its name, how many, a fading rule, what it is worth, Sell at a
	-- merchant; under the mouse, its "..." (its card).
	local function Header(index)
		local header = headers[index]
		if header then return header end
		header = CreateFrame("Button", nil, content)
		header:SetHeight(HEADER_HEIGHT)
		header:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		header.padRight, header.padRightWord = true, L.PAD_CARD -- (its right click: the section's card)
		header.ground = header:CreateTexture(nil, "BACKGROUND")
		header.ground:SetAllPoints()
		header.ground:SetColorTexture(1, 1, 1, 0)
		header.chevron = W.Skin.Glyph(header, "down", 10)
		header.chevron:SetPoint("LEFT", header, "LEFT", 2, 0)
		header.text = W.Skin.CreateKicker(header)
		header.text:SetPoint("LEFT", header.chevron, "RIGHT", 6, 0)
		header.text:SetJustifyH("LEFT")
		if header.text.SetWordWrap then header.text:SetWordWrap(false) end
		header.count = W.Skin.Text(header, "GameTooltipTextSmall", "muted")
		header.count:SetPoint("LEFT", header.text, "RIGHT", 6, 0)
		header.sell = W.Skin.SmallButton(header, L.SELL, function()
			local section = header.section
			Sell(section and section.items or {}, nil, section and section.key == "others")
		end, function() return PadWords("SELL_DESC") end, 18)
		header.sell:SetPoint("RIGHT", header, "RIGHT", -MoreRoom(), 0)
		header.value = W.Skin.Text(header, "GameTooltipTextSmall", "label")
		header.value:SetJustifyH("RIGHT")
		header.rule = header:CreateTexture(nil, "ARTWORK")
		header.rule:SetHeight(1)
		W.Skin.FadingRule(header.rule, 0.15)
		header.rule:SetPoint("LEFT", header.count, "RIGHT", 8, 0)
		header.rule:SetPoint("RIGHT", header.value, "LEFT", -8, 0)
		header.more = W.Skin.RowMore(header, function(frame) OpenCard(frame) end)
		header:SetScript("OnClick", function(frame, mouse)
			local section = frame.section
			if not (section and section.key) then return end
			if mouse == "RightButton" then
				OpenCard(frame)
			else
				ns.ToggleFolded(FoldKey(section.key))
			end
		end)
		header:HookScript("OnEnter", function(frame)
			frame.ground:SetColorTexture(1, 1, 1, W.Skin.HOVER or 0.05)
			local gold = W.Skin.COLORS.gold
			frame.chevron:SetVertexColor(gold[1], gold[2], gold[3])
			-- (its title or its worth cut short for want of room: whole, under the mouse)
			if frame.fullTitle then
				W.Skin.ShowTip(frame, { { frame.fullTitle, 1, 1, 1 }, frame.fullValue and { frame.fullValue, 1, 1, 1 } or nil }, "ANCHOR_TOP")
			end
		end)
		header:HookScript("OnLeave", function(frame)
			frame.ground:SetColorTexture(1, 1, 1, 0)
			local label = W.Skin.COLORS.label
			frame.chevron:SetVertexColor(label[1], label[2], label[3])
			if GameTooltip:IsOwned(frame) then GameTooltip:Hide() end
		end)
		W.Skin.Tooltip(header.more, function() return PadWords("SECTION_TIP") end, "ANCHOR_TOP")
		headers[index] = header
		return header
	end

	-- A title's line: its name takes what is left after the count, the worth, Sell and the "..." (cut short with
	-- "..."); short of room, the worth drops its auction part first (both whole under the mouse). width: the line's.
	local TITLE_LEAST = 60
	local function FitTitle(header, value, plain, width)
		local function Right()
			local sell = header.sell:IsShown() and (header.sell:GetWidth() or 0) + 8 or 0
			return MoreRoom() + sell + U.Measure(header.value, "GetStringWidth", 0)
		end
		header.text:SetWidth(0)
		local natural = U.Measure(header.text, "GetStringWidth", 0)
		local left = 18 + 6 + U.Measure(header.count, "GetStringWidth", 0) + 16
		local room = width - left - Right()
		header.fullTitle, header.fullValue = nil, nil
		if room < math.min(natural, TITLE_LEAST * 2) and plain ~= value then
			header.value:SetText(plain)
			header.fullValue = value
			room = width - left - Right()
		end
		if natural > room then
			header.text:SetWidth(math.max(TITLE_LEAST, room))
			header.fullTitle = header.text:GetText()
		elseif header.fullValue then
			header.fullTitle = header.text:GetText()
		end
	end

	-- Sections of squares, row by row; returns the height used.
	local function Layout(sections, settings)
		local size, columns = settings.iconSize, settings.columns
		local y, used = 0, 0
		local lineWidth = math.max(columns * (size + GAP) - GAP, 260)
		for _, section in ipairs(sections) do
			local folded = section.key and section.title and ns.IsFolded(FoldKey(section.key))
			-- (the free slots' square has no title: its count is in it)
			if section.title then
				used = used + 1
				local header = Header(used)
				header.section = section
				local plain = (section.value or 0) > 0 and W.Skin.Colorize(U.Coins(section.value), "label") or ""
				local value = plain
				if (section.auctionValue or 0) > 0 then
					value = value .. (value ~= "" and "   " or "") .. W.Skin.Colorize(L.AUCTION_VALUE:format(U.Coins(section.auctionValue)), "blue")
				end
				W.Skin.SetGlyph(header.chevron, folded and "chevron" or "down")
				header.text:SetText(Upper(section.title))
				header.count:SetText(tostring(section.count or #section.buttons))
				header.value:SetText(value)
				header:ClearAllPoints()
				header:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
				header:SetPoint("RIGHT", content, "RIGHT", 0, 0)
				header.sell:SetShown(section.sellable and W.IsMerchantOpen() or false)
				header.value:ClearAllPoints()
				if header.sell:IsShown() then
					header.value:SetPoint("RIGHT", header.sell, "LEFT", -8, 0)
				else
					header.value:SetPoint("RIGHT", header, "RIGHT", -MoreRoom(), 0)
				end
				FitTitle(header, value, plain, lineWidth)
				header:Show()
				y = y + HEADER_ROOM
			end
			if folded then
				for _, button in ipairs(section.buttons) do button:Hide() end
				y = y + SECTION_GAP - 4
			else
				for index, button in ipairs(section.buttons) do
					local column = (index - 1) % columns
					local row = math.floor((index - 1) / columns)
					button:ClearAllPoints()
					button:SetSize(size, size)
					button:SetPoint("TOPLEFT", content, "TOPLEFT", column * (size + GAP), -(y + row * (size + GAP)))
				end
				y = y + math.ceil(#section.buttons / columns) * (size + GAP) + SECTION_GAP
			end
		end
		for index = used + 1, #headers do
			headers[index]:Hide()
			headers[index].section = nil
		end
		return math.max(y - SECTION_GAP, size)
	end

	-- The window's width for a number of squares a row (its margins in).
	local function WidthFor(columns, settings)
		return columns * (settings.iconSize + GAP) - GAP + (W.Skin.Margin() + 8) * 2
	end

	-- Places that hold while the window is open: each item keeps its rank (the same item in the same slot) in its
	-- section, what comes later takes the next ones (at the end of its section), an item gone leaves its empty slot
	-- where it was (nothing slides under the mouse while you sell or deposit). Ranked anew as the window opens, and
	-- a moment after Sort. Returns the items and those places (hole: an empty slot), in their order.
	local places, nextRank -- "bag:slot" -> { id, section, rank }
	function self.ResetPlaces() places = nil end
	local function Steady(items, empty, settings)
		if not places or (self.resortUntil and GetTime() < self.resortUntil) then places, nextRank = {}, 0 end
		local entries, newcomers = {}, {}
		for _, item in ipairs(items) do
			-- (new items in their own section first, unless they stay in their place with the game's glow)
			item.section = item.fresh and not settings.newInPlace and "new" or item.group
			local place = places[Key(item)]
			if place and place.id == item.id and place.section == item.section then
				item.rank = place.rank
				entries[#entries + 1] = item
			else
				newcomers[#newcomers + 1] = item
			end
		end
		table.sort(newcomers, Before)
		for _, item in ipairs(newcomers) do
			nextRank = nextRank + 1
			item.rank = nextRank
			places[Key(item)] = { id = item.id, section = item.section, rank = nextRank }
			entries[#entries + 1] = item
		end
		for _, slot in ipairs(empty) do
			local place = places[Key(slot)]
			if place then entries[#entries + 1] = { hole = true, bag = slot.bag, slot = slot.slot, section = place.section, rank = place.rank } end
		end
		table.sort(entries, function(a, b) return a.rank < b.rank end)
		return entries
	end

	-- A special bag's free square (a quiver, a soul bag, a profession's bag): its bag's faint icon, its name and its
	-- count under the mouse.
	local function SpecialFree(button, bag, count)
		local name = Clean(Safe(C_Container.GetBagName, bag)) or ""
		button.wandererFreeTip = L.FREE_SPECIAL:format(name, count)
		local inventory = Clean(Safe(C_Container.ContainerIDToInventoryID, bag))
		local icon = inventory and Clean(Safe(_G.GetInventoryItemTexture, "player", inventory))
		if icon and SetItemButtonTexture and type(button.icon) == "table" and button.icon.SetAlpha then
			SetItemButtonTexture(button, icon)
			button.icon:SetAlpha(0.35)
			if button.icon.SetDesaturated then button.icon:SetDesaturated(true) end
			button.wandererFaint = true
		end
	end

	function self.Refresh()
		if not (window and window:IsShown()) then return end
		local settings = ns.Settings()
		if not settings then return end
		local query = Fold(searchBox:GetText() or "")
		local source = spec.source and spec.source()
		local pool = source and pools.saved or pools.live
		if pool ~= buttons then
			for _, list in pairs(buttons) do
				for _, button in pairs(list) do button:Hide() end
			end
			buttons = pool
		end
		local containers = spec.containers()
		local items, empty, total = {}, {}, 0
		local slotsOf, familyOf = {}, {}
		-- (the ordinary bags' slots: how full is said of them, a quiver or a soul bag apart)
		local plainTotal, plainFree = 0, 0
		for _, bag in ipairs(containers) do
			local slots = NumSlots(bag)
			slotsOf[bag] = slots
			familyOf[bag] = not source and slots > 0 and ns.BagFamily(bag) or 0
			for slot = 1, slots do
				total = total + 1
				if familyOf[bag] == 0 then plainTotal = plainTotal + 1 end
				local item = Read(bag, slot, source, spec.bank)
				if item then
					items[#items + 1] = item
				else
					empty[#empty + 1] = { bag = bag, slot = slot }
					if familyOf[bag] == 0 then plainFree = plainFree + 1 end
				end
			end
		end
		-- The chosen ones still there (the same item in the same slot); the others let go.
		local here = {}
		for _, item in ipairs(items) do here[Key(item)] = item end
		for key, item in pairs(picked) do
			local now = here[key]
			picked[key] = now and now.id == item.id and now or nil
		end
		-- Squares of containers gone or smaller: hidden.
		for bag, list in pairs(buttons) do
			for slot, button in pairs(list) do
				if slot > (slotsOf[bag] or 0) then button:Hide() end
			end
		end
		local sections = {}
		if settings.layout == "bags" then
			-- Container by container, in the game's order, empty slots in their place.
			local byBag = {}
			for _, item in ipairs(items) do byBag[item.bag] = byBag[item.bag] or {} byBag[item.bag][item.slot] = item end
			for _, bag in ipairs(containers) do
				if (slotsOf[bag] or 0) > 0 then
					local section = { key = "bag:" .. bag, title = spec.nameOf(bag), buttons = {} }
					for slot = 1, slotsOf[bag] do
						local button = Button(bag, slot)
						Paint(button, byBag[bag] and byBag[bag][slot], settings, query)
						section.buttons[#section.buttons + 1] = button
					end
					sections[#sections + 1] = section
				end
			end
		else
			-- By kind: what just came first, then each kind its section (in your order, the pinned ones first), each
			-- item in its place while the window is open (Steady); the empty slots in one square at the end, a special
			-- bag's apart.
			local byKind = {}
			for _, entry in ipairs(Steady(items, empty, settings)) do
				byKind[entry.section] = byKind[entry.section] or {}
				table.insert(byKind[entry.section], entry)
			end
			local order = {}
			for _, kind in ipairs(CATEGORY_ORDER) do
				if kind == "custom" then
					-- Your sections, in your order.
					for _, name in ipairs(ns.MarksDB().sections or {}) do order[#order + 1] = ns.CUSTOM .. name end
				elseif kind == "professions" then
					-- Your professions, by name.
					local mine = {}
					for group in pairs(byKind) do
						if group:find(PROFESSION, 1, true) == 1 then mine[#mine + 1] = group end
					end
					table.sort(mine)
					for _, group in ipairs(mine) do order[#order + 1] = group end
				else
					order[#order + 1] = kind
				end
			end
			if ns.ArrangeSections then order = ns.ArrangeSections(self.where, order) end
			local held = {} -- the empty slots keeping an item's place in its section
			for _, kind in ipairs(order) do
				local entries, real = byKind[kind] or {}, {}
				for _, entry in ipairs(entries) do
					if not entry.hole then real[#real + 1] = entry end
				end
				-- (a section left with nothing but places: gone)
				if real[1] then
					local section = { key = kind, title = KindName(kind), buttons = {}, items = real, count = #real, value = 0,
						sellable = spec.canSell and not source and SELLABLE[kind] }
					for _, entry in ipairs(entries) do
						local button = Button(entry.bag, entry.slot)
						section.buttons[#section.buttons + 1] = button
						if entry.hole then
							held[Key(entry)] = true
							Paint(button, nil, settings, query)
						else
							Paint(button, entry, settings, query)
							-- (what is never sold counts for nothing: the sale leaves it aside)
							if SELLABLE[kind] and not ns.NeverSold(entry.id) then section.value = section.value + (U.SellPrice(entry.link) or 0) * entry.count end
							if AUCTION_VALUE[kind] then
								local price = ns.AuctionPrice(entry.link)
								if price then section.auctionValue = (section.auctionValue or 0) + price * entry.count end
							end
						end
					end
					sections[#sections + 1] = section
				end
			end
			-- The first empty slot of a kind of bag stands for all of them: something dropped on it goes there (its
			-- count in it). The ordinary bags' first, then each special bag's (its faint icon, its name under the mouse).
			local free, families = {}, {}
			for _, slot in ipairs(empty) do
				local family = familyOf[slot.bag] or 0
				local of = free[family]
				if not of then
					of = { count = 0 }
					free[family] = of
					families[#families + 1] = family
				end
				of.count = of.count + 1
				if not held[Key(slot)] then
					if of.slot then Button(slot.bag, slot.slot):Hide() else of.slot = slot end
				end
			end
			table.sort(families)
			local squares = {}
			for _, family in ipairs(families) do
				local of = free[family]
				if of.slot then
					local button = Button(of.slot.bag, of.slot.slot)
					Paint(button, nil, settings, "", of.count)
					if family ~= 0 then SpecialFree(button, of.slot.bag, of.count) end
					squares[#squares + 1] = button
				end
			end
			if squares[1] then sections[#sections + 1] = { key = "free", buttons = squares, count = plainFree } end
		end
		self.shownKeys = {}
		for _, section in ipairs(sections) do
			if section.title then self.shownKeys[#self.shownKeys + 1] = section.key end
		end
		local height = sections[1] and Layout(sections, settings) or settings.iconSize
		if not sections[1] then for index = 1, #headers do headers[index]:Hide() end end
		-- The items as drawn, in their order (Shift+click chooses a run of them).
		shown = {}
		for _, section in ipairs(sections) do
			if not (section.key and section.title and ns.IsFolded(FoldKey(section.key))) then
				for _, button in ipairs(section.buttons) do
					if button.wandererItem then shown[#shown + 1] = button.wandererItem end
				end
			end
		end
		local margin = W.Skin.Margin() + 8
		-- How full: beside the title (used of all), and the free slots in the footer (the ordinary bags': a quiver,
		-- a soul bag, a profession's bag each have their own square).
		countText:SetText(L.USED_SLOTS:format(plainTotal - plainFree, plainTotal))
		freeText:SetText(L.FREE_SLOTS:format(plainFree))
		elsewhereShown = false
		-- (bags nearly full: the line in amber, its tooltip naming the cheapest things carried)
		roomTip = nil
		if spec.canSell and not source and ns.NearlyFull(plainFree, plainTotal) then
			freeText:SetText(W.Skin.Colorize(L.FREE_SLOTS:format(plainFree), "warn"))
			local cheapest = ns.Cheapest(items)
			if cheapest[1] then
				roomTip = { L.ROOM_TITLE, { L.ROOM_DESC, 0.8, 0.8, 0.8 } }
				for _, item in ipairs(cheapest) do
					local name = item.count > 1 and L.ROOM_ITEM_COUNT:format(item.name, item.count) or item.name
					roomTip[#roomTip + 1] = name .. U.SEPARATOR .. U.Coins(item.value)
				end
			end
		end
		self.Money()
		-- The arrangement shown, in gold (the other one beside it, a click away).
		layoutPair:Select(settings.layout == "bags" and "bags" or "categories")
		sortButton:SetShown(spec.sort ~= nil and (not spec.canSort or spec.canSort()) or false)
		-- (the window's own words: a bank seen before says when, in the free slots' place)
		if spec.onRefresh then spec.onRefresh(window, total, items) end
		-- (then the footer placed: its own tools shown or not by then)
		self.PlaceFooter()
		-- (that line kept for after a search; a search going on: its line instead)
		self.lastFree = freeText:GetText()
		if (searchBox:GetText() or "") ~= "" then self.Search(true) end
		local width = math.max(settings.columns * (settings.iconSize + GAP) - GAP, 260, self.BarWidth() - margin * 2,
			self.FooterWidth())
		content:SetSize(width, height)
		-- A character who never marked anything: how, said over the footer (gone once the window closes).
		local hintRoom = 0
		if hintText then
			local showHint = not selecting and ns.MarkHintShown() or false
			hintText:SetShown(showHint)
			if showHint then
				-- (a controller in hand: its own button named)
				hintText:SetText(U and U.UsingPad and U.UsingPad() and L.MARK_HINT_PAD or L.MARK_HINT)
				hintText:SetWidth(width)
				hintRoom = U.Measure(hintText, "GetStringHeight", 12) + 6
				hintShown = true
			end
		end
		if bar then
			bar:ClearAllPoints()
			bar:SetPoint("BOTTOMLEFT", window, "BOTTOMLEFT", margin, margin + BOTTOM_ROOM + hintRoom)
		end
		local barHeight = bar and self.LayoutBar(width) or 0
		local fullHeight = height + TOP_ROOM + BOTTOM_ROOM + hintRoom + barHeight + margin * 2
		window:SetSize(width + margin * 2, fullHeight)
		-- (widened by its corner: from six squares a row, or what its heading and footer need, to sixteen; its
		-- height its own)
		if window.SetResizeBounds then
			local least = math.max(WidthFor(MIN_COLUMNS, settings), math.max(260, self.BarWidth() - margin * 2, self.FooterWidth()) + margin * 2)
			pcall(window.SetResizeBounds, window, least, fullHeight, math.max(WidthFor(MAX_COLUMNS, settings), width + margin * 2), fullHeight)
		end
		self.ChainLinks()
		W.Skin.Get(window):Layout()
	end

	-- The room the title and the links shown take on the window's first line (the margins included).
	function self.BarWidth()
		local total = 0
		for _, link in ipairs(links) do
			if link:IsShown() then total = total + (link:GetWidth() or 0) + 6 end
		end
		local title = window.titleText and U.Measure(window.titleText, "GetStringWidth", 0) or 0
		local count = countText and U.Measure(countText, "GetStringWidth", 0) + 10 or 0
		return total + title + count + W.Skin.Margin() * 2 + 30 + 12 + (window.help and 24 or 0) + (self.cogRoom or 0)
	end

	-- The room the footer needs: its pieces (the sorting, the arrangement or its own tools), a short free line, the gold.
	function self.FooterWidth()
		local used = 0
		for _, piece in ipairs(self.FooterPieces()) do used = used + (piece:GetWidth() or 0) + 8 end
		local money = moneyText and U.Measure(moneyText, "GetStringWidth", 0) or 0
		return used + 4 + 56 + 12 + money
	end

	-- The links shown, right to left from the "?" and the cross, without a gap for the hidden ones.
	function self.ChainLinks()
		local previous
		for _, link in ipairs(links) do
			link:ClearAllPoints()
			if link:IsShown() then
				if previous then
					link:SetPoint("RIGHT", previous, "LEFT", -6, 0)
				else
					link:SetPoint("TOPRIGHT", window, "TOPRIGHT", -(W.Skin.Margin() + 30 + (window.help and 22 or 0) + (self.cogRoom or 0)),-(W.Skin.Margin() + 6))
				end
				previous = link
			end
		end
	end

	local soon = U.Debounce(REFRESH_DELAY, function() self.Refresh() end)
	function self.Soon()
		if window and window:IsShown() then soon() end
	end

	-- What changes often, touched alone (no drawing again): each button shown.
	local function EachShown(fn)
		for _, pool in pairs(pools) do
			for _, list in pairs(pool) do
				for _, button in pairs(list) do
					if button:IsShown() then fn(button) end
				end
			end
		end
	end

	-- The cooldowns (each global cooldown in a fight).
	function self.Cooldowns()
		if not (window and window:IsShown()) then return end
		EachShown(function(button)
			if button.UpdateCooldown then pcall(button.UpdateCooldown, button, button.wandererItem ~= nil) end
		end)
	end

	-- An item taken or let go by the cursor: its button alone.
	function self.Lock(bag, slot)
		if not (window and window:IsShown()) then return end
		local button = bag and slot and pools.live[bag] and pools.live[bag][slot]
		if not (button and button:IsShown() and SetItemButtonDesaturated) then return end
		local info = Safe(C_Container.GetContainerItemInfo, bag, slot)
		SetItemButtonDesaturated(button, type(info) == "table" and Clean(info.isLocked) and true or false)
	end

	-- Your money, or the window's own (a bank that keeps none: nothing).
	function self.Money()
		if not (moneyText and window:IsShown()) then return end
		local copper
		if spec.money then copper = spec.money() else copper = Clean(Safe(GetMoney)) end
		moneyText:SetText(copper and U.Coins(copper) or "")
	end

	-- The search: what does not match steps back (nothing read again; lineOnly: the squares just drawn with it).
	function self.Search(lineOnly)
		if not (window and window:IsShown()) then return end
		local query = Fold(searchBox:GetText() or "")
		if not lineOnly then EachShown(function(button) Dim(button, query) end) end
		-- What your other characters have of it, in the free slots' place while you search.
		local elsewhere = query ~= "" and Plain(query) and ns.CarriedElsewhere(query) or nil
		elsewhereShown = elsewhere ~= nil
		if elsewhere then
			freeText:SetText(elsewhere)
		elseif self.lastFree then
			freeText:SetText(self.lastFree)
		end
	end

	-- The selection ---------------------------------------------------------------------------

	-- An item chosen or let go; with Shift, every item drawn from the last one chosen to this one.
	function self.TogglePick(item, run)
		if not item then return end
		if run and lastPicked then
			local from, to
			for index, other in ipairs(shown) do
				if Key(other) == lastPicked then from = index end
				if Key(other) == Key(item) then to = index end
			end
			if from and to then
				for index = math.min(from, to), math.max(from, to) do picked[Key(shown[index])] = shown[index] end
				lastPicked = Key(item)
				return self.Refresh()
			end
		end
		local key = Key(item)
		picked[key] = not picked[key] and item or nil
		lastPicked = picked[key] and key or lastPicked
		W.Skin.Play("click")
		self.Refresh()
	end

	function self.SetSelecting(on)
		selecting = on and true or false
		wipe(picked)
		lastPicked = nil
		if selectButton then selectButton:SetText(selecting and L.SELECT_DONE or L.SELECT) end
		if window and window:IsShown() then self.Refresh() end
	end

	local function Chosen()
		local list, ids, seen = {}, {}, {}
		for _, item in pairs(picked) do
			list[#list + 1] = item
			if item.id and not seen[item.id] then seen[item.id], ids[#ids + 1] = true, item.id end
		end
		table.sort(list, function(a, b) return a.bag * 1000 + a.slot < b.bag * 1000 + b.slot end)
		return list, ids
	end

	local function Clear()
		wipe(picked)
		lastPicked = nil
		self.Refresh()
	end

	-- What the bar offers, in two lines: what can be done here first (at a merchant, the banker, the auction
	-- house), then your say over the items, always.
	local ACTIONS = {
		-- (sold: the selection cleared once the sale is accepted)
		{ key = "sell", group = "here", label = "SELL", when = function() return W.IsMerchantOpen() end,
			tip = "ACT_SELL_DESC", keep = true, run = function(list)
				-- (sold by lots of twelve: those sold let go, the rest still chosen for the next click)
				Sell(list, function(lot)
					for _, entry in ipairs(lot) do picked[Key(entry)] = nil end
					if next(picked) then self.Refresh() else Clear() end
				end)
			end },
		-- (deposited: what really went in let go, the rest, a full bank's, still chosen)
		{ key = "deposit", group = "here", label = "ACT_DEPOSIT", when = function() return ns.AtBank() end, keep = true,
			run = function(list)
				ns.DepositChosen(list, function(moved)
					for _, entry in ipairs(moved) do picked[Key(entry)] = nil end
					if next(picked) then self.Refresh() else Clear() end
				end)
			end },
		{ key = "search", group = "here", label = "ACT_SEARCH", when = function(count)
				local frame = _G.AuctionHouseFrame
				local api = ns.Auction()
				return count == 1 and api and api.Search and frame and frame:IsShown()
			end,
			run = function(list) if list[1].name ~= "" then WandererAuction.Search(list[1].name) end end },
		{ key = "keep", group = "marks", label = "ACT_KEEP", run = function(_, ids) ns.MarkMany(ids, "keep") end },
		{ key = "auction", group = "marks", label = "FOR_AUCTION", tip = "ACT_AUCTION_DESC", run = function(_, ids) ns.MarkMany(ids, "auction") end },
		{ key = "junk", group = "marks", label = "ACT_JUNK", run = function(_, ids) ns.MarkMany(ids, "junk") end },
		{ key = "bank", group = "marks", label = "ACT_BANK", run = function(_, ids) ns.MarkMany(ids, "bank") end },
		{ key = "section", group = "marks", label = "ACT_SECTION", keep = true, run = function(_, ids, link) ns.SectionsMenu(link, ids, Clear) end },
		{ key = "free", group = "marks", label = "ACT_FREE", run = function(_, ids) ns.FreeMany(ids) end },
	}

	-- The bar, over the footer while selecting: how many are chosen, all or none, then what to do with them.
	-- Returns its height (0 when not selecting).
	function self.LayoutBar(width)
		if not selecting then
			bar:Hide()
			return 0
		end
		local count = 0
		for _ in pairs(picked) do count = count + 1 end
		bar.count:SetText(count > 0 and L.PICKED:format(count) or (U.UsingPad and U.UsingPad()) and L.PICK_HINT_PAD or L.PICK_HINT)
		local x, y, line, group = 0, 24, 26, nil
		for _, action in ipairs(ACTIONS) do
			local link = bar.links[action.key]
			local show = not action.when or action.when(count) or false
			link:SetShown(show)
			if show then
				link:SetAlpha(count > 0 and 1 or 0.45)
				local w = link:GetWidth() or 60
				-- A new line for each group, and when the width is full.
				if x > 0 and (x + w > width or action.group ~= group) then x, y = 0, y + line end
				group = action.group
				link:ClearAllPoints()
				link:SetPoint("TOPLEFT", bar, "TOPLEFT", x, -y)
				x = x + w + 4
			end
		end
		local height = y + line + 6
		bar:SetSize(width, height)
		bar:Show()
		return height
	end

	local function CreateBar(margin)
		bar = CreateFrame("Frame", nil, window)
		bar:SetPoint("BOTTOMLEFT", window, "BOTTOMLEFT", margin, margin + BOTTOM_ROOM)
		bar.rule = W.Skin.Rule(bar, false, 0.2)
		bar.rule:SetPoint("TOPLEFT")
		bar.rule:SetPoint("TOPRIGHT")
		bar.count = W.Skin.Text(bar, "GameTooltipTextSmall", "label")
		bar.count:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, -6)
		bar.none = W.Skin.SmallButton(bar, L.SELECT_NONE, Clear)
		bar.none:SetPoint("TOPRIGHT", bar, "TOPRIGHT", 0, -2)
		bar.all = W.Skin.SmallButton(bar, L.SELECT_ALL, function()
			-- (a search typed: only what it finds)
			local query = Fold(searchBox:GetText() or "")
			for _, item in ipairs(shown) do
				if Matches(item, query) then picked[Key(item)] = item end
			end
			self.Refresh()
		end)
		bar.all:SetPoint("RIGHT", bar.none, "LEFT", -4, 0)
		bar.links = {}
		for _, action in ipairs(ACTIONS) do
			local link
			link = W.Skin.SmallButton(bar, L[action.label], function()
				local list, ids = Chosen()
				if not list[1] then return end
				action.run(list, ids, link)
				-- Done: the selection cleared (the sale and the section's card clear it once a choice is made).
				if not action.keep then Clear() end
			end, L[action.tip or action.label .. "_DESC"])
			bar.links[action.key] = link
		end
		bar:Hide()
	end

	-- The footer strip: a thin rule; the sorting and the arrangement (the one shown in gold) on the left, the free
	-- slots after them (in amber when nearly full; during a search, what your other characters carry), the gold on
	-- the right.
	local function CreateFooter(margin)
		local rule = W.Skin.Rule(window, false, 0.14)
		rule:SetPoint("BOTTOMLEFT", window, "BOTTOMLEFT", margin, margin + BOTTOM_ROOM - 4)
		rule:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -margin, margin + BOTTOM_ROOM - 4)
		sortButton = W.Skin.SmallButton(window, L.SORT, function()
			if not spec.sort then return end
			-- (sorted: every place ranked anew while the game moves the items)
			self.resortUntil = GetTime() + RESORT_TIME
			self.ResetPlaces()
			spec.sort()
		end, spec.sortTip or L.SORT_DESC, 22)
		sortButton:SetPoint("BOTTOMLEFT", window, "BOTTOMLEFT", margin, margin - 2)
		layoutPair = W.Skin.Choices(window, { { "categories", L.MODE_CATEGORIES }, { "bags", L.MODE_BAGS } }, function(key)
			-- (in every profile of this character, as the options page does)
			local settings = ns.Settings()
			if not settings or settings.layout == key then return end
			W.ChangeEverywhere(function() ns.Settings().layout = key end)
			ns.RefreshAll()
		end, 22)
		for _, choice in ipairs(layoutPair.buttons) do
			W.Skin.Tooltip(choice, choice.key == "bags" and L.MODE_BAGS_DESC or L.MODE_CATEGORIES_DESC, "ANCHOR_TOP")
		end
		layoutPair:SetPoint("BOTTOMLEFT", window, "BOTTOMLEFT", margin, margin - 2)
		moneyText = W.Skin.Text(window, "GameTooltipText", "text")
		moneyText:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -margin, margin + 2)
		freeText = W.Skin.Text(window, "GameTooltipTextSmall", "muted")
		freeText:SetPoint("LEFT", layoutPair, "RIGHT", 12, 0)
		freeText:SetPoint("RIGHT", moneyText, "LEFT", -12, 0)
		if freeText.SetWordWrap then freeText:SetWordWrap(false) end
		window.freeText = freeText
		local room = CreateFrame("Frame", nil, window)
		room:SetAllPoints(freeText)
		room:EnableMouse(true)
		room.padTip = true -- (a controller reaches it to read it)
		-- (nearly full: the cheapest things carried; a search: what your other characters have, whole)
		W.Skin.Tooltip(room, function()
			if elsewhereShown then return freeText:GetText() end
			return roomTip
		end, "ANCHOR_TOP")
		window.room = room
	end

	-- The footer's pieces shown, left to right: Sort, then the arrangement or the window's own tools.
	local footTools = {}
	function self.FooterPieces()
		local list = {}
		if sortButton:IsShown() then list[#list + 1] = sortButton end
		if spec.footTools then
			for _, tool in ipairs(footTools) do
				if tool:IsShown() then list[#list + 1] = tool end
			end
		else
			list[#list + 1] = layoutPair
		end
		return list
	end

	-- The footer's pieces placed again, without a gap for the hidden ones; the free slots' line after them.
	local function PlaceFooter(margin)
		layoutPair:SetShown(not spec.footTools)
		local previous
		for _, piece in ipairs(self.FooterPieces()) do
			piece:ClearAllPoints()
			if previous then
				piece:SetPoint("LEFT", previous, "RIGHT", 8, 0)
			else
				piece:SetPoint("BOTTOMLEFT", window, "BOTTOMLEFT", margin, margin - 2)
			end
			previous = piece
		end
		freeText:ClearAllPoints()
		if previous then
			freeText:SetPoint("LEFT", previous, "RIGHT", 12, 0)
		else
			freeText:SetPoint("BOTTOMLEFT", window, "BOTTOMLEFT", margin, margin + 2)
		end
		freeText:SetPoint("RIGHT", moneyText, "LEFT", -12, 0)
	end

	local function Create()
		window = W.Skin.CreateWindow(spec.name, "MEDIUM")
		if spec.sounds then W.Skin.Sounds(window, spec.sounds[1], spec.sounds[2]) end
		W.Skin.Dress(window, spec.point, spec.name .. "Pos")
		local _, title, margin = Heading(window, spec.title, spec.settings)
		window.titleText = title
		-- How full, beside the title: quiet.
		countText = W.Skin.Text(window, "GameTooltipTextSmall", "muted")
		countText:SetPoint("BOTTOMLEFT", title, "BOTTOMRIGHT", 8, 1)
		-- What can be done here, said once: a "?" by the cross (by the cog, when Wanderer draws one), Wanderer's
		-- heading corner.
		local cog = window.cog
		cog = type(cog) == "table" and cog.IsShown and cog or nil
		self.cogRoom = cog and 24 or 0
		if spec.help then
			local help = W.Skin.Help(window, spec.help, "HEADING")
			-- (with a controller: spec.helpPad, its buttons instead of the mouse's)
			if help and spec.helpPad then
				help:HookScript("OnEnter", function(frame)
					if U.UsingPad and U.UsingPad() then W.Skin.ShowTip(frame, spec.helpPad, "ANCHOR_BOTTOM") end
				end)
			end
		end
		-- Its links, right to left from the "?": only what depends on where you are.
		if spec.padClose and W.Skin.PadWindow then W.Skin.PadWindow(window, { closeBinding = spec.padClose }) end
		if spec.actions then spec.actions(window, function(link) links[#links + 1] = link end) end
		self.ChainLinks()
		-- Choosing several items (or one) to act on them together, without Alt: a button of its own, beside
		-- the search, where it is seen.
		if spec.selectable then
			selectButton = W.Skin.Button(window, L.SELECT_DONE, function() self.SetSelecting(not selecting) end)
			-- As wide as the longer of its two words ("Select", "Done").
			local done = selectButton:GetWidth()
			selectButton:SetText(L.SELECT)
			selectButton:Fit()
			selectButton:SetWidth(math.max(done, selectButton:GetWidth()))
			selectButton:SetHeight(22)
			selectButton:SetPoint("RIGHT", window, "RIGHT", -margin, 0)
			selectButton:SetPoint("TOP", title, "BOTTOM", 0, -7)
			W.Skin.Tooltip(selectButton, function() return PadWords("SELECT_DESC") end, "ANCHOR_BOTTOM")
		end
		-- The search, the whole width (up to the selection's button).
		searchBox = W.Skin.CreateInput(window, spec.name .. "Search", 40, {
			hint = L.SEARCH,
			onChange = function() self.Search() end,
			onEscape = function(box)
				box:SetText("")
				box:ClearFocus()
			end,
		})
		searchBox:SetHeight(20)
		-- (its words, under the mouse: levels, qualities, signs)
		local ink = W.Skin.COLORS.text
		W.Skin.Tooltip(searchBox, { L.SEARCH_HELP_TITLE, { L.SEARCH_HELP, ink[1], ink[2], ink[3] } }, "ANCHOR_BOTTOM")
		searchBox:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
		if selectButton then
			searchBox:SetPoint("RIGHT", selectButton, "LEFT", -6, 0)
		else
			searchBox:SetPoint("RIGHT", window, "RIGHT", -margin, 0)
		end
		content = CreateFrame("Frame", nil, window)
		content:SetPoint("TOPLEFT", window, "TOPLEFT", margin, -(margin + TOP_ROOM))
		CreateFooter(margin)
		if spec.footTools then spec.footTools(window, function(tool) footTools[#footTools + 1] = tool end) end
		if spec.markHint then
			hintText = W.Skin.Text(window, "GameTooltipTextSmall", "muted")
			hintText:SetPoint("BOTTOMLEFT", window, "BOTTOMLEFT", margin, margin + BOTTOM_ROOM + 2)
			hintText:SetText(L.MARK_HINT)
			hintText:Hide()
		end
		if spec.selectable then CreateBar(margin) end
		-- Widened by its corner: a whole row of squares at a time, said while dragged; let go, the window takes the
		-- exact width of its rows (the option's slider says the same number).
		local function ColumnsAt(width)
			local settings = ns.Settings()
			if not settings then return nil end
			local columns = math.floor((width - margin * 2 + GAP) / (settings.iconSize + GAP))
			return W.Skin.Within(columns, MIN_COLUMNS, MAX_COLUMNS)
		end
		rowsText = W.Skin.Text(window, "GameTooltipTextSmall", "muted")
		rowsText:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -margin, margin + BOTTOM_ROOM + 2)
		rowsText:Hide()
		W.Skin.Resizable(window, {
			minWidth = 200, minHeight = 120, maxWidth = 2000, maxHeight = 2400,
			onStart = function() rowsText:Show() end,
			onSizing = function()
				local columns = ColumnsAt(window:GetWidth() or 0)
				if columns then rowsText:SetText((spec.bank and L.PER_ROW_BOTH or L.PER_ROW):format(columns)) end
			end,
			onResized = function(width)
				rowsText:Hide()
				local columns = ColumnsAt(width)
				-- (the same number: the window takes the exact width of its rows again)
				local settings = ns.Settings()
				if columns and settings and settings.columns ~= columns then
					W.ChangeEverywhere(function() ns.Settings().columns = columns end)
				end
				ns.RefreshAll()
			end,
		})
		window:HookScript("OnShow", function(frame)
			frame:SetScale(W.Skin.FitScale(frame))
			self.Refresh()
			if spec.onShow then spec.onShow() end
		end)
		window:HookScript("OnHide", function()
			-- Closed: the selection ends, the places are ranked anew at the next opening.
			if selecting then self.SetSelecting(false) end
			self.ResetPlaces()
			-- (the Alt+click line seen once: not again)
			if hintShown then ns.MarkHintSeen() end
			-- Closed: the new items are new no more.
			if C_NewItems and C_NewItems.RemoveNewItem then
				for bag, list in pairs(pools.live) do
					for slot in pairs(list) do Safe(C_NewItems.RemoveNewItem, bag, slot) end
				end
			end
			if spec.onHide then spec.onHide() end
		end)
		-- Every square of what is there made now, out of a fight.
		if not (spec.source and spec.source()) then
			for _, bag in ipairs(spec.containers()) do
				for slot = 1, NumSlots(bag) do Button(bag, slot):Hide() end
			end
		end
		self.window = window
		self.PlaceFooter = function() PlaceFooter(margin) end
		self.parts = { pair = layoutPair, sort = sortButton, count = countText, free = freeText, headers = headers, rows = rowsText }
	end

	local function Window()
		if not window then Create() end
		return window
	end

	function self.Open()
		if Window():IsShown() then self.Soon() else window:Show() end
	end

	function self.Close()
		if window then window:Hide() end
	end

	function self.IsShown() return window and window:IsShown() or false end
	self.On = spec.on

	ns.INVENTORIES[#ns.INVENTORIES + 1] = self
	return self
end

-- A setting changed: every window drawn again, or closed when no longer in use.
function ns.RefreshAll()
	for _, inventory in ipairs(ns.INVENTORIES) do
		if inventory.On() then inventory.Refresh() else inventory.Close() end
	end
	ns.RefreshBankFrame()
end
