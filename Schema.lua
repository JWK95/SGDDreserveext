-- Schema.lua -- the shape of the imported dataset.
--
-- Pure, and separate from Core.lua so the tests can build a real set without
-- loading a file that calls CreateFrame at load time. A test double of this
-- shape would drift from the real one silently, and the drift would only show
-- up as an import that stores a field nothing reads.

local _, ns = ...

-- There is exactly ONE dataset. Format version 2 removed the personal export
-- and the awarded records with it: only the master looter imports, and the
-- addon is inert on everybody else's client.
--
-- Each import replaces the set wholesale and is never merged with what it
-- replaces: the website wipes reserves weekly, and a merge is how a pick that
-- was deliberately cleared is still on screen three weeks later.
function ns.EmptySet()
	return {
		exportedAt = nil,   -- ISO-8601 UTC string, the WEBSITE's clock
		importedAt = nil,   -- epoch seconds, this client's clock
		guild = nil,
		minor = 0,

		chars = {},         -- [foldedKey] = { key, name, realmSlug, class }

		-- Indexed by item id, not a flat list. The voting column's cell update
		-- runs once per candidate per redraw of a live loot session, so the
		-- lookup it performs has to be O(1). A list scanned per cell is the one
		-- place this addon could become something you feel.
		reserves = {},      -- [itemId] = { [foldedKey] = tier }

		reservedAt = {},    -- ["foldedKey:itemId"] = ISO-8601, for the tooltip
		itemNames = {},     -- [itemId] = English name, fallback only

		reserveCount = 0,
	}
end

return ns.EmptySet
