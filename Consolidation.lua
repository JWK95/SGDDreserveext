-- Consolidation.lua -- everyone's response and roll on the item that just
-- dropped, in the order a raider reads it.
--
-- Pure: no WoW API, no addon state. RC.lua owns the subscriptions that produce
-- these entries and DropWindow.lua owns the frame; this file owns the two rules
-- that are easy to get subtly wrong -- who is allowed to see whose answer, and
-- what order the rows come in.
--
-- WHY THIS HONOURS SOMEBODY ELSE'S SETTING
--
-- Candidate responses travel over RCLootCouncil's group channel to EVERY
-- client. RCVotingFrame simply does not subscribe to them unless the viewer is
-- on the council or the master looter has turned on RCLootCouncil's "observe"
-- setting, so on an ordinary raider's machine the bytes arrive and are dropped.
-- We subscribe through the same supported extension point RC.lua already uses,
-- which means we CAN read every candidate's response on any client, whatever
-- the master looter chose.
--
-- We do not. "observe" defaults to off, it is broadcast by the master looter in
-- the MLDB, and its description is "Allows non-council members to see the voting
-- frame" -- an officer who leaves it off has made a decision about what the raid
-- sees. Routing around that would make this addon's selling point "it shows you
-- what your officers turned off", which is how an addon gets banned from a guild
-- rather than adopted. So when observe is off a raider sees their OWN answer and
-- a count of what is hidden, and is told the setting exists.
--
-- Note the asymmetry, because it is deliberate: the RESERVE half of the window
-- is not gated this way. Reserves are our data, imported from the guild's own
-- website and handed out by the master looter on purpose. Responses are
-- RCLootCouncil's data and its rules apply to them.

local _, ns = ...

local Consolidation = {}
ns.Consolidation = Consolidation

-- Shown where a candidate has not answered yet. A blank cell would read as
-- "passed", which is a different fact and the wrong one.
Consolidation.WAITING = "Waiting"

-- Shown where somebody has a response but no roll. Not "0": a zero roll is a
-- real thing somebody can roll, and printing one where none exists is the
-- confidently-wrong output this addon exists to remove.
Consolidation.NO_ROLL = "-"

--------------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------------

-- entries: array of { name = , display = , response = , roll = , class = }
-- opts:    { observe = boolean, viewer = <the viewer's own name> }
--
-- Returns { rows = { ... }, hidden = n, observing = boolean }.
--
-- `hidden` is counted over everything that was filtered out, and it is stated
-- rather than implied. A window showing one row with no explanation reads as
-- "nobody else has answered", which is a lie; showing "4 others hidden" is the
-- truth and points at the reason.
function Consolidation.Build(entries, opts)
	opts = opts or {}
	local observe = opts.observe == true
	local viewer = opts.viewer

	local rows, hidden = {}, 0

	if type(entries) == "table" then
		for _, e in ipairs(entries) do
			-- The viewer always sees their own answer. It is theirs, they
			-- already know it, and it is the one row that makes the window
			-- useful when everything else is hidden.
			local mine = viewer ~= nil and e.name == viewer
			if observe or mine then
				rows[#rows + 1] = {
					name = e.name,
					display = e.display or e.name,
					response = (type(e.response) == "string" and e.response ~= "") and e.response or Consolidation.WAITING,
					roll = tonumber(e.roll),
					class = e.class,
					mine = mine,
				}
			else
				hidden = hidden + 1
			end
		end
	end

	-- Highest roll first, then name. Fully determined all the way down: two
	-- raiders comparing their windows must read the same order, and a list that
	-- reshuffles between redraws reads as data changing under them.
	--
	-- A missing roll sorts LAST rather than as zero. Somebody who has not
	-- rolled has not lost; they have not answered, and putting them below a
	-- genuine roll of 1 says so without inventing a number for them.
	table.sort(rows, function(a, b)
		if a.roll ~= b.roll then
			if a.roll == nil then return false end
			if b.roll == nil then return true end
			return a.roll > b.roll
		end
		return tostring(a.name) < tostring(b.name)
	end)

	return { rows = rows, hidden = hidden, observing = observe }
end

--------------------------------------------------------------------------------
-- The line that explains an empty table
--------------------------------------------------------------------------------

-- Returns nil when there is nothing to explain.
--
-- Says the number AND the reason. "Hidden" on its own invites a raider to
-- conclude the addon is broken; naming the setting turns a silent limitation
-- into a conversation the guild can actually have, and it is the master
-- looter's call either way.
function Consolidation.HiddenLine(result)
	if not result or result.observing then return nil end
	if not result.hidden or result.hidden <= 0 then return nil end

	return ("%d other %s hidden -- the master looter can show them with RCLootCouncil's \"observe\" setting.")
		:format(result.hidden, result.hidden == 1 and "response is" or "responses are")
end

return Consolidation
