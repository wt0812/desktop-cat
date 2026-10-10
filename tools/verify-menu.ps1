# Reads the cat's right-click menu straight out of the compiled form.
#
# Why: the menu is a user-visible surface that nothing else in the project
# checks. The tray/menu cannot be clicked by a script, but BuildMenu() runs in
# the constructor, so constructing the form offscreen and reading
# ContextMenuStrip.Items proves exactly which entries exist and what they say.
#
# Every entry is printed twice: as text and as code points. The console
# codepage can mangle CJK, the code points cannot -- U+6492 U+6B22 is the
# contract, whatever the terminal shows.
#
# This runs in its own process, never shows a window, and never touches the
# user's running cat.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$root = Split-Path -Parent $PSScriptRoot
$petPath = Join-Path $root "pet.ps1"

$raw = [System.IO.File]::ReadAllText($petPath, [System.Text.Encoding]::UTF8)
$s = $raw.IndexOf("@'"); $e = $raw.IndexOf("'@", $s + 2)
Add-Type -TypeDefinition $raw.Substring($s + 2, $e - $s - 2) -Language CSharp `
  -ReferencedAssemblies 'System.dll','System.Core.dll','System.Drawing.dll','System.Windows.Forms.dll' `
  -IgnoreWarnings -ErrorAction Stop
Write-Output "compiled pet.ps1 C# into this process"

$dataDir = Join-Path $root ".petdata-menutest"
Remove-Item $dataDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
$cfgPath = Join-Path $dataDir "config.json"

$form = New-Object DesktopCat.PetForm($root, $dataDir, $cfgPath)
Write-Output "PetForm constructed (never shown - nothing appears on screen)"

$flags = [System.Reflection.BindingFlags]::NonPublic -bor [System.Reflection.BindingFlags]::Instance
$mClip = $form.GetType().GetMethod("ClipCount", $flags, $null, @(), $null)
$clipCount = $mClip.Invoke($form, @())

$menu = $form.ContextMenuStrip
$entries = @()
Write-Output ""
Write-Output ("=== right-click menu: " + $menu.Items.Count + " top-level entries ===")
foreach ($it in $menu.Items) {
  $txt = $it.Text
  if ([string]::IsNullOrEmpty($txt)) {
    Write-Output "  (separator)"
    continue
  }
  $cps = (($txt.ToCharArray() | ForEach-Object { "U+{0:X4}" -f [int]$_ }) -join " ")
  $entries += $txt
  Write-Output ("  " + $txt + "      [" + $cps + "]")
  if ($it.DropDownItems.Count -gt 0) {
    foreach ($sub in $it.DropDownItems) {
      $scps = (($sub.Text.ToCharArray() | ForEach-Object { "U+{0:X4}" -f [int]$_ }) -join " ")
      $entries += ("SUB:" + $sub.Text)
      Write-Output ("      - " + $sub.Text + "   [" + $scps + "]")
    }
  }
}

$deleted = [string][char]0x7761 + [string][char]0x89C9   # the removed nap entry
$added   = [string][char]0x6492 + [string][char]0x6B22   # the entry that replaces it

$hasDeleted = $false; $hasAdded = $false
foreach ($t in $entries) {
  if ($t.Contains($deleted)) { $hasDeleted = $true }
  if ($t.Contains($added))   { $hasAdded = $true }
}

Write-Output ""
Write-Output ("ClipCount() = " + $clipCount + "            (expect 12)")
Write-Output ("top-level action entries = " + $menu.Items.Count)
Write-Output ("contains the removed nap entry = " + $hasDeleted + "   (expect False)")
Write-Output ("contains the new action entry  = " + $hasAdded + "   (expect True)")

$ok = ($clipCount -eq 12) -and (-not $hasDeleted) -and $hasAdded
Write-Output ""
if ($ok) { Write-Output "PASS" } else { Write-Output "FAIL" }

# leave nothing behind in the repo
try { $form.Close(); $form.Dispose() } catch { }
Remove-Item $dataDir -Recurse -Force -ErrorAction SilentlyContinue

if (-not $ok) { exit 1 }
