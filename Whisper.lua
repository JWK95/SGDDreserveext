-- Whisper.lua -- what "!wdir" means and what comes back.
--
-- Pure: no WoW API, no addon state. Responder.lua owns the event, the queue
-- and the sending; this file owns the two rules that are easy to get subtly
-- wrong and impossible to notice in a raid -- what counts as the trigger, and
-- how a reply that does not fit gets shortened.

local _, ns = ...

local Tiers = ns.Tiers

local Whisper = {}
ns.Whisper = Whisper

Whisper.TRIGGER = "!wdir"

-- WoW caps a chat message at 255 bytes. One whisper, always: a reply split
-- across several messages is how a master looter gets throttled off chat by
-- twenty people asking at once.
Whisper.MAX_BYTES = 255

local PREFIX = "Your SGDD reserves: "
local SEP = "; "

-- On pipes. A BARE "|" in a chat message is rejected by the server as an
-- invalid escape code; a WELL-FORMED escape sequence -- an item link -- is
-- fine, and is how everybody links items in chat. So the rule is not "no
-- pipes", it is "no pipe this file did not receive as part of a finished
-- label".
--
-- This file never writes a "|" of its own. Labels arrive already built from
-- Core.ItemWhisperLabel, which hands over either a real item link or a plain
-- name, and everything here treats a label as an opaque string. That is what
-- keeps Whisper.lua pure and testable while the reply contains links.

--------------------------------------------------------------------------------
-- The trigger
--------------------------------------------------------------------------------

-- Matches "!wdir" and "!wdir please", case-insensitively, with surrounding
-- whitespace trimmed. Does NOT match "!wdirty" -- the boundary is the whole
-- point of the second comparison below, and dropping it turns every word that
-- happens to start with the trigger into a request. spec/whisper_spec.lua
-- breaks it deliberately.
--
-- RCLootCouncil's own whisper parser sees this message first on a master
-- looter's client, and ignores it -- but NOT for the reason this file used to
-- claim. ml_core.lua does:
--
--     local ses = addon:GetArgs(msg, 4)
--     ses = tonumber(ses)
--     if not ses or ... then return end   -- we need a valid session
--
-- The early return is the SESSION NUMBER parse, not the "|Hitem:" check. That
-- link check only runs once the first token has already parsed as a valid
-- session number. So the property that keeps us out of RCLootCouncil's loot
-- responses is:
--
--     neither the trigger nor any reply may BEGIN with a token that
--     tonumber() accepts
--
-- and that is what spec/whisper_spec.lua pins. It matters more now than it did:
-- replies carry item links, so if a reply ever started with a number we would
-- be handing RCLootCouncil a session number followed by a link, which is
-- exactly the shape it acts on.
function Whisper.IsTrigger(msg)
	if type(msg) ~= "string" then return false end

	local m = msg:lower():match("^%s*(.-)%s*$")
	if m == Whisper.TRIGGER then return true end
	return m:sub(1, #Whisper.TRIGGER + 1) == Whisper.TRIGGER .. " "
end

--------------------------------------------------------------------------------
-- The reply
--------------------------------------------------------------------------------

-- entries: { { tier = "Mythic", label = "Greatsword" }, ... }
--
-- Grouped by difficulty, hardest first, so the answer reads the way the guild
-- talks about it. Ordering is fully determined -- tier, then label -- because
-- two people comparing their replies is a thing that happens.
-- Groups are keyed by the LABEL an officer and a raider both see ("Myth"), but
-- ordered by the RANK of the tier that produced it. Ranking the label instead
-- would silently put every group last: Tiers.Rank knows "Mythic", not "Myth".
local function Render(entries, count)
	local groups, ranks, order = {}, {}, {}

	for i = 1, count do
		local e = entries[i]
		local label = Tiers.Label(e.tier)
		if not groups[label] then
			groups[label] = {}
			ranks[label] = Tiers.Rank(e.tier)
			order[#order + 1] = label
		end
		local g = groups[label]
		g[#g + 1] = e.label
	end

	table.sort(order, function(a, b)
		local ra, rb = ranks[a], ranks[b]
		if ra == rb then return a < b end
		return ra < rb
	end)

	local parts = {}
	for _, label in ipairs(order) do
		parts[#parts + 1] = label .. ": " .. table.concat(groups[label], ", ")
	end

	return PREFIX .. table.concat(parts, SEP)
end

-- Returns a single message of at most MAX_BYTES bytes.
--
-- When it does not fit, entries are dropped from the end and the number
-- dropped is stated. The count is the part that matters: a reply that silently
-- shows four of someone's six reserves is worse than no reply, because they
-- have no way to know they are reading a partial answer.
function Whisper.FormatReply(entries)
	if type(entries) ~= "table" or #entries == 0 then return nil end

	local sorted = {}
	for i, e in ipairs(entries) do sorted[i] = e end
	table.sort(sorted, function(a, b)
		local ra, rb = Tiers.Rank(a.tier), Tiers.Rank(b.tier)
		if ra ~= rb then return ra < rb end
		return tostring(a.label) < tostring(b.label)
	end)

	local full = Render(sorted, #sorted)
	if #full <= Whisper.MAX_BYTES then return full end

	for shown = #sorted - 1, 1, -1 do
		local dropped = #sorted - shown
		local msg = Render(sorted, shown) .. (" (+%d more)"):format(dropped)
		if #msg <= Whisper.MAX_BYTES then return msg end
	end

	-- Even one entry does not fit, which needs a name absurdly long to reach.
	-- Say the count rather than a truncated name that reads as the whole answer.
	return ("You have %d reserves -- too many to fit in one whisper."):format(#sorted)
end

--------------------------------------------------------------------------------
-- The two answers that are not a list
--------------------------------------------------------------------------------

-- These are separate sentences on purpose. "You have no reserves" and "I have
-- no list" are different facts, and both are different from silence -- which is
-- the failure this addon exists to stamp out. The responder always sends one of
-- the three.
function Whisper.NoData()
	return "I have no reserve list loaded -- ask an officer to import tonight's reserves."
end

function Whisper.NoReserves(charName)
	if type(charName) == "string" and charName ~= "" then
		return ("No reserves found for %s. Reserves are per character -- ask from the one you reserved on.")
			:format(charName)
	end
	return "No reserves found for you."
end

return Whisper
