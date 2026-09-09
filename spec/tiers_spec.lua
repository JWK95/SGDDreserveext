-- The difficulty vocabulary.
--
-- Two user-facing surfaces read this file -- the officer's voting column and
-- the raider's whisper reply -- and the failure mode when they disagree is that
-- two people looking at the same reserve describe it with different words. The
-- rules below are the ones that are easy to break without anything looking
-- wrong.

local helper = require("spec.helper")
local ns = helper.namespace()
local Tiers = ns.Tiers

describe("Label", function()
	it("speaks in tracks, not difficulties", function()
		-- The whole point of the file. The website stores the difficulty a
		-- raider picked; the guild talks in the track it drops.
		assert.are.equal("Myth", Tiers.Label("Mythic"))
		assert.are.equal("Hero", Tiers.Label("Heroic"))
		assert.are.equal("Champ", Tiers.Label("Normal"))
	end)

	it("leaves LFR alone", function()
		-- The track is called Veteran. Nobody says Veteran.
		assert.are.equal("LFR", Tiers.Label("LFR"))
	end)

	it("does not care how the website capitalised it", function()
		-- The tier crosses a repo boundary as a bare string. Matching on exact
		-- capitalisation is a silent miss the first time somebody on the site
		-- writes it in lower case.
		assert.are.equal("Myth", Tiers.Label("mythic"))
		assert.are.equal("Myth", Tiers.Label("MYTHIC"))
		assert.are.equal("Champ", Tiers.Label("nOrMaL"))
	end)

	it("shows an unrecognised tier VERBATIM, never abbreviated", function()
		-- This is the rule worth breaking to check. The tempting alternative is
		-- to abbreviate anything unknown to its first letter, which is what
		-- this addon used to do -- and that turns a tier the addon has never
		-- heard of into a plausible single character nobody questions.
		--
		-- "Warband" in a cell is a bug report. "W" is invisible.
		assert.are.equal("Warband", Tiers.Label("Warband"))
		assert.are.equal("Timewalking", Tiers.Label("Timewalking"))
	end)

	it("says '?' when there is no tier at all", function()
		-- Distinct from an unrecognised tier: nothing arrived, rather than
		-- something arrived that we could not place.
		assert.are.equal(Tiers.UNKNOWN, Tiers.Label(nil))
		assert.are.equal(Tiers.UNKNOWN, Tiers.Label(""))
		assert.are.equal(Tiers.UNKNOWN, Tiers.Label(42))
	end)
end)

describe("Rank", function()
	it("orders hardest first", function()
		assert.is_true(Tiers.Rank("Mythic") < Tiers.Rank("Heroic"))
		assert.is_true(Tiers.Rank("Heroic") < Tiers.Rank("Normal"))
		assert.is_true(Tiers.Rank("Normal") < Tiers.Rank("LFR"))
	end)

	it("sorts an unrecognised tier last, not first", function()
		-- An entry the addon could not identify belongs at the bottom. Ranking
		-- it 0 would float every unknown tier above Mythic, which is exactly
		-- backwards and would look deliberate.
		assert.is_true(Tiers.Rank("Warband") > Tiers.Rank("LFR"))
		assert.is_true(Tiers.Rank(nil) > Tiers.Rank("LFR"))
	end)

	it("is case insensitive, like Label", function()
		assert.are.equal(Tiers.Rank("Mythic"), Tiers.Rank("mythic"))
	end)
end)

describe("Colour", function()
	it("gives every known tier its own colour", function()
		local seen = {}
		for _, tier in ipairs({ "Mythic", "Heroic", "Normal", "LFR" }) do
			local c = Tiers.Colour(tier)
			local k = table.concat(c, ",")
			assert.is_nil(seen[k], tier .. " shares a colour with " .. tostring(seen[k]))
			seen[k] = tier
		end
	end)

	it("hands out a fresh table each time", function()
		-- The cell update runs once per candidate per redraw and colours text
		-- from whatever it gets back. Returning the shared table means one
		-- caller mutating its copy recolours every tier in the frame -- and it
		-- would only show up as "the colours went wrong sometimes".
		local a = Tiers.Colour("Mythic")
		a[1] = 0
		local b = Tiers.Colour("Mythic")
		assert.is_true(b[1] > 0)
	end)

	it("falls back to white rather than nil", function()
		-- A nil colour is a Lua error inside SetTextColor, in a cell update, in
		-- somebody else's frame, mid-session.
		local c = Tiers.Colour("Warband")
		assert.is_number(c[1])
		assert.is_number(c[2])
		assert.is_number(c[3])
	end)
end)
