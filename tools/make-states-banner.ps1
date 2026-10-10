# Renders docs\states.png -- the four-panel banner the READMEs show.
#
# Why this exists: the original banner was produced by a one-off script that
# never lived in the repo, so when the sleep action was removed the README kept
# showing a cat lying flat under the word for "napping". A marketing image that
# advertises a feature the program no longer has is worse than no image.
#
# How it works: the pet's own C# is compiled into this process, a PetForm is
# constructed but NEVER shown, and each of the four states is entered with
# SetState(userInitiated: true) so no reaction gate can swallow it. The sprite
# is then read straight off the form's AnimationPlayer -- the same bitmap the
# window would paint -- and composited onto a gradient at an INTEGER zoom, so
# the pixel art stays crisp.
#
# The Chinese strings live in tools\banner-strings.txt, not in this file: a
# .ps1 with non-ASCII in it is read by PowerShell 5.1 using the system ANSI
# codepage unless it carries a BOM, and this repo's tooling writes BOM-less
# files. Keeping the script pure ASCII removes that whole class of bug.
#
# Tiers and their names are taken from the program's own TIER table, so the
# banner cannot drift away from the app: 20 / 100 / 200 / 400 affinity.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$root    = Split-Path -Parent $PSScriptRoot
$petPath = Join-Path $root "pet.ps1"
$strPath = Join-Path $root "tools\banner-strings.txt"
$outPath = Join-Path $root "docs\states.png"

# ---- strings (UTF-8, read explicitly so the BOM question never matters) ----
$STR = @{}
foreach ($line in ([System.IO.File]::ReadAllText($strPath, [System.Text.Encoding]::UTF8) -split "`r?`n")) {
  if ($line -match '^([A-Za-z0-9]+)=(.*)$') { $STR[$Matches[1]] = $Matches[2] }
}
foreach ($k in @('caption','p1','p2','p3','p4','t1','t2','t3','t4')) {
  if (-not $STR.ContainsKey($k)) { throw "banner-strings.txt is missing key '$k'" }
}

# ---- compile the pet's own C# ----
$raw = [System.IO.File]::ReadAllText($petPath, [System.Text.Encoding]::UTF8)
$s = $raw.IndexOf("@'"); $e = $raw.IndexOf("'@", $s + 2)
Add-Type -TypeDefinition $raw.Substring($s + 2, $e - $s - 2) -Language CSharp `
  -ReferencedAssemblies 'System.dll','System.Core.dll','System.Drawing.dll','System.Windows.Forms.dll' `
  -IgnoreWarnings -ErrorAction Stop
Write-Output "compiled pet.ps1 C# into this process"

$dataDir = Join-Path $root ".petdata-banner"
Remove-Item $dataDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
$cfgPath = Join-Path $dataDir "config.json"
$form = New-Object DesktopCat.PetForm($root, $dataDir, $cfgPath)
Write-Output "PetForm constructed (never shown)"

$flags = [System.Reflection.BindingFlags]::NonPublic -bor [System.Reflection.BindingFlags]::Instance
$mSetState = $form.GetType().GetMethod("SetState", $flags, $null, @([DesktopCat.PetState], [int], [bool]), $null)
if ($null -eq $mSetState) { throw "SetState not found" }
$mDesiredClip = $form.GetType().GetMethod("DesiredClip", $flags, $null, @(), $null)
if ($null -eq $mDesiredClip) { throw "DesiredClip not found" }
$player = $form.GetType().GetField("player", $flags).GetValue($form)
if ($null -eq $player) { throw "player field not found" }

# ---- canvas ----
$W = 1280; $H = 440
$bmp = New-Object System.Drawing.Bitmap($W, $H)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
$g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit

# radial vignette, sampled from the banner this replaces: #081018 at the edge,
# #184048 in the middle
$path = New-Object System.Drawing.Drawing2D.GraphicsPath
$path.AddEllipse(-380, -520, ($W + 760), ($H + 1040))
$pgb = New-Object System.Drawing.Drawing2D.PathGradientBrush($path)
$pgb.CenterColor = [System.Drawing.Color]::FromArgb(255, 0x1C, 0x48, 0x52)
$pgb.SurroundColors = @([System.Drawing.Color]::FromArgb(255, 0x08, 0x10, 0x18))
$g.FillRectangle($pgb, 0, 0, $W, $H)
$pgb.Dispose(); $path.Dispose()

function Get-Font([string]$name, [single]$size, $style) {
  foreach ($n in @($name, "Microsoft YaHei UI", "Microsoft YaHei", "SimHei", "Segoe UI")) {
    try { return (New-Object System.Drawing.Font($n, $size, $style)) } catch { }
  }
  return (New-Object System.Drawing.Font([System.Drawing.FontFamily]::GenericSansSerif, $size, $style))
}
$fTop   = Get-Font "Microsoft YaHei UI" 21 ([System.Drawing.FontStyle]::Regular)
$fLabel = Get-Font "Microsoft YaHei UI" 17 ([System.Drawing.FontStyle]::Bold)
$fTier  = Get-Font "Microsoft YaHei UI" 13 ([System.Drawing.FontStyle]::Regular)
# Guard against the bug this file actually had: PowerShell variable names are
# case-insensitive, so a later "$s = ..." silently overwrote the "$S" string
# table with a chunk of C# source, every DrawString got an empty string, and
# the banner rendered with no text while reporting success. Assert the values
# survived, not just that the keys exist.
if ($STR['caption'].Length -lt 4 -or $STR['p1'].Length -lt 1 -or $STR['t4'].Length -lt 1) {
  throw "banner-strings.txt parsed to empty values - was the table overwritten?"
}
Write-Output ("strings OK: caption " + $STR['caption'].Length + " chars, panel labels " + $STR['p1'] + " / " + $STR['p2'] + " / " + $STR['p3'] + " / " + $STR['p4'])

$cyan  = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 0x4F, 0xDA, 0xE4))
$white = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 0xEC, 0xF6, 0xF7))
$dim   = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 0x9F, 0xC2, 0xC8))
$edge  = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 0x2C, 0x6C, 0x78), 1.4)
$sf    = New-Object System.Drawing.StringFormat
$sf.Alignment = [System.Drawing.StringAlignment]::Center

# sprite floor and the two text rows inside each panel
$floorY = 330
$tierY  = 350
$capY   = 386
$zoom   = 8

$panels = @(
  @{ State = 'Idle';    Label = $STR['p1']; Tier = $STR['t1']; Bar = 34  }
  @{ State = 'Stretch'; Label = $STR['p2']; Tier = $STR['t2']; Bar = 66  }
  @{ State = 'Dancing'; Label = $STR['p3']; Tier = $STR['t3']; Bar = 98  }
  @{ State = 'Cheer';   Label = $STR['p4']; Tier = $STR['t4']; Bar = 130 }
)

$cx = @()
for ($i = 0; $i -lt 4; $i++) { $cx += [int](($i + 0.5) * ($W / 4)) }

# top caption
$g.DrawString($STR['caption'], $fTop, $white, (New-Object System.Drawing.RectangleF(0, 16, $W, 40)), $sf)

# panels
for ($i = 0; $i -lt 4; $i++) {
  $p = $panels[$i]
  $st = [DesktopCat.PetState]::$($p.State)
  $mSetState.Invoke($form, [object[]]@([DesktopCat.PetState]$st, [int]3000, [bool]$true)) | Out-Null
  # The program only calls Play() from its paint path, and nothing here ever
  # paints the form, so the player would still have no clip. DesiredClip() +
  # Play() is exactly the pair OnPaint itself uses, so the frame that gets
  # rendered is the one the program would have chosen for this state.
  Start-Sleep -Milliseconds 60
  $player.Play($mDesiredClip.Invoke($form, @()))
  Start-Sleep -Milliseconds 170

  $cur  = $player.Current
  $clip = $player.Clip
  $spr  = $player.Bitmap
  if ($null -eq $spr) { throw ("no bitmap for state " + $p.State) }
  Write-Output ("  " + $p.State.PadRight(8) + " clip=" + $clip.Name.PadRight(12) + " frame=" + $cur + " src=" + $spr.Width + "x" + $spr.Height + " -> " + ($spr.Width * $zoom) + "x" + ($spr.Height * $zoom))

  $dw = $spr.Width  * $zoom
  $dh = $spr.Height * $zoom
  $dx = $cx[$i] - ($dw / 2)
  $dy = $floorY - $dh
  $g.DrawImage($spr, [single]$dx, [single]$dy, [single]$dw, [single]$dh)

  # tier name + progress bar
  $tr = New-Object System.Drawing.RectangleF(($cx[$i] - 90), $tierY, 180, 24)
  $g.DrawString($p.Tier, $fTier, $dim, $tr, $sf)
  $barX = $cx[$i] - ($p.Bar / 2)
  $g.FillRectangle($cyan, [single]$barX, [single]($tierY + 22), [single]$p.Bar, 2.6)

  # the state name in a rounded outline
  $bw = 132; $bh = 30
  $bx = $cx[$i] - ($bw / 2); $by = $capY
  $rp = New-Object System.Drawing.Drawing2D.GraphicsPath
  $r = 9
  $rp.AddArc($bx, $by, $r, $r, 180, 90)
  $rp.AddArc(($bx + $bw - $r), $by, $r, $r, 270, 90)
  $rp.AddArc(($bx + $bw - $r), ($by + $bh - $r), $r, $r, 0, 90)
  $rp.AddArc($bx, ($by + $bh - $r), $r, $r, 90, 90)
  $rp.CloseFigure()
  $g.DrawPath($edge, $rp)
  $g.DrawString($p.Label, $fLabel, $white, (New-Object System.Drawing.RectangleF($bx, ($by + 1), $bw, $bh)), $sf)
  $rp.Dispose()
}


# Self-check that can fail: the caption band holds text and no sprite, so a
# zero here means the text silently did not paint (which is exactly what
# happened when a case-insensitive variable clash left every string empty).
$light = 0
for ($yy = 8; $yy -lt 62; $yy++) {
  for ($xx = 0; $xx -lt $W; $xx++) {
    $c = $bmp.GetPixel($xx, $yy)
    if ($c.R -ge 150 -and $c.G -ge 150) { $light++ }
  }
}
Write-Output ('  caption band light pixels = ' + $light + '   (0 means the text did not paint)')
if ($light -lt 200) { throw "caption text did not render (only " + $light + " light pixels)" }
$g.Dispose()
$bmp.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Output ""
Write-Output ("banner -> " + $outPath)
Write-Output ("size   = " + (Get-Item -LiteralPath $outPath).Length + " bytes")

try { $form.Close(); $form.Dispose() } catch { }
Remove-Item $dataDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Output "done"
