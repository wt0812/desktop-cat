# Verifies the new stats & credits window actually opens.
#
# The tray menu cannot be clicked by a script, so this compiles the same C# that
# pet.ps1 compiles, builds a PetForm, calls ShowInfo() by reflection, and then
# looks for the resulting window by title.
#
# This runs in its own process and never touches the user's running cat.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$root = Split-Path -Parent $PSScriptRoot
$petPath = Join-Path $root "pet.ps1"

$raw = [System.IO.File]::ReadAllText($petPath, [System.Text.Encoding]::UTF8)
$s = $raw.IndexOf("@'"); $e = $raw.IndexOf("'@", $s + 2)
$cs = $raw.Substring($s + 2, $e - $s - 2)

Add-Type -TypeDefinition $cs -Language CSharp `
  -ReferencedAssemblies 'System.dll','System.Core.dll','System.Drawing.dll','System.Windows.Forms.dll' `
  -IgnoreWarnings -ErrorAction Stop
Write-Output "compiled the pet's own C# into this process"

$dataDir = Join-Path $root ".petdata-infotest"
Remove-Item $dataDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
$cfgPath = Join-Path $dataDir "config.json"

$form = New-Object DesktopCat.PetForm($root, $dataDir, $cfgPath)
Write-Output "PetForm constructed"

# ClipCount is private; read it to prove all 12 clips are registered in code.
$mClip = $form.GetType().GetMethod("ClipCount", [System.Reflection.BindingFlags]::NonPublic -bor [System.Reflection.BindingFlags]::Instance)
$clipCount = $mClip.Invoke($form, @())
Write-Output ("ClipCount() = " + $clipCount + "   (expect 12)")

$mTier = $form.GetType().GetMethod("TierName", [System.Reflection.BindingFlags]::NonPublic -bor [System.Reflection.BindingFlags]::Instance)
Write-Output ("TierName()  = '" + $mTier.Invoke($form, @()) + "'   (expect the first tier)")

$mInfo = $form.GetType().GetMethod("ShowInfo", [System.Reflection.BindingFlags]::NonPublic -bor [System.Reflection.BindingFlags]::Instance)
$mInfo.Invoke($form, @())
Write-Output "ShowInfo() invoked"

# pump messages so the non-modal form is created and shown
$cs2 = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public class WinFind {
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  public struct RECT { public int L, T, R, B; }
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  public static List<string> Titled(string contains) {
    var res = new List<string>();
    EnumWindows((h, p) => {
      var t = new StringBuilder(512); GetWindowText(h, t, 512);
      string s = t.ToString();
      if (s.Length > 0 && s.Contains(contains)) {
        RECT r; GetWindowRect(h, out r);
        res.Add("'" + s + "' visible=" + IsWindowVisible(h) + " " + (r.R-r.L) + "x" + (r.B-r.T));
      }
      return true;
    }, IntPtr.Zero);
    return res;
  }
}
'@
Add-Type -TypeDefinition $cs2 -Language CSharp -ReferencedAssemblies 'System' -ErrorAction Stop

$sw = [System.Diagnostics.Stopwatch]::StartNew()
while ($sw.ElapsedMilliseconds -lt 2500) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 20 }

Write-Output ""
Write-Output "=== windows titled 'Desktop Cat' ==="
$found = [WinFind]::Titled("Desktop Cat")
if ($found.Count -eq 0) { Write-Output "  NONE - the stats window did not open" }
else { $found | ForEach-Object { Write-Output ("  " + $_) } }

Write-Output ""
Write-Output "=== windows titled 'stats' ==="
$found2 = [WinFind]::Titled("stats")
if ($found2.Count -eq 0) { Write-Output "  NONE" } else { $found2 | ForEach-Object { Write-Output ("  " + $_) } }

Write-Output ""
if ($clipCount -eq 12 -and $found2.Count -gt 0) {
  Write-Output "RESULT: PASS - 12 clips registered and the stats/credits window opened."
} else {
  Write-Output "RESULT: FAIL"
}

try { $form.Close(); $form.Dispose() } catch { }
Remove-Item $dataDir -Recurse -Force -ErrorAction SilentlyContinue
