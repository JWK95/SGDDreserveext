-- Nag.lua -- "you have not imported tonight's reserves".
--
-- Fires at the master looter, twice: on entering a raid, and again when a loot
-- session opens. Entering the raid is the last moment the fact is comfortably
-- actionable; the session start is the last moment it is actionable at all.
--
-- It blocks nothing. It cannot stop a session, cannot pre-empt an award and
-- cannot alter anything RCLootCouncil does -- the whole addon's rule. It says
-- the thing loudly and gets out of the way; whether a list is too old is the
-- officer's judgement, not the addon's.

local _, ns = ...

local Freshness = ns.Freshness

local Nag = { active = false }
ns.Nag = Nag

-- RCLootCouncil sends one lootTable comm per session batch, so this rarely
-- matters -- but a master looter who restarts a session should not be shouted
-- at twice inside a minute.
local DEBOUNCE = 60

local lastWarned = 0

--------------------------------------------------------------------------------
-- What to say
--------------------------------------------------------------------------------

local function Message(status)
	local set = ns.ImportedSet()
	local stamp = set and set.exportedAt

	if status == Freshness.NONE then
		return "no reserve list imported. The voting frame will show no reserve column tonight."
	end

	if status == Freshness.RESET then
		return ("your reserve list was exported %s -- BEFORE this week's reset. Import tonight's list.")
			:format(tostring(stamp))
	end

	return ("your reserve list was exported %s and is more than %d days old. Import tonight's list.")
		:format(tostring(stamp), Freshness.MAX_AGE_DAYS)
end

--------------------------------------------------------------------------------
-- Whether to say it
--------------------------------------------------------------------------------

-- Only the master looter is nagged: they are the one person who needs the data
-- loaded, and nagging everyone who ever imported is how a warning becomes
-- background noise.
--
-- An unresolved master looter is a THIRD answer, not "no". RCLootCouncil
-- reports "Unknown" while it is still working it out, and staying quiet there
-- means the one client that needed telling hears nothing -- so it warns.
local function ShouldWarn()
	if ns.RC:IsMasterLooter() then return true end
	if not ns.RC:MasterLooterKnown() then return true end
	return false
end

local function Check()
	if not Nag.active then return end
	if not ShouldWarn() then return end

	local status = ns.FreshnessStatus()
	if not Freshness.IsStale(status) then return end

	local now = time()
	if now - lastWarned < DEBOUNCE then return end
	lastWarned = now

	ns.Shout(Message(status))

	-- The header carries the same fact for the rest of the session, for the
	-- times a chat line scrolls past unread.
	if ns.VotingColumn then ns.VotingColumn:MarkFreshness() end
end

Nag.Check = Check

function Nag:OnEnterRaid()
	Check()
end

--------------------------------------------------------------------------------
-- Scope
--------------------------------------------------------------------------------

-- The session-start subscription is opened on an officer's client and closed
-- when there is nothing to be an officer about. It is a read-only tap on
-- RCLootCouncil's existing comm traffic -- one subscription, fired only when a
-- master looter actually starts a session. No polling, no OnUpdate, no timer.
function Nag:SetActive()
	local want = ns.IsOfficerClient()
	if want == self.active then return end
	self.active = want

	if want then
		ns.RC:SubscribeSessionStart(Check)
	else
		ns.RC:UnsubscribeSessionStart()
	end
end
