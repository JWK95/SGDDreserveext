# Releasing

How a change on `master` becomes an addon in a guild member's `Interface\AddOns`
folder. This is the whole path, including the parts that are somebody else's
infrastructure.

`README.md` is what the addon does. `CLAUDE.md` is the rules. This is the one
you open when you are cutting a release and cannot remember what happens next.

---

## The one-paragraph version

**The tag is the only input.** You never upload a zip, never edit a version
number, never touch the website. `git tag v1.2.3 && git push --tags` starts a
GitHub Actions run that builds the addon, attaches it to a GitHub Release, and
uploads it to CurseForge. The guild site reads the GitHub Release. Both channels
are fed by that one tag.

Use `release.ps1` rather than tagging by hand — it is a preflight that catches
the ways a tag silently produces nothing.

---

## The pipeline, end to end

```
  .\release.ps1 -Version 1.2.3 -Push
        |
        |  preflight (see below), then:
        |  git tag -a v1.2.3 && git push origin v1.2.3
        v
  GitHub sees a tag matching  v*
        |
        v
  .github/workflows/release.yml
        |  runs-on: ubuntu-latest
        |  uses: BigWigsMods/packager@v2
        |  env: GITHUB_OAUTH = secrets.GITHUB_TOKEN   (automatic)
        |       CF_API_KEY   = secrets.CF_API_KEY     (you set this)
        v
  BigWigsMods/packager
        |  1. checks out the TAG (not master)
        |  2. reads .pkgmeta
        |  3. pulls Libs/ fresh from upstream
        |        Libs/LibStub    <- repos.curseforge.com SVN mirror
        |        Libs/LibDeflate <- github.com/SafeteeWoW/LibDeflate
        |  4. deletes everything in .pkgmeta's `ignore` list
        |  5. substitutes @project-version@ in the TOC with "v1.2.3"
        |  6. zips the result as SGDDReserves-v1.2.3.zip
        |  7. reads ## X-Curse-Project-ID from the TOC  -> 1685978
        |  8. maps ## Interface: 120100 to a CurseForge game version
        |
        +--> GitHub Release  (zip + release.json)
        |         ^
        |         |  guild site: api.github.com/repos/JWK95/SGDDreserveext/releases/latest
        |         |  WowUp:      reads release.json for auto-update
        |
        +--> CurseForge project 1685978
                  ^
                  |  CurseForge app, WowUp, anyone searching the site
```

Two distribution channels, one tag, no manual step in either.

---

## CurseForge

### What the token is

A **CurseForge API token**, generated in your CurseForge account settings under
API Tokens. It is a long bcrypt-shaped string beginning `$2a$10$`.

It is shown **once**, at generation. There is no way to read it back. If you
lose it, generate a new one and replace the secret — that is cheap, and it is
always the right move when you are unsure.

### Where it lives

GitHub repository secret named exactly **`CF_API_KEY`**, at
`https://github.com/JWK95/SGDDreserveext/settings/secrets/actions`.

The name is not negotiable — `release.yml` references
`${{ secrets.CF_API_KEY }}`, and BigWigsMods/packager reads the environment
variable of that name. Renaming either without the other produces a silent
skip, not an error.

Setting it from the CLI, which keeps the value out of your shell history:

```bash
gh secret set CF_API_KEY --repo JWK95/SGDDreserveext
# paste the token at the prompt; it is not echoed and not stored in history
```

Or in the browser: Settings -> Secrets and variables -> Actions -> New
repository secret.

### Rotating it

Do this whenever the value has been anywhere it should not have been — a chat
window, a log, a screenshot, a file, a pasted command.

1. CurseForge -> Account Settings -> API Tokens -> **delete** the old token.
   Deleting is what actually revokes it; generating a new one does not disable
   the old one.
2. Generate a new token, copy it.
3. `gh secret set CF_API_KEY --repo JWK95/SGDDreserveext` and paste.
4. Cut any release, or re-run the last release workflow, and confirm the log
   says it uploaded.

Rotation costs two minutes. Deciding a leaked token is probably fine costs
whatever somebody does with publish rights to an addon your guild auto-updates.

### What "no token" looks like

The packager **warns and skips** the CurseForge upload when `CF_API_KEY` is
absent or empty. It does not fail the run. That is deliberate, and it is why
the workflow was committed long before the token existed — a tag still produces
the GitHub Release, which is the channel the guild site actually reads.

The consequence is that **a missing or wrong token is quiet**. The run is green
either way. The only way to know the upload happened is to read the log or look
at the project page.

---

## Cutting a release

### 1. Preflight

```powershell
.\release.ps1 -Version 1.2.3
```

This is a **dry run** and changes nothing. It checks nine things, and each one
of them is a way a release silently fails:

| # | Check | Why it exists |
| --- | --- | --- |
| 1 | Version is `MAJOR.MINOR.PATCH` | Pass `1.2.3`, not `v1.2.3` — the script adds the `v`. The workflow triggers on `v*`. |
| 2 | Inside a git work tree | — |
| 3 | Working tree is clean | A tag points at a **commit**. Uncommitted work is simply not in the release, silently. |
| 4 | In sync with origin | CI checks the tag out **from GitHub**. A tag on an unpushed commit builds something nobody can see. |
| 5 | `release.yml` and `.pkgmeta` are committed | Actions only runs workflows present **in the commit it checks out**. A tag with no workflow produces total silence — no run, no release, no error. |
| 6 | TOC still carries `@project-version@` | Without the token the addon ships reporting its version as the literal string. |
| 7 | `SGDDReserves.toc` and `build.ps1` list the same Lua files | See "The file list exists twice" below. |
| 8 | Tag is unused locally and on origin | Reusing a tag is the one thing that cannot be undone cleanly. |
| 9 | CI is green on this commit | Soft — warns rather than blocks, because a network failure here is not a reason to stop. |

### 2. Push it

```powershell
.\release.ps1 -Version 1.2.3 -Push
```

It asks you to type the version back before it does anything irreversible. The
tag is annotated (`git tag -a`), which is the only record of who cut the release
and when.

Add `-Wait` to poll the GitHub API until the release appears and list its
assets.

### 3. Verify both channels

**GitHub** — `https://github.com/JWK95/SGDDreserveext/releases`. Two assets:
`SGDDReserves-v1.2.3.zip` and `release.json`. Missing `release.json` means WowUp
falls back to filename sniffing, which still works for a retail-only addon but
is worth noticing.

**Actions log** — `https://github.com/JWK95/SGDDreserveext/actions`. Search the
packager step for `CurseForge`. You want a line saying it uploaded, with a file
id. A line saying it is skipping because no API key is set means `CF_API_KEY` is
missing, misnamed, or empty.

**CurseForge** — project 1685978's Files tab. The new file should be listed with
the right game version and marked Release.

---

## When it goes wrong

Each of these is either something that has bitten, or a stated assumption in
this repo that has not been exercised yet. The distinction is marked.

### The tag produced no Actions run at all

**Cause:** `.github/workflows/release.yml` is not in the tagged commit, or the
tag does not match `v*`.

Actions reads the workflow **from the commit being built**. Tagging a commit
that predates the workflow produces nothing — no run, no failure, no
notification. Preflight check 5 exists for exactly this.

**Fix:** delete the tag locally and on origin, tag a commit that contains the
workflow, push again.

```bash
git tag -d v1.2.3
git push origin :refs/tags/v1.2.3
```

### The GitHub release worked, CurseForge did not appear

Read the packager log first; it distinguishes these.

- **`CF_API_KEY` missing, empty, or misnamed** -> log says it is skipping the
  upload. This is a warning, not an error, and the run stays green.
- **Token revoked or wrong** -> an HTTP 401/403 from CurseForge.
- **Game version not recognised** -> the packager maps `## Interface: 120100` to
  a CurseForge game version. If CurseForge does not yet list that interface
  version, or the project does not have it enabled, the upload is rejected.
  Check the project's supported versions on its settings page.
- **Project not approved** -> a brand-new CurseForge project is not publishable
  until moderation has approved it. *Status unverified — check the project page
  before assuming the token is at fault.*

### The addon fails to load for everybody

**Cause:** a Lua file is listed in `SGDDReserves.toc` but not shipped, or the
reverse.

This is invisible until somebody installs the zip, because the file is present
on every development machine. See "The file list exists twice" below.

### `Libs/` is empty in the built addon

`.pkgmeta` pulls both libraries from upstream at package time; neither is
committed (`Libs/` is gitignored). Two upstreams, two failure modes:

- **`tag: latest` on LibDeflate** — *unverified assumption.* If the packager
  does not resolve `latest`, replace it with an explicit tag or drop the line to
  take the default branch.
- **LibStub's SVN mirror** — `repos.curseforge.com/wow/libstub/trunk` is
  long-standing convention but is somebody else's infrastructure. If it 404s,
  vendor LibStub into `Libs/` instead: it is about forty lines and it does not
  change.

Symptom in game: the addon errors on load, naming `LibStub` or `LibDeflate`.

### The TOC shows `@project-version@` as the version

The packager did not substitute. Either the token was edited out of the TOC
(preflight 6), or the build did not go through the packager at all — for
example, somebody hand-zipped `build.ps1`'s output and uploaded it.

### The addon shows as out of date for everyone

`## Interface: 120100` disagrees with the live client. *Unverified:* that number
was derived from Midnight being patch 12.1 and has not been confirmed against a
running client. Check it before a public release.

---

## The file list exists twice

Every shipped Lua file is named in **two** places, and they must agree:

1. `SGDDReserves.toc` — what WoW loads.
2. `build.ps1` — what the local packaging script copies.

Adding or removing a Lua file means editing **both**. A file in the TOC but not
in the package is an addon that fails to load for the whole guild, and it is
invisible until somebody installs the zip.

`release.ps1` check 7 compares them and refuses to release on a mismatch.

**Caveat:** `build.ps1` is gitignored — it is local packaging for testing, and
CI builds from `.pkgmeta` instead. So check 7 only runs on a machine that has
it. On a fresh clone the check degrades to a warning rather than an error, which
is worth knowing before trusting a green preflight on a new machine.

---

## Local builds

```powershell
.\build.ps1                    # dist\SGDDReserves\ and a zip
.\build.ps1 -Version 1.2.0
```

For hand-installing and for testing. **Not** what goes to CurseForge — that
always comes from the tagged CI build.

Two things `build.ps1` gets right that the obvious approaches get wrong, both
worth preserving if it is ever rewritten:

- **No BOM in the TOC.** Windows PowerShell 5.1's `Set-Content -Encoding UTF8`
  writes a byte order mark, and a BOM in front of `## Interface` stops WoW
  reading the first directive — the addon then shows as out of date, or does not
  appear at all.
- **Forward slashes in zip entry names.** Both `Compress-Archive` and .NET
  Framework's `ZipFile::CreateFromDirectory` write backslash separators on
  Windows, which `unzip` on Linux and macOS turns into files literally named
  `SGDDReserves\Core.lua`. The guild site serves this zip to whoever asks, so it
  has to unpack anywhere.

`build.ps1` copies whatever is in `Libs/` on disk, unlike the packager which
pulls from upstream. On a fresh clone `Libs/` is empty and the built addon will
not load.

---

## Rolling back

**You do not rewrite a tag.** Anyone who has already fetched it keeps the old
one, so a rewritten tag means two different builds sharing a version number.

To undo a bad release: **burn the version number and cut another.** Fix the
problem, ship `v1.2.4`. Optionally mark the bad GitHub release as a pre-release
or delete it, and on CurseForge delete or archive the bad file so the app stops
offering it.

---

## The local Lua toolchain

CI runs `luacheck .` and `busted --verbose` on every push. Running them locally
on Windows needs setup, because Lua for Windows ships LuaRocks 2.0.2 (2011) and
a 32-bit Lua 5.1.

- **32-bit matters.** `lua.exe` is x86, so any C module must be built x86. Build
  from an x86 developer prompt (`vcvarsall.bat x86`); an x64 build links fine
  and then fails to load.
- **`cl` is not on PATH** after installing Visual Studio. It only exists inside
  a developer environment.
- **LuaRocks 2.0.2 ignores `--local` and `--tree`** and insists on writing into
  `C:\Program Files (x86)\Lua\5.1\rocks`, which needs admin. Point
  `LUAROCKS_CONFIG` at a config file that redirects `rocks_trees` somewhere
  user-writable instead — no elevation needed. That is how `luacheck` was
  installed here.
- **`busted` will not install at all** on LuaRocks 2.0.2: it cannot parse modern
  rockspec dependency syntax and fails with
  `Parse error processing dependency 'lua_cliargs >= 3.0'`. This is not a
  compiler problem and installing MSVC does not fix it. Either upgrade LuaRocks
  to 3.x, or run the specs under plain `lua.exe` with a small shim — they use
  only `describe`, `it`, and nine `luassert` methods.
- **`luac -p` is the one that matters most.** `CLAUDE.md` requires every
  mutation test to compile before its "caught" is believed, and this repo has
  already produced a mutation that was only a syntax error. `luac -p <file>` is
  that check.
