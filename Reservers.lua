-- Reservers.lua -- who reserved a given item, in the order an officer reads it.
--
-- Pure: no WoW API, no addon state, so spec/reservers_spec.lua can break every
-- rule in here. Tooltip.lua owns the hook and the colours; this file owns the
-- three rules that are easy to get subtly wrong and impossible to notice in a
-- raid -- which name to print, what order, and what to do when the whole raid
-- reserved the same trinket.

local _, ns = ...

local Tiers = ns.Tiers

local Reservers = {}
ns.Reservers = Reservers

-- Fifteen names is already a wall of text in a tooltip; past that the item's
-- own stats are pushed off the screen and the line stops being useful for the
-- thing it was added for.
Reservers.MAX_SHOWN = 15

local PREFIX = "Reserved by: "

--------------------------------------------------------------------------------
-- Names
--------------------------------------------------------------------------------

-- The in-game realm half of a stored key: "Beefy-ArgentDawn" -> "ArgentDawn".
-- Safe on the first hyphen because a character name cannot contain one -- the
-- same fact Names.Fold is built on.
local function RealmOf(key)
	if type(key) ~= "string" then return nil end
	return key:match("^[^%-]+%-(.+)$")
end

local function DisplayName(char, folded)
	if char and type(char.name) == "string" and char.name ~= "" then
		return char.name
	end
	-- No C record for this key. The export format forbids orphans, so this is a
	-- broken import rather than a normal case: show the folded key, which is
	-- ugly and therefore gets reported, rather than nothing, which does not.
	return folded
end

--------------------------------------------------------------------------------
-- Who reserved this
--------------------------------------------------------------------------------

-- Returns { entries = { { name, tier, class, key }, ... }, dropped = n }
-- or nil when nobody reserved this item.
--
-- One table index to find the holders, so this stays cheap enough to run from a
-- tooltip callback that fires on every item the officer hovers.
function Reservers.For(set, itemId)
	if not set or not itemId then return nil end
	if type(set.reserves) ~= "table" then return nil end

	local holders = set.reserves[itemId]
	if not holders then return nil end

	local entries = {}
	for folded, tier in pairs(holders) do
		local char = set.chars and set.chars[folded]
		entries[#entries + 1] = {
			name = DisplayName(char, folded),
			realm = char and RealmOf(char.key) or nil,
			tier = tier,
			class = char and char.class or nil,
		}
	end

	if #entries == 0 then return nil end

	-- Hardest first, then name, then realm. Fully determined all the way down:
	-- two officers hovering the same item must read the same list, and a list
	-- that reshuffles between hovers reads as data changing under them.
	table.sort(entries, function(a, b)
		local ra, rb = Tiers.Rank(a.tier), Tiers.Rank(b.tier)
		if ra ~= rb then return ra < rb end
		if a.name ~= b.name then return a.name < b.name end
		return tostring(a.realm) < tostring(b.realm)
	end)

	-- The guild raids across many realms, so two people called Beefy on
	-- different realms is not theoretical. Printing both as "Beefy" is the
	-- silent kind of wrong this addon exists to remove -- an officer awards to
	-- one of them believing the tooltip told them which. So a name that appears
	-- more than once in THIS list carries its realm; a name that does not stays
	-- short. Counted over the whole list before truncation, so the answer does
	-- not change depending on where the cap fell.
	local seen = {}
	for _, e in ipairs(entries) do
		seen[e.name] = (seen[e.name] or 0) + 1
	end
	for _, e in ipairs(entries) do
		if seen[e.name] > 1 and e.realm then
			e.display = e.name .. "-" .. e.realm
		else
			e.display = e.name
		end
	end

	local dropped = 0
	if #entries > Reservers.MAX_SHOWN then
		dropped = #entries - Reservers.MAX_SHOWN
		for i = #entries, Reservers.MAX_SHOWN + 1, -1 do
			entries[i] = nil
		end
	end

	return { entries = entries, dropped = dropped }
end

--------------------------------------------------------------------------------
-- The line
--------------------------------------------------------------------------------

-- colourize(displayName, class) -> string. Optional: without it the line is
-- plain text, which is what the spec reads. Tooltip.lua passes one that wraps
-- the name in the class colour, so there is ONE line-building path rather than
-- a plain one and a coloured one drifting apart.
function Reservers.Line(result, colourize)
	if not result or not result.entries or #result.entries == 0 then return nil end

	local parts = {}
	for i, e in ipairs(result.entries) do
		local shown = e.display or e.name
		if colourize then shown = colourize(shown, e.class) end
		parts[i] = ("%s (%s)"):format(shown, Tiers.Label(e.tier))
	end

	local line = PREFIX .. table.concat(parts, ", ")

	-- Says how many it could not fit, for the same reason the whisper reply
	-- does: a silently shortened list reads as the complete answer.
	if result.dropped > 0 then
		line = line .. (" (+%d more)"):format(result.dropped)
	end

	return line
end

return Reservers
