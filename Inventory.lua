local _, ns = ...
local L = ns.L

-- The engine shared by the bags and the bank: one window drawn by Wanderer's
-- engine (its style, its profiles), the items of a list of containers sorted
-- by kind (gear, consumables, crafting, quests, the rest, junk at the end) or
-- container by container. The squares are the game's own item buttons: a
-- right click uses (or moves between bags and bank), a drag moves, the
-- tooltip, the cooldowns and the new items glow as in the game. Gear better
-- for the branch you play wears Wanderer's green arrow.

local W = Wanderer
local U = W and W.Util
local Safe, Clean = U and U.Safe, U and U.Clean
local Upper = U and U.Upper or string.upper -- capitals in every language (an older Wanderer: the game's own)

local GAP = 4
local SECTION_GAP = 10
local HEADER_HEIGHT = 14
local TOP_ROOM = 64 -- heading, search
local BOTTOM_ROOM = 26 -- free slots, gold
local REFRESH_DELAY = 0.05 -- many updates at once: one drawing

local CATEGORY_ORDER = { "new", "custom", "gear", "consumable", "professions", "alts", "trade", "quest", "other", "auction", "others", "junk", "kept" }
local PROFESSION = "profession:" -- a section of one of your professions: this, then its name
ns.CUSTOM = "custom:" -- a section of yours: this, then its name
local SELLABLE = { junk = true, others = true } -- what a merchant may take, a link away
local LOCK_MARK = "Interface\\PetBattles\\PetBattle-LockIcon"
local AUCTION_MARK = "Interface\\Minimap\\Tracking\\Auctioneer"
local AUCTION_VALUE = { auction = true, others = true } -- what the auction house would pay (Auctionator's prices)
local TRADE = { [3] = true, [5] = true, [7] = true, [9] = true } -- gems, reagents, trade goods, recipes
local CONSUMABLE = { [0] = true, [6] = true } -- consumables, projectiles
local WEAPON, ARMOR, QUEST = 2, 4, 12
local POOR = 0

local function Container() return C_Container or {} end

-- The slots of a container (none when it is not there).
function ns.NumSlots(bag)
	return Clean(Safe(Container().GetContainerNumSlots, bag)) or 0
end

ns.INVENTORIES = {}

local function KindName(kind)
	if kind:find(PROFESSION, 1, true) == 1 then return kind:sub(#PROFESSION + 1) end
	if kind:find(ns.CUSTOM, 1, true) == 1 then return kind:sub(#ns.CUSTOM + 1) end
	return L["CAT_" .. kind:upper()]
end

-- A crafting reagent's section, from what Wanderer knows of the professions using it: the one of yours with the most
-- recipes using it, else your other characters', else the other professions'; plain crafting when none is known.
local function CraftingGroup(id)
	local settings = ns.Settings()
	if not (id and settings and settings.byProfession and W.ReagentUses) then return "trade" end
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

-- Where an item goes: its kind's section, crafting by profession, then your say over it (your section, junk,
-- for the auction house, or kept: their own section, at the bottom).
function ns.Group(kind, id)
	local group = kind == "trade" and CraftingGroup(id) or kind
	local placed = ns.Placed and ns.Placed(id)
	if placed then return ns.CUSTOM .. placed end
	local mark = ns.Mark and ns.Mark(id)
	if mark == "junk" then return "junk" end
	if mark == "auction" then return "auction" end
	-- Kept: together at the bottom, out of the way (they never move).
	if mark == "keep" then return "kept" end
	return group
end

function ns.Settings()
	return W and W.Settings("bags")
end

local function LiveInfo(bag, slot) return Safe(Container().GetContainerItemInfo, bag, slot) end

-- One item of a slot: what to sort it by and where it goes. Read in the bags,
-- or from a source (a bank seen before), where nothing is new or for a quest.
local function Read(bag, slot, source)
	local info = (source or LiveInfo)(bag, slot)
	if type(info) ~= "table" then return nil end
	local id = Clean(info.itemID)
	local link = Clean(info.hyperlink)
	local quality = Clean(info.quality) or 1
	local _, _, _, equip, _, class = Safe(C_Item and C_Item.GetItemInfoInstant or GetItemInfoInstant, id or 0)
	equip, class = Clean(equip), Clean(class)
	local quest = not source and Safe(Container().GetContainerItemQuestInfo, bag, slot) or nil
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
	local name = link and link:match("%[(.-)%]") or ""
	local level = kind == "gear" and link and Clean(Safe(C_Item and C_Item.GetDetailedItemLevelInfo, link)) or 0
	return { bag = bag, slot = slot, id = id, link = link, kind = kind, quality = quality, name = name, level = level,
		count = Clean(info.stackCount) or 1, info = info, quest = quest,
		fresh = not source and C_NewItems and Clean(Safe(C_NewItems.IsNewItem, bag, slot)) and true or false,
		group = ns.Group(kind, id) }
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

-- The search: by name, or by a word of the kind ("quest", "junk"...).
local function Matches(item, query)
	if query == "" then return true end
	if item.name:lower():find(query, 1, true) then return true end
	if KindName(item.kind):lower():find(query, 1, true) then return true end
	return KindName(item.group):lower():find(query, 1, true) ~= nil
end

-- A small text link, gold when hovered: Wanderer's own.
function ns.TextButton(parent, text, onClick, tooltip) return W.Skin.CreateLink(parent, text, onClick, tooltip) end

-- An inventory window ------------------------------------------------------------------------
-- spec: name (of its frame), title, on() (in use), containers() -> { bag ids }, nameOf(bag)
-- (its section title by container), point (where it first opens), sounds,
-- money() (the copper shown, the player's by default), actions(window, add) to put links
-- in its heading, onRefresh(window, total, items) (the items just read), onHide(); source() (items read elsewhere than
-- in the bags: (bag, slot) -> info) and numSlots(bag) for what is not at hand.

function ns.NewInventory(spec)
	local self = {}
	local window, content, searchBox, freeText, moneyText, modeButton
	local bagFrames, headers, links = {}, {}, {}
	-- The game's squares for what is at hand, plain ones for what is only seen.
	local pools = { live = {}, saved = {} }
	local buttons = pools.live
	local NumSlots = spec.numSlots or ns.NumSlots
	local pending = false
	-- The selection (spec.selectable): a click chooses an item instead of using it, the bar acts on all chosen.
	local selecting, picked, shown, lastPicked = false, {}, {}, nil
	local selectButton, bar
	local function Key(item) return item.bag .. ":" .. item.slot end

	local function BagFrame(bag)
		local frame = bagFrames[bag]
		if frame then return frame end
		frame = CreateFrame("Frame", nil, content)
		frame:SetAllPoints(content)
		frame:SetID(bag)
		bagFrames[bag] = frame
		return frame
	end

	-- A square of what is only seen: its tooltip and its link, nothing to move.
	local function SavedButton()
		local button = CreateFrame("ItemButton", nil, content)
		button:SetScript("OnEnter", function(square)
			if not square.wandererLink then return end
			GameTooltip:SetOwner(square, "ANCHOR_RIGHT")
			GameTooltip:SetHyperlink(square.wandererLink)
			GameTooltip:Show()
		end)
		button:SetScript("OnLeave", function() GameTooltip:Hide() end)
		button:SetScript("OnClick", function(square)
			if IsAltKeyDown() and square.wandererItem then
				return ns.ItemMenu(square, square.wandererItem)
			end
			if square.wandererLink and HandleModifiedItemClick then HandleModifiedItemClick(square.wandererLink) end
		end)
		return button
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
			-- Alt and a click (a modified one: nothing taken, nothing used) opens your say over the item.
			button:HookScript("OnMouseUp", function(square)
				if IsAltKeyDown() and square.wandererItem then return ns.ItemMenu(square, square.wandererItem) end
				-- Kept, where it could be sold: the click is refused, and said why.
				if square.wandererGuarded and UIErrorsFrame then
					local item = square.wandererItem
					local auction = item and ns.IsForAuction and ns.IsForAuction(item.id)
					UIErrorsFrame:AddMessage(auction and L.AUCTION_BLOCKED or L.KEPT_BLOCKED, 1, 0.1, 0.1)
				end
			end)
			-- Kept: said in its tooltip, with how to free it.
			button:HookScript("OnEnter", function(square)
				local item = square.wandererItem
				if not (item and GameTooltip:IsOwned(square)) then return end
				local tip = (ns.IsKept and ns.IsKept(item.id) and L.KEPT_TIP) or (ns.IsForAuction and ns.IsForAuction(item.id) and L.AUCTION_TIP)
				if tip then
					GameTooltip:AddLine(tip, 0.62, 0.74, 0.86, true)
					GameTooltip:Show()
				end
			end)
		end
		button:SetID(slot)
		-- An empty square still looks like a slot of a bag.
		local ground = button:CreateTexture(nil, "BACKGROUND", nil, -6)
		ground:SetAllPoints()
		if not (ground.SetAtlas and pcall(ground.SetAtlas, ground, "bags-item-slot64")) then
			ground:SetTexture("Interface\\Buttons\\UI-EmptySlot-Disabled")
			ground:SetTexCoord(0.14, 0.86, 0.14, 0.86)
		end
		-- Its item level, small, in a corner.
		-- A padlock in the other corner: kept by you, never offered for sale.
		button.wandererLock = button:CreateTexture(nil, "OVERLAY", nil, 2)
		button.wandererLock:SetSize(14, 14)
		button.wandererLock:SetPoint("TOPRIGHT", button, "TOPRIGHT", -1, -1)
		button.wandererLock:SetTexture(LOCK_MARK)
		button.wandererLock:Hide()
		button.wandererLevel = button:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
		button.wandererLevel:SetPoint("TOPLEFT", button, "TOPLEFT", 2, -2)
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
		pick.veil:SetColorTexture(1, 0.82, 0, 0.22)
		pick.edges = {}
		for index, point in ipairs({ { "TOPLEFT", "TOPRIGHT" }, { "BOTTOMLEFT", "BOTTOMRIGHT" }, { "TOPLEFT", "BOTTOMLEFT" }, { "TOPRIGHT", "BOTTOMRIGHT" } }) do
			local edge = pick:CreateTexture(nil, "OVERLAY", nil, 1)
			edge:SetColorTexture(1, 0.82, 0, 0.9)
			edge:SetPoint(point[1])
			edge:SetPoint(point[2])
			if index <= 2 then edge:SetHeight(1) else edge:SetWidth(1) end
			pick.edges[index] = edge
		end
		pick.check = pick:CreateTexture(nil, "OVERLAY", nil, 2)
		pick.check:SetSize(16, 16)
		pick.check:SetPoint("BOTTOMRIGHT", pick, "BOTTOMRIGHT", 2, -2)
		pick.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
		pick:SetScript("OnClick", function(frame) self.TogglePick(frame:GetParent().wandererItem, IsShiftKeyDown()) end)
		pick:SetScript("OnEnter", function(frame)
			local square = frame:GetParent()
			if not square.wandererLink then return end
			GameTooltip:SetOwner(frame, "ANCHOR_RIGHT")
			GameTooltip:SetHyperlink(square.wandererLink)
			GameTooltip:Show()
		end)
		pick:SetScript("OnLeave", function() GameTooltip:Hide() end)
		button.wandererPick = pick
		return pick
	end

	local function PaintPick(button, item)
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

	local function Paint(button, item, settings, query)
		PaintPick(button, item)
		local info = item and item.info
		button.wandererLink = item and item.link
		button.wandererItem = item
		local kept = item and ns.IsKept and ns.IsKept(item.id) or false
		local auction = item and ns.IsForAuction and ns.IsForAuction(item.id) or false
		button.wandererLock:SetTexture(auction and AUCTION_MARK or LOCK_MARK)
		button.wandererLock:SetShown(kept or auction)
		-- At a merchant or the auction house, a kept item takes no click nor drag (no sale by mistake): Alt+click frees it first.
		if spec.canSell and buttons == pools.live then
			-- For the auction house: never to a merchant.
			local guarded = (kept and ns.Guarding()) or (auction and W.IsMerchantOpen and W.IsMerchantOpen()) or false
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
		if level and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[item.quality] then
			local color = ITEM_QUALITY_COLORS[item.quality]
			button.wandererLevel:SetTextColor(color.r, color.g, color.b)
		end
		-- The search: what does not match steps back.
		local match = not item or Matches(item, query)
		if button.SetMatchesSearch then button:SetMatchesSearch(match) else button:SetAlpha(match and 1 or 0.25) end
		button:Show()
	end

	-- What a section shows to sell, sold at the merchant, one by one (Wanderer does it).
	local function Sell(section)
		local list = {}
		for _, item in ipairs(section and section.items or {}) do
			if not (ns.IsKept and ns.IsKept(item.id)) then list[#list + 1] = { bag = item.bag, slot = item.slot, id = item.id } end
		end
		if W.SellItems then W.SellItems(list) end
	end

	local function Header(index)
		local header = headers[index]
		if header then return header end
		header = CreateFrame("Button", nil, content)
		header:SetHeight(HEADER_HEIGHT)
		header:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		header.text = W.Skin.CreateKicker(header)
		header.text:SetPoint("LEFT", header, "LEFT", 0, 0)
		header.sell = ns.TextButton(header, L.SELL, function() Sell(header.section) end, L.SELL_DESC)
		header.sell:SetPoint("RIGHT", header, "RIGHT", 0, 0)
		header:SetScript("OnClick", function(frame, mouse)
			local section = frame.section
			if not (section and section.key) then return end
			if mouse == "RightButton" then
				if section.key:find(ns.CUSTOM, 1, true) == 1 then ns.SectionMenu(frame, section.title) end
			else
				ns.ToggleFolded(section.key)
			end
		end)
		header:SetScript("OnEnter", function(frame) frame.text:SetTextColor(1, 0.82, 0) end)
		header:SetScript("OnLeave", function(frame) frame.text:SetTextColor(0.85, 0.75, 0.5) end)
		headers[index] = header
		return header
	end

	-- Sections of squares, row by row; returns the height used.
	local function Layout(sections, settings)
		local size, columns = settings.iconSize, settings.columns
		local y, used = 0, 0
		for _, section in ipairs(sections) do
			used = used + 1
			local header = Header(used)
			header.section = section
			local folded = section.key and ns.IsFolded(section.key)
			local value = (section.value or 0) > 0 and ("   |cffd8c79a%s|r"):format(U.Coins(section.value)) or ""
			if (section.auctionValue or 0) > 0 then
				value = value .. ("   |cff9ab8d8%s|r"):format(L.AUCTION_VALUE:format(U.Coins(section.auctionValue)))
			end
			header.text:SetText(("%s%s  |cff8c8070%d|r%s"):format(folded and "+ " or "", Upper(section.title),
				section.count or #section.buttons, value))
			header:ClearAllPoints()
			header:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
			header:SetPoint("RIGHT", content, "RIGHT", 0, 0)
			header.sell:SetShown(section.sellable and W.IsMerchantOpen and W.IsMerchantOpen() or false)
			header:Show()
			y = y + HEADER_HEIGHT + 2
			if folded then
				for _, button in ipairs(section.buttons) do button:Hide() end
				y = y + SECTION_GAP - 2
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
		for index = used + 1, #headers do headers[index]:Hide() end
		return math.max(y - SECTION_GAP, size)
	end

	function self.Refresh()
		pending = false
		if not (window and window:IsShown()) then return end
		local settings = ns.Settings()
		if not settings then return end
		local query = (searchBox:GetText() or ""):lower()
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
		local slotsOf = {}
		for _, bag in ipairs(containers) do
			local slots = NumSlots(bag)
			slotsOf[bag] = slots
			for slot = 1, slots do
				total = total + 1
				local item = Read(bag, slot, source)
				if item then items[#items + 1] = item else empty[#empty + 1] = { bag = bag, slot = slot } end
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
			-- By kind: what just came first, then each kind its section, the empty slots in one square at the end.
			table.sort(items, Before)
			local byKind = {}
			for _, item in ipairs(items) do
				local group = item.fresh and "new" or item.group
				byKind[group] = byKind[group] or {}
				table.insert(byKind[group], item)
			end
			local order = {}
			for _, kind in ipairs(CATEGORY_ORDER) do
				if kind == "custom" then
					-- Your sections, in your order.
					for _, name in ipairs(ns.MarksDB and ns.MarksDB().sections or {}) do order[#order + 1] = ns.CUSTOM .. name end
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
			for _, kind in ipairs(order) do
				if byKind[kind] then
					local section = { key = kind, title = KindName(kind), buttons = {}, items = byKind[kind], value = 0,
						sellable = spec.canSell and not source and SELLABLE[kind] }
					for _, item in ipairs(byKind[kind]) do
						local button = Button(item.bag, item.slot)
						Paint(button, item, settings, query)
						section.buttons[#section.buttons + 1] = button
						if SELLABLE[kind] then section.value = section.value + (U.SellPrice(item.link) or 0) * item.count end
						if AUCTION_VALUE[kind] and ns.AuctionPrice then
							local price = ns.AuctionPrice(item.link)
							if price then section.auctionValue = (section.auctionValue or 0) + price * item.count end
						end
					end
					sections[#sections + 1] = section
				end
			end
			-- The first empty slot stands for all of them: something dropped on it goes there.
			for index, slot in ipairs(empty) do
				local button = Button(slot.bag, slot.slot)
				if index == 1 then
					Paint(button, nil, settings, "")
					sections[#sections + 1] = { key = "free", title = L.CAT_FREE, buttons = { button }, count = #empty }
				else
					button:Hide()
				end
			end
		end
		local height = sections[1] and Layout(sections, settings) or settings.iconSize
		if not sections[1] then for index = 1, #headers do headers[index]:Hide() end end
		-- The items as drawn, in their order (Shift+click chooses a run of them).
		shown = {}
		for _, section in ipairs(sections) do
			if not (section.key and ns.IsFolded(section.key)) then
				for _, button in ipairs(section.buttons) do
					if button.wandererItem then shown[#shown + 1] = button.wandererItem end
				end
			end
		end
		local margin = W.Skin.Margin() + 8
		local width = math.max(settings.columns * (settings.iconSize + GAP) - GAP, 260)
		content:SetSize(width, height)
		local barHeight = bar and self.LayoutBar(width) or 0
		window:SetSize(width + margin * 2, height + TOP_ROOM + BOTTOM_ROOM + barHeight + margin * 2)
		freeText:SetText(L.FREE:format(#empty, total))
		moneyText:SetText(U.Coins(spec.money and spec.money() or Clean(Safe(GetMoney)) or 0))
		modeButton:SetLabel(settings.layout == "bags" and L.MODE_CATEGORIES or L.MODE_BAGS)
		if spec.onRefresh then spec.onRefresh(window, total, items) end
		self.ChainLinks()
		W.Skin.Get(window):Layout()
	end

	-- The links shown, right to left from the cross, without a gap for the hidden ones.
	function self.ChainLinks()
		local previous
		for _, link in ipairs(links) do
			link:ClearAllPoints()
			if link:IsShown() then
				if previous then
					link:SetPoint("RIGHT", previous, "LEFT", -6, 0)
				else
					link:SetPoint("TOPRIGHT", window, "TOPRIGHT", -(W.Skin.Margin() + 30), -(W.Skin.Margin() + 8))
				end
				previous = link
			end
		end
	end

	function self.Soon()
		if pending or not (window and window:IsShown()) then return end
		pending = true
		C_Timer.After(REFRESH_DELAY, self.Refresh)
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

	-- Your money.
	function self.Money()
		if moneyText and window:IsShown() then moneyText:SetText(U.Coins(spec.money and spec.money() or Clean(Safe(GetMoney)) or 0)) end
	end

	-- The search: what does not match steps back (nothing read again).
	function self.Search()
		if not (window and window:IsShown()) then return end
		local query = (searchBox:GetText() or ""):lower()
		EachShown(function(button)
			local item = button.wandererItem
			local match = not item or Matches(item, query)
			if button.SetMatchesSearch then button:SetMatchesSearch(match) else button:SetAlpha(match and 1 or 0.25) end
		end)
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
		if U.PlaySound then U.PlaySound("IG_MAINMENU_OPTION_CHECKBOX_ON") end
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

	-- Into the bank, one after another (the banker open).
	local function Deposit(list)
		local index = 0
		local function Next()
			index = index + 1
			local item = list[index]
			if not (item and ns.AtBank and ns.AtBank()) then return end
			Safe(Container().UseContainerItem, item.bag, item.slot)
			C_Timer.After(0.15, Next)
		end
		Next()
	end

	-- What the bar offers, in two lines: what can be done here first (at a merchant, the banker, the auction
	-- house), then your say over the items, always.
	local ACTIONS = {
		{ key = "sell", group = "here", label = "ACT_SELL", when = function() return spec.canSell and W.IsMerchantOpen and W.IsMerchantOpen() end,
			run = function(list)
				-- What you keep, and what is for the auction house, never goes to a merchant.
				local sold, aside = {}, 0
				for _, item in ipairs(list) do
					if ns.IsKept(item.id) or ns.IsForAuction(item.id) then aside = aside + 1 else sold[#sold + 1] = item end
				end
				if sold[1] and W.SellItems then W.SellItems(sold) end
				if aside > 0 and W.Print then W.Print(L.SKIPPED:format(aside)) end
			end },
		{ key = "deposit", group = "here", label = "ACT_DEPOSIT", when = function() return spec.canSell and ns.AtBank and ns.AtBank() end,
			run = function(list) Deposit(list) end },
		{ key = "search", group = "here", label = "ACT_SEARCH", when = function(count)
				local frame = _G.AuctionHouseFrame
				return count == 1 and type(WandererAuction) == "table" and WandererAuction.Search and frame and frame:IsShown()
			end,
			run = function(list) if list[1].name ~= "" then WandererAuction.Search(list[1].name) end end },
		{ key = "keep", group = "marks", label = "ACT_KEEP", run = function(_, ids) ns.MarkMany(ids, "keep") end },
		{ key = "auction", group = "marks", label = "ACT_AUCTION", run = function(_, ids) ns.MarkMany(ids, "auction") end },
		{ key = "junk", group = "marks", label = "ACT_JUNK", run = function(_, ids) ns.MarkMany(ids, "junk") end },
		{ key = "section", group = "marks", label = "ACT_SECTION", keep = true, run = function(_, ids, link) ns.SectionsMenu(link, ids, Clear) end },
		{ key = "free", group = "marks", label = "ACT_FREE", run = function(_, ids) ns.FreeMany(ids) end },
	}

	-- The bar, under the squares while selecting: how many are chosen, all or none, then what to do with them.
	-- Returns its height (0 when not selecting).
	function self.LayoutBar(width)
		if not selecting then
			bar:Hide()
			return 0
		end
		local count = 0
		for _ in pairs(picked) do count = count + 1 end
		bar.count:SetText(count > 0 and L.PICKED:format(count) or L.PICK_HINT)
		local x, y, line, group = 0, 22, 18, nil
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
				link:SetPoint("TOPLEFT", bar, "TOPLEFT", x - 5, -y)
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
		bar.rule = bar:CreateTexture(nil, "ARTWORK")
		bar.rule:SetColorTexture(1, 0.82, 0, 0.2)
		bar.rule:SetHeight(1)
		bar.rule:SetPoint("TOPLEFT")
		bar.rule:SetPoint("TOPRIGHT")
		bar.count = W.Skin.CreateText(bar, "GameTooltipTextSmall", 0.85, 0.78, 0.6)
		bar.count:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, -6)
		bar.none = ns.TextButton(bar, L.SELECT_NONE, Clear)
		bar.none:SetPoint("TOPRIGHT", bar, "TOPRIGHT", 5, -2)
		bar.all = ns.TextButton(bar, L.SELECT_ALL, function()
			for _, item in ipairs(shown) do picked[Key(item)] = item end
			self.Refresh()
		end)
		bar.all:SetPoint("RIGHT", bar.none, "LEFT", -4, 0)
		bar.links = {}
		for _, action in ipairs(ACTIONS) do
			local link
			link = ns.TextButton(bar, L[action.label], function()
				local list, ids = Chosen()
				if not list[1] then return end
				if U.PlaySound then U.PlaySound("IG_MAINMENU_OPTION_CHECKBOX_ON") end
				action.run(list, ids, link)
				-- Done: the selection cleared (the section's menu clears it once a choice is made).
				if not action.keep then Clear() end
			end, L[action.label .. "_DESC"])
			bar.links[action.key] = link
		end
		bar:Hide()
	end

	local function Create()
		window = W.Skin.CreateWindow(spec.name, "MEDIUM")
		if spec.sounds then W.Skin.Sounds(window, spec.sounds[1], spec.sounds[2]) end
		W.Skin.Dress(window, spec.point, spec.name .. "Pos", spec.onClose)
		window:SetClampedToScreen(true)
		local margin = W.Skin.Margin() + 8
		local kicker = W.Skin.CreateKicker(window, "Wanderer")
		kicker:SetPoint("TOPLEFT", window, "TOPLEFT", margin, -margin)
		local title = W.Skin.CreateText(window, "GameTooltipHeaderText", 1, 0.82, 0)
		title:SetPoint("TOPLEFT", kicker, "BOTTOMLEFT", 0, -3)
		title:SetText(spec.title)
		window.titleText = title
		-- Its links, right to left from the cross: the window's own, where it puts the choice by kind or by
		-- container (given to it; first when it does not place it).
		modeButton = ns.TextButton(window, L.MODE_BAGS, function()
			local settings = ns.Settings()
			settings.layout = settings.layout == "bags" and "categories" or "bags"
			U.PlaySound("IG_MAINMENU_OPTION_CHECKBOX_ON")
			ns.RefreshAll()
		end)
		local placed = false
		if spec.actions then
			spec.actions(window, function(link)
				if link == modeButton then placed = true end
				links[#links + 1] = link
			end, modeButton)
		end
		if not placed then table.insert(links, 1, modeButton) end
		self.ChainLinks()
		-- Choosing several items (or one) to act on them together, without Alt: a button of its own, beside
		-- the search, where it is seen.
		if spec.selectable then
			selectButton = CreateFrame("Button", spec.name .. "Select", window, "UIPanelButtonTemplate")
			-- As wide as the longer of its two words ("Select", "Done").
			local widest = 0
			for _, text in ipairs({ L.SELECT_DONE, L.SELECT }) do
				selectButton:SetText(text)
				widest = math.max(widest, U.Measure(selectButton:GetFontString() or selectButton, "GetStringWidth", 70))
			end
			selectButton:SetSize(widest + 28, 22)
			selectButton:SetPoint("RIGHT", window, "RIGHT", -margin, 0)
			selectButton:SetPoint("TOP", title, "BOTTOM", 0, -7)
			selectButton:SetScript("OnClick", function()
				U.PlaySound("IG_MAINMENU_OPTION_CHECKBOX_ON")
				self.SetSelecting(not selecting)
			end)
			selectButton:SetScript("OnEnter", function(button)
				GameTooltip:SetOwner(button, "ANCHOR_BOTTOM")
				GameTooltip:AddLine(L.SELECT_DESC, 1, 1, 1, true)
				GameTooltip:Show()
			end)
			selectButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
		end
		-- The search, the whole width (up to the selection's button).
		searchBox = W.Skin.CreateInput(window, spec.name .. "Search", 40)
		searchBox:SetHeight(20)
		searchBox:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
		if selectButton then
			searchBox:SetPoint("RIGHT", selectButton, "LEFT", -6, 0)
		else
			searchBox:SetPoint("RIGHT", window, "RIGHT", -margin, 0)
		end
		searchBox.hint = W.Skin.CreateText(searchBox, "GameTooltipTextSmall", 0.5, 0.5, 0.5)
		searchBox.hint:SetPoint("LEFT", searchBox, "LEFT", 8, 0)
		searchBox.hint:SetText(L.SEARCH)
		searchBox:SetScript("OnTextChanged", function(box)
			box.hint:SetShown((box:GetText() or "") == "" and not box:HasFocus())
			self.Search()
		end)
		searchBox:SetScript("OnEditFocusGained", function(box) box.hint:Hide() end)
		searchBox:SetScript("OnEditFocusLost", function(box) box.hint:SetShown((box:GetText() or "") == "") end)
		searchBox:SetScript("OnEscapePressed", function(box)
			box:SetText("")
			box:ClearFocus()
		end)
		searchBox:SetScript("OnEnterPressed", function(box) box:ClearFocus() end)
		content = CreateFrame("Frame", nil, window)
		content:SetPoint("TOPLEFT", window, "TOPLEFT", margin, -(margin + TOP_ROOM))
		-- At the bottom: the free slots, the gold.
		freeText = W.Skin.CreateText(window, "GameTooltipTextSmall", 0.65, 0.65, 0.65)
		freeText:SetPoint("BOTTOMLEFT", window, "BOTTOMLEFT", margin, margin)
		window.freeText = freeText
		moneyText = W.Skin.CreateText(window, "GameTooltipText", 1, 1, 1)
		moneyText:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -margin, margin)
		if spec.selectable then CreateBar(margin) end
		window:HookScript("OnShow", function(frame)
			frame:SetScale(W.Skin.Scale())
			self.Refresh()
		end)
		window:HookScript("OnHide", function()
			-- Closed: the selection ends.
			if selecting then
				selecting = false
				wipe(picked)
				if selectButton then selectButton:SetText(L.SELECT) end
			end
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
	end

	local function Window()
		if not window then Create() end
		return window
	end

	function self.Open()
		if Window():IsShown() then self.Refresh() else window:Show() end
	end

	function self.Close()
		if window then window:Hide() end
	end

	function self.Toggle() Window():SetShown(not window:IsShown()) end

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
	if ns.RefreshBankFrame then ns.RefreshBankFrame() end
end
