<#
.SYNOPSIS
  把 Claude 桌面应用（Code 标签页）旧账号/组织下的侧栏会话索引复制到当前账号，恢复“换号后会话不见了”。

.DESCRIPTION
  侧栏只读 claude-code-sessions\<账号uuid>\<组织uuid>\local_*.json；对话正文在 ~/.claude/projects，与账号无关。
  本脚本只复制 local_*.json（同名跳过），不碰 deleted_*、scheduled-tasks.json 及其它文件。
  默认只预览；加 -Apply 才会写入，写入前自动整体备份。兼容 Windows PowerShell 5.1。

.PARAMETER Source
  源目录：账号 uuid 前缀、组织 uuid 前缀、“账号\组织”前缀或完整路径。默认：除目标外 local 最多的目录。
.PARAMETER Target
  目标目录，写法同 -Source。默认：local_*.json 最后修改时间最新的目录（即当前登录账号）。
.PARAMETER All
  把除目标外的所有目录都合并进目标。
.PARAMETER Apply
  实际执行（备份 + 复制 + 校验）。不加则只预览。
.PARAMETER BackupDir
  备份位置，默认 $HOME\claude-session-backups\claude-code-sessions_<时间>。
.PARAMETER Restore
  从备份还原：现有 claude-code-sessions 改名为 claude-code-sessions_replaced_<时间>，再把备份复制回去。
.PARAMETER Force
  跳过“桌面应用是否在运行”的检查（不推荐）。

.EXAMPLE
  .\migrate-sessions.ps1                         # 预览
  .\migrate-sessions.ps1 -Apply                  # 执行
  .\migrate-sessions.ps1 -Source 13afc54d -Apply # 指定源（示例 uuid 前缀）
  .\migrate-sessions.ps1 -All -Apply             # 合并所有旧账号
  .\migrate-sessions.ps1 -Restore "$HOME\claude-session-backups\claude-code-sessions_20261003_120000"
#>
[CmdletBinding()]
param(
    [string]$Source,
    [string]$Target,
    [switch]$All,
    [switch]$Apply,
    [string]$BackupDir,
    [string]$Restore,
    [switch]$Force,
    # 以下为测试用隐藏参数
    [Parameter(DontShow = $true)][string]$SessionsRoot,
    [Parameter(DontShow = $true)][string]$ProjectsDir
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
$Stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$Utf8 = New-Object Text.UTF8Encoding($false)

function Write-Step($msg) { Write-Host ""; Write-Host "== $msg" -ForegroundColor Cyan }
function Fail($msg) { Write-Host "错误：$msg" -ForegroundColor Red; exit 1 }

# ---------- 定位 sessions 根目录 ----------
function Find-SessionsRoot {
    if ($SessionsRoot) {
        if (-not (Test-Path -LiteralPath $SessionsRoot)) { Fail "-SessionsRoot 不存在：$SessionsRoot" }
        return (Resolve-Path -LiteralPath $SessionsRoot).Path
    }
    $cands = @()
    $pkgs = Join-Path $env:LOCALAPPDATA 'Packages'
    if (Test-Path -LiteralPath $pkgs) {
        Get-ChildItem -LiteralPath $pkgs -Directory -Filter 'Claude_*' -ErrorAction SilentlyContinue | ForEach-Object {
            $cands += (Join-Path $_.FullName 'LocalCache\Roaming\Claude\claude-code-sessions')
        }
    }
    if ($env:APPDATA) { $cands += (Join-Path $env:APPDATA 'Claude\claude-code-sessions') }
    $found = @($cands | Where-Object { Test-Path -LiteralPath $_ })
    if ($found.Count -eq 0) {
        Fail ("未找到 claude-code-sessions。已探测：`n  " + ($cands -join "`n  "))
    }
    if ($found.Count -gt 1) {
        Write-Host "发现多个 sessions 目录，使用第一个（商店版优先）：" -ForegroundColor Yellow
        $found | ForEach-Object { Write-Host "  $_" }
    }
    return $found[0]
}

# ---------- 桌面应用进程检测 ----------
function Get-DesktopClaudeProcs {
    $procs = @()
    try {
        $procs = @(Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction Stop |
            ForEach-Object { [pscustomobject]@{ Id = $_.ProcessId; Path = $_.ExecutablePath } })
    } catch {
        $procs = @(Get-Process -Name claude -ErrorAction SilentlyContinue |
            ForEach-Object { [pscustomobject]@{ Id = $_.Id; Path = $_.Path } })
    }
    # 只认桌面应用：商店版 WindowsApps\Claude_*，或安装版 AnthropicClaude；排除 VS Code 扩展与 CLI
    return @($procs | Where-Object {
        $_.Path -and
        ($_.Path -match '\\WindowsApps\\Claude_' -or $_.Path -match '\\AnthropicClaude\\') -and
        ($_.Path -notmatch '\\\.vscode[^\\]*\\extensions\\')
    })
}

function Assert-AppClosed {
    if ($Force) { Write-Host "已指定 -Force，跳过进程检查。" -ForegroundColor Yellow; return }
    $p = Get-DesktopClaudeProcs
    if ($p.Count -gt 0) {
        Write-Host "Claude 桌面应用仍在运行（应用运行时会覆盖写回 sessions 目录）：" -ForegroundColor Red
        $p | Sort-Object Id | ForEach-Object { Write-Host ("  PID {0}  {1}" -f $_.Id, $_.Path) }
        Fail "请从托盘图标彻底退出桌面应用（确认上面的进程全部消失）后重试。"
    }
}

# ---------- 读取 local_*.json 的必要字段（不用 ConvertFrom-Json） ----------
function Get-JsonField([string]$text, [string]$name) {
    $m = [regex]::Match($text, '"' + [regex]::Escape($name) + '"\s*:\s*"((?:[^"\\]|\\.)*)"')
    if ($m.Success) { try { return [regex]::Unescape($m.Groups[1].Value) } catch { return $m.Groups[1].Value } }
    return $null
}

function Read-SessionMeta([string]$file) {
    $t = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8)
    [pscustomobject]@{
        File         = $file
        Name         = [IO.Path]::GetFileName($file)
        CliSessionId = Get-JsonField $t 'cliSessionId'
        Title        = Get-JsonField $t 'title'
        Cwd          = Get-JsonField $t 'cwd'
    }
}

# ---------- 枚举 账号\组织 目录 ----------
function Get-OrgDirs([string]$root) {
    $list = @()
    foreach ($acct in Get-ChildItem -LiteralPath $root -Directory) {
        foreach ($org in Get-ChildItem -LiteralPath $acct.FullName -Directory) {
            $locals = @(Get-ChildItem -LiteralPath $org.FullName -File -Filter 'local_*.json')
            $last = if ($locals.Count) { ($locals | Measure-Object LastWriteTime -Maximum).Maximum } else { $org.LastWriteTime }
            $list += [pscustomobject]@{
                Key        = "$($acct.Name)\$($org.Name)"
                Account    = $acct.Name
                Org        = $org.Name
                Path       = $org.FullName
                LocalCount = $locals.Count
                LastWrite  = $last
            }
        }
    }
    return $list
}

function Resolve-OrgDir($dirs, [string]$spec, [string]$label) {
    $full = $null
    if (Test-Path -LiteralPath $spec) { $full = (Resolve-Path -LiteralPath $spec).Path.TrimEnd('\') }
    $m = @($dirs | Where-Object {
        ($full -and ($_.Path -eq $full -or $_.Path.StartsWith($full + '\'))) -or
        $_.Key.StartsWith($spec, [StringComparison]::OrdinalIgnoreCase) -or
        $_.Org.StartsWith($spec, [StringComparison]::OrdinalIgnoreCase)
    })
    if ($m.Count -eq 0) { Fail "$label '$spec' 没有匹配到任何 账号\组织 目录。" }
    if ($m.Count -gt 1) { Fail ("$label '$spec' 匹配到多个目录，请写得更具体：`n  " + (($m | ForEach-Object Key) -join "`n  ")) }
    return $m[0]
}

function Get-JsonlIndex {
    $dir = if ($ProjectsDir) { $ProjectsDir } else { Join-Path $HOME '.claude\projects' }
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    if (Test-Path -LiteralPath $dir) {
        foreach ($p in Get-ChildItem -LiteralPath $dir -Directory) {
            foreach ($f in Get-ChildItem -LiteralPath $p.FullName -File -Filter '*.jsonl') { [void]$set.Add($f.BaseName) }
        }
    } else { Write-Host "警告：未找到 $dir，无法校验对话正文。" -ForegroundColor Yellow }
    return , $set
}

function Count-Files([string]$p) { @(Get-ChildItem -LiteralPath $p -Recurse -File -Force).Count }

# ================= 主流程 =================
$root = Find-SessionsRoot
Write-Host "sessions 根目录：$root"

# ---------- 还原 ----------
if ($Restore) {
    Write-Step "从备份还原"
    if (-not (Test-Path -LiteralPath $Restore)) { Fail "备份不存在：$Restore" }
    $bak = (Resolve-Path -LiteralPath $Restore).Path
    if (@(Get-ChildItem -LiteralPath $bak -Directory).Count -eq 0) { Fail "备份目录里没有账号子目录，看起来不是 claude-code-sessions 的备份：$bak" }
    Assert-AppClosed
    $replaced = "${root}_replaced_$Stamp"
    Move-Item -LiteralPath $root -Destination $replaced
    Write-Host "当前目录已改名为：$replaced（未删除，确认无误后可移到 _待删除/）"
    Copy-Item -LiteralPath $bak -Destination $root -Recurse
    $a = Count-Files $bak; $b = Count-Files $root
    if ($a -ne $b) { Fail "还原后文件数不一致（备份 $a / 还原 $b），请手动检查。" }
    Write-Host "已还原 $b 个文件。重新打开桌面应用确认。" -ForegroundColor Green
    exit 0
}

# ---------- 列目录、选源与目标 ----------
$dirs = @(Get-OrgDirs $root)
if ($dirs.Count -lt 2) {
    $dirs | Format-Table Key, LocalCount, LastWrite -AutoSize | Out-String -Width 200 | Write-Host
    Fail "只找到 $($dirs.Count) 个 账号\组织 目录，没有可迁移的来源。请先用新账号打开一次桌面应用让它建目录。"
}

$tgt = if ($Target) { Resolve-OrgDir $dirs $Target '-Target' } else { $dirs | Sort-Object LastWrite -Descending | Select-Object -First 1 }
$others = @($dirs | Where-Object { $_.Path -ne $tgt.Path })
if ($All) {
    $srcs = @($others | Where-Object { $_.LocalCount -gt 0 })
} elseif ($Source) {
    $s = Resolve-OrgDir $dirs $Source '-Source'
    if ($s.Path -eq $tgt.Path) { Fail "源和目标是同一个目录。" }
    $srcs = @($s)
} else {
    $srcs = @($others | Where-Object { $_.LocalCount -gt 0 } | Sort-Object LocalCount -Descending | Select-Object -First 1)
}
if ($srcs.Count -eq 0) { Fail "除目标外没有含 local_*.json 的目录。" }

# ~/.claude.json 中的当前账号（仅作提示；正则读取，避免 ConvertFrom-Json 解析失败）
$cj = Join-Path $HOME '.claude.json'
$hintAcct = $null
if (-not $SessionsRoot -and (Test-Path -LiteralPath $cj)) {
    try {
        $m = [regex]::Match([IO.File]::ReadAllText($cj, [Text.Encoding]::UTF8), '"accountUuid"\s*:\s*"([0-9a-fA-F-]{36})"')
        if ($m.Success) { $hintAcct = $m.Groups[1].Value }
    } catch {}
}

Write-Step "账号\组织 目录"
$dirs | Sort-Object LastWrite -Descending | ForEach-Object {
    $mark = @()
    if ($_.Path -eq $tgt.Path) { $mark += '[目标]' }
    if ($srcs | Where-Object Path -eq $_.Path) { $mark += '[源]' }
    if ($hintAcct -and $_.Account -eq $hintAcct) { $mark += '(~/.claude.json 账号)' }
    [pscustomobject]@{ '标记' = ($mark -join ' '); '账号\组织' = $_.Key; 'local数' = $_.LocalCount; '最后修改' = $_.LastWrite.ToString('yyyy-MM-dd HH:mm') }
} | Format-Table -AutoSize | Out-String -Width 250 | ForEach-Object { Write-Host $_.Trim() }

# ---------- 计划 ----------
$existing = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
Get-ChildItem -LiteralPath $tgt.Path -File -Filter 'local_*.json' | ForEach-Object { [void]$existing.Add($_.Name) }
$toCopy = @(); $skip = 0
foreach ($s in $srcs) {
    foreach ($f in Get-ChildItem -LiteralPath $s.Path -File -Filter 'local_*.json') {
        if ($existing.Contains($f.Name)) { $skip++ } else { $toCopy += $f; [void]$existing.Add($f.Name) }
    }
}
Write-Step "迁移计划"
Write-Host ("目标：{0}" -f $tgt.Key)
Write-Host ("源  ：{0}" -f (($srcs | ForEach-Object Key) -join ', '))
Write-Host ("将复制 {0} 个，跳过（目标已有同名）{1} 个。只复制 local_*.json，不复制 deleted_*、scheduled-tasks.json 等。" -f $toCopy.Count, $skip)

if (-not $Apply) {
    if ($toCopy.Count -gt 0) {
        Write-Host "前 10 个待复制会话：" -ForegroundColor DarkGray
        $toCopy | Select-Object -First 10 | ForEach-Object {
            $mt = Read-SessionMeta $_.FullName
            Write-Host ("  {0}  {1}" -f $mt.Name, $mt.Title)
        }
    }
    Write-Host ""
    $p = Get-DesktopClaudeProcs
    if ($p.Count) { Write-Host ("提示：桌面应用正在运行（{0} 个进程），执行 -Apply 前需彻底退出。" -f $p.Count) -ForegroundColor Yellow }
    Write-Host "这是预览，未做任何修改。确认后加 -Apply 执行。" -ForegroundColor Green
    exit 0
}

# ---------- 执行 ----------
Assert-AppClosed

Write-Step "备份"
if (-not $BackupDir) { $BackupDir = Join-Path $HOME "claude-session-backups\claude-code-sessions_$Stamp" }
if (Test-Path -LiteralPath $BackupDir) { Fail "备份路径已存在：$BackupDir" }
$parent = Split-Path -Parent $BackupDir
if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
Copy-Item -LiteralPath $root -Destination $BackupDir -Recurse
$n1 = Count-Files $root; $n2 = Count-Files $BackupDir
if ($n1 -ne $n2) { Fail "备份文件数不一致（原 $n1 / 备份 $n2），已中止，未复制任何会话。" }
Write-Host "已备份 $n2 个文件到：$BackupDir" -ForegroundColor Green

Write-Step "复制"
$done = 0
foreach ($f in $toCopy) {
    $dest = Join-Path $tgt.Path $f.Name
    if (Test-Path -LiteralPath $dest) { continue }
    Copy-Item -LiteralPath $f.FullName -Destination $dest
    $done++
}
$after = @(Get-ChildItem -LiteralPath $tgt.Path -File -Filter 'local_*.json').Count
Write-Host "已复制 $done 个；目标目录现有 $after 个 local_*.json。" -ForegroundColor Green

Write-Step "校验对话正文（~/.claude/projects/*/<cliSessionId>.jsonl）"
$idx = Get-JsonlIndex
$missing = @()
$noId = 0
foreach ($f in Get-ChildItem -LiteralPath $tgt.Path -File -Filter 'local_*.json') {
    $mt = Read-SessionMeta $f.FullName
    if (-not $mt.CliSessionId) { $noId++; continue }
    if (-not $idx.Contains($mt.CliSessionId)) { $missing += $mt }
}
Write-Host ("共 {0} 条，缺正文 {1} 条，无 cliSessionId {2} 条。" -f $after, $missing.Count, $noId)
if ($missing.Count) {
    Write-Host "以下会话侧栏会显示但点开为空（正文可能已被 cleanupPeriodDays 清理）：" -ForegroundColor Yellow
    $missing | ForEach-Object { Write-Host ("  {0}  {1}" -f $_.CliSessionId, $_.Title) }
}

Write-Host ""
Write-Host "完成。现在打开桌面应用检查侧栏。若有问题，退出应用后运行：" -ForegroundColor Green
Write-Host "  .\migrate-sessions.ps1 -Restore `"$BackupDir`""
