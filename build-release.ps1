<#
Builds the release zip + SHA-256 hashes. Maintainer use only (not part of the distributed zip).
  .\build-release.ps1
Output: dist\LolObsSceneSwitcher-v<version>.zip and dist\RELEASE_HASHES.txt
The zip contains the source files as-is (no compiled binary), so the published
repository at the same git tag must hash identically file-by-file (SHA256SUMS.txt).
Release builds require a clean working tree (everything committed): the build STOPS if
`git status --porcelain` reports anything (modified or untracked files; dist/ is git-ignored).
The git commit is recorded in RELEASE_HASHES.txt, so a zip always maps to exactly one commit.
  -AllowDirty  local testing only. The zip is named "...-DIRTY-NOT-FOR-RELEASE.zip".
#>
[CmdletBinding()]
param([switch]$AllowDirty)
$ErrorActionPreference = 'Stop'

# --- Release gate: clean tree + known commit --------------------------------
$commit = (git -C $PSScriptRoot rev-parse HEAD 2>$null)
if (-not $commit) { throw 'Not a git repository (or git is not installed). Cannot record the commit; aborting.' }
$dirtyList = @(git -C $PSScriptRoot status --porcelain 2>$null)
$isDirty = $dirtyList.Count -gt 0
if ($isDirty -and -not $AllowDirty) {
    throw ("Working tree is not clean. Commit your changes first, then build.`n" + ($dirtyList -join "`n"))
}
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$root = $PSScriptRoot
$version = '0.1.1'
$guide = 'はじめに読んでください.txt'
$files = 'LolObsSceneSwitcher.ps1', 'Start-LolObsSceneSwitcher.bat', $guide, 'README.md', 'LICENSE', 'icon.ico'

$dist = Join-Path $root 'dist'
$folder = "LolObsSceneSwitcher-v$version"
$stage = Join-Path $dist $folder
if (Test-Path $dist) { Remove-Item $dist -Recurse -Force }
New-Item -ItemType Directory -Path $stage | Out-Null
foreach ($f in $files) { Copy-Item (Join-Path $root $f) $stage }

$sums = foreach ($f in $files) {
    "{0}  {1}" -f (Get-FileHash (Join-Path $stage $f) -Algorithm SHA256).Hash.ToLower(), $f
}
[IO.File]::WriteAllText((Join-Path $stage 'SHA256SUMS.txt'), (($sums -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))

# Compress-Archive (Windows PowerShell 5.1) writes backslash paths and non-UTF-8 names, which breaks
# Japanese file names in some extractors. Write entries with "/" separators via .NET instead.
$zipName = if ($isDirty) { "LolObsSceneSwitcher-v$version-DIRTY-NOT-FOR-RELEASE.zip" } else { "LolObsSceneSwitcher-v$version.zip" }
$zip = Join-Path $dist $zipName
$za = [IO.Compression.ZipFile]::Open($zip, 'Create')
try {
    foreach ($f in ($files + 'SHA256SUMS.txt')) {
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($za, (Join-Path $stage $f), "$folder/$f", 'Optimal') | Out-Null
    }
} finally { $za.Dispose() }
$zipHash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()

$dirty = if ($isDirty) { 'WARNING: built from a DIRTY tree. NOT FOR RELEASE.' } else { '' }
@"
$zipName
SHA-256: $zipHash
git commit: $commit
$dirty
(Paste into the GitHub Release notes. Add the VirusTotal report URL after scanning the zip.)

Per-file SHA-256 (also in the zip as SHA256SUMS.txt):
$($sums -join "`n")
"@ | Set-Content (Join-Path $dist 'RELEASE_HASHES.txt') -Encoding UTF8
Get-Content (Join-Path $dist 'RELEASE_HASHES.txt')
