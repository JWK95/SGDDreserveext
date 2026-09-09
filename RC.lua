-- RC.lua -- every handle into RCLootCouncil, in one file.
--
-- This addon touches RCLootCouncil in three places: it reads which item is up
-- for vote, it reads whether this client is the master looter, and it listens
-- for the comm that means a session started. This file owns all three, and
-- VotingColumn.lua owns the column spec. Nothing else in the addon may name
-- RCLootCouncil -- that is the rule, and the reason is that this is what breaks
-- when RCLootCouncil updates, so the blast radius should be one file you can
-- open rather than a search.
--
-- Everything here is READ-ONLY with respect to RCLootCouncil. We subscribe to
-- its comm prefix; we never send on it. We read its state; we never set it. The
-- addon does not set a response, pre-sort a session, filter a candidate or warn
-- before an award. Officers make the decisions; this supplies context.
--
-- Supported surfaces used, and nothing else:
--   RCVotingFrame:AddColumn / :RemoveColumn   Modules/VotingFrame/ColumnAPI.lua
--   RCLootCouncil:GetLootTable()              core.lua
--   RCVotingFrame:GetCurrentSession()         VotingFrame.lua
--   RCLootCouncil.isMasterLooter / .masterLooter
--   Comms:Subscribe(PREFIXES.MAIN, ...)       Classes/Services/Comms.lua

local _, ns = ...

local RC = { warned = false }
ns.RC = RC

-- The column API landed in RCLootCouncil 3.23.0. Below that, AddColumn does not
-- exist and the addon would simply render no column -- which is indistinguishable
-- from "nobody reserved anything", the exact ambiguity this addon exists to
-- remove. So it refuses loudly and names the version instead.
RC.MIN_VERSION = "3.23.0"

--------------------------------------------------------------------------------
-- Handles
--------------------------------------------------------------------------------

function RC:Addon()
	if not LibStub then return nil end
	local ace = LibStub("AceAddon-3.0", true)
	if not ace then return nil end
	local ok, rc = pcall(ace.GetAddon, ace, "RCLootCouncil", true)
	if not ok then return nil end
	return rc
end

function RC:VotingFrame()
	local rc = self:Addon()
	if not rc then return nil end
	local ok, vf = pcall(rc.GetModule, rc, "RCVotingFrame", true)
	if not ok then return nil, rc end
	return vf, rc
end

function RC:HasColumnAPI()
	local vf = self:VotingFrame()
	return vf ~= nil and type(vf.AddColumn) == "function"
end

-- Said once, at PLAYER_ENTERING_WORLD, and never repeated -- a message that
-- fires on every zone-in is a message people filter out.
function RC:CheckVersion()
	if self.warned then return true end
	if not self:Addon() then return false end
	if self:HasColumnAPI() then return true end

	self.warned = true
	ns.Warn(("RCLootCouncil %s or newer is required -- this addon uses its column API. No reserve column will be shown until you update.")
		:format(self.MIN_VERSION))
	return false
end

--------------------------------------------------------------------------------
-- Master looter
--------------------------------------------------------------------------------

-- RCLootCouncil carries the master looter as a name that can read "Unknown"
-- while it is still resolving. That is a THIRD answer, never "no": treating it
-- as "I am not the master looter" silences the import warning at exactly the
-- moment nobody has checked yet.
function RC:MasterLooterKnown()
	local rc = self:Addon()
	if not rc then return false end
	local ml = rc.masterLooter
	if ml == nil or ml == "Unknown" then return false end
	return true
end

function RC:IsMasterLooter()
	local rc = self:Addon()
	if not rc then return false end
	return rc.isMasterLooter == true
end

--------------------------------------------------------------------------------
-- What is up for vote
--------------------------------------------------------------------------------

-- The item id currently up for vote, or nil. Reads RCLootCouncil's own loot
-- table rather than the voting frame's -- the voting frame's copy is marked
-- deprecated in its source and documented as not in sync with the replacement.
function RC:CurrentItemId()
	local vf, rc = self:VotingFrame()
	if not vf or not rc then return nil end

	local ok, session = pcall(vf.GetCurrentSession, vf)
	if not ok or not session then return nil end

	local ok2, lootTable = pcall(rc.GetLootTable, rc)
	if not ok2 or type(lootTable) ~= "table" then return nil end

	local entry = lootTable[session]
	local link = entry and entry.link
	if type(link) ~= "string" then return nil end

	return tonumber(link:match("item:(%d+)"))
end

--------------------------------------------------------------------------------
-- Session start
--------------------------------------------------------------------------------

-- There is no AceEvent message for "a loot session started" on any client, and
-- the voting frame's own session messages only fire where the voting frame is
-- running. The honest hook is the comm the master looter actually sends: one
-- subscription, fired only when something happened, no polling.
--
-- Subscribing is read-only. We never send on RCLootCouncil's prefix.
function RC:SubscribeSessionStart(fn)
	if self.subscription then return true end

	local rc = self:Addon()
	if not rc or type(rc.Require) ~= "function" then return false end

	local ok, comms = pcall(rc.Require, "Services.Comms")
	if not ok or not comms or type(comms.Subscribe) ~= "function" then return false end

	local prefix = rc.PREFIXES and rc.PREFIXES.MAIN
	if not prefix then return false end

	local ok2, sub = pcall(comms.Subscribe, comms, prefix, "lootTable", function()
		fn()
	end)
	if not ok2 then return false end

	self.subscription = sub
	return true
end

function RC:UnsubscribeSessionStart()
	local sub = self.subscription
	self.subscription = nil
	if sub and type(sub.unsubscribe) == "function" then
		pcall(sub.unsubscribe, sub)
	end
end
