-- Names.lua -- character key folding.
--
-- Pure: touches no WoW API and no addon state, so spec/names_spec.lua can load
-- it standalone. Every other file in this addon depends on it being correct,
-- and its failure mode is silent -- a fold that disagrees with the site's
-- matches nothing, and an empty column is indistinguishable from "nobody
-- reserved anything". Treat a change here as a change to the export contract.

local _, ns = ...

local Names = {}
ns.Names = Names

-- The site emits a character in two forms, deliberately:
--   ingameKey  "Beefy-ArgentDawn"   -- what WoW and RCLootCouncil use
--   realmSlug  "argent-dawn"        -- what the website stores
-- Stripping every separator collapses both onto the same string, so the two
-- can never disagree:
--   "Beefy-ArgentDawn"  -> "beefyargentdawn"
--   "Beefy-argent-dawn" -> "beefyargentdawn"
--
-- Safe because a WoW character name cannot contain a hyphen, a space or an
-- apostrophe: every one of those in a key belongs to the realm half.
-- Deliberately ASCII-only -- string.lower does not fold accented bytes, so
-- "Zoë" folds to "zoë" on both sides and still matches, whereas a hand-rolled
-- UTF-8 table would have to agree with the site's byte for byte to be worth
-- anything.
function Names.Fold(key)
	if type(key) ~= "string" then return nil end
	local folded = key:gsub("[%-%s']", ""):lower()
	if folded == "" then return nil end
	return folded
end

-- Build the in-game key for a character. realm may arrive empty from
-- UnitName/GetNormalizedRealmName on the player's own realm, in which case the
-- caller must supply the home realm -- a key with no realm folds to just the
-- name and would match a same-named character on any realm.
function Names.Key(name, realm)
	if type(name) ~= "string" or name == "" then return nil end
	if type(realm) ~= "string" or realm == "" then return nil end
	return name .. "-" .. realm
end

-- Split a stored "Name-Realm" into its halves. Splits on the FIRST hyphen: a
-- realm slug carries its own hyphens and the name half never does.
function Names.Split(key)
	if type(key) ~= "string" then return nil, nil end
	local name, realm = key:match("^([^%-]+)%-(.+)$")
	return name, realm
end

return Names
