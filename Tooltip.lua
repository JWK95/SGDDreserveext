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

	-- No work in combat, which is the addon's standing rule, and it keeps
	-- AddLine off a tooltip nobody can read mid-pull.
	--
	-- BUT DO NOT MISTAKE THIS FOR A TAINT FIX. An earlier version of this
	-- comment claimed it reduced taint exposure. It does not: taint attaches
	-- when our code RUNS on a path, and returning early does not undo having
	-- been called. Once this callback is registered, every item tooltip in the
	-- game runs it.
	--
	-- That is why the real lever is registration, not this branch, and why the
	-- setting now defaults off. See Tooltip:SetActive and
	-- docs/in-game-gotchas.md #9.
	if InCombatLockdown() then return end

	if not ns.Options().showTooltipReserves then return end

	-- AnySet, not Data: an officer's own import if there is one, otherwise the
	-- list the master looter handed out. A raider who accepted tonight's
	-- reserves gets the same "Reserved by" line an officer does, on the same
	-- data, which is the point -- they are the people who most often want to
	-- know whether hovering a drop is worth arguing about.
	local set = ns.AnySet()
	if not set or set.reserveCount == 0 then return end

	-- Secret values, and why the check is here rather than deeper in.
	--
	-- This callback runs inside whatever execution asked for the tooltip, which
	-- is very often not us: a unit frame addon, a bag addon, anything that calls
	-- GameTooltip:SetItemByID. So the payload can describe an item belonging to
	-- somebody whose identity the game is currently keeping secret, and the
	-- error is attributed to whichever addon tainted that execution path -- not
	-- to us, which is what made it so hard to place.
	--
	-- `data` first, because the very next line indexes it, and indexed access on
	-- a secret is an immediate error. `data.id` next, because Reservers.For uses
	-- it as a table key and a secret cannot be one.
	if ns.IsSecret(data) then return end

	-- The item id arrives directly on the tooltip data. Not GetItem(), which
	-- RCLootCouncil-era code used and which Blizzard's own source marks as a
	-- temporary replacement pending removal.
	local itemId = data and data.id
	if ns.IsSecret(itemId) then return end
	if not itemId then return end

	local result = Reservers.For(set, itemId)
	if not result then return end

	local line = Reservers.Line(result, Colourize)
	if not line then return end

	-- The boundary check, and the honest status of it: UNPROVEN. The two guards
	-- above are mutation-tested -- delete either and the harness throws, the id
	-- one with the exact message the raid reported. Delete this one and nothing
	-- fails, because every ingredient of `line` is data we imported ourselves,
	-- so today it cannot be secret.
	--
	-- It stays anyway, and this is the reasoning rather than a habit: AddLine is
	-- where a secret string would finally have to become real bytes, and format
	-- and concat propagate secrecy in silence, so a future secret anywhere
	-- upstream surfaces HERE and nowhere earlier. The watch list says the set of
	-- secret values grows every patch. One predicate call, on a line we are
	-- about to draw anyway, against an error on every tooltip redraw -- which is
	-- how this arrived: 537 of them in one night.
	if ns.IsSecret(line) then return end

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
-- The scope widened with the raider-facing half, and the cost widened with it.
--
-- It used to register only on an officer's client, because only an officer had
-- data. A raider who accepts a reserve list now has data too, so the line is
-- available to them -- which was asked for deliberately, with this trade
-- understood: the first time a raider accepts a list, this callback is added to
-- their client and held until they log out, even if they later clear the data
-- or turn the setting off. Turning the setting off stops the LINE, because the
-- option is checked inside the callback; it cannot stop the callback.
--
-- What has not changed: a raider who never accepts a list registers nothing.
--
-- THE OPTION IS NOW CHECKED HERE TOO, and that is a correction rather than a
-- belt-and-braces addition.
--
-- Before, the callback was registered whenever this client had data, whatever
-- the setting said, and the setting was only consulted inside the callback. So
-- somebody who turned the feature off still had this addon executing inside
-- every item tooltip in the game -- including bag buttons and action buttons --
-- for the rest of the session, with no way to stop it and nothing gained. The
-- off switch stopped the LINE and left the exposure.
--
-- That matters because this callback is where the addon runs inside somebody
-- else's execution. Off at login now means never registered, which is the only
-- honest meaning of off for a callback that cannot be removed. It also makes
-- "turn it off and reload" a real remedy somebody can apply on a raid night,
-- rather than a half-measure -- see docs/in-game-gotchas.md #8 and #9.
--
-- Turning it ON mid-session still works: Options.lua calls ns.UpdateScope()
-- when the setting changes, which lands here. Turning it OFF mid-session still
-- stops the line via the check inside the callback, because unregistering
-- remains unavailable.
function Tooltip:SetActive()
	if self.registered then return end
	if not ns.Options().showTooltipReserves then return end
	if not (ns.IsOfficerClient() or ns.ReceivedSet()) then return end

	local processor = TooltipDataProcessor
	if not processor or type(processor.AddTooltipPostCall) ~= "function" then return end

	local itemType = Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item
	if itemType == nil then return end

	local ok = pcall(processor.AddTooltipPostCall, itemType, OnItem)
	if ok then self.registered = true end
end
