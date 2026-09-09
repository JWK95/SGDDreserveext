-- Import.lua -- decode and store a pasted export string.
--
-- Wire format, outermost first (the full contract is docs/export-format.md,
-- which is mirrored in the website's repo):
--
--   SGDDR:<major>:<standard base64 of raw-deflated UTF-8 text>
--
-- Standard base64, RFC 4648, not LibDeflate's printable alphabet. That choice
-- is deliberate and belongs to the website: it means the site encodes with one
-- built-in Node call and has no hand-written alphabet to get subtly wrong, at
-- the cost of the twenty lines of decoder below. A wrong alphabet decodes to
-- garbage that looks like a working string, so the risk was moved to the side
-- that can be unit-tested here.
--
-- Raw DEFLATE, no zlib or gzip header -- LibDeflate:DecompressDeflate expects
-- exactly what Node's zlib.deflateRawSync produces. There is no checksum field
-- because there does not need to be one: a truncated paste fails the deflate
-- decode loudly, which is the behaviour we want.

local _, ns = ...

local Names = ns.Names
local LibDeflate = LibStub and LibStub:GetLibrary("LibDeflate", true)

local Import = {}
ns.Import = Import

--------------------------------------------------------------------------------
-- base64
--------------------------------------------------------------------------------

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_BYTE = {}
for i = 1, #B64 do
	B64_BYTE[B64:byte(i)] = i - 1
end

local PAD = 61 -- '='

local function DecodeBase64(str)
	str = str:gsub("[%s]", "")
	if str == "" then return nil, "empty" end
	if #str % 4 ~= 0 then return nil, "the string is truncated" end
	if str:find("[^A-Za-z0-9+/=]") then return nil, "the string contains characters that are not base64" end

	local out, n = {}, 0
	local floor = math.floor

	for i = 1, #str, 4 do
		local c1, c2, c3, c4 = str:byte(i, i + 3)
		local a, b = B64_BYTE[c1], B64_BYTE[c2]
		if not a or not b then return nil, "the string is malformed" end

		local c, d = B64_BYTE[c3], B64_BYTE[c4]
		local trip = a * 262144 + b * 4096 + (c or 0) * 64 + (d or 0)

		n = n + 1
		if c3 == PAD then
			out[n] = string.char(floor(trip / 65536) % 256)
		elseif c4 == PAD then
			out[n] = string.char(floor(trip / 65536) % 256, floor(trip / 256) % 256)
		else
			out[n] = string.char(floor(trip / 65536) % 256, floor(trip / 256) % 256, trip % 256)
		end
	end

	return table.concat(out)
end

Import.DecodeBase64 = DecodeBase64

--------------------------------------------------------------------------------
-- Payload parsing
--------------------------------------------------------------------------------

-- Splits on "|" without a pattern-based split, so a field containing a pattern
-- magic character cannot misbehave. The website refuses to export a field
-- containing "|" or a newline, which is what makes this safe rather than merely
-- tolerable.
local function SplitFields(line)
	local fields, n, pos = {}, 0, 1
	while true do
		local hit = line:find("|", pos, true)
		n = n + 1
		if not hit then
			fields[n] = line:sub(pos)
			return fields, n
		end
		fields[n] = line:sub(pos, hit - 1)
		pos = hit + 1
	end
end

-- Which side is behind, said in the direction the officer can act on.
--
-- The addon ships before the website does, so a version BELOW ours is the
-- expected failure on a cutover night and the officer's fix is on the site, not
-- here. Telling somebody who updated an hour ago to update again is how a real
-- message gets ignored.
local function VersionMessage(theirs)
	local n = tonumber(theirs)
	if n and n < ns.VERSION_MAJOR then
		return ("that export is format version %s; this addon reads version %d. The website is still producing the old format -- it needs updating.")
			:format(tostring(theirs), ns.VERSION_MAJOR)
	end
	return ("that export is format version %s; this addon reads version %d. Update the addon.")
		:format(tostring(theirs), ns.VERSION_MAJOR)
end

Import.VersionMessage = VersionMessage

-- Returns a populated set, or nil plus a reason.
--
-- Unknown record types and extra trailing fields are ignored rather than
-- refused: that is the whole of the minor-version contract, and it is what lets
-- the website add a field without every raider's addon breaking on the same
-- night. A change that is NOT backwards compatible bumps the major version and
-- is refused above, before this function ever runs.
local function ParsePayload(text)
	local set = ns.EmptySet()
	local sawVersion

	for line in text:gmatch("([^\n]+)") do
		local f = SplitFields(line)
		local rec = f[1]

		if rec == "V" then
			local major = tonumber(f[2])
			set.minor = tonumber(f[3]) or 0
			if major ~= ns.VERSION_MAJOR then
				return nil, VersionMessage(f[2])
			end
			sawVersion = true

		elseif rec == "G" then
			set.guild = f[2]

		elseif rec == "T" then
			set.exportedAt = f[2]

		elseif rec == "C" then
			local folded = Names.Fold(f[2])
			if folded then
				set.chars[folded] = {
					key = f[2],
					name = f[3],
					realmSlug = f[4],
					class = f[5] ~= "" and f[5] or nil,
				}
				-- The slug form folds to the same string as the in-game form,
				-- so this is a no-op when both are well formed. It is here for
				-- the case where they do not agree, which is the failure this
				-- format carries two forms to survive.
				local alt = Names.Fold(Names.Key(f[3], f[4]))
				if alt and not set.chars[alt] then
					set.chars[alt] = set.chars[folded]
				end
			end

		elseif rec == "S" then
			local folded = Names.Fold(f[2])
			local itemId = tonumber(f[3])
			if folded and itemId then
				local holders = set.reserves[itemId]
				if not holders then
					holders = {}
					set.reserves[itemId] = holders
				end
				if not holders[folded] then
					set.reserveCount = set.reserveCount + 1
				end
				holders[folded] = f[4] ~= "" and f[4] or "?"
				set.itemNames[itemId] = set.itemNames[itemId] or f[6]
				set.reservedAt[folded .. ":" .. itemId] = f[5]
			end
		end
	end

	if not sawVersion then
		return nil, "this does not look like an SGDD Reserves export (no version record)"
	end
	if not set.exportedAt then
		return nil, "this export carries no timestamp"
	end

	return set
end

Import.ParsePayload = ParsePayload

--------------------------------------------------------------------------------
-- Public entry point
--------------------------------------------------------------------------------

-- Returns ok, message.
function Import.Paste(str)
	if type(str) ~= "string" or str:match("^%s*$") then
		return false, "nothing to import"
	end

	str = str:match("^%s*(.-)%s*$")

	local major, blob = str:match("^SGDDR:(%d+):(.+)$")
	if not major then
		return false, "that is not an SGDD Reserves export string"
	end
	if tonumber(major) ~= ns.VERSION_MAJOR then
		return false, VersionMessage(major)
	end

	if not LibDeflate then
		return false, "LibDeflate is missing; reinstall the addon"
	end

	local raw, err = DecodeBase64(blob)
	if not raw then
		return false, "could not read that string -- " .. err
	end

	local text = LibDeflate:DecompressDeflate(raw)
	if not text then
		return false, "could not decompress that string -- it is probably an incomplete copy"
	end

	local set, reason = ParsePayload(text)
	if not set then
		return false, reason
	end

	set.importedAt = time()

	-- Replace wholesale, never merged with what it replaces: reserves are wiped
	-- weekly on the website, and a merge resurrects picks that were deliberately
	-- cleared.
	ns.DB().set = set

	-- This client belongs to somebody who imports, which is how the addon knows
	-- it is an officer's and not a raider's. It never goes back to false.
	ns.DB().everImported = true

	-- Paste time is the only moment this addon does real work, so it is where
	-- the item cache gets warmed. By the time somebody whispers "!wdir" the
	-- links are ready; without this the first reply after a /reload is plain
	-- text and nobody would ever know why.
	if ns.WarmItemCache then ns.WarmItemCache(set) end

	if ns.UpdateScope then ns.UpdateScope() end

	local msg = ("imported %d reserve%s, generated %s")
		:format(set.reserveCount, set.reserveCount == 1 and "" or "s", set.exportedAt)

	return true, msg, Import.MatchReport()
end

-- Does this group member's name fold to a character the imported list knows?
--
-- Wrapped because of Secret Values, added in 12.0. A unit's name can come back
-- as a "secret" -- a value tainted code may hold and pass along but must not
-- compare, index or run string operations on. Doing any of those raises an
-- immediate Lua error, and Names.Fold does exactly that: :lower() and gsub.
--
-- Group members should be exempt, but "should" is an inference from Blizzard's
-- wording, not a guarantee, and MatchReport is the wrong place in this addon to
-- find out we were wrong. It is the alarm for the silent failure the whole addon
-- exists to catch, so an unreadable roster member counts as UNMATCHED and the
-- loop keeps going. That errs toward crying wolf, which is the safe direction:
-- a match report that reads low is investigated, and one that throws is gone.
local function FoldsToKnownChar(unit, set)
	local ok, folded = pcall(function()
		local name, realm = UnitFullName(unit)
		if not name then return nil end
		if not realm or realm == "" then realm = GetNormalizedRealmName() end
		return Names.Fold(Names.Key(name, realm))
	end)

	if not ok or not folded then return false end
	return set.chars[folded] ~= nil
end

-- The standing check against this addon's one invisible failure. If the site's
-- character keys and the game's disagree, everything above succeeds, the column
-- renders empty, and an empty column is indistinguishable from "nobody reserved
-- anything". So say out loud how many group members were matched, and let a
-- zero be loud.
--
-- Returns nil when not in a group -- there is nothing to match against, which is
-- not the same as a mismatch.
function Import.MatchReport()
	local set = ns.DB() and ns.DB().set
	if not set or not set.exportedAt then return nil end

	local n = GetNumGroupMembers()
	if not n or n == 0 then return nil end

	local prefix = IsInRaid() and "raid" or "party"
	local matched, total = 0, 0

	for i = 1, n do
		local unit = prefix .. i
		if UnitExists(unit) then
			total = total + 1
			if FoldsToKnownChar(unit, set) then
				matched = matched + 1
			end
		end
	end

	if total == 0 then return nil end
	return matched, total
end
