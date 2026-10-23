# Starts DOS2 Definitive Edition directly, skipping Larian's launcher (bin\SupportTool.exe), which needs the
# .NET Desktop Runtime 3.1 and fails silently without it. Steam must be running.
param([string]$GameDir = 'D:\SteamLibrary\steamapps\common\Divinity Original Sin 2')
$ErrorActionPreference = 'Stop'
$bin = Join-Path $GameDir 'DefEd\bin'
if (Get-Process EoCApp -ErrorAction SilentlyContinue) { Write-Host 'The game is already running.'; exit 0 }
Start-Process -FilePath (Join-Path $bin 'EoCApp.exe') -WorkingDirectory $bin
Write-Host "Started $bin\EoCApp.exe"
