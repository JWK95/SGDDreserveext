-- Is the imported list still good for tonight?
--
-- The rule this file exists to protect: AGE IS THE WRONG MEASURE. The website
-- wipes reserves weekly, so the question is not "how old is this" but "was it
-- exported before the current lockout began". A day count alone passes the
-- first test below and fails every raider in the raid.

local helper = require("spec.helper")
local ns = helper.namespace()
local Freshness = ns.Freshness

local DAY = 86400
local NOW = 1788000000

describe("Check", function()
	it("says NONE when nothing has been imported", function()
		assert.are.equal(Freshness.NONE, Freshness.Check(nil, NOW, DAY))
	end)

	it("catches a list from before the reset even when it is fresh by the clock", function()
		-- The reset was one day ago; the export is two days old. Two days is
		-- well inside the three-day backstop, so ONLY the reset boundary can
		-- catch this -- and this is the everyday case: exported Tuesday for a
		-- Tuesday raid, reset Wednesday, still loaded on Thursday.
		local untilReset = 6 * DAY          -- last reset was 1 day ago
		local exported = NOW - 2 * DAY
		assert.are.equal(Freshness.RESET, Freshness.Check(exported, NOW, untilReset))
	end)

	it("accepts a list exported after the last reset", function()
		local untilReset = 6 * DAY          -- last reset was 1 day ago
		local exported = NOW - (DAY / 2)    -- half a day ago, so after it
		assert.are.equal(Freshness.OK, Freshness.Check(exported, NOW, untilReset))
	end)

	it("accepts a list that is days old but still inside this lockout", function()
		-- Exported Monday, raiding Wednesday, reset was Sunday. Nothing wrong
		-- with it, and warning here is how a warning becomes noise.
		local untilReset = 5 * DAY          -- last reset was 2 days ago
		local exported = NOW - (1.5 * DAY)
		assert.are.equal(Freshness.OK, Freshness.Check(exported, NOW, untilReset))
	end)

	it("falls back to the age backstop when the reset cannot be read", function()
		-- nil is a third answer, not "the reset is far away". The client has
		-- not been told yet, and going quiet at the moment it knows least is
		-- the wrong direction to fail.
		assert.are.equal(Freshness.AGE, Freshness.Check(NOW - 4 * DAY, NOW, nil))
		assert.are.equal(Freshness.OK, Freshness.Check(NOW - DAY, NOW, nil))
	end)

	it("applies the backstop at the boundary, not a day either side of it", function()
		local justInside = NOW - (Freshness.MAX_AGE_DAYS * DAY - 60)
		local justOutside = NOW - (Freshness.MAX_AGE_DAYS * DAY + 60)
		assert.are.equal(Freshness.OK, Freshness.Check(justInside, NOW, nil))
		assert.are.equal(Freshness.AGE, Freshness.Check(justOutside, NOW, nil))
	end)
end)

describe("IsStale", function()
	it("treats everything except OK as stale", function()
		assert.is_true(Freshness.IsStale(Freshness.NONE))
		assert.is_true(Freshness.IsStale(Freshness.RESET))
		assert.is_true(Freshness.IsStale(Freshness.AGE))
		assert.is_false(Freshness.IsStale(Freshness.OK))
	end)
end)
