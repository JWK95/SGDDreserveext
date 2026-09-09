-- Tooltip.lua -- the "Reserved by:" line on an item's tooltip.
--
-- Who reserved what, and how that list reads, lives in Reservers.lua, which is
-- pure and tested. This file owns the parts that need the game: the callback,
-- which tooltips get decorated, and the class colours.
--
-- This is the first thing the addon draws OUTSIDE RCLootCouncil's own frames.
-- It still changes nothing about what RCLootCouncil does -- it adds a line to
-- an item tooltip and nothing else -- but it is a real widening of where the
-- addon appears, and it is deliberate: the moment an officer wants to know who
-- is on an item is usually while looking at the item, not while looking at the
-- voting frame.

local _, ns = ...

local Reservers = ns.Reservers

local Tooltip = { registered = false }
ns.Tooltip = Tooltip

--------------------------------------------------------------------------------
-- Colour
--------------------------------------------------------------------------------

-- Reservers.lua is pure and cannot read a WoW global, so the colour comes from
-- here and is handed in. There is still only one line-building path.
--
-- A tooltip is not chat: escape sequences are fine here, and none of the "no
-- bare pipe" care the whisper reply needs applies.
local function Colourize(name, class)
	local colours = RAID_CLASS_COLORS
	local c = class and colours and colours[class]
	if not c or not c.colorStr then return name end
	return ("|c%s%s|r"):format(c.colorStr, name)
end

--------------------------------------------------------------------------------
-- The callback
--------------------------------------------------------------------------------

-- Runs on every item tooltip the client builds, which is far more often than
-- "every hover": a tooltip is rebuilt on TOOLTIP_DATA_UPDATE too, and some
-- frames re-set theirs repeatedly. So the cheap rejections come first, and the
-- only real work -- one table index in Reservers.For -- happens for an item
-- somebody actually reserved.
local function OnItem(tooltip, data)
	-- GameTooltip covers bags, the loot window, the merchant and the character
	-- sheet, which all render into it. ItemRefTooltip is the one from clicking
	-- an item link in chat, and is a separate frame.
	--
	-- ShoppingTooltip1/2 are deliberately NOT included. Those are the
	-- comparison tooltips showing the gear you are already wearing, and a
	-- "Reserved by" line there would be describing the wrong item entirely.
	if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then return end

	if not ns.Options().showTooltipReserves then return end

	local set = ns.Data()
	if not set then return end

	-- The item id arrives directly on the tooltip data. Not GetItem(), which
	-- RCLootCouncil-era code used and which Blizzard's own source marks as a
	-- temporary replacement pending removal.
	local itemId = data and data.id
	if not itemId then return end

	local result = Reservers.For(set, itemId)
	if not result then return end

	local line = Reservers.Line(result, Colourize)
	if not line then return end

	tooltip:AddLine(" ")
	-- Wrapped: fifteen names is wider than any tooltip, and the alternative to
	-- wrapping is a tooltip stretched off the edge of the screen.
	tooltip:AddLine(line, 1, 0.82, 0, true)
end

--------------------------------------------------------------------------------
-- Registration
--------------------------------------------------------------------------------

-- Registered on an officer's client only, through ns.UpdateScope(), so a raider
-- who installs the addon never adds a callback at all.
--
-- There is NO WAY TO UNREGISTER. AddTooltipPostCall has no removal, so once an
-- officer imports, this callback is held for the rest of the session. That is a
-- real exception to the addon's "two registered events at rest" rule and it is
-- written down in CLAUDE.md rather than left to be discovered.
--
-- It is also why the option is checked INSIDE the callback rather than by
-- tearing the callback down: turning the setting off has to stop the line
-- appearing, and unregistering is not available to do it.
function Tooltip:SetActive()
	if self.registered then return end
	if not ns.IsOfficerClient() then return end

	local processor = TooltipDataProcessor
	if not processor or type(processor.AddTooltipPostCall) ~= "function" then return end

	local itemType = Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item
	if itemType == nil then return end

	local ok = pcall(processor.AddTooltipPostCall, itemType, OnItem)
	if ok then self.registered = true end
end
