# Measures the PACING of repaint requests, not just how many there are.
#
# Why: a fixed-rate gate (if now - lastPaint < 66ms then return) does not drop
# frames, it distorts the rhythm. The clip advances one frame every 80ms from its
# own stopwatch, while the gate opens every 66ms, so the two beat against each
# other: some frames get shown for 66ms, others for 146ms. That reads as stutter
# even though nothing was skipped.
#
# This calls the real PetForm.Repaint() in real time against the real
# AnimationPlayer clock, and counts how often the form actually asks to be
# repainted. No window is shown and no message loop is needed: the moment that
# matters is the invalidation, because that is when a new frame is scheduled.
#
# The number to judge is the SPREAD of the gaps between invalidations while one
# clip plays. For the 80ms idle clip, smooth means a tight cluster near 80ms,
# one repaint per frame, about 12.5 per second.

$ErrorActionPreference = 'Stop'

$pet  = Join-Path $PSScriptRoot '..\pet.ps1'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

$probe = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

public class RepaintPacingProbe
{
    public static string Replay(object formObj, int windowMs)
    {
        Form form = (Form)formObj;
        Type t = form.GetType();
        const BindingFlags PRIV = BindingFlags.NonPublic | BindingFlags.Instance;

        // creating the handle is what lets Invalidate() register, and it is what
        // makes Control raise Invalidated at all
        IntPtr handle = form.Handle;

        FieldInfo fPlayer = t.GetField("player", PRIV);
        object player = fPlayer.GetValue(formObj);
        Type pt = player.GetType();

        // get the idle clip running through the real API
        FieldInfo fClipIdle = t.GetField("clipIdle", PRIV);
        object idleClip = (fClipIdle == null) ? null : fClipIdle.GetValue(formObj);
        MethodInfo mPlay = pt.GetMethod("Play");
        if (mPlay != null && idleClip != null) mPlay.Invoke(player, new object[] { idleClip });

        MethodInfo mRepaint = t.GetMethod("Repaint", PRIV);
        bool repaintHasForceArg = (mRepaint.GetParameters().Length == 2);

        PropertyInfo pCurrent = pt.GetProperty("Current");

        List<int> marks = new List<int>();
        List<int> frames = new List<int>();
        InvalidateEventHandler onInval = delegate(object s, InvalidateEventArgs e)
        {
            marks.Add(Environment.TickCount);
            frames.Add((pCurrent == null) ? -1 : (int)pCurrent.GetValue(player, null));
        };
        t.GetEvent("Invalidated").AddEventHandler(formObj, onInval);

        // real time and the real player stopwatch; poll far faster than either
        // period so the measurement itself cannot be what limits the pacing
        // CRITICAL: pass the very same clock the app passes. PetForm keeps a
        // readonly Stopwatch (line 443) and OnIdle calls Repaint(clock.Elapsed).
        // Using Environment.TickCount here instead would quantise everything to
        // the 15.6ms system tick, which rounds the 66ms gate up to 78ms and
        // HIDES the very defect this instrument exists to find.
        FieldInfo fClock = t.GetField("clock", PRIV);
        Stopwatch appClock = (fClock == null) ? null : (Stopwatch)fClock.GetValue(formObj);

        int started = Environment.TickCount;
        int lastFrameSeen = int.MinValue;
        int frameMoves = 0;
        while (Environment.TickCount - started < windowMs)
        {
            long now = (appClock != null) ? appClock.ElapsedMilliseconds : (long)Environment.TickCount;
            int cur = (pCurrent == null) ? -1 : (int)pCurrent.GetValue(player, null);
            if (cur != lastFrameSeen) { frameMoves++; lastFrameSeen = cur; }

            object[] call = repaintHasForceArg
                ? new object[] { now, false }
                : new object[] { now };
            mRepaint.Invoke(formObj, call);
            // Thread.Sleep(1) is rounded up to a whole 15.6ms system tick here,
            // which would quantise the very gate under test and hide the defect.
            // Spin instead: this loop has to poll far faster than 66ms.
            System.Threading.Thread.SpinWait(300);
        }
        t.GetEvent("Invalidated").RemoveEventHandler(formObj, onInval);

        if (marks.Count < 4) return "invalidates=" + marks.Count + " (too few to judge)";

        // Two different questions, two different metrics.
        //
        // (a) How often does the form ask to be repainted? That is the cost.
        // (b) How long did each PICTURE stay on screen? That is the smoothness.
        //
        // (b) is the one the eye judges: an invalidation that re-draws the frame
        // already showing changes nothing for the viewer, so collapse runs of
        // equal frames into one "shown" event and time the gaps between those.
        List<int> shownStart = new List<int>();
        int redundant = 0;
        for (int i = 0; i < marks.Count; i++)
        {
            if (i > 0 && frames[i] == frames[i - 1]) { redundant++; continue; }
            shownStart.Add(marks[i]);
        }
        List<int> dur = new List<int>();
        for (int i = 1; i < shownStart.Count; i++) dur.Add(shownStart[i] - shownStart[i - 1]);
        if (dur.Count < 2) return "invalidates=" + marks.Count + " (no frame changes seen)";

        int dmin = dur[0], dmax = dur[0];
        double dmean = 0;
        foreach (int d in dur) { if (d < dmin) dmin = d; if (d > dmax) dmax = d; dmean += d; }
        dmean /= dur.Count;
        List<int> dsorted = new List<int>(dur); dsorted.Sort();
        int dmed = dsorted[dsorted.Count / 2];
        double dvar = 0; foreach (int d in dur) dvar += (d - dmean) * (d - dmean); dvar /= dur.Count;

        // the idle clip wants every picture to last the same 80ms
        int offPace = 0;
        foreach (int d in dur) if (Math.Abs(d - 80) > 16) offPace++;

        List<int> gaps = new List<int>();
        for (int i = 1; i < marks.Count; i++) gaps.Add(marks[i] - marks[i - 1]);
        double gmean = 0; foreach (int g in gaps) gmean += g; gmean /= gaps.Count;

        StringBuilder sb = new StringBuilder();
        sb.Append("paints=").Append(marks.Count).Append(" (").Append(Math.Round(1000.0 * gaps.Count / windowMs, 1)).Append("/s)");
        sb.Append("  wasted=").Append(redundant);
        sb.Append("  pictures=").Append(dur.Count);
        sb.Append("  ONSCREEN min=").Append(dmin);
        sb.Append(" med=").Append(dmed);
        sb.Append(" mean=").Append(Math.Round(dmean, 1));
        sb.Append(" max=").Append(dmax);
        sb.Append("  sd=").Append(Math.Round(Math.Sqrt(dvar), 1));
        sb.Append("  off80ms=").Append(offPace).Append("/").Append(dur.Count);
        return sb.ToString();
    }
}
'@

$raw = [System.IO.File]::ReadAllText($pet, [System.Text.Encoding]::UTF8)
$s = $raw.IndexOf("@'")
$e = $raw.IndexOf("'@", $s + 2)
$cs = $raw.Substring($s + 2, $e - $s - 2)

Add-Type -TypeDefinition $cs -Language CSharp `
    -ReferencedAssemblies 'System.dll','System.Core.dll','System.Drawing.dll','System.Windows.Forms.dll' `
    -IgnoreWarnings
Add-Type -TypeDefinition $probe -Language CSharp `
    -ReferencedAssemblies 'System.dll','System.Core.dll','System.Drawing.dll','System.Windows.Forms.dll'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$dir = Join-Path $env:TEMP ('DesktopCat-pace-' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$cfg = Join-Path $dir 'config.json'
[System.IO.File]::WriteAllText($cfg, '{ "scale": 100, "topMost": true }')

$window = 6000
if ($args.Count -ge 1) { $window = [int]$args[0] }

$script:REPORT = @()
Write-Output ''
Write-Output '################ pacing of the code on disk right now ################'
for ($run = 1; $run -le 3; $run++) {
    $form = New-Object DesktopCat.PetForm($root, $dir, $cfg)
    $line = [RepaintPacingProbe]::Replay($form, $window)
    Write-Output ('  run ' + $run + ': ' + $line)
    $script:REPORT += $line
    try { $form.Close(); $form.Dispose() } catch { }
    Start-Sleep -Milliseconds 250
}
Write-Output ''
Write-Output '  idle clip = 4 frames x 80ms  ->  smooth means one repaint per frame,'
Write-Output '  gaps clustered near 80ms, about 12.5 per second, sd small and offPace 0.'

Get-ChildItem -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Attributes = 'Normal' }
Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue