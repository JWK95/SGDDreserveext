-- The wire between a master looter and a raider.
--
-- Everything here is a rule that fails invisibly in a raid: a version mismatch
-- read as an empty list, a forged reserve list accepted as gospel, a broadcast
-- storm that disconnects the one client that must not disconnect, a dialog that
-- reappears on every boss.
--
-- Mutation-tested. Accepting a mismatched wire version, accepting a payload
-- from somebody who is not the master looter, accepting one while the master
-- looter is still "Unknown", broadcasting per request instead of coalescing,
-- re-prompting for a list already accepted, and collapsing the four outcomes
-- into one message were each introduced and each caught here.

local helper = require("spec.helper")

describe("Protocol", function()
	local ns = helper.namespace()
	local P = ns.Protocol

	describe("round trip", function()
		it("parses an announce it built", function()
			local msg = P.Announce("2026-09-14T18:00:00Z", 94)
			local got = P.Parse(msg)
			assert.is_table(got)
			assert.are.equal(P.ANNOUNCE, got.kind)
			assert.are.equal("2026-09-14T18:00:00Z", got.exportedAt)
			assert.are.equal(94, got.reserveCount)
		end)

		it("parses a data payload it built, byte for byte", function()
			local export = "SGDDR:2:SGVsbG8gd29ybGQ="
			local got = P.Parse(P.Data(export))
			assert.is_table(got)
			assert.are.equal(P.DATA, got.kind)
			-- The export string is the contract. Anything that mangles it here
			-- produces a raider holding a different list from the officer.
			assert.are.equal(export, got.export)
		end)

		it("parses a request and a no-list", function()
			assert.are.equal(P.REQUEST, P.Parse(P.Request()).kind)
			assert.are.equal(P.NOLIST, P.Parse(P.NoList()).kind)
		end)

		it("does not corrupt a base64 payload containing + / and =", function()
			local export = "SGDDR:2:ab+/cd=="
			assert.are.equal(export, P.Parse(P.Data(export)).export)
		end)
	end)

	describe("wire version", function()
		-- MUTATION: accepting any wire version. A newer master looter's payload
		-- would be handed to a parser that does not understand it, and the
		-- raider would see an empty window rather than "update the addon".
		it("refuses a version above ours", function()
			local msg = "A\t" .. tostring(P.VERSION + 1) .. "\t2026-09-14T18:00:00Z\t5"
			local got, reason = P.Parse(msg)
			assert.is_nil(got)
			assert.is_string(reason)
		end)

		it("refuses a version below ours", function()
			local msg = "A\t" .. tostring(P.VERSION - 1) .. "\t2026-09-14T18:00:00Z\t5"
			local got, reason = P.Parse(msg)
			assert.is_nil(got)
			assert.is_string(reason)
		end)

		it("names the side that is behind, in the direction the reader can act", function()
			local newer = P.VersionMessage(P.VERSION + 1)
			local older = P.VersionMessage(P.VERSION - 1)
			-- Two different situations, two different sentences. Telling a
			-- raider who just updated to update again is how a real message
			-- gets ignored.
			assert.are_not.equal(newer, older)
		end)

		it("refuses a message with no version at all", function()
			assert.is_nil(P.Parse("A\tnotanumber\t2026-09-14T18:00:00Z\t5"))
		end)
	end)

	describe("malformed messages", function()
		it("refuses an unrecognised kind", function()
			assert.is_nil(P.Parse("Z\t" .. P.VERSION))
		end)

		it("refuses an announce with no timestamp", function()
			assert.is_nil(P.Parse("A\t" .. P.VERSION .. "\t\t5"))
		end)

		it("refuses an empty payload", function()
			assert.is_nil(P.Parse("D\t" .. P.VERSION .. "\t"))
		end)

		it("refuses a non-string", function()
			assert.is_nil(P.Parse(nil))
			assert.is_nil(P.Parse(42))
		end)
	end)

	describe("authority", function()
		-- MUTATION: trusting the sender. Anyone in the raid can register the
		-- prefix and send a list; without this, one person can make every
		-- raider's window read "you reserved nothing".
		it("rejects a sender who is not the master looter", function()
			assert.is_false(P.IsAuthority("beefy-argentdawn", "officer-argentdawn", "Officer-ArgentDawn"))
		end)

		it("accepts the master looter", function()
			assert.is_true(P.IsAuthority("officer-argentdawn", "officer-argentdawn", "Officer-ArgentDawn"))
		end)

		-- MUTATION: treating "Unknown" as a name. RCLootCouncil reports the
		-- master looter as "Unknown" while it is still resolving, which is a
		-- third answer and never "yes".
		it("rejects everyone while the master looter is Unknown", function()
			assert.is_false(P.IsAuthority("officer-argentdawn", "officer-argentdawn", "Unknown"))
			assert.is_false(P.IsAuthority("unknown", "unknown", "Unknown"))
		end)

		it("rejects everyone while the master looter is nil or empty", function()
			assert.is_false(P.IsAuthority("officer-argentdawn", "officer-argentdawn", nil))
			assert.is_false(P.IsAuthority("officer-argentdawn", "officer-argentdawn", ""))
		end)

		it("rejects an empty or non-string sender", function()
			assert.is_false(P.IsAuthority("", "officer-argentdawn", "Officer-ArgentDawn"))
			assert.is_false(P.IsAuthority(nil, "officer-argentdawn", "Officer-ArgentDawn"))
		end)

		it("reports the unresolved state separately from a refusal", function()
			assert.are.equal("unresolved", P.AuthorityState(nil))
			assert.are.equal("unresolved", P.AuthorityState("Unknown"))
			assert.are.equal("known", P.AuthorityState("Officer-ArgentDawn"))
		end)
	end)

	describe("coalescing", function()
		it("answers the first request", function()
			assert.is_true(P.ShouldBroadcast(1000, nil))
		end)

		-- MUTATION: broadcasting per request. Twenty raiders click yes within
		-- two seconds of a boss dying; answering each one individually is the
		-- full reserve set multiplied by the raid size, on the master looter's
		-- outbound budget, which the API documentation says can disconnect the
		-- client outright.
		it("does NOT answer a second request inside the window", function()
			assert.is_false(P.ShouldBroadcast(1001, 1000))
			assert.is_false(P.ShouldBroadcast(1000 + P.COALESCE_WINDOW - 1, 1000))
		end)

		it("answers again once the window has passed", function()
			assert.is_true(P.ShouldBroadcast(1000 + P.COALESCE_WINDOW, 1000))
			assert.is_true(P.ShouldBroadcast(9999, 1000))
		end)

		it("honours an explicit window", function()
			assert.is_false(P.ShouldBroadcast(1005, 1000, 30))
			assert.is_true(P.ShouldBroadcast(1031, 1000, 30))
		end)
	end)

	describe("prompting", function()
		it("asks about a list it has never seen", function()
			assert.is_true(P.ShouldPrompt("2026-09-14T18:00:00Z", nil))
		end)

		-- MUTATION: prompting every session. A raid night is eight or more loot
		-- sessions; a dialog at each one is an addon people disable by boss
		-- three, and then the feature is worse than not existing.
		it("does NOT ask again about a list already accepted", function()
			assert.is_false(P.ShouldPrompt("2026-09-14T18:00:00Z", "2026-09-14T18:00:00Z"))
		end)

		it("asks again when the officer imports a new list", function()
			assert.is_true(P.ShouldPrompt("2026-09-21T18:00:00Z", "2026-09-14T18:00:00Z"))
		end)

		it("does not ask on a missing timestamp", function()
			assert.is_false(P.ShouldPrompt(nil, nil))
			assert.is_false(P.ShouldPrompt("", nil))
		end)
	end)

	describe("the four outcomes", function()
		-- MUTATION: collapsing them. "The leader has not imported" said to
		-- somebody whose master looter does not run this addon sends them to
		-- nag an officer who cannot fix it; said during lockdown it is simply
		-- false. Four facts, four sentences, and silence is not one of them.
		it("are four distinct sentences", function()
			local seen = {}
			local n = 0
			for _, msg in pairs(P.OUTCOME) do
				assert.is_string(msg)
				assert.is_true(#msg > 0)
				assert.is_nil(seen[msg])
				seen[msg] = true
				n = n + 1
			end
			assert.are.equal(4, n)
		end)

		it("distinguishes no-list from no-answer", function()
			assert.are_not.equal(P.OUTCOME.NO_LIST, P.OUTCOME.NO_ANSWER)
		end)

		it("gives lockdown its own sentence rather than blaming the officer", function()
			assert.are_not.equal(P.OUTCOME.REFUSED, P.OUTCOME.NO_LIST)
			assert.are_not.equal(P.OUTCOME.REFUSED, P.OUTCOME.NO_ANSWER)
		end)
	end)

	describe("the prefix", function()
		it("fits the 16-character addon message limit", function()
			assert.is_true(#P.PREFIX <= 16)
		end)

		it("is not one of RCLootCouncil's", function()
			assert.are_not.equal("RCLC", P.PREFIX)
			assert.are_not.equal("RCLCv", P.PREFIX)
			assert.are_not.equal("RCLCs", P.PREFIX)
		end)
	end)
end)
