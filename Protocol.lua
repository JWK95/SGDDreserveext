-- Protocol.lua -- what crosses the wire between a master looter and a raider.
--
-- Pure: no WoW API, no addon state, no LibStub. Sync.lua owns the addon
-- channel, the events and the dialog; this file owns the five rules that are
-- easy to get subtly wrong and impossible to notice in a raid -- what a message
-- means, which protocol versions may talk to each other, who is allowed to hand
-- out a reserve list, when a request is answered by an answer already given,
-- and when a raider gets asked a second time.
--
-- WHY THERE IS A PROTOCOL AT ALL, GIVEN THE RULE THAT SAID THERE WOULD NOT BE
--
-- This addon spent its whole life reading RCLootCouncil's wire and never
-- writing to one. That is still true of RCLootCouncil's prefix: we subscribe,
-- we never send. What is new is a prefix of OUR OWN, carrying reserve data one
-- way, from the master looter to the raid, so a raider can be reminded what
-- they reserved at the moment an item drops. The trade is written down in
-- CLAUDE.md rather than absorbed quietly, because "no sync protocol" was a
-- stated invariant and it is now a narrower one.
--
-- WHAT GOES OVER IT
--
-- The payload is the EXPORT STRING ITSELF -- the exact "SGDDR:<major>:<base64>"
-- the officer pasted -- and not a re-serialised copy of the parsed dataset.
-- That is the single most important decision in this file. It means a raider
-- runs the same Import parser, against the same envelope, with the same major
-- version check and the same duplicate-reserve handling as the officer did. A
-- second way to construct a dataset would be a second set of rules to keep in
-- step, and the failure mode of them drifting is a raider holding a subtly
-- different list from the officer -- which is this addon's signature invisible
-- bug wearing a new hat.
--
-- VERSIONS
--
-- Two different version numbers live in the same message and they are NOT the
-- same thing:
--
--   ns.VERSION_MAJOR  the EXPORT FORMAT, shared with the website. Import.lua
--                     owns it. Changing it is a two-repo deploy.
--   Protocol.VERSION  the WIRE, shared only between two copies of this addon.
--                     Changing it needs nothing but a release.
--
-- Two clients on different addon releases can disagree about the wire while
-- agreeing perfectly about the format, so the wire needs its own number. A
-- mismatch is a NAMED REFUSAL, never a silent miss: a raider whose addon is too
-- old must be told that, not left staring at an empty window that looks exactly
-- like "nobody reserved anything".

local _, ns = ...

local Protocol = {}
ns.Protocol = Protocol

Protocol.VERSION = 1

-- Max 16 characters, and it must not be one of RCLootCouncil's ("RCLC",
-- "RCLCv", "RCLCs"). Prefix namespaces are per-string and the server's throttle
-- allowance is per-prefix, so having our own keeps our traffic off theirs.
Protocol.PREFIX = "SGDDRsv"

-- A tab. Not a pipe: the export blob is base64 (A-Za-z0-9+/=) and an ISO
-- timestamp is digits, dashes, colons and "Z", so a tab cannot occur inside any
-- field and needs no escaping. Chat's bare-pipe rule does not apply on an addon
-- channel, but picking a separator that simply cannot collide is cheaper than
-- remembering which rules apply where.
local SEP = "\t"

Protocol.ANNOUNCE = "A"
Protocol.REQUEST  = "R"
Protocol.DATA     = "D"
Protocol.NOLIST   = "N"

-- How long one broadcast answers for. A boss dies, twenty dialogs appear, and
-- twenty people click yes within a couple of seconds of each other; every one
-- of those after the first is served by the broadcast already going out.
--
-- This is the number that keeps the master looter connected. A full reserve set
-- is several kilobytes, which is ten-odd addon messages after chunking; the
-- server allows ten per prefix and regenerates one per second, and sending too
-- much at once can disconnect the client outright. Answering each asker
-- individually is that cost multiplied by the raid size.
Protocol.COALESCE_WINDOW = 8

--------------------------------------------------------------------------------
-- Building
--------------------------------------------------------------------------------

function Protocol.Announce(exportedAt, reserveCount)
	if type(exportedAt) ~= "string" or exportedAt == "" then return nil end
	return table.concat({
		Protocol.ANNOUNCE,
		tostring(Protocol.VERSION),
		exportedAt,
		tostring(tonumber(reserveCount) or 0),
	}, SEP)
end

function Protocol.Request()
	return Protocol.REQUEST .. SEP .. tostring(Protocol.VERSION)
end

function Protocol.Data(exportString)
	if type(exportString) ~= "string" or exportString == "" then return nil end
	return table.concat({
		Protocol.DATA,
		tostring(Protocol.VERSION),
		exportString,
	}, SEP)
end

function Protocol.NoList()
	return Protocol.NOLIST .. SEP .. tostring(Protocol.VERSION)
end

--------------------------------------------------------------------------------
-- Parsing
--------------------------------------------------------------------------------

-- Which side is behind, said in the direction the reader can act on -- the same
-- courtesy Import.VersionMessage extends about the export format. A raider
-- whose addon is older is the one who can fix it; a raider whose addon is newer
-- needs to go and tell the officer, and being told "update the addon" when they
-- already did is how a real message gets ignored.
function Protocol.VersionMessage(theirs)
	local n = tonumber(theirs)
	if n and n > Protocol.VERSION then
		return ("the master looter's SGDD Reserves is newer than yours (wire version %s, yours is %d). Update the addon.")
			:format(tostring(theirs), Protocol.VERSION)
	end
	return ("the master looter's SGDD Reserves is older than yours (wire version %s, yours is %d). They need to update.")
		:format(tostring(theirs), Protocol.VERSION)
end

-- Returns a table, or nil plus a reason.
--
-- The reason is never dropped on the floor by the caller. A message we could
-- not read is a message somebody expected an answer to.
function Protocol.Parse(msg)
	if type(msg) ~= "string" or msg == "" then return nil, "empty message" end

	local fields, n, pos = {}, 0, 1
	while true do
		local hit = msg:find(SEP, pos, true)
		n = n + 1
		if not hit then
			fields[n] = msg:sub(pos)
			break
		end
		fields[n] = msg:sub(pos, hit - 1)
		pos = hit + 1
	end

	local kind = fields[1]
	if kind ~= Protocol.ANNOUNCE and kind ~= Protocol.REQUEST
		and kind ~= Protocol.DATA and kind ~= Protocol.NOLIST then
		return nil, "unrecognised message"
	end

	local version = tonumber(fields[2])
	if not version then return nil, "no wire version" end

	-- The whole point of the number. Refuse loudly, name the version, and say
	-- which side is behind -- never fall through and try to read the rest.
	if version ~= Protocol.VERSION then
		return nil, Protocol.VersionMessage(fields[2])
	end

	if kind == Protocol.ANNOUNCE then
		local exportedAt = fields[3]
		if type(exportedAt) ~= "string" or exportedAt == "" then
			return nil, "announce carries no timestamp"
		end
		return {
			kind = kind,
			version = version,
			exportedAt = exportedAt,
			reserveCount = tonumber(fields[4]) or 0,
		}
	end

	if kind == Protocol.DATA then
		local export = fields[3]
		if type(export) ~= "string" or export == "" then
			return nil, "payload is empty"
		end
		return { kind = kind, version = version, export = export }
	end

	return { kind = kind, version = version }
end

--------------------------------------------------------------------------------
-- The four outcomes, and why there are four
--------------------------------------------------------------------------------

-- From a raider's client, four different situations all look like silence:
--
--   1. the master looter has a list and it is on its way
--   2. the master looter has this addon but no list loaded
--   3. the master looter does not have this addon at all
--   4. the send was refused, because the client is under addon-comm lockdown
--
-- Only (2) is "the leader has not imported". Saying that in case (3) sends a
-- raider to nag an officer who cannot fix it, and saying it in case (4) is
-- simply false. This is the whisper responder's "never goes quiet" rule applied
-- to a second channel: distinct facts get distinct sentences, and silence is
-- never one of the answers.
Protocol.OUTCOME = {
	NO_LIST = "The master looter has no reserve list loaded -- ask them to import tonight's reserves.",
	NO_ANSWER = "No reply from the master looter. They may not have SGDD Reserves installed.",
	REFUSED = "Could not ask right now -- addon chat is restricted during encounters and Mythic+ keys. Try again after the pull.",
	NOT_IN_RAID = "You are not in a raid group, so there is no master looter to ask.",
}

-- How long to wait before concluding nobody is going to answer. Long enough to
-- cover a broadcast already in flight being chunked and throttled, short enough
-- that a raider is not left staring at a spinner while loot is being handed out.
Protocol.ANSWER_TIMEOUT = 10

--------------------------------------------------------------------------------
-- Who is allowed to hand out a list
--------------------------------------------------------------------------------

-- RCLootCouncil reports the master looter as a name that can read "Unknown"
-- while it is still resolving, and as nil before it has looked. Neither is
-- "no". This is the same rule Nag and Freshness follow, applied to a new
-- question: an unresolved master looter means we do not KNOW who is allowed to
-- send us a list, which is not the same as knowing this sender is not.
function Protocol.AuthorityState(masterLooter)
	if masterLooter == nil or masterLooter == "" then return "unresolved" end
	if masterLooter == "Unknown" then return "unresolved" end
	return "known"
end

-- Both names arrive already folded, because folding is a string operation and
-- the values behind these come in from the game. Sync.lua screens them with
-- ns.IsSecret and folds them before anything here sees them; this file stays
-- pure and comparable.
--
-- Anyone in the raid can register our prefix and send a message claiming to
-- carry tonight's reserves. Without this check, one person could make every
-- raider's window read "you reserved nothing" -- confidently wrong, which is
-- the exact failure this addon exists to eliminate. Rejecting while the master
-- looter is unresolved is safe precisely because a raider can ask again: the
-- pull path exists, so a rejected push costs a few seconds, not the feature.
function Protocol.IsAuthority(senderFolded, mlFolded, masterLooterRaw)
	if Protocol.AuthorityState(masterLooterRaw) ~= "known" then return false end
	if type(senderFolded) ~= "string" or senderFolded == "" then return false end
	if type(mlFolded) ~= "string" or mlFolded == "" then return false end
	return senderFolded == mlFolded
end

--------------------------------------------------------------------------------
-- Coalescing
--------------------------------------------------------------------------------

-- Answer a request only if the answer already given has gone stale.
--
-- The reply is a BROADCAST, not a whisper back to the asker, which is what
-- makes this work: one send serves everybody who asked and everybody who is
-- about to. Raiders who declined receive the bytes and discard them.
function Protocol.ShouldBroadcast(now, lastBroadcastAt, window)
	if type(now) ~= "number" then return false end
	window = tonumber(window) or Protocol.COALESCE_WINDOW
	if lastBroadcastAt == nil then return true end
	if type(lastBroadcastAt) ~= "number" then return true end
	return (now - lastBroadcastAt) >= window
end

--------------------------------------------------------------------------------
-- Asking the raider
--------------------------------------------------------------------------------

-- Once per LIST, not once per session. A raid night is eight or more loot
-- sessions and a dialog at every one of them is an addon people turn off by the
-- third boss. The export timestamp is the list's identity -- it is what the
-- website stamps and what the officer pasted -- so a raider who accepted that
-- timestamp is never asked about it again, and next week's import asks once.
function Protocol.ShouldPrompt(announcedAt, lastAcceptedAt)
	if type(announcedAt) ~= "string" or announcedAt == "" then return false end
	return announcedAt ~= lastAcceptedAt
end

return Protocol
