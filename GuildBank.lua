local _, ns = ...
local L = ns.L

-- The guild bank in Wanderer's window, of the bank's family: opened at the guild vault beside your bags, closed
-- with the visit. On the left the guild's tabs (their icons and names, what your rank allows in each, the ones
-- closed to you greyed, a tab to buy for the guild master); on the right the pages of the game's own window: the
-- items of the tab shown (laid out as the game lays them, the guild arranges them so; the search of the bags), the
-- item log, the gold log, the tab's text. At the foot the guild's gold, what you may still take of it today, and
-- the game's own questions to deposit or withdraw gold.
-- A click takes an item in hand, a right click puts it in your bags, a right click in your bags puts it in the tab
-- shown: the game's own moves, its own refusals; what your rank would be refused is not offered (said instead).
-- The game's window stays open out of sight (the game needs it to keep the vault open); a link shows it, a link
-- above it comes back, and the choice is kept for this character (as the setting). A client without a guild bank:
-- nothing here wakes.

local W = Wanderer
local U = W and W.Util
local Safe, Clean = U and U.Safe, U and U.Clean
local Fold = U and U.Fold or string.lower

local SLOTS = 98 -- a tab's squares
local PER_GROUP, ROWS = 14, 7 -- the game draws them in seven groups of two columns of seven
local GAP, GROUP_GAP = 4, 10
local TAB_WIDTH, TAB_HEIGHT = 176, 32
local FOOT = 34
local LOG_ROW = 20
local DRAW_DELAY = 0.05

-- What a client with a guild bank has (any one missing: no guild bank here, nothing wakes).
local NEEDED = { "GetNumGuildBankTabs", "GetGuildBankTabInfo", "GetGuildBankItemInfo", "GetGuildBankItemLink",
	"GetCurrentGuildBankTab", "SetCurrentGuildBankTab", "QueryGuildBankTab", "PickupGuildBankItem", "AutoStoreGuildBankItem",
	"CloseGuildBankFrame" }

-- The game's function by its name, called safely (nothing when the client lacks it).
local function Call(name, ...)
	local fn = rawget(_G, name)
	if type(fn) == "function" then return Safe(fn, ...) end
end
local function Game(name) return rawget(_G, name) end

-- The client has a guild bank: its functions, and the game does not say it is off.
function ns.HasGuildBank()
	for _, name in ipairs(NEEDED) do
		if type(rawget(_G, name)) ~= "function" then return false end
	end
	local api = rawget(_G, "C_GuildBank")
	if type(api) == "table" and type(api.IsGuildBankEnabled) == "function" then
		local ok, enabled = pcall(api.IsGuildBankEnabled)
		if ok and enabled == false then return false end
	end
	return true
end

local window, reopen, placeGame
local atBank = false -- at the guild vault
local mode = "wanderer" -- this visit: Wanderer's window ("wanderer") or the game's ("game")
local switching = false -- Wanderer's window hidden to show the game's (the vault stays open)
local page = "items" -- the page shown: items, log, money, info (buying: the tab to buy instead)
local buying = false
local answered = {} -- tab -> the game has told its items (and the withdrawals left) since the visit began
local heldFromGuild = false -- the item in hand was taken from the guild bank (a move inside it, not a deposit)
local squares, rows, logRows = {}, {}, {}
local laidSize -- the squares' size laid out last
local drawSoon

local function Settings() return ns.Settings() end

-- Wanderer's window wanted here (the bags' extension on, the setting kept to Wanderer's).
local function Wanted()
	local settings = Settings()
	return ns.On() and settings and settings.guildBank ~= false or false
end

-- The window you switch to by its link: kept for the next visits, in every profile of this character.
local function Choose(wanderer)
	local function Set()
		local settings = Settings()
		if settings then settings.guildBank = wanderer and true or false end
	end
	if W.ChangeEverywhere then W.ChangeEverywhere(Set) else Set() end
end

-- The tabs ------------------------------------------------------------------------------------------------------

local function MaxTabs() return tonumber(Game("MAX_GUILDBANK_TABS")) or 8 end
local function NumTabs() return Clean(Call("GetNumGuildBankTabs")) or 0 end
local function Current() return Clean(Call("GetCurrentGuildBankTab")) or 1 end

-- A tab as the game tells it: its name (its number when it has none), its icon, what your rank allows.
local function TabInfo(tab)
	local name, icon, view, deposit, withdrawals, left = Call("GetGuildBankTabInfo", tab)
	name = Clean(name)
	return { tab = tab, name = name or L.GUILD_TAB:format(tab), icon = Clean(icon), view = Clean(view) and true or false,
		deposit = Clean(deposit) and true or false, withdrawals = Clean(withdrawals) or 0, left = Clean(left) or 0 }
end
ns.GuildTabInfo = TabInfo

-- What your rank allows in a tab, in a few words, and its tone.
local function Access(info)
	if not info.view then return L.GUILD_ACCESS_HIDDEN, "grey" end
	if not info.deposit and info.withdrawals == 0 then return L.GUILD_ACCESS_LOOK, "grey" end
	if not info.deposit then return L.GUILD_ACCESS_TAKE, "blue" end
	if info.withdrawals == 0 then return L.GUILD_ACCESS_GIVE, "blue" end
	return L.GUILD_ACCESS_FULL, "green"
end
ns.GuildAccess = Access

-- The withdrawals left today in a tab (none when your rank takes nothing there).
local function LeftWords(info)
	if info.withdrawals == 0 then return nil end
	if info.left < 0 then return L.GUILD_LEFT_ANY, "grey" end
	if info.left == 0 then return L.GUILD_LEFT_NONE, "red" end
	return U.Plural(info.left, L.GUILD_LEFT_ONE, L.GUILD_LEFT_MANY), "gold"
end

-- A tab for the guild master to buy: the next one, while the game names a price.
local function Buyable()
	if not Clean(Call("IsGuildLeader")) then return false end
	local most = tonumber(Game("MAX_BUY_GUILDBANK_TABS")) or MaxTabs()
	return NumTabs() < most and (Clean(Call("GetGuildBankTabCost")) or 0) > 0
end

-- No tab open to your rank (the guild master sees them all).
local function NoneViewable()
	if Clean(Call("IsGuildLeader")) then return false end
	for tab = 1, NumTabs() do
		if TabInfo(tab).view then return false end
	end
	return true
end

-- What your rank refuses of a tab's item: taking it at all, or (toBags) another withdrawal today. Said only once
-- the game has told the tab (before that its numbers are not known yet: the game decides).
local function TakeRefusal(info, toBags)
	if not answered[info.tab] then return nil end
	if info.withdrawals == 0 then return L.GUILD_NO_WITHDRAW end
	if toBags and info.left == 0 then return L.GUILD_NONE_LEFT end
end
ns.GuildTakeRefusal = TakeRefusal

local function Refuse(words)
	if UIErrorsFrame and UIErrorsFrame.AddMessage then UIErrorsFrame:AddMessage(words, 1, 0.1, 0.1) end
end

local function Cursor() return Safe(rawget(_G, "GetCursorInfo")) end

-- Asks the game for a tab's items (and its withdrawals left), its log, its text: as its own window does.
local function Ask(tab)
	tab = tab or Current()
	if page == "log" then
		Call("QueryGuildBankTab", tab)
		Call("QueryGuildBankLog", tab)
	elseif page == "money" then
		Call("QueryGuildBankLog", MaxTabs() + 1)
	elseif page == "info" then
		Call("QueryGuildBankText", tab)
	else
		Call("QueryGuildBankTab", tab)
	end
end

-- The tab's text being written, saved before another tab is shown (as the game's window does).
local function SaveText()
	local info = window and window.info
	if not (info and info.edit and info.edit:IsShown()) then return end
	local text = info.edit:GetText() or ""
	if text ~= (info.edit.saved or "") then
		Call("SetGuildBankText", info.edit.tab or Current(), text)
		info.edit.saved = text
	end
end

function ns.GuildShowTab(tab)
	if not (tab and TabInfo(tab).view) and not Clean(Call("IsGuildLeader")) then return end
	SaveText()
	buying = false
	Call("SetCurrentGuildBankTab", tab)
	Ask(tab)
	ns.GuildDraw()
end

-- The items --------------------------------------------------------------------------------------------------

-- A tab's item, read for the search and the squares: nil when the slot is empty.
local function ReadItem(tab, slot)
	local link = Clean(Call("GetGuildBankItemLink", tab, slot))
	local texture, count, locked, _, quality = Call("GetGuildBankItemInfo", tab, slot)
	texture = Clean(texture)
	if not (link or texture) then return nil end
	quality = Clean(quality) or 1
	local id = U.ItemID(link)
	local kind, equip = ns.KindOf(id, quality, false, false)
	local level = kind == "gear" and link and Clean(Safe(C_Item and C_Item.GetDetailedItemLevelInfo, link)) or 0
	return { slot = slot, id = id, link = link, texture = texture, count = Clean(count) or 1, locked = Clean(locked) and true or false,
		quality = quality, kind = kind, group = kind, equip = equip, level = level, boe = false, live = false,
		name = U.LinkName(link) or "" }
end
ns.GuildReadItem = ReadItem

local function Query()
	local box = window and window.search
	return box and Fold(box:GetText() or "") or ""
end

-- How many items of a tab the search finds, among those the game has told (a tab never shown says nothing yet).
local function Found(tab, query)
	local count = 0
	for slot = 1, SLOTS do
		local item = Clean(Call("GetGuildBankItemLink", tab, slot)) and ReadItem(tab, slot)
		if item and ns.Matches(item, query) then count = count + 1 end
	end
	return count
end

-- A square's click, as the game's own: a modified click links it or tries it on, Shift splits its stack, gold in
-- hand is deposited, a right click puts the item in your bags, a click takes it in hand or puts down what you hold.
local function PickOrDrop(square)
	local tab = Current()
	local info = TabInfo(tab)
	local held = Cursor()
	if not held then heldFromGuild = false end
	if held == "item" then
		if not heldFromGuild and answered[tab] and not info.deposit then return Refuse(L.GUILD_NO_DEPOSIT) end
	elseif square.wandererItem then
		local refusal = TakeRefusal(info, false)
		if refusal then return Refuse(refusal) end
	else
		return
	end
	Call("PickupGuildBankItem", tab, square.slot)
	local now = Cursor()
	if not now then heldFromGuild = false elseif held ~= "item" then heldFromGuild = true end
end

local function SquareClick(square, mouse)
	local item = square.wandererItem
	if item and item.link and U.ItemClick and U.ItemClick(item.link) then return end
	local tab = Current()
	if IsModifiedClick and Clean(Safe(IsModifiedClick, "SPLITSTACK")) then
		if item and not CursorHasItem() and not item.locked and item.count > 1 then
			local refusal = TakeRefusal(TabInfo(tab), false)
			if refusal then return Refuse(refusal) end
			if StackSplitFrame and StackSplitFrame.OpenStackSplitFrame then
				Safe(StackSplitFrame.OpenStackSplitFrame, StackSplitFrame, item.count, square, "BOTTOMLEFT", "TOPLEFT")
			end
		end
		return
	end
	local held, money = Cursor()
	if held == "money" then
		Call("DepositGuildBankMoney", money)
		Call("ClearCursor")
		return
	elseif held == "guildbankmoney" then
		Call("DropCursorMoney")
		Call("ClearCursor")
		return
	end
	if mouse == "RightButton" then
		if not item then return end
		local refusal = TakeRefusal(TabInfo(tab), true)
		if refusal then return Refuse(refusal) end
		Call("AutoStoreGuildBankItem", tab, square.slot)
		if GameTooltip:IsOwned(square) then GameTooltip:Hide() end
		return
	end
	PickOrDrop(square)
end
ns.GuildSquareClick = SquareClick

local function SquareTip(square)
	if not square.wandererItem then return end
	GameTooltip:SetOwner(square, "ANCHOR_RIGHT")
	if GameTooltip.SetGuildBankItem then
		Safe(GameTooltip.SetGuildBankItem, GameTooltip, Current(), square.slot)
	elseif square.wandererItem.link then
		Safe(GameTooltip.SetHyperlink, GameTooltip, square.wandererItem.link)
	end
	GameTooltip:Show()
end

local function Square(parent, slot)
	local square = CreateFrame("ItemButton", "WandererBagsGuildItem" .. slot, parent)
	square.slot = slot
	square:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	square:RegisterForDrag("LeftButton")
	square:SetScript("OnClick", SquareClick)
	square:SetScript("OnDragStart", function(self) if self.wandererItem and not Cursor() then PickOrDrop(self) end end)
	square:SetScript("OnReceiveDrag", function(self) SquareClick(self, "LeftButton") end)
	square:SetScript("OnEnter", SquareTip)
	square:SetScript("OnLeave", function() GameTooltip:Hide() end)
	square.UpdateTooltip = SquareTip
	-- (the game's stack window splits through this)
	square.SplitStack = function(self, split) Call("SplitGuildBankItem", Current(), self.slot, split) end
	-- (a controller: the bottom button puts it in your bags, the top one takes it in hand)
	square.padPrimary, square.padSecondary, square.padSecondaryWord = "RightButton", "LeftButton", L.PAD_IN_HAND
	local ground = square:CreateTexture(nil, "BACKGROUND", nil, -6)
	ground:SetAllPoints()
	if not (ground.SetAtlas and pcall(ground.SetAtlas, ground, "bags-item-slot64")) then
		ground:SetTexture("Interface\\Buttons\\UI-EmptySlot-Disabled")
		ground:SetTexCoord(0.14, 0.86, 0.14, 0.86)
	end
	square.level = square:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
	square.level:SetPoint("BOTTOMLEFT", square, "BOTTOMLEFT", 2, 2)
	return square
end

-- The squares placed as the game places them: seven groups of two columns of seven, a little apart.
local function LaySquares(size)
	laidSize = size
	local grid = window.grid
	for slot = 1, SLOTS do
		local square = squares[slot]
		local group, index = math.floor((slot - 1) / PER_GROUP), (slot - 1) % PER_GROUP
		local column, row = math.floor(index / ROWS), index % ROWS
		square:SetSize(size, size)
		square:ClearAllPoints()
		square:SetPoint("TOPLEFT", grid, "TOPLEFT", group * (size * 2 + GAP + GROUP_GAP) + column * (size + GAP), -row * (size + GAP))
	end
	local width = 7 * (size * 2 + GAP) + 6 * GROUP_GAP
	local height = ROWS * size + (ROWS - 1) * GAP
	grid:SetSize(width, height)
	return width, height
end

local function PaintSquare(square, item, query, settings)
	square.wandererItem = item
	if SetItemButtonTexture then SetItemButtonTexture(square, item and item.texture or nil) end
	if SetItemButtonCount then SetItemButtonCount(square, item and item.count or 0) end
	if SetItemButtonDesaturated then SetItemButtonDesaturated(square, item and item.locked or false) end
	if SetItemButtonQuality then SetItemButtonQuality(square, item and item.quality or nil, item and item.link or nil) end
	local level = item and settings.itemLevel and item.level or 0
	square.level:SetText(level > 0 and tostring(level) or "")
	local match = not item or query == "" or ns.Matches(item, query)
	if square.SetMatchesSearch then square:SetMatchesSearch(match) else square:SetAlpha(match and 1 or 0.25) end
	square:Show()
end

-- The logs ---------------------------------------------------------------------------------------------------------

-- When, as the game says it in its logs ("3 hours"), then "ago".
local function When(year, month, day, hour)
	year, month, day, hour = tonumber(year) or 0, tonumber(month) or 0, tonumber(day) or 0, tonumber(hour) or 0
	local util = rawget(_G, "TimeUtil")
	if type(util) == "table" and type(util.GetRecentTimeDate) == "function" then
		local ok, words = pcall(util.GetRecentTimeDate, year, month, day, hour)
		if ok and type(words) == "string" and words ~= "" then return L.GUILD_LOG_AGO:format(words) end
	end
	local hours = ((year * 12 + month) * 30 + day) * 24 + hour
	if hours <= 0 then return L.GUILD_LOG_RECENT end
	return U.AgoWords(hours * 3600)
end

local function Who(name) return W.Skin.Colorize(Clean(name) or UNKNOWN or "?", "gold") end
local function Times(count)
	count = tonumber(count) or 1
	return count > 1 and (" x%d"):format(count) or ""
end

-- The item log of a tab, the newest first: { { text, when, link } }.
function ns.GuildItemLog(tab)
	local list = {}
	for index = 1, Clean(Call("GetNumGuildBankTransactions", tab)) or 0 do
		local kind, name, link, count, from, to, year, month, day, hour = Call("GetGuildBankTransaction", tab, index)
		kind, link = Clean(kind), Clean(link)
		local item = (link or "?") .. Times(count)
		local text
		if kind == "deposit" then
			text = L.GUILD_LOG_IN:format(Who(name), item)
		elseif kind == "withdraw" then
			text = L.GUILD_LOG_OUT:format(Who(name), item)
		elseif kind == "move" then
			text = L.GUILD_LOG_MOVE:format(Who(name), item, TabInfo(from).name, TabInfo(to).name)
		end
		if text then table.insert(list, 1, { text = text, when = When(year, month, day, hour), link = link }) end
	end
	return list
end

-- The game's own words for a rarer kind of gold line (its name, the sum).
local function GameWords(key, ...)
	local pattern = rawget(_G, key)
	if type(pattern) ~= "string" then return nil end
	local ok, text = pcall(string.format, pattern, ...)
	return ok and text or nil
end

-- The gold log, the newest first.
function ns.GuildMoneyLog()
	local list = {}
	for index = 1, Clean(Call("GetNumGuildBankMoneyTransactions")) or 0 do
		local kind, name, amount, year, month, day, hour = Call("GetGuildBankMoneyTransaction", index)
		kind, amount = Clean(kind), Clean(amount) or 0
		local who, coins = Who(name), U.Coins(amount)
		local text
		if kind == "deposit" then
			text = L.GUILD_LOG_IN:format(who, coins)
		elseif kind == "withdraw" then
			text = L.GUILD_LOG_OUT:format(who, coins)
		elseif kind == "repair" then
			text = L.GUILD_LOG_REPAIR:format(who, coins)
		elseif kind == "withdrawForTab" then
			text = L.GUILD_LOG_TAB_PAY:format(who, coins)
		elseif kind == "buyTab" then
			text = amount > 0 and L.GUILD_LOG_TAB_BUY:format(who, coins) or L.GUILD_LOG_TAB_FREE:format(who)
		elseif kind == "depositSummary" then
			text = GameWords("GUILDBANK_AWARD_MONEY_SUMMARY_FORMAT", coins)
		elseif kind == "buyRename" then
			text = GameWords("GUILDBANK_GUILD_RENAME_PURCHASE", who, coins)
		elseif kind == "refundRename" then
			text = GameWords("GUILDBANK_GUILD_RENAME_REFUND", who, coins)
		end
		if text then table.insert(list, 1, { text = text, when = When(year, month, day, hour) }) end
	end
	return list
end

local function LogRow(parent)
	local row = CreateFrame("Button", nil, parent)
	row:SetHeight(LOG_ROW)
	row.text = W.Skin.Text(row, "GameTooltipText", "text")
	row.text:SetPoint("LEFT", row, "LEFT", 4, 0)
	row.when = W.Skin.Text(row, "GameTooltipTextSmall", "muted")
	row.when:SetPoint("RIGHT", row, "RIGHT", -4, 0)
	row.text:SetPoint("RIGHT", row.when, "LEFT", -10, 0)
	if row.text.SetWordWrap then row.text:SetWordWrap(false) end
	row.text:SetJustifyH("LEFT")
	local hover = row:CreateTexture(nil, "HIGHLIGHT")
	hover:SetAllPoints()
	W.Skin.HoverTint(hover)
	-- (an item's line: its tooltip, Shift links it)
	W.Skin.ItemTooltip(row, function(self) return self.link end, "ANCHOR_RIGHT")
	row:SetScript("OnClick", function(self) if self.link and U.ItemClick then U.ItemClick(self.link) end end)
	return row
end

local function DrawLog(list)
	local log = window.log
	log.lines = list
	local shown = #logRows
	log.offset = math.max(0, math.min(log.offset or 0, #list - shown))
	for index, row in ipairs(logRows) do
		local line = list[index + log.offset]
		row:SetShown(line ~= nil)
		if line then
			row.text:SetText(line.text)
			row.when:SetText(line.when or "")
			row.link = line.link
		end
	end
	log.empty:SetShown(not list[1])
	log.bar:Set(#list, shown, log.offset)
end

-- The window ---------------------------------------------------------------------------------------------------

local function Chip(tip)
	local chip = W.Skin.Chip(window)
	chip:EnableMouse(true)
	chip.padTip = true
	W.Skin.Tooltip(chip, tip, "ANCHOR_BOTTOM")
	return chip
end

local function TabRow(index)
	local row = rows[index]
	if row then return row end
	local Skin = W.Skin
	row = CreateFrame("Button", nil, window)
	row:SetSize(TAB_WIDTH, TAB_HEIGHT)
	row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	row.chosen = row:CreateTexture(nil, "BACKGROUND")
	row.chosen:SetAllPoints()
	Skin.ChosenTint(row.chosen)
	row.chosen:Hide()
	local hover = row:CreateTexture(nil, "HIGHLIGHT")
	hover:SetAllPoints()
	Skin.HoverTint(hover)
	row.icon = Skin.Icon(row, TAB_HEIGHT - 8)
	row.icon:SetPoint("LEFT", row, "LEFT", 4, 0)
	row.name = Skin.Text(row, "GameFontNormal", "text")
	row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 8, -1)
	row.name:SetPoint("RIGHT", row, "RIGHT", -30, 0)
	row.name:SetJustifyH("LEFT")
	if row.name.SetWordWrap then row.name:SetWordWrap(false) end
	row.access = Skin.Text(row, "GameTooltipTextSmall", "muted")
	row.access:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 8, 1)
	row.found = Skin.Chip(row)
	row.found:SetPoint("RIGHT", row, "RIGHT", -4, 0)
	row:SetPoint("TOPLEFT", window, "TOPLEFT", window.margin, window.bodyTop - (index - 1) * (TAB_HEIGHT + 2))
	row:SetScript("OnClick", function(self, mouse)
		if self.buy then
			SaveText()
			buying = true
			ns.GuildDraw()
			return
		end
		-- Its name and its icon: the game's own window, on that tab, its editing open (for this visit only).
		if mouse == "RightButton" and self.editable then return ns.GuildEditTab(self.tab) end
		ns.GuildShowTab(self.tab)
	end)
	Skin.Tooltip(row, function(self) return self.tip end, "ANCHOR_RIGHT")
	rows[index] = row
	return row
end

local function PaintRows(current, query)
	local count = NumTabs()
	local editable = Clean(Call("CanEditGuildBankTabInfo")) and true or false
	local index = 0
	for tab = 1, count do
		index = index + 1
		local row = TabRow(index)
		local info = TabInfo(tab)
		local words = Access(info)
		row.tab, row.buy = tab, nil
		row.editable = editable and info.view
		row.padRight = row.editable or nil
		row.icon:Set(info.icon or "Interface\\Icons\\INV_Misc_QuestionMark", nil)
		row.name:SetText(info.name)
		row.access:SetText(words)
		local chosen = not buying and tab == current and page ~= "money"
		row.chosen:SetShown(chosen)
		row.name:SetTextColor(W.Skin.RGB(chosen and "gold" or "text"))
		-- (closed to your rank, or the gold log shown: greyed, as the game's)
		local usable = info.view and page ~= "money"
		row:SetEnabled(usable)
		row:SetAlpha(usable and 1 or 0.45)
		local found = info.view and query ~= "" and Found(tab, query) or 0
		row.found:Set(found > 0 and tostring(found) or nil, "gold")
		local tip = { info.name, { words, W.Skin.RGB("text") } }
		local left = info.view and LeftWords(info)
		if left then tip[#tip + 1] = { left, W.Skin.RGB("muted") } end
		if row.editable then tip[#tip + 1] = { L.GUILD_TAB_EDIT, W.Skin.RGB("blue") } end
		row.tip = tip
		row:Show()
	end
	if Buyable() then
		index = index + 1
		local row = TabRow(index)
		row.tab, row.buy, row.editable, row.padRight = count + 1, true, false, nil
		row.icon:Set("Interface\\GuildBankFrame\\UI-GuildBankFrame-NewTab", nil)
		row.name:SetText(L.GUILD_BUY_ROW)
		row.name:SetTextColor(W.Skin.RGB(buying and "gold" or "text"))
		row.access:SetText("")
		row.chosen:SetShown(buying)
		row:SetEnabled(true)
		row:SetAlpha(1)
		row.found:Set(nil)
		row.tip = { L.GUILD_BUY_ROW, { L.GUILD_BUY_DESC, W.Skin.RGB("text") } }
		row:Show()
	elseif buying then
		buying = false
	end
	for extra = index + 1, #rows do rows[extra]:Hide() end
end

-- The foot: the guild's gold, what you may take of it today, deposit and withdraw (the game's own questions).
local function WithdrawLimit()
	local limit = Clean(Call("GetGuildBankWithdrawMoney")) or 0
	if limit < 0 then return nil end
	local can = Clean(Call("CanWithdrawGuildBankMoney"))
	local money = can and (Clean(Call("GetGuildBankMoney")) or 0) or 0
	return math.min(limit, money)
end
ns.GuildWithdrawLimit = WithdrawLimit

local function CanWithdraw()
	if not Clean(Call("CanWithdrawGuildBankMoney")) then return false end
	local limit = WithdrawLimit()
	return limit == nil or limit > 0
end
ns.GuildCanWithdraw = CanWithdraw

local function PaintFoot()
	local money = Clean(Call("GetGuildBankMoney")) or 0
	window.money:SetText(L.GUILD_MONEY:format(U.Coins(money)))
	local limit = WithdrawLimit()
	if not Clean(Call("CanWithdrawGuildBankMoney")) then
		window.mayTake:SetText("")
	elseif limit == nil then
		window.mayTake:SetText(L.GUILD_MAY_TAKE_ANY)
	else
		window.mayTake:SetText(L.GUILD_MAY_TAKE:format(U.Coins(limit)))
	end
	local can = CanWithdraw()
	window.withdraw.allowed = can
	window.withdraw:SetEnabled(can)
end

-- One of the game's gold questions, the other one put away (a second click puts it away too).
local function GoldQuestion(name, other)
	Call("StaticPopup_Hide", other)
	if Clean(Call("StaticPopup_Visible", name)) then
		Call("StaticPopup_Hide", name)
	else
		Call("StaticPopup_Show", name)
	end
end
function ns.GuildDeposit() GoldQuestion("GUILDBANK_DEPOSIT", "GUILDBANK_WITHDRAW") end
function ns.GuildWithdraw()
	if not CanWithdraw() then return Refuse(L.GUILD_WITHDRAW_NO) end
	GoldQuestion("GUILDBANK_WITHDRAW", "GUILDBANK_DEPOSIT")
end

-- The tab to buy: the game's own question, with its price.
function ns.GuildBuy()
	if not Buyable() then return end
	local cost = Clean(Call("GetGuildBankTabCost")) or 0
	if (Clean(Call("GetGuildBankMoney")) or 0) < cost then return Refuse(L.GUILD_BUY_SHORT:format(U.Coins(cost - (Clean(Call("GetGuildBankMoney")) or 0)))) end
	Call("StaticPopup_Show", "CONFIRM_BUY_GUILDBANK_TAB")
end

local function PaintBuy()
	local card = window.buyCard
	local cost = Clean(Call("GetGuildBankTabCost")) or 0
	local money = Clean(Call("GetGuildBankMoney")) or 0
	local most = tonumber(Game("MAX_BUY_GUILDBANK_TABS")) or MaxTabs()
	card.count:SetText(L.GUILD_BUY_COUNT:format(NumTabs(), most))
	card.cost:SetText(L.GUILD_BUY_COST:format(U.Coins(cost)))
	local short = cost - money
	card.short:SetText(short > 0 and W.Skin.Colorize(L.GUILD_BUY_SHORT:format(U.Coins(short)), "warn") or "")
	card.button:SetEnabled(short <= 0)
	card.button.allowed = short <= 0
end

local function PaintInfo(tab)
	local info = window.info
	local text = Clean(Call("GetGuildBankText", tab)) or ""
	local editable = Clean(Call("CanEditGuildTabInfo", tab)) and true or false
	info.edit:SetShown(editable)
	info.read:SetShown(not editable)
	info.save:SetShown(false)
	if editable then
		-- (what is being written stays while the game tells the text again)
		if info.edit.tab ~= tab or not info.edit:HasFocus() then
			info.edit.tab, info.edit.saved = tab, text
			info.edit:SetText(text)
		end
		info.save:SetShown((info.edit:GetText() or "") ~= (info.edit.saved or ""))
	else
		info.read:SetText(text ~= "" and text or W.Skin.Colorize(L.GUILD_INFO_EMPTY, "muted"))
	end
end

local function ShowPage(name)
	for key, frame in pairs(window.pages) do frame:SetShown(key == name) end
end

function ns.GuildDraw()
	if not (window and window:IsShown()) then return end
	local settings = Settings()
	if not settings then return end
	local title = Clean(Safe(GetGuildInfo, "player"))
	window.title:SetText(title or L.GUILD_BANK)
	local count = NumTabs()
	local current = Current()
	-- The tab shown: one open to you (the first one when the game's is not).
	if not buying and count > 0 and not (current <= count and TabInfo(current).view) and not Clean(Call("IsGuildLeader")) then
		for tab = 1, count do
			if TabInfo(tab).view then
				Call("SetCurrentGuildBankTab", tab)
				Ask(tab)
				current = tab
				break
			end
		end
	end
	-- No tab bought yet: the guild master buys the first.
	if count == 0 and Buyable() then buying = true end
	local query = Query()
	PaintRows(current, query)
	local info = current <= count and TabInfo(current) or nil
	-- The tab's chips: what your rank allows there, the withdrawals left today.
	local access, tone = nil, nil
	if info and info.view and not buying and page ~= "money" then access, tone = Access(info) end
	window.chips.access:Set(access, tone)
	local left, leftTone = nil, nil
	if info and info.view and not buying and page ~= "money" then left, leftTone = LeftWords(info) end
	window.chips.left:Set(left, leftTone)
	window.chips.left:ClearAllPoints()
	if window.chips.access:IsShown() then
		window.chips.left:SetPoint("LEFT", window.chips.access, "RIGHT", 6, 0)
	else
		window.chips.left:SetPoint("TOPLEFT", window.title, "BOTTOMLEFT", 0, -10)
	end
	window.tabs:Select(page)
	-- The page: the tab to buy, a word when nothing is open to you, else the page chosen.
	local message
	if buying then
		ShowPage("buy")
		PaintBuy()
	elseif page == "money" then
		ShowPage("log")
		DrawLog(ns.GuildMoneyLog())
	elseif count == 0 then
		message = L.GUILD_NO_TABS
	elseif NoneViewable() then
		message = page == "log" and L.GUILD_NO_LOG or L.GUILD_NO_VIEW
	elseif page == "log" then
		ShowPage("log")
		DrawLog(ns.GuildItemLog(current))
	elseif page == "info" then
		ShowPage("info")
		PaintInfo(current)
	else
		ShowPage("items")
		local size = settings.iconSize or 36
		if size ~= laidSize then LaySquares(size) end
		for slot = 1, SLOTS do PaintSquare(squares[slot], ReadItem(current, slot), query, settings) end
	end
	if message then
		ShowPage("message")
		window.message:SetText(message)
	end
	PaintFoot()
end

function ns.GuildPage(name)
	buying = false
	page = name
	Ask()
	ns.GuildDraw()
end

-- The window's size: the tabs' column and the squares (their size from the bags' settings).
local function Size()
	local settings = Settings()
	local width, height = LaySquares(settings and settings.iconSize or 36)
	local margin = window.margin
	window:SetSize(margin * 2 + TAB_WIDTH + 16 + width, -window.bodyTop + 30 + height + 12 + FOOT + margin)
end

local function Create()
	local Skin = W.Skin
	window = Skin.CreateWindow("WandererBagsGuildBank", "MEDIUM")
	-- No sound of its own: it opens and closes with the vault, whose own window (kept open, aside) plays the game's.
	window.wandererSounds = true
	Skin.Dress(window, { "TOPLEFT", UIParent, "TOPLEFT", 40, -120 }, "WandererBagsGuildBankPos")
	local _, title, margin = Skin.Header(window, L.GUILD_BANK, L.GUILD_BANK, { margin = 10, settings = "ext:bags" }, "GameFontNormalLarge")
	window.title, window.margin = title, margin
	window.bodyTop = -(margin + 104)
	if Skin.Help then Skin.Help(window, L.GUILD_HELP, "HEADING") end
	-- The game's own window, on the right (the "?", the cog and the cross after it).
	window.game = Skin.SmallButton(window, Skin.GlyphText("move", "label") .. " " .. L.GUILD_GAME, function()
		ns.GuildUseGame(true)
	end, L.GUILD_GAME_DESC)
	window.game:SetPoint("TOPRIGHT", window, "TOPRIGHT", -(margin + 78), -margin + 2)
	window.chips = { access = Chip(L.GUILD_ACCESS_TIP), left = Chip(L.GUILD_LEFT_TIP) }
	window.chips.access:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -10)
	-- The pages, over a thin rule.
	local rule = Skin.Rule(window)
	rule:SetPoint("TOPLEFT", window, "TOPLEFT", margin, -(margin + 92))
	rule:SetPoint("RIGHT", window, "RIGHT", -margin, 0)
	window.tabs = Skin.Tabs(window, { { "items", L.GUILD_PAGE_ITEMS }, { "log", L.GUILD_PAGE_LOG }, { "money", L.GUILD_PAGE_MONEY },
		{ "info", L.GUILD_PAGE_INFO } }, function(name) ns.GuildPage(name) end)
	window.tabs:SetPoint("BOTTOMLEFT", rule, "TOPLEFT", 0, 0)
	window.pages = {}
	local function Page(name)
		local frame = CreateFrame("Frame", nil, window)
		frame:SetPoint("TOPLEFT", window, "TOPLEFT", margin + TAB_WIDTH + 16, window.bodyTop)
		frame:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -margin, margin + FOOT)
		frame:Hide()
		window.pages[name] = frame
		return frame
	end
	-- Items: the search of the bags, the squares.
	local items = Page("items")
	window.search = Skin.CreateInput(items, "WandererBagsGuildSearch", 40, {
		hint = L.SEARCH,
		onChange = function() if drawSoon then drawSoon() end end,
		onEscape = function(box)
			box:SetText("")
			box:ClearFocus()
		end,
	})
	window.search:SetHeight(20)
	window.search:SetPoint("TOPLEFT", items, "TOPLEFT", 0, 0)
	window.search:SetPoint("RIGHT", items, "RIGHT", 0, 0)
	Skin.Tooltip(window.search, { L.SEARCH_HELP_TITLE, { L.GUILD_SEARCH_HELP, Skin.RGB("text") } }, "ANCHOR_BOTTOM")
	window.grid = CreateFrame("Frame", nil, items)
	window.grid:SetPoint("TOPLEFT", items, "TOPLEFT", 0, -30)
	for slot = 1, SLOTS do squares[slot] = Square(window.grid, slot) end
	-- The logs (items of the tab shown, or gold): the newest first, the wheel scrolls.
	local log = Page("log")
	window.log = log
	log.offset = 0
	local shown = math.floor((ROWS * 40) / LOG_ROW)
	for index = 1, shown do
		local row = LogRow(log)
		row:SetPoint("TOPLEFT", log, "TOPLEFT", 0, -(index - 1) * LOG_ROW)
		row:SetPoint("RIGHT", log, "RIGHT", -(Skin.SCROLL_WIDTH or 10) - 4, 0)
		logRows[index] = row
	end
	log.bar = Skin.ScrollBar(log, function(offset)
		log.offset = offset
		DrawLog(log.lines or {})
	end)
	log.bar:SetPoint("TOPRIGHT", log, "TOPRIGHT", 0, 0)
	log.bar:SetPoint("BOTTOMRIGHT", log, "BOTTOMRIGHT", 0, 0)
	log:EnableMouseWheel(true)
	log:SetScript("OnMouseWheel", function(_, delta)
		log.offset = (log.offset or 0) - delta * 3
		DrawLog(log.lines or {})
	end)
	log.empty = Skin.Text(log, "GameTooltipText", "muted")
	log.empty:SetPoint("TOPLEFT", log, "TOPLEFT", 4, -4)
	log.empty:SetText(L.GUILD_LOG_EMPTY)
	-- The tab's text: written here by those whose rank may, read by the others.
	local infoPage = Page("info")
	local info = { page = infoPage }
	window.info = info
	info.read = Skin.Text(infoPage, "GameTooltipText", "text")
	info.read:SetPoint("TOPLEFT", infoPage, "TOPLEFT", 4, -4)
	info.read:SetPoint("RIGHT", infoPage, "RIGHT", -4, 0)
	info.read:SetJustifyH("LEFT")
	if info.read.SetWordWrap then info.read:SetWordWrap(true) end
	-- (a page of its own: a dark ground, a thin gold edge, the words written on it)
	info.edit = CreateFrame("EditBox", "WandererBagsGuildText", infoPage)
	info.edit:SetMultiLine(true)
	info.edit:SetAutoFocus(false)
	info.edit:SetMaxLetters(500)
	info.edit:SetFontObject(Skin.FontFor("ChatFontNormal"))
	info.edit:SetTextInsets(8, 8, 8, 8)
	info.edit:SetPoint("TOPLEFT", infoPage, "TOPLEFT", 0, 0)
	info.edit:SetPoint("BOTTOMRIGHT", infoPage, "BOTTOMRIGHT", 0, 40)
	local paper = info.edit:CreateTexture(nil, "BACKGROUND")
	paper:SetAllPoints()
	paper:SetColorTexture(0, 0, 0, 0.35)
	-- (the game look: the game's sunken frame around the page, no gold edge)
	local inset
	if Skin.GameWindows() and Skin.Game("InsetFrameTemplate") then
		local ok, made = pcall(CreateFrame, "Frame", nil, infoPage, "InsetFrameTemplate")
		if ok and type(made) == "table" then inset = made end
	end
	if inset then
		inset:SetAllPoints(info.edit)
		inset:SetFrameLevel(math.max(0, info.edit:GetFrameLevel() - 1))
		paper:Hide()
	else
		Skin.Edges(info.edit, Skin.RGB("gold", 0.12))
	end
	info.hint = Skin.Text(info.edit, "GameTooltipTextSmall", "muted")
	info.hint:SetPoint("TOPLEFT", info.edit, "TOPLEFT", 9, -9)
	info.hint:SetText(L.GUILD_INFO_HINT)
	info.edit:SetScript("OnTextChanged", function(box)
		local text = box:GetText() or ""
		info.hint:SetShown(text == "")
		info.save:SetShown(text ~= (box.saved or ""))
	end)
	info.edit:SetScript("OnEscapePressed", function(box) box:ClearFocus() end)
	info.save = Skin.Button(infoPage, L.GUILD_SAVE, function()
		SaveText()
		info.edit:ClearFocus()
		info.save:Hide()
	end, "main")
	info.save:SetHeight(26)
	info.save:SetPoint("BOTTOMRIGHT", infoPage, "BOTTOMRIGHT", 0, 6)
	Skin.Tooltip(info.save, L.GUILD_SAVE_DESC)
	-- The tab to buy (the guild master).
	local buy = Page("buy")
	local card = {}
	window.buyCard = card
	card.title = Skin.Text(buy, "GameFontNormalLarge", "gold")
	card.title:SetPoint("TOPLEFT", buy, "TOPLEFT", 4, -8)
	card.title:SetText(L.GUILD_BUY_TITLE)
	card.count = Skin.Text(buy, "GameTooltipText", "soft")
	card.count:SetPoint("TOPLEFT", card.title, "BOTTOMLEFT", 0, -10)
	card.cost = Skin.Text(buy, "GameTooltipText", "text")
	card.cost:SetPoint("TOPLEFT", card.count, "BOTTOMLEFT", 0, -6)
	card.short = Skin.Text(buy, "GameTooltipText", "text")
	card.short:SetPoint("TOPLEFT", card.cost, "BOTTOMLEFT", 0, -6)
	card.button = Skin.Button(buy, L.GUILD_BUY, function() ns.GuildBuy() end, "main")
	card.button:SetPoint("TOPLEFT", card.short, "BOTTOMLEFT", 0, -14)
	Skin.Tooltip(card.button, L.GUILD_BUY_DESC)
	-- A word when nothing is open to you.
	local message = Page("message")
	window.message = Skin.Text(message, "GameTooltipText", "muted")
	window.message:SetPoint("TOPLEFT", message, "TOPLEFT", 4, -8)
	window.message:SetPoint("RIGHT", message, "RIGHT", -4, 0)
	window.message:SetJustifyH("LEFT")
	-- The foot.
	local footRule = Skin.Rule(window, false, 0.14)
	footRule:SetPoint("BOTTOMLEFT", window, "BOTTOMLEFT", margin, margin + FOOT - 6)
	footRule:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -margin, margin + FOOT - 6)
	window.withdraw = Skin.SmallButton(window, L.GUILD_WITHDRAW, function() ns.GuildWithdraw() end, function(self)
		return self.allowed and L.GUILD_WITHDRAW_DESC or L.GUILD_WITHDRAW_NO
	end, 22)
	window.withdraw:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -margin, margin - 2)
	window.deposit = Skin.SmallButton(window, L.GUILD_DEPOSIT, function() ns.GuildDeposit() end, L.GUILD_DEPOSIT_DESC, 22)
	window.deposit:SetPoint("RIGHT", window.withdraw, "LEFT", -8, 0)
	window.money = Skin.Text(window, "GameTooltipText", "text")
	window.money:SetPoint("BOTTOMLEFT", window, "BOTTOMLEFT", margin, margin + 2)
	window.mayTake = Skin.Text(window, "GameTooltipTextSmall", "muted")
	window.mayTake:SetPoint("LEFT", window.money, "RIGHT", 16, 0)
	window.mayTake:SetPoint("RIGHT", window.deposit, "LEFT", -12, 0)
	if window.mayTake.SetWordWrap then window.mayTake:SetWordWrap(false) end
	window.mayTake:SetJustifyH("LEFT")
	Size()
	window:HookScript("OnShow", function(self)
		Size()
		self:SetScale(Skin.FitScale(self))
		ns.GuildDraw()
	end)
	-- Closed by hand (its cross, Escape): the visit ends with it, as the game's window does.
	window:HookScript("OnHide", function(self)
		if switching or self:IsShown() or not atBank or mode ~= "wanderer" then return end
		Call("CloseGuildBankFrame")
	end)
end

function ns.GuildWindow() return window end
function ns.GuildAtBank() return atBank end
function ns.GuildMode() return mode end

local function Open()
	if not window then Create() end
	if window:IsShown() then ns.GuildDraw() else window:Show() end
end

-- The game's window ------------------------------------------------------------------------------------------

local function PlaceGame() if placeGame then placeGame() end end

local function HookGame()
	local frame = rawget(_G, "GuildBankFrame")
	if placeGame or type(frame) ~= "table" or not frame.HookScript then return end
	placeGame = W.Skin.AsideGameWindow(frame, function() return atBank and mode == "wanderer" end)
	-- (the game puts its window away when the vault is out of reach: the visit ends with it)
	frame:HookScript("OnHide", function() if ns.GuildVisitEnded then ns.GuildVisitEnded() end end)
end

-- The game's window shows our tab, as it is now (its own drawing, called safely).
local function SyncGame()
	local frame = rawget(_G, "GuildBankFrame")
	if type(frame) ~= "table" then return end
	if frame.UpdateTabs then Safe(frame.UpdateTabs, frame) end
	if frame.Update then Safe(frame.Update, frame) end
end

-- The link above the game's window, back to Wanderer's.
local function Reopen()
	local frame = rawget(_G, "GuildBankFrame")
	if reopen or type(frame) ~= "table" then return end
	reopen = W.Skin.SmallButton(UIParent, W.Skin.GlyphText("chevron", "label") .. " " .. L.GUILD_BACK, function()
		ns.GuildUseWanderer()
	end, L.GUILD_BACK_DESC)
	reopen:SetFrameStrata("HIGH")
	reopen:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", 0, 4)
	reopen:Hide()
end

local function ShowReopen()
	if reopen then reopen:SetShown(atBank and mode == "game" and ns.On()) end
end

-- The game's window, Wanderer's out of sight (the vault stays open). keep: the choice kept for the next visits.
function ns.GuildUseGame(keep)
	if keep then Choose(false) end
	mode = "game"
	if window and window:IsShown() then
		switching = true
		window:Hide()
		switching = false
	end
	HookGame()
	Reopen()
	PlaceGame()
	SyncGame()
	ShowReopen()
end

-- Wanderer's window, the game's out of sight; kept for the next visits.
function ns.GuildUseWanderer()
	Choose(true)
	if not atBank then return end
	mode = "wanderer"
	ShowReopen()
	PlaceGame()
	Open()
end

-- A tab's name and icon: the game's own window on that tab, its editing open (this visit only).
function ns.GuildEditTab(tab)
	if not Clean(Call("CanEditGuildBankTabInfo")) then return end
	SaveText()
	Call("SetCurrentGuildBankTab", tab)
	ns.GuildUseGame(false)
	local frame = rawget(_G, "GuildBankFrame")
	local tabs = type(frame) == "table" and frame.BankTabs
	local button = type(tabs) == "table" and tabs[tab]
	if type(button) == "table" and button.OnClick then Safe(button.OnClick, button, "RightButton") end
end

-- The visit --------------------------------------------------------------------------------------------------

local AT_BANK = { "GUILDBANKBAGSLOTS_CHANGED", "GUILDBANK_ITEM_LOCK_CHANGED", "GUILDBANK_UPDATE_TABS", "GUILDBANK_UPDATE_MONEY",
	"GUILDBANK_UPDATE_WITHDRAWMONEY", "GUILD_ROSTER_UPDATE", "GUILDBANKLOG_UPDATE", "GUILDBANK_UPDATE_TEXT", "GUILDBANK_TEXT_CHANGED" }

local events
local function Hear(on)
	for _, event in ipairs(AT_BANK) do pcall(on and events.RegisterEvent or events.UnregisterEvent, events, event) end
end

local function Arrived()
	if atBank or not ns.On() then return end
	atBank, buying, page, heldFromGuild = true, false, "items", false
	answered = {}
	mode = Wanted() and "wanderer" or "game"
	Hear(true)
	-- The game's window comes with the vault: placed now if it is there, else a moment later (loaded on demand).
	local function Place()
		HookGame()
		Reopen()
		PlaceGame()
		ShowReopen()
	end
	Place()
	C_Timer.After(0, function() if atBank then Place() end end)
	if mode == "wanderer" then
		if window and window.search then window.search:SetText("") end
		Open()
		if ns.Bags and ns.Bags.Open then ns.Bags.Open() end
	end
	Ask()
end

local function Ended()
	if not atBank then return end
	atBank = false
	Hear(false)
	if window and window:IsShown() then
		switching = true
		window:Hide()
		switching = false
	end
	PlaceGame()
	if reopen then reopen:Hide() end
	if ns.Bags and ns.Bags.Soon then ns.Bags.Soon() end
end

function ns.GuildVisitEnded()
	C_Timer.After(0, function()
		local frame = rawget(_G, "GuildBankFrame")
		if atBank and not (type(frame) == "table" and frame:IsShown()) then Ended() end
	end)
end

-- A setting changed (the bags' extension, this window's): the window chosen now is the one shown.
function ns.GuildRefresh()
	if not atBank then return end
	if not ns.On() then
		if mode == "wanderer" then ns.GuildUseGame(false) end
		ShowReopen()
		return
	end
	if Wanted() and mode ~= "wanderer" then
		mode = "wanderer"
		ShowReopen()
		PlaceGame()
		Open()
	elseif not Wanted() and mode == "wanderer" then
		ns.GuildUseGame(false)
	else
		ns.GuildDraw()
	end
end

local function Banker()
	local types = Enum and Enum.PlayerInteractionType
	return types and types.GuildBanker
end

function ns.InitGuildBank()
	-- (a client without a guild bank: nothing heard, nothing said)
	if not ns.HasGuildBank() then return end
	drawSoon = U.Debounce(DRAW_DELAY, ns.GuildDraw)
	-- Wanderer Bags' own refresh (a setting changed): this window follows.
	local refreshAll = ns.RefreshAll
	function ns.RefreshAll(...)
		refreshAll(...)
		ns.GuildRefresh()
	end
	events = CreateFrame("Frame")
	events:SetScript("OnEvent", function(_, event, ...)
		if event == "GUILDBANKFRAME_OPENED" then return Arrived() end
		if event == "GUILDBANKFRAME_CLOSED" then return Ended() end
		if event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" or event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
			local banker = Banker()
			if not (banker and ... == banker) then return end
			if event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then return Arrived() end
			return Ended()
		end
		if event == "GUILDBANKBAGSLOTS_CHANGED" then answered[Current()] = true end
		-- (the tab's text changed by someone: asked again when it is the one shown)
		if event == "GUILDBANK_TEXT_CHANGED" then
			if page == "info" and tonumber(...) == Current() then Call("QueryGuildBankText", Current()) end
			return
		end
		if drawSoon then drawSoon() end
	end)
	for _, event in ipairs({ "GUILDBANKFRAME_OPENED", "GUILDBANKFRAME_CLOSED", "PLAYER_INTERACTION_MANAGER_FRAME_SHOW",
		"PLAYER_INTERACTION_MANAGER_FRAME_HIDE" }) do
		pcall(events.RegisterEvent, events, event)
	end
end
