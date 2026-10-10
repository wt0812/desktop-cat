# Desktop Cat —— 开发与构建

面向**改代码的人**。想玩猫请看 [README.md](README.md)。

---

## 项目结构

```text
pet.ps1                 <- 唯一的源代码（PowerShell 5.1 + 内嵌 C#）
DesktopCat.ico          <- exe 图标（构建时嵌进去）
cat-assets\             <- 像素素材（12 个 GIF）
tools\                  <- 构建脚本 + 验证工具
.petdata\               <- 运行期数据（不进仓库：config.json + pet.log）
```

`pet.ps1` 的结构是三段：前面一小段 PowerShell（定位目录、单实例互斥、`Add-Type`），
中间是 `@' ... '@` 里的一整段 C#（`namespace DesktopCat`），最后是启动入口。

**没有安装步骤、没有依赖、没有运行时。** 编译出的 `.exe` 是自包含的 GUI 程序
（PE subsystem = `WINDOWS_GUI`，所以双击不会闪黑框）。

---

## 改代码 -> 重新编译

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\build-exe.ps1
```

它把 `pet.ps1` 里 `@' ... '@` 之间的 C# 抽出来，用 CodeDom 编译成 `DesktopCat.exe`，
并且**自己验证三件事**：

1. 0 error / 0 warning
2. PE subsystem 必须是 `WINDOWS_GUI`
3. 嵌进去的图标必须与 `DesktopCat.ico` **逐像素**相同

**改代码后一律走这个脚本**，不要手改 `.exe`。

---

## 构建产物怎么装到你自己的目录

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\deploy.ps1 -Destination "D:\某个目录"
```

不传 `-Destination` 时，默认装到 `%USERPROFILE%\Documents\DesktopCat`；
也可以用环境变量 `DESKTOPCAT_DEPLOY` 指定一个固定目录。

它会：

- **跳过 `.petdata`** —— 那是猫自己的状态（好感度、窗口位置），不能被覆盖
- 逐文件比对哈希，第二次跑不会重复复制，只报告真正变化的文件
- 猫正在运行、`.exe` 被占用时给出明确提示并退出，而不是复制到一半失败
- 目标目录若被误设成「源目录内部」会直接拒绝（否则会无限自我复制）

---

## 验证工具（`tools\`）

这些都是**离屏**跑的：构造 `DesktopCat.PetForm` 但不 `Show()`，
所以你屏幕上不会闪东西。

| 脚本 | 作用 |
| --- | --- |
| `build-exe.ps1` | 编译 + 三项自检（见上） |
| `probe-harness.ps1` | 离屏构造对象 -> 打印当前状态、状态机耗时、每帧帧号与缩放 |
| `capture-states.ps1` | 把各状态各渲染一张 PNG 到 `state-caps\` |
| `fall-strip.ps1` | 摔倒动画的逐帧轮廓校验（宽度只能变宽，且必须是缩放基准的整数倍） |
| `dump-frames.ps1` | 逐帧导出 |
| `dump-clip-strip.ps1` | 单个动画片段导成一条长图 |
| `verify-info.ps1` | 验证「统计与致谢」窗口 |
| `gen-lines.ps1` + `lines.txt` | 台词表的**唯一真源**：改台词先改 `lines.txt`，再跑脚本生成 C# 转义数组 |

> 这些脚本都用 `$PSScriptRoot` 定位项目根目录，所以**整个文件夹可以随便改名、搬家**。

---

## 设计决策记录

[DECISIONS.md](DECISIONS.md) 记了 30 多条，每条都是「决定 / 理由 / 代价 / 代码位置」，
包括几个真踩过的坑：透明度键、DPI 缩放与逐显示器混用、动画帧时长下限、
图标位深、单实例互斥体、以及素材许可证版本的更正过程。

---

## 许可证

- 程序代码：**MIT**（见 [LICENSE](LICENSE)）
- 角色素材：**CC-BY 3.0**（见 [CREDITS.txt](CREDITS.txt)，**再分发必须保留**）
