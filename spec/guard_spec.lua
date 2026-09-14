-- The error boundary.
--
-- This is the code that runs when something else has already gone wrong, which
-- makes it the code least likely to be exercised before it matters and most
-- embarrassing to get wrong. It is here because the first version WAS wrong in
-- a way only one test shape reveals -- see "unprintable" below.
--
-- Mutation-tested. Reporting on every occurrence instead of once per site,
-- swallowing the failure silently, returning the wrong answer to the caller,
-- and building the report outside the pcall were each introduced and each
-- caught here.

local helper = require("spec.helper")

describe("Guard", function()
	local ns = helper.namespace()

	-- Fresh warning log and a fresh "already reported" table per test, so one
	-- test's first failure is not another's second.
	local function fresh()
		local warnings = {}
		ns.Warn = function(msg) warnings[#warnings + 1] = msg end
		ns.GuardModule.Reset()
		return warnings
	end

	describe("the caller's answer", function()
		it("returns true when nothing went wrong", function()
			fresh()
			assert.is_true(ns.Guard("site", function() return 1 end))
		end)

		it("returns false when something did", function()
			fresh()
			assert.is_false(ns.Guard("site", function() error("boom") end))
		end)

		it("forwards arguments", function()
			fresh()
			local got
			ns.Guard("site", function(a, b) got = a + b end, 2, 3)
			assert.are.equal(5, got)
		end)

		it("does not rethrow", function()
			fresh()
			-- The entire point: the caller is somebody else's dispatch loop.
			assert.is_true((pcall(ns.Guard, "site", function() error("boom") end)))
		end)
	end)

	describe("reporting", function()
		-- MUTATION: swallowing it. Silence is the outcome this addon refuses
		-- everywhere else; an error handler that hides errors is worse than no
		-- error handler, because it converts a loud bug into a quiet one.
		it("says something when a call fails", function()
			local warnings = fresh()
			ns.Guard("the widget", function() error("boom") end)
			assert.are.equal(1, #warnings)
		end)

		it("names the site so somebody knows where to look", function()
			local warnings = fresh()
			ns.Guard("the widget", function() error("boom") end)
			assert.is_truthy(warnings[1]:find("the widget", 1, true))
		end)

		-- MUTATION: reporting every time. A comm handler that throws throws for
		-- every message; "537 errors in a night" is a real number from this
		-- addon's history, and five hundred copies of a message bury it.
		it("reports a repeat failure at the same site only once", function()
			local warnings = fresh()
			for _ = 1, 50 do
				ns.Guard("the widget", function() error("boom") end)
			end
			assert.are.equal(1, #warnings)
		end)

		it("still reports a different site", function()
			local warnings = fresh()
			ns.Guard("one", function() error("boom") end)
			ns.Guard("two", function() error("boom") end)
			assert.are.equal(2, #warnings)
		end)

		it("says nothing at all when nothing failed", function()
			local warnings = fresh()
			ns.Guard("the widget", function() return true end)
			assert.are.equal(0, #warnings)
		end)
	end)

	describe("an error that cannot be printed", function()
		-- MUTATION: building the message outside the pcall.
		--
		-- THIS IS THE ONE THAT CAUGHT THE REAL BUG. Written the obvious way --
		-- pcall(ns.Warn, ("..."):format(tostring(err))) -- the message is built
		-- BEFORE pcall is entered, so an error object whose tostring throws
		-- goes straight out of the error handler. Every other test in this file
		-- passes either way; only this shape distinguishes them.
		--
		-- It is not a hypothetical object. Concatenation propagates secrecy
		-- silently, so any secret value reaching an error message produces
		-- exactly this behaviour -- which is the failure mode that produced
		-- this addon's worst night.
		local function unprintable()
			return setmetatable({}, { __tostring = function() error("secret") end })
		end

		it("does not throw out of the guard", function()
			fresh()
			local ok = pcall(ns.Guard, "the widget", function() error(unprintable()) end)
			assert.is_true(ok)
		end)

		it("still answers the caller", function()
			fresh()
			assert.is_false(ns.Guard("the widget", function() error(unprintable()) end))
		end)

		-- Lost the detail, never the fact.
		it("still reports, naming the site", function()
			local warnings = fresh()
			ns.Guard("the widget", function() error(unprintable()) end)
			assert.are.equal(1, #warnings)
			assert.is_truthy(warnings[1]:find("the widget", 1, true))
		end)
	end)
end)
