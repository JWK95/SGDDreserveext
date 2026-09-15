-- Core.lua -- shared state, saved variables, events.
--
-- Weight budget this addon holds itself to: no OnUpdate anywhere, no polling,
-- no work during combat, and nothing built until it is asked for. Parsing
-- happens exactly once, when a string is pasted.
--
-- At rest the addon holds THREE registered events -- ADDON_LOADED,
-- PLAYER_ENTERING_WORLD and GROUP_ROSTER_UPDATE -- and nothing else. It used to
-- be two, and the third arrived with the raider-facing half: a client has to be
-- able to notice it joined a raid, and no other event says so.
--
-- "At rest" also means something narrower than it used to. It was every client
-- that had never imported, which was every raider. Now a raider in a raid group
-- registers an addon-comm handler so the master looter can hand them tonight's
-- reserves (Sync.lua), and their windows draw. Outside a raid group they are
-- back to the three events and nothing else, and a raider who never joins a
-- raid still runs nothing.
--
-- TWO SCOPES, and keeping them apart is the whole trick:
--
--   IsOfficerClient()  sticky, keyed on everImported. The voting column, the
--                      whisper responder, the stale-import warning. An officer
--                      whose data was cleared is still an officer, because they
--                      still have to be able to say "I have no list".
--   InRaidScope()      not sticky, keyed on being in a raid group. The sync
--                      handler and the windows. Tears down on leaving.
--
-- Nothing may key officer behaviour off "has data", because a raider now has
-- data too. That is why received lists live in their own slot.

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
-- Secret values
--------------------------------------------------------------------------------

-- The one place in this addon that knows what a secret value is.
--
-- A secret is a value tainted code -- which is every line of every addon --
-- may hold, pass along and concatenate, but may not compare, index, take the
-- length of, or store as a table key. Reading one the wrong way is an
-- immediate Lua error, not a wrong answer.
--
-- Two things about them are counter-intuitive enough to be worth writing down,
-- because this addon assumed both of them wrong until a raid said otherwise.
--
-- FIRST: type() returns the REAL type. A secret string answers "string", so
-- every `if type(x) ~= "string" then return nil end` in this codebase screens
-- exactly nothing -- the secret walks through it into the gsub on the next
-- line. issecretvalue is the only screen that exists. Names.Fold, Names.Split,
-- Reservers.RealmOf and RC:CurrentItemId all carry that guard and none of them
-- is protected by it; they are pure or foreign-facing, so the screening is done
-- HERE, at each point a value crosses in from the game.
--
-- SECOND: concatenation and string.format are ALLOWED, and they propagate.
-- Folding a secret into a message produces a secret message, silently, and no
-- error arrives until that message reaches something that needs real bytes --
-- GameTooltip:AddLine, FontString:SetText, SendChatMessage. The throw lands a
-- long way from the value that caused it, in code that looks blameless. That is
-- exactly how this presented: "attempt to perform string conversion on a secret
-- string value", out of a tooltip, blamed on whichever addon's execution we
-- happened to be running inside.
--
-- Variadic because most call sites have more than one value to clear before
-- they touch any of them, and clearing them one at a time is how you clear
-- three and forget the fourth.
local issecret = issecretvalue

function ns.IsSecret(...)
	-- Before 12.0 there is no such thing, so there is nothing to screen.
	if not issecret then return false end
	for i = 1, select("#", ...) do
		if issecret((select(i, ...))) then return true end
	end
	return false
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
	-- DEFAULTS OFF, and this changed after a raid.
	--
	-- The item tooltip is the only part of this addon that executes inside
	-- another frame's code. Everything else draws in our own windows or through
	-- RCLootCouncil's column API. A guild member could not use items from their
	-- bags during a raid, and disabling this addon fixed it -- confirmed in
	-- game, not inferred.
	--
	-- The reason it has to be the DEFAULT rather than a switch people find after
	-- it bites them: TooltipDataProcessor.AddTooltipPostCall cannot be
	-- unregistered, and simply RUNNING on a path taints it -- an early return
	-- inside the callback does not undo having been called. So the only state
	-- that costs nothing is "never registered", and that has to be where
	-- somebody starts rather than where they end up.
	--
	-- The feature still works and is one checkbox away. See
	-- docs/in-game-gotchas.md #9.
	if SGDDReservesDB.options.showTooltipReserves == nil then
		SGDDReservesDB.options.showTooltipReserves = false
	end

	-- One-time, for anybody who already had it on.
	--
	-- A changed default does nothing for an existing install: their saved
	-- variables already say true, so they would upgrade straight back into the
	-- bug. This forces it off once, says so, and never touches the setting
	-- again -- somebody who turns it back on stays turned on.
	if not SGDDReservesDB.tooltipSafetyReset then
		SGDDReservesDB.tooltipSafetyReset = true
		if SGDDReservesDB.options.showTooltipReserves then
			SGDDReservesDB.options.showTooltipReserves = false
			ns.Warn("the 'Reserved by' tooltip line has been turned OFF. It could stop you using items "
				.. "from your bags in a raid. Everything else is unchanged -- the reserve column, the loot "
				.. "windows and !wdir replies all still work. Turn it back on in the settings if you want it.")
		end
	end
	-- Both windows open themselves when a loot session starts. The off switch
	-- exists for the same reason the tooltip's does: somebody who finds two
	-- frames intrusive needs an answer that is not "uninstall".
	if SGDDReservesDB.options.autoOpenReserves == nil then
		SGDDReservesDB.options.autoOpenReserves = true
	end
	if SGDDReservesDB.options.autoOpenResponses == nil then
		SGDDReservesDB.options.autoOpenResponses = true
	end
	-- Whether to offer the master looter's list at all. Off means no dialog
	-- ever, for somebody who does not want to be asked; the offer still arrives
	-- and is discarded unread, and /rc askml still works for a deliberate ask.
	if SGDDReservesDB.options.acceptReserveSync == nil then
		SGDDReservesDB.options.acceptReserveSync = true
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

-- The list a RAIDER received over the wire, kept in its own slot.
--
-- Deliberately NOT merged into .set, and the separation is the point. `.set` is
-- "what I imported", and half this addon keys officer behaviour off it --
-- ns.Data() gates the voting column, everImported gates the whisper responder
-- and the stale-import warning. Routing received data through the same variable
-- would silently switch officer surfaces on for twenty-five raiders, and the
-- symptom would be an SR column appearing in somebody's voting frame with no
-- explanation. Two slots, two meanings, no shared variable whose sense depends
-- on which client is reading it.
--
-- Sync.lua writes this. It never sets everImported, so a raider stays a raider.
function ns.ReceivedSet()
	local set = SGDDReservesDB and SGDDReservesDB.received
	if set and set.exportedAt then return set end
	return nil
end

-- The best list THIS client has, whoever they are: an officer's own import if
-- there is one, otherwise whatever the master looter handed out.
--
-- For read-only display only -- the reserve window and the tooltip. Nothing
-- that decides scope may call this, because "do I have a list" and "am I an
-- officer" are the two questions this addon must never conflate again.
function ns.AnySet()
	return ns.ImportedSet() or ns.ReceivedSet()
end

-- The export timestamp of the last list this client accepted from the wire.
-- Protocol.ShouldPrompt compares against it, so a raider is asked once per
-- list rather than once per boss.
function ns.LastAcceptedAt()
	return SGDDReservesDB and SGDDReservesDB.lastAcceptedAt
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
	-- First, because the equality test on the next line is a comparison and the
	-- match after it is a string operation, and both are errors on a secret.
	-- Responder guards the whisper sender against chat messaging lockdown
	-- already, but lockdown is not the only thing that makes a name secret and
	-- the set of things that do has grown in every patch since 12.0.
	if ns.IsSecret(fullName) then return nil end

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
-- Is this client somewhere the raider-facing half should be running?
--
-- NOT sticky, unlike IsOfficerClient. An officer must stay an officer after
-- their data is cleared, because they still have to be able to say "I have no
-- list"; a raider has no such obligation, so this can be exactly what it says
-- and tear down when it stops being true. Outside a raid group the addon is
-- back to its two events and nothing else.
--
-- Raid only. Inside a Mythic+ key the ChallengeMode restriction refuses addon
-- sends for the whole dungeon, so the announce never lands and a request comes
-- back refused for twenty minutes -- a feature that degrades confusingly in a
-- place nobody reserved items for. Reserves are a raid artefact: the website
-- wipes them against the weekly raid reset, which is the boundary the whole of
-- Freshness.lua is built on.
function ns.InRaidScope()
	local inInstance, kind = IsInInstance()
	if inInstance and kind ~= "raid" then return false end
	return IsInRaid() == true
end

-- Each switch guarded separately, and that is the point: without this, one
-- module throwing means every module after it in this list never runs. An
-- officer whose voting column broke would silently also lose the whisper
-- responder, the stale warning and the sync -- four failures reported as none.
function ns.UpdateScope()
	if ns.VotingColumn then ns.Guard("voting column", ns.VotingColumn.Refresh, ns.VotingColumn) end
	if ns.Responder then ns.Guard("whisper responder", ns.Responder.SetActive, ns.Responder) end
	if ns.Nag then ns.Guard("stale-import warning", ns.Nag.SetActive, ns.Nag) end
	if ns.Sync then ns.Guard("reserve sync", ns.Sync.SetActive, ns.Sync) end
	-- One way only: the tooltip callback cannot be unregistered once added, so
	-- this switch turns on and never off. See Tooltip.lua.
	if ns.Tooltip then ns.Guard("item tooltip", ns.Tooltip.SetActive, ns.Tooltip) end
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

local events = CreateFrame("Frame")

events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")

-- The third at-rest event, and it is a real addition to the budget rather than
-- a free one. The raider-facing half turns on when this client joins a raid and
-- off when it leaves, and there is no way to learn the first of those without
-- listening for it -- PLAYER_ENTERING_WORLD does not fire when a raid invite is
-- accepted in a capital city.
--
-- It is cheap in the way that matters: it fires on roster changes, not on a
-- timer, and its handler is one boolean compared against a stored one. It does
-- no work when the answer has not changed.
events:RegisterEvent("GROUP_ROSTER_UPDATE")

events:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 ~= ADDON then return end
		InitDB()
		events:UnregisterEvent("ADDON_LOADED")
		return
	end

	if event == "GROUP_ROSTER_UPDATE" then
		-- Only when the answer actually changed. GROUP_ROSTER_UPDATE fires for
		-- every join, leave, promotion and zone-in of every member, and doing
		-- real work on each of those in a twenty-five person raid is exactly
		-- the kind of cost this addon promises not to have.
		local now = ns.InRaidScope()
		if now ~= ns.raidScope then
			ns.raidScope = now
			ns.UpdateScope()
		end
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
		ns.raidScope = ns.InRaidScope()
		ns.UpdateScope()

		local inInstance, kind = IsInInstance()
		if inInstance and kind == "raid" and ns.Nag then
			-- Group data and the master looter both lag the zone-in. One
			-- delayed check, not a poll.
			C_Timer.After(5, function() ns.Nag:OnEnterRaid() end)
		end
	end
end)
