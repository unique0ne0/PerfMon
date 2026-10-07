param(
    [string]$ProjectRoot,
    [int]$MaxTotalBytes = 16384,
    # Start  = SessionStart: inject every unconsumed carry-over body (original behaviour).
    # Prompt = per-prompt hook (Claude/Codex UserPromptSubmit, Gemini BeforeAgent): stay
    #          silent unless another session added/changed/consumed a carry-over file since
    #          this session last looked, or the session resumes after IdleHours of no prompts.
    [ValidateSet('Start', 'Prompt')][string]$Event = 'Start',
    # text = plain stdout (Claude, Codex).  gemini = hookSpecificOutput.additionalContext JSON,
    # because Gemini CLI rejects plain-text stdout.
    [ValidateSet('text', 'gemini')][string]$Format = 'text',
    [double]$IdleHours = 2
)

$ErrorActionPreference = 'Stop'

# The SessionStart boundary must never be blocked by this hook (Done When 3).
function Exit-Silent { exit 0 }
trap { Exit-Silent }

# Korean carry-over text must survive the hook boundary: Windows PowerShell 5.1
# defaults stdout to the ANSI/OEM code page, while Claude Code decodes hook
# stdout as UTF-8.  Pin UTF-8 (no BOM) so the injected body is not mangled.
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
try {
    [Console]::OutputEncoding = $utf8NoBom
    $OutputEncoding = $utf8NoBom
} catch { }

function Get-CarryoverSortTime {
    # Primary key: the filename timestamp (session-carryover-YYYYMMDD-HHMM.md).
    # Files whose name does not parse fall back to LastWriteTime so ordering is
    # still deterministic (challenge review: filename first, LastWriteTime fallback).
    param([System.IO.FileInfo]$File)
    if ($File.BaseName -match '^session-carryover-(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})$') {
        try {
            return [datetime]::new([int]$matches[1], [int]$matches[2], [int]$matches[3], [int]$matches[4], [int]$matches[5], 0, [System.DateTimeKind]::Local)
        } catch { }
    }
    return $File.LastWriteTime
}

function Get-FileStamp {
    param([System.IO.FileInfo]$File)
    return "$($File.LastWriteTimeUtc.Ticks):$($File.Length)"
}

function Write-HookOutput {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return }
    if ($Format -eq 'gemini') {
        $eventName = if ($Event -eq 'Start') { 'SessionStart' } else { 'BeforeAgent' }
        $payload = @{ hookSpecificOutput = @{ hookEventName = $eventName; additionalContext = $Text } }
        [Console]::Out.Write(($payload | ConvertTo-Json -Depth 4 -Compress))
    } else {
        [Console]::Out.Write($Text)
    }
}

# Per-session view of the carry-over files, kept under the gitignored
# .agents\briefs\logs (same place as session-health-hook state).  One file per
# session so concurrent sessions never rewrite each other's state.
function Get-SessionStatePath {
    param([string]$LogsDir, [string]$SessionId)
    $safeId = ($SessionId -replace '[^A-Za-z0-9_-]', '_')
    if ([string]::IsNullOrWhiteSpace($safeId)) { return $null }
    return Join-Path (Join-Path $LogsDir 'carryover-sessions') "$safeId.json"
}

function Save-SessionState {
    param([string]$Path, [hashtable]$Seen, [datetime]$NowUtc)
    if (-not $Path) { return }
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $body = @{ lastSeenUtc = $NowUtc.ToString('o'); seen = $Seen } | ConvertTo-Json -Depth 4
    $tmp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    [System.IO.File]::WriteAllText($tmp, $body, $utf8NoBom)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

# Activity days (session-carryover retention): one local date per line, any
# tool, any session.  Days with no prompt in this project are never recorded,
# so idle periods do not count toward the 7-activity-day retention.
function Add-ActivityDay {
    param([string]$LogsDir)
    $path = Join-Path $LogsDir 'carryover-activity.log'
    $today = (Get-Date).ToString('yyyy-MM-dd')
    if (Test-Path -LiteralPath $path) {
        $known = @([System.IO.File]::ReadAllLines($path))
        if ($known -contains $today) { return }
    }
    [System.IO.File]::AppendAllText($path, "$today`r`n", $utf8NoBom)
}

try {
    $stdinText = [Console]::In.ReadToEnd()
    $hookPayload = $null
    if (-not [string]::IsNullOrWhiteSpace($stdinText)) {
        try { $hookPayload = $stdinText | ConvertFrom-Json } catch { $hookPayload = $null }
    }

    $isExplicitProjectRoot = -not [string]::IsNullOrWhiteSpace($ProjectRoot)
    if (-not $isExplicitProjectRoot) {
        # Same upward .agents\briefs search as session-health-hook.ps1 (CFG095),
        # so a session started in a subdirectory still finds the project root.
        $searchDir = $null
        if ($hookPayload -and $hookPayload.cwd) { $searchDir = [string]$hookPayload.cwd }
        if ([string]::IsNullOrWhiteSpace($searchDir)) { Exit-Silent }

        $foundRoot = $null
        $curr = $searchDir
        while (-not [string]::IsNullOrWhiteSpace($curr)) {
            $candidate = Join-Path $curr '.agents\briefs'
            if (Test-Path -LiteralPath $candidate) {
                $foundRoot = $curr
                break
            }
            $parent = Split-Path -Path $curr -Parent
            if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $curr) {
                break
            }
            $curr = $parent
        }
        if (-not $foundRoot) { Exit-Silent }
        $ProjectRoot = $foundRoot
    }

    $briefsDir = Join-Path $ProjectRoot '.agents\briefs'
    if (-not (Test-Path -LiteralPath $briefsDir)) { Exit-Silent }

    # Unconsumed carry-over files only.  The consumed/ folder is a directory, so
    # -File excludes it; the hook never moves, edits, or deletes carry-over files.
    $files = @(Get-ChildItem -LiteralPath $briefsDir -Filter 'session-carryover-*.md' -File -ErrorAction SilentlyContinue)

    $nowUtc = [datetime]::UtcNow
    $currentSeen = @{}
    foreach ($f in $files) { $currentSeen[$f.Name] = Get-FileStamp $f }

    # Session bookkeeping is best-effort: a failure here must never block the
    # injection itself, so it is isolated from the outer catch.
    $statePath = $null
    $prevState = $null
    try {
        $logsDir = Join-Path $briefsDir 'logs'
        if (-not (Test-Path -LiteralPath $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }
        Add-ActivityDay $logsDir
        if ($hookPayload -and $hookPayload.session_id) {
            $statePath = Get-SessionStatePath $logsDir ([string]$hookPayload.session_id)
            if ($statePath -and (Test-Path -LiteralPath $statePath)) {
                $prevState = [System.IO.File]::ReadAllText($statePath, $utf8NoBom) | ConvertFrom-Json
            }
        }
    } catch { $statePath = $null; $prevState = $null }

    $idleLine = $null
    if ($prevState -and $prevState.lastSeenUtc) {
        try {
            $last = [datetime]::Parse([string]$prevState.lastSeenUtc, $null, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
            $idleHoursObserved = ($nowUtc - $last).TotalHours
            if ($idleHoursObserved -ge $IdleHours) {
                $idleLine = "이 세션은 $([math]::Round($idleHoursObserved, 1))시간 idle 후 재개되었다. 그 사이 다른 세션이 저장소·라우터·락을 바꿨을 수 있으므로 판단 전에 git log·락·라우터를 다시 조회한다."
            }
        } catch { }
    }

    if ($Event -eq 'Prompt') {
        if (-not $statePath) { Exit-Silent }
        try { Save-SessionState $statePath $currentSeen $nowUtc } catch { }
        # First prompt of a session that predates this hook: baseline silently.
        if (-not $prevState) { Exit-Silent }

        $prevSeen = @{}
        if ($prevState.seen) { foreach ($p in @($prevState.seen.psobject.Properties)) { $prevSeen[$p.Name] = [string]$p.Value } }
        $changed = @($files | Where-Object { $prevSeen[$_.Name] -ne $currentSeen[$_.Name] } | Sort-Object -Property @{ Expression = { Get-CarryoverSortTime $_ } })
        $removed = @($prevSeen.Keys | Where-Object { -not $currentSeen.ContainsKey($_) } | Sort-Object)
        if ($changed.Count -eq 0 -and $removed.Count -eq 0 -and -not $idleLine) { Exit-Silent }

        # Paths only, not bodies: the session's own freshly written carry-over
        # shows up here too, and re-injecting it every time would waste context.
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine('=== Session Carry-over 갱신 ===')
        if ($idleLine) { [void]$sb.AppendLine($idleLine) }
        if ($changed.Count -gt 0 -or $removed.Count -gt 0) {
            [void]$sb.AppendLine('이 세션이 마지막으로 확인한 뒤 인계 파일이 바뀌었다(동시 세션). 이 세션이 직접 쓰거나 옮긴 것이 아니면 Read로 읽고, 결정·금지사항·미결이 지금 판단과 충돌하는지 확인한 뒤 진행한다. 해결 기록은 미결보다 우선한다(session-carryover 스킬).')
            foreach ($f in $changed) { [void]$sb.AppendLine("- 추가·수정: $($f.FullName) ($($f.LastWriteTime.ToString('yyyy-MM-dd HH:mm')))") }
            foreach ($n in $removed) { [void]$sb.AppendLine("- 소비됨(병합 완료): $n") }
        } else {
            [void]$sb.AppendLine('인계 파일 변동은 없다.')
        }
        [void]$sb.AppendLine('=== End Session Carry-over 갱신 ===')
        Write-HookOutput $sb.ToString()
        exit 0
    }

    if ($statePath) { try { Save-SessionState $statePath $currentSeen $nowUtc } catch { } }
    if ($files.Count -eq 0) {
        if ($idleLine) { Write-HookOutput "=== Session Carry-over ===`r`n$idleLine`r`n=== End Session Carry-over ===`r`n" }
        Exit-Silent
    }

    $sorted = @($files | Sort-Object -Property @{ Expression = { Get-CarryoverSortTime $_ }; Ascending = $true })

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('=== Session Carry-over ===')
    if ($idleLine) { [void]$sb.AppendLine($idleLine) }
    [void]$sb.AppendLine('아래는 이 프로젝트의 미소비 인계 파일이다. 미해결 항목을 한 줄씩 확인하고, 사용자 재확인 없이 결정을 번복하지 않는다. 시작 시에는 파일을 옮기지 않는다. 세션 종료 시 그 시점의 미소비 파일 전부를 항목 ID 기준으로 병합(해결 기록 우선, 원문 승계)해 새 인계 파일을 쓴 뒤 병합한 원본만 .agents/briefs/session-carryover-consumed/ 로 옮긴다(session-carryover 스킬). remember 플러그인·auto-memory로 대체하지 않는다.')
    [void]$sb.AppendLine('')

    # Keep a bounded reserve for the truncation notice, omitted-file paths, and
    # closing wrapper.  The final whole-payload guard below remains necessary
    # when an unusual number of paths exceeds this reserve.
    $trailerReserveBytes = 1024
    $budget = $MaxTotalBytes - $utf8NoBom.GetByteCount($sb.ToString()) - $trailerReserveBytes
    $skippedNames = @()
    $budgetExhausted = $false

    foreach ($file in $sorted) {
        if ($budgetExhausted) { $skippedNames += $file.Name; continue }

        $fileHeader = "--- $($file.Name) ---"
        $headerBytes = $utf8NoBom.GetByteCount($fileHeader) + 2
        if ($headerBytes -gt $budget) {
            $budgetExhausted = $true
            $skippedNames += $file.Name
            continue
        }

        $bodyLines = $null
        try {
            $bodyLines = @(Get-Content -LiteralPath $file.FullName -Encoding UTF8)
        } catch {
            # A per-file read failure must not abort the whole injection.
            $skippedNames += $file.Name
            continue
        }

        [void]$sb.AppendLine($fileHeader)
        $budget -= $headerBytes

        $truncated = $false
        foreach ($bodyLine in $bodyLines) {
            $lineBytes = $utf8NoBom.GetByteCount($bodyLine) + 2
            if ($lineBytes -gt $budget) { $truncated = $true; break }
            [void]$sb.AppendLine($bodyLine)
            $budget -= $lineBytes
        }
        [void]$sb.AppendLine('')
        $budget -= 2

        if ($truncated) {
            # Line-based truncation (never mid-line, so UTF-8 code points and code
            # fences stay intact).  Remaining files are listed by path only.
            [void]$sb.AppendLine("[... 본문이 용량 한도로 잘렸다. 나머지는 이 파일에서 확인: $($file.FullName)]")
            $budgetExhausted = $true
        }
    }

    if ($skippedNames.Count -gt 0) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('--- 용량 초과로 본문을 생략한 인계 파일 (직접 확인) ---')
        foreach ($skippedName in $skippedNames) {
            [void]$sb.AppendLine("- $(Join-Path $briefsDir $skippedName)")
        }
    }

    [void]$sb.AppendLine('=== End Session Carry-over ===')

    # The body budget above deliberately leaves room for the truncation notice,
    # omitted-file list, and closing wrapper.  Those variable-length additions
    # can nevertheless push the final payload over MaxTotalBytes.  Enforce the
    # cap on the complete UTF-8 payload too, retaining whole lines only so a
    # multibyte character or a Markdown line is never split at the boundary.
    $output = $sb.ToString()
    if ($utf8NoBom.GetByteCount($output) -gt $MaxTotalBytes) {
        $bounded = New-Object System.Text.StringBuilder
        foreach ($outputLine in ($output -split "`r?`n")) {
            $candidate = $bounded.ToString() + $outputLine + [Environment]::NewLine
            if ($utf8NoBom.GetByteCount($candidate) -gt $MaxTotalBytes) { break }
            [void]$bounded.AppendLine($outputLine)
        }
        $output = $bounded.ToString()
    }
    Write-HookOutput $output
} catch {
    Exit-Silent
}

exit 0
