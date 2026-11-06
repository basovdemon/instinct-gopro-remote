<#
.SYNOPSIS
  Presses a key in the Connect IQ simulator window (to drive the app without clicking).
.EXAMPLE
  ./tools/sim_key.ps1            # Enter = START
  ./tools/sim_key.ps1 -Vk 0x28   # any other virtual-key code
#>
param([int]$Vk = 0x0D)
$ErrorActionPreference = "Stop"
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class SimKey {
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
}
"@
$p = Get-Process simulator -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if ($null -eq $p) { throw "Simulator window not found (start it with ./tools/build.ps1 -Run)" }
[SimKey]::SetForegroundWindow($p.MainWindowHandle) | Out-Null
Start-Sleep -Milliseconds 300
# WM_KEYDOWN, then WM_KEYUP
[SimKey]::PostMessage($p.MainWindowHandle, 0x100, [IntPtr]$Vk, [IntPtr]0) | Out-Null
Start-Sleep -Milliseconds 100
[SimKey]::PostMessage($p.MainWindowHandle, 0x101, [IntPtr]$Vk, [IntPtr]0) | Out-Null
