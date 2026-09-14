-- Guard.lua -- what happens when our code throws inside somebody else's.
--
-- Pure: no WoW API, no addon state. It calls ns.Warn when something fails, but
-- only at the moment it fails, so spec/guard_spec.lua can supply its own and
-- read what came out.
--
-- WHAT IT IS FOR, in order of how much each has already cost this project.
--
-- ONE: an error thrown inside somebody else's dispatch is attributed to THEM.
-- A throw inside an RCLootCouncil comm handler reads as an RCLootCouncil bug and
-- can take out the other subscribers to that message. The item tooltip taught
-- this the expensive way -- docs/in-game-gotchas.md #6, where our error was
-- blamed on whichever addon happened to be running, and there was no stack to
-- read because debugstack is itself a secret value.
--
-- TWO: once per site, not once per occurrence. A comm handler that throws
-- throws for EVERY message, and "537 errors in a night" is a real number from
-- this addon's history. One report names the problem; five hundred bury it.
--
-- THREE: it says our name, so the next person to see it knows which addon to
-- file it against.
--
-- It deliberately does NOT make failures silent -- silence is the outcome this
-- addon refuses everywhere else, and introducing it in the error handler would
-- be perverse. The caller gets false and decides what the user sees.

local _, ns = ...

local Guard = {}
ns.GuardModule = Guard

-- Exposed so a spec can start from a known state. Nothing in the addon calls it.
Guard.reported = {}

function Guard.Reset()
	Guard.reported = {}
end

function ns.Guard(site, fn, ...)
	local ok, err = pcall(fn, ...)
	if ok then return true end

	if not Guard.reported[site] then
		Guard.reported[site] = true

		-- THE FORMAT AND THE TOSTRING ARE INSIDE THE PCALL, and that placement
		-- is the whole rule.
		--
		-- Written the obvious way -- pcall(ns.Warn, ("..."):format(tostring(err)))
		-- -- the message is built BEFORE pcall is entered, so an error object
		-- that cannot be turned into bytes throws straight out of the error
		-- handler. That is the guard defeating itself at precisely the moment
		-- it is needed, and it is not hypothetical: concatenation propagates
		-- secrecy silently, so any secret value reaching an error message
		-- produces exactly that object. Caught by writing the test with an
		-- error whose __tostring throws, which is the only way this shows up.
		local okReport = pcall(function()
			ns.Warn(("error in %s -- that part stopped, the rest of the addon is still running. (%s)")
				:format(site, tostring(err)))
		end)

		-- Lost the detail, never the fact. A report naming the site with no
		-- explanation still tells somebody where to look; no report at all
		-- tells them the addon is fine.
		if not okReport then
			pcall(ns.Warn, "error in " .. site ..
				" -- that part stopped. Details unreadable (the game is hiding the value).")
		end
	end

	return false
end

return Guard
