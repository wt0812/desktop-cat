# Generates the C# speech-line arrays from tools\lines.txt and splices them into
# pet.ps1.
#
# pet.ps1 must stay PURE ASCII: it is launched from a .bat, and cmd.exe parses
# batch text with the system ANSI codepage (GBK here), which would mangle UTF-8
# Chinese. So the Chinese lives in lines.txt and is emitted as \uXXXX escapes.
#
# This script itself is pure ASCII; lines.txt is read with an explicit UTF-8
# decoder so the encoding is never guessed.

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$txtPath = Join-Path $root "tools\lines.txt"
$petPath = Join-Path $root "pet.ps1"

$raw = [System.IO.File]::ReadAllText($txtPath, [System.Text.Encoding]::UTF8)
$lines = $raw -split "`r?`n"

# group into ordered arrays, preserving first-seen order
$order = New-Object System.Collections.ArrayList
$map = @{}
foreach ($ln in $lines) {
    if ($ln.Trim().Length -eq 0) { continue }
    $i = $ln.IndexOf('|')
    if ($i -lt 1) { continue }
    $name = $ln.Substring(0, $i).Trim()
    $text = $ln.Substring($i + 1)
    if (-not $map.ContainsKey($name)) { $map[$name] = New-Object System.Collections.ArrayList; [void]$order.Add($name) }
    [void]$map[$name].Add($text)
}

function ConvertTo-CsLiteral([string]$s) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        $code = [int]$ch
        if ($code -eq 34) { [void]$sb.Append('\"') }
        elseif ($code -eq 92) { [void]$sb.Append('\\') }
        elseif ($code -ge 32 -and $code -lt 127) { [void]$sb.Append($ch) }
        else { [void]$sb.Append('\u' + $code.ToString('x4')) }
    }
    return $sb.ToString()
}

$out = New-Object System.Text.StringBuilder
# NOTE: always append "`n", never AppendLine -- AppendLine emits CRLF, which would
# leave the generated block with different line endings from the rest of pet.ps1.
$out.Append("        // ------------------------------------------------------------ speech`n")
$out.Append("        //`n")
$out.Append("        // Lines are chosen by situation: time of day for the greeting, the`n")
$out.Append("        // action for the rest. The Chinese is written as \uXXXX escapes`n")
$out.Append("        // because this file must stay pure ASCII (a .bat launches it and`n")
$out.Append("        // cmd.exe reads batch text with the system ANSI codepage).`n")
$out.Append("        // Source text lives in tools\lines.txt; tools\gen-lines.ps1 splices it in.`n")
$out.Append("`n")
foreach ($name in $order) {
    $items = $map[$name]
    $parts = @()
    foreach ($it in $items) { $parts += '"' + (ConvertTo-CsLiteral $it) + '"' }
    $body = ($parts -join ", ")
    if ($body.Length -le 96) {
        $out.Append("        static readonly string[] $name = { $body };`n")
    } else {
        $out.Append("        static readonly string[] $name =`n")
        $out.Append("        {`n")
        for ($k = 0; $k -lt $parts.Count; $k++) {
            $sep = if ($k -lt $parts.Count - 1) { "," } else { "" }
            $out.Append("            $($parts[$k])$sep`n")
        }
        $out.Append("        };`n")
    }
}
$out.Append("`n")
$out.Append("        // Affection thresholds for each TIER entry. Affinity starts at 0 and`n")
$out.Append("        // the last tier is the top of the meter.`n")
$out.Append("        static readonly int[] TIER_AT = { 0, 20, 50, 100, 200, 400 };`n")
$block = $out.ToString()

# Splice: replace everything from the old speech comment/arrays up to (not
# including) the "readonly Config cfg" line.
$pet = [System.IO.File]::ReadAllText($petPath, [System.Text.Encoding]::UTF8)
$anchorEnd = "        readonly Config cfg = new Config();"
$endIdx = $pet.IndexOf($anchorEnd)
if ($endIdx -lt 0) { throw "anchor not found: readonly Config cfg" }

# walk back to the start of the existing speech block.
# NOTE: this anchor must be the FIRST array in the block, and it is what makes
# the splice repeatable -- re-running this script replaces the whole block.
$startMark = "        static readonly string[] GREET_MORNING"
$startIdx = $pet.IndexOf($startMark)
if ($startIdx -lt 0) { throw "anchor not found: GREET_MORNING array (has the speech block moved?)" }
# include any comment lines directly above it
$pre = $pet.Substring(0, $startIdx)
$preLines = $pre -split "`n"
$cut = $preLines.Count - 1
while ($cut -gt 0) {
    $t = $preLines[$cut - 1].Trim()
    if ($t.StartsWith("//") -or $t.Length -eq 0) { $cut-- } else { break }
}
$newPre = ($preLines[0..($cut - 1)] -join "`n")
if (-not $newPre.EndsWith("`n")) { $newPre += "`n" }

$newPet = $newPre + $block + $pet.Substring($endIdx)
[System.IO.File]::WriteAllText($petPath, $newPet, (New-Object System.Text.UTF8Encoding($false)))

# verify
$check = [System.IO.File]::ReadAllBytes($petPath)
$nonAscii = 0
foreach ($b in $check) { if ($b -gt 127) { $nonAscii++ } }
Write-Output ("arrays written = " + $order.Count)
Write-Output ("total lines    = " + ($order | ForEach-Object { $map[$_].Count } | Measure-Object -Sum).Sum)
Write-Output ("pet.ps1 non-ASCII bytes = " + $nonAscii + "   (must be 0)")
Write-Output ("pet.ps1 size = " + (Get-Item $petPath).Length + " bytes")
Write-Output ""
Write-Output "first 12 lines of the generated block:"
($block -split "`n")[0..11] | ForEach-Object { Write-Output ("  " + $_) }
