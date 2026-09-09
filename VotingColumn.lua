-- VotingColumn.lua -- the RCLootCouncil voting frame column.
--
-- The column spec and its cell live here; every handle into RCLootCouncil lives
-- in RC.lua. Between them those are the only two files in this addon that know
-- RCLootCouncil exists, and they are separate files for exactly that reason:
-- they are what breaks when RCLootCouncil changes, and the blast radius should
-- be visible rather than spread through the addon.
--
-- Everything here is READ-ONLY. It renders a column and sorts on it. It never
-- writes to a session, never sets a response, never filters a candidate out and
-- never warns anybody before an award. The addon provides context; the officers
-- make the decisions.
--
-- The column answers exactly one question -- did this candidate reserve the
-- item currently up -- and nothing else may be folded into the cell. A cell
-- that also means "and they already won something" is a cell that lies about
-- what it is, and the cost of that is paid mid-session.

-- lib-ScrollingTable calls DoCellUpdate with a fixed nine-argument signature
-- and comparesort with four. The parameters are named the way the library
-- documents them even where this addon does not read them: renaming a
-- positional argument to silence a warning is how you end up reading the wrong
-- one.
-- luacheck: no unused args

local _, ns = ...

local Names = ns.Names
local Tiers = ns.Tiers

local VotingColumn = { registered = false }
ns.VotingColumn = VotingColumn

local COL_NAME = "sgddReserve"
local HEADER = "Reserved"
local HEADER_STALE = "Reserved!"

-- Wide enough for the header word and for "Champ", which is the longest label
-- Tiers hands back for a difficulty we recognise. An unrecognised tier is shown
-- verbatim and can overflow -- that is the intended behaviour, not an oversight:
-- a cell that looks wrong is a cell somebody reports.
local WIDTH = 60

-- The column goes immediately after RCLootCouncil's candidate name column
-- rather than being appended to the far right of an already wide frame. The
-- cell answers "did THIS PERSON reserve the item that is up", so it belongs
-- next to the person, and it stays on screen when the frame is wider than the
-- monitor.
local AFTER_COLUMN = "name"

--------------------------------------------------------------------------------
-- Lookup
--------------------------------------------------------------------------------

-- Returns tier for this candidate on the item currently up, or nil.
-- One table index, no scan: this runs per candidate per redraw.
local function ReserveFor(candidateName, itemId)
	if not itemId or not candidateName then return nil end

	local set = ns.Data()
	if not set then return nil end

	local holders = set.reserves[itemId]
	if not holders then return nil end

	local folded = Names.Fold(candidateName)
	if not folded then return nil end

	return holders[folded], folded, set
end

local function RowName(t, rowIndex)
	local data = t and t.data
	local row = data and data[rowIndex]
	return row and row.name
end

--------------------------------------------------------------------------------
-- Cell
--------------------------------------------------------------------------------

-- Emptying a cell, and the reason it also hides the tooltip.
--
-- lib-ScrollingTable RECYCLES cell frames. The frame describing one candidate a
-- moment ago is handed to a different candidate on the next redraw, and the row
-- that went away never gets an OnLeave. So a tooltip left showing sits pinned
-- over the voting frame describing a reserve that belongs to somebody else --
-- which is worse than showing nothing, because it is legible and wrong.
--
-- IsOwned, not an unconditional Hide: this cell must not close a tooltip that
-- some other part of the UI has since opened.
local function ClearCell(frame)
	frame.text:SetText("")
	frame:SetScript("OnEnter", nil)
	frame:SetScript("OnLeave", nil)
	if GameTooltip:IsOwned(frame) then GameTooltip:Hide() end
end

local function DoCellUpdate(rowFrame, frame, data, cols, row, realrow, column, fShow, t)
	-- fShow false means this cell is being HIDDEN, and it has to be emptied.
	-- Skipping this branch is the classic lib-st bug: with more rows than data,
	-- a recycled cell keeps the previous candidate's text -- here, a reserve
	-- shown against the wrong raider, silently, mid-session.
	if not fShow then
		ClearCell(frame)
		return
	end

	local name = data[realrow] and data[realrow].name
	local itemId = ns.RC:CurrentItemId()
	local tier, folded, set = ReserveFor(name, itemId)

	if not tier then
		ClearCell(frame)
		return
	end

	local label = Tiers.Label(tier)
	local c = Tiers.Colour(tier)
	frame.text:SetText(label)
	frame.text:SetTextColor(c[1], c[2], c[3])

	frame:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine("SGDD Reserve")

		local char = set.chars[folded]
		GameTooltip:AddDoubleLine("Character", char and char.key or name, 1, 1, 1, 1, 1, 1)

		-- Both words, source in brackets: "Champ (Normal)". The cell shows the
		-- track because that is how the guild talks, but the website stores the
		-- difficulty, and the tooltip is where an officer comes when something
		-- looks wrong. Showing only the translated word makes a bad translation
		-- undebuggable. Same reasoning as showing both clocks on the timestamp.
		local shown = label
		if type(tier) == "string" and tier ~= "" and label ~= tier then
			shown = ("%s (%s)"):format(label, tier)
		end
		GameTooltip:AddDoubleLine("Difficulty", shown, 1, 1, 1, c[1], c[2], c[3])

		local when = set.reservedAt[folded .. ":" .. itemId]
		if when then
			GameTooltip:AddDoubleLine("Reserved", when, 1, 1, 1, 0.7, 0.7, 0.7)
		end

		-- Other reserves this character is holding, so an officer can see the
		-- whole picture without leaving the frame.
		local others = {}
		for otherId, holders in pairs(set.reserves) do
			if otherId ~= itemId and holders[folded] then
				others[#others + 1] = ns.ItemLabel(otherId, set)
			end
		end
		if #others > 0 then
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine("Also reserved:", 0.7, 0.7, 0.7)
			for _, otherLabel in ipairs(others) do
				GameTooltip:AddLine(otherLabel, 1, 1, 1)
			end
		end

		GameTooltip:AddLine(" ")
		GameTooltip:AddLine(ns.FreshnessLine(set), 0.6, 0.6, 0.6)

		if ns.Freshness.IsStale(ns.FreshnessStatus()) then
			GameTooltip:AddLine("This list may be out of date -- reimport.", 1, 0.3, 0.3)
		end

		GameTooltip:Show()
	end)

	frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

-- Reservers to the top, hardest difficulty first among them, then name.
--
-- One ordering expressed once, as a single key, so it cannot disagree with
-- itself: a non-reserver ranks after every reserver, a reserver ranks by
-- Tiers.Rank, and equal ranks fall through to name. Name last is what stops the
-- list shuffling between redraws when two people tie.
local function SortsBefore(nameA, tierA, nameB, tierB)
	local ra = tierA and Tiers.Rank(tierA) or math.huge
	local rb = tierB and Tiers.Rank(tierB) or math.huge
	if ra ~= rb then return ra < rb end
	return (nameA or "") < (nameB or "")
end

local function CompareSort(t, rowa, rowb, sortbycol)
	local itemId = ns.RC:CurrentItemId()
	local nameA, nameB = RowName(t, rowa), RowName(t, rowb)
	local tierA = ReserveFor(nameA, itemId)
	local tierB = ReserveFor(nameB, itemId)

	local direction = t.cols[sortbycol] and t.cols[sortbycol].sort
	if direction == 1 then -- lib-st ascending: the same order, reversed
		return SortsBefore(nameB, tierB, nameA, tierA)
	end
	return SortsBefore(nameA, tierA, nameB, tierB)
end

--------------------------------------------------------------------------------
-- Registration
--------------------------------------------------------------------------------

-- No import, no column. An empty column in a live loot session is noise at the
-- worst possible moment, and -- worse -- a column of blanks is exactly what a
-- character-key mismatch looks like. Absent is the honest signal.
--
-- This is also what makes the addon inert on a raider's client: they never
-- import, so they never register a column. (RCLootCouncil disables its whole
-- voting frame for non-council players anyway, unless the master looter turns
-- on its "observe" setting.)
function VotingColumn:Register()
	if self.registered then return end
	if not ns.Data() then return end

	local vf = ns.RC:VotingFrame()
	if not vf or not ns.RC:HasColumnAPI() then return end

	local spec = {
		colName = COL_NAME,
		name = HEADER,
		width = WIDTH,
		align = "CENTER",
		defaultsort = 2, -- lib-st descending: reservers first
		comparesort = CompareSort,
		DoCellUpdate = DoCellUpdate,
	}

	-- AddColumn(spec, target, position). Positioned first, appended as a
	-- fallback: if RCLootCouncil ever renames or drops its "name" column the
	-- positioned call errors on resolving the target, and a column in the wrong
	-- place is enormously better than no column at all -- an absent column is
	-- indistinguishable from nobody having reserved anything, which is the
	-- ambiguity this addon exists to remove.
	--
	-- Safe to retry: AddColumn checks the spec and the name's uniqueness before
	-- it resolves the target, so a call that fails on the target has inserted
	-- nothing.
	local ok = pcall(vf.AddColumn, vf, spec, AFTER_COLUMN, "after")
	if not ok then
		ok = pcall(vf.AddColumn, vf, spec)
	end

	if ok then
		self.registered = true
		self:MarkFreshness()
	end
end

function VotingColumn:Unregister()
	if not self.registered then return end
	local vf = ns.RC:VotingFrame()
	if vf and type(vf.RemoveColumn) == "function" then
		pcall(vf.RemoveColumn, vf, COL_NAME)
	end
	self.registered = false
end

-- The second half of the stale-import warning. A chat line can be missed; the
-- header sits in the officer's eyeline for the whole session. Done through the
-- public UpdateColumn rather than by touching RCLootCouncil's frame, which is
-- why the signal is a header rename and not a banner.
function VotingColumn:MarkFreshness()
	if not self.registered then return end

	local vf = ns.RC:VotingFrame()
	if not vf or type(vf.UpdateColumn) ~= "function" then return end

	local stale = ns.Freshness.IsStale(ns.FreshnessStatus())
	pcall(vf.UpdateColumn, vf, COL_NAME, { name = stale and HEADER_STALE or HEADER })
end

-- Called after an import, and whenever the dataset may have changed. Adds the
-- column if there is now data, removes it if there is not.
function VotingColumn:Refresh()
	if ns.Data() then
		self:Register()
		self:MarkFreshness()
	else
		self:Unregister()
	end
end
