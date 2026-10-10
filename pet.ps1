# =============================================================================
#  Desktop Cat -- WinForms single-process edition
#
#  Why this exists (2026-09-29):
#  Chromium/Electron cannot render on this machine. Electron's renderer needs a
#  child process; process spawning is blocked here, so the renderer never starts.
#  Tested and failed: --no-sandbox, --single-process, --in-process-gpu,
#  --disable-gpu, --use-gl=swiftshader, --no-zygote.
#  WinForms is single-process pure Win32 and renders fine (verified by pixel
#  analysis of a real screenshot: 31190 teal pixels on screen).
#
#  This file must stay PURE ASCII. It is launched by a .bat, and cmd.exe parses
#  batch/console text with the system ANSI codepage (GBK here), which mangles
#  UTF-8 Chinese into garbage. Chinese UI strings are built from \uXXXX escapes
#  in the C# below -- the compiler and GDI+ handle those correctly, no encoding
#  risk at all.
# =============================================================================

$ErrorActionPreference = 'Stop'

$ROOT = Split-Path -Parent $MyInvocation.MyCommand.Path

# Data directory. PET_DATA overrides it so a throwaway second instance can run
# beside a real one without the two sharing -- and truncating -- each other's log.
if ($env:PET_DATA) { $DATA = $env:PET_DATA } else { $DATA = Join-Path $ROOT '.petdata' }
$LOGF = Join-Path $DATA 'pet.log'
$CFGF = Join-Path $DATA 'config.json'
# Written by whichever instance actually owns the launch, so the .bat launcher can
# report the truth. The launcher used to delete pet.log before starting, which
# destroyed a RUNNING instance's log and then reported "did not start" even though
# the cat was already on screen.
$LAUNCHF = Join-Path $DATA 'last-launch.txt'

if (-not (Test-Path $DATA)) { New-Item -ItemType Directory -Path $DATA -Force | Out-Null }

# The pid is in every line so it is always obvious WHICH process wrote it.
function Note($s) { Add-Content -Path $LOGF -Value ("$(Get-Date -Format 'HH:mm:ss.fff') [$PID] $s") -Encoding UTF8 }

# -----------------------------------------------------------------------------
#  Single instance guard.
#  Without this, double-clicking the launcher a few times puts several copies of
#  her on screen at once (each is its own process with its own window).
#  The mutex must be held in a script-scope variable for the whole run, otherwise
#  PowerShell may collect it and the guard stops working.
#
#  PET_FORCE=1 deliberately skips the guard, so a second copy can be run on
#  purpose during development. Pair it with PET_DATA so the logs stay separate.
#
#  NOTE: the log is NOT truncated until AFTER this guard. It used to be truncated
#  on line one, which meant a rejected second launch wiped the log of the
#  instance that was actually running -- making every diagnosis read like a mix
#  of two processes.
# -----------------------------------------------------------------------------
$gotInstance = $true
if ($env:PET_FORCE -ne '1') {
    $script:INSTANCE_MUTEX = New-Object System.Threading.Mutex($false, 'Global\DesktopCat_SingleInstance')
    try { $gotInstance = $script:INSTANCE_MUTEX.WaitOne(0, $false) } catch { $gotInstance = $true }
}

if (-not $gotInstance) {
    Note "another instance already running - exiting"
    Set-Content -Path $LAUNCHF -Value "ALREADY_RUNNING" -Encoding ASCII
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    # Built from code points because this file has to stay pure ASCII, and
    # PowerShell 5.1 has no \uXXXX escape of its own (that is C# syntax).
    # Word for word the same as the C# guard in Program.Main, which is the path
    # the packaged exe takes. Source text: tools\info-strings.txt lines 34, 35.
    $zhTitle = (-join ([char[]]@(0x684C, 0x9762, 0x5C0F, 0x732B))) + " Desktop Cat"
    $zhLine1 = -join ([char[]]@(0x5DF2, 0x7ECF, 0x6709, 0x4E00, 0x53EA, 0x732B, 0x54AA, 0x5728, 0x684C, 0x9762, 0x4E0A, 0x5566, 0x3002))
    $zhLine2 = -join ([char[]]@(0x5982, 0x679C, 0x627E, 0x4E0D, 0x5230, 0x5979, 0xFF0C, 0x53F3, 0x952E, 0x4EFB, 0x52A1, 0x680F, 0x6258, 0x76D8, 0x91CC, 0x7684, 0x732B, 0x56FE, 0x6807, 0xFF0C, 0x9009, 0x300C, 0x9000, 0x51FA, 0x300D, 0xFF0C, 0x518D, 0x91CD, 0x65B0, 0x53CC, 0x51FB, 0x4E00, 0x6B21, 0x3002))
    [System.Windows.Forms.MessageBox]::Show(
        $zhLine1 + [Environment]::NewLine + [Environment]::NewLine + $zhLine2,
        $zhTitle) | Out-Null
    exit 0
}

# Only the instance that owns the log gets to start it fresh.
Set-Content -Path $LOGF -Value "MARK_START $(Get-Date -Format 'HH:mm:ss.fff') pid=$PID" -Encoding UTF8
Note "single instance acquired"

Note "root=$ROOT"
Note "psversion=$($PSVersionTable.PSVersion)"

# -----------------------------------------------------------------------------
#  Character + app, in C# so it is compiled to IL and fast enough for 30fps.
# -----------------------------------------------------------------------------
$CSHARP = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;
using Microsoft.Win32;

namespace DesktopCat
{
    // ---------------------------------------------------------------- state FSM
    //
    // Priority order (low number = easy to interrupt). Stretch sits just above
    // Idle so it can be pushed aside; Surprise sits above Game so a startle wins.
    public enum PetState
    {
        Idle = 0, Stretch = 30, Sad = 55, Happy = 60,
        Play = 65, Dancing = 70, Cheer = 75, Game = 80, Surprise = 85,
        Talking = 90, Reminder = 100
    }

    public class StateInfo
    {
        public PetState State;
        public int Priority;
        public int MinMs;
        public bool Interruptible;
        public StateInfo(PetState s, int p, int minMs, bool inter)
        { State = s; Priority = p; MinMs = minMs; Interruptible = inter; }
    }

    public class Config
    {
        public int X = -1;
        public int Y = -1;
        public int Affinity = 0;
        public int Interactions = 0;
        public bool TopMost = true;
        // Overall size as a percentage of the default 340x460 window. A reviewer
        // put it plainly -- the size cannot be adjusted -- so this is now a menu
        // choice and it persists. 50..200, clamped on load.
        public int Scale = 100;
    }

    // --------------------------------------------------- global mouse watching
    // Lets her react to the user's normal mouse activity (needed for petting)
    // and lets her walk toward wherever you are working.
    public class MouseHook : IDisposable
    {
        const int WH_MOUSE_LL = 14;
        const int WM_LBUTTONDOWN = 0x0201;

        [StructLayout(LayoutKind.Sequential)]
        struct POINT { public int X; public int Y; }

        [StructLayout(LayoutKind.Sequential)]
        struct MSLLHOOKSTRUCT { public POINT pt; public uint mouseData; public uint flags; public uint time; public IntPtr dwExtraInfo; }

        delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll", SetLastError = true)]
        static extern IntPtr SetWindowsHookEx(int idHook, HookProc lpfn, IntPtr hMod, uint dwThreadId);
        [DllImport("user32.dll", SetLastError = true)]
        static extern bool UnhookWindowsHookEx(IntPtr hhk);
        [DllImport("user32.dll")]
        static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
        [DllImport("kernel32.dll", CharSet = CharSet.Auto)]
        static extern IntPtr GetModuleHandle(string name);

        IntPtr hook = IntPtr.Zero;
        readonly HookProc proc;              // keep a reference; otherwise it is GC'd

        public event Action<int, int> LeftButtonDown;

        public MouseHook()
        {
            proc = new HookProc(Callback);
            try
            {
                hook = SetWindowsHookEx(WH_MOUSE_LL, proc, GetModuleHandle(null), 0);
                Installed = hook != IntPtr.Zero;
            }
            catch { Installed = false; }
        }

        public bool Installed { get; private set; }
        public string LastError { get; private set; }

        IntPtr Callback(int nCode, IntPtr wParam, IntPtr lParam)
        {
            try
            {
                if (nCode >= 0 && wParam == (IntPtr)WM_LBUTTONDOWN && LeftButtonDown != null)
                {
                    var info = (MSLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(MSLLHOOKSTRUCT));
                    LeftButtonDown(info.pt.X, info.pt.Y);
                }
            }
            catch { }
            return CallNextHookEx(hook, nCode, wParam, lParam);
        }

        public void Dispose()
        {
            if (hook != IntPtr.Zero) { try { UnhookWindowsHookEx(hook); } catch { } hook = IntPtr.Zero; }
        }
    }

    // --------------------------------------------------- stats + attribution
    //
    // A plain opaque dialog, shown non-modally so the cat keeps animating behind
    // it. It also carries the CC-BY credit, which the licence requires to be
    // reachable from the app itself and not only from a text file.
    public class InfoForm : Form
    {
        public InfoForm(string title, string body)
        {
            Text = title;
            ClientSize = new Size(470, 350);
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            ShowInTaskbar = true;
            StartPosition = FormStartPosition.CenterScreen;
            BackColor = Color.FromArgb(255, 26, 28, 36);
            ForeColor = Color.FromArgb(255, 236, 240, 248);
            TopMost = true;

            var tb = new TextBox();
            tb.Multiline = true;
            tb.ReadOnly = true;
            tb.WordWrap = true;
            tb.BorderStyle = BorderStyle.None;
            tb.ScrollBars = ScrollBars.Vertical;
            tb.BackColor = BackColor;
            tb.ForeColor = ForeColor;
            tb.Font = new Font("Microsoft YaHei UI", 9.5f);
            tb.Dock = DockStyle.Fill;
            tb.Text = body;
            Controls.Add(tb);
        }
    }

    // ---------------------------------------------------------------- the pet
    public class PetForm : Form
    {
        // ---- constants -----------------------------------------------------
        // Authored in 96-dpi units. A DPI-UNAWARE process gets its whole window
        // bitmap-stretched by Windows, and this machine's primary display runs
        // at 150%: the 7x pixel art was landing on 10.5-device-pixel boundaries
        // (soft, uneven edges), and the low-level mouse hook -- which always
        // reports PHYSICAL pixels -- stopped agreeing with the form's virtualised
        // coordinates, so head-pats were hit-tested against a rectangle 1.5x too
        // far out. InitDpi() makes the process DPI-aware and multiplies these
        // units out, so the pet keeps the same apparent size while the art lands
        // on whole device pixels.
        static int W = 340;
        static int H = 460;
        static double dpiScale = 1.0;
        static int S(int v) { return (int)Math.Round(v * dpiScale); }

        [DllImport("user32.dll")]
        static extern bool SetProcessDPIAware();

        // Idempotent. Program.Main passes true (the live pet renders at native
        // device pixels); the constructor passes false so the offscreen capture
        // harness can still render the 96-dpi baseline for comparison.
        public static void InitDpi(bool makeAware)
        {
            if (makeAware) { try { SetProcessDPIAware(); } catch { } }
            try
            {
                using (var g = Graphics.FromHwnd(IntPtr.Zero)) dpiScale = g.DpiX / 96.0;
            }
            catch { dpiScale = 1.0; }
            if (dpiScale < 1.0) dpiScale = 1.0;
            W = S(340);
            H = S(460);
        }
        static readonly Color MAGIC = Color.FromArgb(255, 1, 2, 3);   // transparency key

        // ---------------------------------------------------------------------
        //  Cat palette -- design "A cream tabby"
        // ---------------------------------------------------------------------
        static readonly Color FUR = Color.FromArgb(255, 255, 226, 178);      // cream body
        static readonly Color FUR_D = Color.FromArgb(255, 214, 168, 112);    // tabby stripes
        static readonly Color CHEST = Color.FromArgb(255, 255, 245, 226);    // chest patch
        static readonly Color EYE = Color.FromArgb(255, 122, 196, 120);      // green eyes
        static readonly Color BLUSH = Color.FromArgb(255, 240, 130, 140);    // cheeks
        static readonly Color LINE = Color.FromArgb(255, 112, 80, 60);       // outline
        static readonly Color TIE = Color.FromArgb(255, 61, 214, 208);       // accent teal
        static readonly Color HAIR = Color.FromArgb(255, 61, 214, 208);      // bubble / tray accent
        // ------------------------------------------------------------ speech
        //
        // Lines are chosen by situation: time of day for the greeting, the
        // action for the rest. The Chinese is written as \uXXXX escapes
        // because this file must stay pure ASCII (a .bat launches it and
        // cmd.exe reads batch text with the system ANSI codepage).
        // Source text lives in tools\lines.txt; tools\gen-lines.ps1 splices it in.

        static readonly string[] GREET_MORNING =
        {
            "\u65e9\u5b89\uff5e\u65b0\u7684\u4e00\u5929\uff01",
            "\u65e9\u4e0a\u597d\u5440\uff5e",
            "\u8fd9\u4e48\u65e9\u5c31\u8d77\u6765\u4e86\uff1f",
            "\u65e9\u4e0a\u597d\uff0c\u4eca\u5929\u4e5f\u8981\u52a0\u6cb9\u54e6"
        };
        static readonly string[] GREET_DAY =
        {
            "\u4e0b\u5348\u597d\uff5e",
            "\u5728\u5fd9\u4ec0\u4e48\u5462\uff1f",
            "\u4f11\u606f\u4e00\u4e0b\u561b\uff5e",
            "\u6211\u53c8\u6765\u770b\u4f60\u4e86"
        };
        static readonly string[] GREET_EVENING =
        {
            "\u665a\u4e0a\u597d\uff5e\u4eca\u5929\u8f9b\u82e6\u4e86",
            "\u5929\u9ed1\u4e86\uff0c\u5f00\u706f\u4e86\u5417\uff1f",
            "\u665a\u996d\u5403\u4e86\u5417\uff1f",
            "\u5fd9\u5b8c\u4e86\u5417\uff1f"
        };
        static readonly string[] GREET_NIGHT =
        {
            "\u8fd9\u4e48\u665a\u8fd8\u4e0d\u7761\u5417\u2026",
            "\u591c\u6df1\u4e86\u54e6\uff5e",
            "\u8be5\u4f11\u606f\u4e86\uff0c\u6211\u966a\u4f60",
            "\u71ac\u591c\u5bf9\u8eab\u4f53\u4e0d\u597d\u54e6"
        };
        static readonly string[] PETTED =
        {
            "\u597d\u75d2\u5440\uff5e",
            "\u5475\u5475\u5475",
            "\u522b\u95f9\u4e86\uff5e",
            "\u547c\u565c\u547c\u565c\u2026",
            "\u518d\u6478\u6478\uff5e",
            "\u8212\u670d\uff5e",
            "\u563f\u563f",
            "\u6478\u6478\u5934\uff5e",
            "\u518d\u5f80\u5de6\u8fb9\u4e00\u70b9\uff5e",
            "\u55ef\u2026\u8fd9\u91cc\u4e5f\u8981"
        };
        static readonly string[] PETTED_MANY =
        {
            "\u597d\u5f00\u5fc3\uff01\uff01",
            "\u6700\u559c\u6b22\u4f60\u4e86\uff5e",
            "\u505c\u4e0d\u4e0b\u6765\u5566\uff5e",
            "\u4eca\u5929\u600e\u4e48\u8fd9\u4e48\u70ed\u60c5",
            "\u597d\u5e78\u798f\uff5e"
        };
        static readonly string[] TAIL =
        {
            "\u522b\u62c9\u5c3e\u5df4\uff01",
            "\u55b5\uff01",
            "\u75db\u5566\uff5e",
            "\u90a3\u91cc\u4e0d\u53ef\u4ee5\u6478\uff01"
        };


        static readonly string[] STRETCH =
        {
            "\u4f38\u4e2a\u61d2\u8170\uff5e",
            "\u5514\u2026\uff08\u4f38\u5c55\uff09",
            "\u5750\u4e45\u4e86\u8981\u52a8\u4e00\u52a8\uff5e",
            "\u54ce\u5440\uff0c\u817f\u9ebb\u4e86"
        };
        static readonly string[] PLAY =
        {
            "\u966a\u6211\u73a9\uff01",
            "\u770b\u6211\u7684\uff01",
            "\u63a5\u62db\uff5e",
            "\u563f\u563f\u563f",
            "\u6765\u8ffd\u6211\u5440"
        };
        static readonly string[] DANCE =
        {
            "\u266a\uff5e",
            "\u8ddf\u7740\u8282\u594f\uff5e",
            "\u770b\u6211\u8df3\u821e\uff01",
            "\u4e00\u8d77\u6765\u561b\uff5e"
        };
        static readonly string[] MUSING =
        {
            "\u4eca\u5929\u5929\u6c14\u600e\u4e48\u6837\uff1f",
            "\u6709\u70b9\u65e0\u804a\u2026",
            "\u4f60\u5728\u505a\u4ec0\u4e48\u5440\uff1f",
            "\u8981\u4e0d\u8981\u4f11\u606f\u4e00\u4e0b\uff1f",
            "\u773c\u775b\u7d2f\u4e86\u8981\u770b\u770b\u8fdc\u5904\u54e6",
            "\u8bb0\u5f97\u559d\u6c34\uff5e",
            "\u6211\u4e00\u76f4\u90fd\u5728\u8fd9\u91cc\u54e6",
            "\u597d\u5b89\u9759\u5440\u2026",
            "\u5728\u60f3\u4ec0\u4e48\u5462\uff1f",
            "\u6478\u6478\u6211\u561b",
            "\u6211\u624d\u6ca1\u6709\u53d8\u80d6\uff01",
            "\u55b5\uff1f",
            "\u952e\u76d8\u597d\u5435\u2026",
            "\u4f60\u80fd\u770b\u89c1\u6211\u5417\uff1f",
            "\u522b\u592a\u7d2f\u4e86",
            "\u4f60\u6253\u5b57\u597d\u5feb\u5440",
            "\u6211\u6570\u4e86\u4e00\u4e0b\uff0c\u4f60\u4eca\u5929\u5f00\u4e86\u597d\u591a\u7a97\u53e3",
            "\u8981\u662f\u80fd\u51fa\u53bb\u8d70\u8d70\u5c31\u597d\u4e86"
        };
        static readonly string[] LEVELUP =
        {
            "\u597d\u611f\u5ea6\u63d0\u5347\u4e86\uff01",
            "\u6211\u4eec\u66f4\u4eb2\u8fd1\u4e86\u5462",
            "\u8c22\u8c22\u4f60\u966a\u7740\u6211\uff5e",
            "\u597d\u5f00\u5fc3\uff01"
        };
        static readonly string[] FAREWELL = { "\u4e0b\u6b21\u89c1\uff5e", "\u6211\u4f1a\u60f3\u4f60\u7684\u2026", "\u62dc\u62dc\uff5e" };
        static readonly string[] HINT = { "\u62d6\u6211\u79fb\u52a8 \u00b7 \u53cc\u51fb\u6362\u4f4d \u00b7 \u53f3\u952e\u83dc\u5355" };
        static readonly string[] BREAK =
        {
            "\u8be5\u8d77\u6765\u6d3b\u52a8\u4e00\u4e0b\u4e86\uff5e",
            "\u5750\u592a\u4e45\u4e86\uff0c\u52a8\u4e00\u52a8\u5427",
            "\u559d\u53e3\u6c34\u5427",
            "\u8ba9\u773c\u775b\u4f11\u606f\u4e00\u4e0b\uff1f",
            "\u5df2\u7ecf\u8fc7\u53bb\u597d\u4e45\u4e86\uff0c\u7ad9\u8d77\u6765\u8d70\u8d70",
            "\u8bb0\u5f97\u770b\u770b\u8fdc\u5904\u54e6"
        };
        static readonly string[] TIER =
        {
            "\u964c\u751f",
            "\u719f\u6089",
            "\u670b\u53cb",
            "\u597d\u670b\u53cb",
            "\u631a\u53cb",
            "\u5fc3\u4e4b\u53cb"
        };

        // Affection thresholds for each TIER entry. Affinity starts at 0 and
        // the last tier is the top of the meter.
        static readonly int[] TIER_AT = { 0, 20, 50, 100, 200, 400 };
        readonly Config cfg = new Config();
        readonly string dataDir;
        readonly string cfgPath;
        readonly Stopwatch clock = Stopwatch.StartNew();
        readonly Random rnd = new Random();
        readonly Dictionary<PetState, StateInfo> table = new Dictionary<PetState, StateInfo>();
        // The heartbeat. A field, not a local: a Timer that nothing references
        // gets collected and quietly stops ticking.
        System.Windows.Forms.Timer heartbeat;

        PetState state = PetState.Idle;
        long stateEnteredMs = 0;
        // When the current state may fall back to Idle. Kept per-visit instead of
        // read from table[] so a one-off long duration cannot become permanent.
        long stateMinUntilMs = 0;
        string bubbleText = null;
        long bubbleUntilMs = 0;
        long nextBlinkMs = 0;
        long nextMicroMs = 0;
        bool blinkClosed = false;

        bool dragging = false;
        Point dragOriginScreen;
        // "Do not disturb" switches. Both persist in config.json. quiet stops
        // every autonomous animation and every speech bubble; locked ignores the
        // drag (petting still works, because that arrives via the mouse hook).
        bool quiet = false;
        bool locked = false;
        Point dragOriginForm;
        long dragStartMs = 0;
        bool dragMoved = false;

        NotifyIcon tray;

        MouseHook hook;
        long lastPatMs = 0;
        long nextAutonomyMs = 0;
        int walkTargetX = int.MinValue;
        long walkUntilMs = 0;
        long lastSaveMs = 0;

        // Double-click centre-toggle. Remembers where the cat was so a second
        // double-click puts it back, instead of it being stuck in the middle.
        bool centred = false;
        Point preCentreLoc = Point.Empty;

        // Gate for one-shot reaction clips (fall over, tumble, reminder).
        //
        // The bug this prevents: Play() only resets Frame when the clip CHANGES.
        // Leaving the reaction (e.g. Sad -> clipPet) and re-entering it a few
        // seconds later therefore switched back to clipPet and restarted it at
        // frame 0 -- so the 1520 ms cat_a1 animation was chopped part way
        // through, over and over. On screen that is flicker plus several poses
                // superimposed on top of each other.
        //
        // While now < reactionGateMs a reaction clip is neither started nor
        // restarted, so whenever one does play it runs start to finish once.
        long reactionGateMs = 0;
        const int REACTION_SETTLE_MS = 3000;

        // ------------------------------------------------------- clip preview
        //
        // Plays every GIF in the pack in turn, labelled in the speech bubble.
        //
        // This exists because the agent CANNOT see the artwork, so deciding
        // which animation means "happy" and which means "fall over" was pure
        // guesswork. Watching the real window is also the only preview channel
        // proven to work on this machine -- an HTML page and a PNG contact
        // sheet both failed to reach the user. Reached from the tray menu.
        bool previewOn = false;
        int previewIdx = 0;
        long previewNextMs = 0;
        GifClip[] previewClips = null;

        // ---- Cat Fighter sprite animation -----------------------------------
        // spriteDir is the folder holding the GIFs; spritesOk stays false if the
        // art is missing, and OnPaint then simply draws nothing rather than
        // crashing. See CREDITS.txt for the CC-BY attribution.
        readonly AnimationPlayer player = new AnimationPlayer();
        readonly string root;
        string spriteDir;
        // Every clip in the Cat Fighter pack is used. They are picked by MEASURED
        // motion energy (changed pixels per second) and silhouette spread, because
        // the art cannot be looked at directly:
        //
        //   a5 2988 px/s spread 1.39  -> Play / Game   (busiest clip in the pack)

        //   a8 2175       spread 1.28  -> Surprise      (short + punchy, 720 ms)
        //   a6 2105       spread 1.22  -> Sad
        //   a9 1780       spread 1.28  -> Talking       (shortest clip, 600 ms)
        //   a3 1388       spread 1.22  -> Dancing
        //   a4 1362       spread 1.06  -> Stretch       (long + narrow)
        //   a7 1205       spread 1.44  -> Cheer         (petting combo reward)
        //   a2  976       spread 1.39  -> Reminder
        //   a1  716       spread 1.17  -> Happy         (gentle "being petted" wiggle)
        //
        // a1 is the LEAST animated clip in the pack -- fewer changed pixels per
        // second than simply standing idle -- which is why it is only used for the
        // gentle petting wiggle, and every louder reaction got its own clip.
        GifClip clipIdle, clipWalk, clipJump, clipPet, clipSad;
        GifClip clipPlay, clipDance, clipStretch, clipCheer, clipSurprise, clipTalk, clipRemind;
        bool spritesOk = false;
        long clipOverrideUntilMs = 0;
        // Bumped whenever a new one-shot reaction begins, so OnPaint can rewind
        // the clip even when it is the same clip that is already playing.
        int clipRestartToken = 0;
        int lastRestartToken = 0;
        // Petting streak, so patting her repeatedly escalates into a Cheer.
        int comboCount = 0;
        long comboWindowMs = 0;
        // Deadline for the next "you have been sitting too long" break reminder.
        // MUST be seeded in the constructor: 0 would mean "already overdue", and
        // the reminder would fire on the very first idle tick after launch.
        long nextReminderMs = 0;
        // Top of the affection meter. The old code capped at 999 while the bar
        // divided by 100, so the bar sat full from a fifth of the maximum.
        const int AFFINITY_MAX = 400;
        int spriteScale = 5;
        // The user's size preference as a fraction. InitDpi() has already folded
        // the monitor DPI into W/H by the time this is applied, so the two
        // multiply: a 150% display and a 125% preference give 1.5 * 1.25.
        double userScale = 1.0;
        // Always 0 today; kept as the hook for tilting her when she is carried.
        double spriteAngle = 0;
        double spriteBob = 0;
        // Mirrored horizontally when she walks or is carried to the left, so she
        // faces the way she is going instead of moonwalking.
        bool spriteFlip = false;

        public PetForm(string root, string dataDir, string cfgPath)
        {
            InitDpi(false);
            this.root = root;
            this.dataDir = dataDir;
            this.cfgPath = cfgPath;

            table[PetState.Idle] = new StateInfo(PetState.Idle, 0, 0, true);
            table[PetState.Stretch] = new StateInfo(PetState.Stretch, 30, 1700, true);

            table[PetState.Sad] = new StateInfo(PetState.Sad, 55, 1600, true);
            table[PetState.Happy] = new StateInfo(PetState.Happy, 60, 1800, true);
            table[PetState.Play] = new StateInfo(PetState.Play, 65, 2600, true);
            table[PetState.Dancing] = new StateInfo(PetState.Dancing, 70, 3000, true);
            table[PetState.Cheer] = new StateInfo(PetState.Cheer, 75, 2400, true);
            table[PetState.Game] = new StateInfo(PetState.Game, 80, 2000, true);
            table[PetState.Surprise] = new StateInfo(PetState.Surprise, 85, 1300, true);
            table[PetState.Talking] = new StateInfo(PetState.Talking, 90, 1500, true);
            table[PetState.Reminder] = new StateInfo(PetState.Reminder, 100, 5000, true);

            LoadConfig();
            // Fold the saved size preference into W/H BEFORE the sprites are
            // fitted, because FitSpriteScale() derives the zoom from W. The form
            // itself is sized further down from these same W/H.
            ApplyScale(cfg.Scale / 100.0, false);
            LoadSprites();

            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.Manual;
            ShowInTaskbar = false;
            TopMost = cfg.TopMost;
            BackColor = MAGIC;
            TransparencyKey = MAGIC;
            Size = new Size(W, H);
            Text = "Desktop Cat";
            KeyPreview = true;
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint, true);
            UpdateStyles();

            // The pet is launched windowless, so anything that escapes the message
            // loop would otherwise kill it with no visible reason at all. Log it
            // instead, so a failure always leaves a trace in .petdata\pet.log.
            Application.ThreadException += delegate(object exSender, System.Threading.ThreadExceptionEventArgs te)
            { Note("UNHANDLED (ui): " + te.Exception); };
            AppDomain.CurrentDomain.UnhandledException += delegate(object exSender, UnhandledExceptionEventArgs ue)
            { Note("UNHANDLED (domain): " + ue.ExceptionObject); };

            int sw = Screen.PrimaryScreen.WorkingArea.Width;
            int sh = Screen.PrimaryScreen.WorkingArea.Height;
            // -1/-1 is the "never saved a position" sentinel and nothing else. Y
            // may now be NEGATIVE on purpose: the window is taller than the art,
            // so her head only reaches the top edge while the window hangs off it.
            if (!(cfg.X == -1 && cfg.Y == -1))
            {
                // a real saved position -- keep it, even a negative one
            }
            else
            {
                cfg.X = sw - W - 40;
                cfg.Y = sh - H - 20;
            }
            cfg.X = Math.Max(0, Math.Min(cfg.X, sw - W));
            cfg.Y = Math.Max(-ArtworkTopRoom(), Math.Min(cfg.Y, sh - H));
            Location = new Point(cfg.X, cfg.Y);

            // Restore previous state if set
            InitTray();
            InitHook();

            // The right-click menu. Handing it to the form lets WinForms raise it
            // through WM_CONTEXTMENU, which fires on button UP. Showing it by hand
            // from OnMouseDown -- while the button was still held down -- produced a
            // menu that appeared but then swallowed every click.
            ContextMenuStrip = BuildMenu();

            SetState(PetState.Happy, 2200);
            // Greeting follows the clock, and mentions the tier she remembers you
            // at -- a small reason to feel the relationship is continuous.
            Bubble(Pick(GreetLines()), 4200);
            if (Tier() > 0) Bubble(Pick(GreetLines()) + "  " + TierName(), 4200);
            nextAutonomyMs = clock.ElapsedMilliseconds + 9000;
            // First break reminder 7-14 minutes in. Seeding this here is what
            // stops the reminder firing immediately at launch (see the field).
            nextReminderMs = clock.ElapsedMilliseconds + 7 * 60000 + rnd.Next(0, 7 * 60000);

            // ------------------------------------------------------ heartbeat
            //
            //  The state machine, the micro-behaviour deadlines and StepWalk --
            //  which slides the window 5 px per tick -- all used to be driven by
            //  Application.Idle. Application.Idle is not a clock: it fires once
            //  when the message queue drains, and then the thread blocks in
            //  GetMessage until a message arrives. In v1.0 the unconditional
            //  Invalidate() at the end of OnIdle was what kept posting WM_PAINT,
            //  and that is what kept this whole program ticking, several hundred
            //  to a few thousand times a second.
            //
            //  Gating the repaint -- the fix for the 78 %-of-a-core idle cost --
            //  silently took the heartbeat away with it. Measured with an
            //  instrument that forces a walk and counts how often her position
            //  changes, inside a message loop nothing else feeds: she moved
            //  exactly ONE step of 5 px in 2 s, 2.5 px/s. She was not walking,
            //  she was twitching once per repaint, and the user saw it as
            //  "much choppier than the git version".
            //
            //  So the heartbeat is explicit now, and the paint stays gated and
            //  frame-driven on top of it. 15 ms is about 64 Hz: enough for
            //  smooth motion, and the tick itself only compares numbers, so a
            //  still cat still costs almost nothing.
            heartbeat = new System.Windows.Forms.Timer();
            heartbeat.Interval = 15;
            heartbeat.Tick += OnIdle;
            heartbeat.Start();
        }


        // ---------------------------------------------------------------------
        //  Load the Cat Fighter sprites and work out the integer zoom.
        //
        //  Nearest-neighbour with an INTEGER scale factor is the whole point:
        //  fractional scaling or smooth interpolation turns crisp pixel art
        //  into mush.
        // ---------------------------------------------------------------------
        void LoadSprites()
        {
            string[] roots = new string[]
            {
                Path.Combine(root, "cat-assets", "ex-F-cat-anim-pack"),
                Path.Combine(root, "cat-assets"),
                Path.Combine(dataDir, "cat-assets")
            };

            foreach (var r in roots)
            {
                if (!Directory.Exists(r)) continue;
                if (!File.Exists(Path.Combine(r, "cat_idle.gif"))) continue;
                spriteDir = r;
                break;
            }
            if (spriteDir == null) { Note("sprite dir not found; pet will draw nothing"); return; }

            try
            {
                // Each clip is loaded independently and may fall back: the ZIP
                // does not contain cat_walk_new.gif, which lives only at the
                // top level of cat-assets.
                clipIdle = LoadFirst(spriteDir, "idle", "cat_idle.gif");
                clipWalk = LoadFirst(spriteDir, "walk", "cat_walk_new.gif", "cat_walk.gif");
                clipJump = LoadFirst(spriteDir, "jump", "cat_jump.gif");
                clipPet = LoadFirst(spriteDir, "pet", "cat_a1.gif");


                // Sad gets its own clip. Ranked by measured motion energy,
                // cat_a6 is 2105 px/s against cat_a1's 716 -- nearly triple the
                // movement, so the sad reaction actually reads as a reaction
                // instead of the cat standing there.
                clipSad = LoadFirst(spriteDir, "sad", "cat_a6.gif");

                // The remaining action clips, previously unused. Assignment is by
                // measured motion energy and silhouette spread (see the table in
                // the field declarations above).
                clipPlay = LoadFirst(spriteDir, "play", "cat_a5.gif");
                clipDance = LoadFirst(spriteDir, "dance", "cat_a3.gif");
                clipStretch = LoadFirst(spriteDir, "stretch", "cat_a4.gif");
                clipCheer = LoadFirst(spriteDir, "cheer", "cat_a7.gif");
                clipSurprise = LoadFirst(spriteDir, "surprise", "cat_a8.gif");
                clipTalk = LoadFirst(spriteDir, "talk", "cat_a9.gif");
                clipRemind = LoadFirst(spriteDir, "remind", "cat_a2.gif");

                if (clipIdle == null) { Note("no idle clip; pet will draw nothing"); return; }

                // Continuous cycles repeat; reaction / fall-over / lie-down
                // clips play once and then hold their final frame.
                if (clipJump != null) clipJump.Loop = false;

                if (clipPet != null) clipPet.Loop = false;
                if (clipSad != null) clipSad.Loop = false;
                if (clipStretch != null) clipStretch.Loop = false;
                if (clipSurprise != null) clipSurprise.Loop = false;
                if (clipTalk != null) clipTalk.Loop = false;
                if (clipRemind != null) clipRemind.Loop = false;
                // clipPlay, clipDance and clipCheer deliberately keep Loop = true:
                // they back sustained moods rather than one-shot reactions.


                // Diagnostic: prove transparency punching worked. Before the
                // fix every frame measured 50x50 (fully opaque); with the GCE
                // transparent colour removed the box collapses to the cat.
                Note("  idle frame0 content box = " + clipIdle.Frames[0].Bmp.Width + "x" +
                     clipIdle.Frames[0].Bmp.Height + "  (50x50 means transparency FAILED)");

                // Integer zoom, set by pixel budget rather than "fill the
                // window". The pack's idle frame is 18x30 AFTER the background
                // is punched out, and a fill-the-window fit lands on 13x, which
                // put a ~390 px tall cat on a 1707x1067 desktop -- far too big
                // for a companion.
                //
                // Target ~126 px wide (210 px tall at 30 px), which is a
                // readable but unobtrusive ~20% of screen height.
                //
                // Measured: 7x -> 126x210 px.  9x (the oversized one) -> 162x270.
                // 96-dpi units; InitDpi() has already applied dpiScale, so on the
                // 150% display this is 189 device px -> 189/18 = a clean 10x zoom.
                int fw = clipIdle.Frames[0].Bmp.Width;
                int fh = clipIdle.Frames[0].Bmp.Height;

                FitSpriteScale();

                spritesOk = true;
                WriteLaunchOutcome("OK");
                Note("sprites OK  dir=" + spriteDir + "  frame=" + fw + "x" + fh +
                     "  scale=" + spriteScale + "x  idleFrames=" + clipIdle.Frames.Length +
                     "  walkFrames=" + (clipWalk == null ? 0 : clipWalk.Frames.Length) +
                     "  clips=" + ClipCount());
            }
            catch (Exception ex)
            {
                spritesOk = false;
                WriteLaunchOutcome("SPRITE_FAIL: " + ex.Message);
                Note("sprite load FAILED: " + ex.Message);
            }
        }

        // Tries each candidate filename, preferring the local spriteDir and
        // falling back to the parent cat-assets folder. Returns null only if
        // none of them exist.
        GifClip LoadFirst(string dir, string name, params string[] files)
        {
            string parent = Path.GetDirectoryName(dir);
            foreach (var fn in files)
            {
                foreach (var d in new string[] { dir, parent })
                {
                    if (d == null) continue;
                    string p = Path.Combine(d, fn);
                    if (!File.Exists(p)) continue;
                    try
                    {
                        var c = LoadGifClip(p, name);
                        // The frame size is the shared crop box for the whole
                        // clip. It is logged because it drives the drawn size:
                        // every clip is scaled by spriteScale from ITS own box,
                        // so a mismatch here is directly visible on screen.
                        Note("  clip " + name + " <- " + fn + "  (" + c.Frames.Length + " frames)" +
                             "  box=" + c.Frames[0].Bmp.Width + "x" + c.Frames[0].Bmp.Height);
                        return c;
                    }
                    catch (Exception ex)
                    {
                        Note("  clip " + name + " from " + fn + " FAILED: " + ex.Message);
                    }
                }
            }
            Note("  clip " + name + " NOT FOUND (tried " + string.Join(", ", files) + ")");
            return null;
        }

        // Frame size in form pixels.
        int SpriteW { get { return spritesOk ? clipIdle.Frames[0].Bmp.Width * spriteScale : 0; } }
        int SpriteH { get { return spritesOk ? clipIdle.Frames[0].Bmp.Height * spriteScale : 0; } }

        // Where the art sits inside the form (bottom-centre anchored).
        //
        // These describe the IDLE sprite and are used for the click hit-test, so
        // they stay valid while other clips are on screen: the box she is petted
        // in should not move just because she happens to be mid-fall.
        int SpriteLeft { get { return (W - SpriteW) / 2; } }
        int SpriteTop { get { return H - 34 - SpriteH; } }

        void InitHook()
        {
            try
            {
                hook = new MouseHook();
                if (hook.Installed)
                {
                    hook.LeftButtonDown += OnGlobalClick;
                    Note("mouse hook installed");
                }
                else Note("mouse hook NOT installed (reactions limited to her own window)");
            }
            catch (Exception ex) { Note("hook failed: " + ex.Message); }
        }

        // Where the last painted frame actually landed, in CLIENT coordinates.
        // The old hit test used SpriteLeft/SpriteTop, which describe the IDLE
        // clip only: a wider pose (cheer is 26 px wide against idle's 18) stuck
        // out of that box, and the transparent margin inside it accepted clicks
        // that were nowhere near the cat.
        Bitmap hitBmp;
        Rectangle hitDest = Rectangle.Empty;
        bool hitFlip;

        // Vertical room between the top of the WINDOW and the top of the art.
        // Uses the tallest clip, so she can always be dragged until her ears
        // touch the screen's top edge, whichever pose she is in at the time.
        int ArtworkTopRoom()
        {
            GifClip[] every = { clipIdle, clipWalk, clipJump, clipPet, clipSad,
                                clipPlay, clipDance, clipStretch, clipCheer,
                                clipSurprise, clipTalk, clipRemind };
            int tallest = SpriteH;
            for (int i = 0; i < every.Length; i++)
            {
                if (every[i] == null || every[i].Frames == null || every[i].Frames.Length == 0) continue;
                int hh = every[i].Frames[0].Bmp.Height * spriteScale;
                if (hh > tallest) tallest = hh;
            }
            int room = H - S(34) - tallest;
            return room < 0 ? 0 : room;
        }

        // True only when the point is over a pixel the cat actually painted.
        bool HitCat(int sx, int sy)
        {
            if (!spritesOk || hitBmp == null || hitDest.Width <= 0 || hitDest.Height <= 0) return false;
            int lx = sx - Location.X;
            int ly = sy - Location.Y;
            int pad = S(3);
            if (lx < hitDest.Left - pad || lx > hitDest.Right + pad) return false;
            if (ly < hitDest.Top - pad || ly > hitDest.Bottom + pad) return false;
            if (spriteAngle != 0) return true;          // rotated: keep the box test
            double fx = (lx - hitDest.Left) / (double)hitDest.Width;
            if (hitFlip) fx = 1.0 - fx;
            double fy = (ly - hitDest.Top) / (double)hitDest.Height;
            int ix = (int)Math.Floor(fx * hitBmp.Width);
            int iy = (int)Math.Floor(fy * hitBmp.Height);
            // Background is punched to alpha 0, so alpha is the whole test.
            for (int oy = -1; oy <= 1; oy++)
                for (int ox = -1; ox <= 1; ox++)
                {
                    int x = ix + ox, y = iy + oy;
                    if (x < 0 || y < 0 || x >= hitBmp.Width || y >= hitBmp.Height) continue;
                    if (hitBmp.GetPixel(x, y).A >= 40) return true;
                }
            return false;
        }

        // A window-level guard on top of the pixel test: a hit test that does not
        // land on her artwork belongs to whatever is underneath, never to her.
        const int WM_NCHITTEST = 0x0084;
        const int HTTRANSPARENT = -1;
        const int HTCLIENT = 1;

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WM_NCHITTEST)
            {
                int lp = m.LParam.ToInt32();
                int sx = (short)(lp & 0xFFFF);
                int sy = (short)((lp >> 16) & 0xFFFF);
                m.Result = (IntPtr)(HitCat(sx, sy) ? HTCLIENT : HTTRANSPARENT);
                return;
            }
            base.WndProc(ref m);
        }

        // Fired for every left click anywhere on the desktop.
        void OnGlobalClick(int sx, int sy)
        {
            long now = clock.ElapsedMilliseconds;
            if (now - lastPatMs < 900) return;

            // Where in the artwork did the click land? The sprite box is split by
            // relative position instead of one head circle, so the head, the body
            // and the tail each react differently -- patting the tail is not the
            // same act as patting the head.
            if (HitCat(sx, sy))
            {
                {
                    float bx = Location.X + hitDest.Left;
                    float by = Location.Y + hitDest.Top;
                    lastPatMs = now;
                    float relY = (sy - by) / (float)SpriteH;          // 0 = top, 1 = feet
                    float relX = (sx - bx) / (float)SpriteW;          // 0 = left, 1 = right
                    bool low = relY > 0.72f;
                    bool offCentre = Math.Abs(relX - 0.5f) > 0.26f;

                    if (low && offCentre)
                    {
                        // Grabbed the tail. She is not amused, and the streak breaks.
                        comboCount = 0;
                        cfg.Affinity = Math.Max(0, cfg.Affinity - 1);
                        SaveConfig();
                        SetState(PetState.Sad, 1600, true);
                        Bubble(Pick(TAIL), 1800);
                    }
                    else
                    {
                        Pet(relY < 0.36f);                            // head zone
                    }
                    return;
                }
            }

            // Otherwise: if the click is far away, she gets curious and walks over.
            if (now > nextAutonomyMs && !dragging)
            {
                nextAutonomyMs = now + rnd.Next(20000, 45000);

                // Only walk within the monitor the CAT is on, and only if the
                // click was on that same monitor. Using the clicked point's
                // screen here made a click on the other monitor teleport her
                // across, because the clamped target was on the far screen.
                var catScreen = Screen.FromPoint(new Point(Location.X + W / 2, Location.Y + H / 2));
                var clickScreen = Screen.FromPoint(new Point(sx, sy));
                if (catScreen.DeviceName == clickScreen.DeviceName)
                {
                    var scr = catScreen.WorkingArea;
                    int target = sx - W / 2;
                    if (!quiet && Math.Abs(target - Location.X) > 130)
                    {
                        walkTargetX = Math.Max(scr.Left, Math.Min(target, scr.Right - W));
                        walkUntilMs = now + 6000;
                        Bubble("\u6765\u5566~", 1500);
                    }
                }
            }
        }

        // Walking keeps her own Y but slides X toward walkTargetX.
        void StepWalk(long now)
        {
            if (walkTargetX == int.MinValue) return;
            if (now > walkUntilMs) { walkTargetX = int.MinValue; return; }

            int dx = walkTargetX - Location.X;
            if (Math.Abs(dx) < 6) { walkTargetX = int.MinValue; SetState(PetState.Happy, 1000); return; }

            int step = Math.Sign(dx) * 5;
            spriteFlip = (step < 0);          // face the way she is walking
            Location = new Point(Location.X + step, Location.Y);
        }

        void Note(string s)
        {
            try { File.AppendAllText(Path.Combine(dataDir, "pet.log"), DateTime.Now.ToString("HH:mm:ss.fff") + " " + s + Environment.NewLine); }
            catch { }
        }

        // Records how THIS launch ended, for the .bat launcher to read back. Kept
        // separate from pet.log so a rejected second launch never has to touch --
        // or delete -- the log of the instance that is already running.
        void WriteLaunchOutcome(string s)
        {
            try { File.WriteAllText(Path.Combine(dataDir, "last-launch.txt"), s); }
            catch { }
        }

        string Pick(string[] a) { return a[rnd.Next(a.Length)]; }

        // ---------------------------------------------------------- personality


        static string[] GreetLines()
        {
            int h = DateTime.Now.Hour;
            if (h >= 5 && h < 11) return GREET_MORNING;
            if (h >= 11 && h < 18) return GREET_DAY;
            if (h >= 18 && h < 23) return GREET_EVENING;
            return GREET_NIGHT;
        }

        // Affection tier. Thresholds live in TIER_AT, names in TIER.
        int Tier()
        {
            int t = 0;
            for (int i = 0; i < TIER_AT.Length; i++) if (cfg.Affinity >= TIER_AT[i]) t = i;
            return t;
        }

        string TierName()
        {
            int t = Tier();
            return (t < TIER.Length) ? TIER[t] : TIER[TIER.Length - 1];
        }

        // Affinity needed for the next tier, or the top of the meter already.
        int NextTierAt()
        {
            int t = Tier() + 1;
            return (t < TIER_AT.Length) ? TIER_AT[t] : TIER_AT[TIER_AT.Length - 1];
        }

        // One menu, two ways to reach it: the tray icon and a right-click on the
        // cat herself. The second copy is not decoration -- Windows 11 files a
        // brand-new program's tray icon into the hidden overflow by default, which
        // made the menu, and with it Quit, effectively unreachable. Right-clicking
        // her is now the dependable way in, and it needs no tray at all.
        // 75/100/125/150 -- the four entries of the size submenu.
        static readonly int[] ScalePcts = new int[] { 75, 100, 125, 150 };
        ToolStripMenuItem[] scaleItems = null;

        // Exactly one size entry is ticked: the one closest to the live scale.
        void SyncScaleMenu()
        {
            if (scaleItems == null) return;
            int best = 0;
            for (int i = 0; i < scaleItems.Length && i < ScalePcts.Length; i++)
            {
                if (Math.Abs(cfg.Scale - ScalePcts[i]) < Math.Abs(cfg.Scale - ScalePcts[best])) best = i;
            }
            for (int i = 0; i < scaleItems.Length; i++)
            {
                if (scaleItems[i] != null) scaleItems[i].Checked = (i == best);
            }
        }

        ContextMenuStrip BuildMenu()
        {
            var menu = new ContextMenuStrip();
            // Logged on purpose. If the menu ever appears but does nothing again, the
            // pet's own log says whether the click reached the menu at all, which is
            // the difference between "the wrong menu" and "the click never arrived".
            menu.Opening += delegate { Note("menu opening"); };
            menu.ItemClicked += delegate(object src, ToolStripItemClickedEventArgs a) { Note("menu item clicked: " + a.ClickedItem.Text); };

            // The whole menu is Chinese now. It used to be a mix -- "Play / <hanzi>"
            // sitting next to a bare "Quit" and "Center on screen" -- and a
            // reviewer called that out in so many words: the translation was
            // incomplete, and their line was "half translated is not translated at
            // all -- where is the Chinese for quit? i18n". Half-translated reads
            // worse than either extreme. Chinese is written as \uXXXX escapes
            // because this file has to stay pure ASCII; tools\menu-strings.txt
            // holds the source text these escapes were generated from.
            menu.Items.Add(new ToolStripMenuItem("\u6478\u6478\u5934", null, delegate { Pet(true); }));
            menu.Items.Add(new ToolStripMenuItem("\u966a\u6211\u73a9", null, delegate { SetState(PetState.Play, 2600, true); Bubble(Pick(PLAY), 2000); }));
            menu.Items.Add(new ToolStripMenuItem("\u8df3\u821e", null, delegate { SetState(PetState.Dancing, 3000, true); Bubble(Pick(DANCE), 2000); }));
            menu.Items.Add(new ToolStripMenuItem("\u4f38\u61d2\u8170", null, delegate { SetState(PetState.Stretch, 1700, true); Bubble(Pick(STRETCH), 1600); }));
            menu.Items.Add(new ToolStripMenuItem("\u6492\u6b22", null, delegate { SetState(PetState.Cheer, 2400, true); Bubble(Pick(PETTED_MANY), 1800); }));
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(new ToolStripMenuItem("\u56de\u5230\u5c4f\u5e55\u4e2d\u592e", null, delegate { CenterOn(); }));
            menu.Items.Add(new ToolStripMenuItem("\u72b6\u6001\u4e0e\u7f72\u540d", null, delegate { ShowInfo(); }));
            menu.Items.Add(new ToolStripMenuItem("\u9884\u89c8\u6240\u6709\u52a8\u4f5c", null, delegate { StartPreview(); }));

            // ---- size ----
            // The tick is NOT computed here any more. It used to be, once, at
            // startup -- BuildMenu() only runs when the form and the tray icon are
            // created, so the menu kept showing whatever size was current back
            // then, however many times the size was actually changed. It is
            // re-derived from the live cfg.Scale instead: on every open of this
            // submenu, and right after a size is picked.
            var miSize = new ToolStripMenuItem("\u5927\u5c0f");
            int[] pct = new int[] { 75, 100, 125, 150 };
            string[] lbl = new string[] { "\u5c0f", "\u6807\u51c6", "\u5927", "\u7279\u5927" };
            scaleItems = new ToolStripMenuItem[pct.Length];
            for (int i = 0; i < pct.Length; i++)
            {
                // p is declared inside the loop on purpose: a captured for-loop
                // variable is shared between iterations before C# 5, which would
                // make every entry apply the last value.
                int p = pct[i];
                var mi = new ToolStripMenuItem(lbl[i] + "  " + p + "%");
                scaleItems[i] = mi;
                mi.Click += delegate { ApplyScale(p / 100.0, true); SyncScaleMenu(); Note("scale -> " + p + "%"); };
                miSize.DropDownItems.Add(mi);
            }
            miSize.DropDownOpening += delegate { SyncScaleMenu(); };
            SyncScaleMenu();
            menu.Items.Add(miSize);
            menu.Items.Add(new ToolStripSeparator());

            // "Do not disturb" switches. CheckOnClick flips Checked BEFORE the
            // Click handler runs, so reading it there gives the new value. The
            // menu is rebuilt on every open, so the ticks always tell the truth.
            var miQuiet = new ToolStripMenuItem("\u5b89\u9759\u6a21\u5f0f");
            miQuiet.CheckOnClick = true;
            miQuiet.Checked = quiet;
            miQuiet.Click += delegate { quiet = miQuiet.Checked; SaveConfig(); Note("quiet -> " + quiet); };
            menu.Items.Add(miQuiet);

            var miLock = new ToolStripMenuItem("\u9501\u5b9a\u4f4d\u7f6e");
            miLock.CheckOnClick = true;
            miLock.Checked = locked;
            miLock.Click += delegate { locked = miLock.Checked; SaveConfig(); Note("locked -> " + locked); };
            menu.Items.Add(miLock);

            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(new ToolStripMenuItem("\u91cd\u7f6e\u597d\u611f\u5ea6", null, delegate
            {
                cfg.Affinity = 0; cfg.Interactions = 0; comboCount = 0;
                SaveConfig(); Bubble("...", 1500);
            }));
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(new ToolStripMenuItem("\u9000\u51fa", null, delegate { Quit(); }));
            return menu;
        }

        void InitTray()
        {
            try
            {
                var bmp = new Bitmap(16, 16);
                using (var g = Graphics.FromImage(bmp))
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    g.Clear(Color.Transparent);
                    using (var b = new SolidBrush(HAIR)) g.FillEllipse(b, 1, 1, 14, 14);
                    using (var b = new SolidBrush(Color.White)) g.FillEllipse(b, 5, 5, 3, 3);
                    using (var b = new SolidBrush(Color.White)) g.FillEllipse(b, 9, 5, 3, 3);
                }
                tray = new NotifyIcon();
                tray.Icon = Icon.FromHandle(bmp.GetHicon());
                tray.Text = "\u684c\u9762\u5c0f\u732b Desktop Cat";
                tray.Visible = true;
                tray.ContextMenuStrip = BuildMenu();
                tray.DoubleClick += delegate { Pet(true); };
            }
            catch (Exception ex)
            {
                Note("TRAY FAILED: " + ex.Message);
            }
        }

        // Double-click toggles: centre on the monitor the cat is CURRENTLY on,
        // or return to where it was.
        //
        // This used to be Screen.PrimaryScreen unconditionally, which yanked the
        // cat off whichever monitor it had been living on and dumped it in the
        // primary screen's middle. On a two-monitor setup that reads as the cat
        // teleporting away for no reason.
        void CenterOn()
        {
            walkTargetX = int.MinValue;          // cancel any walk in progress

            if (centred)
            {
                // go back where it was
                Location = preCentreLoc;
                centred = false;
            }
            else
            {
                preCentreLoc = Location;
                var wa = Screen.FromControl(this).WorkingArea;   // the cat's own screen
                Location = new Point(wa.Left + (wa.Width - W) / 2, wa.Top + (wa.Height - H) / 2);
                centred = true;
            }

            cfg.X = Location.X; cfg.Y = Location.Y; SaveConfig();
        }

        public void Quit()
        {
            SaveConfig();
            if (hook != null) { try { hook.Dispose(); } catch { } }
            if (tray != null) { tray.Visible = false; tray.Dispose(); }
            Application.Exit();
        }

        // Stats + the CC-BY attribution, in one reachable place.
        void ShowInfo()
        {
            int tier = Tier();
            int nextAt = NextTierAt();
            int nowTier = TIER_AT[tier];
            int span = nextAt - nowTier;
            int into = cfg.Affinity - nowTier;
            string progress = (span <= 0)
                ? "\u5df2\u8fbe\u5230\u6700\u9ad8\u7ea7"
                : (into + " / " + span);

            // Chinese throughout, built from \uXXXX escapes so this file stays
            // pure ASCII. Labels are padded to five cells with U+3000 (an
            // ideographic space, exactly 1 em wide in Microsoft YaHei UI) so the
            // colons line up regardless of a label being 3 or 4 characters.
            // Source text: tools\info-strings.txt.
            string n = Environment.NewLine;
            string body =
                "\u684c\u9762\u5c0f\u732b Desktop Cat" + n +
                "-------------------------------------------------------------" + n +
                "\u597d\u611f\u5ea6\u3000\u3000\uff1a" + cfg.Affinity + "\u3000\uff08" + TierName() + "\uff09" + n +
                "\u8ddd\u4e0b\u4e00\u7ea7\u3000\uff1a" + progress + n +
                "\u4e92\u52a8\u6b21\u6570\u3000\uff1a" + cfg.Interactions + n +
                "\u52a8\u753b\u6570\u91cf\u3000\uff1a" + ClipCount() + "\u4e2a\u52a8\u4f5c" + n +
                "\u672c\u6b21\u8fd0\u884c\u3000\uff1a" + (int)(clock.ElapsedMilliseconds / 1000) + "\u79d2" + n +
                "\u5c4f\u5e55\u4f4d\u7f6e\u3000\uff1a" + Location.X + ", " + Location.Y + n +
                "\u7a97\u53e3\u7f6e\u9876\u3000\uff1a" + (cfg.TopMost ? "\u662f" : "\u5426") + n +
                "\u5f53\u524d\u5c3a\u5bf8\u3000\uff1a" + cfg.Scale + "%" + n +
                "\u6570\u636e\u76ee\u5f55\u3000\uff1a" + dataDir + n +
                n +
                "\u73a9\u6cd5" + n +
                "-------------------------------------------------------------" + n +
                "  \u70b9\u5934\u9876\uff1a\u5979\u6700\u5f00\u5fc3\uff0c\u597d\u611f\u5ea6 +2" + n +
                "  \u70b9\u8eab\u4f53\uff1a\u597d\u611f\u5ea6 +1" + n +
                "  \u70b9\u5c3e\u5df4\uff1a\u5979\u4f1a\u4e0d\u9ad8\u5174\uff0c\u597d\u611f\u5ea6 -1" + n +
                "  \u8fde\u70b9\u4e94\u4e0b\uff1a\u8fde\u7eed\u629a\u6478\uff0c\u5979\u4f1a\u6492\u6b22" + n +
                "  \u62d6\u52a8\uff1a\u628a\u5979\u642c\u5230\u522b\u7684\u5730\u65b9" + n +
                "  \u53cc\u51fb\uff1a\u5728\u8fd9\u4e00\u5c4f\u5c45\u4e2d\uff0c\u518d\u53cc\u51fb\u56de\u539f\u4f4d" + n +
                "  \u6eda\u8f6e\uff1a\u624b\u52a8\u52a0\u51cf\u597d\u611f\u5ea6" + n +
                "  Esc\uff1a\u9000\u51fa" + n +
                n +
                "\u9700\u8981\u6ce8\u660e\u51fa\u5904\u7684\u7d20\u6750\uff08\u8bb8\u53ef\u8bc1\u8981\u6c42\uff09" + n +
                "-------------------------------------------------------------" + n +
                "  Cat Fighter \u50cf\u7d20\u7d20\u6750" + n +
                "  \u4f5c\u8005 dogchicken" + n +
                "  https://opengameart.org/content/cat-fighter-sprite-sheet" + n +
                "  \u8bb8\u53ef\u8bc1\uff1aCC-BY 3.0 (https://creativecommons.org/licenses/by/3.0/)" + n +
                n +
                "  \u8be5\u7d20\u6750\u672a\u7ecf\u4fee\u6539\u3001\u539f\u6837\u5206\u53d1\u300212 \u4e2a\u52a8\u4f5c\u5168\u90e8\u4f7f\u7528\uff0c" + n +
                "  \u9010\u5e27\u5bf9\u5e94\u5173\u7cfb\u89c1 CREDITS.txt\u3002" + n;

            try
            {
                var f = new InfoForm("\u684c\u9762\u5c0f\u732b \u00b7 \u72b6\u6001\u4e0e\u7f72\u540d", body);
                f.Show();
            }
            catch (Exception ex)
            {
                Note("ShowInfo failed: " + ex.Message);
            }
        }

        // How many clips actually loaded, for the stats panel.
        int ClipCount()
        {
            GifClip[] all = { clipIdle, clipWalk, clipJump, clipPet, clipSad,
                              clipPlay, clipDance, clipStretch, clipCheer, clipSurprise,
                              clipTalk, clipRemind };
            int c = 0;
            for (int i = 0; i < all.Length; i++) if (all[i] != null) c++;
            return c;
        }

        // ------------------------------------------------------------- config
        void LoadConfig()
        {
            try
            {
                if (File.Exists(cfgPath))
                {
                    string j = File.ReadAllText(cfgPath);
                    cfg.X = JInt(j, "x", cfg.X);
                    cfg.Y = JInt(j, "y", cfg.Y);
                    cfg.Affinity = JInt(j, "affinity", 0);
                    cfg.Interactions = JInt(j, "interactions", 0);
                    quiet  = JInt(j, "quiet", 0)  != 0;
                    locked = JInt(j, "locked", 0) != 0;
                    cfg.Scale = JInt(j, "scale", 100);
                    Note("config loaded x=" + cfg.X + " y=" + cfg.Y + " aff=" + cfg.Affinity +
                         " quiet=" + quiet + " locked=" + locked + " scale=" + cfg.Scale);
                }
                else Note("no config yet");
            }
            catch (Exception ex) { Note("LoadConfig failed: " + ex.Message); }
        }

        void SaveConfig()
        {
            try
            {
                cfg.X = Location.X; cfg.Y = Location.Y;
                var sb = new StringBuilder();
                sb.Append("{\n");
                sb.Append("  \"x\": ").Append(cfg.X).Append(",\n");
                sb.Append("  \"y\": ").Append(cfg.Y).Append(",\n");
                sb.Append("  \"affinity\": ").Append(cfg.Affinity).Append(",\n");
                sb.Append("  \"interactions\": ").Append(cfg.Interactions).Append(",\n");
                // 1/0 rather than true/false: JInt() reads them back, so the
                // whole config round-trips through the one tiny parser.
                sb.Append("  \"quiet\": ").Append(quiet ? 1 : 0).Append(",\n");
                sb.Append("  \"locked\": ").Append(locked ? 1 : 0).Append(",\n");
                sb.Append("  \"scale\": ").Append(cfg.Scale).Append(",\n");
                sb.Append("  \"topMost\": ").Append(cfg.TopMost ? "true" : "false").Append("\n");
                sb.Append("}\n");
                File.WriteAllText(cfgPath, sb.ToString());
            }
            catch (Exception ex) { Note("SaveConfig failed: " + ex.Message); }
        }

        static int JInt(string json, string key, int dflt)
        {
            try
            {
                int i = json.IndexOf("\"" + key + "\"");
                if (i < 0) return dflt;
                int c = json.IndexOf(':', i);
                if (c < 0) return dflt;
                int e = c + 1;
                while (e < json.Length && (char.IsWhiteSpace(json[e]) || json[e] == '-')) e++;
                int s = c + 1;
                while (s < json.Length && !char.IsDigit(json[s]) && json[s] != '-') s++;
                int f = s;
                while (f < json.Length && (char.IsDigit(json[f]) || json[f] == '-')) f++;
                int v;
                if (int.TryParse(json.Substring(s, f - s), out v)) return v;
            }
            catch { }
            return dflt;
        }

        // ------------------------------------------------------------- sizing
        //
        //  Resizes the pet to the user's preference. Steps that were measured on
        //  this machine (150% display, 1707x1067 logical / 2560x1600 physical):
        //
        //      75%  -> 7x zoom,  cat 126x210 device px
        //      100% -> 10x      cat 180x300
        //      125% -> 13x      cat 234x390
        //      150% -> 15x      cat 270x450
        //
        //  The four menu labels are menu-strings.txt lines 14..17; they are
        //  spliced in as \uXXXX escapes because this file must stay pure ASCII.
        //
        //  The zoom is an integer multiple of the 18x30 GIF frames, so it is
        //  quantised; these four steps are monotonic, which is all that matters.
        void FitSpriteScale()
        {
            if (clipIdle == null || clipIdle.Frames == null || clipIdle.Frames.Length == 0) return;
            int TARGET_W = S((int)Math.Round(126 * userScale));
            int fw = clipIdle.Frames[0].Bmp.Width;
            int byWidth = TARGET_W / fw;
            int maxFitW = (W - S(20)) / fw;
            // No height term: the cat is never tall enough for height to bind, and
            // including it only produced a confusing off-by-one that forced 6x.
            spriteScale = Math.Max(1, Math.Min(byWidth, maxFitW));
        }

        // applyNow == false is the construction-time path: W/H are set so that the
        // later "Size = new Size(W, H)" picks them up, but the Form is not sized
        // or positioned yet (and LoadSprites has not run, so FitSpriteScale
        // no-ops against a null clipIdle).
        void ApplyScale(double s, bool applyNow)
        {
            if (s < 0.5) s = 0.5;
            if (s > 2.0) s = 2.0;
            userScale = s;
            cfg.Scale = (int)Math.Round(s * 100);

            int oldW = W, oldH = H;
            W = S((int)Math.Round(340 * userScale));
            H = S((int)Math.Round(460 * userScale));
            FitSpriteScale();

            if (!applyNow) return;

            // Keep her feet on the same line and her centre where it was. Growing
            // from the top-left corner instead would walk her off the bottom edge
            // on every upward step.
            int cx = Left + oldW / 2;
            int bottom = Top + oldH;
            Size = new Size(W, H);
            Left = cx - W / 2;
            Top = bottom - H;

            var wa = Screen.FromPoint(new Point(Left + W / 2, Top + H / 2)).WorkingArea;
            if (Left < wa.Left) Left = wa.Left;
            // Same room as the drag clamp: the artwork sits far below the top of
            // the window, so the window has to be allowed to hang off the top
            // edge for her head to stay put when the size grows.
            int topRoom = ArtworkTopRoom();
            if (Top < wa.Top - topRoom) Top = wa.Top - topRoom;
            if (Left + W > wa.Right) Left = wa.Right - W;
            if (Top + H > wa.Bottom) Top = wa.Bottom - H;

            SaveConfig();
            Invalidate();
        }

        // -------------------------------------------------------------- FSM
        void SetState(PetState s, int minMs) { SetState(s, minMs, false); }

        // userInitiated == true means a person clicked or dragged the cat. That
        // must respond instantly, so it bypasses the autonomous reaction gate.
        void SetState(PetState s, int minMs, bool userInitiated)
        {
            // Quiet mode suppresses everything she does on her own, but anything
            // the person asked for (menu item, petting, dragging) still runs.
            if (quiet && !userInitiated) return;

            long now = clock.ElapsedMilliseconds;

            bool isReaction = (s == PetState.Happy || s == PetState.Sad ||
                               s == PetState.Reminder || s == PetState.Game ||
                               s == PetState.Talking || s == PetState.Stretch ||
                               s == PetState.Surprise || s == PetState.Cheer);

            bool oneShot = isReaction;

            // One autonomous one-shot at a time. The idle timer used to re-fire
            // while the previous tumble was barely over, so these clips ran
            // back to back with no breathing room -- which read as animations
            // piling up on top of each other.
            if (oneShot && !userInitiated && now < reactionGateMs) return;

            var cur = table[state];
            var next = table[s];
            if (next.Priority < cur.Priority && !cur.Interruptible) return;
            // The remaining two guards must ALSO let a user click through. They used
            // not to, so asking for a lower-priority state was silently dropped and
            // the menu looked broken -- confirmed by probing the compiled form.
            if (next.Priority < cur.Priority && !userInitiated && (now - stateEnteredMs) < cur.MinMs) return;
            if (state == s && s != PetState.Idle && !userInitiated) return;

            // Duration for THIS visit. It is deliberately not written back into the
            // table: table[] is shared static state for the whole session, so
            // "table[s].MinMs = minMs" used to make one call permanent. The boot
            // greeting made Happy 2200 forever, and each tray action rewrote its
            // state's duration again -- so the cat's behaviour drifted the longer
            // it ran.
            long wantMs = (minMs > table[s].MinMs) ? minMs : table[s].MinMs;

            state = s;
            stateEnteredMs = now;
            stateMinUntilMs = now + wantMs;
            Note("state -> " + s);

            if (oneShot)
            {
                // A one-shot clip interrupts the idle loop. The hold is derived
                // from the clip's OWN duration instead of a fixed guess, because a
                // short window cut the animation off part way and, since Play()
                // only resets Frame when the clip CHANGES, re-entering the state
                // restarted it from frame 0 -- the cat repeatedly collapsing on
                // top of itself.
                GifClip shot = OneShotClip(s);
                long clipMs = (shot == null ? 900 : shot.TotalMs);

                // ...but the hold must also cover the whole STATE. It used to be
                // clipMs + 120 (1640 ms) while the state lasted 1800 ms, so the
                // final 160 ms fell through DesiredClip() to clipIdle and the
                // pose snapped upright before the tumble had settled.
                long hold = clipMs + 120;
                if (wantMs + 120 > hold) hold = wantMs + 120;

                clipOverrideUntilMs = isReaction ? (now + hold) : 0;

                // A new reaction must replay its clip from frame 0 even if the
                // same clip is already the current one -- otherwise petting her
                // twice in a row leaves her parked on the held final frame.
                clipRestartToken++;

                // The rest interval is measured from the END of the animation,
                // not from the moment it started. Previously the next
                // micro-behaviour was scheduled at fire time, so the 1.8 s
                // reaction ate most of the 3-7 s window and left only ~1.2 s of
                // stillness between clips.
                reactionGateMs = now + hold + REACTION_SETTLE_MS;
                long rest = reactionGateMs + rnd.Next(800, 3200);
                if (rest > nextMicroMs) nextMicroMs = rest;
            }
            else
            {
                clipOverrideUntilMs = 0;
            }
        }

        // The clip backing a one-shot state. Kept in one place so the hold time
        // calculated in SetState can never drift from the clip DesiredClip shows.
        GifClip OneShotClip(PetState s)
        {
            switch (s)
            {

                case PetState.Sad: return clipSad;
                case PetState.Stretch: return clipStretch;
                case PetState.Surprise: return clipSurprise;
                case PetState.Talking: return clipTalk;
                case PetState.Reminder: return clipRemind;
                case PetState.Game: return clipPlay;
                case PetState.Cheer: return clipCheer;
                default: return clipPet;
            }
        }

        // Chooses which clip should be on screen right now.
        GifClip DesiredClip()
        {
            if (!spritesOk) return null;

            // Preview mode wins outright: it is showing one specific clip.
            if (previewOn && previewClips != null && previewIdx < previewClips.Length)
                return previewClips[previewIdx];

            // Being carried beats everything -- she tucks up as you carry her.
            if (dragging) return clipJump;

            // Walking uses the WALK cycle. Both dragging and walking used to
            // return clipJump, so she hopped sideways across the floor instead of
            // taking steps.
            if (walkTargetX != int.MinValue) return clipWalk;

            // Every state now has its own animation, so the switch alone decides;
            // the old clipOverride branch is gone. (clipOverrideUntilMs still
            // exists, but only to time the reaction gate in SetState.)
            switch (state)
            {

                case PetState.Stretch: return clipStretch;
                case PetState.Play: return clipPlay;
                case PetState.Game: return clipPlay;
                case PetState.Dancing: return clipDance;
                case PetState.Cheer: return clipCheer;
                case PetState.Surprise: return clipSurprise;
                case PetState.Talking: return clipTalk;
                case PetState.Reminder: return clipRemind;
                case PetState.Sad: return clipSad;
                case PetState.Happy: return clipPet;
                default: return clipIdle;
            }
        }

        void Bubble(string text, int ms)
        {
            // Quiet mode means no speech at all -- including the break reminder,
            // which is rather the point of switching it on in a meeting. She
            // still animates; she just stops talking.
            if (quiet) return;
            bubbleText = text;
            bubbleUntilMs = clock.ElapsedMilliseconds + ms;
        }

        // ---------------------------------------------------- preview methods
        void StartPreview()
        {
            if (spriteDir == null) { Bubble("no sprites", 2000); return; }
            try
            {
                var files = Directory.GetFiles(spriteDir, "cat_*.gif");
                Array.Sort(files);
                var list = new List<GifClip>();
                foreach (var f in files)
                {
                    // Loaded fresh, so these are separate objects from the clips
                    // the pet normally uses -- forcing Loop here cannot change
                    // how the one-shot reactions behave.
                    var c = LoadGifClip(f, Path.GetFileNameWithoutExtension(f));
                    c.Loop = true;          // preview must loop to be watchable
                    list.Add(c);
                }
                previewClips = list.ToArray();
                previewIdx = 0;
                previewNextMs = 0;
                previewOn = (previewClips.Length > 0);
                walkTargetX = int.MinValue;     // cancel any walk
                dragging = false;
                Note("preview: " + previewClips.Length + " clips");
            }
            catch (Exception ex) { Note("preview failed: " + ex.Message); }
        }

        void StopPreview()
        {
            if (!previewOn) return;
            previewOn = false;
            Bubble("preview off", 1500);
            Note("preview stopped");
        }

        // Public entry point: the tray menu uses StartPreview directly, but
        // PowerShell starts the pet with PET_PREVIEW=1 for a direct preview run.
        public void BeginPreview() { StartPreview(); }

        // Advances through the clips, showing each one's filename in the bubble.
        void StepPreview(long now)
        {
            if (!previewOn) return;

            if (previewClips == null || previewIdx >= previewClips.Length)
            {
                StopPreview();
                return;
            }

            var c = previewClips[previewIdx];

            if (previewNextMs == 0)
            {
                // First tick on this clip: label it and hold for its own length
                // plus a beat, so a 320 ms cycle is still readable.
                Bubble("[" + (previewIdx + 1) + "/" + previewClips.Length + "]  " +
                       c.Name + "  " + c.Frames.Length + "f  " + c.TotalMs + "ms", 3000);
                previewNextMs = now + c.TotalMs + 1400;
                return;
            }

            if (now >= previewNextMs) { previewIdx++; previewNextMs = 0; }
        }

        // ----------------------------------------------------- repaint pacing
        //
        //  Application.Idle fires as fast as the message pump empties. For an
        //  otherwise idle pet that is thousands of times per second, and every
        //  single one of those used to end in a full-window Invalidate().
        //
        //  Measured cost of that: 16.27 s of CPU time in a 20 s wall-clock
        //  idle window == 81 % of one whole core, 4.06 % of all 20 cores.
        //  It also starved the WH_MOUSE_LL hook, which runs on this very
        //  thread -- that is why a reviewer reported the pet "severely
        //  interferes with typing and with using the computer": it was not the
        //  pet stealing focus, it was this thread never being idle enough to
        //  return the hook callback promptly.
        //
        //  The state machine still runs on every idle tick (it has to: those
        //  are the checks that decide whether anything happens at all). Only
        //  the paint is gated.
        //
        //  v1.1's first attempt at that gate used a fixed 66 ms clock, about
        //  15 fps, on the theory that it was more than the clips need (their
        //  frame delays are 80-120 ms). It was cheap, and WRONG. The user
        //  caught it: "the animation is choppier now". The clip advances one
        //  frame every 80 ms from its own stopwatch while the gate opens every
        //  66 ms, and 66 does not divide 80, so the two beat against each
        //  other. Measured on the idle clip (4 frames x 80 ms), 6 s window:
        //
        //      paints                     91      (15.0 per second)
        //      repaints of a frame that
        //        was already on screen    16
        //      time each picture stayed
        //        on screen                min 62  median 63  max 141 ms
        //      spread                     sd 27.5 ms
        //      pictures that missed the
        //        80 ms the clip asked for 60 of 74
        //
        //  So: paint when the FRAME changes, not when a timer says so. The
        //  player already works out which frame is due from a real clock, and
        //  reading Current is what advances it, so the paint lands exactly on
        //  the frame boundary. One paint per frame is both smoother than the
        //  gate and cheaper than it: 12.5 fps instead of 15 fps on the idle
        //  clip, and no wasted repaints at all.
        //
        //  Anything that is not frame-driven -- bubble text, the hint, the
        //  affection hearts, dragging -- is picked up by a slow safety net.
        const int REPAINT_FALLBACK_MS = 200;   // 5 fps floor for everything else
        long lastPaintMs = 0;
        GifClip lastPaintClip = null;
        int lastPaintFrame = -2;

        void Repaint(long now)
        {
            GifClip clip = player.Clip;
            int frame = player.Current;                 // also advances the clip
            bool frameMoved = (clip != lastPaintClip) || (frame != lastPaintFrame);
            if (!frameMoved && (now - lastPaintMs) < REPAINT_FALLBACK_MS) return;
            lastPaintClip = clip;
            lastPaintFrame = frame;
            lastPaintMs = now;
            Invalidate();
        }

        // ------------------------------------------------- cached GDI+ objects
        //
        //  Every OnPaint used to build a fresh Font (and, for the bubble, a
        //  fresh GraphicsPath with four arcs and two Pens). On an unthrottled
        //  idle loop that is thousands of unmanaged GDI+ allocations per second.
        //  Nothing leaked -- they were all inside using blocks -- but the churn
        //  was a real part of the 81 %-of-a-core measurement. These live as long
        //  as the form does.
        Font fontBubble, fontHint, fontTier;

        Font Use(ref Font slot, float size)
        {
            if (slot == null) slot = new Font("Microsoft YaHei UI", size);
            return slot;
        }

        // ----------------------------------------------------- bubble anchoring
        //
        //  Top edge of the sprite in client coordinates, refreshed on every
        //  paint. The bubble was pinned to y = S(8) -- the very top of the
        //  window -- while the cat stands near the bottom, so it read as "the
        //  speech bubble is a mile away from the model", and it landed in
        //  exactly the same strip as the onboarding hint, which is why those two
        //  overlapped for the first 18 seconds of a session.
        //
        //  -1 means "no sprite measured yet, fall back to the old position".
        float catTopY = -1f;
        float hintTopY = -1f;

        void OnIdle(object sender, EventArgs e)
        {
            long now = clock.ElapsedMilliseconds;

            // Preview mode drives the clip directly and parks the state machine,
            // so the reaction gate and idle fidgeting cannot fight it.
            if (previewOn)
            {
                StepPreview(now);
                if (bubbleText != null && now > bubbleUntilMs) bubbleText = null;
                Repaint(now);
                return;
            }

            // Auto-return to Idle once this visit's own duration has elapsed.
            if (state != PetState.Idle)
            {
                if (now > stateMinUntilMs) SetState(PetState.Idle, 0);
            }

            // Blink scheduling
            if (now > nextBlinkMs)
            {
                if (blinkClosed) { blinkClosed = false; nextBlinkMs = now + rnd.Next(2200, 5200); }
                else { blinkClosed = true; nextBlinkMs = now + 110; }
            }

            // Break reminder: the one thing she says unprompted, and the only
            // thing this pet does that is actually useful rather than decorative.
            // Only fires from Idle so it never interrupts a reaction the user just
            // triggered. The first one lands 7-14 minutes in, then every 25-45
            // minutes: a reminder that fires often is just an irritation, and an
            // irritated user turns the reminder off.
            if (now > nextReminderMs && state == PetState.Idle)
            {
                nextReminderMs = now + rnd.Next(25 * 60000, 45 * 60000);
                SetState(PetState.Reminder, 5000, true);
                Bubble(Pick(BREAK), 5000);
                Note("break reminder fired; next at +" + ((nextReminderMs - now) / 1000) + "s");
            }

            // Idle micro-behaviour
            if (state == PetState.Idle && now > nextMicroMs)
            {
                // Cadence of idle fidgeting. Was 5000..12000, which left the cat
                // completely still for up to 12 s and read as "nothing is
                // happening". 3000..7000 keeps it visibly alive.
                nextMicroMs = now + rnd.Next(3000, 7000);

                // Sometimes she just says something instead of doing something.
                // Unconditional musing often: it is the cheapest way to make her
                // feel like she has a train of thought. Any action below that has
                // its own line overwrites this, which is the desired priority.
                if (rnd.Next(100) < 34) Bubble(Pick(MUSING), 2800);

                // SetState enforces the reaction gate itself, so these are safe
                // to call unconditionally.
                //
                // Weights are a percentage of idle rolls. Sad stays at 8% on
                // purpose: a companion that looks miserable a fifth of the time is
                // not pleasant to have on screen.
                int r = rnd.Next(100);

                if (r < 22)
                {
                    SetState(PetState.Happy, 1600);
                    if (state == PetState.Happy) Bubble(Pick(PETTED), 1500);
                }
                else if (r < 38)
                {
                    SetState(PetState.Play, 2400);
                    if (state == PetState.Play) Bubble(Pick(PLAY), 1800);
                }
                else if (r < 52)
                {
                    SetState(PetState.Stretch, 1700);
                    if (state == PetState.Stretch) Bubble(Pick(STRETCH), 1600);
                }
                else if (r < 64)
                {
                    // Loops, so it is safe as a sustained mood.
                    SetState(PetState.Dancing, 2600);
                    if (state == PetState.Dancing) Bubble(Pick(DANCE), 1800);
                }
                else if (r < 74)
                {
                    SetState(PetState.Surprise, 1300);
                    if (state == PetState.Surprise) Bubble("!?", 1200);
                }
                else if (r < 82)
                {
                    SetState(PetState.Sad, 1600);
                }
                else if (r < 88)
                {
                    // She talks to herself. Without this bucket the Talking state
                    // and cat_a9 were loaded but unreachable.
                    SetState(PetState.Talking, 1500);
                    if (state == PetState.Talking) Bubble(Pick(MUSING), 1600);
                }
                else
                {
                    // Cheer. This bucket used to be her nap; with the sleep clip
                    // gone it is the one action the idle roll had no other way to
                    // reach, and both the state and the clip already existed.
                    SetState(PetState.Cheer, 2400);
                    if (state == PetState.Cheer) Bubble(Pick(PETTED_MANY), 1800);
                }

                // The roll wanted a reaction but the gate is still shut (the
                // previous one is not done settling). Retry shortly instead of
                // sitting out another full 3-7 s idle interval.
                if (state == PetState.Idle) nextMicroMs = now + 1200;
            }

            if (bubbleText != null && now > bubbleUntilMs) bubbleText = null;

            StepWalk(now);

            if (now - lastSaveMs > 10000) { lastSaveMs = now; SaveConfig(); }

            Repaint(now);
        }

        // -------------------------------------------------------- interaction
        void Pet() { Pet(false); }

        // head == the click landed on her head, which is the spot she likes and
        // therefore builds affection (and the combo) faster.
        void Pet(bool head)
        {
            long now = clock.ElapsedMilliseconds;

            // Petting streak: repeated pets inside a rolling window escalate into
            // a Cheer instead of yet another small Happy wiggle.
            if (now < comboWindowMs) comboCount++; else comboCount = 1;
            comboWindowMs = now + 2600;

            int tierBefore = Tier();
            cfg.Interactions++;
            cfg.Affinity = Math.Min(AFFINITY_MAX, cfg.Affinity + (head ? 2 : 1));
            SaveConfig();

            if (comboCount >= 5)
            {
                comboCount = 0;
                SetState(PetState.Cheer, 2400, true);
                Bubble(Pick(PETTED_MANY), 2400);
            }
            else
            {
                // userInitiated: a click must always react at once, gate or no gate.
                SetState(PetState.Happy, 2000, true);
                Bubble(Pick(PETTED), 2000);
            }

            // Tier-up is announced after the reaction line so it is the last word.
            if (Tier() > tierBefore)
                Bubble(Pick(LEVELUP) + "  " + TierName(), 3400);
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            // Right-click is deliberately NOT handled here. The menu is the form's
            // ContextMenuStrip, so WinForms raises it from WM_CONTEXTMENU on button
            // UP. Showing it here, on button DOWN, produced a menu that appeared but
            // then ignored every click on its items.
            if (e.Button == MouseButtons.Left && !locked)
            {
                dragging = true;
                dragMoved = false;
                dragStartMs = clock.ElapsedMilliseconds;
                dragOriginScreen = Cursor.Position;
                dragOriginForm = Location;
            }
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            if (!dragging) return;
            Point now = Cursor.Position;
            int dx = now.X - dragOriginScreen.X;
            int dy = now.Y - dragOriginScreen.Y;
            if (Math.Abs(dx) > 3 || Math.Abs(dy) > 3) dragMoved = true;
            if (dragMoved)
            {
                if (Math.Abs(dx) > 3) spriteFlip = (dx < 0);   // face the way she is pulled
                int nx = dragOriginForm.X + dx;
                int ny = dragOriginForm.Y + dy;
                var scr = Screen.FromPoint(now).WorkingArea;
                nx = Math.Max(scr.Left - W / 3, Math.Min(nx, scr.Right - W * 2 / 3));
                ny = Math.Max(scr.Top - ArtworkTopRoom(), Math.Min(ny, scr.Bottom - 60));
                Location = new Point(nx, ny);
            }
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            base.OnMouseUp(e);
            if (e.Button != MouseButtons.Left) return;
            bool wasDrag = dragMoved;
            dragging = false;
            if (wasDrag)
            {
                cfg.X = Location.X; cfg.Y = Location.Y; SaveConfig();
                SetState(PetState.Happy, 1200, true);   // userInitiated: she was just moved
                centred = false;   // dragged deliberately: forget the centre toggle
            }
            else Pet();
        }

        protected override void OnMouseDoubleClick(MouseEventArgs e)
        {
            base.OnMouseDoubleClick(e);
            if (e.Button == MouseButtons.Right) return;
            CenterOn();
            Bubble("~\u266a", 1500);
        }

        protected override void OnMouseWheel(MouseEventArgs e)
        {
            base.OnMouseWheel(e);
            int d = e.Delta > 0 ? 10 : -10;
            cfg.Affinity = Math.Max(0, Math.Min(AFFINITY_MAX, cfg.Affinity + d));
            Bubble(TierName() + "  " + cfg.Affinity + " / " + NextTierAt(), 1800);
            SaveConfig();
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            base.OnKeyDown(e);
            if (e.KeyCode == Keys.Escape) Quit();
        }

        // ------------------------------------------------------------- render
        double Now() { return clock.ElapsedMilliseconds / 1000.0; }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;

            // Nothing used to fill the client area, so every pixel the cat does
            // not cover kept whatever the double buffer happened to hold instead
            // of the transparency key. Windows could not key those pixels out, so
            // the empty band above her head was a real part of the window: it
            // swallowed clicks that were nowhere near her. Fill it explicitly.
            g.Clear(MAGIC);

            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.TextRenderingHint = TextRenderingHint.AntiAlias;

            double t = Now();

            // ---------------------------------------------------------------
            //  Sprite draw.
            //
            //  The transform chain is fully saved and restored. The old
            //  hand-drawn renderer leaked its transforms, which was one of the
            //  reasons the figure came out mangled.
            // ---------------------------------------------------------------
            if (spritesOk)
            {
                var want = DesiredClip();
                player.Play(want);
                if (clipRestartToken != lastRestartToken)
                {
                    lastRestartToken = clipRestartToken;
                    player.Restart();
                }

                // gentle idle bob; stronger while she is being carried
                double bobT = dragging ? 4.5 : 1.6;
                spriteBob = -Math.Abs(Math.Sin(t * bobT)) * (dragging ? (double)S(6) : 0.0);
                spriteAngle = 0;

                var bmp = player.Bitmap;
                if (bmp != null)
                {
                    var st = g.Save();
                    g.ResetTransform();
                    // integer scale, nearest neighbour: keeps the pixels crisp
                    g.InterpolationMode = InterpolationMode.NearestNeighbor;
                    g.PixelOffsetMode = PixelOffsetMode.Half;
                    g.SmoothingMode = SmoothingMode.None;

                    // The destination MUST be sized from the frame actually being
                    // drawn, not from clipIdle.
                    //
                    // SpriteW/SpriteH come from clipIdle's cropped frame (18x30),
                    // but srcR below is the CURRENT clip's full bitmap -- and
                    // LoadGifClip gives every clip its OWN shared crop box, sized
                    // to the union of that clip's frames:
                    //
                    //     idle  18x30      pet (cat_a1) 21x29
                    //     walk  18x30      sad (cat_a6) 24x29
                    //     jump  18x31
                    //
                    // Drawing all of those into idle's fixed 126x210 box stretched
                    // each one by a different amount -- a 30 px wide frame came out
                    // 40% too narrow against the 18 px wide ones -- so the cat
                    // SNAPPED to a different size whenever the clip changed.
                    //
                    // Scale each frame by spriteScale instead, and anchor it to
                    // the same floor line (H-34) and the same horizontal centre,
                    // so the cat does not jump around when the clip changes. For
                    // clipIdle this is arithmetically identical to before.
                    int bw = bmp.Width, bh = bmp.Height;
                    float dw = bw * spriteScale;
                    float dh = bh * spriteScale;
                    float dx = (W - dw) / 2f;
                    float dy = H - S(34) - dh + (float)spriteBob;
                    catTopY = dy;                 // bubble anchors to this

                    if (spriteAngle != 0)
                    {
                        g.TranslateTransform(dx + dw / 2f, dy + dh / 2f);
                        g.RotateTransform((float)spriteAngle);
                        g.TranslateTransform(-(dx + dw / 2f), -(dy + dh / 2f));
                    }

                    // Mirror around the sprite's own centre so she faces the way
                    // she is travelling. Using the sprite centre (not the window
                    // centre) keeps her exactly where the destination rect says.
                    if (spriteFlip)
                    {
                        g.TranslateTransform(dx + dw / 2f, 0f);
                        g.ScaleTransform(-1f, 1f);
                        g.TranslateTransform(-(dx + dw / 2f), 0f);
                    }

                    var dest = new Rectangle((int)Math.Round(dx), (int)Math.Round(dy), (int)dw, (int)dh);
                    hitBmp = bmp; hitDest = dest; hitFlip = spriteFlip;
                    var srcR = new Rectangle(0, 0, bmp.Width, bmp.Height);
                    g.DrawImage(bmp, dest, srcR, GraphicsUnit.Pixel);

                    g.Restore(st);
                }
            }

            // Hint first, then the bubble. DrawHint records where it landed, so
            // the bubble can stack itself above the hint instead of colliding
            // with it; drawing the hint first also means the bubble wins the
            // z-order when the two ever do meet.
            hintTopY = -1f;
            if (dragging || clock.ElapsedMilliseconds < 18000) DrawHint(g);

            if (bubbleText != null) DrawBubble(g, bubbleText);

            // persistent affection bar, very subtle
            DrawAffection(g);
        }

        void DrawAffection(Graphics g)
        {
            int barW = S(90), barH = S(6);
            int x = (W - barW) / 2, y = H - S(14);

            using (var b = new SolidBrush(Color.FromArgb(70, 0, 0, 0)))
                g.FillRectangle(b, x, y, barW, barH);

            // The bar is normalised against the TOP tier, not against a hardcoded
            // 100: the old code capped affinity at 999 but divided by 100, so the
            // bar was pinned full from a quarter of the maximum.
            double frac = Math.Min(1.0, cfg.Affinity / (double)TIER_AT[TIER_AT.Length - 1]);
            int fill = (int)Math.Round(barW * frac);
            if (fill > 0)
                using (var b = new SolidBrush(Color.FromArgb(210, HAIR)))
                    g.FillRectangle(b, x, y, fill, barH);

            // Tier name above the bar, with a shadow so it survives on any wallpaper.
            string name = TierName();
            {
                var f = Use(ref fontTier, 8f);
                var sz = g.MeasureString(name, f);
                float tx = x + (barW - sz.Width) / 2f;
                float ty = y - sz.Height - 1;
                using (var sh = new SolidBrush(Color.FromArgb(200, 0, 0, 0)))
                    g.DrawString(name, f, sh, tx + 1, ty + 1);
                using (var fb = new SolidBrush(Color.FromArgb(235, 255, 255, 255)))
                    g.DrawString(name, f, fb, tx, ty);
            }
        }

        void DrawHint(Graphics g)
        {
            string s = HINT[0];
            var f = Use(ref fontHint, 8f);
            var sz = g.MeasureString(s, f);
            float x = (W - sz.Width) / 2f;

            // Just above her head. Falls back to the old top strip only if no
            // sprite has been measured yet.
            float hy = (catTopY > 0f ? catTopY - sz.Height - S(4) : (float)S(6));
            if (hy < S(2)) hy = S(2);
            hintTopY = hy;

            using (var sh = new SolidBrush(Color.FromArgb(190, 0, 0, 0)))
                g.DrawString(s, f, sh, x + 1, hy + 1);
            using (var b = new SolidBrush(Color.FromArgb(215, 255, 255, 255)))
                g.DrawString(s, f, b, x, hy);
        }

        void DrawBubble(Graphics g, string text)
        {
            var f = Use(ref fontBubble, 10.5f);
            SizeF sz = g.MeasureString(text, f);
            float padX = S(12), padY = S(8);
            float bw = sz.Width + padX * 2;
            float bh = sz.Height + padY * 2;
            float bx = (W - bw) / 2f;

            // Stack above the hint when it is visible, otherwise sit right above
            // her head. The clearance has to be LARGER than the tail: the tail
            // reaches S(11) below the bubble body, so at the original S(8) it
            // landed right on the hint line -- an offscreen render caught that at
            // 150%. S(16) leaves the tail tip S(5) clear of the hint. The window
            // top is only the last resort, for when no sprite has been measured.
            float baseY = (hintTopY > 0f ? hintTopY : (catTopY > 0f ? catTopY : (float)H));
            float by = baseY - bh - S(16);
            if (bx < S(2)) bx = S(2);
            if (by < S(2)) by = S(2);

            var path = new GraphicsPath();
            float r = S(12);
            path.AddArc(bx, by, r * 2, r * 2, 180, 90);
            path.AddArc(bx + bw - r * 2, by, r * 2, r * 2, 270, 90);
            path.AddArc(bx + bw - r * 2, by + bh - r * 2, r * 2, r * 2, 0, 90);
            path.AddArc(bx, by + bh - r * 2, r * 2, r * 2, 90, 90);
            path.CloseFigure();

            using (var b = new SolidBrush(Color.FromArgb(238, 255, 255, 255)))
                g.FillPath(b, path);
            using (var p = new Pen(Color.FromArgb(230, HAIR), 2f))
                g.DrawPath(p, path);
            using (var b = new SolidBrush(Color.FromArgb(255, 40, 52, 62)))
                g.DrawString(text, f, b, bx + padX, by + padY);

            // little tail pointing down to her
            var tail = new PointF[] { new PointF(bx + bw / 2 - S(7), by + bh - 1), new PointF(bx + bw / 2 + S(7), by + bh - 1), new PointF(bx + bw / 2, by + bh + S(11)) };
            using (var b = new SolidBrush(Color.FromArgb(238, 255, 255, 255)))
                g.FillPolygon(b, tail);
            using (var p = new Pen(Color.FromArgb(230, HAIR), 2f))
            {
                g.DrawLine(p, tail[0].X, tail[0].Y, tail[2].X, tail[2].Y);
                g.DrawLine(p, tail[1].X, tail[1].Y, tail[2].X, tail[2].Y);
            }
        }

        // ===================================================================
        //  SPRITE RENDERER  --  "Cat Fighter" by dogchicken (OpenGameArt)
        //
        //  CC-BY 3.0. See CREDITS.txt next to this script. This line said 4.0 for
        //  a long time -- D-27 corrected the version everywhere else after
        //  re-checking the source page, but this comment was missed.
        //
        //  This replaced ~240 lines of hand-drawn GDI+ geometry. The hand-drawn
        //  version was rejected on sight and had a real defect: the ears were
        //  rooted at headY + 0.52*headR, i.e. below the head centre, so they
        //  grew out of her cheeks. Authored pixel art beats improvised vector
        //  shapes, so the pet now draws real GIF frames.
        //
        //  Two things make this work on .NET Framework / PowerShell 5.1:
        //    - GDI+ can read GIF frames but NOT their per-frame delays, so the
        //      delays are parsed straight out of the GIF bytes.
        //    - GIF frames are deltas with disposal methods, not standalone
        //      pictures, so they are composited onto a canvas exactly as a
        //      browser would, then cropped to a common box so the cat does not
        //      jitter between frames.
        // ===================================================================

        class CharFrame
        {
            public Bitmap Bmp;
            public int DelayMs;
            public CharFrame(Bitmap b, int d) { Bmp = b; DelayMs = d; }
        }

        class GifClip
        {
            public string Name;
            public CharFrame[] Frames;
            public long TotalMs;

            // Looping clips (idle breathing, walk cycle) repeat forever.
            // One-shot clips (the reactions) must play exactly ONCE and then hold
            // their last frame -- otherwise a 720 ms reaction repeats for as long
            // as the state lasts and the cat visibly keeps going through the same
            // tumble.
            public bool Loop = true;

            public GifClip(string name, CharFrame[] frames)
            {
                Name = name;
                Frames = frames;
                foreach (var f in frames) TotalMs += f.DelayMs;
                if (TotalMs <= 0) TotalMs = 100;
            }
        }

        class GifMeta
        {
            public List<int> Delays = new List<int>();
            public List<Color> Transparent = new List<Color>();   // Color.Empty if none
            public Color Background = Color.Empty;
        }

        // ---------------------------------------------------------------------
        //  Read the GIF metadata GDI+ will not give us.
        //
        //  GDI+ decodes GIF frames into Format32bppArgb with EVERY pixel at
        //  alpha=255 -- it drops the Graphic Control Extension transparency
        //  entirely, and reports Palette.Entries.Length == 0 so the index
        //  cannot be recovered afterwards. Without this parser the pet draws a
        //  solid opaque square of the GIF's transparent-background colour.
        //
        //  So: decode the Global Colour Table from the raw bytes, resolve each
        //  frame's transparent index to a concrete RGB colour, and return the
        //  delays while we are in there.
        // ---------------------------------------------------------------------
        static GifMeta ReadGifMeta(string path)
        {
            var meta = new GifMeta();
            byte[] b = File.ReadAllBytes(path);
            if (b.Length < 13 || Encoding.ASCII.GetString(b, 0, 3) != "GIF") return meta;

            int flags = b[10];
            int gctEntries = (flags & 0x80) != 0 ? (int)Math.Pow(2, (flags & 7) + 1) : 0;
            int gctStart = 13;
            int bgIndex = b[11];
            if (gctEntries > bgIndex)
                meta.Background = Color.FromArgb(255,
                    b[gctStart + bgIndex * 3], b[gctStart + bgIndex * 3 + 1], b[gctStart + bgIndex * 3 + 2]);

            int p = gctStart + gctEntries * 3;

            while (p < b.Length)
            {
                byte blk = b[p];
                if (blk == 0x3B) break;                       // trailer
                if (blk == 0x21)                              // extension
                {
                    byte label = b[p + 1];
                    p += 2;
                    if (label == 0xF9)                        // graphic control
                    {
                        int size = b[p];
                        int packed = b[p + 1];
                        int delay = b[p + 2] | (b[p + 3] << 8);
                        int tIndex = b[p + 4];
                        bool hasFlag = (packed & 1) != 0;
                        meta.Delays.Add(delay * 10);
                        if (hasFlag && tIndex < gctEntries)
                            meta.Transparent.Add(Color.FromArgb(255,
                                b[gctStart + tIndex * 3], b[gctStart + tIndex * 3 + 1], b[gctStart + tIndex * 3 + 2]));
                        else
                            meta.Transparent.Add(Color.Empty);
                        p += size + 1;
                    }
                    while (p < b.Length && b[p] != 0) p += b[p] + 1;
                    p++;
                }
                else if (blk == 0x2C)                         // image descriptor
                {
                    int lflags = b[p + 9];
                    p += 10;
                    if ((lflags & 0x80) != 0) p += 3 * (int)Math.Pow(2, (lflags & 7) + 1);
                    p++;                                      // LZW min code size
                    while (p < b.Length && b[p] != 0) p += b[p] + 1;
                    p++;
                }
                else p++;
            }
            return meta;
        }

        // Makes the sprite's opaque background transparent.
        //
        // The cat GIFs in the F-cat pack are the awkward case: their Graphic
        // Control Extension declares palette index 19 transparent, but after
        // LZW-decoding the frames there is NOT ONE pixel using index 19. The
        // artist drew the cat on an OPAQUE canvas (index 18, rgb(0,114,188))
        // and the transparency declaration is vestigial. GDI+ faithfully
        // reproduces that -- every pixel arrives at alpha=255.
        //
        // So the declared key is useless, and the palette is not available on
        // the decoded Bitmap either. Instead, infer the background from the
        // bitmap itself: take the most common colour along the border and flood
        // fill inward from the edges. A colour enclosed by the character is
        // never reached, so this cannot eat the cat's own pixels.
        static int PunchBackground(Bitmap bmp, Color declaredKey, Color background)
        {
            int W = bmp.Width, H = bmp.Height;
            var r = new Rectangle(0, 0, W, H);
            var d = bmp.LockBits(r, ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
            int removed = 0;
            try
            {
                int stride = d.Stride;
                byte[] buf = new byte[stride * H];
                Marshal.Copy(d.Scan0, buf, 0, buf.Length);

                // --- vote on the border colour ---
                var votes = new Dictionary<int, int>();
                int[] bx = new int[] { 0, W - 1 };
                for (int y = 0; y < H; y++)
                    for (int s = 0; s < 2; s++)
                    {
                        int o = y * stride + bx[s] * 4;
                        int rgb = (buf[o + 2] << 16) | (buf[o + 1] << 8) | buf[o];
                        if (votes.ContainsKey(rgb)) votes[rgb]++; else votes[rgb] = 1;
                    }
                for (int x = 0; x < W; x++)
                    for (int s = 0; s < 2; s++)
                    {
                        int o = (s == 0 ? 0 : H - 1) * stride + x * 4;
                        int rgb = (buf[o + 2] << 16) | (buf[o + 1] << 8) | buf[o];
                        if (votes.ContainsKey(rgb)) votes[rgb]++; else votes[rgb] = 1;
                    }

                var cands = new List<Color>();
                if (!background.IsEmpty) cands.Add(background);
                if (!declaredKey.IsEmpty) cands.Add(declaredKey);
                int perim = 2 * W + 2 * H;
                foreach (var kv in votes)
                    if (kv.Value > perim / 8)   // anything covering >12% of the border
                    {
                        var c = Color.FromArgb(255, (kv.Key >> 16) & 0xFF, (kv.Key >> 8) & 0xFF, kv.Key & 0xFF);
                        bool dup = false;
                        foreach (var e in cands) if (e.R == c.R && e.G == c.G && e.B == c.B) { dup = true; break; }
                        if (!dup) cands.Add(c);
                    }
                if (cands.Count == 0) return 0;

                // NOTE: no local function here -- the CodeDom compiler used by
                // Add-Type targets an older C# and rejects them.

                // --- flood fill from every border pixel ---
                var seen = new bool[W * H];
                var stack = new Stack<int>();
                for (int x = 0; x < W; x++)
                {
                    stack.Push(x);
                    stack.Push((H - 1) * W + x);
                }
                for (int y = 0; y < H; y++)
                {
                    stack.Push(y * W);
                    stack.Push(y * W + W - 1);
                }

                while (stack.Count > 0)
                {
                    int i = stack.Pop();
                    if (i < 0 || i >= W * H || seen[i]) continue;
                    seen[i] = true;
                    int x = i % W, y = i / W;
                    int o = y * stride + x * 4;

                    byte pb = buf[o], pg = buf[o + 1], pr = buf[o + 2];
                    bool isBg = false;
                    for (int c = 0; c < cands.Count; c++)
                        if (cands[c].R == pr && cands[c].G == pg && cands[c].B == pb) { isBg = true; break; }
                    if (!isBg) continue;

                    buf[o + 3] = 0;
                    removed++;

                    if (x > 0) stack.Push(i - 1);
                    if (x < W - 1) stack.Push(i + 1);
                    if (y > 0) stack.Push(i - W);
                    if (y < H - 1) stack.Push(i + W);
                }

                // Sanity guard: if almost the whole image looked like
                // background we mis-identified the colour, so put it back.
                if (removed > (W * H * 9) / 10)
                {
                    for (int i = 0; i < W * H; i++)
                        if (seen[i]) buf[(i / W) * stride + (i % W) * 4 + 3] = 255;
                    removed = 0;
                }

                Marshal.Copy(buf, 0, d.Scan0, buf.Length);
            }
            finally { bmp.UnlockBits(d); }
            return removed;
        }

        // Bounding box of non-transparent pixels, via LockBits.
        static void ContentBox(Bitmap bmp, ref int minX, ref int minY, ref int maxX, ref int maxY)
        {
            var r = new Rectangle(0, 0, bmp.Width, bmp.Height);
            var d = bmp.LockBits(r, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            try
            {
                int stride = d.Stride;
                byte[] buf = new byte[stride * bmp.Height];
                Marshal.Copy(d.Scan0, buf, 0, buf.Length);
                for (int y = 0; y < bmp.Height; y++)
                {
                    int row = y * stride;
                    for (int x = 0; x < bmp.Width; x++)
                    {
                        if (buf[row + x * 4 + 3] < 16) continue;   // BGRA
                        if (x < minX) minX = x;
                        if (y < minY) minY = y;
                        if (x > maxX) maxX = x;
                        if (y > maxY) maxY = y;
                    }
                }
            }
            finally { bmp.UnlockBits(d); }
        }

        // Composites the GIF the way a browser does, then crops every frame to
        // one shared bounding box so the animation stays registered.
        //
        // Instance method (not static) so it can log diagnostics via Note().
        GifClip LoadGifClip(string path, string name)
        {
            var meta = ReadGifMeta(path);

            var raw = new List<Bitmap>();
            var disposals = new List<int>();
            using (var src = Image.FromFile(path))
            {
                var fd = new FrameDimension(src.FrameDimensionsList[0]);
                int n = src.GetFrameCount(fd);
                for (int k = 0; k < n; k++)
                {
                    src.SelectActiveFrame(fd, k);
                    var frame = new Bitmap(src);

                    // GDI+ left this frame fully opaque; restore the GIF's own
                    // transparency before it is composited.
                    Color key = (k < meta.Transparent.Count) ? meta.Transparent[k] : Color.Empty;
                    int punched = PunchBackground(frame, key, meta.Background);
                    if (k == 0)
                        Note("  punch " + name + " f0: key=" + (key.IsEmpty ? "none" : key.R + "," + key.G + "," + key.B) +
                             "  bg=" + (meta.Background.IsEmpty ? "none" : meta.Background.R + "," + meta.Background.G + "," + meta.Background.B) +
                             "  removed=" + punched + " px");

                    raw.Add(frame);
                    int disp = 0;
                    try { disp = src.GetPropertyItem(0x5100).Value[0]; } catch { }
                    disposals.Add(disp);
                }
            }

            Color bg = meta.Background.IsEmpty ? Color.Transparent : meta.Background;

            int W = raw[0].Width, H = raw[0].Height;
            var canvas = new Bitmap(W, H, PixelFormat.Format32bppArgb);
            var composed = new List<Bitmap>();

            using (var g = Graphics.FromImage(canvas))
            {
                g.Clear(Color.Transparent);
                for (int k = 0; k < raw.Count; k++)
                {
                    // disposal 3 restores the canvas to its state BEFORE this frame
                    Bitmap saved = (disposals[k] == 3) ? new Bitmap(canvas) : null;

                    g.DrawImage(raw[k], 0, 0, W, H);
                    composed.Add(new Bitmap(canvas));

                    if (saved != null)
                    {
                        g.Clear(Color.Transparent);
                        g.DrawImage(saved, 0, 0, W, H);
                        saved.Dispose();
                    }
                    else if (disposals[k] == 2)
                    {
                        g.Clear(Color.Transparent);
                    }
                }
            }
            canvas.Dispose();
            foreach (var r in raw) r.Dispose();

            int minX = W, minY = H, maxX = -1, maxY = -1;
            foreach (var c in composed) ContentBox(c, ref minX, ref minY, ref maxX, ref maxY);
            if (maxX < 0) { minX = 0; minY = 0; maxX = W - 1; maxY = H - 1; }

            var frames = new List<CharFrame>();
            for (int k = 0; k < composed.Count; k++)
            {
                int d = (k < meta.Delays.Count && meta.Delays[k] > 0) ? meta.Delays[k] : 100;
                var crop = new Bitmap(maxX - minX + 1, maxY - minY + 1, PixelFormat.Format32bppArgb);
                using (var g = Graphics.FromImage(crop))
                {
                    g.InterpolationMode = InterpolationMode.NearestNeighbor;
                    g.PixelOffsetMode = PixelOffsetMode.Half;
                    g.DrawImage(composed[k],
                        new Rectangle(0, 0, crop.Width, crop.Height),
                        new Rectangle(minX, minY, crop.Width, crop.Height),
                        GraphicsUnit.Pixel);
                }
                frames.Add(new CharFrame(crop, d));
                composed[k].Dispose();
            }
            return new GifClip(name, frames.ToArray());
        }

        class AnimationPlayer
        {
            public GifClip Clip;
            public int Frame;
            readonly Stopwatch clock = Stopwatch.StartNew();
            long frameStartedMs;

            public void Play(GifClip c)
            {
                if (c == null || Clip == c) return;
                Clip = c;
                Frame = 0;
                frameStartedMs = clock.ElapsedMilliseconds;
            }

            // Rewinds the clip that is already playing. Play() deliberately does
            // nothing when the clip has not changed, which is right for continuous
            // cycles but wrong for a one-shot reaction: petting her a second time
            // would leave the clip parked on its held final frame and she would
            // look unresponsive. OnPaint calls this when a new reaction starts.
            public void Restart()
            {
                if (Clip == null || Clip.Frames == null || Clip.Frames.Length == 0) return;
                Frame = 0;
                frameStartedMs = clock.ElapsedMilliseconds;
            }

            public int Current
            {
                get
                {
                    if (Clip == null || Clip.Frames == null || Clip.Frames.Length == 0) return -1;
                    long now = clock.ElapsedMilliseconds;
                    int guard = 0;
                    while (now - frameStartedMs >= Clip.Frames[Frame].DelayMs && guard++ < 512)
                    {
                        frameStartedMs += Clip.Frames[Frame].DelayMs;
                        if (!Clip.Loop && Frame == Clip.Frames.Length - 1)
                        {
                            // one-shot finished: hold the final frame
                            frameStartedMs = now;
                            break;
                        }
                        Frame = (Frame + 1) % Clip.Frames.Length;
                    }
                    return Frame;
                }
            }

            public Bitmap Bitmap
            {
                get
                {
                    int i = Current;
                    return (i < 0) ? null : Clip.Frames[i].Bmp;
                }
            }
        }
    }

    public static class Program
    {
        // Entry point for the compiled DesktopCat.exe.
        //
        // pet.ps1 deliberately does NOT call this Main: it constructs PetForm
        // itself, because under a PowerShell host AppDomain.CurrentDomain
        // .BaseDirectory points at the transpile temp directory instead of at
        // this folder, which silently broke sprite discovery. In a real .exe that
        // same call is exactly what is wanted -- BaseDirectory IS the folder that
        // holds the .exe, the sprites and .petdata.
        //
        // The app was moved off its .bat launcher because this machine's security
        // agent raises the Windows "Open File - Security Warning" dialog every time
        // a .bat or .lnk is opened, and an Attachment Manager policy change did not
        // suppress it. Launching an .exe is not intercepted. This also removes the
        // console window that used to flash on every start, and the dependency on
        // the PowerShell execution policy.
        [STAThread]
        public static int Main(string[] args)
        {
            string root = AppDomain.CurrentDomain.BaseDirectory;
            // PET_DATA redirects the data folder so a throwaway instance can run
            // beside a real one, as the script's own harness relies on.
            string data = Environment.GetEnvironmentVariable("PET_DATA");
            if (data == null || data.Length == 0) data = Path.Combine(root, ".petdata");
            string cfg = Path.Combine(data, "config.json");
            string log = Path.Combine(data, "pet.log");
            string launch = Path.Combine(data, "last-launch.txt");

            try { Directory.CreateDirectory(data); } catch { }

            // Single instance guard. It uses the SAME mutex name as pet.ps1, so a
            // script-launched cat and an .exe-launched cat cannot both appear.
            System.Threading.Mutex guard = null;
            bool gotInstance = true;
            if (Environment.GetEnvironmentVariable("PET_FORCE") != "1")
            {
                try
                {
                    guard = new System.Threading.Mutex(false, @"Global\DesktopCat_SingleInstance");
                    gotInstance = guard.WaitOne(0, false);
                }
                catch { gotInstance = true; }
            }

            if (!gotInstance)
            {
                try { File.WriteAllText(launch, "ALREADY_RUNNING"); } catch { }
                MessageBox.Show(
                    "\u5df2\u7ecf\u6709\u4e00\u53ea\u732b\u54aa\u5728\u684c\u9762\u4e0a\u5566\u3002\r\n\r\n\u5982\u679c\u627e\u4e0d\u5230\u5979\uff0c\u53f3\u952e\u4efb\u52a1\u680f\u6258\u76d8\u91cc\u7684\u732b\u56fe\u6807\uff0c\u9009\u300c\u9000\u51fa\u300d\uff0c\u518d\u91cd\u65b0\u53cc\u51fb\u4e00\u6b21\u3002",
                    "Desktop Cat", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return 0;
            }

            // Only the instance that owns the log gets to start it fresh.
            try
            {
                File.WriteAllText(log, "MARK_START " + DateTime.Now.ToString("HH:mm:ss.fff") +
                    " pid=" + Process.GetCurrentProcess().Id.ToString() + Environment.NewLine);
            }
            catch { }

            // Before any window exists: become DPI-aware so the pet renders at
            // native device pixels and window/mouse coordinates finally match.
            PetForm.InitDpi(true);

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            try
            {
                var f = new PetForm(root, data, cfg);
                if (Environment.GetEnvironmentVariable("PET_PREVIEW") == "1")
                {
                    f.BeginPreview();
                }
                f.Show();
                Application.Run(f);
            }
            finally
            {
                try { File.AppendAllText(log, DateTime.Now.ToString("HH:mm:ss.fff") + " MARK_END" + Environment.NewLine); }
                catch { }
                if (guard != null)
                {
                    try { guard.ReleaseMutex(); } catch { }
                    try { guard.Close(); } catch { }
                }
            }
            return 0;
        }
    }
}
'@

Note "compiling C#..."
try {
    Add-Type -TypeDefinition $CSHARP -Language CSharp -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing', 'System', 'System.Core' -IgnoreWarnings -ErrorAction Stop
    Note "compile OK"
}
catch {
    Note ("COMPILE FAILED: " + $_.Exception.Message)
    Write-Host "Compile failed. See $LOGF"
    exit 1
}

Note "starting message loop"
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

# NOTE: DesktopCat.Program.Main is NOT used here -- the form is constructed and run
# straight from PowerShell. $ROOT must therefore be passed in explicitly:
# AppDomain.CurrentDomain.BaseDirectory points at the PowerShell temp transpile
# directory, not at this folder, which silently broke sprite discovery.
$form = New-Object DesktopCat.PetForm($ROOT, $DATA, $CFGF)

# Preview mode: cycle every animation in the pack, labelled in the speech
# bubble. Set PET_PREVIEW=1 (set PET_PREVIEW=1) or pick it from the tray menu.
if ($env:PET_PREVIEW -eq "1") {
    Note "PREVIEW MODE requested"
    $form.BeginPreview()
}

[System.Windows.Forms.Application]::Run($form)

Note "MARK_END"
