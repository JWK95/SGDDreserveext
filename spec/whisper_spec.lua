-- The "!wdir" trigger and the reply that comes back.
--
-- Both rules here are load-bearing and neither is visible when it goes wrong:
-- a loose trigger answers whispers nobody meant as a question, and a reply that
-- silently shows four of somebody's six reserves reads as the whole answer.

local helper = require("spec.helper")
local ns = helper.namespace()
local Whisper = ns.Whisper

describe("IsTrigger", function()
	it("matches the command on its own", function()
		assert.is_true(Whisper.IsTrigger("!wdir"))
	end)

	it("is case insensitive", function()
		assert.is_true(Whisper.IsTrigger("!WDIR"))
		assert.is_true(Whisper.IsTrigger("!WdIr"))
	end)

	it("tolerates surrounding whitespace, which a paste picks up", function()
		assert.is_true(Whisper.IsTrigger("  !wdir  "))
	end)

	it("accepts trailing words, because people are polite", function()
		assert.is_true(Whisper.IsTrigger("!wdir please"))
	end)

	it("does NOT match a longer word starting with the trigger", function()
		-- The boundary is the whole reason IsTrigger compares against the
		-- trigger plus a space rather than just the prefix. Drop that and every
		-- word beginning "!wdir" becomes a request.
		assert.is_false(Whisper.IsTrigger("!wdirty"))
		assert.is_false(Whisper.IsTrigger("!wdirplease"))
	end)

	it("does not match the trigger mid-sentence", function()
		-- Anchored at the start: a whisper that merely mentions the command is
		-- somebody talking about it, not using it.
		assert.is_false(Whisper.IsTrigger("hey what does !wdir do"))
	end)

	it("does not match a partial command", function()
		assert.is_false(Whisper.IsTrigger("!wdi"))
		assert.is_false(Whisper.IsTrigger("wdir"))
	end)

	it("refuses a non-string", function()
		assert.is_false(Whisper.IsTrigger(nil))
		assert.is_false(Whisper.IsTrigger(42))
	end)

	it("does not begin with a number, which is what keeps RCLootCouncil out", function()
		-- RCLootCouncil's master looter client parses incoming whispers into
		-- loot responses. This file used to claim the thing protecting us was
		-- its "|Hitem:" check -- it is not. ml_core.lua does:
		--
		--     local ses = addon:GetArgs(msg, 4)
		--     ses = tonumber(ses)
		--     if not ses or ... then return end
		--
		-- The link check only runs AFTER the first token parses as a valid
		-- session number. So the load-bearing property is the leading token,
		-- and this is the assertion that has to fail if somebody changes it.
		assert.is_false(helper.leadsWithNumber(Whisper.TRIGGER))
	end)
end)

describe("FormatReply", function()
	local function reply(entries)
		return Whisper.FormatReply(entries)
	end

	it("returns nil for nothing, so the caller sends a real sentence instead", function()
		assert.is_nil(reply({}))
		assert.is_nil(reply(nil))
	end)

	it("groups by difficulty, hardest first, in the guild's words", function()
		-- The reply speaks tracks, not difficulties -- the same vocabulary the
		-- officer's column shows. Two surfaces, one set of words: see
		-- spec/tiers_spec.lua.
		local msg = reply({
			{ tier = "Heroic", label = "Bow" },
			{ tier = "Mythic", label = "Axe" },
		})
		assert.is_truthy(msg:find("Myth: Axe", 1, true))
		assert.is_truthy(msg:find("Hero: Bow", 1, true))
		assert.is_true(msg:find("Myth", 1, true) < msg:find("Hero", 1, true))
	end)

	it("orders groups by the tier, not by the label it printed", function()
		-- The grouping key is the label ("Champ") but the sort key has to be
		-- the tier ("Normal"): Tiers.Rank knows difficulties, not track names,
		-- so ranking the label instead silently drops every group to last and
		-- the reply comes out in alphabetical order with no sign anything is
		-- wrong.
		local msg = reply({
			{ tier = "Normal", label = "Shield" },
			{ tier = "Mythic", label = "Axe" },
			{ tier = "Heroic", label = "Bow" },
		})
		local m = msg:find("Myth:", 1, true)
		local h = msg:find("Hero:", 1, true)
		local c = msg:find("Champ:", 1, true)
		assert.is_true(m < h)
		assert.is_true(h < c)
	end)

	it("orders items within a difficulty, so two people's replies agree", function()
		local msg = reply({
			{ tier = "Mythic", label = "Zulian Blade" },
			{ tier = "Mythic", label = "Aegis" },
		})
		assert.is_truthy(msg:find("Aegis, Zulian Blade", 1, true))
	end)

	it("never introduces a pipe of its own", function()
		-- A BARE "|" is rejected by the server as an invalid escape code. A
		-- well-formed one -- an item link -- is fine and is the whole point of
		-- the test below. So the rule is not "no pipes in the reply", it is
		-- "no pipe this file wrote", and plain labels in means no pipes out.
		local msg = reply({
			{ tier = "Mythic", label = "Axe" },
			{ tier = "Heroic", label = "Bow" },
		})
		assert.is_nil(msg:find("|", 1, true))
	end)

	it("passes an item link through untouched", function()
		-- Labels arrive already built by Core.ItemWhisperLabel and are opaque
		-- here. Anything that escaped, trimmed or re-cased a label would turn a
		-- working link into visible garbage in a raider's chat window.
		local link = "|cffa335ee|Hitem:237569::::::::80:258:::::::|h[Aureate Sentry Greatsword]|h|r"
		local msg = reply({ { tier = "Mythic", label = link } })
		assert.is_truthy(msg:find(link, 1, true))
	end)

	it("counts link bytes against the cap, not link display text", function()
		-- The cap is 255 BYTES and the escape sequences count in full. A reply
		-- measured on what the link looks like on screen would sail past the
		-- limit -- which does not truncate, it errors or disconnects.
		local entries = {}
		for i = 1, 6 do
			entries[i] = {
				tier = "Mythic",
				label = ("|cffa335ee|Hitem:2375%02d::::::::80:258:::::::|h[Aureate Sentry Greatsword]|h|r"):format(i),
			}
		end
		assert.is_true(#reply(entries) <= Whisper.MAX_BYTES)
	end)

	it("fits two real links, which is the case that actually happens", function()
		-- The website allows two reserves per person, so this is the normal
		-- reply and it must not truncate. If this starts failing, links no
		-- longer fit and the format has to give way -- not the completeness.
		local msg = reply({
			{ tier = "Mythic", label = "|cffa335ee|Hitem:237569::::::::80:258:::::::|h[Aureate Sentry Greatsword]|h|r" },
			{ tier = "Heroic", label = "|cffa335ee|Hitem:237570::::::::80:258:::::::|h[Bandolier of the Wakening Dread]|h|r" },
		})
		assert.is_true(#msg <= Whisper.MAX_BYTES)
		assert.is_nil(msg:find("more)", 1, true))
	end)

	it("fits inside one chat message", function()
		local entries = {}
		for i = 1, 40 do
			entries[i] = { tier = "Mythic", label = ("Item%02d"):format(i) }
		end
		local msg = reply(entries)
		assert.is_true(#msg <= Whisper.MAX_BYTES)
	end)

	it("states how many it could not fit, and states it accurately", function()
		-- A truncated reply that does not say it is truncated is worse than no
		-- reply: the reader has no way to know they are looking at part of the
		-- answer. The count is the part that has to be right.
		local total = 40
		local entries = {}
		for i = 1, total do
			entries[i] = { tier = "Mythic", label = ("Item%02d"):format(i) }
		end

		local msg = reply(entries)
		local dropped = tonumber(msg:match("%(%+(%d+) more%)"))
		assert.is_number(dropped)

		local shown = 0
		for _ in msg:gmatch("Item%d%d") do shown = shown + 1 end

		assert.are.equal(total, shown + dropped)
	end)

	it("does not truncate when everything fits", function()
		local msg = reply({
			{ tier = "Mythic", label = "Axe" },
			{ tier = "Heroic", label = "Bow" },
		})
		assert.is_nil(msg:find("more)", 1, true))
	end)
end)

describe("the answers that are not a list", function()
	it("says something different for 'no list' and 'no reserves'", function()
		-- Three outcomes, three sentences, never silence. A raider who gets
		-- nothing back cannot tell which of them is true, and that ambiguity is
		-- the failure this addon exists to remove.
		assert.are_not.equal(Whisper.NoData(), Whisper.NoReserves("Beefy"))
	end)

	it("names the character it looked at, because reserves are per character", function()
		assert.is_truthy(Whisper.NoReserves("Beefy-ArgentDawn"):find("Beefy-ArgentDawn", 1, true))
	end)
end)

describe("nothing we send begins with a number", function()
	-- The same guard as the trigger, applied to the other end of the
	-- conversation. Every outgoing sentence has to fail RCLootCouncil's session
	-- parse, or the master looter's own client can read our reply as somebody
	-- voting on a session.
	it("holds for a list of reserves", function()
		local msg = Whisper.FormatReply({
			{ tier = "Mythic", label = "|cffa335ee|Hitem:237569::::::::80:258:::::::|h[Axe]|h|r" },
		})
		assert.is_false(helper.leadsWithNumber(msg))
	end)

	it("holds for a truncated list of reserves", function()
		local entries = {}
		for i = 1, 40 do
			entries[i] = { tier = "Mythic", label = ("Item%02d"):format(i) }
		end
		assert.is_false(helper.leadsWithNumber(Whisper.FormatReply(entries)))
	end)

	it("holds for both of the answers that are not a list", function()
		assert.is_false(helper.leadsWithNumber(Whisper.NoData()))
		assert.is_false(helper.leadsWithNumber(Whisper.NoReserves("Beefy")))
		assert.is_false(helper.leadsWithNumber(Whisper.NoReserves(nil)))
	end)
end)
