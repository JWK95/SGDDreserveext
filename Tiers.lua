-- Tiers.lua -- the difficulty vocabulary, in one place.
--
-- Pure: no WoW API, no addon state, so spec/tiers_spec.lua can break it.
--
-- The website stores and exports the DIFFICULTY ("Mythic", "Heroic",
-- "Normal", "LFR"), because that is what a raider picked. The guild talks in
-- the ITEM TRACK the difficulty drops -- Myth, Hero, Champ -- so that is what
-- the addon shows. This file is the translation and the only place it happens.
--
-- Translating on display rather than changing what the website stores is
-- deliberate. "Mythic" is the correct name of the difficulty; "Myth" is the
-- correct name of the track. Rewriting stored data to match a UI label would
-- make the export format lie about its own contents, and it would need a
-- coordinated deploy across two repos -- which docs/export-format.md already
-- calls a raid-night hazard.
--
-- Two surfaces read this: the voting column an officer sees, and the whisper a
-- raider gets back from "!wdir". They must agree. A vocabulary that drifts
-- between two user-facing surfaces is how a raider ends up asking an officer
-- what the difference is, mid-pull.

local _, ns = ...

local Tiers = {}
ns.Tiers = Tiers

-- Shown when the website sends no tier at all. Distinct from an unrecognised
-- tier, which is shown verbatim -- see Label.
Tiers.UNKNOWN = "?"

-- Keyed lowercase: the tier arrives as a string from another codebase, and
-- matching on exact capitalisation is a silent miss waiting for the day
-- somebody on the website writes "mythic".
local LABEL = {
	mythic = "Myth",
	heroic = "Hero",
	normal = "Champ",
	lfr    = "LFR",
}

-- LFR keeps its own name rather than becoming "Veteran". The track is called
-- Veteran, but nobody says "I got it on Veteran" -- they say LFR. The point of
-- this file is to speak the way the guild speaks, not to be pedantic about
-- Blizzard's nomenclature.

-- Hardest first. Unknown tiers sort last: an entry the addon could not
-- identify belongs at the bottom, not silently interleaved.
local RANK = {
	mythic = 1,
	heroic = 2,
	normal = 3,
	lfr    = 4,
}

local RANK_UNKNOWN = 5

local COLOUR = {
	mythic = { 0.64, 0.21, 0.93 },
	heroic = { 0.00, 0.44, 0.87 },
	normal = { 0.12, 0.75, 0.31 },
	lfr    = { 0.62, 0.62, 0.62 },
}

local COLOUR_UNKNOWN = { 1, 1, 1 }

local function key(tier)
	if type(tier) ~= "string" or tier == "" then return nil end
	return tier:lower()
end

--------------------------------------------------------------------------------
-- The three questions asked of a tier
--------------------------------------------------------------------------------

-- The word to put in front of a raider or an officer.
--
-- An UNRECOGNISED tier is returned VERBATIM, and that is the rule this file
-- exists to protect. The obvious alternative -- abbreviate anything unknown to
-- its first letter, which is what this addon used to do -- turns a tier the
-- addon has never heard of into a plausible-looking single character that
-- nobody will ever question. A cell reading "Warband" is a bug report. A cell
-- reading "W" is invisible, and stays invisible for as long as the website and
-- the addon disagree.
function Tiers.Label(tier)
	local k = key(tier)
	if not k then return Tiers.UNKNOWN end
	return LABEL[k] or tier
end

-- Sort weight, hardest first. Used by the voting column to order two people
-- who both reserved the item that is up, and by the whisper reply to group a
-- raider's reserves the way the guild reads them.
function Tiers.Rank(tier)
	local k = key(tier)
	if not k then return RANK_UNKNOWN end
	return RANK[k] or RANK_UNKNOWN
end

-- { r, g, b }. Returned as a fresh table so a caller cannot colour every other
-- cell by mutating the one it was handed.
function Tiers.Colour(tier)
	local k = key(tier)
	local c = (k and COLOUR[k]) or COLOUR_UNKNOWN
	return { c[1], c[2], c[3] }
end

return Tiers
