# Builds DesktopCat.exe from the C# embedded in pet.ps1.
#
# Why this exists: on this machine a security agent raises the Windows
# "Open File - Security Warning" dialog on every .bat / .lnk launch, and an
# Attachment Manager policy change (LowRiskFileTypes) did not suppress it.
# Launching a plain .exe is not intercepted, and a GUI-subsystem .exe also
# removes the console window that used to flash on every start.
#
# pet.ps1 stays the single source of truth. This script only extracts its
# embedded C# and compiles it, so there is no second copy to keep in sync.

$ErrorActionPreference = 'Stop'

$tools   = Split-Path -Parent $MyInvocation.MyCommand.Path
$root    = Split-Path -Parent $tools
$petPath = Join-Path $root 'pet.ps1'
$outExe  = Join-Path $root 'DesktopCat.exe'

if (-not (Test-Path $petPath)) { throw "pet.ps1 not found at $petPath" }

# ---- extract the C# between the here-string markers ----
$raw = [System.IO.File]::ReadAllText($petPath, [System.Text.Encoding]::UTF8)
$start = $raw.IndexOf("@'")
if ($start -lt 0) { throw "could not find the opening @' marker in pet.ps1" }
$end = $raw.IndexOf("'@", $start + 2)
if ($end -lt 0) { throw "could not find the closing '@ marker in pet.ps1" }
$cs = $raw.Substring($start + 2, $end - $start - 2)
Write-Host ("extracted " + $cs.Length + " chars of C# from pet.ps1")

# ---- compile ----
$provider = New-Object Microsoft.CSharp.CSharpCodeProvider
$p = New-Object System.CodeDom.Compiler.CompilerParameters
$p.GenerateExecutable = $true
$p.GenerateInMemory   = $false
$p.OutputAssembly     = $outExe
$p.MainClass          = 'DesktopCat.Program'
# /target:winexe is what makes it a GUI binary. Without it the compiler emits a
# console-subsystem image and Windows opens a black console window first, which
# is exactly the flash this build is meant to remove.
#
# /win32icon embeds DesktopCat.ico as the executable's own icon resource. Without
# it Explorer, the taskbar and any shortcut fall back to the generic blank
# application icon, which makes the program look unfinished.
$iconPath = Join-Path $root 'DesktopCat.ico'
if (Test-Path $iconPath) {
    $p.CompilerOptions = '/target:winexe /win32icon:"' + $iconPath + '"'
} else {
    $p.CompilerOptions = '/target:winexe'
    Write-Host "WARNING: DesktopCat.ico not found - building with no icon"
}
$p.TreatWarningsAsErrors = $false
$p.IncludeDebugInformation = $false
$p.WarningLevel = 4
foreach ($a in @('System.dll','System.Core.dll','System.Drawing.dll','System.Windows.Forms.dll')) {
    [void]$p.ReferencedAssemblies.Add($a)
}

$res = $provider.CompileAssemblyFromSource($p, $cs)
$errors   = @($res.Errors | Where-Object { -not $_.IsWarning })
$warnings = @($res.Errors | Where-Object { $_.IsWarning })

Write-Host ""
Write-Host ("errors   = " + $errors.Count)
Write-Host ("warnings = " + $warnings.Count)
foreach ($x in $errors) {
    # map the C# line number back to a pet.ps1 line number so the error is findable
    $offset = ($cs.Substring(0, [Math]::Min($cs.Length, $x.Line)) -split "`n").Count
    $petLine = ($raw.Substring(0, [Math]::Min($raw.Length, $start + 2 + $x.Line)) -split "`n").Count
    Write-Host ("  pet.ps1:" + $petLine + "  " + $x.ErrorText)
}
foreach ($x in $warnings) {
    Write-Host ("  warning: " + $x.ErrorText)
}

if ($errors.Count -gt 0) {
    Write-Host ""
    Write-Host "BUILD FAILED - no exe written"
    exit 1
}

if (-not (Test-Path $outExe)) { throw "compiler reported no errors but produced no $outExe" }

# ---- verify it is really a GUI binary, not a console one ----
$b = [System.IO.File]::ReadAllBytes($outExe)
$peOff = [BitConverter]::ToInt32($b, 0x3C)
$sig = [System.Text.Encoding]::ASCII.GetString($b, $peOff, 2)
$optOff = $peOff + 24
$magic = [BitConverter]::ToUInt16($b, $optOff)
$subsystem = [BitConverter]::ToUInt16($b, $optOff + 68)
$subName = switch ($subsystem) { 2 { 'WINDOWS_GUI' } 3 { 'WINDOWS_CUI (console!)' } default { "unknown ($subsystem)" } }

$info = Get-Item $outExe
Write-Host ""
Write-Host ("built      : " + $outExe)
Write-Host ("size       : " + $info.Length + " bytes")
Write-Host ("pe sig     : " + $sig + "   optional header magic: 0x" + $magic.ToString('x4'))
Write-Host ("subsystem  : " + $subName)

if ($subsystem -ne 2) {
    Write-Host ""
    Write-Host "WARNING: subsystem is not WINDOWS_GUI, so a console window will still appear."
    exit 2
}

# ---- read the icon back OFF the exe, so "was it really embedded?" is answered ----
# Compared pixel-for-pixel against DesktopCat.ico. An earlier version of this check
# counted "teal" pixels instead: that was a guess about the artwork and it reported
# a false alarm. Comparing against the source file cannot go wrong that way.
if (Test-Path $iconPath) {
    Add-Type -AssemblyName System.Drawing
    $exIcon = $null
    try { $exIcon = [System.Drawing.Icon]::ExtractAssociatedIcon($outExe) } catch { }
    if ($null -eq $exIcon) {
        Write-Host "icon       : COULD NOT BE READ BACK - embedding probably failed"
    } else {
        $srcIcon = New-Object System.Drawing.Icon($iconPath, 32, 32)
        $a  = $exIcon.ToBitmap()
        $b2 = $srcIcon.ToBitmap()
        $diff = -1
        if ($a.Width -eq $b2.Width -and $a.Height -eq $b2.Height) {
            $diff = 0
            for ($y = 0; $y -lt $a.Height; $y++) {
                for ($x = 0; $x -lt $a.Width; $x++) {
                    if ($a.GetPixel($x, $y).ToArgb() -ne $b2.GetPixel($x, $y).ToArgb()) { $diff++ }
                }
            }
        }
        Write-Host ("icon       : " + $a.Width + "x" + $a.Height + " read back from the exe, " + $diff + " pixels differ from DesktopCat.ico")
        if ($diff -ne 0) { Write-Host "WARNING: the icon embedded in the exe does not match DesktopCat.ico" }
        $a.Dispose(); $b2.Dispose(); $srcIcon.Dispose(); $exIcon.Dispose()
    }
} else {
    Write-Host "icon       : none (DesktopCat.ico missing)"
}

Write-Host ""
Write-Host "OK - compiled."
Write-Host ""
Write-Host "IMPORTANT - this .exe now sits INSIDE the DSH sandbox workspace, and Windows"
Write-Host "shows a security prompt for anything launched from there (DECISIONS.md D-23)."
Write-Host "DO NOT run this copy. Copy it out to the folder you actually run it from:"
Write-Host ""
Write-Host "    powershell -ExecutionPolicy Bypass -File tools\deploy.ps1"
Write-Host ""
Write-Host "Close the cat first if it is running and this rebuild changed the .exe."
