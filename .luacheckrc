-- luacheck configuration.
--
-- In Lua a misspelled variable is silently nil rather than an error, and this
-- addon has no compiler and no type checker. This file is the whole of the
-- static safety net, so the globals list below is an ALLOWLIST: anything not
-- named here is flagged. Adding a WoW API means adding it here, deliberately.

std = "lua51"
max_line_length = false

-- Several modules expose methods with ":" because that is how callers invoke
-- them (ns.Nag:OnEnterRaid(), ns.RC:Addon()), while the body works on
-- file-local state and never touches the implicit self. That is deliberate, not
-- an oversight.
--
-- 212 is "unused argument", and "212/self" narrows the exemption to the
-- implicit self alone -- a real argument that goes unused is still reported.
-- Blanket "no unused args" would hide those, which is why this is scoped rather
-- than turned off. (VotingColumn.lua does use the blanket form, for a different
-- reason it documents: lib-ScrollingTable's fixed nine-argument callback.)
ignore = { "212/self" }

exclude_files = {
	"Libs/",
	".luacheckrc",
	-- Build output: a COPY of the addon plus a copy of Libs/. CI never sees it
	-- (it is gitignored), but locally it makes the documented "luacheck ."
	-- report the same file twice and fail on vendored library warnings.
	"dist/",
}

-- The specs run under busted, which supplies describe/it/assert.
files["spec/"] = {
	std = "+busted",
}

globals = {
	-- Ours
	"SGDDReservesDB",
}

read_globals = {
	-- Lua/WoW shared
	"tinsert",
	"time",
	"date",
	"difftime",

	-- Frames and UI
	"CreateFrame",
	"UIParent",
	"UISpecialFrames",
	"GameTooltip",
	"DEFAULT_CHAT_FRAME",
	"RaidNotice_AddMessage",
	"RaidWarningFrame",
	"ChatTypeInfo",

	-- Player and group
	"UnitFullName",
	"UnitExists",
	"GetNormalizedRealmName",
	"GetNumGroupMembers",
	"IsInRaid",
	"IsInInstance",

	-- Items
	"C_Item",
	"GetItemInfo",

	-- Chat. The addon sends exactly one kind of message: a whisper, in reply to
	-- "!wdir", from the master looter's client. See Responder.lua.
	"C_ChatInfo",
	"SendChatMessage",

	-- Clocks
	"C_DateAndTime",
	"C_Timer",

	-- Misc
	"LibStub",
	"C_AddOns",
}
