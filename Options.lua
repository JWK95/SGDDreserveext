-- Options.lua -- the settings panel, nested under RCLootCouncil's.
--
-- This is what "an extension of RCLootCouncil, not a standalone addon" actually
-- looks like in the settings tree: AceConfigDialog's third argument parents our
-- panel to RCLootCouncil's own entry, so an officer finds it where they already
-- look. It is the same route RCLootCouncil_Merit takes.
--
-- Note what is NOT done here: RCLootCouncil rebuilds its options table from
-- scratch on every refresh, so anything inserted into it would be silently
-- discarded. We register our own table and hang it off theirs. No part of
-- RCLootCouncil's configuration is read or written.
--
-- Ace3 itself is not embedded -- RCLootCouncil is a required dependency and
-- loads it, exactly as Merit relies on.

local _, ns = ...

local OptionsPanel = { registered = false }
ns.OptionsPanel = OptionsPanel

local function Table()
	return {
		type = "group",
		name = "SGDD Reserves",
		args = {
			status = {
				order = 1,
				type = "description",
				fontSize = "medium",
				name = function()
					local set = ns.ImportedSet()
					if not set then
						return "|cffff4444Nothing imported.|r No reserve column will be shown."
					end
					if set.reserveCount == 0 then
						return ("Imported %s, but nobody has reserved anything -- no column will be shown.")
							:format(set.exportedAt)
					end
					local line = ("%d reserves, exported %s."):format(set.reserveCount, set.exportedAt)
					if ns.Freshness.IsStale(ns.FreshnessStatus()) then
						return "|cffff4444" .. line .. " This list is out of date.|r"
					end
					return line
				end,
			},
			open = {
				order = 2,
				type = "execute",
				name = "Open import window",
				desc = "Also available as /rc reserves.",
				func = function() ns.OfficerFrame:Show() end,
			},
			gap1 = { order = 3, type = "header", name = "Whisper replies" },
			respond = {
				order = 4,
				type = "toggle",
				width = "full",
				name = "Answer !wdir whispers",
				desc = "When you are the master looter, reply to anyone who whispers you !wdir with the reserves they are holding. "
					.. "Replies are held during an encounter and sent when it ends.",
				get = function() return ns.Options().respondToWhispers end,
				set = function(_, v) ns.Options().respondToWhispers = v end,
			},
			explain = {
				order = 5,
				type = "description",
				name = "Only the master looter answers, so the raid always gets exactly one reply. "
					.. "Raiders do not need this addon installed to ask.",
			},
			gap2 = { order = 6, type = "header", name = "What raiders see" },
			observe = {
				order = 7,
				type = "description",
				name = "This addon shows nothing on a raider's client. If you want raiders to see the "
					.. "session and what everybody rolled, turn on RCLootCouncil's own |cffffffffObserve|r "
					.. "setting (Master Looter settings). It is per master looter, so whoever is running "
					.. "loot that night needs it on.",
			},
		},
	}
end

-- Registered at PLAYER_ENTERING_WORLD rather than at load: RCLootCouncil has to
-- have registered its own panel first for ours to have a parent to hang from.
function OptionsPanel:Register()
	if self.registered then return end
	if not LibStub then return end

	local config = LibStub("AceConfig-3.0", true)
	local dialog = LibStub("AceConfigDialog-3.0", true)
	if not config or not dialog then return end

	local ok = pcall(config.RegisterOptionsTable, config, "SGDDReserves", Table())
	if not ok then return end

	pcall(dialog.AddToBlizOptions, dialog, "SGDDReserves", "SGDD Reserves", "RCLootCouncil")
	self.registered = true
end

-- "/rc reserves" opens the import window. ModuleChatCmd is RCLootCouncil's
-- documented hook for exactly this, and its own usage example is a third-party
-- addon, so this is the supported way in rather than a slash command of our own.
function OptionsPanel:RegisterChatCommand()
	if self.chatRegistered then return end

	local rc = ns.RC:Addon()
	if not rc or type(rc.ModuleChatCmd) ~= "function" then return end

	self.chatRegistered = true

	-- "/rc help" prints the owning module's baseName and version for every
	-- registered command, and falls back to C_AddOns.GetAddOnMetadata(baseName)
	-- when there is no version field. RCLootCouncil's own modules are AceAddon
	-- modules and carry both for free; ours is a plain table, so without these
	-- two lines baseName is nil, the metadata lookup throws, and we break
	-- somebody else's "/rc help" rather than our own feature.
	--
	-- pcall because C_AddOns.GetAddOnMetadata ERRORS on an addon name it does
	-- not know, where the old global returned nil. ns.ADDON is this folder's
	-- own name so it is always valid -- but an unguarded throw here would take
	-- out "/rc reserves" registration entirely, and that is a large consequence
	-- to leave resting on an assumption about somebody else's API.
	ns.OfficerFrame.baseName = ns.ADDON
	if C_AddOns and C_AddOns.GetAddOnMetadata then
		local ok, version = pcall(C_AddOns.GetAddOnMetadata, ns.ADDON, "Version")
		if ok then ns.OfficerFrame.version = version end
	end

	pcall(rc.ModuleChatCmd, rc, ns.OfficerFrame, "Show", nil,
		"Open the SGDD Reserves import window (alt. 'sr')", "reserves", "sr")
end
