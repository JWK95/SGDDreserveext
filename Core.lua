-- Core.lua -- shared state, saved variables, events.
--
-- Weight budget this addon holds itself to: no OnUpdate anywhere, no polling,
-- no work during combat, and nothing built until it is asked for. Parsing
-- happens exactly once, when a string is pasted.
--
-- At rest -- which is every client that has never imported, meaning every
-- raider -- the addon holds exactly two registered events, ADDON_LOADED and
-- PLAYER_ENTERING_WORLD, and nothing else. The whisper responder, the encounter
-- queue and the session-start subscription are registered when a dataset
-- appears and torn down when one goes away. Since only the master looter ever
-- imports, "has data" IS the officer scope, and a raider who installs this
-- addon runs nothing.

local ADDON, ns = ...

local Names = ns.Names

ns.ADDON = ADDON
ns.VERSION_MAJOR = 2        -- must match the envelope's version; see Import.lua
ns.COLOUR = "|cff8b5cf6"    -- the site's purple, so the two read as one thing

--------------------------------------------------------------------------------
-- Output
--------------------------------------------------------------------------------

function ns.Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage(ns.COLOUR .. "SGDD Reserves|r: " .. tostring(msg))
end

function ns.Warn(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cffff4444SGDD Reserves|r: " .. tostring(msg))
end

-- Loud means loud. A chat line scrolls away behind twenty people's damage
-- meters at exactly the moment this matters, so the warning also goes on screen
-- the way a raid warning does. Local to this client, changes nothing, tells
-- nobody else.
function ns.Shout(msg)
	ns.Warn(msg)
	if RaidNotice_AddMessage and RaidWarningFrame then
		pcall(RaidNotice_AddMessage, RaidWarningFrame, tostring(msg), ChatTypeInfo["RAID_WARNING"])
	end
end

--------------------------------------------------------------------------------
-- Saved variables
--------------------------------------------------------------------------------

-- The set shape itself lives in Schema.lua, which is pure so the tests can
-- build a real one without loading this file.
local EmptySet = ns.EmptySet

function ns.DB()
	return SGDDReservesDB
end

-- One dataset, replaced wholesale by each import.
--
-- A version 1 database held two (personal and officer) and awarded records that
-- no longer exist. It is discarded rather than migrated, which is the same rule
-- the format applies to a major version mismatch: a shape that changed meaning
-- is read as a miss, never translated.
local function InitDB()
	SGDDReservesDB = SGDDReservesDB or {}

	if SGDDReservesDB.officer or SGDDReservesDB.personal then
		SGDDReservesDB.officer = nil
		SGDDReservesDB.personal = nil
		SGDDReservesDB.set = nil
		ns.Warn("your old reserve data was cleared -- the export format changed. Import tonight's list again.")
	end

	SGDDReservesDB.set = SGDDReservesDB.set or EmptySet()
	SGDDReservesDB.options = SGDDReservesDB.options or {}
	if SGDDReservesDB.options.respondToWhispers == nil then
		SGDDReservesDB.options.respondToWhispers = true
	end
end

function ns.Options()
	return (SGDDReservesDB and SGDDReservesDB.options) or {}
end

-- Two accessors, and the difference between them matters.
--
-- ImportedSet answers "did an import happen", Data answers "is there anything
-- to draw". They diverge in one real case: a week where nobody reserved
-- anything. That import is valid and current, and there is still no column to
-- show -- so the column asks Data (no import, no column, and no column of
-- blanks either), while the freshness warning and the whisper reply ask
-- ImportedSet, because telling an officer "nothing imported" when they imported
-- an hour ago is a lie that teaches them to ignore the warning.
function ns.ImportedSet()
	local set = SGDDReservesDB and SGDDReservesDB.set
	if set and set.exportedAt then return set end
	return nil
end

function ns.Data()
	local set = ns.ImportedSet()
	if set and set.reserveCount > 0 then return set end
	return nil
end

-- Has this client ever imported? Since only the master looter imports, this is
-- how the addon knows it is on an officer's machine.
--
-- Deliberately sticky rather than "has data right now". An officer whose list
-- was cleared still has to be able to answer "I have no list loaded" and still
-- has to be told they have not imported -- and both of those go quiet if the
-- scope switch keys on live data. Sticky is also what keeps a raider's client
-- inert: they never import, so it never flips.
function ns.IsOfficerClient()
	return (SGDDReservesDB and SGDDReservesDB.everImported) == true
end

--------------------------------------------------------------------------------
-- Display helpers
--------------------------------------------------------------------------------

-- Seconds to add to a UTC-parsed timestamp to reach the real epoch. Computed
-- rather than assumed, because the guild raids across realms in more than one
-- offset and half of them move twice a year.
local function UTCOffset()
	local now = time()
	local utc = date("!*t", now)
	utc.isdst = false
	return difftime(now, time(utc))
end

-- "2026-09-07T18:14:22Z" -> epoch seconds, or nil.
function ns.ParseISO(s)
	if type(s) ~= "string" then return nil end
	local y, mo, d, h, mi, se = s:match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)Z$")
	if not y then return nil end
	local asLocal = time({
		year = tonumber(y), month = tonumber(mo), day = tonumber(d),
		hour = tonumber(h), min = tonumber(mi), sec = tonumber(se),
		isdst = false,
	})
	if not asLocal then return nil end
	return asLocal + UTCOffset()
end

-- Both clocks, always. The site's stamp says how fresh the DATA is; the paste
-- stamp says how recently somebody bothered. They diverge exactly when it
-- matters -- exported Monday, pasted Friday -- and showing only one of them
-- lets five-day-old reserves read as current.
function ns.FreshnessLine(set)
	if not set or not set.exportedAt then return "no data imported" end

	local exported = ns.ParseISO(set.exportedAt)
	local exportedText = exported and date("%d %b %H:%M", exported) or set.exportedAt
	local importedText = set.importedAt and date("%d %b %H:%M", set.importedAt) or "?"

	return ("Reserves from %s  |cff666666\194\183|r  imported %s"):format(exportedText, importedText)
end

-- An item link when the client has the item cached, the exported English name
-- when it does not. The id is the truth; the name is only ever a fallback, so a
-- cold cache shows something readable instead of "item 213456".
function ns.ItemLabel(itemId, set)
	local getInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
	if getInfo then
		local _, link = getInfo(itemId)
		if link then return link end
	end
	local stored = set and set.itemNames and set.itemNames[itemId]
	if stored and stored ~= "" then return stored end
	return "item " .. tostring(itemId)
end

-- The plain English name, never a link. Used as the fallback everywhere a link
-- could not be built, and on its own wherever a link would be wrong.
function ns.ItemPlainName(itemId, set)
	local getInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
	if getInfo then
		local name = getInfo(itemId)
		if name and name ~= "" then return name end
	end
	local stored = set and set.itemNames and set.itemNames[itemId]
	if stored and stored ~= "" then return stored end
	return "item " .. tostring(itemId)
end

-- The label that goes into a "!wdir" reply: a real item link when the client
-- has the item cached, the plain name when it does not.
--
-- A well-formed item link is legal in an outgoing whisper -- RCLootCouncil
-- sends them itself. What the server rejects is a BARE "|", which is why the
-- link has to come from the client rather than be assembled by hand here.
--
-- The link is built from an item id and nothing else, so it carries no bonus
-- ids: it links the BASE item and shows base item level, not the Myth/Hero/
-- Champ level the reserve is actually for. That is a known and accepted trade.
-- The website exports item ids, no API manufactures a track-correct link from
-- an id alone, and the tier word sits right next to the link in the reply.
--
-- Falls back per entry, not per reply. A raider with one cached item and one
-- cold one gets one link and one name -- still a complete, correct answer.
-- Degrading the whole reply to plain text would punish them for the state of
-- somebody else's item cache.
function ns.ItemWhisperLabel(itemId, set)
	local getInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
	if getInfo then
		local ok, _, link = pcall(getInfo, itemId)
		if ok and link and link ~= "" then return link end
	end
	return ns.ItemPlainName(itemId, set)
end

-- Ask the client to cache every reserved item, once, when a string is pasted.
--
-- GetItemInfo returns nil for everything -- including the link -- until an item
-- is cached, and a cold cache is the NORMAL state just after a login or a
-- /reload. It is never the state on the machine this addon was written on,
-- which is exactly what makes this class of bug invisible until a raid night.
--
-- RequestLoadItemDataByID is fire and forget. Deliberately not the Item mixin's
-- ContinueOnItemLoad: some item ids never resolve, and a callback that never
-- fires is a reply that never arrives -- silence, which is the one outcome this
-- addon refuses. Nothing here registers an event or survives the call, so the
-- weight budget is unchanged: one pass over a few dozen ids, once, at paste.
function ns.WarmItemCache(set)
	if not set or type(set.reserves) ~= "table" then return end
	if not (C_Item and C_Item.RequestLoadItemDataByID) then return end

	for itemId in pairs(set.reserves) do
		pcall(C_Item.RequestLoadItemDataByID, itemId)
	end
end

--------------------------------------------------------------------------------
-- Names arriving from the game
--------------------------------------------------------------------------------

-- A whisper sender or a group member arrives as "Beefy-ArgentDawn" when they
-- are cross-realm and bare "Beefy" when they are not. A key with no realm folds
-- to just the name and would match a same-named character on any realm, so the
-- home realm is supplied when the game omits it.
function ns.FoldGameName(fullName)
	if type(fullName) ~= "string" or fullName == "" then return nil end

	local name, realm = fullName:match("^([^%-]+)%-(.+)$")
	if not name then
		name = fullName
		realm = GetNormalizedRealmName()
	end

	local key = Names.Key(name, realm)
	if not key then return nil end
	return Names.Fold(key)
end

--------------------------------------------------------------------------------
-- Freshness, against the clock the game actually keeps
--------------------------------------------------------------------------------

-- Returns a Freshness status for the current dataset.
--
-- GetSecondsUntilWeeklyReset is region-correct and needs no guessing about
-- which weekday a lockout starts on -- the guild raids across realms but sits
-- in one region, and hard-coding Wednesday would be wrong the moment it did
-- not.
function ns.FreshnessStatus()
	local set = ns.ImportedSet()
	if not set then return ns.Freshness.NONE end

	local exported = ns.ParseISO(set.exportedAt)
	local untilReset
	if C_DateAndTime and C_DateAndTime.GetSecondsUntilWeeklyReset then
		local ok, v = pcall(C_DateAndTime.GetSecondsUntilWeeklyReset)
		if ok then untilReset = v end
	end

	return ns.Freshness.Check(exported, time(), untilReset)
end

--------------------------------------------------------------------------------
-- Scope
--------------------------------------------------------------------------------

-- Called whenever the dataset may have appeared or gone away. Everything that
-- costs anything at rest hangs off this one switch.
function ns.UpdateScope()
	if ns.VotingColumn then ns.VotingColumn:Refresh() end
	if ns.Responder then ns.Responder:SetActive() end
	if ns.Nag then ns.Nag:SetActive() end
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

local events = CreateFrame("Frame")

events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")

events:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 ~= ADDON then return end
		InitDB()
		events:UnregisterEvent("ADDON_LOADED")
		return
	end

	if event == "PLAYER_ENTERING_WORLD" then
		-- RCLootCouncil is a required dependency so it is present, but its
		-- voting frame module is not guaranteed to have been created yet at
		-- ADDON_LOADED time.
		if ns.RC then ns.RC:CheckVersion() end
		if ns.OptionsPanel then
			ns.OptionsPanel:Register()
			ns.OptionsPanel:RegisterChatCommand()
		end
		ns.UpdateScope()

		local inInstance, kind = IsInInstance()
		if inInstance and kind == "raid" and ns.Nag then
			-- Group data and the master looter both lag the zone-in. One
			-- delayed check, not a poll.
			C_Timer.After(5, function() ns.Nag:OnEnterRaid() end)
		end
	end
end)
