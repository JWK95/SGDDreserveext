# CurseForge — what to do when the API key arrives

Written for whoever (or whatever) picks this up later. **Nothing here is done
yet, and nothing here blocks releasing today** — the release workflow already
publishes a GitHub release asset, which is what the guild website serves.

CurseForge project ID: **1685978** (already in `SGDDReserves.toc` as
`## X-Curse-Project-ID`).

---

## State of play

| Thing | Status |
| --- | --- |
| GitHub repo `JWK95/SGDDreserveext` | public |
| `.github/workflows/release.yml` | written, tag-driven |
| GitHub release asset | works now, no secret needed |
| Guild site serving the zip | specced in `SITE-EXPORT-PROMPT.txt`, not built |
| CurseForge upload | **waiting on `CF_API_KEY`** |
| CurseForge project approval | unknown — check the project page |

The packager **warns and skips** the CurseForge upload when `CF_API_KEY` is
absent. That is why the workflow is already committed and already useful: a tag
today produces a working GitHub release, and the CurseForge upload starts
happening on the next tag after the secret is added. No workflow edit is needed.

---

## Steps, when the key is in hand

1. **Get the token.** CurseForge account settings → API Tokens → generate one.
   It is shown once; copy it immediately.

2. **Add it to GitHub.** Repo → Settings → Secrets and variables → Actions →
   New repository secret. Name it exactly `CF_API_KEY`. The workflow already
   references `${{ secrets.CF_API_KEY }}`; do not rename it.

3. **Check the project page** for game version and category. The project must
   list **Midnight** as a supported version or the upload is rejected. The TOC
   says `## Interface: 120100`; the packager derives the game version from it,
   so those two must agree with what CurseForge knows about.

4. **Confirm the licence.** The project's licence field should read MIT, matching
   `LICENSE` and `## X-License` in the TOC.

5. **Tag a release and watch the run.**

   ```bash
   git tag v1.0.1
   git push --tags
   ```

   The Actions log will say whether it uploaded to CurseForge or skipped it.

---

## Things to verify on the first real run

These are assumptions, not verified facts — check each against the Actions log
rather than trusting this file.

- **`tag: latest` on the LibDeflate external** in `.pkgmeta`. If the packager
  does not resolve it, replace it with an explicit tag or drop the line to take
  the default branch.
- **`## Interface: 120100`** is derived from Midnight being patch 12.1. Confirm
  against the live client's `Interface` value before a public release — a wrong
  number makes the addon show as out of date for everyone.
- **The LibStub external** points at CurseForge's SVN mirror, which is the
  long-standing convention but is somebody else's infrastructure. If it 404s,
  vendor LibStub into `Libs/` instead; it is about forty lines and it does not
  change.
- **RCLootCouncil's `ColumnAPI`** was read from
  `evil-morfar/RCLootCouncil2/Modules/VotingFrame/ColumnAPI.lua`. It is a
  supported public API, but it has not been exercised against a live client yet
  — the first in-game test should be an officer import with a real loot session,
  checking that the `SR` column appears and sorts.

---

## Distribution today, without CurseForge

The guild site is the channel that matters this week. It fetches the latest
GitHub release asset for `JWK95/SGDDreserveext` and serves it behind the guild
wall — specced in the second half of `SITE-EXPORT-PROMPT.txt`, modelled on the
site's existing `class-codex.ts`.

No token is needed while the repo is public. **If the repo is ever made
private, that path breaks** and needs a GitHub token in the site's environment.
