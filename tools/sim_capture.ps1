<#
.SYNOPSIS
  Saves the Connect IQ simulator window to a PNG. Works without focus (PrintWindow).
.EXAMPLE
  ./tools/sim_capture.ps1 -Out layout.png
#>
param([Parameter(Mandatory)][string]$Out)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class SimWin {
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
  public struct RECT { public int Left, Top, Right, Bottom; }
}
"@
$p = Get-Process simulator -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if ($null -eq $p) { throw "Simulator window not found (start it with ./tools/build.ps1 -Run)" }
$h = $p.MainWindowHandle
$r = New-Object SimWin+RECT
[SimWin]::GetWindowRect($h, [ref]$r) | Out-Null
$bmp = New-Object System.Drawing.Bitmap ($r.Right - $r.Left), ($r.Bottom - $r.Top)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$dc = $g.GetHdc()
# 2 = PW_RENDERFULLCONTENT
[SimWin]::PrintWindow($h, $dc, 2) | Out-Null
$g.ReleaseHdc($dc)
# .NET resolves relative paths against its own current directory, not PowerShell's.
$bmp.Save($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Out))
$g.Dispose()
$bmp.Dispose()
