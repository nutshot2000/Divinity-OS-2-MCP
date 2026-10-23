# Brings the game window to the front so screen-control clicks and keys reach it. Windows refuses
# SetForegroundWindow from a background process unless the last input came from it, so tap Alt first (the usual
# workaround), then restore and focus the window. Prints whether the game is now in front.
$ErrorActionPreference = 'Stop'
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class GameFocus {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
}
'@
$game = Get-Process EoCApp -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $game) { throw 'The game is not running.' }
$h = $game.MainWindowHandle
[GameFocus]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)      # Alt down
[GameFocus]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)      # Alt up
[void][GameFocus]::ShowWindow($h, 9)                        # restore if minimised
[void][GameFocus]::SetForegroundWindow($h)
Start-Sleep -Milliseconds 300
[GameFocus]::GetForegroundWindow() -eq $h
