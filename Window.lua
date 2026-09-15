-- Window.lua -- the chrome both drop windows share, and the rule about combat.
--
-- Exists so the frame-building logic is written once. OfficerFrame.lua already
-- had a version of it; a second and third copy would drift, and the way that
-- drift shows up is one window losing its close button after an RCLootCouncil
-- update while the others keep theirs.
--
-- Everything here is built ON FIRST USE. A raider who never gets a reserve list
-- never builds a frame.

local _, ns = ...

local Window = {}
ns.Window = Window

--------------------------------------------------------------------------------
-- Position
--------------------------------------------------------------------------------

-- Remembered per window, because two frames that both open on every boss and
-- both land in the middle of the screen is worse than one that does.
local function SavePosition(f, key)
	local point, _, relPoint, x, y = f:GetPoint()
	if not point then return end
	local db = ns.DB()
	if not db then return end
	db.windows = db.windows or {}
	db.windows[key] = { point = point, relPoint = relPoint, x = x, y = y }
end

local function RestorePosition(f, key)
	local db = ns.DB()
	local p = db and db.windows and db.windows[key]
	if not p then
		f:SetPoint("CENTER")
		return
	end
	f:ClearAllPoints()
	-- pcall: a saved point from an older layout can be invalid, and a window
	-- that throws on show is a window nobody can get back.
	local ok = pcall(f.SetPoint, f, p.point, UIParent, p.relPoint, p.x, p.y)
	if not ok then
		f:ClearAllPoints()
		f:SetPoint("CENTER")
	end
end

--------------------------------------------------------------------------------
-- Building
--------------------------------------------------------------------------------

-- Returns frame, content.
--
-- Built from RCLootCouncil's own frame widget when it is available, so these
-- read as part of RCLootCouncil rather than as a second addon with its own
-- look. Falls back to a plain frame -- a cosmetic dependency must not be able
-- to take the window away.
function Window.New(globalName, key, title, width, height)
	local f

	local rc = ns.RC:Addon()
	if rc and rc.UI and type(rc.UI.NewNamed) == "function" then
		local ok, made = pcall(rc.UI.NewNamed, rc.UI, "RCFrame", UIParent,
			globalName, title, width, height)
		if ok and made then f = made end
	end

	if not f then
		f = CreateFrame("Frame", globalName, UIParent, "BasicFrameTemplateWithInset")
		f:SetSize(width, height)
	end

	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		SavePosition(self, key)
	end)

	RestorePosition(f, key)

	-- RCLootCouncil's RCFrame ships no close button, and that is the frame these
	-- windows almost always use. Escape closes them -- they are registered in
	-- UISpecialFrames below -- but nothing on screen says so, and a window with
	-- no visible way out reads as stuck. The fallback template brings its own,
	-- so only add one when there is not one already.
	if not (f.CloseButton or f.closeButton) then
		local anchor = f.title or f.Title or f
		local close = CreateFrame("Button", nil, anchor, "UIPanelCloseButtonNoScripts")
		close:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", -2, -2)
		-- Our own OnClick rather than the stock script: UIPanelCloseButton_OnClick
		-- routes through HideUIPanel, which in 12.x opens with a protected-function
		-- check. A plain custom frame has no reason to depend on that gate.
		close:SetScript("OnClick", function() f:Hide() end)
		f.closeButton = close
	end

	tinsert(UISpecialFrames, globalName)

	f:Hide()
	return f, f.content or f
end

--------------------------------------------------------------------------------
-- Combat
--------------------------------------------------------------------------------

-- NO UI WORK IN COMBAT. Not "not much" -- none.
--
-- This addon's weight rule has always said no work in combat, and the sync
-- feature broke it before anyone noticed: responses and rolls arrive as comm
-- messages, they arrive *during the pull*, and every one of them was redrawing
-- a window. Twenty candidates answering meant twenty redraws inside
-- RCLootCouncil's comm dispatch while a boss was up.
--
-- That is wrong twice over. It is work in combat, which the addon promises not
-- to do. And drawing from tainted code during an encounter -- when the values
-- the game hands its own UI are secret -- is a taint risk this addon has no
-- business taking for a window nobody can read mid-pull anyway.
--
-- So every UI update goes through here. KEYED, so a hundred messages during one
-- pull collapse into one redraw when combat drops, rather than a hundred queued
-- closures. The event is registered only while something is waiting and
-- unregistered in the handler -- it is never permanently held.
local deferred = {}
local waiter

local function RunDeferred()
	-- Swapped out before running: a callback that queues more work must land in
	-- the next batch, not be dropped or cause this loop to mutate underfoot.
	local batch = deferred
	deferred = {}
	for key, fn in pairs(batch) do
		ns.Guard(key, fn)
	end
end

function ns.WhenOutOfCombat(key, fn)
	if not InCombatLockdown() then
		ns.Guard(key, fn)
		return
	end

	deferred[key] = fn

	if not waiter then waiter = CreateFrame("Frame") end
	waiter:RegisterEvent("PLAYER_REGEN_ENABLED")
	waiter:SetScript("OnEvent", function(self)
		-- Unregister FIRST. If a deferred call throws, this must still be torn
		-- down -- otherwise the addon holds an event it never releases and
		-- retries the same failure on every combat drop for the rest of the
		-- night.
		self:UnregisterEvent("PLAYER_REGEN_ENABLED")
		self:SetScript("OnEvent", nil)
		RunDeferred()
	end)
end

-- Opening the windows, but never over somebody's action bars mid-pull.
--
-- A loot session normally starts on a corpse, so this normally happens
-- immediately. "Normally" is not "always": a session can open while adds are
-- still up, and the exceptional case is the one that annoys people enough to
-- uninstall.
function ns.OpenWindowsWhenSafe()
	ns.WhenOutOfCombat("open loot windows", function()
		local opts = ns.Options()
		-- Separately guarded so one window failing to build cannot take the
		-- other with it. These are the least-tested paths in the addon and they
		-- run at the busiest moment of a raid night.
		if opts.autoOpenReserves ~= false and ns.ReserveWindow then
			ns.Guard("reserve window", ns.ReserveWindow.Show, ns.ReserveWindow)
		end
		if opts.autoOpenResponses ~= false and ns.ResponseWindow then
			ns.Guard("responses window", ns.ResponseWindow.Show, ns.ResponseWindow)
		end
	end)
end

return Window
