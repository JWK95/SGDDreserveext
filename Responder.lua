-- Responder.lua -- answering "!wdir" in a whisper.
--
-- What the trigger means and what the reply looks like live in Whisper.lua,
-- which is pure and tested. This file owns the parts that need the game: the
-- event, who is allowed to answer, and the cooldown.
--
-- This is the one place the addon SPEAKS. It still never changes what
-- RCLootCouncil does -- it sends one whisper, in reply, only when asked. That
-- is a real widening of "read-only" and it is deliberate: it is what let the
-- personal export die, because a raider now needs no addon at all to find out
-- what they reserved.

local _, ns = ...

local Whisper = ns.Whisper

local Responder = { active = false }
ns.Responder = Responder

-- One answer per person per half minute. Twenty raiders discovering the command
-- at once is a chat throttle, and a throttled master looter cannot answer
-- anybody -- including RCLootCouncil's own announcements.
local COOLDOWN = 30

local cooldowns = {}

local frame

local function SendWhisper(msg, target)
	local send = C_ChatInfo and C_ChatInfo.SendChatMessage or SendChatMessage
	if not send then return end
	pcall(send, msg, "WHISPER", nil, target)
end

--------------------------------------------------------------------------------
-- Chat messaging lockdown
--------------------------------------------------------------------------------

-- The reason this addon no longer queues anything.
--
-- CHAT_MSG_WHISPER is marked SecretInChatMessagingLockdown, and neither its
-- text nor its playerName is flagged NeverSecret. During lockdown -- an
-- encounter, a Mythic+ run or a PvP match on a communication-restricted map --
-- both arrive as SECRET VALUES. Tainted code, which means every line of this
-- addon, may hold and pass a secret but may not compare it, index it, boolean
-- test it, or run a string operation on it. Any of those is an immediate Lua
-- error.
--
-- Whisper.IsTrigger calls msg:lower(). So without the guard below, ANY whisper
-- the master looter receives during a boss pull -- not just "!wdir" -- throws
-- an error out of this addon, in the middle of a fight, looking like nothing to
-- do with reserves.
--
-- This also killed the old encounter queue outright. Secrecy is permanent, so a
-- sender name captured during lockdown can never be replied to, not when the
-- encounter ends and not ever. Queueing a name we are forbidden to read was
-- storing something we could never use. It is gone rather than kept as
-- decoration.
--
-- The cost is real and is stated in CLAUDE.md rather than hidden: during
-- lockdown the responder is DEAF. It does not see the request, so it cannot
-- answer it and cannot apologise for not answering it. That dents "the
-- responder never goes quiet", and it is not fixable from inside this addon at
-- any price -- people ask between pulls, which still works.
local function InLockdown()
	if not (C_ChatInfo and C_ChatInfo.InChatMessagingLockdown) then
		-- Before 12.0 there is no lockdown and no secrets, so there is nothing
		-- to be deaf to.
		return false
	end
	-- One return value on purpose. This briefly returned a second
	-- "lockdownReason" and 12.0.5 removed it again; reading only the first is
	-- correct in every version that has the function.
	local ok, restricted = pcall(C_ChatInfo.InChatMessagingLockdown)
	if not ok then return false end
	return restricted == true
end

--------------------------------------------------------------------------------
-- The answer
--------------------------------------------------------------------------------

-- Always one of three sentences, never silence. "You have no reserves", "I have
-- no list loaded" and a list are three different facts, and a raider who gets
-- nothing back cannot tell which of them is true -- which is the whole failure
-- this addon was built to stamp out.
local function BuildReply(sender)
	-- ImportedSet, not Data: a week where nobody reserved anything is still a
	-- loaded list, and the honest answer to the asker is "you have no reserves"
	-- rather than "I have no list".
	local set = ns.ImportedSet()
	if not set then return Whisper.NoData() end

	local folded = ns.FoldGameName(sender)
	if not folded then return Whisper.NoReserves(sender) end

	local entries = {}
	for itemId, holders in pairs(set.reserves) do
		local tier = holders[folded]
		if tier then
			entries[#entries + 1] = {
				tier = tier,
				-- A real item link when the client has the item cached, the
				-- plain name when it does not. Warmed at import, so the cold
				-- case is rare rather than normal.
				label = ns.ItemWhisperLabel(itemId, set),
			}
		end
	end

	if #entries == 0 then return Whisper.NoReserves(sender) end
	return Whisper.FormatReply(entries) or Whisper.NoReserves(sender)
end

local function Answer(sender)
	local reply = BuildReply(sender)
	if reply then SendWhisper(reply, sender) end
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

local function OnWhisper(msg, sender)
	-- FIRST, before anything reads msg or sender. Both may be secret values
	-- right now, and reading one is an error rather than a wrong answer. Every
	-- other check in this function touches one of them.
	if InLockdown() then return end

	if not ns.Options().respondToWhispers then return end
	if not Whisper.IsTrigger(msg) then return end

	-- Only the master looter answers. They are the one person the raid can
	-- identify without being told, and one answer is better than five.
	if not ns.RC:IsMasterLooter() then return end

	local now = time()
	local last = cooldowns[sender]
	if last and now - last < COOLDOWN then return end
	cooldowns[sender] = now

	Answer(sender)
end

local function OnEvent(_, event, ...)
	if event == "CHAT_MSG_WHISPER" then
		local msg, sender = ...
		OnWhisper(msg, sender)
	end
end

--------------------------------------------------------------------------------
-- Scope
--------------------------------------------------------------------------------

-- Registered only on a client that has imported at least once -- which, since
-- only the master looter ever imports, means officers and nobody else. A raider
-- who installs this addon registers none of these events.
--
-- Deliberately keyed on "has ever imported" rather than "has data right now":
-- an officer whose data was cleared still needs to answer "I have no list
-- loaded", and dropping to silence there is the failure we are avoiding.
--
-- One event now. ENCOUNTER_START and ENCOUNTER_END went with the queue: they
-- existed to defer replies past a fight, and a deferred reply to a name we are
-- not allowed to read was never going to be sendable. See InLockdown.
function Responder:SetActive()
	local want = ns.IsOfficerClient()
	if want == self.active then return end
	self.active = want

	if want then
		frame = frame or CreateFrame("Frame")
		frame:SetScript("OnEvent", OnEvent)
		frame:RegisterEvent("CHAT_MSG_WHISPER")
	elseif frame then
		frame:UnregisterAllEvents()
		frame:SetScript("OnEvent", nil)
	end
end
