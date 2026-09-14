-- Responses.lua -- what candidates have answered, for the session in progress.
--
-- Consolidation.lua owns the rules about who may see this and in what order;
-- this file is only the box it accumulates in. Kept separate because it is
-- state with a lifetime -- it fills up during a session and is emptied when the
-- next one starts -- and mixing that into a pure module is how a pure module
-- stops being testable.
--
-- IN MEMORY ONLY, deliberately. Nothing here is written to saved variables.
-- These are other people's answers about one item on one night; they are
-- RCLootCouncil's data, they are already stale by the next pull, and there is
-- no question a raider asks tomorrow that they answer. A /reload during a
-- session loses them, which costs nothing: the next session refills the box.

local _, ns = ...

local Responses = {}
ns.Responses = Responses

Responses.bySession = {}

--------------------------------------------------------------------------------
-- Lifetime
--------------------------------------------------------------------------------

-- Emptied on every session start. A response from the last boss shown against
-- this boss's item is confidently wrong, which is the failure mode this addon
-- exists to remove, and "it was right ten minutes ago" is no defence.
function Responses:Reset()
	self.bySession = {}
end

--------------------------------------------------------------------------------
-- Recording
--------------------------------------------------------------------------------

local function bucket(self, session)
	session = tonumber(session)
	if not session then return nil end
	local b = self.bySession[session]
	if not b then
		b = {}
		self.bySession[session] = b
	end
	return b
end

-- Names arriving from RCLootCouncil's comms are screened before they are used
-- as a table key or folded. CHAT_MSG_ADDON payloads are not secret -- checked
-- against Blizzard's generated docs -- but this name has passed through another
-- addon on its way here, and screening at the boundary is cheaper than proving
-- every hop.
local function entryFor(b, name)
	if ns.IsSecret(name) then return nil end
	if type(name) ~= "string" or name == "" then return nil end

	local folded = ns.FoldGameName(name) or name
	local e = b[folded]
	if not e then
		e = { name = folded, display = name }
		b[folded] = e
	end
	return e
end

function Responses:Record(sender, session, response, roll)
	local b = bucket(self, session)
	if not b then return end

	local e = entryFor(b, sender)
	if not e then return end

	if type(response) == "string" and response ~= "" then e.response = response end
	-- Only overwrite a roll with a real one. A response message carries a roll
	-- field that is frequently absent, and letting it blank out a roll that
	-- already arrived on its own message loses information for no reason.
	if tonumber(roll) then e.roll = tonumber(roll) end
end

-- A candidate-driven roll. Carries the roller's name, so attribution is
-- certain -- see RC:SubscribeRolls for why the master looter's random rolls are
-- not read at all.
--
-- `sessions` is a list of session numbers the roll applies to, because one roll
-- can cover several items.
function Responses:RecordRoll(name, roll, sessions)
	roll = tonumber(roll)
	if not roll then return end

	local list = sessions
	if type(list) ~= "table" then list = { sessions } end

	for _, session in ipairs(list) do
		local b = bucket(self, session)
		if b then
			local e = entryFor(b, name)
			if e then e.roll = roll end
		end
	end
end

--------------------------------------------------------------------------------
-- Reading
--------------------------------------------------------------------------------

-- Entries for one session, in the shape Consolidation.Build expects.
--
-- Class comes from the reserve list rather than from the response payload: the
-- payload carries a spec id, turning that into a class is another API call per
-- candidate per redraw, and this client usually already knows the answer
-- because the website exported it.
function Responses:For(session)
	local b = self.bySession[tonumber(session) or -1]
	if not b then return {} end

	local set = ns.AnySet()
	local chars = set and set.chars

	local out = {}
	for folded, e in pairs(b) do
		local char = chars and chars[folded]
		out[#out + 1] = {
			name = folded,
			display = (char and char.name) or e.display or folded,
			response = e.response,
			roll = e.roll,
			class = char and char.class or nil,
		}
	end
	return out
end

return Responses
