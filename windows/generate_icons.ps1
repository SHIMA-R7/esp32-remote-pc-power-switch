param(
  [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\assets')
)

Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class PowerIconNativeMethods {
  [DllImport("user32.dll", SetLastError = true)]
  public static extern bool DestroyIcon(IntPtr hIcon);
}
"@

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

function New-PowerStateIcon([string]$Path, [string]$Label, [System.Drawing.Color]$Color) {
  $bitmap = [System.Drawing.Bitmap]::new(64, 64)
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $graphics.Clear([System.Drawing.Color]::Transparent)

  $background = [System.Drawing.SolidBrush]::new($Color)
  $graphics.FillEllipse($background, 3, 3, 58, 58)

  $fontSize = if ($Label.Length -gt 2) { 12 } else { 15 }
  $font = [System.Drawing.Font]::new('Segoe UI', $fontSize, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
  $textBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::White)
  $format = [System.Drawing.StringFormat]::new()
  $format.Alignment = [System.Drawing.StringAlignment]::Center
  $format.LineAlignment = [System.Drawing.StringAlignment]::Center
  $graphics.DrawString($Label, $font, $textBrush, [System.Drawing.RectangleF]::new(4, 4, 56, 56), $format)

  $iconHandle = $bitmap.GetHicon()
  $icon = [System.Drawing.Icon]::FromHandle($iconHandle)
  $stream = [System.IO.File]::Create($Path)
  try { $icon.Save($stream) } finally { $stream.Dispose() }

  [void][PowerIconNativeMethods]::DestroyIcon($iconHandle)
  $icon.Dispose()
  $format.Dispose()
  $textBrush.Dispose()
  $font.Dispose()
  $background.Dispose()
  $graphics.Dispose()
  $bitmap.Dispose()
}

New-PowerStateIcon (Join-Path $OutputDirectory 'power_on.ico') 'ON' ([System.Drawing.Color]::FromArgb(30, 145, 82))
New-PowerStateIcon (Join-Path $OutputDirectory 'power_off.ico') 'OFF' ([System.Drawing.Color]::FromArgb(76, 86, 100))
