# Diagnostic: does calling SetState() actually change the state, and does calling
# OnPaint() actually advance the animation clip?
#
# This exists because the offscreen harness produced a silhouette that matched
# clipPet while the state had been set to Sleep. Before trusting ANY offscreen
# measurement, the harness itself has to be shown to be honest.

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

$dataDir = Join-Path $root ".petdata-probe"
Remove-Item $dataDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
$form = New-Object DesktopCat.PetForm($root, $dataDir, (Join-Path $dataDir "config.json"))

$ff = [System.Reflection.BindingFlags]::NonPublic -bor [System.Reflection.BindingFlags]::Instance
$mSetState = $form.GetType().GetMethod("SetState", $ff, $null, @([DesktopCat.PetState], [int], [bool]), $null)
$mOnPaint  = $form.GetType().GetMethod("OnPaint", $ff, $null, @([System.Windows.Forms.PaintEventArgs]), $null)
$fState    = $form.GetType().GetField("state", $ff)
$fPlayer   = $form.GetType().GetField("player", $ff)
$fScale    = $form.GetType().GetField("spriteScale", $ff)
$fGate     = $form.GetType().GetField("reactionGateMs", $ff)
$fRG       = $form.GetType().GetField("reactionGateMs", $ff)

Write-Output ("state right after construction : " + $fState.GetValue($form))
Write-Output ("reactionGateMs                 : " + $fRG.GetValue($form))

$mSetState.Invoke($form, [object[]]@([DesktopCat.PetState]::Sleep, [int]8000, [bool]$true)) | Out-Null
Write-Output ("state right after SetState(Sleep,8000,true) : " + $fState.GetValue($form))
Write-Output ""

$player = $fPlayer.GetValue($form)
$fClip = $player.GetType().GetField("Clip")
$fFrame = $player.GetType().GetField("Frame")
foreach ($nm in @('clipSleep','clipPet','clipIdle')) {
  Write-Output ("  " + $nm + " bmp0 = " + $form.GetType().GetField($nm, $ff).GetValue($form).GetType().GetField("Frames").GetValue($form.GetType().GetField($nm, $ff).GetValue($form))[0].GetType().GetField("Bmp").GetValue($form.GetType().GetField($nm, $ff).GetValue($form).GetType().GetField("Frames").GetValue($form.GetType().GetField($nm, $ff).GetValue($form))[0]).Width)
}
Write-Output ""
Write-Output "iter | state      | clipWidth | frame | spriteScale"
$W = 340; $H = 460
for ($i = 0; $i -lt 14; $i++) {
  $bmp = New-Object System.Drawing.Bitmap($W, $H)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.Clear([System.Drawing.Color]::FromArgb(255, 90, 96, 106))
  $rect = New-Object System.Drawing.Rectangle(0, 0, $W, $H)
  $pe = New-Object System.Windows.Forms.PaintEventArgs($g, $rect)
  $mOnPaint.Invoke($form, [object[]]@([System.Windows.Forms.PaintEventArgs]$pe)) | Out-Null
  $g.Dispose()
  $clip = $fClip.GetValue($player)
  $cw = if ($clip) { $clip.GetType().GetField("Frames").GetValue($clip)[0].GetType().GetField("Bmp").GetValue($clip.GetType().GetField("Frames").GetValue($clip)[0]).Width } else { -1 }
  Write-Output ("  " + $i.ToString().PadLeft(2) + " | " + $fState.GetValue($form).ToString().PadRight(10) + " | " +
                $cw.ToString().PadLeft(9) + " | " + $fFrame.GetValue($player).ToString().PadLeft(5) + " | " + $fScale.GetValue($form))
  $bmp.Dispose()
  Start-Sleep -Milliseconds 60
}

try { $form.Close(); $form.Dispose() } catch { }
Remove-Item $dataDir -Recurse -Force -ErrorAction SilentlyContinue
