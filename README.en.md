# Desktop Cat

[简体中文](README.md) | **English**

![Desktop Cat · real screen recording](docs/demo.gif)

A pixel cat that lives on your Windows desktop. She zones out, stretches, naps, dances
and occasionally trips over, and every so often she reminds you to take a break.
Pet her and she reacts; pet her often and her affection grows.

She remembers where she was sitting and how many times you have petted her — close her
and start her again, and she is right back where you left her.

**Author: daijun** · **MIT licensed** · **Windows 10 / 11** · **no installer · no network access**

### ⬇ [Download DesktopCat-1.1.zip](https://github.com/wt0812/desktop-cat/releases/latest)

> Unzip it into any folder you can write to and double-click `DesktopCat.exe`.
> The first run triggers a Windows SmartScreen prompt, because this app is not code-signed.
> Click **More info** → **Run anyway**. Details are in [section 5](#5-about-that-security-warning-please-read-it).

![Main artwork, rendered by the app itself](docs/hero.png)

<div align="center"><sub>The artwork above, and the four poses below, are drawn by the app's own renderer — not mock-ups</sub></div>

![Idle / stretching / dancing / romping](docs/states.png)

![Real screenshot](docs/screenshot.png)

> Note: the screenshots and artwork carry Chinese labels. The app's UI is bilingual
> (every menu item reads like `Dance / 跳舞`), but the demo was recorded on a Chinese system.

---

## 1. Getting started

1. Unzip **the whole folder** into a directory **you have write permission for** —
   your Documents folder or the desktop, for example.

   > ⚠ Do not put it in `C:\Program Files\`. That location is read-only, and she will
   > not be able to remember her position or her affection for you.

2. Double-click **`DesktopCat.exe`**.

3. On first launch Windows shows a blue "**Windows protected your PC**" dialog.

   That is the standard treatment for every small tool **without a paid code-signing
   certificate** — it is **not** an antivirus alert. Click **More info** → **Run anyway**.

   To stop it asking in future: right-click `DesktopCat.exe` → **Properties** → tick
   **Unblock** at the bottom → OK, then run it once more.

---

## 2. How to play

Once she is on screen:

| Action | Result |
| --- | --- |
| **Press and drag** | Move her somewhere else; she cheers up a little |
| **Double-click her** | She returns to the centre of the screen with a `~♪` |
| **Click anywhere on the desktop** | She may walk over in that direction |
| **Hover her head / body** | Affection goes up; repeatedly petting triggers a cheer; her tail costs you affection |
| **Scroll the wheel** | Affection ±10, and her current tier is shown |
| **Right-click her** | Open the menu (below) |
| **Double-click the tray icon** | Same as petting her once |
| **Right-click the tray icon** | The same menu |
| **Esc** | Quit, saving her position and affection |

**Can't find her?** Right-click the tray icon → `Quit`, then start her again.

### The menu (right-click her, or the tray icon)

| Item | What it does |
| --- | --- |
| `Say hi / 摸摸头` | Pet her once |
| `Play / 陪我玩` | Play animation |
| `Dance / 跳舞` | Dance |
| `Stretch / 伸懒腰` | Stretch |
| `撒欢` | Romping: a spread-limbed twirl (this slot used to be Nap) |
| `Center on screen` | Move her back to the centre of the screen |
| `Stats & credits` | Affection, interaction count, asset credits |
| `Preview all animations` | Play all 13 animations in sequence |
| **`Quiet mode / 安静模式`** | When ticked she goes **completely silent**: no speech bubbles, no automatic animation changes, not even break reminders. Petting, dragging and the menu still work |
| **`Lock position / 锁定位置`** | When ticked she **cannot be dragged**, so a slip of the mouse can't move her. Petting still works |
| `Reset affection` | Reset affection to zero |
| `Quit` | Quit |

Both toggles are remembered — next time you start her, she is still in the state you left her.

---

## 3. Affection tiers

Affection caps at 400 and has **6 tiers** (the names below are what the app itself reports —
they are Chinese in the UI, with the English gloss added here for reference):

| Tier | Affection needed | Name (UI / gloss) |
| --- | --- | --- |
| 1 | 0 | **陌生** (Stranger) |
| 2 | 20 | **熟悉** (Acquainted) |
| 3 | 50 | **朋友** (Friend) |
| 4 | 100 | **好朋友** (Good friend) |
| 5 | 200 | **挚友** (Best friend) |
| 6 | 400 | **心之友** (Kindred spirit) |

Petting her head gives +1 (+2 if you pet the top of her head); the scroll wheel gives ±10.
Her current tier is displayed just above the thin progress bar under her feet.

---

## 4. Where your data lives

Everything sits in a `.petdata\` folder next to the program:

| File | Contents |
| --- | --- |
| `config.json` | Position, affection, interaction count, quiet mode and lock position |
| `pet.log` | Runtime log (the first thing to read if something goes wrong) |
| `last-launch.txt` | Record of the last launch (used by the launcher to tell whether she came up) |

Delete the whole `.petdata\` folder and she is back to factory state.

**There is no networking code anywhere in this program**: no internet access, no uploads,
no telemetry, no registry writes, and no administrator rights required.

---

## 5. About that security warning, please read it

The program installs **one global hook that only reads the mouse position**, to work out
whether you are petting her head or her body. It **does not record, store or transmit
anything** — but it is also the reason some antivirus tools are suspicious of it.

Because the app is **not code-signed**, Windows warns you once on first run. It is not a
virus alert.

---

## 6. Requirements

| Item | Requirement |
| --- | --- |
| OS | **Windows 10 / 11** |
| Runtime | **Nothing to install** — it uses the PowerShell 5.1 and .NET Framework already in Windows |
| Network | **Not required at all** (it runs with the network unplugged) |
| Administrator rights | **Not required** |
| Write permission | **Required** — she writes her memories into `.petdata\` next to the program |

---

## 7. FAQ

**Q: Windows says "unrecognised app" when I download or run it — is it malware?**
No. The reason is simply that the app is **not code-signed**; every unsigned program gets
this. The release page lists the ZIP's SHA256 if you want to verify it. If you would rather
not run a packed executable at all, you can run the source directly: `pet.ps1` is plain
PowerShell.

**Q: Does it go online? Does it upload anything?**
It does not. Searching the source for `HttpClient`, `WebClient`, `WebRequest` or `Socket`
returns zero hits. Unplug your network and start her — she works just the same.

**Q: Is that mouse hook spying on me?**
It determines exactly one thing: **whether the left mouse button went down** (that is how
petting works). It records no coordinates, stores nothing and sends nothing, and hands the
event straight back to the system. **The right button is not hooked at all.**

**Q: How do I fully uninstall it?**
Delete the program folder. Everything is inside its `.petdata\`. No registry entries, no
`%APPDATA%`, no services, no startup entries.

**Q: How do I make it start with Windows?**
There is **no such option in the app yet** (it is on the list). Workaround: press `Win+R`,
type `shell:startup`, and drop a shortcut to `DesktopCat.exe` in there.

**Q: I want to modify it / build on it.**
Please do. The source is the single file `pet.ps1` (pure PowerShell with embedded C#);
rebuild the exe with `tools\build-exe.ps1`. See [DEVELOPMENT.md](DEVELOPMENT.md).

**Q: Is there a Mac / Linux version?**
No, and there won't be one soon — the implementation is Windows-only (WinForms + a Win32
mouse hook + a transparent window). Porting it would mean rewriting it.

**Q: I found a problem. What now?**
Open an [issue](https://github.com/wt0812/desktop-cat/issues) and paste the last few dozen
lines of `pet.log`; that is usually enough to pinpoint it.

---

## 8. License

**Program code**: **MIT**, full text in [LICENSE](LICENSE).

You may use, modify and redistribute it freely, **including commercially** — the only
obligation is to keep the copyright notice.

**The character artwork is not covered by MIT**; it is
**[CC-BY 3.0](https://creativecommons.org/licenses/by/3.0/)**:

The pixel cat comes from the
**[Cat Fighter Sprite Sheet](https://opengameart.org/content/cat-fighter-sprite-sheet)**
by **dogchicken**.

As CC-BY 3.0 requires, **please keep [CREDITS.txt](CREDITS.txt) when redistributing** —
it contains the full attribution and a note on what each of the 13 animations is used for.

---

## 9. More documentation

| File | What's inside |
| --- | --- |
| [README.md](README.md) | The Chinese README — the authoritative version of this document |
| [DEVELOPMENT.md](DEVELOPMENT.md) | Architecture, directory layout, build and packaging flow, how to tweak her behaviour |
| [RELEASE-NOTES-v1.0.md](RELEASE-NOTES-v1.0.md) | What changed in this release, both SHA256 checksums |
| [CHANGELOG.md](CHANGELOG.md) | Every functional iteration, Keep a Changelog format (Chinese) |
| [RELEASE-NOTES-v1.1.md](RELEASE-NOTES-v1.1.md) | What changed in v1.1, both SHA256 checksums, measured resource use |
| [DECISIONS.md](DECISIONS.md) | **36 engineering decision records**: why WinForms instead of Electron, why the transparent window needs `TransparencyKey`, why the mouse hook deliberately ignores the right button — all the potholes are in here |
| [CREDITS.txt](CREDITS.txt) | Full asset attribution (required by CC-BY 3.0) |
| [tools/](tools) | Development scripts: exe packaging, offscreen state capture, deployment, probing |
