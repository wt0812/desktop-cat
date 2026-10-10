# Renders every animation state OFFSCREEN to a contact sheet PNG.
#
# Why: the agent cannot screenshot the real desktop usefully (CopyFromScreen is
# broken on this machine, and PrintWindow cannot capture the pet's layered
# window reliably). But OnPaint() can simply be called by reflection with a
# Graphics of our own, which draws exactly the same pixels the window would --
# with two advantages: nothing appears on screen, and we control the backdrop.
#
# The backdrop is deliberately mid-grey, NOT the pet's magic transparency colour.
# Any surviving background inside the art then shows up as a dark blob, which is
# how we check that the GIF background punch-out actually worked.
#
# The pet's own constructor is still used (so every field is initialised the way
# the real app initialises it), but the form is never Show()n.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$root = Split-Path -Parent $PSScriptRoot
$petPath = Join-Path $root "pet.ps1"
$outDir  = Join-Path $root "tools\state-caps"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

$raw = [System.IO.File]::ReadAllText($petPath, [System.Text.Encoding]::UTF8)
$s = $raw.IndexOf("@'"); $e = $raw.IndexOf("'@", $s + 2)
$cs = $raw.Substring($s + 2, $e - $s - 2)
Add-Type -TypeDefinition $cs -Language CSharp `
  -ReferencedAssemblies 'System.dll','System.Core.dll','System.Drawing.dll','System.Windows.Forms.dll' `
  -IgnoreWarnings -ErrorAction Stop
Write-Output "compiled pet.ps1 C# into this process"

$dataDir = Join-Path $root ".petdata-caps"
Remove-Item $dataDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
$cfgPath = Join-Path $dataDir "config.json"

$form = New-Object DesktopCat.PetForm($root, $dataDir, $cfgPath)
Write-Output "PetForm constructed (never shown - nothing appears on screen)"

$flags = [System.Reflection.BindingFlags]::NonPublic -bor [System.Reflection.BindingFlags]::Instance
$mSetState = $form.GetType().GetMethod("SetState", $flags, $null,
              @([DesktopCat.PetState], [int], [bool]), $null)
$mOnPaint  = $form.GetType().GetMethod("OnPaint", $flags, $null,
              @([System.Windows.Forms.PaintEventArgs]), $null)
if ($null -eq $mSetState) { throw "SetState not found" }
if ($null -eq $mOnPaint)  { throw "OnPaint not found" }
Write-Output "reflection hooks OK (SetState, OnPaint)"

$W = 340; $H = 460
$states = @('Idle','Happy','Stretch','Play','Dancing','Cheer','Sad','Surprise','Talking','Reminder','Game')

# Backdrop the sprite is composited onto.
$BACK = [System.Drawing.Color]::FromArgb(255, 90, 96, 106)

function Render-State($stateName, $ticks) {
  $bmp = New-Object System.Drawing.Bitmap($W, $H)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
  $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
  $g.Clear($BACK)
  $rect = New-Object System.Drawing.Rectangle(0, 0, $W, $H)
  for ($i = 0; $i -lt $ticks; $i++) {
    $pe = New-Object System.Windows.Forms.PaintEventArgs($g, $rect)
    # the [object[]] cast is required: PowerShell otherwise wraps the argument in
    # a PSObject and reflection refuses to convert it
    $mOnPaint.Invoke($form, [object[]]@([System.Windows.Forms.PaintEventArgs]$pe)) | Out-Null
    Start-Sleep -Milliseconds 60
  }
  # measure how much of the art is still the near-black magic key colour
  $dark = 0
  for ($y = 0; $y -lt $H; $y += 2) {
    for ($x = 0; $x -lt $W; $x += 2) {
      $c = $bmp.GetPixel($x, $y)
      if ($c.R -lt 12 -and $c.G -lt 12 -and $c.B -lt 14) { $dark++ }
    }
  }
  $g.Dispose()
  return @{ Bmp = $bmp; Dark = $dark }
}

$results = @()
foreach ($name in $states) {
  $st = [DesktopCat.PetState]::$name
  # userInitiated = true so the reaction gate cannot swallow the state we asked for
  $mSetState.Invoke($form, [object[]]@([DesktopCat.PetState]$st, [int]3000, [bool]$true)) | Out-Null
  Start-Sleep -Milliseconds 120
  $r = Render-State $name 6
  $path = Join-Path $outDir ("$name.png")
  $r.Bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  $results += [pscustomobject]@{ State = $name; DarkSamples = $r.Dark; Path = $path; Bmp = $r.Bmp }
  Write-Output ("  rendered " + $name.PadRight(9) + " darkKeySamples=" + $r.Dark)
}

# ---- contact sheet: 4 cols x 4 rows at 1/2 scale, labelled ----
$scale = 0.5
$cw = [int]($W * $scale); $ch = [int]($H * $scale)
$cols = 4; $rows = 4
$sheet = New-Object System.Drawing.Bitmap(($cw * $cols), ($ch * $rows))
$sg = [System.Drawing.Graphics]::FromImage($sheet)
$sg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$sg.Clear([System.Drawing.Color]::FromArgb(255, 20, 22, 28))
$font = New-Object System.Drawing.Font("Consolas", 11, [System.Drawing.FontStyle]::Bold)
$brush = [System.Drawing.Brushes]::Yellow
for ($i = 0; $i -lt $results.Count; $i++) {
  $cx = ($i % $cols) * $cw
  $cy = [int][Math]::Floor($i / $cols) * $ch
  $sg.DrawImage($results[$i].Bmp, $cx, $cy, $cw, $ch)
  $sg.DrawString($results[$i].State, $font, $brush, ($cx + 4), ($cy + 3))
}
$sg.Dispose()
$sheetPath = Join-Path $root "tools\state-sheet.png"
$sheet.Save($sheetPath, [System.Drawing.Imaging.ImageFormat]::Png)
Write-Output ""
Write-Output ("contact sheet -> " + $sheetPath + "  (" + $sheet.Width + "x" + $sheet.Height + ")")

try { $form.Close(); $form.Dispose() } catch { }
Remove-Item $dataDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Output "done"
