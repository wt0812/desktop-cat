# 决策索引（DECISIONS）

每个关键选择：**决定 / 理由 / 代价 / 位置**。按时间顺序，越靠后越新。
每条都是**真的发生过**的，不是设想 —— 带数字的都是实测值。

---

## D-01 放弃 Electron，改用单进程 WinForms

| | |
| --- | --- |
| **决定** | 整个项目从 Electron + React + TypeScript 改成 **PowerShell + C# WinForms 单进程** |
| **理由** | 这台机器上 **Electron 完全无法启动**：`FATAL:platform_channel.cc(83) Check failed: . : 拒绝访问。 (0x5)`；`electron.exe --version` 返回 `-2147483645`（= `STATUS_BREAKPOINT`）。原因是本机安全内核驱动拦截了进程创建。反复换版本、加 `--no-sandbox` 都无效 |
| **代价** | 失去 Web 技术栈；Live2D / React 生态不可用；UI 只能靠 GDI+ 手绘 |
| **位置** | 旧的 `app/`、`src/`、`docs/`、`package.json` 等已在 2026-10-08 全部删除 |

---

## D-02 C# 内嵌在 `pet.ps1` 里，`.exe` 是它的产物

| | |
| --- | --- |
| **决定** | `pet.ps1` 是**唯一真源**（`$CSHARP = @' ... '@`，C# 在此之间）；`DesktopCat.exe` 由 `tools\build-exe.ps1` 抽取并编译生成 |
| **理由** | 只有一份代码，不存在"改了 .ps1 忘了改 .exe"的同步问题。另外 PowerShell 直跑时会多一个控制台窗口，且 `.ps1` 每次都要现场编译 |
| **代价** | 改代码后**必须**重新跑构建脚本，不能直接双击 `.ps1` 当成品 |
| **位置** | `pet.ps1` 中 `$CSHARP` 与 `[Add-Type]` 调用；`tools\build-exe.ps1` |

---

## D-03 编译成 GUI 子系统（`/target:winexe`）

| | |
| --- | --- |
| **决定** | `CompilerOptions = '/target:winexe'`，并在构建后读 PE 头校验 `subsystem == 2` |
| **理由** | 默认的 `/target:exe` 产出控制台子系统程序，Windows 会先开一个黑窗再显示猫 —— 正是要消除的那个闪烁 |
| **代价** | 没有控制台输出；调试信息只能写日志文件 |
| **位置** | `tools\build-exe.ps1` 的 `$p.CompilerOptions` 与其后的 PE 校验块 |

---

## D-04 透明靠 `TransparencyKey`，不靠分层窗口

| | |
| --- | --- |
| **决定** | `FormBorderStyle=None` + `TransparencyKey` = 魔术色 `Color.FromArgb(255,1,2,3)` + `BackColor` 同色；再开 `OptimizedDoubleBuffer | AllPaintingInAllPaint | UserPaint` |
| **理由** | 分层窗口（`WS_EX_LAYERED` + `UpdateLayeredWindow`）在这台机器上被安全驱动干扰；`TransparencyKey` 是纯 Win32 行为，稳定。魔术色选 `(1,2,3)` 而不是纯黑，避免误伤画面里的深色像素 |
| **代价** | 该颜色的像素会被"打洞"，画面上不能出现 `(1,2,3)` —— 素材里没有这种颜色 |
| **位置** | `pet.ps1` → `PetForm` 构造函数 |

---

## D-05 `Graphics.CopyFromScreen` 在这台机器上是坏的，永不使用

| | |
| --- | --- |
| **决定** | 彻底不用屏幕截图 API；需要验证画面时改用**离屏反射渲染**（见 D-06） |
| **理由** | 实测 `CopyFromScreen` 只返回**过期的壁纸**，不返回窗口内容，导致基于截图的验证全部不可信（曾据此得出错误结论） |
| **代价** | 无法做"截屏对比"式的 UI 测试 |
| **位置** | 全项目零处调用；替代方案在 `tools\` |

---

## D-06 验证方式：离屏反射构造窗体，绝不 `Show()`

| | |
| --- | --- |
| **决定** | 验证脚本用 `New-Object DesktopCat.PetForm(...)` 构造真窗体，然后用反射调用私有成员、逐帧读状态和像素，**不显示窗口** |
| **理由** | 这是 `CopyFromScreen` 坏掉之后唯一能拿到真像素的途径；而且不打扰用户、不改数据 |
| **代价** | 依赖私有成员名，重构参数时脚本会一起坏 |
| **踩过的坑** | `[Type]::GetType('DesktopCat.PetForm')` 在 `Add-Type` 之后返回 `$null`，必须遍历 `[AppDomain]::CurrentDomain.GetAssemblies()`；`Activator::CreateInstance` 与 `ConstructorInfo.Invoke` 都会报 `PSObject 无法转换为 String`，**必须用 `New-Object -TypeName ... -ArgumentList @(...)`** |
| **位置** | `tools\probe-harness.ps1`、`capture-states.ps1`、`fall-strip.ps1`、`dump-frames.ps1` |

---

## D-07 角色换成像素猫，素材用 Cat Fighter（CC-BY 4.0）

| | |
| --- | --- |
| **决定** | 放弃 Live2D 与自绘 SVG，改用 [Cat Fighter Sprite Sheet](https://opengameart.org/content/cat-fighter-sprite-sheet)（dogchicken，CC-BY 4.0）的 13 个动画素材（本版本打包其中的 12 个） |
| **理由** | 用户明确要求"像人/像猫"且要现成成品（自绘 SVG 观感太差）；该素材授权干净、动画齐全、像素风正好 |
| **代价** | **CC-BY 4.0 要求署名义**，`CREDITS.txt` 必须随程序一起分发，不能删 |
| **位置** | `cat-assets\ex-F-cat-anim-pack\`（12 个 GIF）、`CREDITS.txt` |

---

## D-08 背景用"边缘泛洪"抠掉，并带安全阀

| | |
| --- | --- |
| **决定** | GIF 解码后从画面边框向内的同色区域做泛洪填充，判为背景则置透明 |
| **理由** | GDI+ 解 GIF 时会把所有帧解码成 `Format32bppArgb`、alpha 一律给 255、并丢弃 Graphic Control Extension 里的透明信息（`Palette.Entries.Length == 0`）—— 素材里自带的透明等于没有 |
| **代价** | 只对"纯色背景 + 角色不贴边"的素材有效 |
| **安全阀** | 如果泛洪会移除超过 90% 的像素，就**放弃**这次抠图并把原图还原 —— 宁可留背景，也不能把猫抠没了 |
| **位置** | `pet.ps1` → `PunchBackground` |

---

## D-09 整数 7 倍最近邻放大

| | |
| --- | --- |
| **决定** | `spriteScale = 7`，`InterpolationMode = NearestNeighbor`；目标宽度 `TARGET_W = 126` |
| **理由** | 整数倍 + 最近邻能让像素保持锐利、且**不会在动画中抖动**（非整数倍会让绘制矩形在帧间取整到不同位置，肉眼就是"闪"） |
| **代价** | 尺寸只能是素材的整数倍，不能精细调大小 |
| **位置** | `pet.ps1` 的绘制路径：`dw = bw*spriteScale`、`dx = (W-dw)/2f`、`dy = H-34-dh+spriteBob` |

---

## D-10 摔倒动画被重新计时（原始时长会让画面堆积）

| | |
| --- | --- |
| **决定** | `StretchFrame(clipSleep, 0, 1); (1,1); (2,50); (6,2000); (7,1); (8,1);` |
| **理由** | 用户反馈"能看见三张图连着、已经摔倒了站立的图还在"。逐帧测量发现 `cat_die.gif` 前 3 帧都是直立姿态（18×29 / 18×29 / 19×29），按原始时长播放会让"站立"停留过久，与"倒地"叠加 |
| **代价** | 动画不再是作者的原始节奏 |
| **另一点** | `cat_die.gif` 其实不是"摔死"，而是**蹲下 → 趴着 → 站起来**；第 6 帧是作者自己给的 200ms 停留、也是最平的姿势，把它拉长到 2000ms 才变成真正的"睡一觉" |
| **位置** | `pet.ps1` → `StretchFrame` 调用表 |
| **现状** | **已作废**：应用户要求删除了睡眠功能，`cat_die.gif`、`StretchFrame` 及其全部调用已从代码与素材中移除 |

---

## D-11 `SetState` 的最短驻留判定必须放行"用户发起"的状态

| | |
| --- | --- |
| **决定** | 进入 `SetState(s, minMs, userInitiated)` 时，**只有非用户发起**的切换才受最短驻留时间限制 |
| **理由** | 托盘菜单点一个低优先级动作曾静默无反应：它的最短驻留是 4000ms，而当时刚进过别的状态，请求被直接吞掉，用户看到的是"点了没用" |
| **代价** | 用户发起的状态可以打断任何正在播放的动画 |
| **位置** | `pet.ps1` → `SetState` 的守卫条件 |

---

## D-12 每次进入状态用**本次时长**，不改共享的时长表

| | |
| --- | --- |
| **决定** | 每次 `SetState` 用局部变量 `wantMs` / `stateMinUntilMs` 记录本次时长，**不写回** `table[s].MinMs` |
| **理由** | 早先的写法把传入的 `minMs` 直接写进静态时长表，一次"睡 6 秒"会**永久**改掉之后每一次睡眠的时长 —— 症状是动画时长越用越怪 |
| **代价** | 时长表只表达默认值，实际时长要看当前这次调用 |
| **位置** | `pet.ps1` → `SetState` / `stateMinUntilMs` |

---

## D-13 右键菜单交给 WinForms 自己弹，不自己 `Show()`

| | |
| --- | --- |
| **决定** | 在构造函数里 `ContextMenuStrip = BuildMenu();`，由 WinForms 在 `WM_CONTEXTMENU`（**鼠标抬起**）时弹出 |
| **理由** | 用户反馈"右键有东西出来，但点了没反应"。根因是在 `OnMouseDown` 里手动弹菜单 —— 此时**按键还按着**，菜单收不到正常的点击序列，这是 WinForms 的经典反模式。9 个菜单项用 `PerformClick()` 逐个验证过，处理器本身全是好的 |
| **代价** | 无 |
| **位置** | `pet.ps1` → `PetForm` 构造函数、`BuildMenu()`；显式的 `ShowPetMenu` 已删除 |

---

## D-14 单实例锁在任何初始化之前

| | |
| --- | --- |
| **决定** | `Global\DesktopCat_SingleInstance` 具名互斥体；拿不到就写 `ALREADY_RUNNING` 并只弹一个提示框后退出 |
| **理由** | 双实例会变成两只猫、两个配置写入者互相覆盖 |
| **代价** | 无 |
| **注意** | 互斥体名在 **两个地方**出现（`pet.ps1` 头部的 PowerShell 驱动、以及 C# `Program.Main`），**必须同时改**，否则两处各锁各的，等于没有锁 |
| **位置** | `pet.ps1:56` 与 `pet.ps1:2271` |

---

## D-15 根目录取 `AppDomain.CurrentDomain.BaseDirectory`，不是当前目录

| | |
| --- | --- |
| **决定** | C# 里用 `AppDomain.CurrentDomain.BaseDirectory` 定位素材与数据目录；PowerShell 直跑时由外部显式传入 `$ROOT` |
| **理由** | 曾经用"当前工作目录"，结果从别的文件夹启动时素材找不到，猫变成空白。另外在 PowerShell 宿主下 `BaseDirectory` 指向临时转译目录而不是程序目录，所以 `.ps1` 那条路径必须显式传 `$ROOT` |
| **代价** | 两条入口（exe / ps1）行为不完全一致，注释里写明了 |
| **位置** | `pet.ps1` → `Program.Main` 注释 + 文件末尾的 PowerShell 驱动 |

---

## D-16 `.ico` 必须手写 32bpp 格式

| | |
| --- | --- |
| **决定** | 自己拼 ICO 字节（`BITMAPINFOHEADER` + BGRA 倒序像素 + AND 掩码），**不用** `Icon.FromHandle($bmp.GetHicon())` + `Icon.Save()` |
| **理由** | 后者只写得出**低色深调色板图标**：我画的 `(61,214,208)` 被量化成 16 色调色板里的 `Cyan(0,255,255)`，**抗锯齿的 alpha 全丢**。实测对比：量化版 766 字节 / 抗锯齿像素 **0** / 图标内颜色数 **~4**；手写版 4286 字节 / 抗锯齿像素 **126** / 颜色数 **211** |
| **代价** | 文件大 5 倍（4 KB 级，无所谓） |
| **附带教训** | 我一度把量化后的亮青当成"设计配色"报告给用户 —— **错误的工具会产生错误的结论**，而且会伪装成事实 |
| **位置** | 生成 `.ico` 的脚本（见 `tools\` 与本次会话记录） |

---

## D-17 用 `.exe` 启动，不用 `.bat` / `.lnk`

| | |
| --- | --- |
| **决定** | 交付物只有一个 `DesktopCat.exe`；`start.bat`、`启动桌宠.bat`、`preview.bat`、`诊断.bat`、`启动猫咪.lnk` 全部废弃并删除 |
| **理由** | 这台机器上每次打开 `.bat` / `.lnk` 都会弹 **Attachment Manager** 的「打开文件 - 安全警告」（`打开(O)` + `有何风险?`，**没有"不再询问"复选框**）。改 `LowRiskFileTypes` **实测无效**。而 `.exe` 不经过 Attachment Manager |
| **代价** | `.exe` 会触发另一套机制：**SmartScreen** 的「Windows 已保护你的电脑」 |
| **未解决** | 把 `EnableWebContentEvaluation` 在 **HKLM 和 HKCU 都设成 0**，SmartScreen 提示**依然出现**。标准 SmartScreen 会按文件哈希记住"仍要运行"，我们的却每次重问 —— 所以**强烈怀疑是第三方（联想电脑管家 `LenovoPcManagerService` / `LenovoServiceAS`、`douyin_performance_service`）在重新触发**。详见 `registry\README.md` |
| **位置** | 已删除；`registry\` 里保留了当时的 `.reg` |

---

## D-18 改注册表由用户双击 `.reg`，agent 不写注册表

| | |
| --- | --- |
| **决定** | 所有注册表改动做成 `.reg` 文件放 `registry\`，由用户双击合并；每个改动都配一个还原文件 |
| **理由** | 本机策略**禁止 agent 写注册表**（连 `danger-full-access` 也不放行），但**读注册表是允许的**（所以验证状态没问题）。`.reg` 合并已验证对用户有效 |
| **代价** | 需要用户动手 |
| **位置** | `registry\` |

---

## D-19 一次只做一个改动，做完停下来给用户看

| | |
| --- | --- |
| **决定** | 用户的原话：「**你别一个人在这里乱改，你改过一次后告诉我让我来看**」（说过两次） |
| **理由** | 一次性改多项时，用户看到的现象无法归因到具体哪一项改动，来回代价远大于分步 |
| **代价** | 迭代次数变多 |
| **位置** | 工作方式约定 |

---

## D-20 不要用 PowerShell 内置别名给辅助函数命名

| | |
| --- | --- |
| **决定** | 辅助函数避开别名名（`Kill` / `Diff` / `RD` / `Rm` / `Del` / `Cat` / `Where` / `Sc` / `Sort` …） |
| **理由** | **PowerShell 的命令解析顺序是 Alias > Function > Cmdlet** —— 别名优先级**高于**函数。命名为 `Kill` 的函数永远不会被调用，实际执行的是 `Stop-Process`，报错信息还会指向你的调用行，极难看出 |
| **已踩过的坑** | `Diff`（撞 `Compare-Object`）、`RD`（撞 `Remove-Item`）、以及本次清理时的 `Kill`（撞 `Stop-Process`，导致一整批删除静默失败） |
| **位置** | 所有 `.ps1` 工具脚本 |

---

## D-21 清理时只用明确路径，不用通配符

| | |
| --- | --- |
| **决定** | 删除文件时逐条列出明确路径；删目录用 `\\?\` 前缀走 `[System.IO.Directory]::Delete` |
| **理由** | ① 早先一个过宽的过滤器**误删了用户的 `.petdata`**（配置和日志），教训深刻；② `node_modules` 的深路径会超过 `MAX_PATH`，`Remove-Item` 会失败，`\\?\` 能绕过 |
| **代价** | 删除脚本更长 |
| **位置** | `CLEANUP.md` 记录了 2026-10-08 那次清理的完整清单 |

---

## D-22 消除安全提示：绕开 shell，而不是改系统策略

| | |
| --- | --- |
| **背景** | 双击 `E:\Nexus\编码\DesktopCat.exe - 快捷方式.lnk` 会弹「打开文件 - 安全警告」 |
| **结论** | 那个对话框**不是 SmartScreen**，而是 Attachment Manager 的「你要打开此文件吗?」。它拦的是**"打开一个 shell 对象"这个动作** —— 对话框自己写着「类型: 快捷方式」 |
| **决定** | ① 提供 `dist\DesktopCat.exe` **单文件启动器**，内部 `UseShellExecute = false` → 直接 `CreateProcess`，完全不经过 shell；② 提供 `registry\开机自启.reg`，登录时由 Windows 直接启动 |
| **验证** | 启动器已**实测**：运行后新增 1 个 `Desktop Cat` 窗口（pid 28228）→ 日志 `MARK_START` → Esc（只发给该新窗口）干净退出 `MARK_END`；用户真实 `.petdata` 未被触碰 |
| **位置** | `dist\`、`registry\` |

**九条被证据排除的可能（不要再重试）：**

| 假说 | 否定证据 |
| --- | --- |
| `.lnk` 带 Mark-of-the-Web | `Get-Item -Stream *` 只有 `:$DATA` |
| 目标 `.exe` 带 MOTW | 同上，只有 `:$DATA` |
| 网络盘 / 可移动盘 | `[System.IO.DriveInfo]`：E: 是 **Fixed NTFS**（"游戏"，1037 GB） |
| Smart App Control | `VerifiedAndReputablePolicyState = 0`（关闭） |
| 应用安装控制策略 | `HKLM\SOFTWARE\Policies\Microsoft\Windows Defender SmartScreen` **键不存在** |
| 第三方 shell 挂钩 | `ShellExecuteHooks`（含 WOW6432Node）**完全为空** |
| Winstep Nexus 在作怪 | `HKLM\SOFTWARE\Winstep` 不存在 —— `E:\Nexus` 只是个下载包 |
| 路径被映射到 Internet 区 | `ZoneMap\Ranges` 为空 |
| `LowRiskFileTypes` 设错 | `.lnk` **已在名单里**，照样弹（该值格式也可疑，用 `还原安全提示.reg` 清掉） |

| | |
| --- | --- |
| **方法论教训** | 排查"外部世界为什么这样"时**必须先建立对照组**。这次的关键对照是"网上下载的文件有没有 ADS" —— 结果没有，一举推翻了整条 MOTW 思路。没有对照就会在错误方向上耗很久 |

---

## D-23 真正的根因：沙箱目录上的两条显式 ACE（不是 Mark-of-the-Web）

| | |
| --- | --- |
| **症状** | 凡是**从 `...\<本机工作目录>\` 里启动**的东西都会被 Windows 拦：`.exe` 弹 SmartScreen「Windows 已保护你的电脑」，`.lnk` 弹「打开文件 - 安全警告」。**同一份文件从别的目录启动则完全不弹** |
| **根因** | 该目录上有两条**显式（非继承）ACE**，并被目录里新建的每个文件**继承**：<br>`Everyone` → **Deny** `DeleteSubdirectoriesAndFiles`<br>`S-1-4-77492772-186351626` → **Allow** `DeleteSubdirectoriesAndFiles, Write, Delete, Synchronize` |
| **证据** | 同一份 `DesktopCat.exe`（sha256 `3FA6329B3575E020…`，字节完全相同）：<br>· 沙箱目录里那份，SDDL 含 `S-1-4-77492772-186351626`<br>· `Documents\<项目目录>` 里那份，**两种 ACE 都没有**<br>· 用户把文件复制出去后，双击**不再出现任何提示**（用户实测确认） |
| **第二个独立症状** | 同一个标记还让 **PowerShell 把 `.ps1` 当成"来自远程"**：本机 `LocalMachine` 策略只是 **`RemoteSigned`**（本地未签名脚本本来可以运行），却报「未对文件进行数字签名，无法在当前系统上运行该脚本」。所以沙箱里的脚本**必须** `-ExecutionPolicy Bypass` |
| **决定** | ① 程序与快捷方式**一律从沙箱外的目录运行**（现为 `<部署目录>`）；② 新增 `tools\deploy.ps1` 承担"构建 → 复制出去"这一步，并且**永不复制 `.petdata`** |
| **位置** | `tools\deploy.ps1`、`registry\开机自启.reg`（指向部署副本） |

**为什么这么久才找到：**

| 查过的东西 | 结果 |
| --- | --- |
| 文件自身的 ADS / MOTW | 只有 `:$DATA` —— 干净 |
| 目标 `.exe` 的 ADS | 干净 |
| **目录**的 ADS（`Get-Item -Stream *`） | 输出**空**，我误判成"干净" ❌ **这是假阴性**：该 cmdlet 在目录上枚举不出流，内核级 `FindFirstStreamW` 直接返回 `ERROR 38` |
| 磁盘类型 / Smart App Control / App Install Control / `ShellExecuteHooks` / `ZoneMap` | 全部排除（见 D-22 表格） |
| **目录的 ACL** | ❌ **一开始根本没查** —— 一查就找到了 |

| | |
| --- | --- |
| **教训** | 排查"为什么系统不信任这个文件"时，**必须查它所在目录的 ACL**；并且不能相信"枚举结果为空"——要先确认那个 API **在目录上到底会不会返回空**。这次两个坑（只查文件不查目录、把目录上的假阴性当成证据）叠在一起，让我在错误方向上耗了很久 |

---

## D-24 PowerShell 5.1 读 UTF-8 无 BOM 的中文文档会乱码 —— 会让核对假通过

| | |
| --- | --- |
| **现象** | 用 `Get-Content` / `Select-String` 在 PowerShell 5.1 里搜中文，**匹配数为 0**，看起来像"文档里确实没有这句话" |
| **真因** | 本项目的 `.md` / `.reg` / 源码都是 **UTF-8 无 BOM**（刻意如此，见 D-02 附近对编码的要求），而 **PS 5.1 的 `Get-Content` 默认按 ANSI(GBK) 解码**，中文变成乱码，于是 `-match '未解决'` 永远为假 |
| **后果（真实踩到）** | 我检查 `registry\README.md` 里"作废声明有没有写进去"，结果报 `False`，差点据此又改一遍文档；实际声明写得好好的 |
| **决定** | 凡是要在 PS 里**判断文件内容**（不是给人看），一律用 `[System.IO.File]::ReadAllText($p)`（默认 UTF-8）或 `Get-Content -Encoding UTF8`；`Get-Content` 只用于**输出给人看** |
| **同一个毛病的第二个面孔** | 在**二进制**（PE/exe）里搜 UTF-16 字符串时，`[System.Text.Encoding]::Unicode.GetString(<整个文件字节>)` 会因**起始偏移不是偶数**而整体错位，`Contains()` 于是返回 `False`。本次会话这个假阴性出现了 **3 次**（都在核对"启动器里到底嵌了哪条路径"） |
| **正确做法** | 把待搜字符串也 `Unicode.GetBytes()`，再在字节数组上做**逐字节子序列搜索**（比较字节，不做字符串解码），这样与对齐无关 |
| **位置** | 所有 `.ps1` 工具脚本、所有核对脚本 |

---

## D-25 进程必须 DPI 感知 —— 否则像素画被拉伸发虚，而且鼠标判定偏掉

| | |
| --- | --- |
| **现象** | 猫的像素画边缘发软，不是锐利的方块边；拍头 / 摸身的好感度判定位置整体偏移 |
| **真因** | 程序**不是 DPI 感知**的（exe 清单里既没有 `dpiAware` 也没有 `dpiAwareness`）。本机 `HKCU\Control Panel\Desktop\LogPixels = 144` 即 **150% 缩放**，于是 Windows 把**整个窗口位图放大 1.5 倍**：7× 的像素画落在 **10.5** 个设备像素的边界上（非整数 → 被双线性插值糊掉） |
| **第二个、更隐蔽的后果** | 全局鼠标钩子 `WH_MOUSE_LL` 报的是**物理**像素，而 DPI 虚拟化下窗口用**逻辑**像素 —— 两套坐标系差 1.5 倍，所以「拍头 +2」实际在测一个**错位的矩形** |
| **环境** | 主屏 2560×1600 @150%（对不感知 DPI 的进程报告为 **1707×1067**）；副屏 2560×1440 @100% —— **混合 DPI** |
| **决定** | `Program.Main` 第一件事调用 `SetProcessDPIAware()`；所有 96-dpi 单位常量（`W`/`H`/`TARGET_W`/气泡内边距/底座锚点/好感度条）统一经 `S()` 换算。**`spriteScale` 本来就是从 `TARGET_W` 推出来的**（`TARGET_W / 帧宽`），所以只改 `TARGET_W` 一个数，7× 自动变 **10×** |
| **验证** | `GetProcessDpiAwareness` 从 0 → **1**（SYSTEM_DPI_AWARE）；日志 `scale=7x` → **`scale=10x`**；窗口实测 **510×690 设备像素**（= 340×460 × 1.5）；猫占屏宽 7.4% → **7.0%**，视觉尺寸几乎不变而边缘变锐利 |
| **注意** | 感知 DPI 后窗口坐标变成物理像素，旧 `.petdata` 里的虚拟化坐标会一次性偏移（L592-599 已有夹取逻辑，保证不会跑出屏幕）；副屏 100% 上猫会略大 —— 这是系统级 DPI 感知的固有取舍 |
| **教训** | 检测脚本自己也要先 `SetProcessDPIAware()`，否则 `GetWindowRect` 读到的仍是**虚拟化**尺寸。我第一次就上当了：读到 340×460，实际是 510×690 |

---

## D-26 新增「安静模式」与「锁定位置」两个开关

| | |
| --- | --- |
| **功能** | 右键菜单新增两个可勾选、可持久化的开关，位置在「Preview all animations」与「Reset affection」之间 |
| **安静模式** | `quiet=1` 时：`Bubble()` 直接返回（**一个气泡都不弹，包括休息提醒** —— 这是刻意的，开会就是要完全闭嘴）；`SetState(s, ms, false)` 直接返回（不自行换动画）；点击走路被跳过。**用户主动触发的动作一律不受影响**（菜单、摸头、拖动照常） |
| **锁定位置** | `locked=1` 时 `OnMouseDown` 不进入拖动分支 → 拖不动。摸头/摸身走的是全局鼠标钩子，**不受影响** |
| **持久化** | 写进 `.petdata/config.json` 的 `"quiet"` / `"locked"`，用 **1/0** 而不是 true/false —— 因为回读走的是那个极简的 `JInt()`，这样整个配置只用一个小解析器就能往返 |
| **验证（离屏，不弹窗）** | `quiet=1` → `Bubble()` 后 `bubbleText` 仍为 `null`；自动 `SetState(Dancing)` → 状态 `Idle→Idle`；**用户**触发 `SetState(Dancing,true)` → `Idle→Dancing` 正常生效；`quiet=0` → 正常说话；`locked=1/0` → `dragging` 分别为 `False`/`True` |
| **验证（实机）** | 部署后 `.petdata/config.json` 出现并回写 `"quiet": 0, "locked": 0`，证明新键真的被读进来又写回去 |
| **教训（又一次，和 D-23 同源）** | 第一版测试报 `locked=1` **通过**，实际是 `MethodInfo.Invoke` 抛了 `PSObject 无法转换为 MouseEventArgs` —— **调用根本没执行，`dragging` 保持默认 false，于是"通过"了**。改用 `[Type]::new()`（而不是 `New-Object`）构造参数才消除 PSObject 包装。**异常被吞掉 / 空结果 = 假通过** |
| **已知未修缺陷** | `PET_DATA` **只重定向了 `config.json`，没有重定向 `pet.log`**，而 pet.ps1 的注释（L23-24、L46-47）承诺「Pair it with PET_DATA so the logs stay separate」。实测：`PET_DATA=%TEMP%\catdiag` 启动后配置里的 1500,300 生效了（证明配置确实走了 `PET_DATA`），但该目录里**根本没有 pet.log**，同时 `$ROOT\.petdata` 也没被写。**只影响诊断，不影响桌宠行为**，故未在交付时一并修改（修它必须重编 exe，会让你多弹一次安全提示，不划算）。 |

---

## D-27 授权版本写错了：Cat Fighter 是 CC-BY 3.0，不是 4.0

| | |
| --- | --- |
| **发现** | 2026-10-08 评估「能否出版」时重新抓取素材源页面 <https://opengameart.org/content/cat-fighter-sprite-sheet>，页面授权栏写的是 **`CC-BY 3.0`**（链接 `http://creativecommons.org/licenses/by/3.0/`）。项目自 D-07 起一直写成 **CC-BY 4.0**，**版本号和链接两个都错** |
| **影响** | 只影响**署名合规**，不影响能否出版：CC-BY 3.0 同样**允许商用**、允许改作、**不是 ShareAlike**（不传染，本项目代码可以另用任何许可证）。但 3.0 的署名条款要求**准确写出授权版本与其链接**，写错即不合规 |
| **改在哪** | `CREDITS.txt`（法律上真正生效的那份）、`README.md` 两处、以及 `pet.ps1` 里「Stats & credits」对话框正文 —— 最后这处**必须重新编译 exe** 才会生效 |
| **不改哪（刻意）** | D-07 与 `CLEANUP.md` 保持原样。决策档与清理日志是**当时认知的历史记录**，不该被追溯涂改；纠正的责任由本条 D-27 承担 |
| **证据** | 源页面授权栏原文 `License(s): CC-BY 3.0`；同一条目的预览图列出 `cat_idle.gif`、`cat_a1..a9.gif`、`cat_die.gif`、`cat_walk.gif`、`cat_jump.gif`、`cat_fighter_sprite1.png`，与本项目 `cat-assets\ex-F-cat-anim-pack\` 内文件一一对应（`cat_die.gif` 后来已随睡眠功能一并删除），确认同源 |
| **顺带核实** | `CREDITS.txt` 中列为「已移出项目、仅作来源记录」的那批素材（CC0 / CC-BY 3.0 等）确实已不在包内（部署目录只有 12 个 GIF + 2 个 PNG），因此它们标注是否准确**不产生法律义务** |
| **出版前仍待处理** | `README.md` 末行写着「代码部分：UNLICENSED（私有项目）」—— 出版前必须为**自己的代码**选定许可证（CC-BY 3.0 只管美术、不传染，代码可任意选择），否则他人没有合法权利再分发/修改 |

---

## D-28 发布包的定义：装什么、不装什么，以及 CREDITS.txt 的收敛

| | |
| --- | --- |
| **触发** | 用户要求「打一个干净的发布包」（选项 a） |
| **产出位置** | `<发布目录>\`（**必须在沙箱工作区之外** —— 否则每个文件都会继承 D-23 的那条目录 ACL，别人拿到就会被 SmartScreen 拦） |
| **装** | `DesktopCat.exe`、`DesktopCat.ico`、`CREDITS.txt`、`README.md`（面向使用者的重写版）、`cat-assets\` 全部素材。共 18 个文件 ≈ 127 KB |
| **不装** | `.petdata\`（用户私人存档，含好感度与位置）、`tools\`（11 个开发/验证脚本，`deploy.ps1` 里硬编码了绝对路径）、`registry\`（含「关闭应用检查」这种关掉 Windows 安全校验的 .reg，公开分发会招举报）、`pet.ps1`、`DECISIONS.md`、`CLEANUP.md` |
| **素材目录拍平** | 开发期的 `cat-assets\ex-F-cat-anim-pack\` → 发布包用 `cat-assets\`。`pet.ps1` 的素材发现顺序是 `cat-assets\ex-F-cat-anim-pack` → `cat-assets` → `<data>\cat-assets`，所以第二项就能命中；此结论由**实际运行发布包内的 exe 并读它自己的日志**验证（`sprites OK dir=<发布包>\cat-assets`、`clips=13`） |
| **`CREDITS.txt` 收敛** | 原文件里有两段**开发期内容**不适合发布：①「NOTE ON THE PROJECT NAME」讲的是本机文件夹名与 `CLEANUP.md`（包里没有这个文件，引用悬空），并且是**唯一还把 `Miku` 写进交付物的地方**；②「ALTERNATIVE / UNUSED ART」清单列的是**已不在包内**的素材，其中一条写着别的 `CC-BY 4.0`，会让审阅者误以为主素材也是 4.0。两段都已迁出：①的实质内容（改名历史）本来就由 D-07 记录，②迁入 `CLEANUP.md`。现在的 `CREDITS.txt` 只含**真正生效的归属声明** + 一段「无第三方角色资产、无 Live2D/Cubism、无网络代码」的来源说明 |
| **收敛的收益** | `CREDITS.txt` 在**项目内与发布包内完全相同**（不像发布 README 那样需要一份衍生的裁剪版），避免两份文件日后走样；同时交付物里 `Miku` 与 `CC-BY 4.0` 的出现次数都归零 |
| **验证** | 对包内每个文件做字节级扫描：本机用户名、绝对路径、开发目录名全部 0 命中；发布包内的 `DesktopCat.exe` 与部署版 sha256 完全一致（同一个二进制，未二次编译） |
| **仍然未决** | 代码自身的许可证（见 D-27 末行）—— 发布包里的 README 暂时写「代码保留所有权利」，用户选定后应同步更新 |

---

## D-29 代码许可证定为 MIT（美术仍是 CC-BY 3.0，两者互不传染）

| | |
| --- | --- |
| **决定** | 程序**代码**采用 **MIT**；**美术素材**仍为 CC-BY 3.0，**不在 MIT 覆盖范围内** |
| **为什么可以这么分** | CC-BY 3.0 **不是 ShareAlike**，不对衍生作品施加许可证要求，所以代码可以另用 MIT；反过来 MIT 也不改变素材的授权。两者互不影响 |
| **落地** | 项目根新增 `LICENSE`（MIT 全文，一字未改）；发布包 `README.md` 第五节重写为「代码 MIT / 美术 CC-BY 3.0」并分别指向 `LICENSE` 与 `CREDITS.txt`；`README.md` 末行的 `UNLICENSED（私有项目）` 同步改掉 |
| **版权行** | 已定为 **`Copyright (c) 2026 daijun`** —— 这是作者指定的署名。MIT 要求保留版权声明；日后要更换署名主体，只需改 `LICENSE` 里的这一行并重新打包 |
| **给别人什么权利** | 任何人可以免费使用、修改、再分发、**商用**；义务只有一条：保留版权与许可声明 |

---

## D-30 打包工艺：两个真踩到的坑，以及「先验证再换名」

| | |
| --- | --- |
| **坑一：反斜杠** | PowerShell 5.1 的 `Compress-Archive` 写出的 zip，**条目名用反斜杠**（`DesktopCat-1.0\cat-assets\cat_a1.gif`）。Explorer 读得出来，因此很容易漏掉；但 ZIP 规范 APPNOTE 4.4.17.1 要求路径分隔符 **MUST be forward slashes**，macOS/Linux 或严格解压器会把整条路径当成**一个文件名**，素材在包里等于消失 |
| **坑一的修法** | 用 `System.IO.Compression.ZipFile` 手工建条目，名字自己拼成 `DesktopCat-1.0/cat-assets/...`（`.Replace('\','/')`），逐个 `CreateEntry` 写入字节 |
| **坑二：枚举字面量** | `[System.IO.Compression.ZipArchiveMode]::Create` 在**全新的 PS 5.1 会话**里解析不了（`找不到类型 [System.IO.Compression.ZipArchiveMode]`）—— 只 `Add-Type -AssemblyName System.IO.Compression.FileSystem` 并不会把 `System.IO.Compression` 一起拉进来。于是第一个文件就抛异常，最后留下一个 **0 字节的 zip** |
| **坑二的修法** | 改用 `[System.IO.Compression.ZipFile]::Open($path, 'Create')` —— **传字符串**，由 PowerShell 隐式转成枚举 —— 并显式加载两个程序集；`CreateEntry($name)` 不带压缩级别参数（默认就是 Optimal） |
| **流程教训（比上面两个更值钱）** | 第一次是「**先删旧 zip，再构建**」，构建一失败就把**已经验证过的那一份**弄没了，手里一个可用产物都没有。改成「构建到 `<名字>.new` → 全部校验通过 → 才换名顶替」，之后失败也不会损失上一个可用版本。**"删除"和"构建"之间必须隔一道验证** |
| **验证必须独立** | 只用 .NET 读回自己写的包，等于自己给自己判卷。改用 **bsdtar**（`tar -tf` / `tar -xf`，Windows 自带、完全不同的实现）列表 + 解压，再对每个文件逐一比对 sha256：`identical = 19, different/missing = 0`，且解压出的文件名里没有反斜杠 |
| **发布包规模** | 20 个文件（含后加的 `LICENSE`），压缩后 91.2 KB。`DesktopCat.exe` 的 sha256 `4D415C45E24D9B51…` —— **本次只改文档，未重编 exe**，所以它从头到尾没变（也意味着用户不会因为这次打包多挨一次安全提示）。zip 的哈希随内容变化，发版时单独记录 |
| **文档改动也会改哈希** | 改 `LICENSE` 的署名（`The Desktop Cat authors` → `daijun`）就要**重打 zip**（zip sha256 从 `43DE694A…` 变为 `C8F84639…`）。exe 不变。**发版说明里的哈希必须来自最终那一份包**，不能沿用旧值 |

---

## D-31 写验证命令时不要深嵌套括号 —— 解析失败会让整段脚本一行都不执行

| | |
| --- | --- |
| **现象** | 端到端验证脚本报 `表达式或语句中包含意外的标记 ")"`（UnexpectedToken），`[exit code: 1]`，**整段脚本一行都没跑** |
| **真因** | 我写了 `Write-Output ("…" + (Test-Path -LiteralPath (Join-Path $t '…\.petdata')))` —— 4 个左括号只配了 3 个右括号。**这种行有 100 多个字符，肉眼数括号不可靠** |
| **后果** | 浪费一轮；更危险的是，如果这种错误出现在**清理/删除类**脚本里，"前半段执行了、后半段没执行"会留下不一致状态 |
| **规矩** | ① 验证/清理脚本一律**先算进变量，再输出**：`$made = Test-Path -LiteralPath (Join-Path $t '…')` 然后 `Write-Output ("… = " + $made)`；② 一段脚本里**最多一层**函数调用嵌套；③ 这是本项目**第二次**因为引号/括号导致整段脚本不执行（另一次见 D-24 附近的 `'HELLO-TEST'` 事件），所以当成规则而不是偶发 |
| **顺带一条** | 与 D-30 的"先验证再换名"配合：**破坏性操作（删除、覆盖）必须放在所有校验通过之后**，这样脚本中途炸掉也不会损失可用产物 |

---

## D-32 不做 AI 对话：它会把「双击即用」这个卖点拆掉

| | |
| --- | --- |
| **决定** | **不做**联网 AI 对话。产品保持单文件、免安装、无依赖、无联网 |
| **理由** | 功能本身**已经实现并验证通过**（`ChatForm` + `AiCfg` + `ai.json`：C# 编译 0 错误、17 项断言全过、坐标无重叠、key 不进日志）。否掉它的**不是技术，是分发**：要用上对话，使用者必须先去 DeepSeek 注册账号、充值、再拿一个 key 填进来。一只桌面宠物要求玩它的人**先注册再付钱**，等于把「双击就能用」这个唯一的卖点自己拆了 |
| **是谁决定的** | 作者本人。原话：「我不需要和它对话，现在就可以了，因为如果配置的话，别人要玩还要注册这不合理」 |
| **代价** | PRD 里的头号功能不再实现。猫只能按内置的 18 组台词说话，不会真的对话 |
| **回退方式** | 按既有的「不留死东西」规矩**整体回退**，而不是留着禁用代码。`git checkout -- pet.ps1` 从初始提交取回：**111,795 字节**、非 ASCII **0**、`ChatForm/AiCfg/deepseek/ShowChat/ai.json` 残留 **0** 处、`git status --porcelain` 为**空**。同时删除 `ai.json.example`、`tools\probe-chat.ps1` 与探针截图 |
| **顺带确认** | 发布包**一个字节都没动**：`DesktopCat.exe` sha256 `4D415C45E24D9B51…`、`DesktopCat-1.0.zip` sha256 `C8F84639F80FFF36…`，均与记录一致 —— 下载过的人不会再多挨一次 SmartScreen |
| **过程中查到的两件实事** | ① 官方模型名已换成 **`deepseek-flash` / `deepseek-v4-pro`**，`deepseek-chat` 是遗留名（照原样发出去会直接 400）；② 官方定价页只写「充值余额或赠送余额」，**没有**免费额度承诺 —— 所以"要花钱"这个前提是成立的。两条都来自 <https://api-docs.deepseek.com/quick_start/pricing> |
| **将来若改主意** | 想**零成本、零注册**地加回来，路是**本地模型**（Ollama 之类）：已验证过的 `baseUrl` 字段天然支持 OpenAI 兼容端点，同一套代码可指向 `http://127.0.0.1:11434/v1`。代价是使用者要下 1 GB 安装包 + 4~5 GB 模型。本次不做 |
| **一条工具教训（顺带）** | 用 `DrawToBitmap` 截图去验证 WinForms 界面时，**RichTextBox 的内容永远画不出来**（原生控件不响应 `WM_PRINT`），只看截图会把"正常"误判成"坏了"。可靠的仪器是**读控件的真实屏幕坐标 + 读文本本身**。另外 here-string 的结束符 `'@` **必须独占一行**，否则整段脚本连解析都过不去 |

---

## D-33 删除睡眠功能，右键菜单的「睡觉」换成「撒欢」

| | |
| --- | --- |
| **决定** | 用户原话：「把你的动作列表的第五个动作替代右键睡觉的选项，然后有关睡觉的全部删了，包括动作列表里面的睡觉的动作」。最终版本：菜单第 5 项由「睡觉」改为「撒欢」，驱动 `PetState.Cheer` / `cat_a7.gif`（14 帧）；睡眠状态、`clipSleep`、`cat_die.gif` 及其全部配套代码一并删除 |
| **理由** | 用户明确要求。另外 `cat_die.gif`（9 帧）本来就不是「摔倒」，而是**蹲下 → 趴着 → 站起来**，要靠把第 6 帧从 200ms 拉到 2000ms 才能当睡眠用（见 D-10）；它是整包素材里唯一必须改帧时长才能用的动作 |
| **「动作列表」指什么** | 指「预览所有动作」气泡里的 `[n/13] 文件名` 编号（`cat_*.gif` 经 `Array.Sort` 排序）。第 5 个是 `cat_a5`，而它已经占着菜单里的「陪我玩」，会重复 —— 所以让用户重新挑，最终选了第 7 格 `cat_a7` |
| **命名** | 定名「撒欢」而不是「欢呼」：逐帧看第 7 格的主帧是**四肢张开的转体/落地**，不是举爪欢呼。用户已确认沿用此名与素材 |
| **行为变化** | 深夜与长时间无人理会时**不再打盹**。自主调度里原本给打盹的 12% 概率整体转给「撒欢」，所以整体活泼程度与删除前一致（已确认可接受） |
| **代价** | 素材包由 13 个 GIF 变为 12 个；`StretchFrame()` 失去唯一调用者后一并删除；夜间性格比之前略吵 |
| **连带修复** | README 那张 `docs/states.png` 原本第三格就是躺平睡姿、图内还印着「打盹」「睡觉」，而生成它的脚本早已不在仓库里。已重画为 `发呆 / 伸懒腰 / 跳舞 / 撒欢`，并把生成器固化为 `tools\make-states-banner.ps1`（内含「标题带亮像素少于 200 就抛错」的自检 —— 因为第一版曾出现「一个字没画上却报告成功」） |
| **位置** | `pet.ps1`（枚举 / 状态表 / 两个 switch / 自主调度 / `BuildMenu`）、素材包、`CREDITS.txt`、`README.md`、`README.en.md`、`DEVELOPMENT.md`，以及 `tools\` 下四个引用 `PetState.Sleep` 会因此报错的工具 |
| **验证** | 用编译后的 C# 反射读真实菜单：`撒欢 [U+6492 U+6B22]` 在、「睡觉」不在、`ClipCount() = 12`；实跑日志 `sprites OK … clips=12` 与 `preview: 12 clips`；`pet.ps1` 仍是纯 ASCII、无 BOM、PowerShell 解析与内嵌 C# 编译均 0 错误；v1.0 的 `DesktopCat.exe`（4D415C45…B40E）与 `DesktopCat-1.0.zip`（C8F84639…1324）哈希未变 |

## D-34 状态窗口里那个写死的「13」：一次「计数与文案各写一遍」的教训 + v1.1 发版记录

| | |
| --- | --- |
| **现象** | 「状态与署名」（`DesktopCat.InfoForm`）窗口里 CC-BY 段落写着「13 个动作全部使用」，而**它正上方那一行**由 `ClipCount()` 生成、写的是 **12**。同一个小窗口里两个数当场打架 |
| **真因** | 那段是**手写死的数字**，不是从 `ClipCount()` 生成的 —— 睡眠功能删除时动作数 13 → 12（见 D-33），这一处漏改。**这与 D-33 是同一批遗漏的两个面孔**：素材删了、菜单改了，状态窗口里的一句长文案没人看第二眼 |
| **为什么现在才发现** | 这段话只出现在**窗口正文**里，验证脚本从没断言过它（D-33 只断言了菜单与 `ClipCount()`），v1.0 发出去的那份 exe 里一直是「13」 |
| **修法** | 改 `pet.ps1` 的 C# 源码：`13 个动作全部使用` → `12 个动作全部使用`。**同一段里**「她会欢呼」→「她会撒欢」，让措辞与改名后的动作一致（菜单项「撒欢」、素材 `cat_a7.gif`） |
| **纪律（比这次修复更值钱）** | **凡能被程序算出来的数，不要手写在文案里。** 已有的「上方的计数」就是范例（`ClipCount()`）；这一句是本项目里唯一的例外，于是它漂了 |
| **代价** | 没有算法变化，只多了一次重新编译 + 重新打包 |
| **发布时点** | 这是 **v1.1 发布前的最后一次代码改动**，所以两个发布产物都是**修复之后**重编/重打的；v1.0 的两份产物**刻意原样不动** |
| **重编（修复后）** | `DesktopCat.exe`：**52,736 字节**、sha256 **7D306BDD997558A8424C5F872AEACDEC26C2D2A996CE4378F733631A0AAE29A1**、PE 子系统 **WINDOWS_GUI**；图标从 exe 里读回与原图**逐像素 0 差异** |
| **重打（修复后）** | `C:\Users\21653\Documents\DesktopCat-1.1\` 与 `DesktopCat-1.1.zip`：**19 个条目 / 92,200 字节**、zip sha256 **9E547A71FF8A81EAC86516610125EDC56AD294A3D1A59EFA265AA72C1A19479A**（v1.0 的 zip 是 **20 条目 / 93,382 字节**，差的正是已删除的 `cat_die.gif`） |
| **冒烟（工作区外 + 独立 `PET_DATA`）** | 日志：`sprites OK … clips=12`、`clip cheer <- cat_a7.gif (14 frames) box=26x29`、`mouse hook installed`，`cat_die` 与 `Sleep` 出现 **0 次**；跑 **13 秒**后干净退出 |
| **界面核对** | `tools\verify-menu.ps1` 读活窗体菜单：**PASS**、`ClipCount() = 12`、**17 个顶级条目**、无打盹条目、`撒欢 [U+6492 U+6B22]` 在 |
| **v1.0 刻意不动（已复核）** | `DesktopCat.exe` **4D415C45E24D9B5174B86A7D173C77AA6435E558A8432E13FF995FA76488B40E**；`DesktopCat-1.0.zip` **C8F84639F80FFF366D5924A59BB4D7A6DCAB2550D75F46CD59DF642A49BC1324** —— 已下载的人不会因为这次发版再多挨一次 SmartScreen |
| **验证的性质** | 本次没有算法改动，所以验证的核心就是**数字与名字对齐** —— 而这次出错的地方恰好就是这个。v1.1 之后：exe 与 zip 的哈希、`ClipCount()`、菜单条目、状态窗口正文，四处**互相印证到同一个「12」** |
| **顺带（推广物料）** | 已发布的帖子还在展示**旧的右键菜单**并写着「睡觉」，因此推广物料一并重做：`make-promo.ps1` / `make-xhs.ps1` 改 `Sleep → Cheer`、四个状态改为**发呆 / 伸懒腰 / 跳舞 / 撒欢**、菜单卡列**当前的 13 个条目**、`DesktopCat-1.0.zip → DesktopCat-1.1.zip`、`sprite-sleep.png → sprite-cheer.png`；重出 `promo-states.png`、`promo-hero.png`、`xhs-1..9.png`、`xhs-contact.png`、`v11-stats-window.png` + `.txt`（现在写 **12 个动作**、全文 **0 处**「13」），并新拍了一组 **1920x1080** 桌面截图 |
| **编码（第二次踩，故记下来）** | 这两个 `.ps1` 带中文，**UTF-8 BOM 是刻意保留的**：PowerShell 5.1 把无 BOM 的 UTF-8 当 ANSI 读，每个中文字符串都会变乱码 —— 这个坑本项目已经**踩过两次** |
| **新增两个工具** | `DesktopCat-promo\make-desk-shot.ps1`（拍**真实** Windows 桌面、把猫合成进去，**真实的 `ContextMenuStrip` 原样入镜**）、`make-stats-shot.ps1`（构造真实 `InfoForm`、显示、裁剪，并从**活的 TextBox 里转录正文**，所以 `.txt` 不可能与程序走样） |
| **平台目录与草稿** | 桌面上的 `DesktopCat-sspai` / `DesktopCat-appinn` / `DesktopCat-xhs` 已更新，旧文件备份到 `DesktopCat-promo\_backups\old-platform-assets\`；`Documents\` 下六份中文草稿（bilibili / 小红书 / 少数派 / 新手报到 / appinn-post / Appinn论坛帖）与 `DesktopCat-promo\post-body.txt` 已改正：`睡觉/打盹 → 撒欢`、`DesktopCat-1.0.zip → DesktopCat-1.1.zip`，并把**每一条「她夜里会睡觉」的说法整句删掉** |
| **删除的边界** | 这次删的是**推广文案里关于睡眠的主张**，不是历史记录。D-33 与上一轮进度记录里关于删除睡眠功能的经过**原文保留**（和 D-27 的规矩一致：历史档不追溯涂改）；程序侧现在确实**没有任何夜间专属行为** —— `IsNightHour` 逻辑已删，`pet.ps1` 里出现 **0 次** |
| **位置** | `pet.ps1`（内嵌 C# 的 `InfoForm` 正文）、`DesktopCat-promo\`、桌面的平台目录、`Documents\` 下六份草稿 |

## D-35 —— 修两个"看不见但真的会发生"的 bug：窗口空白区抢点击、她够不到屏幕顶部

| | |
| --- | --- |
| **现象（用户报告）** | ① 她**头顶上方一大片空白**，明明没东西，点下去她**照样有反应**；② 因此/另外，她**永远到不了桌面最顶部**，像被什么挡住 |
| **根因 ①-a** | 窗体 **340×460**（150% DPI 下 **510×690**），而她的画只有 **126×210**（idle 帧 18×30 × 缩放）→ **头顶空 223px**（150% 下 ≈335px）、左右各空 ~107px，整个窗口约七成是空的 |
| **根因 ①-b** | `OnPaint` **从不填背景**：没有 `g.Clear`、没有 `base.OnPaint(e)`、也没有 `OnPaintBackground` 覆盖 → 那些像素**不是透明键色**，在 Windows 眼里**属于窗口** → 点它 = 点她 → `OnMouseUp`「没拖动 = 单击」→ `Pet()`（被摸头 / 变开心） |
| **根因 ②** | `OnMouseMove` 里 `ny = Math.Max(scr.Top, …)` 夹的是**窗口顶**，而她的头画在窗口顶下方 223px → 永远差那么多够不到顶部 |
| **修法 ①** | `OnPaint` 开头 `g.Clear(MAGIC)`：每帧把整窗铺成透明键色 |
| **修法 ②** | 新增 `WndProc` 处理 **`WM_NCHITTEST`**：光标不在她**真的画出来的像素**上就返回 **`HTTRANSPARENT`**，这个点击归下面的窗口 |
| **修法 ③** | 全局钩子的判定由**矩形**改为**按当前帧 alpha 逐像素采样**（`OnPaint` 里把真实落点记进 `hitBmp`/`hitDest`）——顺带修掉一个隐藏问题：撒欢的帧宽 **26px**（idle 是 **18px**），原来落在旧框外的那部分点了没反应 |
| **修法 ④** | 顶部夹取改为 `scr.Top - ArtworkTopRoom()`：窗口顶允许伸出屏幕，`ArtworkTopRoom()` 取**最高的那套动作**（探针测得 **209px**，150% 下 ≈314px）→ 任何姿势她都能贴到顶；启动夹取与 `-1/-1`（"从未存过位置"）哨兵一并处理，否则贴顶的位置重开会丢 |
| **证据（反射直测，不是推测）** | `HitCat()`：身体正中 **True**；头顶 60px / 200px **False**；窗口左上角、左下角、左右各 40px **False** —— 8 个探点全部符合预期 |
| **重编译与冒烟** | C# **0 errors**；`DesktopCat.exe` **53,760 字节**、sha256 **190BED6564086A17F4927FAB309A396C8FC79C991183D828ADC78F72924630C6**；工作区外 + 独立 `PET_DATA` 冒烟：`clips=12`、`mouse hook installed`、无 `UNHANDLED` |
| **⚠ 取代 D-34 的哈希** | D-34 记的 exe **7D306BDD…** 与 zip **9E547A71…** **已作废**（D-34 的正文按规矩不追溯涂改）；新 zip **0489FEDD51304662526C23E005D42AFFB76F3E16943E7C90874947379936821A**（**92,198 字节 / 19 条目 / 12 个 GIF**，zip 内 exe 与磁盘 exe 同哈希） |
| **三处 exe 已对齐** | `MikuDesktop\DesktopCat.exe`、`Documents\DesktopCat-1.1\DesktopCat.exe`、桌面 `桌面小猫-发布素材\02-安装包\DesktopCat-1.1\DesktopCat.exe` —— **同一个哈希** |
| **刻意没动的** | v1.0 的 exe / zip（`4D415C45…B40E` / `C8F84639…1324`）；推广用的桌面截图与 B 站视频（它们是把猫**离屏合成**出来的，不经过这个窗口，所以不受这次修复影响） |
| **位置** | `pet.ps1`：`OnPaint`（`g.Clear(MAGIC)`）、新增 `WndProc`、`OnGlobalClick`、`OnMouseMove`、启动夹取 |