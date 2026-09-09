-- Freshness.lua -- is the imported list still good for tonight?
--
-- Pure: takes epoch seconds and returns a verdict, so spec/freshness_spec.lua
-- can drive it across a reset boundary without waiting for Wednesday. Core
-- does the parsing and the clock reading; this file only decides.
--
-- The interesting rule is that AGE IS THE WRONG MEASURE. The website wipes
-- reserves weekly, so a list exported on Monday for a Wednesday raid is two
-- days old and perfectly correct, while a list exported an hour before the
-- weekly reset is minutes old and completely wrong. The reset boundary does
-- the real work here; the day count is only a backstop for the case where the
-- boundary cannot be read.

local _, ns = ...

local Freshness = {}
ns.Freshness = Freshness

local DAY = 86400
local WEEK = 7 * DAY

-- The backstop, in days. Deliberately longer than a normal export-to-raid gap
-- so it never fires on a correct list, and short enough to catch a list that
-- survived a reset the boundary check somehow missed.
Freshness.MAX_AGE_DAYS = 3

Freshness.NONE = "none"     -- nothing imported at all
Freshness.RESET = "reset"   -- exported before the current lockout began
Freshness.AGE = "age"       -- older than MAX_AGE_DAYS
Freshness.OK = "ok"

-- exportedEpoch      when the WEBSITE produced the string, epoch seconds
-- now                epoch seconds
-- secondsUntilReset  from C_DateAndTime.GetSecondsUntilWeeklyReset(), or nil
--
-- nil secondsUntilReset is a third answer, not "the reset is far away": the API
-- has not answered yet. Skipping straight to OK there would silence the warning
-- at precisely the moment the client knows least, so the backstop still runs.
function Freshness.Check(exportedEpoch, now, secondsUntilReset)
	if type(exportedEpoch) ~= "number" then return Freshness.NONE end
	if type(now) ~= "number" then return Freshness.NONE end

	if type(secondsUntilReset) == "number" and secondsUntilReset > 0 then
		local lastReset = now + secondsUntilReset - WEEK
		if exportedEpoch < lastReset then
			return Freshness.RESET
		end
	end

	if now - exportedEpoch > Freshness.MAX_AGE_DAYS * DAY then
		return Freshness.AGE
	end

	return Freshness.OK
end

function Freshness.IsStale(status)
	return status ~= Freshness.OK
end

return Freshness
