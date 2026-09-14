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
--   RCLootCouncil.mldb.observe                Classes/Data/MLDB.lua
--   Comms:Subscribe(PREFIXES.MAIN, ...)       Classes/Services/Comms.lua
--     commands: "lootTable", "response", "roll"
--
-- Note what is NOT here. We do not call RCVotingFrame:GetCandidateData, which
-- returns nothing unless that module is enabled (council or observe) and is
-- module internals besides. We do not parse "srolls". We do not touch
-- addon.lootTable's candidate structures. Every read above is either a public
-- field or a Comms subscription, which is the same door RCLootCouncil's own
-- modules use.

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

-- The raw value, "Unknown" and nil included. Deliberately NOT normalised to a
-- boolean here: Protocol.AuthorityState is what decides what an unresolved
-- master looter means, and flattening the three answers to two at the point of
-- reading is how the third one gets lost.
function RC:MasterLooterName()
	local rc = self:Addon()
	if not rc then return nil end
	return rc.masterLooter
end

-- RCLootCouncil's "observe" setting, as broadcast by the master looter in the
-- MLDB and read by every client as addon.mldb.observe. Default false.
--
-- "Allows non-council members to see the voting frame." An officer who leaves
-- it off has decided what the raid sees, and Consolidation.lua honours that
-- rather than routing around it -- see the long note at the top of that file
-- for why, given that we could trivially do otherwise.
--
-- Absent MLDB is NOT "off": it means nobody has told us yet. Returns nil in
-- that case so the caller can tell the two apart.
function RC:Observe()
	local rc = self:Addon()
	if not rc then return nil end
	local mldb = rc.mldb
	if type(mldb) ~= "table" then return nil end
	return mldb.observe == true
end

-- Every item in the current loot session, in session order, as
-- { { session = n, itemId = n, link = s }, ... }.
--
-- Every item, not just the reserved ones. An item missing from the window would
-- be indistinguishable from an item nobody reserved AND from a broken key
-- match, which is the ambiguity this addon exists to remove -- so the window
-- lists them all and says "no reserves" out loud.
function RC:SessionItems()
	local _, rc = self:VotingFrame()
	if not rc then return nil end

	local ok, lootTable = pcall(rc.GetLootTable, rc)
	if not ok or type(lootTable) ~= "table" then return nil end

	local out = {}
	for session, entry in ipairs(lootTable) do
		local link = entry and entry.link
		-- A secret link would throw on the match below, and a session we cannot
		-- name is a session we cannot draw. Skipping it loses one row; letting
		-- it through loses the whole window.
		if not ns.IsSecret(link) and type(link) == "string" then
			local itemId = tonumber(link:match("item:(%d+)"))
			if itemId then
				out[#out + 1] = { session = session, itemId = itemId, link = link }
			end
		end
	end

	if #out == 0 then return nil end
	return out
end

--------------------------------------------------------------------------------
-- What is up for vote
--------------------------------------------------------------------------------

-- The session number currently up for vote, or nil.
--
-- GetCurrentSession lives on the voting frame module, which is only enabled for
-- council members and observers -- so on an ordinary raider's client this
-- returns nil even mid-session. That is why the response window falls back to
-- saying "no loot session in progress" rather than claiming to know better:
-- the honest answer on a client RCLootCouncil is not talking to.
function RC:CurrentSession()
	local vf = self:VotingFrame()
	if not vf or type(vf.GetCurrentSession) ~= "function" then return nil end
	local ok, session = pcall(vf.GetCurrentSession, vf)
	if not ok then return nil end
	return session
end

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

--------------------------------------------------------------------------------
-- Responses and rolls
--------------------------------------------------------------------------------

-- Candidates' answers, on a client that RCLootCouncil does not show them to.
--
-- These messages already arrive here. A candidate sends its response to the
-- whole group, so the bytes reach every client in the raid; RCVotingFrame just
-- does not subscribe to them unless the viewer is council or the master looter
-- turned on "observe", and with no subscriber the Comms service decodes the
-- message and drops it. Subscribing ourselves uses the same supported extension
-- point as the session-start hook above -- no internals, no module poking.
--
-- Which means we can read every response on any client regardless of what the
-- officer chose, and Consolidation.lua is where we decide not to. This file
-- supplies; that file decides. Keeping those apart is what lets the decision be
-- stated in one place and tested.
--
-- Payload, from core.lua's SendResponse:
--   data = { session, { gear1, gear2, ilvl, diff, note, response, specID, roll } }
function RC:SubscribeResponses(fn)
	return self:subscribeCommand("response", function(data, sender)
		if type(data) ~= "table" then return end
		local session = data[1]
		local body = data[2]
		if type(body) ~= "table" then return end
		fn(sender, tonumber(session), body.response or body[6], tonumber(body.roll or body[8]))
	end)
end

-- Candidate-driven rolls only, and that is a deliberate limit.
--
-- There are two roll mechanisms. This one carries the roller's NAME in the
-- payload, so a roll can be attributed with certainty. The master looter's
-- random rolls arrive as "srolls" and are matched to candidates by ALPHABETICAL
-- ORDER of candidate names, with no names in the payload at all -- a positional
-- convention inside somebody else's addon that will break silently the first
-- time their sort changes. A roll shown against the wrong raider is exactly the
-- confidently-wrong output this addon exists to eliminate, so srolls is not
-- parsed. If the guild starts using random rolls, the right fix is to read them
-- off the voting frame where RCLootCouncil has already done the matching.
--
-- Payload, from lootFrame.lua: data = { playerName, roll, sessions }
function RC:SubscribeRolls(fn)
	return self:subscribeCommand("roll", function(data)
		if type(data) ~= "table" then return end
		fn(data[1], tonumber(data[2]), data[3])
	end)
end

-- Shared plumbing for the two above. Keeps every subscription in one list so
-- scope teardown cannot forget one.
function RC:subscribeCommand(command, handler)
	self.subs = self.subs or {}
	if self.subs[command] then return true end

	local rc = self:Addon()
	if not rc or type(rc.Require) ~= "function" then return false end

	local ok, comms = pcall(rc.Require, "Services.Comms")
	if not ok or not comms or type(comms.Subscribe) ~= "function" then return false end

	local prefix = rc.PREFIXES and rc.PREFIXES.MAIN
	if not prefix then return false end

	local ok2, sub = pcall(comms.Subscribe, comms, prefix, command, function(...)
		-- Guarded because this runs inside RCLootCouncil's dispatch: an error
		-- thrown here is attributed to RCLootCouncil and can take out the rest
		-- of its subscribers for that message. ns.Guard rather than a bare
		-- pcall so the failure is reported once, with our name on it, instead
		-- of being swallowed -- these handlers fire many times per session and
		-- a silent one would hide a broken window behind an empty one.
		ns.Guard("RCLootCouncil '" .. command .. "' message", handler, ...)
	end)
	if not ok2 then return false end

	self.subs[command] = sub
	return true
end

function RC:UnsubscribeCommands()
	if not self.subs then return end
	for command, sub in pairs(self.subs) do
		if sub and type(sub.unsubscribe) == "function" then
			pcall(sub.unsubscribe, sub)
		end
		self.subs[command] = nil
	end
end
