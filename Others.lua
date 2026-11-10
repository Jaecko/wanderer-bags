local _, ns = ...
local L = ns.L

-- What your other characters carry: over an item, which of them have it, in
-- their bags or their bank, as last seen. Each character's bags are counted
-- when they change, its bank when the banker shows it; kept by character in
-- the account's saved variables. Only the characters Wanderer has met.

local W = Wanderer
local U = W and W.Util
local Clean = U and U.Clean

local NOTE_DELAY = 1 -- seconds after the last change of the bags

local function Store()
	WandererBagsDB = type(WandererBagsDB) == "table" and WandererBagsDB or {}
	local db = WandererBagsDB
	db.carried = type(db.carried) == "table" and db.carried or {}
	return db.carried
end

-- This character's bags and bank, counted by item.
function ns.NoteCarried()
	local store = Store()
	local items = {}
	U.EachBagItem(function(_, _, info)
		local id = Clean(info.itemID)
		if id then items[id] = (items[id] or 0) + (Clean(info.stackCount) or 1) end
	end)
	local me = W.CharacterKey()
	store[me] = { time = time(), items = items, bank = ns.SavedBankCounts() }
	-- (the list of characters once compared here: Wanderer now says who is forgotten, below)
	WandererBagsDB.listed = nil
end

-- A character let go in Wanderer (its characters window): what it carried, its marks and its bank as seen let go
-- here too (all kept by its GUID: Wanderer's key).
function ns.ForgetCharacter(key)
	local db = WandererBagsDB
	if not (key and type(db) == "table") then return end
	for _, name in ipairs({ "carried", "choices", "characters" }) do
		if type(db[name]) == "table" then db[name][key] = nil end
	end
end
-- (the delay made at the first change, never at loading)
local noteSoon
function ns.NoteCarriedSoon()
	noteSoon = noteSoon or U.Debounce(NOTE_DELAY, function() ns.NoteCarried() end)
	noteSoon()
end

-- Who else has this item: { { name, class, bags, bank } }, the most first.
function ns.Carriers(id)
	local list = {}
	local store = Store()
	if not id then return list end
	for _, who in ipairs(W.Characters(true)) do
		local kept = store[who.key]
		if type(kept) == "table" then
			local bags, bank = (kept.items or {})[id] or 0, (kept.bank or {})[id] or 0
			if bags + bank > 0 then list[#list + 1] = { name = who.name, class = who.class, bags = bags, bank = bank } end
		end
	end
	table.sort(list, function(a, b) return a.bags + a.bank > b.bags + b.bank end)
	return list
end

local function ClassColoredName(name, class)
	local r, g, b = U.ClassColor(class)
	return r and U.Colorize(name, r, g, b) or name
end

-- How many: "12", "12 (bank 3)", "(bank 3)".
local function Amount(bags, bank)
	if bank > 0 and bags > 0 then return L.OTHERS_BOTH:format(bags, bank) end
	if bank > 0 then return L.OTHERS_BANK:format(bank) end
	return tostring(bags)
end

-- What your other characters have whose name holds a word: "Alice: Potion 12 (bank 3), ..." (nil: none).
local MAX_FOUND = 6
local names = {} -- item id -> its name (and in small letters), once known
local function NameOf(id)
	local known = names[id]
	if known then return known.lower, known.name end
	local name = U.ItemName(id)
	if not name then
		ns.AskItem(id)
		return nil
	end
	-- (folded as the search is: accents and capitals aside)
	names[id] = { lower = U.Fold and U.Fold(name) or name:lower(), name = name }
	return names[id].lower, name
end
function ns.CarriedElsewhere(query)
	local store = Store()
	-- (an option: off, nothing said of the others)
	local settings = ns.Settings()
	if not (settings and settings.others) or type(query) ~= "string" or query == "" then return nil end
	local parts, count = {}, 0
	for _, who in ipairs(W.Characters(true)) do
		local kept = store[who.key]
		if type(kept) == "table" then
			local ids = {}
			for id in pairs(kept.items or {}) do ids[id] = true end
			for id in pairs(kept.bank or {}) do ids[id] = true end
			for id in pairs(ids) do
				local lower, name = NameOf(id)
				if lower and name and lower:find(query, 1, true) and count < MAX_FOUND then
					count = count + 1
					local amount = Amount((kept.items or {})[id] or 0, (kept.bank or {})[id] or 0)
					parts[#parts + 1] = ClassColoredName(who.name, who.class) .. ": " .. name .. " " .. amount
				end
			end
		end
	end
	if not parts[1] then return nil end
	return L.OTHERS_LINE:format(table.concat(parts, U.SEPARATOR))
end

-- Your other characters carrying it, one per line: { name (in its class colour), amount }.
local function Rows(id)
	local settings = ns.Settings()
	if not (settings and settings.enabled and settings.others) then return nil end
	-- (another addon already says it in the same tooltip)
	if W.Yields and W.Yields("altCounts") then return nil end
	local rows = {}
	for _, who in ipairs(ns.Carriers(id)) do
		rows[#rows + 1] = { ClassColoredName(who.name, who.class), Amount(who.bags, who.bank) }
	end
	return rows[1] and rows or nil
end

function ns.InitOthers()
	W.OnCharacterForgotten(ns.ForgetCharacter)
	-- (a clear list: a heading, then each character on its own line, its count on the right)
	U.OnItemTooltip(function(tooltip, id)
		local rows = Rows(id)
		if not rows then return false end
		local blue = W.Skin.COLORS.blue
		tooltip:AddLine(L.OTHERS_HEADING, blue[1], blue[2], blue[3])
		for _, row in ipairs(rows) do tooltip:AddDoubleLine("  " .. row[1], row[2], 1, 1, 1, blue[1], blue[2], blue[3]) end
		return true
	end)
end
