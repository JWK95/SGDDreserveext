-- ResponseWindow.lua -- what everyone answered, and what they rolled.
--
-- The second of the two windows. Kept separate from ReserveWindow because they
-- answer different questions from different data: reserves are ours, imported
-- from the guild's website; responses are RCLootCouncil's, arriving live over
-- its comms. They open together and close independently.
--
-- WHOSE ANSWERS ARE SHOWN IS NOT THIS FILE'S DECISION. Consolidation.Build
-- makes it, honouring RCLootCouncil's "observe" setting, and the long note at
-- the top of that file explains why it honours it when it could trivially not.
-- This file draws whatever comes back and prints the reason when rows are
-- missing -- never a silently short list.

local _, ns = ...

local Consolidation = ns.Consolidation

local ResponseWindow = {}
ns.ResponseWindow = ResponseWindow

local WIDTH, HEIGHT = 380, 340
local LINE_H = 14

local frame, content, header, note, scroll, child, lines

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

local function Colourise(name, class)
	local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
	if not c then return name end
	return ("|cff%02x%02x%02x%s|r"):format(c.r * 255, c.g * 255, c.b * 255, name)
end

--------------------------------------------------------------------------------
-- Frame
--------------------------------------------------------------------------------

local function Build()
	frame, content = ns.Window.New("SGDDReservesResponseWindow", "responses",
		"SGDD Loot Responses", WIDTH, HEIGHT)
	lines = { n = 0 }

	header = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	header:SetPoint("TOPLEFT", content, "TOPLEFT", 12, -14)
	header:SetWidth(WIDTH - 30)
	header:SetJustifyH("LEFT")

	note = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	note:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
	note:SetWidth(WIDTH - 30)
	note:SetJustifyH("LEFT")

	scroll = CreateFrame("ScrollFrame", "SGDDReservesResponseScroll", content, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", note, "BOTTOMLEFT", 0, -8)
	scroll:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -30, 14)

	child = CreateFrame("Frame", nil, scroll)
	child:SetSize(WIDTH - 40, 1)
	scroll:SetScrollChild(child)
end

--------------------------------------------------------------------------------
-- Contents
--------------------------------------------------------------------------------

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

-- Every item in the session, each with its own answers.
--
-- Deliberately NOT "the item currently up for vote". GetCurrentSession lives on
-- RCVotingFrame, which is disabled on an ordinary raider's client -- so keying
-- this window to the current session would leave it permanently empty for
-- exactly the people it was built for. Listing every item sidesteps a question
-- this client cannot answer, and it matches how the reserve window already
-- reads.
function ResponseWindow:Refresh()
	if not frame then return end
	Reset()

	local items = ns.RC:SessionItems()
	if not items then
		header:SetText("No loot session in progress.")
		note:SetText("")
		child:SetHeight(1)
		return
	end

	local set = ns.AnySet()
	header:SetText(("%d item%s up for loot"):format(#items, #items == 1 and "" or "s"))

	-- Observe is a tri-state on the way in: true, false, or "nobody has told us
	-- yet" when the MLDB has not arrived. Unknown is treated as OFF, which is
	-- the conservative direction -- showing everyone's answers because we have
	-- not heard otherwise would be exactly the override this addon declines to
	-- make.
	local observe = ns.RC:Observe() == true
	local viewer = MyKey()
	local hiddenLine

	for _, item in ipairs(items) do
		AddLine(ns.ItemLabel(item.itemId, set))

		local result = Consolidation.Build(ns.Responses:For(item.session), {
			observe = observe,
			viewer = viewer,
		})

		hiddenLine = hiddenLine or Consolidation.HiddenLine(result)

		if #result.rows == 0 then
			AddLine("no responses yet", 0.55, 0.55, 0.55, 12)
		end

		for _, row in ipairs(result.rows) do
			local roll = row.roll and tostring(row.roll) or Consolidation.NO_ROLL
			local name = Colourise(row.display, row.class)
			local line = ("%s  |cff888888%s|r  %s"):format(name, row.response, roll)
			if row.mine then
				AddLine(line, 0.55, 0.9, 0.55, 12)
			else
				AddLine(line, 0.9, 0.9, 0.9, 12)
			end
		end

		AddLine(" ")
	end

	-- Said once for the window rather than once per item: the setting is the
	-- same for every row, and repeating it eight times reads as eight problems.
	note:SetText(hiddenLine or "")

	child:SetHeight(math.max(1, lines.n * LINE_H + 10))
end

function ResponseWindow:Show()
	if not frame then Build() end
	self:Refresh()
	frame:Show()
end

function ResponseWindow:Toggle()
	if frame and frame:IsShown() then
		frame:Hide()
		return
	end
	self:Show()
end

return ResponseWindow
