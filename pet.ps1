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
    [System.Windows.Forms.MessageBox]::Show(
        "Desktop Cat is already running. Look for her on your desktop." + [Environment]::NewLine + [Environment]::NewLine +
        "If you cannot find her, right-click the tray icon and choose Quit, then start again.",
        "Desktop Cat") | Out-Null
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
        Idle = 0, Stretch = 30, Sleep = 50, Sad = 55, Happy = 60,
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
        static readonly string[] SLEEPY =
        {
            "\u56f0\u4e86\u2026",
            "\u54c8\uff5e\uff08\u6253\u54c8\u6b20\uff09",
            "\u8ba9\u6211\u772f\u4e00\u4f1a\u513f\u2026",
            "\u773c\u775b\u7741\u4e0d\u5f00\u4e86\u2026",
            "\u597d\u56f0\u2026"
        };
        static readonly string[] WAKE =
        {
            "\uff01\uff1f",
            "\u5e72\u561b\u5440\uff5e",
            "\u5413\u6211\u4e00\u8df3\uff01",
            "\u6211\u9192\u4e86\u6211\u9192\u4e86",
            "\u5514\u2026\u5435\u9192\u6211\u4e86"
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
        //   die 2800      spread 1.61  -> Sleep         (only clip that lies flat)
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
        GifClip clipIdle, clipWalk, clipJump, clipPet, clipSleep, clipSad;
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
            table[PetState.Sleep] = new StateInfo(PetState.Sleep, 50, 4000, true);
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
            if (cfg.X < 0 || cfg.Y < 0)
            {
                cfg.X = sw - W - 40;
                cfg.Y = sh - H - 20;
            }
            cfg.X = Math.Max(0, Math.Min(cfg.X, sw - W));
            cfg.Y = Math.Max(0, Math.Min(cfg.Y, sh - H));
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

            Application.Idle += OnIdle;
        }

        // Stretches one frame's on-screen time and recomputes the clip total.
        // Used to turn cat_die's 80 ms "collapse and bounce back up" into a nap.
        static void StretchFrame(GifClip c, int index, int ms)
        {
            if (c == null || c.Frames == null) return;
            if (index < 0 || index >= c.Frames.Length) return;
            c.Frames[index].DelayMs = ms;
            c.TotalMs = 0;
            for (int i = 0; i < c.Frames.Length; i++) c.TotalMs += c.Frames[i].DelayMs;
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
                clipSleep = LoadFirst(spriteDir, "sleep", "cat_die.gif");

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
                if (clipSleep != null) clipSleep.Loop = false;
                if (clipPet != null) clipPet.Loop = false;
                if (clipSad != null) clipSad.Loop = false;
                if (clipStretch != null) clipStretch.Loop = false;
                if (clipSurprise != null) clipSurprise.Loop = false;
                if (clipTalk != null) clipTalk.Loop = false;
                if (clipRemind != null) clipRemind.Loop = false;
                // clipPlay, clipDance and clipCheer deliberately keep Loop = true:
                // they back sustained moods rather than one-shot reactions.

                // cat_die's first three frames are all upright -- measured content
                // boxes are 18x29, 18x29 and 19x29 -- so at the authored 80/80/200
                // ms they put the cat on screen standing still for 360 ms before
                // anything happens. That is precisely the report of "three standing
                // images in a row, and the standing image is still there after she
                // has already fallen".
                //
                // The frames DO contain motion (pixel-diffing consecutive frames
                // shows 7-9% of pixels changing, so they are a real anticipation
                // pose, not a frozen frame), which is why they are kept but
                // collapsed to 1 ms each: one painted frame, effectively a skip,
                // preserving the pose while removing the dead time.
                StretchFrame(clipSleep, 0, 1);
                StretchFrame(clipSleep, 1, 1);
                StretchFrame(clipSleep, 2, 50);
                //
                // Frame map of the fall, all 9 frames sharing one 30x30 box (so the
                // drawn rectangle is a constant 210x210 and the sprite cannot
                // shrink or grow mid-fall -- that was the old flicker):
                //   f0-f2 upright crouch   -> f3 sprawl (29x30) -> f4,f5 prone
                //   f6 the author's own 200 ms hold, and the flattest prone pose
                //   f7,f8 prone variants
                //
                // There is NO get-up frame: the clip ends lying down, and with
                // Loop = false it HOLDS that last frame. So stretching f6 turns the
                // same clip into a real nap -- fall, lie asleep, and she only stands
                // up when the Sleep state ends.
                StretchFrame(clipSleep, 6, 2000);
                //
                // f7 and f8 come AFTER that 2 s hold and are still prone. Left at
                // their authored 80 ms they make the settled, apparently-asleep cat
                // twitch twice before the clip ends, so they are collapsed too.
                StretchFrame(clipSleep, 7, 1);
                StretchFrame(clipSleep, 8, 1);

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
                int TARGET_W = S(126);
                int fw = clipIdle.Frames[0].Bmp.Width;
                int fh = clipIdle.Frames[0].Bmp.Height;

                int byWidth = TARGET_W / fw;                    // 126/18 = 7
                int maxFitW = (W - S(20)) / fw;

                // Clamp to the narrowest real limit. No height term: at 7x the
                // cat is 210 px tall inside a 460 px window, so height is never
                // the binding constraint and including it only produced a
                // confusing off-by-one (it silently forced 6x).
                spriteScale = Math.Max(1, Math.Min(byWidth, maxFitW));

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

        // Fired for every left click anywhere on the desktop.
        void OnGlobalClick(int sx, int sy)
        {
            long now = clock.ElapsedMilliseconds;
            if (now - lastPatMs < 900) return;

            // Where in the artwork did the click land? The sprite box is split by
            // relative position instead of one head circle, so the head, the body
            // and the tail each react differently -- patting the tail is not the
            // same act as patting the head.
            if (spritesOk)
            {
                float pad = 10f;
                float bx = Location.X + SpriteLeft;
                float by = Location.Y + SpriteTop;
                if (sx >= bx - pad && sx <= bx + SpriteW + pad &&
                    sy >= by - pad && sy <= by + SpriteH + pad)
                {
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
        // The greeting and her willingness to nap both follow the clock.
        static bool IsNightHour() { int h = DateTime.Now.Hour; return h >= 23 || h < 5; }

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
        ContextMenuStrip BuildMenu()
        {
            var menu = new ContextMenuStrip();
            // Logged on purpose. If the menu ever appears but does nothing again, the
            // pet's own log says whether the click reached the menu at all, which is
            // the difference between "the wrong menu" and "the click never arrived".
            menu.Opening += delegate { Note("menu opening"); };
            menu.ItemClicked += delegate(object src, ToolStripItemClickedEventArgs a) { Note("menu item clicked: " + a.ClickedItem.Text); };
            menu.Items.Add(new ToolStripMenuItem("Say hi / \u6478\u6478\u5934", null, delegate { Pet(true); }));
            menu.Items.Add(new ToolStripMenuItem("Play / \u966a\u6211\u73a9", null, delegate { SetState(PetState.Play, 2600, true); Bubble(Pick(PLAY), 2000); }));
            menu.Items.Add(new ToolStripMenuItem("Dance / \u8df3\u821e", null, delegate { SetState(PetState.Dancing, 3000, true); Bubble(Pick(DANCE), 2000); }));
            menu.Items.Add(new ToolStripMenuItem("Stretch / \u4f38\u61d2\u8170", null, delegate { SetState(PetState.Stretch, 1700, true); Bubble(Pick(STRETCH), 1600); }));
            menu.Items.Add(new ToolStripMenuItem("Nap / \u7761\u89c9", null, delegate { SetState(PetState.Sleep, 6000, true); }));
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(new ToolStripMenuItem("Center on screen", null, delegate { CenterOn(); }));
            menu.Items.Add(new ToolStripMenuItem("Stats & credits", null, delegate { ShowInfo(); }));
            menu.Items.Add(new ToolStripMenuItem("Preview all animations", null, delegate { StartPreview(); }));
            menu.Items.Add(new ToolStripSeparator());

            // "Do not disturb" switches. CheckOnClick flips Checked BEFORE the
            // Click handler runs, so reading it there gives the new value. The
            // menu is rebuilt on every open, so the ticks always tell the truth.
            var miQuiet = new ToolStripMenuItem("Quiet mode / \u5b89\u9759\u6a21\u5f0f");
            miQuiet.CheckOnClick = true;
            miQuiet.Checked = quiet;
            miQuiet.Click += delegate { quiet = miQuiet.Checked; SaveConfig(); Note("quiet -> " + quiet); };
            menu.Items.Add(miQuiet);

            var miLock = new ToolStripMenuItem("Lock position / \u9501\u5b9a\u4f4d\u7f6e");
            miLock.CheckOnClick = true;
            miLock.Checked = locked;
            miLock.Click += delegate { locked = miLock.Checked; SaveConfig(); Note("locked -> " + locked); };
            menu.Items.Add(miLock);

            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(new ToolStripMenuItem("Reset affection", null, delegate
            {
                cfg.Affinity = 0; cfg.Interactions = 0; comboCount = 0;
                SaveConfig(); Bubble("...", 1500);
            }));
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(new ToolStripMenuItem("Quit", null, delegate { Quit(); }));
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
                tray.Text = "Desktop Cat";
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
                ? "(top tier reached)"
                : (into + " / " + span + " toward the next tier");

            string n = Environment.NewLine;
            string body =
                "Desktop Cat" + n +
                "-------------------------------------------------------------" + n +
                "Affection      : " + cfg.Affinity + "  (" + TierName() + ")" + n +
                "Next tier      : " + progress + n +
                "Interactions   : " + cfg.Interactions + n +
                "Animations     : " + ClipCount() + " clips in use" + n +
                "Running for    : " + (int)(clock.ElapsedMilliseconds / 1000) + " s" + n +
                "Position       : " + Location.X + ", " + Location.Y + n +
                "Topmost        : " + (cfg.TopMost ? "yes" : "no") + n +
                "Data folder    : " + dataDir + n +
                n +
                "HOW TO PLAY" + n +
                "-------------------------------------------------------------" + n +
                "  click her head   -> she is happiest there, affection +2" + n +
                "  click her body   -> affection +1" + n +
                "  click her tail   -> she objects (affection -1)" + n +
                "  click 5 times fast -> petting combo, she cheers" + n +
                "  drag her         -> carry her somewhere else" + n +
                "  double-click     -> centre on this screen, and back again" + n +
                "  mouse wheel      -> nudge affection up or down" + n +
                "  Esc              -> quit" + n +
                n +
                "ARTWORK CREDIT (required by the licence)" + n +
                "-------------------------------------------------------------" + n +
                "  Cat Fighter sprite sheet" + n +
                "  by dogchicken" + n +
                "  https://opengameart.org/content/cat-fighter-sprite-sheet" + n +
                "  Licence: CC-BY 3.0 (https://creativecommons.org/licenses/by/3.0/)" + n +
                n +
                "  The sprite sheet is redistributed unmodified. All 13 animations" + n +
                "  are used; see CREDITS.txt for the clip-by-clip mapping." + n;

            try
            {
                var f = new InfoForm("Desktop Cat - stats & credits", body);
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
            GifClip[] all = { clipIdle, clipWalk, clipJump, clipPet, clipSleep, clipSad,
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
                    Note("config loaded x=" + cfg.X + " y=" + cfg.Y + " aff=" + cfg.Affinity +
                         " quiet=" + quiet + " locked=" + locked);
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

            // Sleep shows a one-shot clip too (cat_die), so it needs the same
            // spacing. Without this the cat naps, gets up, and lies straight
            // back down 1.4 s later -- measured, and clearly wrong.
            bool oneShot = isReaction || s == PetState.Sleep;

            // One autonomous one-shot at a time. The idle timer used to re-fire
            // while the previous tumble was barely over, so these clips ran
            // back to back with no breathing room -- which read as animations
            // piling up on top of each other.
            if (oneShot && !userInitiated && now < reactionGateMs) return;

            var cur = table[state];
            var next = table[s];
            if (next.Priority < cur.Priority && !cur.Interruptible) return;
            // The remaining two guards must ALSO let a user click through. They used
            // not to, so asking for a lower-priority state was silently dropped:
            // the tray menu's "Nap" is Sleep (priority 50), so clicking it while she
            // was Happy (60) did nothing at all for the next two seconds, and the
            // menu looked broken. Confirmed by probing the compiled form directly.
            if (next.Priority < cur.Priority && !userInitiated && (now - stateEnteredMs) < cur.MinMs) return;
            if (state == s && s != PetState.Idle && !userInitiated) return;

            // Duration for THIS visit. It is deliberately not written back into the
            // table: table[] is shared static state for the whole session, so
            // "table[s].MinMs = minMs" used to make one call permanent. A night nap
            // passes 9000 and every nap afterwards lasted 9 seconds even at noon,
            // the boot greeting made Happy 2200 forever, and each tray action
            // rewrote its state's duration again -- so the cat's behaviour drifted
            // the longer it ran.
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

                // Sleep reaches its clip through the DesiredClip switch, so it
                // must not set the override.
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
                case PetState.Sleep: return clipSleep;
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
                case PetState.Sleep: return clipSleep;
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

        void OnIdle(object sender, EventArgs e)
        {
            long now = clock.ElapsedMilliseconds;

            // Preview mode drives the clip directly and parks the state machine,
            // so the reaction gate and idle fidgeting cannot fight it.
            if (previewOn)
            {
                StepPreview(now);
                if (bubbleText != null && now > bubbleUntilMs) bubbleText = null;
                Invalidate();
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
                else if (state != PetState.Sleep) { blinkClosed = true; nextBlinkMs = now + 110; }
                else nextBlinkMs = now + 1000;
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
                // Weights are a percentage of idle rolls. Measured on a live run,
                // the first cut handed Sleep 28% -- the single most likely outcome
                // -- and the cat napped 5 times in 90 seconds, which reads as a
                // switched-off cat rather than a resting one. Sleep is now 12% and
                // the lively states dominate. Sad stays at 8% on purpose: a
                // companion that looks miserable a fifth of the time is not
                // pleasant to have on screen.
                int r = rnd.Next(100);
                bool wantedReaction = (r < 88);

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
                    // At night she naps far longer than she does during the day.
                    long napMs = IsNightHour() ? 9000 : 3500;
                    SetState(PetState.Sleep, (int)napMs);
                    Bubble(Pick(SLEEPY), 2200);
                }

                // The roll wanted a reaction but the gate is still shut (the
                // previous one is not done settling). Retry shortly instead of
                // sitting out another full 3-7 s idle interval.
                if (wantedReaction && state == PetState.Idle) nextMicroMs = now + 1200;
            }

            if (bubbleText != null && now > bubbleUntilMs) bubbleText = null;

            StepWalk(now);

            if (now - lastSaveMs > 10000) { lastSaveMs = now; SaveConfig(); }

            Invalidate();
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
                ny = Math.Max(scr.Top, Math.Min(ny, scr.Bottom - 60));
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
                    //     jump  18x31      sleep (cat_die) 30x30
                    //
                    // Drawing all of those into idle's fixed 126x210 box stretched
                    // each one by a different amount. cat_die came out at 126/30 =
                    // 4.2x horizontally against 7x vertically: the fall rendered
                    // 40% too narrow, and the cat SNAPPED to a different size the
                    // moment Sleep began and snapped back when it ended.
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
                    var srcR = new Rectangle(0, 0, bmp.Width, bmp.Height);
                    g.DrawImage(bmp, dest, srcR, GraphicsUnit.Pixel);

                    g.Restore(st);
                }
            }

            if (bubbleText != null) DrawBubble(g, bubbleText);
            // Onboarding hint for the first stretch of the session, plus whenever
            // she is actually being carried. A permanent "drag" label was just
            // clutter once the user had worked it out.
            if (dragging || clock.ElapsedMilliseconds < 18000) DrawHint(g);

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
            using (var f = new Font("Microsoft YaHei UI", 8f))
            {
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
            using (var f = new Font("Microsoft YaHei UI", 8f))
            {
                var sz = g.MeasureString(s, f);
                float x = (W - sz.Width) / 2f;
                using (var sh = new SolidBrush(Color.FromArgb(190, 0, 0, 0)))
                    g.DrawString(s, f, sh, x + 1, S(7));
                using (var b = new SolidBrush(Color.FromArgb(215, 255, 255, 255)))
                    g.DrawString(s, f, b, x, S(6));
            }
        }

        void DrawBubble(Graphics g, string text)
        {
            using (var f = new Font("Microsoft YaHei UI", 10.5f))
            {
                SizeF sz = g.MeasureString(text, f);
                float padX = S(12), padY = S(8);
                float bw = sz.Width + padX * 2;
                float bh = sz.Height + padY * 2;
                float bx = (W - bw) / 2f;
                float by = S(8);
                if (bx < S(2)) bx = S(2);

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
        }

        // ===================================================================
        //  SPRITE RENDERER  --  "Cat Fighter" by dogchicken (OpenGameArt)
        //
        //  CC-BY 4.0. See CREDITS.txt next to this script.
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
            // One-shot clips (fall over, sleep) must play exactly ONCE and then
            // hold their last frame -- otherwise a 720 ms fall animation repeats
            // for as long as the state lasts and the cat visibly keeps
            // collapsing, getting up and collapsing again.
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
