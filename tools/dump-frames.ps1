# Ground truth on the decoded sprite art.
#
# For every clip, and every frame in it, this prints:
#   - the frame bitmap's size (what DrawImage is asked to scale)
#   - the content bounding box inside it (where the non-transparent pixels are)
#   - how the background was punched out (alpha=0 vs an opaque key colour)
#
# Reason: the sprite is drawn from its own bitmap at a fixed integer scale, so the
# CONTENT box is what determines the on-screen size of the cat. Reasoning about
# the animation from the GIF's authored frame sizes was wrong before, and the
# first attempt at measuring the fall produced a silhouette that never changed
# shape, which cannot be right for a clip that ends lying flat.

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

$dataDir = Join-Path $root ".petdata-dump"
Remove-Item $dataDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
$form = New-Object DesktopCat.PetForm($root, $dataDir, (Join-Path $dataDir "config.json"))

$ff = [System.Reflection.BindingFlags]::NonPublic -bor [System.Reflection.BindingFlags]::Instance
$clips = @('clipIdle','clipWalk','clipJump','clipPet','clipSad','clipPlay',
           'clipDance','clipStretch','clipCheer','clipSurprise','clipTalk','clipRemind')

foreach ($name in $clips) {
  $fld = $form.GetType().GetField($name, $ff)
  if (-not $fld) { Write-Output ("  " + $name + " : FIELD NOT FOUND"); continue }
  $clip = $fld.GetValue($form)
  if ($null -eq $clip) { Write-Output ("  " + $name + " : null"); continue }

  $frames = $clip.GetType().GetField("Frames").GetValue($clip)
  $isLoop = $clip.GetType().GetField("Loop").GetValue($clip)
  Write-Output ("== " + $name + "   frames=" + $frames.Length + "  loop=" + $isLoop)

  for ($i = 0; $i -lt $frames.Length; $i++) {
    $fr = $frames[$i]
    $bmp = $fr.GetType().GetField("Bmp").GetValue($fr)
    $delay = $fr.GetType().GetField("DelayMs").GetValue($fr)
    $bw = $bmp.Width; $bh = $bmp.Height

    $minX = $bw; $minY = $bh; $maxX = -1; $maxY = -1
    $opaque = 0; $alpha0 = 0; $magic = 0
    for ($y = 0; $y -lt $bh; $y++) {
      for ($x = 0; $x -lt $bw; $x++) {
        $c = $bmp.GetPixel($x, $y)
        if ($c.A -eq 0) { $alpha0++; continue }
        $opaque++
        # the pet's magic transparency colour, in case the punch left it opaque
        if ($c.R -eq 1 -and $c.G -eq 2 -and $c.B -eq 3) { $magic++ }
        if ($x -lt $minX) { $minX = $x }
        if ($y -lt $minY) { $minY = $y }
        if ($x -gt $maxX) { $maxX = $x }
        if ($y -gt $maxY) { $maxY = $y }
      }
    }
    $cw = if ($maxX -ge 0) { $maxX - $minX + 1 } else { 0 }
    $ch = if ($maxY -ge 0) { $maxY - $minY + 1 } else { 0 }
    Write-Output ("     f" + $i.ToString().PadLeft(2) + "  bmp=" + $bw + "x" + $bh +
                  "  content=" + $cw + "x" + $ch + " at (" + $minX + "," + $minY + ")" +
                  "  delay=" + $delay.ToString().PadLeft(4) + "ms" +
                  "  drawnAs=" + ($cw * 7) + "x" + ($ch * 7) +
                  "  transparentPx=" + $alpha0 + "  magicLeft=" + $magic)
  }
}

try { $form.Close(); $form.Dispose() } catch { }
Remove-Item $dataDir -Recurse -Force -ErrorAction SilentlyContinue
