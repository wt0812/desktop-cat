# Renders the fall / nap animation (cat_die, used for PetState.Sleep) as a timed
# strip, and measures the sprite in every sample.
#
# This targets the bug the user actually reported: "the fall flickers, and three
# standing frames are visible while she has already fallen". The earlier cause was
# that each clip was drawn from its OWN crop box at a different fractional scale,
# so entering the fall snapped the cat ~40% narrower and thin limbs popped in and
# out. Those are size changes, and size changes are measurable.
#
# Two deliberate details:
#   * The bubble is cleared first, so the speech bubble cannot be mistaken for part
#     of the sprite.
#   * Sprite metrics are taken from the band y in [100,427] only. Above 100 is the
#     bubble; below 427 is the tier name and the affection bar, which are drawn in
#     the same bottom-centre area as the feet and would otherwise be measured AS
#     the cat (that mistake is what made the first analysis report a bogus 446 px
#     tall "cat").

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$root = Split-Path -Parent $PSScriptRoot
$petPath = Join-Path $root "pet.ps1"
$outDir  = Join-Path $root "tools\fall-caps"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
Remove-Item (Join-Path $outDir "*.png") -Force -ErrorAction SilentlyContinue

$raw = [System.IO.File]::ReadAllText($petPath, [System.Text.Encoding]::UTF8)
$s = $raw.IndexOf("@'"); $e = $raw.IndexOf("'@", $s + 2)
$cs = $raw.Substring($s + 2, $e - $s - 2)
Add-Type -TypeDefinition $cs -Language CSharp `
  -ReferencedAssemblies 'System.dll','System.Core.dll','System.Drawing.dll','System.Windows.Forms.dll' `
  -IgnoreWarnings -ErrorAction Stop

$dataDir = Join-Path $root ".petdata-fall"
Remove-Item $dataDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
$form = New-Object DesktopCat.PetForm($root, $dataDir, (Join-Path $dataDir "config.json"))

$flags = [System.Reflection.BindingFlags]::NonPublic -bor [System.Reflection.BindingFlags]::Instance
$mSetState = $form.GetType().GetMethod("SetState", $flags, $null, @([DesktopCat.PetState], [int], [bool]), $null)
$mOnPaint  = $form.GetType().GetMethod("OnPaint", $flags, $null, @([System.Windows.Forms.PaintEventArgs]), $null)

# kill the boot greeting so only the sprite is left in the upper half
$fBubble = $form.GetType().GetField("bubbleText", [System.Reflection.BindingFlags]::NonPublic -bor [System.Reflection.BindingFlags]::Instance)
if ($fBubble) { $fBubble.SetValue($form, $null) }

$W = 340; $H = 460
$BACK = [System.Drawing.Color]::FromArgb(255, 90, 96, 106)
$FLOOR = $H - 34          # 426 - where the draw code anchors the feet
$BAND_TOP = 100
$BAND_BOT = 427

# enter the fall
$mSetState.Invoke($form, [object[]]@([DesktopCat.PetState]::Sleep, [int]8000, [bool]$true)) | Out-Null
$sw = [System.Diagnostics.Stopwatch]::StartNew()

$samples = @()
$count = 16
# NOTE: the player's frame index must be read DURING the capture loop. Reading it
# afterwards in the analysis loop returns the final state 16 times over, which
# looks exactly like "the drawn rectangle never changed" whether or not it did.
$fPlayer0 = $form.GetType().GetField("player", $flags)
$player0 = $fPlayer0.GetValue($form)
$fClip0 = $player0.GetType().GetField("Clip")
for ($i = 0; $i -lt $count; $i++) {
  $t = $sw.ElapsedMilliseconds
  $bmp = New-Object System.Drawing.Bitmap($W, $H)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
  $g.Clear($BACK)
  $rect = New-Object System.Drawing.Rectangle(0, 0, $W, $H)
  $pe = New-Object System.Windows.Forms.PaintEventArgs($g, $rect)
  $mOnPaint.Invoke($form, [object[]]@([System.Windows.Forms.PaintEventArgs]$pe)) | Out-Null
  $g.Dispose()

  $clipNow = $fClip0.GetValue($player0)
  $frNow = $player0.GetType().GetField("Frame").GetValue($player0)
  $bw = 0; $bh = 0
  if ($clipNow) {
    $frArr = $clipNow.GetType().GetField("Frames").GetValue($clipNow)
    if ($frNow -ge 0 -and $frNow -lt $frArr.Length) {
      $fb = $frArr[$frNow].GetType().GetField("Bmp").GetValue($frArr[$frNow])
      $bw = $fb.Width; $bh = $fb.Height
    }
  }

  $path = Join-Path $outDir ("f" + $i.ToString("00") + ".png")
  $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  $samples += [pscustomobject]@{ Index = $i; T = $t; Path = $path; Bmp = $bmp
                                 Frame = $frNow; BoxW = $bw; BoxH = $bh }
  Start-Sleep -Milliseconds 60
}

# ---- measure the sprite only, inside the band ----
#
# Two different things are measured, and only one of them is a bug signal:
#   content box  - the silhouette of the cat, which is EXPECTED to change during
#                  a fall (she goes from upright to prone, so she gets wider and
#                  shorter). A changing content box is correct behaviour.
#   drawn rect   - bmp size x spriteScale, i.e. the destination rectangle handed
#                  to DrawImage. Within one clip this must be constant. The
#                  original flicker was that entering the fall swapped in a
#                  differently-cropped clip, so the rect changed by 40% and the
#                  cat visibly snapped narrower. Measuring the silhouette alone
#                  cannot detect that, which is why the first version of this test
#                  gave a false alarm in one direction and missed the real bug.
$fPlayer = $form.GetType().GetField("player", $flags)
$player = $fPlayer.GetValue($form)
$fClipF  = $player.GetType().GetField("Clip")

$metrics = @()
foreach ($sm in $samples) {
  $bmp = $sm.Bmp
  $minX = $W; $maxX = -1; $minY = $H; $maxY = -1; $art = 0
  for ($y = $BAND_TOP; $y -le $BAND_BOT; $y++) {
    for ($x = 0; $x -lt $W; $x++) {
      $c = $bmp.GetPixel($x, $y)
      if ([Math]::Abs($c.R - 90) -le 6 -and [Math]::Abs($c.G - 96) -le 6 -and [Math]::Abs($c.B - 106) -le 6) { continue }
      $art++
      if ($x -lt $minX) { $minX = $x }
      if ($x -gt $maxX) { $maxX = $x }
      if ($y -lt $minY) { $minY = $y }
      if ($y -gt $maxY) { $maxY = $y }
    }
  }
  $wid = if ($maxX -ge 0) { $maxX - $minX + 1 } else { 0 }
  $hgt = if ($maxY -ge 0) { $maxY - $minY + 1 } else { 0 }

  # per-sample values captured during the render loop
  $bw = $sm.BoxW; $bh = $sm.BoxH
  $fr = $sm.Frame
  $drawnW = $bw * 7; $drawnH = $bh * 7

  $metrics += [pscustomobject]@{
    Index = $sm.Index; T = $sm.T
    W = $wid; H = $hgt; ArtPx = $art
    Bottom = $maxY
    Frame = $fr; ClipBox = ("" + $bw + "x" + $bh)
    DrawnW = $drawnW; DrawnH = $drawnH
    Wmod7 = if ($wid -gt 0) { $wid % 7 } else { -1 }
  }
}

$metrics | Format-Table -AutoSize | Out-String -Width 200 | Write-Output

Write-Output "=== the flicker test ==="
Write-Output "  width of the sprite, sample by sample (px):"
Write-Output ("    " + (($metrics | Select-Object -ExpandProperty W) -join "  "))
Write-Output "  feet row (426 = the floor line the draw code anchors to):"
Write-Output ("    " + (($metrics | Select-Object -ExpandProperty Bottom) -join "  "))

$ws = $metrics | Where-Object { $_.W -gt 0 } | Select-Object -ExpandProperty W
$wMin = ($ws | Measure-Object -Minimum).Minimum
$wMax = ($ws | Measure-Object -Maximum).Maximum
Write-Output ""
Write-Output ("  silhouette: narrowest = " + $wMin + " px, widest = " + $wMax + " px  (widening is CORRECT: she goes from upright to prone)")

# the real anti-flicker test: the destination rectangle must never change
$drawn = $metrics | Where-Object { $_.DrawnW -gt 0 } |
         Select-Object -ExpandProperty DrawnW -Unique
if (@($drawn).Count -eq 1) {
  Write-Output ("  VERDICT: PASS - the drawn rectangle is a CONSTANT " + $drawn[0] + " px wide for every sample,")
  Write-Output "                    so nothing can shrink or snap mid-fall (the old bug was a 40% change here)"
} else {
  Write-Output ("  VERDICT: FAIL - the drawn rectangle changes during the fall: " + ($drawn -join ", "))
}

# the silhouette must never jump BACKWARDS: an upright pose reappearing after the
# sprawl is the "standing image is still there while she has already fallen" report
$seq = @($metrics | Where-Object { $_.W -gt 0 } | Select-Object -ExpandProperty W)
$back = @()
for ($i = 1; $i -lt $seq.Count; $i++) {
  if ($seq[$i] -lt $seq[$i - 1] - 7) { $back += $i }
}
if ($back.Count -eq 0) {
  Write-Output "  VERDICT: PASS - the silhouette only ever widens; no upright frame reappears after the sprawl"
} else {
  Write-Output ("  VERDICT: silhouette narrows again at samples: " + ($back -join ", "))
}

$nonMult = $metrics | Where-Object { $_.W -gt 0 -and $_.Wmod7 -ne 0 }
if (@($nonMult).Count -eq 0) {
  Write-Output "  VERDICT: PASS - every silhouette width is an exact multiple of 7 (integer pixel scaling, no shimmer)"
} else {
  Write-Output ("  VERDICT: non-integer widths at samples: " + (($nonMult | Select-Object -ExpandProperty Index) -join ", "))
}

# how long the cat spends visibly upright before the fall commits
$upright = @($metrics | Where-Object { $_.W -gt 0 -and $_.W -le 140 })
if ($upright.Count -gt 0) {
  $lastUp = ($upright | Select-Object -Last 1)
  Write-Output ("  upright wind-up before the sprawl: " + $upright.Count + " sample(s), ending at t=" + $lastUp.T + " ms")
}

# ---- strip: crop y 120..460 so the bar stays in frame as a reference ----
$cropY = 120; $cropH = 340
$scale = 0.72
$cw = [int]($W * $scale); $ch = [int]($cropH * $scale)
$cols = 8; $rows = 2
$sheet = New-Object System.Drawing.Bitmap(($cw * $cols), ($ch * $rows))
$sg = [System.Drawing.Graphics]::FromImage($sheet)
$sg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
$sg.Clear([System.Drawing.Color]::FromArgb(255, 15, 16, 20))
$font = New-Object System.Drawing.Font("Consolas", 10, [System.Drawing.FontStyle]::Bold)
$pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 255, 60, 60), 1)
for ($i = 0; $i -lt $samples.Count; $i++) {
  $cx = ($i % $cols) * $cw
  $cy = [int][Math]::Floor($i / $cols) * $ch
  $srcRect = New-Object System.Drawing.Rectangle(0, $cropY, $W, $cropH)
  $dstRect = New-Object System.Drawing.Rectangle($cx, $cy, $cw, $ch)
  $sg.DrawImage($samples[$i].Bmp, $dstRect, $srcRect, [System.Drawing.GraphicsUnit]::Pixel)
  # red line at the floor row, so a drift is visible by eye too
  $floorY = $cy + [int](($FLOOR - $cropY) * $scale)
  $sg.DrawLine($pen, $cx, $floorY, ($cx + $cw - 1), $floorY)
  $sg.DrawString(("t=" + $samples[$i].T + "ms"), $font, [System.Drawing.Brushes]::Yellow, ($cx + 3), ($cy + 2))
}
$sg.Dispose()
$stripPath = Join-Path $root "tools\fall-strip.png"
$sheet.Save($stripPath, [System.Drawing.Imaging.ImageFormat]::Png)
Write-Output ""
Write-Output ("strip -> " + $stripPath + "  (" + $sheet.Width + "x" + $sheet.Height + "), 16 timed samples, red line = floor row 426")

try { $form.Close(); $form.Dispose() } catch { }
Remove-Item $dataDir -Recurse -Force -ErrorAction SilentlyContinue
