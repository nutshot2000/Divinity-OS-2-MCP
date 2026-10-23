param(
  # LSLib's command-line packer (https://github.com/Norbyte/lslib/releases): Tools\Divine.exe
  [string]$Divine = $env:DIVINE_EXE,
  # The game's Mods folder in Documents (or OneDrive\Documents)
  [string]$ModsDir = ''
)
# Packs mod/ into DOS2Bridge.pak and copies it to the game's Mods folder. Enable "DOS2 Bridge" in the game's
# Mods menu afterwards. Re-run after every Lua change, then type `reset` in the extender console or reload a save.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $Divine) { $Divine = Join-Path $root 'tools\lslib\Packed\Tools\Divine.exe' }
if (-not (Test-Path $Divine)) {
  throw 'Divine.exe not found. Download LSLib, then pass -Divine <path to Divine.exe> or set DIVINE_EXE.'
}
if (-not $ModsDir) {
  $sub = 'Larian Studios\Divinity Original Sin 2 Definitive Edition\Mods'
  $ModsDir = @("$env:USERPROFILE\Documents\$sub", "$env:USERPROFILE\OneDrive\Documents\$sub") |
    Where-Object { Test-Path $_ } | Select-Object -First 1
  if (-not $ModsDir) { throw 'Game Mods folder not found. Run the game once, or pass -ModsDir.' }
}
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force $dist | Out-Null
$pak = Join-Path $dist 'DOS2Bridge_313216a1-9eda-4f4d-bb10-8a18437d473b.pak'
# Remove the pak name used by earlier versions of this script, so the game does not see two copies.
Remove-Item (Join-Path $ModsDir 'DOS2Bridge.pak') -ErrorAction SilentlyContinue
& $Divine -g dos2de -a create-package -s (Join-Path $root 'mod') -d $pak
if ($LASTEXITCODE -ne 0) { throw "Divine.exe failed with exit code $LASTEXITCODE" }
Copy-Item $pak $ModsDir -Force
Write-Host "Installed $pak to $ModsDir"
