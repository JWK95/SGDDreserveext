# The export format

The contract between this addon and the guild website
(`wowappguildreserveloot`). **It lives in both repos and must say the same thing
in both.** A field renamed on one side and not the other is a silent import
failure at raid time — everything decodes, nothing matches, and the loot master
sees an empty column that reads as "nobody reserved anything".

Anything below marked as a rule has a test behind it. Change one and change the
test, on both sides.

---

## Layers

    SGDDR:<major>:<standard base64 of raw-deflated UTF-8 text>

### Base64 is standard, not LibDeflate's

RFC 4648 alphabet, `=` padding, no line wrapping. **Not** `EncodeForPrint`, not
base64url.

The website encodes in JavaScript and this addon decodes in Lua, and only one of
those two sides can be unit-tested against real vectors. Standard base64 means
the website's half is one built-in Node call with no hand-written alphabet to
get subtly wrong, and the risk lands here, where `spec/import_spec.lua` pins it
against RFC 4648's own vectors. A wrong alphabet does not error; it produces
plausible bytes that fail deflate afterwards with a misleading message.

`spec/import_spec.lua` deliberately tests `+` and `/` — index 62 and 63 are the
two characters base64url spells differently, so that one test is what catches a
switch to base64url on the website.

### Raw deflate, no wrapper

`zlib.deflateRawSync` on the website, `LibDeflate:DecompressDeflate` here.
`deflateSync` (zlib-wrapped) and `gzipSync` both fail to decode. This is the
easiest thing in the whole format to get wrong, and the website's round-trip
test exists to catch it.

**There is no checksum, deliberately.** A truncated paste fails the deflate
decode loudly, which is the behaviour we want; a checksum would only be a second
way to say the same thing.

### Payload

UTF-8, `\n`-separated lines, `|`-separated fields, first field is a
one-character record type.

**No field may contain `|` or a newline.** WoW names cannot, so the website
*refuses to export* rather than escaping — an escaping scheme is a second thing
for two codebases to agree on for no gain.

---

## Records

| Rec | Fields |
| --- | --- |
| `V` | major, minor |
| `G` | guild name, exactly as Blizzard spells it |
| `T` | export timestamp, UTC ISO-8601, `Z`, second precision |
| `C` | ingameKey, name, realmSlug, class |
| `S` | ingameKey, itemId, tier, reservedAt, itemName |

That is the whole format. Version 1 also carried `K` (which of two exports this
was) and `A` (awarded items); **both are gone in version 2** and the addon
ignores them if it sees them, which is what makes a transitional export that
still emits them harmless rather than fatal.

There is exactly one export and one button. Only the master looter imports;
raiders install nothing and paste nothing, and ask what they reserved by
whispering `!wdir` to the master looter in game.

### The character key is carried twice, on purpose

    C|Beefy-ArgentDawn|Beefy|argent-dawn|WARRIOR

The website stores `Name-realm-slug`; WoW and RCLootCouncil use
`Name-RealmNoSpaces`. **These do not match**, and the mismatch is invisible — it
looks exactly like an empty reserve list.

`Names.Fold` resolves it by stripping every separator and lowercasing, so both
forms converge:

    "Beefy-ArgentDawn"  -> "beefyargentdawn"
    "Beefy-argent-dawn" -> "beefyargentdawn"

Safe because a character name cannot contain a hyphen, space or apostrophe:
every one in a key belongs to the realm half. **The guild raids across many
realms**, including multi-word and apostrophe realms, so this is not
theoretical — `spec/names_spec.lua` covers Argent Dawn, Twisting Nether and
Kil'jaeden, and is mutation-tested (dropping the hyphen strip, dropping the
lowercase, and splitting on the last hyphen were each introduced and each
caught).

Both forms are emitted anyway. Belt and braces is justified here specifically
because the failure is silent.

### `tier` is a difficulty, from a closed set of four

    Mythic    Heroic    Normal    LFR

Matched case-insensitively by the addon, but emitted with the capitalisation
above. The website sends the **difficulty**; the addon displays the **track** —
`Myth`, `Hero`, `Champ`, `LFR` — and does that translation on its own side, in
`Tiers.lua`, covered by `spec/tiers_spec.lua`.

That split is the rule and it runs in one direction only. The difficulty is the
true name of the thing a raider picked, so it is what crosses the wire. The
track name is how the guild talks, so it is what appears on screen. **The
website must never send `Myth`, `Hero`, `Champ` or `Veteran`** — rewriting
stored data to match a UI label would make this format lie about its own
contents, and would need a coordinated deploy on both sides to change again
later.

A tier outside the four is rendered **verbatim** in the voting column rather
than being coerced or abbreviated. `Warband` in a cell is a bug report; `W`
would be invisible. That is a backstop for a disagreement between the two repos,
not a licence to widen the set on one side — the addon's colour and sort order
are keyed on these four.

### The item id is the truth; the name is a fallback

The addon resolves name, icon, quality and a real item link from the id, which
gives hoverable tooltips and correct localisation on every client. The exported
English name is displayed **only** while the client's item cache is cold, so a
raider sees a name instead of `item 213456`.

**A link built from an id alone shows base item level.** Bonus ids are what
carry item level, an id carries none, and no API manufactures a track-correct
link from an id. So a `!wdir` reply links the base item, and the raider reads
the difficulty from the word next to it. This is a known and accepted trade, not
a defect to work around on the addon side.

The only thing that could fix it is this format carrying the bonus ids for each
difficulty, which would mean the website knowing them. **Do not add that
speculatively** — it is a major bump, it makes every reply substantially longer
against a 255-byte cap, and the guild has already decided the base-level link is
good enough.

### Both clocks, always

`T` is the **website's** stamp — when the data was pulled. The addon separately
records when the string was pasted. Both are shown:

    Reserves from 3 Sep 20:14 · imported 7 Sep 19:02

They diverge exactly when it matters: exported Monday, pasted Friday. Showing
only the paste time lets five-day-old reserves read as current.

**Informative only.** The addon never refuses, warns or colours anything based
on age. How stale is too stale is the officer's judgement, not the addon's.

---

## Versioning

`V|major|minor`.

- **Minor bump**: a new optional trailing field on an existing record, or a new
  record type. Old addons ignore what they do not recognise and keep working.
- **Major bump**: a changed meaning, order or presence of an existing field, or
  a removed record type. Old addons refuse the import and name the version they
  need.

A mismatch is **never migrated**. It is read as a miss and refused — the same
rule the website already applies to its stored JSON payloads.

The major version is checked in the envelope, before anything is decompressed,
so a wrong-version string costs nothing to reject.

### Version 2, and which side to blame

Version 2 removed the personal export, the `K` record and the `A` record. That
is a changed-meaning, removed-record change, so it is a major bump and there is
no transition format.

**The addon ships before the website does.** So on a cutover night the expected
failure is an officer with the new addon pasting a version 1 string, and the fix
is on the site. The refusal message therefore names the *website* when the
string's version is below the addon's, and names the addon when it is above.
Telling somebody who updated an hour ago to update again is how a real message
gets ignored — `spec/import_spec.lua` pins both directions.

---

## One dataset, replaced wholesale

There is one set and each import replaces it entirely. It is never merged with
what it replaces.

The website wipes reserves weekly. A merge is how a pick that was deliberately
cleared is still on a loot master's screen three weeks later — and once that
happens once, officers stop trusting the column, which costs more than the
feature is worth.

A version 1 saved-variables database is **discarded, not migrated**, for the
same reason the format refuses a version 1 string: a shape whose meaning changed
is not something to translate. The officer is told, and imports again.

---

## Freshness is judged against the weekly reset, not against a clock

The addon warns the master looter when the loaded list is stale, on entering the
raid and again when a session opens. Staleness is **exported before the most
recent weekly reset**, with a three-day age backstop for when the reset time
cannot be read.

Age alone is the wrong measure and this is the case that proves it: a list
exported on Tuesday for a Tuesday raid is one day old and perfectly good, and
the same list on Thursday is two days old and completely wrong, because the
reset happened in between. `T` is what both checks read, which is why an export
with no timestamp is refused outright.
