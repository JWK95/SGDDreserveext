# Cuts a release. Tag-driven: the tag IS the version.
#
#   .\release.ps1 -Version 0.1.0           # dry run - checks everything, changes nothing
#   .\release.ps1 -Version 0.1.0 -Push     # actually tags and pushes
#   .\release.ps1 -Version 0.1.0 -Push -Wait   # ...and waits for the release to appear
#
# WHAT A RELEASE ACTUALLY IS HERE
#
#   git push --tags
#         |   GitHub sees a tag matching  v*
#   .github/workflows/release.yml runs
#         |   BigWigsMods/packager checks out the TAG
#   packager reads .pkgmeta
#         |   pulls LibStub + LibDeflate fresh from upstream
#         |   substitutes @project-version@ in the TOC with the tag name
#         |   zips it, attaches the zip AND release.json to a GitHub Release
#   GitHub Release exists
#         |   guild site calls api.github.com/.../releases/latest
#   /addons serves the zip, and WowUp can auto-update from release.json
#
# You never upload a zip by hand, never bump a version in a file, and never
# touch the website. The tag is the only input. That is why the TOC carries the
# literal token @project-version@ rather than a number.
#
# DRY RUN IS THE DEFAULT ON PURPOSE. A pushed tag is effectively permanent:
# anyone who has already fetched it keeps it, so the fix for a bad release is
# always to burn the version number and cut another, never to rewrite one.

param(
	[Parameter(Mandatory = $true)]
	[string]$Version,

	# Without this the script only reports. Nothing is created or pushed.
	[switch]$Push,

	# After pushing, poll the GitHub API until the release appears.
	[switch]$Wait
)

$ErrorActionPreference = "Stop"

$repoSlug = "JWK95/SGDDreserveext"
$tag = "v$Version"
$problems = @()
$warnings = @()

function Ok    ($m) { Write-Host "  [ ok ] $m" }
function Bad   ($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red;    $script:problems += $m }
function Warn  ($m) { Write-Host "  [warn] $m" -ForegroundColor Yellow; $script:warnings += $m }

Write-Host ""
Write-Host "  Release preflight for $tag"
Write-Host "  ---------------------------------------------------------------"

# 1 - Version shape. The workflow triggers on "v*", and the leading v matters.
if ($Version -match '^\d+\.\d+\.\d+$') {
	Ok "version '$Version' is MAJOR.MINOR.PATCH"
} else {
	Bad "version '$Version' is not MAJOR.MINOR.PATCH (pass 0.1.0, not v0.1.0)"
}

# 2 - Are we even in the repo.
git rev-parse --is-inside-work-tree *> $null
if ($LASTEXITCODE -ne 0) { Bad "not inside a git work tree"; }

# 3 - Clean tree. The tag points at a COMMIT: anything uncommitted is simply
#     not in the release, and that is silent rather than loud.
$dirty = git status --porcelain
if ([string]::IsNullOrWhiteSpace($dirty)) {
	Ok "working tree is clean"
} else {
	Bad "working tree has uncommitted changes - they will NOT be in the release"
	$dirty -split "`n" | Select-Object -First 10 | ForEach-Object { Write-Host "         $_" }
}

# 4 - In sync with the remote. CI checks out the tag FROM GITHUB, so a tag on a
#     commit that was never pushed builds something nobody can see.
$upstream = git rev-parse --abbrev-ref --symbolic-full-name "@{u}" 2>$null
if ($LASTEXITCODE -ne 0) {
	Bad "this branch has no upstream - push it first"
} else {
	git fetch --quiet origin
	$counts = (git rev-list --left-right --count "HEAD...@{u}") -split "\s+"
	$ahead = [int]$counts[0]
	$behind = [int]$counts[1]
	if ($ahead -eq 0 -and $behind -eq 0) {
		Ok "in sync with $upstream"
	} elseif ($ahead -gt 0) {
		Bad "$ahead commit(s) not pushed - push before tagging"
	} else {
		Bad "$behind commit(s) behind $upstream - pull before tagging"
	}
}

# 5 - The release machinery has to exist ON GITHUB, in the tagged commit.
#     This is the trap: Actions only runs workflows present in the commit it
#     checks out, so a tag with no workflow produces total silence - no run, no
#     release, no error.
foreach ($needed in @(".github/workflows/release.yml", ".pkgmeta")) {
	git cat-file -e "HEAD:$needed" 2>$null
	if ($LASTEXITCODE -eq 0) {
		Ok "$needed is committed"
	} else {
		Bad "$needed is NOT committed - a tag would do nothing at all"
	}
}

# 6 - The TOC must still carry the substitution token, or the addon ships
#     reporting its version as the literal string "@project-version@".
$toc = Get-Content "SGDDReserves.toc" -Raw
if ($toc -match [regex]::Escape("@project-version@")) {
	Ok "TOC carries the @project-version@ token"
} else {
	Bad "TOC has no @project-version@ token - the packager has nothing to substitute"
}

# 7 - The shipped-file list exists twice and the two must agree. A file in the
#     TOC but not in the package is an addon that fails to load for the whole
#     guild, and it is invisible until somebody installs the zip.
$tocFiles = Select-String -Path "SGDDReserves.toc" -Pattern '^[A-Za-z][A-Za-z0-9_]*\.lua\s*$' |
	ForEach-Object { $_.Line.Trim() } | Sort-Object
if (Test-Path "build.ps1") {
	$pkgFiles = Select-String -Path "build.ps1" -Pattern '^\s*"([A-Za-z][A-Za-z0-9_]*\.lua)"' |
		ForEach-Object { $_.Matches[0].Groups[1].Value } | Sort-Object
	$diff = Compare-Object $tocFiles $pkgFiles
	if ($null -eq $diff) {
		Ok "SGDDReserves.toc and build.ps1 agree ($($tocFiles.Count) files)"
	} else {
		Bad "SGDDReserves.toc and build.ps1 disagree:"
		$diff | ForEach-Object {
			$where = if ($_.SideIndicator -eq "<=") { "TOC only" } else { "build.ps1 only" }
			Write-Host "         $($_.InputObject)  ($where)"
		}
	}
} else {
	Warn "build.ps1 not found - skipping the two-manifest check"
}

# 8 - Has this version already been used? Reusing a tag is the one thing that
#     genuinely cannot be undone cleanly.
$localTag = git tag -l $tag
if (-not [string]::IsNullOrWhiteSpace($localTag)) { Bad "tag $tag already exists locally" }
$remoteTag = git ls-remote --tags origin $tag 2>$null
if (-not [string]::IsNullOrWhiteSpace($remoteTag)) { Bad "tag $tag already exists on origin" }
if ([string]::IsNullOrWhiteSpace($localTag) -and [string]::IsNullOrWhiteSpace($remoteTag)) {
	Ok "tag $tag is unused"
}

# 9 - Did CI pass on the commit being tagged? Soft: a network problem here is
#     not a reason to block a release, so it warns rather than fails.
try {
	[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
	$sha = (git rev-parse HEAD).Trim()
	$headers = @{ "User-Agent" = "sgddreserves-release-script" }
	$runs = Invoke-RestMethod -Headers $headers -TimeoutSec 15 `
		-Uri "https://api.github.com/repos/$repoSlug/commits/$sha/check-runs"
	if ($runs.total_count -eq 0) {
		Warn "no CI checks found for this commit yet"
	} else {
		$bad = @($runs.check_runs | Where-Object { $_.conclusion -and $_.conclusion -ne "success" })
		if ($bad.Count -eq 0) {
			Ok "CI is green on this commit ($($runs.total_count) check(s))"
		} else {
			Bad "CI is not green: $(($bad | ForEach-Object { $_.name + '=' + $_.conclusion }) -join ', ')"
		}
	}
} catch {
	Warn "could not reach the GitHub API to check CI ($($_.Exception.Message))"
}

Write-Host "  ---------------------------------------------------------------"

if ($problems.Count -gt 0) {
	Write-Host ""
	Write-Host "  $($problems.Count) problem(s). Nothing was changed." -ForegroundColor Red
	Write-Host ""
	exit 1
}

if ($warnings.Count -gt 0) { Write-Host "  $($warnings.Count) warning(s), none blocking." -ForegroundColor Yellow }

if (-not $Push) {
	Write-Host ""
	Write-Host "  Preflight passed. This was a DRY RUN - nothing was created."
	Write-Host "  To release for real:"
	Write-Host ""
	Write-Host "      .\release.ps1 -Version $Version -Push"
	Write-Host ""
	exit 0
}

# ------------------------------------------------------------------------------
# The irreversible part
# ------------------------------------------------------------------------------

Write-Host ""
Write-Host "  About to tag $(git rev-parse --short HEAD) as $tag and push to origin."
Write-Host "  A pushed tag cannot be cleanly recalled." -ForegroundColor Yellow
$answer = Read-Host "  Type the version ($Version) to confirm"
if ($answer -ne $Version) {
	Write-Host "  Cancelled. Nothing was changed."
	exit 1
}

# Annotated, not lightweight: an annotated tag records who cut the release and
# when, which is the only place that information exists afterwards.
git tag -a $tag -m "Release $tag"
if ($LASTEXITCODE -ne 0) { throw "git tag failed" }

git push origin $tag
if ($LASTEXITCODE -ne 0) { throw "git push failed - the local tag exists; delete it with: git tag -d $tag" }

Write-Host ""
Write-Host "  Pushed $tag."
Write-Host "  Watch:    https://github.com/$repoSlug/actions"
Write-Host "  Releases: https://github.com/$repoSlug/releases"
Write-Host ""
Write-Host "  Expect a CurseForge warning in the log - CF_API_KEY is not set and"
Write-Host "  the packager skips that upload. The GitHub release still happens,"
Write-Host "  and that is the one the guild site and WowUp read."

if (-not $Wait) { exit 0 }

Write-Host ""
Write-Host "  Waiting for the release to appear (up to 5 minutes)..."
$headers = @{ "User-Agent" = "sgddreserves-release-script" }
for ($i = 1; $i -le 30; $i++) {
	Start-Sleep -Seconds 10
	try {
		$rel = Invoke-RestMethod -Headers $headers -TimeoutSec 15 `
			-Uri "https://api.github.com/repos/$repoSlug/releases/tags/$tag"
		Write-Host ""
		Write-Host "  Released: $($rel.tag_name)"
		foreach ($a in $rel.assets) {
			Write-Host ("    {0,-40} {1,8:N0} bytes" -f $a.name, $a.size)
		}
		$hasJson = @($rel.assets | Where-Object { $_.name -eq "release.json" }).Count -gt 0
		if ($hasJson) {
			Write-Host "  release.json present - WowUp install-from-URL will work."
		} else {
			Write-Host "  NOTE: no release.json asset. WowUp auto-update will fall back to" -ForegroundColor Yellow
			Write-Host "        filename sniffing, which still works for retail-only addons."
		}
		Write-Host ""
		exit 0
	} catch {
		Write-Host "    still building... ($i/30)"
	}
}

Write-Host ""
Write-Host "  Gave up waiting. The build may still be running - check the Actions tab."
exit 0
