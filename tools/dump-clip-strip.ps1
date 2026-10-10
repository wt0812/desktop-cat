# Dumps one clip's decoded frames as a single labelled strip, composited on
# flat MAGENTA.
#
# Magenta is used deliberately: it appears nowhere in this art, so any leftover
# GIF background inside a frame shows up as an obvious non-magenta slab behind
# the cat instead of blending into a neutral backdrop.
#
# Usage:  dump-clip-strip.ps1  <clipFieldName>  <outPngName>

param(
  [string]$ClipField = "clipCheer",
  [string]$OutName   = "clip-strip.png",
  [int]$Zoom         = 4
)

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

$dataDir = Join-Path $root ".petdata-strip"
Remove-Item $dataDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
$form = New-Object DesktopCat.PetForm($root, $dataDir, (Join-Path $dataDir "config.json"))

$ff = [System.Reflection.BindingFlags]::NonPublic -bor [System.Reflection.BindingFlags]::Instance
$clip = $form.GetType().GetField($ClipField, $ff).GetValue($form)
if ($null -eq $clip) { throw ("clip not found: " + $ClipField) }
$frames = $clip.GetType().GetField("Frames").GetValue($clip)
$n = $frames.Length
$b0 = $frames[0].GetType().GetField("Bmp").GetValue($frames[0])
$fw = $b0.Width * $Zoom
$fh = $b0.Height * $Zoom
$label = 22
$cw = $fw + 8
$ch = $fh + $label + 8

$sheet = New-Object System.Drawing.Bitmap(($cw * $n), $ch)
$g = [System.Drawing.Graphics]::FromImage($sheet)
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
$g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
$g.Clear([System.Drawing.Color]::FromArgb(255, 255, 0, 255))    # magenta everywhere
$font = New-Object System.Drawing.Font("Consolas", 11, [System.Drawing.FontStyle]::Bold)
$white = [System.Drawing.Brushes]::White

for ($i = 0; $i -lt $n; $i++) {
  $bmp = $frames[$i].GetType().GetField("Bmp").GetValue($frames[$i])
  $delay = $frames[$i].GetType().GetField("DelayMs").GetValue($frames[$i])
  $dx = ($i * $cw) + 4
  $dy = $label
  $dst = New-Object System.Drawing.Rectangle($dx, $dy, $fw, $fh)
  $g.DrawImage($bmp, $dst)
  # separator so adjacent frames are distinguishable
  $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 0, 200, 0), 2)
  $g.DrawRectangle($pen, $dx, $dy, ($fw - 1), ($fh - 1))
  $g.DrawString(("f" + $i + " " + $delay + "ms"), $font, $white, ($dx), 3)
}
$g.Dispose()

$out = Join-Path $root ("tools\" + $OutName)
$sheet.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
Write-Output ("clip  = " + $ClipField)
Write-Output ("frames= " + $n)
Write-Output ("strip -> " + $out + "  (" + $sheet.Width + "x" + $sheet.Height + "), zoom=" + $Zoom + "x, backdrop=magenta")

try { $form.Close(); $form.Dispose() } catch { }
Remove-Item $dataDir -Recurse -Force -ErrorAction SilentlyContinue
