<#
    sync.ps1 -- 把本仓库推送到所有已配置的远端，然后逐个回读校验。

    用法（在仓库根目录，或任意目录）：
        powershell -ExecutionPolicy Bypass -File tools\sync.ps1
        powershell -ExecutionPolicy Bypass -File tools\sync.ps1 -DryRun     # 只看计划，不推

    设计要点（都是被现实教出来的）：
      1. 代理按远端分开：GitHub 需要走本地代理，Gitee 等国内站必须不走，
         否则很容易撞上 "TLS connect error: unexpected eof while reading"。
      2. 每个远端都带重试：代理抖动是常态，一次失败不代表推不上去。
      3. 推完必须 ls-remote 回读比对：git 说 pushed 不等于远端真的有了。
      4. 远端从 git 配置里读，不写死任何 URL。
#>

[CmdletBinding()]
param(
    [switch]$DryRun,
    [int]$Retries = 4,
    [int]$RetryWaitSeconds = 6
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- 定位仓库根目录
$here = Split-Path -Parent $MyInvocation.MyCommand.Path          # ...\tools
$ROOT = Split-Path -Parent $here                                  # 仓库根
if (-not (Test-Path -LiteralPath (Join-Path $ROOT '.git'))) {
    Write-Host "✗ 找不到仓库根目录（$ROOT 下没有 .git）" -ForegroundColor Red
    exit 1
}

$git = 'git'

# ⚠ 参数名绝不能叫 $Args —— 那是 PowerShell 的自动变量。
#    一旦叫 $Args，@Args 展开的是「函数自己的未绑定参数」，而不是你传进来的那个数组，
#    结果 git 被调用成 `git -C <repo>`（没有子命令），只会打印 usage 说明。
#    2026-10-09 踩过一次：dry run 测不出来，因为 dry run 根本不执行推送那一段。
function Invoke-Git {
    param([string[]]$ArgList)
    # Native commands write their normal progress to stderr: git push prints
    # "To https://..." and "* [new branch] ..." on stderr.  Under
    # $ErrorActionPreference = 'Stop' PowerShell promotes that stderr to a
    # terminating NativeCommandError, which killed this script mid-run
    # (GitHub got pushed, Gitee never ran).  So: relax EAP around the native
    # call and judge success ONLY by $LASTEXITCODE.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $git -C $ROOT @ArgList 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    return @{ Output = $out; Code = $code }
}

# ---------------------------------------------------------------- 代理策略
# 远端名 -> 是否走代理。GitHub 走，国内站不走。
function Set-ProxyFor {
    param([string]$RemoteName)
    if ($RemoteName -eq 'origin') {
        $env:HTTPS_PROXY = 'http://127.0.0.1:7890'
        $env:HTTP_PROXY  = 'http://127.0.0.1:7890'
        return 'proxy http://127.0.0.1:7890'
    } else {
        $env:HTTPS_PROXY = ''
        $env:HTTP_PROXY  = ''
        $env:ALL_PROXY   = ''
        return 'direct (no proxy)'
    }
}

# ---------------------------------------------------------------- 前置检查
Write-Host ''
Write-Host '==== sync: 推送到所有远端 ====' -ForegroundColor Cyan

$branch = (& $git -C $ROOT rev-parse --abbrev-ref HEAD).Trim()
$head   = (& $git -C $ROOT rev-parse HEAD).Trim()
$tags   = @(& $git -C $ROOT tag)

Write-Host ("  分支      : " + $branch)
Write-Host ("  本地 HEAD : " + $head)
Write-Host ("  标签      : " + $(if ($tags.Count -gt 0) { $tags -join ', ' } else { '(无)' }))

if ($branch -eq 'HEAD') {
    Write-Host '✗ 处于游离 HEAD 状态，拒绝推送。先切回分支。' -ForegroundColor Red
    exit 1
}

# 未提交的改动只警告，不阻断（有时就是要推已提交的那部分）
$dirty = @(& $git -C $ROOT status --porcelain)
if ($dirty.Count -gt 0) {
    Write-Host ''
    Write-Host ('⚠ 工作区有 ' + $dirty.Count + ' 处未提交的改动 —— 本次只推送已提交的内容：') -ForegroundColor Yellow
    foreach ($d in ($dirty | Select-Object -First 8)) { Write-Host ('     ' + $d) }
    if ($dirty.Count -gt 8) { Write-Host ('     ... 还有 ' + ($dirty.Count - 8) + ' 处') }
}

# ---------------------------------------------------------------- 远端清单
$remotes = @(& $git -C $ROOT remote)
if ($remotes.Count -eq 0) {
    Write-Host '✗ 一个远端都没有配置。' -ForegroundColor Red
    exit 1
}

# origin 先推（它是主仓库），其余按字母序
$ordered = @()
if ($remotes -contains 'origin') { $ordered += 'origin' }
foreach ($r in ($remotes | Sort-Object)) { if ($r -ne 'origin') { $ordered += $r } }

Write-Host ''
Write-Host ('  远端清单  : ' + ($ordered -join '  →  '))
Write-Host ''

# ---------------------------------------------------------------- 逐个推送
$results = @()
$anyFail = $false

foreach ($remote in $ordered) {
    $mode = Set-ProxyFor $remote
    Write-Host ('---- ' + $remote + '   [' + $mode + '] ----') -ForegroundColor Cyan

    $url = (& $git -C $ROOT remote get-url $remote).Trim()
    Write-Host ('     地址: ' + $url)

    if ($DryRun) {
        Write-Host ('     [DryRun] 本应执行: git push ' + $remote + ' ' + $branch + ' --tags')
        $results += [pscustomobject]@{ Remote = $remote; Pushed = 'dry-run'; Verified = '-' ; Url = $url }
        continue
    }

    $ok = $false
    $attempt = 0
    while ($attempt -lt $Retries) {
        $attempt++
        if ($attempt -gt 1) { Write-Host ('     第 ' + $attempt + ' 次尝试 ...') }
        $r = Invoke-Git @('push', $remote, $branch, '--tags')
        if ($r.Code -eq 0) {
            foreach ($line in $r.Output) { if ($line) { Write-Host ('     ' + $line) } }
            $ok = $true
            break
        } else {
            $firstLine = ''
            foreach ($line in $r.Output) { if ($line) { $firstLine = [string]$line; break } }
            Write-Host ('     ✗ ' + $firstLine) -ForegroundColor Yellow
            if ($attempt -lt $Retries) { Start-Sleep -Seconds $RetryWaitSeconds }
        }
    }

    if (-not $ok) {
        Write-Host ('     ✗ ' + $remote + ' 推送失败（已重试 ' + $Retries + ' 次）') -ForegroundColor Red
        $results += [pscustomobject]@{ Remote = $remote; Pushed = 'FAILED'; Verified = '-'; Url = $url }
        $anyFail = $true
        continue
    }

    # 回读校验：远端的分支是否真的等于本地 HEAD
    $remoteHead = ''
    $r2 = Invoke-Git @('ls-remote', $remote, ('refs/heads/' + $branch))
    foreach ($line in $r2.Output) {
        $parts = ([string]$line).Trim() -split '\s+'
        if ($parts.Count -ge 1 -and $parts[0].Length -ge 7) { $remoteHead = $parts[0]; break }
    }

    if ($remoteHead -eq $head) {
        Write-Host ('     ✓ 回读校验通过：远端 ' + $branch + ' = ' + $head.Substring(0, 12)) -ForegroundColor Green
        $results += [pscustomobject]@{ Remote = $remote; Pushed = 'OK'; Verified = 'MATCH'; Url = $url }
    } else {
        Write-Host ('     ✗ 回读校验失败：远端 = ' + $remoteHead + '   本地 = ' + $head) -ForegroundColor Red
        $results += [pscustomobject]@{ Remote = $remote; Pushed = 'OK'; Verified = 'MISMATCH'; Url = $url }
        $anyFail = $true
    }
    Set-ProxyFor 'origin' | Out-Null   # 复位
}

# ---------------------------------------------------------------- 汇总
Write-Host ''
Write-Host '==== 汇总 ====' -ForegroundColor Cyan
foreach ($r in $results) {
    $line = '  ' + $r.Remote.PadRight(10) + $r.Pushed.PadRight(10) + $r.Verified.PadRight(10) + $r.Url
    if ($r.Verified -eq 'MATCH') { Write-Host $line -ForegroundColor Green }
    elseif ($r.Pushed -eq 'FAILED' -or $r.Verified -eq 'MISMATCH') { Write-Host $line -ForegroundColor Red }
    else { Write-Host $line }
}

if ($DryRun) {
    Write-Host ''
    Write-Host '  （DryRun：没有任何东西被推送）' -ForegroundColor Yellow
    exit 0
}

if ($anyFail) {
    Write-Host ''
    Write-Host '✗ 有远端没同步成功 —— 改动仍在本地，没丢。' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host '✓ 所有远端都已同步并校验通过。' -ForegroundColor Green
exit 0
