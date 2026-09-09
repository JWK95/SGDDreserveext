-- Decoding and parsing an export.
--
-- The base64 vectors are RFC 4648's own. They are here to pin the ALPHABET:
-- the website encodes with Node's built-in base64 and this decoder has to agree
-- with it byte for byte, and a wrong alphabet does not error -- it produces
-- plausible-looking bytes that fail deflate later with a misleading message.

local helper = require("spec.helper")
local ns = helper.namespace()
local Import = ns.Import

describe("DecodeBase64", function()
	it("matches the RFC 4648 test vectors", function()
		assert.are.equal("f", Import.DecodeBase64("Zg=="))
		assert.are.equal("fo", Import.DecodeBase64("Zm8="))
		assert.are.equal("foo", Import.DecodeBase64("Zm9v"))
		assert.are.equal("foob", Import.DecodeBase64("Zm9vYg=="))
		assert.are.equal("fooba", Import.DecodeBase64("Zm9vYmE="))
		assert.are.equal("foobar", Import.DecodeBase64("Zm9vYmFy"))
	end)

	it("decodes the high end of the alphabet", function()
		-- Exercises index 62 and 63 ("+" and "/"), which base64url spells "-"
		-- and "_". If the website ever switches to base64url this test is what
		-- catches it.
		assert.are.equal("\251\255\191", Import.DecodeBase64("+/+/"))
	end)

	it("refuses a truncated string", function()
		local ok, err = Import.DecodeBase64("Zm9vYmF")
		assert.is_nil(ok)
		assert.is_string(err)
	end)

	it("refuses characters outside the alphabet", function()
		local ok = Import.DecodeBase64("Zm9v*mFy")
		assert.is_nil(ok)
	end)

	it("tolerates whitespace, which is what a paste picks up", function()
		assert.are.equal("foobar", Import.DecodeBase64("Zm9v\n YmFy"))
	end)
end)

local function payload(lines)
	return table.concat(lines, "\n")
end

-- Format version 2: one dataset, no K record, no A record.
local GOOD = {
	"V|2|0",
	"G|Same Gear Different Day",
	"T|2026-09-07T18:14:22Z",
	"C|Talithmusher-TwistingNether|Talithmusher|twisting-nether|PALADIN",
	"C|Beefy-ArgentDawn|Beefy|argent-dawn|WARRIOR",
	"S|Talithmusher-TwistingNether|213456|Mythic|2026-09-03T19:04:11Z|Greatsword",
	"S|Beefy-ArgentDawn|213456|Heroic|2026-09-04T11:20:44Z|Greatsword",
}

describe("ParsePayload", function()
	it("reads a well-formed export", function()
		local set, err = Import.ParsePayload(payload(GOOD))
		assert.is_nil(err)
		assert.are.equal("Same Gear Different Day", set.guild)
		assert.are.equal("2026-09-07T18:14:22Z", set.exportedAt)
		assert.are.equal(2, set.reserveCount)
	end)

	it("indexes reserves by item id so the column lookup is O(1)", function()
		local set = Import.ParsePayload(payload(GOOD))
		local holders = set.reserves[213456]
		assert.is_table(holders)
		assert.are.equal("Mythic", holders[ns.Names.Fold("Talithmusher-TwistingNether")])
		assert.are.equal("Heroic", holders[ns.Names.Fold("Beefy-ArgentDawn")])
	end)

	it("finds a character by the website's slug form as well as the in-game form", function()
		-- Both forms are carried precisely so one of them failing is survivable.
		local set = Import.ParsePayload(payload(GOOD))
		assert.is_table(set.chars[ns.Names.Fold("Beefy-ArgentDawn")])
		assert.is_table(set.chars[ns.Names.Fold("Beefy-argent-dawn")])
	end)

	it("refuses a major version it does not know", function()
		local lines = { unpack(GOOD) }
		lines[1] = "V|3|0"
		local set, err = Import.ParsePayload(payload(lines))
		assert.is_nil(set)
		assert.is_string(err)
	end)

	it("refuses a version 1 export", function()
		-- Version 1 carried a K record and a personal dataset. It is read as a
		-- miss and refused, never migrated: a shape that changed meaning is not
		-- something to translate.
		local lines = { unpack(GOOD) }
		lines[1] = "V|1|0"
		local set, err = Import.ParsePayload(payload(lines))
		assert.is_nil(set)
		assert.is_string(err)
	end)

	it("blames the website for an older format and the addon for a newer one", function()
		-- The addon ships before the website does, so a version BELOW ours is
		-- the expected cutover failure and the officer's fix is on the site.
		-- Telling somebody who updated an hour ago to update again is how a
		-- real message gets ignored.
		assert.is_truthy(Import.VersionMessage(1):find("website"))
		assert.is_truthy(Import.VersionMessage(3):find("Update the addon"))
	end)

	it("tolerates unknown record types", function()
		-- The minor-version contract: the website adds a record, and last
		-- week's addon keeps working instead of every raider breaking at once.
		-- The retired K and A records land here now, which is what makes a
		-- transitional export that still emits them harmless.
		local lines = { unpack(GOOD) }
		table.insert(lines, "Z|something|new")
		table.insert(lines, "K|officer")
		table.insert(lines, "A|Beefy-ArgentDawn|213460|Heroic|2026-09-05T21:33:00Z|Band")
		local set, err = Import.ParsePayload(payload(lines))
		assert.is_nil(err)
		assert.are.equal(2, set.reserveCount)
		assert.is_nil(set.awarded)
	end)

	it("tolerates extra trailing fields on a known record", function()
		local lines = { unpack(GOOD) }
		lines[6] = lines[6] .. "|a future field"
		local set, err = Import.ParsePayload(payload(lines))
		assert.is_nil(err)
		assert.are.equal(2, set.reserveCount)
	end)

	it("refuses a payload with no version record", function()
		local lines = {}
		for i = 2, #GOOD do lines[#lines + 1] = GOOD[i] end
		local set, err = Import.ParsePayload(payload(lines))
		assert.is_nil(set)
		assert.is_string(err)
	end)

	it("refuses a payload with no timestamp", function()
		-- Freshness is the whole point. A set with no export stamp cannot say
		-- how old it is, and the stale-import warning has nothing to read.
		local lines = {}
		for _, line in ipairs(GOOD) do
			if not line:match("^T|") then lines[#lines + 1] = line end
		end
		local set, err = Import.ParsePayload(payload(lines))
		assert.is_nil(set)
		assert.is_string(err)
	end)

	it("does not double-count a repeated reserve", function()
		local lines = { unpack(GOOD) }
		table.insert(lines, GOOD[6])
		local set = Import.ParsePayload(payload(lines))
		assert.are.equal(2, set.reserveCount)
	end)
end)
