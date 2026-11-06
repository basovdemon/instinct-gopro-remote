<#
.SYNOPSIS
  Drives the Connect IQ simulator's menu without clicking: lists menu items with their IDs,
  or sends one (WM_COMMAND). IDs are those of SDK 9.3.0 and may change with the simulator.
.EXAMPLE
  ./tools/sim_menu.ps1 -List -Filter "Data Fields|Language"   # find IDs
  ./tools/sim_menu.ps1 -Id 6075    # Settings > Language > Russian
  ./tools/sim_menu.ps1 -Id 6010    # Data Fields > Layout > 3 Fields B (layouts are 6007..6011 while a data field runs)
#>
param([switch]$List, [string]$Filter = ".", [int]$Id = 0)
$ErrorActionPreference = "Stop"
Add-Type @"
using System; using System.Text; using System.Runtime.InteropServices;
public class SimMenu {
 [DllImport("user32.dll")] public static extern IntPtr GetMenu(IntPtr h);
 [DllImport("user32.dll")] public static extern int GetMenuItemCount(IntPtr m);
 [DllImport("user32.dll")] public static extern IntPtr GetSubMenu(IntPtr m, int p);
 [DllImport("user32.dll")] public static extern uint GetMenuItemID(IntPtr m, int p);
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetMenuString(IntPtr m, uint id, StringBuilder s, int max, uint flag);
 [DllImport("user32.dll")] public static extern IntPtr PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
}
"@
$p = Get-Process simulator -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if ($null -eq $p) { throw "Simulator window not found (start it with ./tools/build.ps1 -Run)" }
$h = $p.MainWindowHandle
function Dump($m, $path) {
  $n = [SimMenu]::GetMenuItemCount($m)
  for ($i = 0; $i -lt $n; $i++) {
    $sb = New-Object System.Text.StringBuilder 256
    [SimMenu]::GetMenuString($m, [uint32]$i, $sb, 256, 0x400) | Out-Null   # MF_BYPOSITION
    $full = "$path/$($sb.ToString())"
    $itemId = [SimMenu]::GetMenuItemID($m, $i)
    if ($full -match $Filter) { "$full [id=$itemId]" }
    $sub = [SimMenu]::GetSubMenu($m, $i)
    if ($sub -ne [IntPtr]::Zero) { Dump $sub $full }
  }
}
if ($List) { Dump ([SimMenu]::GetMenu($h)) "" }
if ($Id -gt 0) { [SimMenu]::PostMessage($h, 0x0111, [IntPtr]$Id, [IntPtr]::Zero) | Out-Null }   # WM_COMMAND
