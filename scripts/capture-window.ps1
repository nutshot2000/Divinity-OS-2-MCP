param(
  [Parameter(Mandatory=$true)][string]$OutputFile,
  [int]$MaxWidth=1280
)
# Captures the DOS2 window. PrintWindow first; DirectX windows often come back black, so fall back to copying the
# window's area of the screen (the game must be visible, windowed or borderless).
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class Dos2WindowCapture {
  [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left,Top,Right,Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct Point { public int X,Y; }
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out Rect r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref Point p);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
'@
# Without this, display scaling (e.g. 125%) makes Windows report a scaled-down client size and the capture is cropped.
[void][Dos2WindowCapture]::SetProcessDPIAware()
$game=@(Get-Process | Where-Object { $_.ProcessName -match '^EoCApp' -and $_.MainWindowHandle -ne 0 })
if ($game.Count -ne 1) { throw "Expected one Divinity: Original Sin 2 window (EoCApp); found $($game.Count)." }
$game=$game[0]
$handle=$game.MainWindowHandle
if ([Dos2WindowCapture]::IsIconic($handle)) { throw 'The game is minimized. Restore the window and retry.' }
$rect=New-Object Dos2WindowCapture+Rect
if (![Dos2WindowCapture]::GetClientRect($handle,[ref]$rect)) { throw 'Cannot read the game window bounds.' }
$width=$rect.Right-$rect.Left; $height=$rect.Bottom-$rect.Top
if ($width -lt 100 -or $height -lt 100) { throw "Invalid game window size: ${width}x${height}" }

function Test-Blank($bmp) {
  $colors=New-Object 'System.Collections.Generic.HashSet[int]'
  for ($x=0; $x -lt $bmp.Width; $x+=[Math]::Max(1,[int]($bmp.Width/32))) {
    for ($y=0; $y -lt $bmp.Height; $y+=[Math]::Max(1,[int]($bmp.Height/32))) { [void]$colors.Add($bmp.GetPixel($x,$y).ToArgb()) }
  }
  return $colors.Count -lt 8
}

$bitmap=New-Object System.Drawing.Bitmap($width,$height)
$method='PrintWindow'
try {
  $graphics=[System.Drawing.Graphics]::FromImage($bitmap)
  try {
    $dc=$graphics.GetHdc()
    try { [void][Dos2WindowCapture]::PrintWindow($handle,$dc,3) } finally { $graphics.ReleaseHdc($dc) }
    if (Test-Blank $bitmap) {
      $origin=New-Object Dos2WindowCapture+Point
      [void][Dos2WindowCapture]::ClientToScreen($handle,[ref]$origin)
      $graphics.CopyFromScreen($origin.X,$origin.Y,0,0,(New-Object System.Drawing.Size($width,$height)))
      $method='CopyFromScreen'
    }
  } finally { $graphics.Dispose() }
  if (Test-Blank $bitmap) { throw 'Game capture is blank. Bring the game to the front in windowed or borderless mode and retry.' }
  $outWidth=[Math]::Min($MaxWidth,$width); $outHeight=[Math]::Max(1,[int]($height*$outWidth/$width))
  $output=New-Object System.Drawing.Bitmap($outWidth,$outHeight)
  try {
    $g=[System.Drawing.Graphics]::FromImage($output)
    try { $g.InterpolationMode=[System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic; $g.DrawImage($bitmap,0,0,$outWidth,$outHeight) }
    finally { $g.Dispose() }
    $output.Save($OutputFile,[System.Drawing.Imaging.ImageFormat]::Png)
  } finally { $output.Dispose() }
  @{width=$outWidth;height=$outHeight;source_width=$width;source_height=$height;capture=$method} | ConvertTo-Json -Compress
} finally { $bitmap.Dispose() }
