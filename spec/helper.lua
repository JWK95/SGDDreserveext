-- Loads addon files outside WoW.
--
-- Each file starts with `local ADDON, ns = ...`, so a chunk has to be called
-- with those two arguments. Only the pure files can be loaded this way: Core,
-- RC, VotingColumn, Responder, Nag, OfficerFrame and Options all touch the WoW
-- API at load or call time and are not covered here.

local M = {}

local function chunk(path)
	local f, err = loadfile(path)
	assert(f, err)
	return f
end

-- A namespace carrying the pure modules, as the addon assembles them in TOC
-- order.
function M.namespace()
	local ns = {}
	ns.VERSION_MAJOR = 2
	chunk("Names.lua")("SGDDReserves", ns)
	chunk("Tiers.lua")("SGDDReserves", ns)
	chunk("Schema.lua")("SGDDReserves", ns)
	chunk("Freshness.lua")("SGDDReserves", ns)
	chunk("Whisper.lua")("SGDDReserves", ns)
	chunk("Import.lua")("SGDDReserves", ns)
	return ns
end

-- Does this message begin with a token that tonumber() accepts?
--
-- RCLootCouncil's master looter reads an incoming whisper as
-- "<session number> <item link> ..." and returns early when the first token is
-- not a number. That early return is what keeps this addon's whisper traffic
-- out of its loot responses, so the trigger and every reply have to fail this.
--
-- It matters more now that replies carry item links: a reply beginning with a
-- number would hand RCLootCouncil a session number followed by a link, which is
-- precisely the shape it acts on.
function M.leadsWithNumber(s)
	if type(s) ~= "string" then return false end
	local first = s:match("^%s*(%S+)")
	return first ~= nil and tonumber(first) ~= nil
end

return M
