-- Everyone's response and roll, and who is allowed to see it.
--
-- Mutation-tested. Showing other candidates' responses when the master looter
-- has "observe" off, reversing the row order, and dropping the name tiebreak
-- were each introduced and each caught here.
--
-- A NOTE ON THE ORDERING TEST, because this repo has already been bitten by the
-- shape of it. Sorting tests are the easiest kind to write so that they pass
-- whichever way the comparator goes -- arrange the fixture so the names happen
-- to be in the same order as the rolls and deleting the roll comparison changes
-- nothing. So: the names below run in the OPPOSITE direction to the rolls,
-- which is the only arrangement that makes the roll comparison load-bearing.
-- The tiebreak gets its own two-row fixture, inserted in reverse alphabetical
-- order, because that is the only arrangement where dropping it is visible.

local helper = require("spec.helper")

describe("Consolidation", function()
	local ns = helper.namespace()
	local C = ns.Consolidation

	local function entries()
		return {
			{ name = "Alice", response = "Greed", roll = 10, class = "MAGE" },
			{ name = "Bob",   response = "Need",  roll = 90, class = "ROGUE" },
			{ name = "Carol", response = "Need",  roll = 50, class = "DRUID" },
		}
	end

	local function names(result)
		local out = {}
		for i, r in ipairs(result.rows) do out[i] = r.name end
		return table.concat(out, ",")
	end

	describe("observe is on", function()
		it("shows everybody", function()
			local r = C.Build(entries(), { observe = true, viewer = "Alice" })
			assert.are.equal(3, #r.rows)
			assert.are.equal(0, r.hidden)
			assert.is_true(r.observing)
		end)

		-- MUTATION: reversing the comparison, and dropping the name tiebreak.
		-- The names here descend while the rolls ascend, so a comparator that
		-- ignores the roll produces "Alice,Bob,Carol" and one that reverses it
		-- produces "Alice,Carol,Bob" -- both different from the truth.
		it("orders by roll, highest first", function()
			local r = C.Build(entries(), { observe = true, viewer = "Alice" })
			assert.are.equal("Bob,Carol,Alice", names(r))
		end)

		it("breaks a tied roll on name", function()
			-- Inserted reverse-alphabetically on purpose: with two rows Lua's
			-- sort makes exactly one comparison, so dropping the tiebreak
			-- leaves them as inserted and the difference is deterministic.
			local r = C.Build({
				{ name = "Zed",   response = "Need", roll = 50 },
				{ name = "Carol", response = "Need", roll = 50 },
			}, { observe = true, viewer = "Zed" })
			assert.are.equal("Carol,Zed", names(r))
		end)

		it("sorts a missing roll last, not as zero", function()
			local r = C.Build({
				{ name = "Nobody", response = "Need", roll = nil },
				{ name = "Aaron",  response = "Need", roll = 1 },
			}, { observe = true, viewer = "Aaron" })
			-- A roll of 1 beats no roll at all. Somebody who has not rolled has
			-- not lost, and inventing a zero for them says they did.
			assert.are.equal("Aaron,Nobody", names(r))
		end)
	end)

	describe("observe is off", function()
		-- MUTATION: ignoring the setting. We CAN read every response on any
		-- client -- they travel over the group channel to everybody and
		-- RCLootCouncil simply does not subscribe. Reading them anyway would
		-- override an officer's deliberate, defaulted-off choice about what the
		-- raid sees, on every machine in the guild.
		it("shows the viewer their own row and nobody else's", function()
			local r = C.Build(entries(), { observe = false, viewer = "Alice" })
			assert.are.equal(1, #r.rows)
			assert.are.equal("Alice", r.rows[1].name)
			assert.is_false(r.observing)
		end)

		it("says how many it hid", function()
			local r = C.Build(entries(), { observe = false, viewer = "Alice" })
			assert.are.equal(2, r.hidden)
		end)

		it("hides everything when the viewer is not a candidate", function()
			local r = C.Build(entries(), { observe = false, viewer = "Stranger" })
			assert.are.equal(0, #r.rows)
			assert.are.equal(3, r.hidden)
		end)

		it("marks the viewer's own row", function()
			local r = C.Build(entries(), { observe = false, viewer = "Bob" })
			assert.is_true(r.rows[1].mine)
		end)
	end)

	describe("the hidden line", function()
		it("names the count and the setting", function()
			local r = C.Build(entries(), { observe = false, viewer = "Alice" })
			local line = C.HiddenLine(r)
			assert.is_string(line)
			assert.is_truthy(line:find("2", 1, true))
			assert.is_truthy(line:find("observe", 1, true))
		end)

		it("is absent when observing", function()
			assert.is_nil(C.HiddenLine(C.Build(entries(), { observe = true, viewer = "Alice" })))
		end)

		it("is absent when nothing was hidden", function()
			local r = C.Build({ { name = "Alice", response = "Need", roll = 5 } },
				{ observe = false, viewer = "Alice" })
			assert.is_nil(C.HiddenLine(r))
		end)

		it("reads singular for one hidden response", function()
			local r = C.Build({
				{ name = "Alice", response = "Need", roll = 5 },
				{ name = "Bob",   response = "Need", roll = 6 },
			}, { observe = false, viewer = "Alice" })
			assert.is_truthy(C.HiddenLine(r):find("response is", 1, true))
		end)
	end)

	describe("missing answers", function()
		it("reads Waiting rather than blank", function()
			-- A blank cell reads as "passed", which is a different fact and the
			-- wrong one.
			local r = C.Build({ { name = "Alice" } }, { observe = true, viewer = "Alice" })
			assert.are.equal(C.WAITING, r.rows[1].response)
		end)

		it("reads Waiting for an empty response string", function()
			local r = C.Build({ { name = "Alice", response = "" } }, { observe = true, viewer = "Alice" })
			assert.are.equal(C.WAITING, r.rows[1].response)
		end)

		it("survives no entries at all", function()
			local r = C.Build(nil, { observe = true, viewer = "Alice" })
			assert.are.equal(0, #r.rows)
			assert.are.equal(0, r.hidden)
		end)
	end)
end)
