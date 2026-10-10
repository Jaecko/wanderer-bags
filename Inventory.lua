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

local GAP = 4
local SECTION_GAP = 10
local HEADER_HEIGHT = 14
local TOP_ROOM = 64 -- heading, search
local BOTTOM_ROOM = 26 -- free slots, gold
local REFRESH_DELAY = 0.05 -- many updates at once: one drawing

local CATEGORY_ORDER = { "new", "gear", "consumable", "trade", "quest", "other", "junk" }
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

local function KindName(kind) return L["CAT_" .. kind:upper()] end

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
	return { bag = bag, slot = slot, link = link, kind = kind, quality = quality, name = name, level = level,
		count = Clean(info.stackCount) or 1, info = info, quest = quest,
		fresh = not source and C_NewItems and Clean(Safe(C_NewItems.IsNewItem, bag, slot)) and true or false }
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
	return KindName(item.kind):lower():find(query, 1, true) ~= nil
end

-- A small text link, gold when hovered, as Wanderer's.
function ns.TextButton(parent, text, onClick, tooltip)
	local button = CreateFrame("Button", nil, parent)
	button.text = W.Skin.CreateText(button, "GameTooltipTextSmall", 0.75, 0.68, 0.5)
	button.text:SetPoint("CENTER")
	button:SetHeight(18)
	function button:SetLabel(label)
		self.text:SetText(label)
		self:SetWidth(U.Measure(self.text, "GetStringWidth", 60) + 10)
	end
	button:SetLabel(text)
	button:SetScript("OnClick", onClick)
	button:SetScript("OnEnter", function(self)
		self.text:SetTextColor(1, 0.82, 0)
		if tooltip then
			GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
			GameTooltip:AddLine(tooltip, 1, 1, 1, true)
			GameTooltip:Show()
		end
	end)
	button:SetScript("OnLeave", function(self)
		self.text:SetTextColor(0.75, 0.68, 0.5)
		GameTooltip:Hide()
	end)
	return button
end

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
		button.wandererLevel = button:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
		button.wandererLevel:SetPoint("TOPLEFT", button, "TOPLEFT", 2, -2)
		buttons[bag][slot] = button
		return button
	end

	local function Paint(button, item, settings, query)
		local info = item and item.info
		button.wandererLink = item and item.link
		if SetItemButtonTexture then SetItemButtonTexture(button, info and Clean(info.iconFileID)) end
		if SetItemButtonCount then SetItemButtonCount(button, info and Clean(info.stackCount) or 0) end
		if SetItemButtonDesaturated then SetItemButtonDesaturated(button, info and Clean(info.isLocked) and true or false) end
		if SetItemButtonQuality then SetItemButtonQuality(button, item and item.quality, item and item.link) end
		if button.UpdateCooldown then pcall(button.UpdateCooldown, button, item ~= nil) end
		if button.UpdateNewItem and item then pcall(button.UpdateNewItem, button, item.quality) end
		if button.UpdateQuestItem then
			local quest = item and type(item.quest) == "table" and item.quest
			pcall(button.UpdateQuestItem, button, quest and Clean(quest.isQuestItem), quest and Clean(quest.questID),
				quest and Clean(quest.isActive))
		end
		if button.SetReadable then button:SetReadable(info and Clean(info.isReadable)) end
		if type(button.JunkIcon) == "table" then button.JunkIcon:SetShown(item and settings.junk and item.kind == "junk" or false) end
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

	local function Header(index)
		local header = headers[index]
		if not header then
			header = W.Skin.CreateKicker(content)
			headers[index] = header
		end
		return header
	end

	-- Sections of squares, row by row; returns the height used.
	local function Layout(sections, settings)
		local size, columns = settings.iconSize, settings.columns
		local y, used = 0, 0
		for _, section in ipairs(sections) do
			used = used + 1
			local header = Header(used)
			header:SetText(("%s  |cff8c8070%d|r"):format(section.title:upper(), section.count or #section.buttons))
			header:ClearAllPoints()
			header:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
			header:Show()
			y = y + HEADER_HEIGHT + 2
			for index, button in ipairs(section.buttons) do
				local column = (index - 1) % columns
				local row = math.floor((index - 1) / columns)
				button:ClearAllPoints()
				button:SetSize(size, size)
				button:SetPoint("TOPLEFT", content, "TOPLEFT", column * (size + GAP), -(y + row * (size + GAP)))
			end
			y = y + math.ceil(#section.buttons / columns) * (size + GAP) + SECTION_GAP
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
					local section = { title = spec.nameOf(bag), buttons = {} }
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
				local group = item.fresh and "new" or item.kind
				byKind[group] = byKind[group] or {}
				table.insert(byKind[group], item)
			end
			for _, kind in ipairs(CATEGORY_ORDER) do
				if byKind[kind] then
					local section = { title = KindName(kind), buttons = {} }
					for _, item in ipairs(byKind[kind]) do
						local button = Button(item.bag, item.slot)
						Paint(button, item, settings, query)
						section.buttons[#section.buttons + 1] = button
					end
					sections[#sections + 1] = section
				end
			end
			-- The first empty slot stands for all of them: something dropped on it goes there.
			for index, slot in ipairs(empty) do
				local button = Button(slot.bag, slot.slot)
				if index == 1 then
					Paint(button, nil, settings, "")
					sections[#sections + 1] = { title = L.CAT_FREE, buttons = { button }, count = #empty }
				else
					button:Hide()
				end
			end
		end
		local height = sections[1] and Layout(sections, settings) or settings.iconSize
		if not sections[1] then for index = 1, #headers do headers[index]:Hide() end end
		local margin = W.Skin.Margin() + 8
		local width = math.max(settings.columns * (settings.iconSize + GAP) - GAP, 260)
		content:SetSize(width, height)
		window:SetSize(width + margin * 2, height + TOP_ROOM + BOTTOM_ROOM + margin * 2)
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
		-- Its links, right to left from the cross: by kind or by container, then the window's own.
		modeButton = ns.TextButton(window, L.MODE_BAGS, function()
			local settings = ns.Settings()
			settings.layout = settings.layout == "bags" and "categories" or "bags"
			U.PlaySound("IG_MAINMENU_OPTION_CHECKBOX_ON")
			ns.RefreshAll()
		end)
		links[1] = modeButton
		if spec.actions then
			spec.actions(window, function(link) links[#links + 1] = link end)
		end
		self.ChainLinks()
		-- The search, the whole width.
		searchBox = W.Skin.CreateInput(window, spec.name .. "Search", 40)
		searchBox:SetHeight(20)
		searchBox:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
		searchBox:SetPoint("RIGHT", window, "RIGHT", -margin, 0)
		searchBox.hint = W.Skin.CreateText(searchBox, "GameTooltipTextSmall", 0.5, 0.5, 0.5)
		searchBox.hint:SetPoint("LEFT", searchBox, "LEFT", 8, 0)
		searchBox.hint:SetText(L.SEARCH)
		searchBox:SetScript("OnTextChanged", function(box)
			box.hint:SetShown((box:GetText() or "") == "" and not box:HasFocus())
			self.Refresh()
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
		window:HookScript("OnShow", function(frame)
			frame:SetScale(W.Skin.Scale())
			self.Refresh()
		end)
		window:HookScript("OnHide", function()
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
