# The sync protocol

What the master looter's client says to the raid, and what a raider's client
says back. This is a contract between **two copies of this addon**, which is
what makes it different from `docs/export-format.md` — that one is a contract
with the website and changing it needs a two-repo deploy. This one needs a
release.

Read this before changing anything in `Protocol.lua` or `Sync.lua`.

---

## Why it exists at all

This addon spent its whole life reading RCLootCouncil's wire and never writing
to one, and "no sync protocol between clients" was a stated invariant. It is now
a narrower invariant rather than an absolute one, and the trade was made
deliberately:

- A raider could not see what they reserved without whispering an officer.
- The reserve data only ever existed on the one client that pasted the import.
- Every alternative was worse: raiders pasting the export themselves resurrects
  the personal export this addon deleted; a whisper-driven query turns the
  master looter into a query server for twenty-five people and is deaf during
  the encounter the loot comes from.

**What has not changed:** we still only *subscribe* to RCLootCouncil's prefix
and still never send on it. Our traffic is on our own prefix, where the server's
per-prefix throttle allowance is ours to spend and cannot starve theirs.

---

## Shape

| | |
| --- | --- |
| Prefix | `SGDDRsv` (max 16 chars; not `RCLC`, `RCLCv`, `RCLCs`) |
| Transport | AceComm-3.0, taken from LibStub — RCLootCouncil loads it, nothing is embedded |
| Channel | `RAID` |
| Separator | tab (`\t`) |
| Wire version | `Protocol.VERSION`, currently **1** |

A message is `<kind>\t<version>[\t<field>...]`.

The separator is a tab because the only variable-length field is a base64 blob
(`A-Za-z0-9+/=`) or an ISO timestamp, and neither can contain one. Nothing needs
escaping.

### Messages

| Kind | Direction | Payload | Meaning |
| --- | --- | --- | --- |
| `A` | ML → raid | `exportedAt`, `reserveCount` | "I have a list, from this time, this big" |
| `R` | raider → raid | — | "Send it" |
| `D` | ML → raid | the export string, verbatim | the list |
| `N` | ML → raid | — | "I have this addon and no list loaded" |

---

## The flow

```
  master looter starts a loot session
        |
        |  A  (~40 bytes, one send)
        v
  every raider's client
        |
        |  ShouldPrompt(announcedAt, lastAcceptedAt)?
        |     no  -> silent, already have this list (or already declined it)
        |     yes -> dialog naming the timestamp and count
        v
  raider clicks Yes
        |
        |  R
        v
  master looter
        |
        |  ShouldBroadcast(now, lastBroadcastAt)?
        |     no  -> nothing; an answer is already on its way
        |     yes -> D, to RAID
        v
  every raider who asked, and everyone about to
```

`/rc askml` enters at the `R` step directly.

---

## The four decisions worth understanding

### 1. The payload is the export string, unchanged

`D` carries the exact `SGDDR:<major>:<base64>` the officer pasted — not a
re-serialised copy of the parsed dataset.

This means a raider runs the *same* `Import.Decode` as the officer: same
envelope check, same major-version check, same base64 decode, same deflate, same
record parser. There is exactly one way to turn a string into a dataset in this
addon.

A second construction path would be a second set of rules to keep in step, and
the failure mode of them drifting is a raider holding a subtly different list
from the officer — this addon's signature invisible bug wearing a new hat.

### 2. The reply is a broadcast, and requests are coalesced

A boss dies, twenty dialogs appear, twenty people click yes inside two seconds.

- An addon message body is **255 bytes**.
- The server throttle is **per prefix: allowance 10, regenerating 1/second**.
- The API documentation is explicit that too much data at once **can disconnect
  the client**.

A full reserve set is several kilobytes, so roughly ten messages after chunking.
Answering each asker individually is that multiplied by the raid size — on the
one client that must not disconnect. Answering **once, to the raid**, is O(1):
the first request triggers a broadcast, every request inside
`Protocol.COALESCE_WINDOW` is served by it, and raiders who declined receive the
bytes and drop them.

The coalescing applies to `N` as well as `D`. An officer who has not imported is
exactly the officer twenty people are about to ask, so an uncoalesced "no list"
is the reply sent twenty times.

### 3. Only the master looter may hand out a list

Anyone in the raid can register this prefix and send a `D` claiming to carry
tonight's reserves. Without a check, one person could make every raider's window
read "you reserved nothing" — confidently wrong, which is worse than blank and
is the exact failure this addon exists to eliminate.

So `A`, `D` and `N` are rejected unless the sender folds to
`RCLootCouncil.masterLooter`. `R` is not checked: it carries no claim, and
answering a request from a non-raider costs one coalesced broadcast.

**`"Unknown"` is a third answer.** RCLootCouncil reports the master looter as
`"Unknown"` while it is still resolving, and as `nil` before it has looked.
Neither means "this sender is not the master looter" — it means we do not know
who is. `Protocol.AuthorityState` names that state and `IsAuthority` rejects
during it. Rejecting is safe *because the pull path exists*: a push that arrives
too early costs a few seconds and one `/rc askml`, not the feature.

### 4. Four outcomes, never silence

From a raider's client these all look identical:

1. the list is on its way
2. the master looter has this addon but no list — `N`
3. the master looter does not have this addon — **timeout**
4. the send was refused (`AddOnMessageLockdown`) — encounter or Mythic+

Only (2) is "the leader has not imported". Saying that in case (3) sends a
raider to nag an officer who cannot fix it; in case (4) it is simply false.
`Protocol.OUTCOME` holds four distinct sentences and `spec/protocol_spec.lua`
pins that they stay distinct. This is the whisper responder's "never goes quiet"
rule applied to a second channel.

---

## Secret values

**`CHAT_MSG_ADDON` is not `SecretInChatMessagingLockdown`.** Checked against
Blizzard's generated `ChatInfoDocumentation.lua` for 12.1.0: the event carries no
secret predicate, so `prefix`, `text`, `channel` and `sender` never arrive
secret. Unlike `CHAT_MSG_WHISPER`, this protocol needs **no lockdown guard to
read a message**, and unlike the deleted whisper queue there is nothing here
that could be stored and never used.

Two things still bite:

- **`C_ChatInfo.SendAddonMessage` is `SecretArguments = "NotAllowed"`** and
  errors on a secret argument. The master looter's name comes from
  RCLootCouncil, not from the message, so it is screened with `ns.IsSecret`
  before it is folded or compared — in `Sync.lua`, at the boundary, before
  `Protocol` (which is pure) ever sees it.
- **Sends can be refused** with `Enum.SendAddonMessageResult.AddOnMessageLockdown`
  during an encounter or a Mythic+ key. That is outcome (4) above.

---

## Scope

- **Raid only.** Inside a Mythic+ key the `ChallengeMode` restriction refuses
  sends for the whole dungeon: the announce never lands and a request comes back
  refused for twenty minutes. Reserves are a raid artefact — the website wipes
  them against the weekly raid reset, which is the boundary `Freshness.lua` is
  built on.
- **Registered only in a raid group** (`ns.InRaidScope`), torn down on leaving.
  Not sticky, unlike the officer scope.

---

## Storage

A received list goes to **`SGDDReservesDB.received`**, never `.set`, and
`everImported` is **not** set.

Half this addon keys officer behaviour off those two: `ns.Data()` gates the
voting column, `everImported` gates the whisper responder and the stale-import
warning. Routing received data through the same variables would switch officer
surfaces on for twenty-five raiders, and the symptom would be an `SR` column
appearing in somebody's voting frame with no explanation.

Two slots, two meanings. `ns.AnySet()` is for display only and nothing that
decides scope may call it.

---

## Changing this

**Bump `Protocol.VERSION` for any change to the shape of a message.** A version
mismatch is a named refusal that says which side is behind — never a silent miss
that leaves a raider staring at an empty window.

Do **not** reuse the export format's major version for this. They are different
contracts with different deploy stories: the export format is shared with the
website, this is shared only between two copies of this addon, and two clients
on different addon releases can disagree about the wire while agreeing perfectly
about the format.

Anything non-obvious you add here gets a mutation test, like the rest of
`Protocol.lua` already has — see the standing list in `CLAUDE.md`.
