-- ReserveWindow.lua -- what is up for loot, who reserved it, and what you
-- reserved tonight.
--
-- The raider-facing half of this addon. An officer has the voting column and
-- the tooltip; until now a raider had a whisper and a good memory.
--
-- Two sections, and the second one is the whole reason the feature was asked
-- for. The top section answers "did I reserve this, and who am I up against" at
-- the moment the item drops. The bottom answers "what did I put on the list
-- last week", which is the thing people actually forget.
--
-- EVERY ITEM IN THE SESSION, not just the reserved ones. An item missing from
-- this list would be indistinguishable from an item nobody reserved AND from a
-- broken character-key match -- the exact ambiguity this addon exists to
-- remove. So unreserved items are listed with "no reserves" said out loud, and
-- absence never has to be interpreted.

local _, ns = ...

local Reservers = ns.Reservers
local Tiers = ns.Tiers

local ReserveWindow = {}
ns.ReserveWindow = ReserveWindow

local WIDTH, HEIGHT = 420, 440
local LINE_H = 14

local frame, content, header, scroll, child, lines

--------------------------------------------------------------------------------
-- Lines
--------------------------------------------------------------------------------

local function Reset()
	for _, fs in ipairs(lines) do
		fs:SetText("")
		fs:Hide()
	end
	lines.n = 0
end

-- Absolute placement by index, not chained off the previous line. The chained
-- version has to carry the previous indent forward to cancel it, which is one
-- arithmetic slip from a column of text walking off the side of the frame --
-- the same lesson OfficerFrame.lua already learned.
local function AddLine(text, r, g, b, indent)
	lines.n = lines.n + 1
	indent = indent or 0

	local fs = lines[lines.n]
	if not fs then
		fs = child:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		fs:SetJustifyH("LEFT")
		lines[lines.n] = fs
	end

	fs:ClearAllPoints()
	fs:SetPoint("TOPLEFT", child, "TOPLEFT", 4 + indent, -((lines.n - 1) * LINE_H))
	fs:SetWidth(WIDTH - 40 - indent)
	fs:SetText(text)
	fs:SetTextColor(r or 1, g or 1, b or 1)
	fs:Show()
end

-- Class colour, via the same route the tooltip uses. Falls back to white rather
-- than to nothing: an uncoloured name is still a readable name.
local function Colourise(name, class)
	local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
	if not c then return name end
	return ("|cff%02x%02x%02x%s|r"):format(c.r * 255, c.g * 255, c.b * 255, name)
end

--------------------------------------------------------------------------------
-- Contents
--------------------------------------------------------------------------------

-- The viewer's own folded key, or nil. Screened before folding, because the
-- name comes in from the game.
local function MyKey()
	local ok, key = pcall(function()
		local name, realm = UnitFullName("player")
		if not name then return nil end
		if not realm or realm == "" then realm = GetNormalizedRealmName() end
		return ns.Names.Fold(ns.Names.Key(name, realm))
	end)
	if not ok then return nil end
	return key
end

local function DrawSessionItems(set, myKey)
	local items = ns.RC:SessionItems()
	if not items then
		AddLine("No loot session in progress.", 0.6, 0.6, 0.6)
		return
	end

	for _, item in ipairs(items) do
		AddLine(ns.ItemLabel(item.itemId, set))

		local result = Reservers.For(set, item.itemId)
		if not result then
			-- Said, not implied. A blank here would read exactly like a key
			-- mismatch, which is the one failure this addon cannot see.
			AddLine("no reserves", 0.55, 0.55, 0.55, 12)
		else
			local mine = false
			for _, e in ipairs(result.entries) do
				if myKey and e.key == myKey then mine = true end
			end

			local line = Reservers.Line(result, Colourise)
			AddLine(line or "", 0.85, 0.85, 0.85, 12)

			if mine then
				AddLine("you reserved this", 0.55, 0.9, 0.55, 12)
			end
		end

		-- A blank line of air between items. An actual line rather than a
		-- fractional bump to lines.n -- lines[] is indexed by that counter, and
		-- a non-integer index silently starts a second, parallel set of keys
		-- that Reset() never clears.
		AddLine(" ")
	end
end

local function DrawMyReserves(set, myKey)
	AddLine(" ")
	AddLine("Your reserves tonight", 0.6, 0.75, 1)

	if not myKey then
		AddLine("could not read your character name", 0.8, 0.5, 0.5, 12)
		return
	end

	-- Grouped by tier, hardest first, the way the guild talks about it and the
	-- way the whisper reply already reads. Two surfaces showing the same facts
	-- in different orders is how somebody ends up asking an officer which one
	-- is right.
	local found = {}
	for itemId, holders in pairs(set.reserves) do
		local tier = holders[myKey]
		if tier then
			found[#found + 1] = { itemId = itemId, tier = tier }
		end
	end

	if #found == 0 then
		AddLine("you have no reserves on this list", 0.6, 0.6, 0.6, 12)
		return
	end

	table.sort(found, function(a, b)
		local ra, rb = Tiers.Rank(a.tier), Tiers.Rank(b.tier)
		if ra ~= rb then return ra < rb end
		return tostring(ns.ItemPlainName(a.itemId, set)) < tostring(ns.ItemPlainName(b.itemId, set))
	end)

	for _, r in ipairs(found) do
		AddLine(("%s  |cff888888(%s)|r"):format(ns.ItemLabel(r.itemId, set), Tiers.Label(r.tier)), 0.9, 0.9, 0.9, 12)
	end
end

--------------------------------------------------------------------------------
-- Frame
--------------------------------------------------------------------------------

local function Build()
	frame, content = ns.Window.New("SGDDReservesDropWindow", "reserves",
		"SGDD Reserves", WIDTH, HEIGHT)
	lines = { n = 0 }

	header = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	header:SetPoint("TOPLEFT", content, "TOPLEFT", 12, -14)
	header:SetWidth(WIDTH - 30)
	header:SetJustifyH("LEFT")

	scroll = CreateFrame("ScrollFrame", "SGDDReservesDropScroll", content, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -8)
	scroll:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -30, 14)

	child = CreateFrame("Frame", nil, scroll)
	child:SetSize(WIDTH - 40, 1)
	scroll:SetScrollChild(child)
end

function ReserveWindow:Refresh()
	if not frame then return end
	Reset()

	local set = ns.AnySet()
	if not set then
		header:SetText("No reserve list. Use |cff8b5cf6/rc askml|r to ask the master looter.")
		child:SetHeight(1)
		return
	end

	header:SetText(ns.FreshnessLine(set))

	local myKey = MyKey()
	DrawSessionItems(set, myKey)
	DrawMyReserves(set, myKey)

	child:SetHeight(math.max(1, lines.n * LINE_H + 10))
end

function ReserveWindow:Show()
	if not frame then Build() end
	self:Refresh()
	frame:Show()
end

function ReserveWindow:Toggle()
	if frame and frame:IsShown() then
		frame:Hide()
		return
	end
	self:Show()
end

return ReserveWindow
