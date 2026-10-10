# Measures the pet's HEARTBEAT: how often the state machine and the walk
# stepping actually run.
#
# Why this instrument exists: the pet drives everything from OnIdle, and OnIdle
# was hung off Application.Idle. Application.Idle fires once when the message
# queue drains and then the thread blocks in GetMessage until a message arrives.
# In v1.0 the unconditional Invalidate() at the end of OnIdle was what kept
# posting WM_PAINT and therefore what kept the heartbeat alive -- hundreds to a
# few thousand ticks a second. Gating the repaint (to stop burning a whole CPU
# core) silently removed that heartbeat too, so StepWalk, which slides the window
# 5 px per tick, dropped to a handful of ticks a second: the cat crawls and jerks
# instead of walking.
#
# This forces a walk and counts how many times her position actually changes. No
# window is shown, so nothing the caller can see contributes messages, and
# therefore nothing can fake the heartbeat.
#
# Two hard-won details, both of which bit me:
#   * Do NOT pump with Application.DoEvents(). It returns to the caller instead
#     of blocking in GetMessage, so Application.Idle fires in a tight loop and
#     the "before" case measures fast. That is a false PASS.
#   * Stop the loop with Application.Exit(), which posts WM_QUIT to every thread
#     context. Application.ExitThread() only targets the calling thread, and the
#     sampler thread has no message queue, so the loop hangs forever.
#
# The measurement also runs in a child process under a hard timeout, and writes
# its result to a file before trying to stop, so a hang can never lose data.

param(
    [int]$Window = 2000,
    [switch]$Child
)

$ErrorActionPreference = 'Stop'

$pet  = Join-Path $PSScriptRoot '..\pet.ps1'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

$probe = @'
using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Windows.Forms;

public class WalkHeartbeatProbe
{
    static string summary = "";

    public static string Sample(object formObj, int windowMs, int targetPx, string reportPath)
    {
        Form form = (Form)formObj;
        Type t = form.GetType();
        const BindingFlags PRIV = BindingFlags.NonPublic | BindingFlags.Instance;

        // walkUntilMs is compared against the pet's OWN stopwatch, not TickCount
        Stopwatch petClock = (Stopwatch)t.GetField("clock", PRIV).GetValue(formObj);

        int startX = form.Location.X;
        t.GetField("walkTargetX", PRIV).SetValue(formObj, startX + targetPx);
        t.GetField("walkUntilMs", PRIV).SetValue(formObj, petClock.ElapsedMilliseconds + windowMs + 5000);

        int samples = 0, steps = 0, lastX = startX;

        Stopwatch sw = Stopwatch.StartNew();
        Thread sampler = new Thread(delegate()
        {
            try
            {
                while (sw.ElapsedMilliseconds < windowMs)
                {
                    int x = form.Location.X;
                    samples++;
                    if (x != lastX) { steps++; lastX = x; }
                    Thread.Sleep(1);
                }
                sw.Stop();
                double secs = sw.ElapsedMilliseconds / 1000.0;
                int dist = Math.Abs(lastX - startX);
                StringBuilder sb = new StringBuilder();
                sb.Append("window=").Append(Math.Round(secs, 2)).Append("s");
                sb.Append("  samples=").Append(samples);
                sb.Append("  MOVE STEPS=").Append(steps);
                sb.Append("  stepsPerSec=").Append(Math.Round(steps / secs, 1));
                sb.Append("  walked=").Append(dist).Append("px");
                sb.Append("  pxPerSec=").Append(Math.Round(dist / secs, 1));
                summary = sb.ToString();
            }
            catch (Exception ex)
            {
                summary = "probe error: " + ex.GetType().Name + ": " + ex.Message;
            }
            // write first, stop second: a hang must not lose the numbers
            if (reportPath != null && reportPath.Length > 0)
            {
                try { File.WriteAllText(reportPath, summary); } catch { }
            }
            try { Application.Exit(); } catch { }
        });
        sampler.IsBackground = true;
        sampler.Start();

        // pump, and nothing else: no form shown, so no paint messages are
        // generated and the only thing that can move her is a real heartbeat
        try { Application.Run(new ApplicationContext()); } catch { }

        return (summary.Length > 0) ? summary : "(the loop returned without a summary)";
    }
}
'@

# ---------------------------------------------------------------- child mode
if ($Child) {
    $raw = [System.IO.File]::ReadAllText($pet, [System.Text.Encoding]::UTF8)
    $s = $raw.IndexOf("@'")
    $e = $raw.IndexOf("'@", $s + 2)
    Add-Type -TypeDefinition $raw.Substring($s + 2, $e - $s - 2) -Language CSharp `
        -ReferencedAssemblies 'System.dll','System.Core.dll','System.Drawing.dll','System.Windows.Forms.dll' `
        -IgnoreWarnings
    Add-Type -TypeDefinition $probe -Language CSharp `
        -ReferencedAssemblies 'System.dll','System.Core.dll','System.Drawing.dll','System.Windows.Forms.dll'
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $dir = Join-Path $env:TEMP ('DesktopCat-walk-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $cfg = Join-Path $dir 'config.json'
    [System.IO.File]::WriteAllText($cfg, '{ "scale": 100, "topMost": true }')
    $report = Join-Path $dir 'result.txt'

    for ($run = 1; $run -le 3; $run++) {
        $form = New-Object DesktopCat.PetForm($root, $dir, $cfg)
        $line = [WalkHeartbeatProbe]::Sample($form, $Window, 1500, $report)
        if (-not (Test-Path -LiteralPath $report)) { [System.IO.File]::WriteAllText($report, $line) }
        $text = [System.IO.File]::ReadAllText($report)
        Write-Output ('RESULT| run ' + $run + ': ' + $text)
        Remove-Item -LiteralPath $report -Force -ErrorAction SilentlyContinue
        try { $form.Dispose() } catch { }
        Start-Sleep -Milliseconds 250
    }

    Get-ChildItem -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Attributes = 'Normal' }
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    return
}

# --------------------------------------------------------------- parent mode
Write-Output ''
Write-Output '################ how often does she actually move? ################'
Write-Output '  (one step == 5 px, so stepsPerSec is the heartbeat rate in Hz)'

$tag  = [guid]::NewGuid().ToString('N').Substring(0,8)
$out  = Join-Path $env:TEMP ('walkprobe-' + $tag + '.out')
$err  = Join-Path $env:TEMP ('walkprobe-' + $tag + '.err')
$budget = [int]([math]::Ceiling($Window / 1000.0) * 6 + 90)

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$p = Start-Process -FilePath 'powershell.exe' `
     -ArgumentList '-ExecutionPolicy','Bypass','-NoProfile','-File', $PSCommandPath, '-Child','-Window',$Window `
     -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
$finished = $p.WaitForExit($budget * 1000)
$sw.Stop()
if (-not $finished) {
    Write-Output ('  *** probe hung, killed after ' + $budget + ' s (this is itself a finding)')
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
} else {
    Write-Output ('  probe finished on its own after ' + [math]::Round($sw.Elapsed.TotalSeconds,1) + ' s')
}

if (Test-Path -LiteralPath $out) {
    foreach ($l in (Get-Content -LiteralPath $out)) { if ($l.Trim().Length -gt 0) { Write-Output $l } }
}
if (Test-Path -LiteralPath $err) {
    $etxt = Get-Content -LiteralPath $err -Raw
    if ($etxt -and $etxt.Trim().Length -gt 0) { Write-Output '--- stderr ---'; Write-Output $etxt }
}
Remove-Item -LiteralPath $out,$err -Force -ErrorAction SilentlyContinue

Write-Output ''
Write-Output '  v1.0 drove this from an unthrottled repaint loop, so the heartbeat was'
Write-Output '  hundreds to thousands of Hz and she glided. Anything near 10-15 Hz means'
Write-Output '  the heartbeat is now just the repaint cadence, and she jerks 5 px at a time.'
Write-Output '  A working heartbeat should be 60 Hz or more.'