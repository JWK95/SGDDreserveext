# SGDD Reserves

An RCLootCouncil extension for **Same Gear Different Day**. It shows the master
looter who reserved the item currently up for loot, and answers raiders who ask
what they reserved.

Retail **Midnight** only. It will not be built for Classic or any other version.

**It is read-only with respect to RCLootCouncil.** It changes nothing about how
RCLootCouncil works — it does not set responses, filter candidates, pre-sort a
session, or stop anyone from awarding anything. It shows context; officers make
the decisions. The one thing it *sends* is a whisper, in reply, when somebody
asks it a question.

## Installing

RCLootCouncil **3.23.0 or newer** is required — the addon uses its official
column API, and will say so loudly rather than showing an empty column if the
version is too old.

Get the addon from the guild site's addons page, or from CurseForge once the
listing is live. Extract so you end up with:

    Interface/AddOns/SGDDReserves/SGDDReserves.toc

## Using it

### If you raid

**You do not need this addon.** Nothing is imported on your client and nothing
is displayed on it.

To find out what you have reserved, whisper the master looter:

    !wdir

You get one whisper back listing your reserves by difficulty, with each item as
a link you can hover or click. If you have none, it says so; if the master
looter has not loaded a list, it says that instead. It never just goes quiet —
"no reserves" and "no list loaded" are different answers and you always get one
of them.

**Ask between pulls, not during one.** While a boss fight, a Mythic+ run or a
PvP match is in progress the game hides whisper contents from addons entirely,
so the master looter's client never sees your question — you will get nothing
back, and it is not able to tell you why. Ask again once the fight is over.

The item level on a linked item is the item's **base** level, not the level it
drops at on the difficulty you reserved. The difficulty is named right next to
the link; trust that rather than the tooltip.

Reserves are **per character**. Ask from the character you reserved on, or the
answer will be about the wrong one.

If you want to watch the session and see what everyone rolled, that is
RCLootCouncil's own **Observe** setting, not this addon — ask whoever is running
loot to turn it on.

### If you are the master looter

1. Export from the guild site.
2. In game, `/rc reserves` (or the SGDD Reserves panel under RCLootCouncil's
   settings), paste, and press **Import**.

Do this **every raid**. The addon tells you loudly if you zone into a raid or
start a session with nothing imported, or with a list exported before this
week's reset. It cannot stop you — it just says so.

You then get a **Reserved** column in the RCLootCouncil voting frame, sitting
just after the candidate's name, showing which candidates reserved the item up
for loot and at which difficulty — **Myth**, **Hero**, **Champ** or **LFR**.
Hover a cell for the detail; click the header to sort reservers to the top,
hardest difficulty first. The header reads `Reserved!` instead of `Reserved`
when the loaded list is out of date.

The column only appears once you have imported something. **An empty column and
a broken import look identical**, so absent is the honest signal — and the
import tells you how many of the people in your group it actually matched. If
that says 0, say something rather than ignoring it.

### Commands

    /rc reserves     open the import window (alt. /rc sr)

## Contributing

See `CLAUDE.md` for the rules and `docs/export-format.md` for the contract with
the guild website. CI runs `luacheck` and `busted` on every push.

MIT licensed.
