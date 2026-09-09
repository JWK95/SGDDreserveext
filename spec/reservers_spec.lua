-- Who reserved a given item.
--
-- Three rules here are load-bearing and none of them is visible when it goes
-- wrong: which name gets printed, what order the list comes out in, and what
-- happens when more people reserved an item than fits.

local helper = require("spec.helper")
local ns = helper.namespace()
local Reservers = ns.Reservers

-- Builds a set the way Import would, so the tests read against the real shape
-- from Schema.lua rather than a double that can drift from it.
local function setWith(reserves)
	local set = ns.EmptySet()
	for _, r in ipairs(reserves) do
		local folded = r.key:lower():gsub("[%-%s']", "")
		set.chars[folded] = {
			key = r.key,
			name = r.key:match("^([^%-]+)"),
			realmSlug = "x",
			class = r.class or "WARRIOR",
		}
		set.reserves[r.item] = set.reserves[r.item] or {}
		set.reserves[r.item][folded] = r.tier
		set.reserveCount = set.reserveCount + 1
	end
	return set
end

describe("For", function()
	it("returns nil when nobody reserved the item", function()
		local set = setWith({ { key = "Beefy-ArgentDawn", item = 1, tier = "Mythic" } })
		assert.is_nil(Reservers.For(set, 999))
	end)

	it("returns nil rather than erroring on a missing set or item", function()
		assert.is_nil(Reservers.For(nil, 1))
		assert.is_nil(Reservers.For(ns.EmptySet(), nil))
	end)

	it("orders hardest difficulty first, AGAINST alphabetical order", function()
		-- The names are deliberately in the opposite order to the difficulties.
		-- An earlier version of this test used names that were already
		-- alphabetical, so deleting the tier comparison entirely still produced
		-- the expected list and the test passed either way -- protecting
		-- nothing. Mutation testing caught it; this arrangement is what makes
		-- the tier comparison load-bearing.
		local set = setWith({
			{ key = "Alice-ArgentDawn", item = 1, tier = "LFR" },
			{ key = "Bob-ArgentDawn", item = 1, tier = "Normal" },
			{ key = "Yuri-ArgentDawn", item = 1, tier = "Heroic" },
			{ key = "Zed-ArgentDawn", item = 1, tier = "Mythic" },
		})
		local got = Reservers.For(set, 1)
		local names = {}
		for i, e in ipairs(got.entries) do names[i] = e.display end
		assert.are.equal("Zed", names[1])   -- Myth
		assert.are.equal("Yuri", names[2])  -- Hero
		assert.are.equal("Bob", names[3])   -- Champ
		assert.are.equal("Alice", names[4]) -- LFR
	end)

	it("falls through to name when the difficulty ties", function()
		-- The second half of the ordering rule, kept separate so the test above
		-- cannot pass on the name comparison alone.
		local set = setWith({
			{ key = "Zed-ArgentDawn", item = 1, tier = "Mythic" },
			{ key = "Alice-ArgentDawn", item = 1, tier = "Mythic" },
		})
		local got = Reservers.For(set, 1)
		assert.are.equal("Alice", got.entries[1].display)
		assert.are.equal("Zed", got.entries[2].display)
	end)
end)

describe("the cross-realm name collision", function()
	it("adds the realm ONLY when two reservers would print identically", function()
		-- The rule worth breaking to check. The guild raids across many realms,
		-- so two people called Beefy is not theoretical -- and printing both as
		-- "Beefy" is the silent kind of wrong this addon exists to remove: an
		-- officer awards to one of them believing the tooltip said which.
		local set = setWith({
			{ key = "Beefy-ArgentDawn", item = 1, tier = "Mythic" },
			{ key = "Beefy-TwistingNether", item = 1, tier = "Mythic" },
			{ key = "Talithmusher-TwistingNether", item = 1, tier = "Mythic" },
		})
		local got = Reservers.For(set, 1)

		local shown = {}
		for _, e in ipairs(got.entries) do shown[e.display] = true end

		assert.is_true(shown["Beefy-ArgentDawn"])
		assert.is_true(shown["Beefy-TwistingNether"])
		assert.is_nil(shown["Beefy"])

		-- ...and the name that does not collide stays short.
		assert.is_true(shown["Talithmusher"])
		assert.is_nil(shown["Talithmusher-TwistingNether"])
	end)

	it("does not disambiguate the same name on a DIFFERENT item", function()
		-- The collision is per item, because the list is per item. Counting
		-- across the whole dataset would put realms on names that read
		-- perfectly unambiguously in the tooltip they appear in.
		local set = setWith({
			{ key = "Beefy-ArgentDawn", item = 1, tier = "Mythic" },
			{ key = "Beefy-TwistingNether", item = 2, tier = "Mythic" },
		})
		assert.are.equal("Beefy", Reservers.For(set, 1).entries[1].display)
		assert.are.equal("Beefy", Reservers.For(set, 2).entries[1].display)
	end)

	it("counts collisions before truncating, not after", function()
		-- If the count ran after the cap, whether a name showed its realm would
		-- depend on where the cap happened to fall -- so the same character
		-- would render differently on two items for no reason the officer can
		-- see.
		local reserves = {}
		for i = 1, Reservers.MAX_SHOWN do
			reserves[#reserves + 1] =
				{ key = ("Aaa%02d-ArgentDawn"):format(i), item = 1, tier = "Mythic" }
		end
		-- Two colliding names sorted to the very end, past the cap.
		reserves[#reserves + 1] = { key = "Zzz-ArgentDawn", item = 1, tier = "LFR" }
		reserves[#reserves + 1] = { key = "Zzz-TwistingNether", item = 1, tier = "LFR" }

		local got = Reservers.For(setWith(reserves), 1)
		assert.are.equal(2, got.dropped)
		assert.are.equal(Reservers.MAX_SHOWN, #got.entries)
	end)
end)

describe("the cap", function()
	local function manyReservers(n)
		local reserves = {}
		for i = 1, n do
			reserves[#reserves + 1] =
				{ key = ("Char%02d-ArgentDawn"):format(i), item = 1, tier = "Mythic" }
		end
		return setWith(reserves)
	end

	it("does not truncate when everything fits", function()
		local got = Reservers.For(manyReservers(Reservers.MAX_SHOWN), 1)
		assert.are.equal(Reservers.MAX_SHOWN, #got.entries)
		assert.are.equal(0, got.dropped)
		assert.is_nil(Reservers.Line(got):find("more)", 1, true))
	end)

	it("states how many it dropped, and states it accurately", function()
		-- Same rule as the whisper reply: a shortened list that does not say it
		-- was shortened reads as the whole answer.
		local total = Reservers.MAX_SHOWN + 7
		local got = Reservers.For(manyReservers(total), 1)

		assert.are.equal(Reservers.MAX_SHOWN, #got.entries)
		local dropped = tonumber(Reservers.Line(got):match("%(%+(%d+) more%)"))
		assert.are.equal(total, #got.entries + dropped)
	end)
end)

describe("Line", function()
	local function lineFor(reserves, colourize)
		return Reservers.Line(Reservers.For(setWith(reserves), 1), colourize)
	end

	it("names the difficulty next to each character, in the guild's words", function()
		local line = lineFor({
			{ key = "Beefy-ArgentDawn", item = 1, tier = "Normal" },
			{ key = "Alice-ArgentDawn", item = 1, tier = "Mythic" },
		})
		assert.is_truthy(line:find("Alice (Myth)", 1, true))
		assert.is_truthy(line:find("Beefy (Champ)", 1, true))
	end)

	it("returns nil for nothing, so the caller adds no line at all", function()
		assert.is_nil(Reservers.Line(nil))
		assert.is_nil(Reservers.Line({ entries = {}, dropped = 0 }))
	end)

	it("applies the colouriser to the name and nothing else", function()
		-- One line-building path, colour or not. Two paths is how the plain and
		-- coloured versions drift into disagreeing about the cap or the order.
		local line = lineFor({ { key = "Beefy-ArgentDawn", item = 1, tier = "Mythic", class = "WARRIOR" } },
			function(name, class) return "<" .. class .. ":" .. name .. ">" end)
		assert.is_truthy(line:find("<WARRIOR:Beefy> (Myth)", 1, true))
	end)

	it("is plain text when no colouriser is given", function()
		local line = lineFor({ { key = "Beefy-ArgentDawn", item = 1, tier = "Mythic" } })
		assert.are.equal("Reserved by: Beefy (Myth)", line)
	end)
end)
