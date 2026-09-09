-- OfficerFrame.lua -- where an officer pastes the export.
--
-- Built on first use and never before: a client that never opens it pays for
-- none of it. Opened with "/rc reserves" or from the settings panel under
-- RCLootCouncil; there is no slash command of our own and no minimap button,
-- because this is opened once a week and it belongs inside RCLootCouncil.
--
-- It is built from RCLootCouncil's own frame widget when that is available, so
-- it reads as part of RCLootCouncil rather than as a second addon with its own
-- look. Failing that it falls back to a plain frame -- a cosmetic dependency
-- should not be able to take the import away.

local _, ns = ...

local OfficerFrame = {}
ns.OfficerFrame = OfficerFrame

local WIDTH, HEIGHT = 450, 420
local LINE_H = 14

local frame, content, status, report, editBox, lines, listScroll, listChild

--------------------------------------------------------------------------------
-- Line pool
--------------------------------------------------------------------------------

local function ResetLines()
	for _, fs in ipairs(lines) do
		fs:SetText("")
		fs:Hide()
	end
	lines.n = 0
end

-- Absolute placement by line index rather than chaining each line off the
-- previous one. The chained version had to carry the previous line's indent
-- forward to cancel it out, which is one arithmetic slip away from a column of
-- text walking off the side of the frame.
local function AddLine(text, r, g, b, indent)
	lines.n = lines.n + 1
	indent = indent or 0

	local fs = lines[lines.n]
	if not fs then
		fs = listChild:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		fs:SetJustifyH("LEFT")
		lines[lines.n] = fs
	end

	fs:ClearAllPoints()
	fs:SetPoint("TOPLEFT", listChild, "TOPLEFT", 4 + indent, -((lines.n - 1) * LINE_H))
	fs:SetWidth(WIDTH - 40 - indent)
	fs:SetText(text)
	fs:SetTextColor(r or 1, g or 1, b or 1)
	fs:Show()
end

--------------------------------------------------------------------------------
-- Contents
--------------------------------------------------------------------------------

local function SortedCharacters(set)
	local seen, keys = {}, {}
	for _, holders in pairs(set.reserves) do
		for folded in pairs(holders) do
			if not seen[folded] then
				seen[folded] = true
				keys[#keys + 1] = folded
			end
		end
	end
	table.sort(keys, function(a, b)
		local ca, cb = set.chars[a], set.chars[b]
		return (ca and ca.name or a) < (cb and cb.name or b)
	end)
	return keys
end

-- What was actually imported, so an officer can see it rather than trust it.
-- The export string itself is an opaque blob on purpose -- a truncated paste
-- fails the decode loudly instead of half-working -- so "what did I just load"
-- is answered here, by display, rather than by making the wire format readable.
local function Redraw()
	ResetLines()

	local set = ns.ImportedSet()
	status:SetText(ns.FreshnessLine(set))

	if ns.Freshness.IsStale(ns.FreshnessStatus()) then
		status:SetTextColor(1, 0.4, 0.4)
	else
		status:SetTextColor(0.7, 0.7, 0.7)
	end

	if not set then
		AddLine("Nothing imported yet.", 0.7, 0.7, 0.7)
		listChild:SetHeight(LINE_H * 2)
		return
	end

	if set.reserveCount == 0 then
		-- A real, current import of a week where nobody reserved anything. Say
		-- which of the two this is: the column will be absent either way, and
		-- absent is also what a failed import looks like.
		AddLine("Imported, but nobody has reserved anything.", 1, 1, 1)
		AddLine("No column will be shown -- there is nothing to show.", 0.7, 0.7, 0.7)
		listChild:SetHeight(LINE_H * 3)
		return
	end

	local chars = SortedCharacters(set)

	AddLine(("%d reserves across %d characters%s")
		:format(set.reserveCount, #chars,
			set.guild and (" -- " .. set.guild) or ""), 1, 1, 1)
	AddLine(" ")

	for _, folded in ipairs(chars) do
		local char = set.chars[folded]
		AddLine(char and char.key or folded, 0.55, 0.78, 1)

		for itemId, holders in pairs(set.reserves) do
			local tier = holders[folded]
			if tier then
				AddLine(("%s  |cff888888%s|r"):format(ns.ItemLabel(itemId, set), tier), 1, 1, 1, 14)
			end
		end
	end

	listChild:SetHeight(math.max(LINE_H * (lines.n + 1), 10))
end

OfficerFrame.Redraw = Redraw

--------------------------------------------------------------------------------
-- Import
--------------------------------------------------------------------------------

-- The match report is this addon's alarm against its one invisible failure: if
-- the website's character keys and the game's disagree, the import succeeds,
-- the column renders empty, and an empty column reads as "nobody reserved
-- anything". A zero here is stated in red and never quietly dropped.
local function ShowMatchReport(matched, total)
	if not matched then
		report:SetText("")
		return
	end

	if matched == 0 then
		report:SetText(("|cffff4444Matched 0 of %d group members.|r Character keys are not lining up -- the column will be empty.")
			:format(total))
	elseif matched < total then
		report:SetText(("Matched %d of %d group members."):format(matched, total))
	else
		report:SetText(("|cff44ff44Matched all %d group members.|r"):format(total))
	end
end

local function DoImport()
	local text = editBox:GetText()
	local ok, msg, matched, total = ns.Import.Paste(text)

	if ok then
		ns.Print(msg)
		editBox:SetText("")
		editBox:ClearFocus()
		ShowMatchReport(matched, total)
	else
		ns.Warn(msg)
		report:SetText("|cffff4444" .. tostring(msg) .. "|r")
	end

	Redraw()
end

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

local function BuildFrame()
	local f

	local rc = ns.RC:Addon()
	if rc and rc.UI and type(rc.UI.NewNamed) == "function" then
		local ok, made = pcall(rc.UI.NewNamed, rc.UI, "RCFrame", UIParent,
			"SGDDReservesWindow", "SGDD Reserves", WIDTH, HEIGHT)
		if ok and made then f = made end
	end

	if not f then
		f = CreateFrame("Frame", "SGDDReservesFrame", UIParent, "BasicFrameTemplateWithInset")
		f:SetSize(WIDTH, HEIGHT)
		f:SetPoint("CENTER")
		f:SetMovable(true)
		f:EnableMouse(true)
		f:RegisterForDrag("LeftButton")
		f:SetScript("OnDragStart", f.StartMoving)
		f:SetScript("OnDragStop", f.StopMovingOrSizing)
	end

	return f, f.content or f
end

local function Build()
	frame, content = BuildFrame()
	lines = { n = 0 }

	status = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	status:SetPoint("TOPLEFT", content, "TOPLEFT", 12, -14)
	status:SetJustifyH("LEFT")

	report = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	report:SetPoint("TOPLEFT", status, "BOTTOMLEFT", 0, -6)
	report:SetWidth(WIDTH - 30)
	report:SetJustifyH("LEFT")

	local label = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	label:SetPoint("TOPLEFT", report, "BOTTOMLEFT", 0, -12)
	label:SetText("Paste the export from the guild website:")

	local boxBg = CreateFrame("Frame", nil, content, "InsetFrameTemplate")
	boxBg:SetPoint("TOPLEFT", label, "BOTTOMLEFT", -4, -4)
	boxBg:SetSize(WIDTH - 24, 64)

	local scroll = CreateFrame("ScrollFrame", "SGDDReservesPasteScroll", boxBg, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 6, -6)
	scroll:SetPoint("BOTTOMRIGHT", -26, 6)

	editBox = CreateFrame("EditBox", nil, scroll)
	editBox:SetMultiLine(true)
	editBox:SetAutoFocus(false)
	editBox:SetFontObject("ChatFontNormal")
	editBox:SetTextInsets(2, 2, 2, 2)
	-- A multiline EditBox used as a scroll child needs BOTH dimensions. With no
	-- height it is zero pixels tall, which does not look broken -- it looks like
	-- an empty box that will not take a click. It grows past this as text
	-- arrives; this is only the clickable target.
	editBox:SetSize(WIDTH - 60, 52)
	editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	-- Replacing the contents is the normal case, not appending to them.
	editBox:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
	scroll:SetScrollChild(editBox)

	-- The whole inset is the paste target. Hunting for a text cursor inside a
	-- box that is mostly empty is a bad first thirty seconds.
	boxBg:EnableMouse(true)
	boxBg:SetScript("OnMouseDown", function() editBox:SetFocus() end)

	local importButton = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
	importButton:SetSize(110, 22)
	importButton:SetPoint("TOPLEFT", boxBg, "BOTTOMLEFT", 4, -8)
	importButton:SetText("Import")
	importButton:SetScript("OnClick", DoImport)

	local clearButton = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
	clearButton:SetSize(110, 22)
	clearButton:SetPoint("LEFT", importButton, "RIGHT", 8, 0)
	clearButton:SetText("Clear box")
	clearButton:SetScript("OnClick", function()
		editBox:SetText("")
		editBox:ClearFocus()
	end)

	listScroll = CreateFrame("ScrollFrame", "SGDDReservesListScroll", content, "UIPanelScrollFrameTemplate")
	listScroll:SetPoint("TOPLEFT", importButton, "BOTTOMLEFT", -4, -10)
	listScroll:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -28, 12)

	listChild = CreateFrame("Frame", nil, listScroll)
	listChild:SetSize(WIDTH - 50, 10)
	listScroll:SetScrollChild(listChild)

	-- Registered only while the window is open, and it coalesces a batch of
	-- item names arriving into a single redraw rather than one per item.
	frame:SetScript("OnShow", function(self)
		self:RegisterEvent("GET_ITEM_INFO_RECEIVED")
		Redraw()
	end)
	frame:SetScript("OnHide", function(self)
		self:UnregisterEvent("GET_ITEM_INFO_RECEIVED")
	end)
	frame:SetScript("OnEvent", function(self)
		if self.pending then return end
		self.pending = true
		C_Timer.After(0.2, function()
			self.pending = false
			if self:IsShown() then Redraw() end
		end)
	end)

	tinsert(UISpecialFrames, frame:GetName())
end

--------------------------------------------------------------------------------
-- Public
--------------------------------------------------------------------------------

function OfficerFrame:Toggle()
	if not frame then Build() end
	if frame:IsShown() then
		frame:Hide()
	else
		frame:Show()
	end
end

function OfficerFrame:Show()
	if not frame then Build() end
	frame:Show()
end
