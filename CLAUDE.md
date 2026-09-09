Bash for reads and searches, Edit for modifications.

# This repo

`SGDDReserves` — an RCLootCouncil extension for the guild Same Gear Different
Day. It shows the master looter who reserved the item currently up for loot, and
answers raiders who whisper `!wdir` asking what they reserved.

Retail **Midnight only**. No Classic, no Cata, no MoP, no other flavour, ever.

`README.md` = what it does and how to install it. This file = the rules.
`docs/export-format.md` = the contract with the website, and is the one document
that also lives in another repo.

## The two halves

The reserve data comes from a **separate Next.js web app** at
`D:\Documents\wowappguildreserveloot`. That app owns the reserves; this addon
only displays them.

They are connected by **a string a human copies**. Nothing else. This addon has
no network access and no way to ask the website anything. There is **one**
export and **one** button, and only the master looter ever pastes it.
`SITE-EXPORT-PROMPT.txt` is the brief handed to the agent building the
website's half.

**Gargul is dead.** The guild evaluated it and the GM decided against it. Do not
add a Gargul export, a Gargul CSV, or Gargul-shaped anything.

## Commands

There is no local Lua toolchain on the dev machine and installing one needs
admin. CI runs both checks on every push:

```bash
luacheck .        # allowlisted globals; an unlisted global is an error
busted --verbose  # spec/, pure modules only
```

To run them locally, fetch a portable Lua 5.1 into the scratchpad — the specs
need no libraries beyond a busted shim. **A mutation applied with `sed` must
still compile**: check with `luac -p` before believing a "caught". A mutation
that only introduces a syntax error proves nothing, and this repo has already
produced one of those.

## Definition of done

`luacheck .` and `busted` clean, and **any non-obvious rule mutation-tested**:
break it, confirm a test fails. A test that passes both ways protects nothing,
and this repo has already caught itself writing four of those.

Standing proofs, all mutation-tested:

- `spec/names_spec.lua` — dropping the hyphen strip, dropping the lowercase,
  splitting on the last hyphen.
- `spec/import_spec.lua` — accepting any major version, double-counting a
  duplicate reserve, blaming the addon when it is the website that is behind.
- `spec/whisper_spec.lua` — dropping the trigger's word boundary, dropping the
  start anchor, dropping the case fold, ignoring the 255-byte cap, misreporting
  how many reserves were truncated away, letting a reply begin with a number,
  ranking a tier group by its printed label, stripping pipes out of an item
  link.
- `spec/freshness_spec.lua` — measuring age instead of the weekly reset,
  treating an unreadable reset time as fresh.
- `spec/tiers_spec.lua` — dropping the Normal→Champ mapping, abbreviating an
  unrecognised tier to its first letter, sorting an unknown tier first instead
  of last, handing out the shared colour table.
- `spec/reservers_spec.lua` — never disambiguating a colliding name, always
  disambiguating one, counting collisions after the cap instead of before,
  ignoring tier rank when ordering, reversing it, dropping the name tiebreak,
  an off-by-one in the truncation count, truncating silently, ignoring the
  colouriser. **The ordering test was itself caught by mutation**: its first
  version used names that were already alphabetical, so deleting the tier
  comparison changed nothing and the test passed either way. The fix was to
  arrange the names in the opposite order to the difficulties, which is the
  only thing that makes that comparison load-bearing.

## Invariants

### It never changes what RCLootCouncil does — but it does speak

- **This addon never changes what RCLootCouncil does, only what it shows.** It
  does not set a response, pre-sort a session, filter a candidate, or warn
  before an award. Officers make the decisions; the addon supplies context. A
  change that would alter RCLootCouncil's behaviour does not belong here, no
  matter how useful.
- **It reads RCLootCouncil's wire; it never writes to it.** `RC.lua` subscribes
  to the `RCLC` prefix to learn that a session started. It opens no prefix of
  its own, sends no addon message, and there is no sync protocol between
  clients.
- **The one thing it sends is a whisper, in reply, when asked.**
  `Responder.lua`, from the master looter's client only. That is a real
  widening of "read-only" and it is deliberate: it is what let the personal
  export die, because a raider now needs no addon at all.
- **It is inert on a raider's client.** They never import, so nothing registers
  and nothing draws. What raiders see of a live session is RCLootCouncil's own
  `observe` setting, which is the master looter's to turn on and none of our
  business.

### Silent failures

- **An empty column and a broken character match look identical.** This is the
  addon's one invisible failure and most rules here exist because of it.
  `Names.Fold` is the fix, `spec/names_spec.lua` is the proof, and
  `Import.MatchReport` is the alarm: an import that matches **0 of N** group
  members says so out loud. Never let that report be quietly dropped.
- **No import, no column** (`VotingColumn:Register`). A column of blanks in a
  live session is noise at the worst moment *and* is exactly what a key mismatch
  looks like. Absent is the honest signal.
- **The whisper responder never goes quiet** — *except in chat messaging
  lockdown, which it cannot help.* Three outcomes, three sentences: a list, "you
  have no reserves", "I have no list loaded". A raider who gets nothing back
  cannot tell which is true. This is also why the responder is scoped on *has
  ever imported* rather than *has data now* — an officer whose data was cleared
  still has to be able to say so. The one hole is stated rather than hidden:
  during lockdown the incoming whisper's text and sender are secret values, so
  the responder never sees the request and cannot answer it or apologise for
  not answering it. See the Whispers section.
- **A truncated reply says how much it truncated.** Showing four of somebody's
  six reserves without saying so is worse than not replying.
- **`nil` is a third answer, never "no".** RCLootCouncil reports the master
  looter as `"Unknown"` while it is still resolving; treating that as "I am not
  the master looter" silences the import warning on the one client that needed
  it, so `Nag` **warns anyway**. `Freshness` treats an unreadable weekly reset
  the same way: it falls through to the age backstop rather than declaring the
  list fresh. Same reasoning as the website's `unknown-rank` — an outage is not
  an answer.
- **Below RCLootCouncil 3.23.0 there is no column API**, and quietly adding no
  column is indistinguishable from nobody having reserved anything. `RC.lua`
  refuses loudly and names the version instead. Said once, at
  `PLAYER_ENTERING_WORLD` — a message on every zone-in is a message people
  filter out.

### Freshness is measured against the reset, not the clock

`Freshness.lua`. The website wipes reserves weekly, so **age is the wrong
measure**: a list exported Tuesday for a Tuesday raid is one day old and correct;
the same list on Thursday is two days old and completely wrong, because the reset
happened in between. The reset boundary does the real work and the three-day age
count is only a backstop for when `GetSecondsUntilWeeklyReset` cannot be read.

The warning fires at the **master looter**, on entering a raid and again when a
session opens, and it blocks nothing. How stale is too stale in a given week is
still the officer's judgement — the addon states the export timestamp and gets
out of the way.

### Weight

- **No `OnUpdate`, no polling, no work in combat** — with **one stated
  exception**. Parsing happens once, at paste. Session starts arrive as one comm
  subscription, fired only when a master looter actually starts one; there is no
  AceEvent for it on any client.
  The exception is `InputScrollFrameTemplate`, Blizzard's multiline input, used
  for the paste box in `OfficerFrame.lua`. It carries a per-frame `OnUpdate` for
  caret tracking. It was taken wholesale rather than hand-rolled because it
  already solves click-anywhere focus, and its `OnUpdate` ticks **only while the
  import window is open** — a window an officer opens once a week. Rewriting it
  to avoid the tick would trade a real usability fix for a number nobody can
  measure.
- **The item tooltip callback cannot be unregistered, and is therefore
  permanent for the session.** `TooltipDataProcessor.AddTooltipPostCall` has no
  removal. `Tooltip.lua` registers through `ns.UpdateScope()` so it is only ever
  added on a client that has imported — raiders add nothing — but once an
  officer imports, it is held until they log out. This is a real dent in the
  rule below and it is why the **option is checked inside the callback** rather
  than by tearing the callback down: turning the setting off has to stop the
  line appearing, and unregistering is not available to do it. The callback's
  first act is the cheapest possible rejection.
- **At rest the addon holds two registered events**, `ADDON_LOADED` and
  `PLAYER_ENTERING_WORLD`. Everything else — the whisper handler, the session
  subscription — hangs off `ns.UpdateScope()` and is
  registered only on a client that has imported at least once. Since only the
  master looter imports, that *is* the officer scope, and a raider who installs
  the addon runs nothing.
- **`reserves` is indexed by item id, not a list.** The cell update runs once
  per candidate per redraw of a live loot session, so its lookup must be O(1). A
  list scanned per cell is the one place this addon could become something you
  feel.
- **Frames are built on first use.** An officer who never opens the import
  window pays for none of it. `GET_ITEM_INFO_RECEIVED` is registered only while
  that window is open, and coalesces a batch into one redraw.
- **No minimap button, and no slash command of our own.** `/rc reserves`, via
  RCLootCouncil's `ModuleChatCmd`.

### Whispers

- **Only the master looter answers.** They are the one person the raid can
  identify without being told, and one reply is better than five.
- **In chat messaging lockdown the responder is deaf, and there is no queue.**
  `CHAT_MSG_WHISPER` is `SecretInChatMessagingLockdown`, and neither its text
  nor its sender is `NeverSecret` — during an encounter, a Mythic+ run or a PvP
  match on a restricted map both arrive as **secret values**. Tainted code may
  hold a secret but may not compare it, index it or run a string operation on
  it, and any of those is an immediate Lua error. `Whisper.IsTrigger` calls
  `msg:lower()`, so without the `C_ChatInfo.InChatMessagingLockdown()` guard at
  the very top of `OnWhisper`, *any* whisper the master looter receives mid-pull
  throws out of this addon.
  The old `ENCOUNTER_START`/`ENCOUNTER_END` queue is **gone, not disabled**:
  secrecy is permanent, so a sender captured during lockdown could never be
  replied to afterwards. It was storing something unusable. Lockdown is also
  broader than a raid encounter, which is why the guard is the API call and not
  an encounter flag.
- **One reply per person per thirty seconds.** Twenty raiders discovering the
  command at once is a chat throttle, and a throttled master looter cannot
  announce anything.
- **Nothing we send may begin with a number, and that is load-bearing.**
  RCLootCouncil's master looter client parses incoming whispers into loot
  responses. It does **not** bail on the absence of `|Hitem:` — `ml_core.lua`
  reads the first token, `tonumber`s it, and returns early unless it is a valid
  session number. The link check runs only *after* that. So the property that
  keeps us out of its loot responses is the leading token, and that is what
  `spec/whisper_spec.lua` pins — for the trigger *and* for all three replies.
  This matters more now that replies carry links: a reply starting with a number
  would hand RCLootCouncil a session number followed by an item link, which is
  exactly the shape it acts on.
- **No *bare* `|` in any outgoing message.** A lone pipe is rejected by the
  server as an invalid escape code. A well-formed escape sequence is fine, and
  replies **do** carry item links — RCLootCouncil sends them itself. `Whisper.lua`
  writes no pipe of its own; labels arrive finished from `Core.ItemWhisperLabel`
  and are treated as opaque, which is what keeps that file pure while the reply
  contains links.
- **Whisper links are base item level, knowingly.** A link built from an item id
  carries no bonus ids, and bonus ids are what carry item level — so a reserve
  links the base item, not the Myth/Hero/Champ version. There is no API that
  builds a track-correct link from an id alone and the website exports ids, so
  the alternative was no links at all. The guild accepted the trade: the tier
  word sits next to the link, and a raider knows the track from the raid.

## Where the code is

**Pure, and covered by `spec/`:** `Names.lua` key folding · `Tiers.lua` the
difficulty vocabulary — the website stores difficulties (`Mythic`), the guild
speaks tracks (`Myth`), and this is the only place that translates ·
`Reservers.lua` who reserved a given item, in the order an officer reads it,
including the cross-realm name collision rule · `Schema.lua` the shape of the
dataset, separate from Core so tests can build one without `CreateFrame` ·
`Freshness.lua` is the list still good for tonight · `Whisper.lua` what `!wdir`
means and what comes back.

**The tier vocabulary is addon-side only.** `docs/export-format.md` is unchanged
and the website keeps sending `Mythic`/`Heroic`/`Normal`/`LFR`. Translating on
display costs one file; changing what the website stores would make the export
format lie about its contents and need a coordinated two-repo deploy, which that
document already calls a raid-night hazard. Both surfaces that show a tier —
the voting column and the whisper reply — go through `Tiers.Label`, because a
vocabulary that drifts between them is how a raider ends up asking an officer
what the difference is mid-pull.

**Everything else:** `Core.lua` state, events, scope, display helpers ·
`Import.lua` base64, deflate, parse · `RC.lua` **every handle into
RCLootCouncil** · `VotingColumn.lua` the column spec and its cell ·
`Responder.lua` the whisper event and cooldown · `Tooltip.lua` the
"Reserved by:" line on item tooltips · `Nag.lua` the stale import warning ·
`OfficerFrame.lua` the import window · `Options.lua` the settings panel.

**The item tooltip is the one place the addon draws outside RCLootCouncil's
frames.** `Tooltip.lua` adds a line to `GameTooltip` (bags, loot window,
merchant, character sheet — they all render into it) and `ItemRefTooltip` (an
item link clicked in chat). It deliberately does **not** decorate
`ShoppingTooltip1/2`, the comparison tooltips: those describe the gear the
viewer is already wearing, so a "Reserved by" line there would be attached to
the wrong item entirely. It still changes nothing about what RCLootCouncil does
— it is display, on this client, of data this client imported — but it is a real
widening of *where* the addon appears, so it is behind a setting.

`RC.lua` and `VotingColumn.lua` are the **only** two files that may name
RCLootCouncil. That is the rule, and the reason is that they are what breaks
when RCLootCouncil updates, so the blast radius should be one or two files you
can open rather than a search. Integration is through supported extension points
only — `Modules/VotingFrame/ColumnAPI.lua`, `Comms:Subscribe`, `ModuleChatCmd`,
`UI:NewNamed`, and `AceConfigDialog:AddToBlizOptions` parented to
RCLootCouncil's panel (the same route RCLootCouncil_Merit takes). Do not reach
past them into RCLootCouncil's internals, and do not copy code out of
RCLootCouncil into this repo.

Specifically **do not** try to insert into RCLootCouncil's options table: it is
rebuilt from scratch on every refresh and anything added is silently discarded.
Register our own table and parent it.

**A table handed to `ModuleChatCmd` must carry `baseName` and `version`.**
`/rc help` prints the owning module of every registered command and falls back
to `C_AddOns.GetAddOnMetadata(baseName)` when there is no version, so a plain
table with neither throws inside RCLootCouncil's help loop. RCLootCouncil's own
modules are AceAddon modules and get both for free; ours is not. Note the shape
of that bug — we broke *somebody else's* command, not our own, so nothing we
would have tested would have shown it.

Ace3 is **not** embedded. RCLootCouncil is a required dependency and loads it,
exactly as Merit relies on.

## Releasing

Tag-driven: `git tag v2.0.0 && git push --tags` runs
`.github/workflows/release.yml`, which packages, pulls the embedded libraries,
substitutes `@project-version@` into the TOC, attaches the zip to a GitHub
release, and uploads to CurseForge. **The GitHub release asset is what the guild
website serves**, so one tag feeds both channels.

**The list of shipped files exists twice** — in `SGDDReserves.toc` and in
`build.ps1` — and they must agree. Adding or removing a Lua file means editing
both; a file in the TOC but not the package is an addon that fails to load for
the whole guild, and it is invisible until somebody installs the zip.

**The addon ships before the website does**, and format version 2 is a hard
cutover with no transition format. So between the two deploys an officer's
paste is refused. Hold the tag until the site's version 2 export is live, unless
the guild has agreed to eat a raid night.

CurseForge project **1685978**. The token is not configured yet and the packager
skips that upload without it — see `NOTES-CURSEFORGE.md`.
