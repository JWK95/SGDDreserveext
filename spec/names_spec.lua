-- The character key fold.
--
-- This is the addon's one invisible failure: if the fold disagrees with what
-- the website emits, every import "succeeds", every column renders blank, and
-- a blank column is indistinguishable from nobody having reserved anything. So
-- these are the tests that have to be loud.
--
-- Mutation-tested. Removing the hyphen from the strip class, dropping the
-- lowercase, and splitting on the last hyphen instead of the first were each
-- introduced and each caught here.

local helper = require("spec.helper")
local Names = helper.namespace().Names

describe("Names.Fold", function()
	it("collapses the in-game form and the website slug onto the same string", function()
		-- The whole reason the export carries a character twice. These two are
		-- the same person and MUST fold identically.
		assert.are.equal(Names.Fold("Beefy-ArgentDawn"), Names.Fold("Beefy-argent-dawn"))
		assert.are.equal(Names.Fold("Talithmusher-TwistingNether"), Names.Fold("Talithmusher-twisting-nether"))
	end)

	it("handles multi-word realms", function()
		assert.are.equal("beefyargentdawn", Names.Fold("Beefy-Argent Dawn"))
		assert.are.equal("beefyargentdawn", Names.Fold("Beefy-ArgentDawn"))
		assert.are.equal("beefyargentdawn", Names.Fold("Beefy-argent-dawn"))
	end)

	it("handles apostrophe realms", function()
		-- Kil'jaeden in game, kiljaeden as a slug.
		assert.are.equal("xyzkiljaeden", Names.Fold("Xyz-Kil'jaeden"))
		assert.are.equal("xyzkiljaeden", Names.Fold("Xyz-kiljaeden"))
	end)

	it("is case insensitive", function()
		assert.are.equal(Names.Fold("BEEFY-ARGENTDAWN"), Names.Fold("beefy-argentdawn"))
	end)

	it("keeps different realms apart", function()
		-- The guild raids across many realms, so a fold that collapses two of
		-- them would attribute one player's reserves to another player.
		assert.are_not.equal(Names.Fold("Beefy-ArgentDawn"), Names.Fold("Beefy-TwistingNether"))
	end)

	it("keeps different names apart on one realm", function()
		assert.are_not.equal(Names.Fold("Beefy-ArgentDawn"), Names.Fold("Beefox-ArgentDawn"))
	end)

	it("refuses what is not a string, and empty results", function()
		assert.is_nil(Names.Fold(nil))
		assert.is_nil(Names.Fold(42))
		assert.is_nil(Names.Fold(""))
		assert.is_nil(Names.Fold("---"))
	end)
end)

describe("Names.Key", function()
	it("joins a name and realm", function()
		assert.are.equal("Beefy-ArgentDawn", Names.Key("Beefy", "ArgentDawn"))
	end)

	it("refuses a missing realm", function()
		-- A key with no realm folds to just the name and would match a
		-- same-named character on any realm in the export.
		assert.is_nil(Names.Key("Beefy", nil))
		assert.is_nil(Names.Key("Beefy", ""))
		assert.is_nil(Names.Key(nil, "ArgentDawn"))
	end)
end)

describe("Names.Split", function()
	it("splits on the first hyphen, not the last", function()
		-- A realm slug carries its own hyphens; a character name never does.
		local name, realm = Names.Split("Beefy-argent-dawn")
		assert.are.equal("Beefy", name)
		assert.are.equal("argent-dawn", realm)
	end)

	it("returns nils for something that is not a key", function()
		local name, realm = Names.Split("Beefy")
		assert.is_nil(name)
		assert.is_nil(realm)
	end)
end)
