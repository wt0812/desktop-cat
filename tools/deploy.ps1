#  deploy.ps1 - copy the freshly built Desktop Cat into the folder you actually
#  run it from, while leaving your cat's own save data alone.
#
#  WHY KEEP THE TWO FOLDERS SEPARATE
#  Syncing docs or assets while the cat is running is completely safe, and the
#  run folder keeps its own state, so a rebuild can never wipe your affinity or
#  window position. (On this project's original machine the split was forced by
#  a sandbox ACL: every file created in the build folder inherited a marker that
#  made Windows treat programs launched from there as untrusted, so they always
#  showed SmartScreen. Copying them out dropped the marker. Full write-up:
#  DECISIONS.md, D-23.)
#
#  .petdata is NEVER copied - that is your cat's own state (affinity, window
#  position, log). The deployed copy keeps its own.
#
#  USAGE
#      powershell -ExecutionPolicy Bypass -File deploy.ps1
#      powershell -ExecutionPolicy Bypass -File deploy.ps1 -Destination D:\Elsewhere
#
#  Close the cat before running this if the .exe itself has to be replaced.

param(
    [string]$Source      = (Split-Path -Parent $PSScriptRoot),
    [string]$Destination = ''
)

$ErrorActionPreference = 'Stop'

# Where to install when -Destination is not given: $env:DESKTOPCAT_DEPLOY if it
# is set, otherwise Documents\DesktopCat.
if (-not $Destination) {
    if ($env:DESKTOPCAT_DEPLOY) { $Destination = $env:DESKTOPCAT_DEPLOY }
    else { $Destination = Join-Path $env:USERPROFILE 'Documents\DesktopCat' }
}

# Never copy these top-level entries into the run folder:
#   .petdata  the live state folder - overwriting it would wipe affinity/position
#   .git      the repository itself - a clone would otherwise be dumped into the
#             run folder, and git marks its object files read-only
$skipTops = @('.petdata', '.git')

function Test-FileLocked([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    try {
        $fs = [System.IO.File]::Open($path, 'Open', 'ReadWrite', 'None')
        $fs.Close()
        return $false
    } catch {
        return $true
    }
}

Write-Host ''
Write-Host '  Desktop Cat - deploy to your run folder'
Write-Host ('  from : ' + $Source)
Write-Host ('  to   : ' + $Destination)
Write-Host ''

if (-not (Test-Path -LiteralPath $Source)) {
    Write-Host ('  ERROR: source not found: ' + $Source) -ForegroundColor Red
    exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $Source 'DesktopCat.exe'))) {
    Write-Host ('  ERROR: ' + (Join-Path $Source 'DesktopCat.exe') + ' does not exist.') -ForegroundColor Red
    Write-Host '         Build it first with tools\build-exe.ps1'
    exit 1
}

# Guard: if the destination sits inside the source, the recursive copy would walk
# its own output and copy the destination into itself, forever.
$srcFull = [System.IO.Path]::GetFullPath($Source).TrimEnd('\') + '\'
$dstFull = [System.IO.Path]::GetFullPath($Destination).TrimEnd('\')
if ($dstFull -eq $srcFull.TrimEnd('\')) {
    Write-Host '  ERROR: source and destination are the SAME folder.' -ForegroundColor Red
    Write-Host ('         ' + $dstFull)
    Write-Host '         Run the copy that lives in the BUILD folder, not the one in the'
    Write-Host '         deployed folder - otherwise it would just copy onto itself.'
    exit 1
}
if ($dstFull.StartsWith($srcFull, [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-Host '  ERROR: the destination is INSIDE the source folder.' -ForegroundColor Red
    Write-Host ('         source      : ' + $srcFull)
    Write-Host ('         destination : ' + $dstFull)
    Write-Host '         Pick a folder outside the build folder (the default is outside it).'
    exit 1
}

$destExe = Join-Path $Destination 'DesktopCat.exe'
$srcExe  = Join-Path $Source 'DesktopCat.exe'

$beforeHash = ''
if (Test-Path -LiteralPath $destExe) {
    $beforeHash = (Get-FileHash -LiteralPath $destExe -Algorithm SHA256).Hash
}
$srcHash = (Get-FileHash -LiteralPath $srcExe -Algorithm SHA256).Hash
$exeWillChange = ($beforeHash -ne $srcHash)

# Only insist the app be closed when the .exe really has to be replaced.
# Syncing docs or assets while the cat is running is perfectly safe.
if ($exeWillChange -and (Test-FileLocked $destExe)) {
    Write-Host '  ERROR: the deployed DesktopCat.exe is in use and has to be replaced.' -ForegroundColor Red
    Write-Host '         Close the cat (tray icon -> Quit, or click it and press Esc), then run this again.'
    exit 1
}

if (-not (Test-Path -LiteralPath $Destination)) {
    [void](New-Item -ItemType Directory -Path $Destination -Force)
    Write-Host ('  created ' + $Destination)
}

$hasState = Test-Path -LiteralPath (Join-Path $Destination '.petdata')

$copied = 0
$unchanged = 0
foreach ($f in [System.IO.Directory]::GetFiles($Source, '*', [System.IO.SearchOption]::AllDirectories)) {
    $rel  = $f.Substring($Source.Length).TrimStart('\')
    $top  = $rel.Split('\')[0]
    if ($skipTops -contains $top) { continue }

    $dest = Join-Path $Destination $rel
    $dir  = Split-Path -Parent $dest
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }

    $same = $false
    if (Test-Path -LiteralPath $dest) {
        $a = Get-Item -LiteralPath $f
        $b = Get-Item -LiteralPath $dest
        if ($a.Length -eq $b.Length) {
            $same = ((Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash)
        }
    }
    if ($same) { $unchanged++ } else {
        [System.IO.File]::Copy($f, $dest, $true)
        Write-Host ('  copied ' + $rel)
        $copied++
    }
}

$afterHash = (Get-FileHash -LiteralPath $destExe -Algorithm SHA256).Hash

# Report - but never delete - anything sitting in the destination that the
# current build no longer contains. Leaving stale files behind is how a dead
# launcher pointing at the old sandbox path survived one deploy unnoticed.
$stale = New-Object System.Collections.ArrayList
if (Test-Path -LiteralPath $Destination) {
    foreach ($f in [System.IO.Directory]::GetFiles($Destination, '*', [System.IO.SearchOption]::AllDirectories)) {
        $rel = $f.Substring($Destination.Length).TrimStart('\')
        if ($skipTops -contains $rel.Split('\')[0]) { continue }
        if (-not (Test-Path -LiteralPath (Join-Path $Source $rel))) { [void]$stale.Add($rel) }
    }
}

Write-Host ''
Write-Host ('  files copied  : ' + $copied)
Write-Host ('  already same  : ' + $unchanged)
if ($hasState) { Write-Host '  .petdata      : kept, untouched' }
else           { Write-Host '  .petdata      : none yet, the cat will create one on first run' }
if ($stale.Count -gt 0) {
    Write-Host ('  STALE in dest : ' + $stale.Count + ' file(s) the current build no longer has:') -ForegroundColor Yellow
    foreach ($s in $stale) { Write-Host ('      ' + $s) }
    Write-Host '      (not deleted automatically - remove by hand if they are old leftovers)'
}
if ($beforeHash -ne $afterHash) {
    $was = '(none - this is the first deploy)'
    if ($beforeHash) { $was = $beforeHash.Substring(0,16) + '...' }
    Write-Host ('  DesktopCat.exe: UPDATED  ' + $was + ' -> ' + $afterHash.Substring(0,16) + '...') -ForegroundColor Green
    Write-Host ''
    Write-Host '  Windows may show a one-off SmartScreen prompt for the new build'
    Write-Host '  (it is a brand new unsigned file). Choose "More info" -> "Run anyway".'
} else {
    Write-Host '  DesktopCat.exe: unchanged'
}
Write-Host ''
Write-Host '  Done. Double-click the deployed DesktopCat.exe to run.'
Write-Host ''
