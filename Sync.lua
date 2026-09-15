-- Sync.lua -- the one thing this addon broadcasts, and the one it asks for.
--
-- Protocol.lua owns what a message means; this file owns the channel, the
-- events, the dialog and the timeout. It is the only file that sends on a
-- prefix of our own.
--
-- WHAT THIS COSTS, STATED RATHER THAN ABSORBED
--
-- "No sync protocol between clients" was an invariant of this addon and it is
-- now a narrower one: there IS a protocol, it carries reserve data one way from
-- the master looter to the raid, and a raider's client is no longer inert while
-- they are in a raid group. What has NOT changed is the rule about somebody
-- else's wire -- we still only subscribe to RCLootCouncil's prefix and still
-- never send on it. Our traffic is on our own prefix, where the server's
-- per-prefix throttle allowance is ours to spend and cannot starve theirs.
--
-- WHY ACECOMM AND NOT SendAddonMessage
--
-- A full reserve set is several kilobytes. An addon message body is 255 bytes,
-- the server allows ten per prefix and regenerates one per second, and the API
-- documentation is explicit that sending too much at once can DISCONNECT the
-- client. The client that must not disconnect is the master looter's. AceComm
-- does the chunking and hands off to ChatThrottleLib, which is the thing the
-- documentation tells you to use instead of hand-rolling this. RCLootCouncil is
-- a required dependency and it loads AceComm with ChatThrottleLib inside it, so
-- we take it from LibStub exactly as CLAUDE.md already describes for the rest
-- of Ace3 -- nothing is embedded here.
--
-- WHY THE REPLY IS A BROADCAST
--
-- A boss dies, twenty dialogs appear, twenty people click yes inside two
-- seconds. Answering each asker individually is the whole set multiplied by the
-- raid size. Answering ONCE, to the raid, serves everybody who asked and
-- everybody about to -- and Protocol.ShouldBroadcast makes every request inside
-- the coalescing window free. Raiders who declined receive the bytes and drop
-- them on the floor without storing or drawing anything.
--
-- SECRET VALUES
--
-- CHAT_MSG_ADDON is NOT marked SecretInChatMessagingLockdown -- checked against
-- Blizzard's generated documentation for 12.1.0 -- so unlike CHAT_MSG_WHISPER,
-- neither the sender nor the body of an addon message ever arrives secret, and
-- this file needs no lockdown guard to read one. The guard it DOES need is on
-- the way out: C_ChatInfo.SendAddonMessage is SecretArguments = "NotAllowed"
-- and errors on a secret argument, and the master looter's name comes from
-- RCLootCouncil rather than from the message. So names are screened with
-- ns.IsSecret before they are folded or compared, which is the same rule as
-- everywhere else in this addon: screen at the point a value crosses in.

local _, ns = ...

local Protocol = ns.Protocol

local Sync = {}
ns.Sync = Sync

local AceComm = LibStub and LibStub("AceComm-3.0", true)

--------------------------------------------------------------------------------
-- Scope
--------------------------------------------------------------------------------

-- On in a raid group, off everywhere else. Not sticky: see ns.InRaidScope.
function Sync:SetActive()
	local want = ns.InRaidScope()

	if want and not self.active then
		self.active = true
		if AceComm then
			AceComm:Embed(self)
			-- Guarded because this is entered from AceComm's dispatch, which is
			-- entered from Blizzard's CHAT_MSG_ADDON handler. An unguarded throw
			-- here fires for EVERY message on this prefix and is attributed to
			-- whatever was on the stack, not to us.
			self:RegisterComm(Protocol.PREFIX, function(_, message, _, sender)
				ns.Guard("reserve sync (incoming message)", function()
					self:OnMessage(message, sender)
				end)
			end)
		end
		ns.RC:SubscribeSessionStart(function()
			ns.Guard("loot session start", function() self:OnSessionStart() end)
		end)
		-- Redrawing on each message rather than on a timer. A session carries a
		-- few dozen responses in total, each one arrives as an event, and the
		-- window is cheap to rebuild -- so this stays inside the no-polling
		-- rule while still being live.
		ns.RC:SubscribeResponses(function(sender, session, response, roll)
			if not ns.Responses then return end
			ns.Guard("response received", function()
				ns.Responses:Record(sender, session, response, roll)
				if ns.ResponseWindow then ns.ResponseWindow:Refresh() end
			end)
		end)
		ns.RC:SubscribeRolls(function(name, roll, sessions)
			if not ns.Responses then return end
			ns.Guard("roll received", function()
				ns.Responses:RecordRoll(name, roll, sessions)
				if ns.ResponseWindow then ns.ResponseWindow:Refresh() end
			end)
		end)

	elseif not want and self.active then
		self.active = false
		if AceComm and self.UnregisterComm then
			pcall(self.UnregisterComm, self, Protocol.PREFIX)
		end
		ns.RC:UnsubscribeSessionStart()
		ns.RC:UnsubscribeCommands()
		self.pending = nil
	end
end

--------------------------------------------------------------------------------
-- Sending
--------------------------------------------------------------------------------

-- Every outgoing message goes through here, so the refusal case is handled in
-- exactly one place.
--
-- SendAddonMessage can be refused outright with AddOnMessageLockdown while an
-- encounter or a Mythic+ key is in progress. AceComm does not surface that, so
-- this is best-effort by design -- but the ASKING side has a timeout, and a
-- refusal simply becomes "no answer", which is already one of the four things a
-- raider can be told. The one thing it must never become is silence.
local function Send(message, prio)
	if not AceComm then return false end
	if not message then return false end
	if not IsInRaid() then return false end
	local ok = pcall(function()
		Sync:SendCommMessage(Protocol.PREFIX, message, "RAID", nil, prio or "NORMAL")
	end)
	return ok
end

--------------------------------------------------------------------------------
-- Master looter side
--------------------------------------------------------------------------------

-- One small message per session. Protocol version, export timestamp, reserve
-- count -- about forty bytes, one send, no chunking.
--
-- This is what makes "ask once per list" possible and what stops the addon
-- nagging people in raids where it has nothing to offer: no announce means no
-- dialog, so a raid whose master looter does not run this addon never sees a
-- popup at all.
function Sync:Announce()
	if not ns.RC:IsMasterLooter() then return end

	local set = ns.ImportedSet()
	if not set then
		-- Nothing to announce. Deliberately silent rather than broadcasting a
		-- no-list: nobody asked yet, and an unprompted "I have nothing" to
		-- twenty-five people is noise. The no-list answer exists for the raider
		-- who DID ask -- see OnMessage.
		return
	end

	Send(Protocol.Announce(set.exportedAt, set.reserveCount), "BULK")
end

-- Answer a request, at most once per coalescing window.
function Sync:Broadcast()
	if not ns.RC:IsMasterLooter() then return end

	-- Coalesced FIRST, and it applies to the no-list answer too.
	--
	-- Getting this the other way round is subtle and bad: an officer who has not
	-- imported is exactly the officer twenty people are about to ask, so the
	-- reply nobody coalesced is the one sent twenty times. It is a small message,
	-- but it is small on the same throttle allowance the real payload needs, and
	-- the whole point of the window is that one answer serves everybody.
	local now = time()
	if not Protocol.ShouldBroadcast(now, self.lastBroadcastAt) then return end
	self.lastBroadcastAt = now

	local set = ns.ImportedSet()
	if not set or type(set.source) ~= "string" or set.source == "" then
		-- "I have this addon and no list" is a different fact from silence, and
		-- the raider who asked has to be able to tell them apart.
		Send(Protocol.NoList())
		return
	end

	Send(Protocol.Data(set.source), "BULK")
end

--------------------------------------------------------------------------------
-- Raider side
--------------------------------------------------------------------------------

-- Ask the master looter for tonight's list. Called on "yes" in the dialog, and
-- by /rc askml.
function Sync:Request()
	if not IsInRaid() then
		ns.Print(Protocol.OUTCOME.NOT_IN_RAID)
		return
	end

	if not Send(Protocol.Request()) then
		ns.Print(Protocol.OUTCOME.REFUSED)
		return
	end

	-- The timeout is the fourth outcome. Without it, a master looter who does
	-- not run this addon produces silence, and silence is the one answer this
	-- addon refuses to give -- the raider cannot tell "no list" from "no addon"
	-- from "still coming".
	self.awaiting = true
	C_Timer.After(Protocol.ANSWER_TIMEOUT, function()
		ns.Guard("reserve sync (timeout)", function()
			if not self.awaiting then return end
			self.awaiting = false
			ns.Print(Protocol.OUTCOME.NO_ANSWER)
		end)
	end)
end

-- "/rc askml". Asks, and opens the windows.
--
-- Both, because they are one intent. A raider typing this either has no list
-- and wants one, or closed a window and wants it back -- and opening what we
-- already have while the request is in flight means the common case answers
-- instantly instead of after a round trip.
function Sync:AskML()
	-- Entered from RCLootCouncil's chat command dispatch, so a throw here would
	-- surface as "/rc" being broken rather than as our window being broken.
	if ns.ReserveWindow then ns.Guard("reserve window", ns.ReserveWindow.Show, ns.ReserveWindow) end
	if ns.ResponseWindow then ns.Guard("responses window", ns.ResponseWindow.Show, ns.ResponseWindow) end

	-- The master looter asking themselves is not a request.
	--
	-- A RAID message comes back to its own sender, so without this the officer
	-- would send a request, receive it, broadcast an answer, ignore that answer
	-- (the DATA branch refuses to overwrite an officer's own import), and then
	-- be told after ten seconds that nobody replied -- while holding the list
	-- the whole time. Windows open, no traffic, honest sentence.
	if ns.RC:IsMasterLooter() then
		if ns.ImportedSet() then
			ns.Print("you are the master looter -- this is your own imported list.")
		else
			ns.Print("you are the master looter and have not imported a list. Use /rc reserves.")
		end
		return
	end

	self:Request()
end

-- The dialog.
--
-- NEVER ASSIGN THE GLOBAL. `StaticPopupDialogs = StaticPopupDialogs or {}` looks
-- like harmless defensive code and is a taint bug that took a raid to find:
-- writing to a global from addon code taints that global permanently, Blizzard's
-- Escape handler reads this table, and the next protected function that path
-- calls is refused and blamed on us. The symptom is nothing to do with popups --
--
--   ADDON_ACTION_FORBIDDEN: AddOn 'SGDDReserves' tried to call the
--   protected function 'SpellStopCasting()'
--     ... Blizzard_GameMenuEsc.lua:101 ... ToggleGameMenu
--
-- i.e. somebody pressed Escape. It fired in a DUNGEON, where the sync is
-- switched off entirely, because the assignment was at file scope and ran at
-- load on every client everywhere.
--
-- Writing a FIELD of the table is fine and is what every addon does. Only the
-- assignment to the global itself is poison. `.luacheckrc` now encodes exactly
-- that: the table is read-only, our one key is not.
--
-- Registered lazily, on first prompt, rather than at load. A client that is
-- never offered a list never touches Blizzard's table at all -- the same
-- "nothing until it is asked for" rule the frames already follow.
local dialogRegistered = false

local function EnsureDialog()
	if dialogRegistered then return true end
	if type(StaticPopupDialogs) ~= "table" then return false end

	StaticPopupDialogs["SGDDRESERVES_ACCEPT"] = {
		text = "%s",
		button1 = YES,
		button2 = NO,
		-- Guarded: these run from Blizzard's popup dispatch, and a throw here
		-- leaves a dialog on screen that cannot be dismissed.
		OnAccept = function()
			ns.Guard("reserve sync (accept)", function() ns.Sync:Request() end)
		end,
		-- Declining is remembered exactly as acceptance is: the question was
		-- about a LIST, and re-asking on the next boss because the answer was
		-- no is the behaviour that gets an addon turned off.
		OnCancel = function()
			ns.Guard("reserve sync (decline)", function()
				local at = ns.Sync.announcedAt
				if at then ns.DB().lastAcceptedAt = at end
			end)
		end,
		timeout = 0,
		whileDead = true,
		hideOnEscape = true,
		preferredIndex = 3,
	}

	dialogRegistered = true
	return true
end

function Sync:Prompt(exportedAt, reserveCount)
	if not Protocol.ShouldPrompt(exportedAt, ns.LastAcceptedAt()) then return end

	-- If Blizzard's popup table is not there, say it in chat rather than
	-- silently never offering. Same rule as everywhere else: the raider has to
	-- be able to tell "not offered" from "nothing to offer".
	if not EnsureDialog() then
		ns.Print("the master looter has a reserve list. Use /rc askml to import it.")
		return
	end

	self.announcedAt = exportedAt

	local when = ns.ParseISO(exportedAt)
	local shown = when and date("%a %H:%M", when) or exportedAt

	StaticPopup_Show("SGDDRESERVES_ACCEPT",
		("SGDD Reserves\n\nThe master looter has a reserve list from %s (%d reserve%s).\n\nImport it?")
			:format(shown, reserveCount, reserveCount == 1 and "" or "s"))
end

--------------------------------------------------------------------------------
-- Receiving
--------------------------------------------------------------------------------

-- Is this sender the person allowed to hand out a reserve list?
--
-- Both names are screened and folded here, at the boundary, before Protocol
-- compares them -- Protocol is pure and must never see a value that could throw
-- on comparison.
local function SenderIsMasterLooter(sender)
	local ml = ns.RC:MasterLooterName()
	if ns.IsSecret(sender, ml) then return false end
	return Protocol.IsAuthority(ns.FoldGameName(sender), ns.FoldGameName(ml), ml)
end

function Sync:OnMessage(message, sender)
	local msg, reason = Protocol.Parse(message)
	if not msg then
		-- A wire version mismatch is the one parse failure worth saying out
		-- loud, and only to somebody who asked: it is actionable, and the
		-- alternative is an empty window that looks like "nobody reserved
		-- anything". Everything else is a malformed message from someone
		-- else's addon and is not our business.
		if self.awaiting and reason and reason:find("version", 1, true) then
			self.awaiting = false
			ns.Warn(reason)
		end
		return
	end

	-- A request is the only message a raider sends, and only the master looter
	-- answers it.
	if msg.kind == Protocol.REQUEST then
		self:Broadcast()
		return
	end

	-- Everything below carries data or a claim about it, so the sender has to
	-- be the master looter. Anyone in the raid can register this prefix; without
	-- this check one person could make every raider's window read "you reserved
	-- nothing", which is confidently wrong and therefore worse than blank.
	if not SenderIsMasterLooter(sender) then return end

	if msg.kind == Protocol.ANNOUNCE then
		if ns.RC:IsMasterLooter() then return end
		if ns.Options().acceptReserveSync == false then return end
		self:Prompt(msg.exportedAt, msg.reserveCount)
		return
	end

	if msg.kind == Protocol.NOLIST then
		if self.awaiting then
			self.awaiting = false
			ns.Print(Protocol.OUTCOME.NO_LIST)
		end
		return
	end

	if msg.kind == Protocol.DATA then
		if ns.RC:IsMasterLooter() then return end
		self.awaiting = false

		-- Two layers, and both are needed. AcceptFromWire RETURNS a reason for
		-- anything it recognises as bad input; the pcall is for what it does
		-- not recognise -- a malformed payload reaching LibDeflate, a saved
		-- variables table in an unexpected shape. Either way the raider is
		-- told, because a window that stays empty with no explanation is the
		-- failure this addon exists to remove.
		local ok, accepted, msgText = pcall(ns.Import.AcceptFromWire, msg.export)
		if not ok then
			ns.Warn("the reserve list from the master looter could not be read (" ..
				tostring(accepted) .. "). Ask them to re-import and try /rc askml.")
			return
		end

		if accepted then
			ns.Print(msgText)
			ns.Guard("reserve window", function()
				if ns.ReserveWindow then ns.ReserveWindow:Refresh() end
			end)
		else
			ns.Warn("could not read the reserve list from the master looter -- " .. tostring(msgText))
		end
	end
end

--------------------------------------------------------------------------------
-- Session start
--------------------------------------------------------------------------------

function Sync:OnSessionStart()
	if ns.RC:IsMasterLooter() then
		self:Announce()
	end

	if ns.Responses then ns.Responses:Reset() end

	-- The windows open here, deferred out of combat. A loot session normally
	-- starts on a corpse, but "normally" is not "always" -- a session can open
	-- while adds are still up, and a frame arriving over somebody's action bars
	-- mid-pull is how an addon gets uninstalled.
	ns.OpenWindowsWhenSafe()
end

return Sync
