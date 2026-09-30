<#
Builds the release zip + SHA-256 hashes. Maintainer use only (not part of the distributed zip).
  .\build-release.ps1
Output: dist\LolObsSceneSwitcher-v<version>.zip and dist\RELEASE_HASHES.txt
The zip contains the source files as-is (no compiled binary), so the published
repository at the same git tag must hash identically file-by-file (SHA256SUMS.txt).
#>
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$version = '0.1.0'
$files = 'LolObsSceneSwitcher.ps1', 'Start-LolObsSceneSwitcher.bat', 'README.md', 'LICENSE', 'icon.ico'

$dist = Join-Path $root 'dist'
$stage = Join-Path $dist "LolObsSceneSwitcher-v$version"
if (Test-Path $dist) { Remove-Item $dist -Recurse -Force }
New-Item -ItemType Directory -Path $stage | Out-Null
foreach ($f in $files) { Copy-Item (Join-Path $root $f) $stage }

$sums = foreach ($f in $files) {
    "{0}  {1}" -f (Get-FileHash (Join-Path $stage $f) -Algorithm SHA256).Hash.ToLower(), $f
}
[IO.File]::WriteAllText((Join-Path $stage 'SHA256SUMS.txt'), (($sums -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))

$zip = Join-Path $dist "LolObsSceneSwitcher-v$version.zip"
Compress-Archive -Path $stage -DestinationPath $zip
$zipHash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()

$commit = ''
try { $commit = (git -C $root rev-parse HEAD 2>$null) } catch { }
@"
LolObsSceneSwitcher-v$version.zip
SHA-256: $zipHash
git commit: $commit
(Paste into the GitHub Release notes. Add the VirusTotal report URL after scanning the zip.)

Per-file SHA-256 (also in the zip as SHA256SUMS.txt):
$($sums -join "`n")
"@ | Set-Content (Join-Path $dist 'RELEASE_HASHES.txt') -Encoding UTF8
Get-Content (Join-Path $dist 'RELEASE_HASHES.txt')
