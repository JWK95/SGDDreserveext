# In-game gotchas

Bugs that `busted` and `luacheck` cannot see, checked against this addon.

This exists because a raid found bugs a green test suite had not. That is not a
gap in the tests — it is the shape of the problem. `spec/` covers the four pure
modules, and every bug below lives somewhere a pure module cannot reach: in an
API that behaves differently on a cold cache, in a frame somebody else recycles,
or in a restriction that only exists while a boss is up.

Sources are Blizzard's generated API documentation, `warcraft.wiki.gg`, and
RCLootCouncil's own source at `evil-morfar/RCLootCouncil2`.

---

## What a spec here can and cannot catch

It **can** catch a rule that is a function of its inputs: what `!wdir` means,
what a reply looks like, how a key folds, whether a list is stale.

It **cannot** catch:

- an API that returns `nil` because the client has not cached something yet,
- a frame the addon does not own being reused underneath it,
- a value that is legal to read at one moment and an error to read at another,
- a call into RCLootCouncil that quietly does nothing,
- anything whose only symptom is on a second machine.

Every finding below is in one of those five categories. The habit that catches
them is not more unit tests; it is asking, for each call out of this addon,
*what does this return when the game is not ready, and who else owns it.*

---

## Fixed in this pass

### 1. Whisper handler threw during every encounter — Secret Values

**Severity: high. This is the most likely candidate for the failure seen in
game.**

`CHAT_MSG_WHISPER` is marked `SecretInChatMessagingLockdown` in Blizzard's
generated documentation, and neither its `text` nor its `playerName` payload is
flagged `NeverSecret`. During chat messaging lockdown — a boss encounter, a
Mythic+ run, or a PvP match on a communication-restricted map — both arrive as
**secret values**.

Tainted code, which means every line of every addon, may hold and pass a secret
but may **not** compare it, index it, boolean-test it, or run a string operation
on it. Any of those raises an immediate Lua error.

`Whisper.IsTrigger` calls `msg:lower()`. So before the fix, **any** whisper the
master looter received during a pull — not only `!wdir` — threw an error out of
this addon, in the middle of a fight, with nothing in the message connecting it
to reserves.

*Fix:* `C_ChatInfo.InChatMessagingLockdown()` guard as the first statement of
`OnWhisper`, returning before anything reads `msg` or `sender`.

*Second-order consequence:* the `ENCOUNTER_START`/`ENCOUNTER_END` queue was
deleted, not repaired. Secrecy is permanent, so a sender name captured during
lockdown can never be replied to — not when the encounter ends, not ever. The
queue was storing something unusable. See "Accepted" below for what that costs.

Why no test saw it: the specs call `IsTrigger("!wdir")` with a plain Lua string.
There is no such thing as a secret value outside the game.

### 2. Tooltip pinned over the voting frame describing the wrong raider

**Severity: medium.**

lib-ScrollingTable recycles cell frames. The frame describing one candidate is
handed to a different candidate on the next redraw, and the row that went away
never receives an `OnLeave`. The cell's clear path reset `OnEnter`/`OnLeave` but
did not hide a tooltip that was already showing — leaving it up, over the voting
frame, legibly describing a reserve belonging to somebody else.

*Fix:* `ClearCell` now calls `GameTooltip:Hide()` when `GameTooltip:IsOwned(frame)`.
`IsOwned` rather than an unconditional hide, so the cell cannot close a tooltip
another part of the UI has since opened.

Why no test saw it: the frame is RCLootCouncil's, the recycling is
lib-ScrollingTable's, and neither is loaded in `spec/`.

### 3. `MatchReport` could throw on a raid roster

**Severity: medium — high consequence, low probability.**

`UnitFullName` fed straight into `Names.Fold`, which does `:lower()` and `gsub`.
Patch 12.1.0 extended secret values to `UnitClass`, `UnitSex`, `UnitRace` and
`UnitGroupRolesAssigned` when unit identity is secret, and 12.0 already returned
secrets from `UnitName`/`UnitClass` for non-party units. Group members *should*
be exempt — but that is an inference from Blizzard's wording, not a guarantee.

`MatchReport` is the alarm for this addon's one invisible failure. It failing is
strictly worse than any other file failing.

*Fix:* the fold is wrapped, and an unreadable roster member counts as
**unmatched** rather than throwing. That errs toward crying wolf, which is the
safe direction: a match report that reads low gets investigated; one that throws
is simply gone.

### 4. Cold item cache produced plain names where links were expected

**Severity: medium, and invisible on a developer's machine — which is the point.**

`C_Item.GetItemInfo` returns `nil` for **everything**, link included, until the
item is cached. A cold cache is the *normal* state right after a login or a
`/reload`, and never the state on a machine that has been testing all evening.

*Fix:* `ns.WarmItemCache` runs once at paste, asking the client to load every
reserved item id. Deliberately `C_Item.RequestLoadItemDataByID` and not the
`Item` mixin's `ContinueOnItemLoad` — some item ids never resolve and that
callback can hang forever, which would turn into a reply that never arrives.
Silence is the one outcome this addon refuses. A per-entry fallback to the plain
name covers whatever is still cold.

### 5. `C_AddOns.GetAddOnMetadata` was called unguarded

**Severity: low.**

The namespaced version **errors** on an addon name it does not know, where the
old global returned `nil`. `ns.ADDON` is this folder's own name so it is always
valid, but an unguarded throw would have taken out `/rc reserves` registration
entirely — a large consequence resting on an assumption about somebody else's
API. Now wrapped.

---

## Checked, and already correct

Recorded so the next person does not re-investigate them.

- **`fShow == false` is handled.** The single most common lib-ScrollingTable
  bug is skipping the hide branch, which leaves a recycled cell showing the
  previous candidate's text — here, a reserve against the wrong raider. The
  branch exists and now routes through `ClearCell`.
- **Data is indexed by `realrow`, not `row`.** They diverge the moment the table
  sorts or scrolls. `DoCellUpdate` uses `data[realrow]`, and `comparesort`
  receives real row indices.
- **`GET_ITEM_INFO_RECEIVED`'s `success` is tri-state** (`true` retrieved,
  `false` not queryable, `nil` does not exist) and code that writes
  `if success then` conflates the last two. `OfficerFrame` ignores the payload
  entirely and just debounces a redraw, so it is immune by construction.
- **`SendChatMessage` was deprecated in 11.2.0** in favour of
  `C_ChatInfo.SendChatMessage`, surviving only through the
  `Blizzard_DeprecatedChatInfo` shim. `Responder.lua` already prefers the
  namespaced call and falls back.
- **The 255-byte cap is counted in bytes, and truncation cannot split a UTF-8
  sequence.** `Whisper.FormatReply` drops whole entries and re-renders; it never
  `string.sub`s a partly-built message, so a multi-byte name cannot be cut
  mid-character. Exceeding the cap does not truncate — ChatThrottleLib `error()`s
  and the wiki notes a disconnect — so this one matters.
- **No frames or textures are created inside `DoCellUpdate`.** It runs once per
  cell per redraw.
- **`GameTooltip:SetOwner` is called before any `AddLine`.**
- **`RCLootCouncil.Require` is a dot call taking one argument.** `RC.lua` calls
  `pcall(rc.Require, "Services.Comms")`, which matches RCLootCouncil's own usage
  (`RCLootCouncil.Require "Services.Comms"`). Worth having confirmed: had it
  needed `self`, the subscription would have silently never been made and the
  stale-import nag would never have fired on a session start — with no error.
- **No `OnUpdate`, no polling, no work in combat.** Unchanged by this pass; the
  cache warm is a single loop at paste time.

---

## Accepted, and why

- **The responder is deaf during chat messaging lockdown.** It cannot see the
  request, so it cannot answer it or apologise for not answering it. This dents
  "the responder never goes quiet" and is not fixable from inside the addon at
  any price. People ask between pulls, which works. Stated in `README.md` for
  raiders and in `CLAUDE.md` next to the invariant it dents.
- **Whisper item links show base item level.** A link built from an item id
  carries no bonus ids, and bonus ids carry item level. No API builds a
  track-correct link from an id alone, and the website exports ids. The guild
  accepted this: the difficulty is named next to the link.
- **An unrecognised tier can overflow the 60px column.** Intended. A cell
  reading `Warband` is a bug report; abbreviating it to `W` is invisible.
- **`RC:MasterLooterKnown` compares `rc.masterLooter` to `"Unknown"`.** If that
  field ever became a secret value the comparison would throw. It is
  RCLootCouncil's own field and is not documented as secret; guarding every read
  of another addon's plain string would be noise. Noted rather than fixed.

---

## Watch list for future patches

Not problems today. Each becomes one on a specific patch.

- **The global `GetItemInfo`** was namespaced to `C_Item` in 10.2.6 and was not
  in 12.0.0's removal list, so it still works. `Core.lua` prefers `C_Item` and
  falls back; the fallback is what dies first.
- **`SendChatMessage`** survives only via `Blizzard_DeprecatedChatInfo`. When
  that shim is pulled, the fallback in `Responder.lua` stops working — the
  primary path is already correct.
- **Secret values keep expanding.** 12.0 covered `UnitName`/`UnitClass` for
  non-party units; 12.1.0 added `UnitClass`, `UnitSex`, `UnitRace` and
  `UnitGroupRolesAssigned`. Anything this addon reads about *other players* is
  the thing to re-check on each patch — that is `Import.MatchReport` and the
  whisper sender.
- **`C_ChatInfo.InChatMessagingLockdown`** briefly returned a second
  `lockdownReason` value, removed again in 12.0.5. `Responder.lua` reads only
  the first return, which is correct in every version that has the function.
- **`C_DateAndTime.GetSecondsUntilWeeklyReset`** documents no failure mode at
  all. `Freshness`'s fallback to the age backstop is defensive beyond what is
  documented — that is the right call, but it means the fallback path is
  untested against real game behaviour because there is no known way to trigger
  it.
- **`getglobal`/`setglobal`** were deprecated in 12.1.0. This addon uses
  neither.

---

## If it breaks in game again

1. `/console scriptErrors 1`, or keep BugSack installed. A swallowed error looks
   exactly like a feature that silently does nothing.
2. Note **when** it broke — during a pull, between pulls, right after a
   `/reload`, on first login. Three of the five bugs above are distinguishable
   by that alone.
3. `/reload` and retry once. If it works the second time and not the first, it
   is a cold cache or a load-order problem, not logic.
4. Check whether the master looter is resolved yet. Several paths behave
   differently while RCLootCouncil still reports `"Unknown"`.
