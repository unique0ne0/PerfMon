param(
    [string]$ProjectRoot,
    [int]$MaxTotalBytes = 16384,
    # Start  = SessionStart: inject every unconsumed carry-over body (original behaviour).
    # Prompt = per-prompt hook (Claude/Codex UserPromptSubmit, Gemini BeforeAgent): stay
    #          silent unless another session added/changed/consumed a carry-over file since
    #          this session last looked, or the session resumes after IdleHours of no prompts.
    [ValidateSet('Start', 'Prompt')][string]$Event = 'Start',
    # text   = plain stdout (Claude, Codex).  gemini = hookSpecificOutput.additionalContext JSON,
    #          because Gemini CLI rejects plain-text stdout.
    # claude = SessionStart JSON carrying both the user-facing "처리 대기 목록" (systemMessage)
    #          and the existing carry-over body (hookSpecificOutput.additionalContext).
    [ValidateSet('text', 'gemini', 'claude')][string]$Format = 'text',
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

# ── 처리 대기 목록 (사용자 화면 systemMessage, CFG113) ────────────────────────
# carry-over 상태 태그(session-carryover SKILL.md).  태그는 미결 줄 끝의 대괄호
# 토큰이다: [다음순서], [사용자결정대기: …], [시간경과: …], [지금처리], [승인대기].
$script:CarryoverKnownTags = @('지금처리', '사용자결정대기', '승인대기', '시간경과', '다음순서')

# 버킷 출력 순서(우선순위 높음 → 낮음).
$script:CarryoverBucketOrder = @(
    '사용자결정대기', '다음순서',
    '시간경과·도래', '시간경과·미도래', '시간경과·날짜 미상',
    '기타', '태그 없음'
)

function Get-CarryoverItemId {
    param([string]$Line)
    $m = [regex]::Match($Line, 'CO-\d{4}-\d{4}-\d{2}')
    if ($m.Success) { return $m.Value }
    return $null
}

function Get-CarryoverTimeStatus {
    # [시간경과: 2026-10-14경] → 도래(오늘 포함)/미도래.  날짜가 없거나 잘못된
    # 날짜(예: 2026-02-31)면 날짜 미상.  예외가 훅 전체를 침묵시키지 않도록 try/catch.
    param([string]$Line)
    $m = [regex]::Match($Line, '\[시간경과[^\]]*?(\d{4})-(\d{2})-(\d{2})')
    if (-not $m.Success) { return '날짜 미상' }
    try {
        $date = [datetime]::new([int]$m.Groups[1].Value, [int]$m.Groups[2].Value, [int]$m.Groups[3].Value)
    } catch {
        return '날짜 미상'
    }
    if ($date -le (Get-Date).Date) { return '도래' }
    return '미도래'
}

function Get-CarryoverBucket {
    # 한 줄에 태그가 여럿이면 우선순위 사용자결정대기 > 다음순서 > 시간경과 >
    # 기타 태그 > 태그 없음으로 한 버킷에만 넣는다.
    param([string]$Line)
    $found = @()
    foreach ($m in [regex]::Matches($Line, '\[([^\]]*)\]')) {
        $name = ($m.Groups[1].Value -split '[:\(]', 2)[0].Trim()
        if (($script:CarryoverKnownTags -contains $name) -and ($found -notcontains $name)) { $found += $name }
    }
    if ($found -contains '사용자결정대기') { return '사용자결정대기' }
    if ($found -contains '다음순서') { return '다음순서' }
    if ($found -contains '시간경과') { return "시간경과·$(Get-CarryoverTimeStatus $Line)" }
    if ($found.Count -gt 0) { return '기타' }
    return '태그 없음'
}

function Get-CarryoverPendingMessage {
    # 미소비 인계 파일들에서 미체크 `- [ ]` 항목만 추려 사용자 화면용 한 줄
    # 목록(systemMessage)을 만든다.  항목이 0건이면 $null을 돌려 systemMessage
    # 키 자체를 만들지 않는다.  실패는 호출자가 삼킨다(세션 시작을 막지 않는다).
    param([System.IO.FileInfo[]]$Files, [int]$MaxBytes = 4096)

    $allFiles = @($Files)
    $resolvedIds = @{}
    $seenIds = @{}
    $items = New-Object System.Collections.ArrayList

    # 1차: 해결된 ID 수집(해결 기록 우선).  `- [x]`는 어디서든, `- CO-…` 줄은
    # `해결·폐기` 절 안에서만 해결로 본다.  코드 펜스 안은 제외한다.
    foreach ($file in $allFiles) {
        $lines = $null
        try { $lines = @(Get-Content -LiteralPath $file.FullName -Encoding UTF8) } catch { continue }
        $inFence = $false
        $inResolvedSection = $false
        foreach ($line in $lines) {
            if ($line -match '^\s*```') { $inFence = -not $inFence; continue }
            if ($inFence) { continue }
            if ($line -match '^\s*#{1,6}\s') {
                $inResolvedSection = ($line -match '^\s*#{1,6}\s*해결')
                continue
            }
            $id = Get-CarryoverItemId $line
            if (($line -match '^\s*- \[x\]') -or ($inResolvedSection -and $id)) {
                if ($id) { $resolvedIds[$id] = $true }
            }
        }
    }

    # 2차: 미체크 항목 수집.  최상위 `- [ ]` 줄만, 코드 펜스·인용문(`>`) 제외,
    # 해결된 ID·중복 ID는 1회만.
    foreach ($file in $allFiles) {
        $lines = $null
        try { $lines = @(Get-Content -LiteralPath $file.FullName -Encoding UTF8) } catch { continue }
        $inFence = $false
        foreach ($line in $lines) {
            if ($line -match '^\s*```') { $inFence = -not $inFence; continue }
            if ($inFence) { continue }
            if ($line -match '^\s*>') { continue }
            if ($line -notmatch '^- \[ \]') { continue }
            $id = Get-CarryoverItemId $line
            if ($id) {
                if ($resolvedIds.ContainsKey($id)) { continue }
                if ($seenIds.ContainsKey($id)) { continue }
                $seenIds[$id] = $true
            }
            [void]$items.Add($line)
        }
    }

    if ($items.Count -eq 0) { return $null }

    # 3차: 태그별 분류.
    $buckets = @{}
    foreach ($key in $script:CarryoverBucketOrder) { $buckets[$key] = New-Object System.Collections.ArrayList }
    foreach ($item in $items) {
        $bucket = Get-CarryoverBucket $item
        if (-not $buckets.ContainsKey($bucket)) { $buckets[$bucket] = New-Object System.Collections.ArrayList }
        [void]$buckets[$bucket].Add($item)
    }

    $allLines = New-Object System.Collections.ArrayList
    [void]$allLines.Add("== 처리 대기 목록: 인계 파일 $($allFiles.Count)개 · 미체크 $($items.Count)건 ==")
    foreach ($key in $script:CarryoverBucketOrder) {
        if ($buckets[$key].Count -eq 0) { continue }
        [void]$allLines.Add("[$key]")
        foreach ($l in $buckets[$key]) { [void]$allLines.Add($l) }
    }

    # 4차: 4096바이트 상한 — 줄 단위로만 자른다(UTF-8 코드포인트·줄 분할 금지).
    # `…외 N건` 접미 바이트를 예산에 포함한다.
    $totalItems = $items.Count
    $reserve = $utf8NoBom.GetByteCount("`r`n…외 ${totalItems}건")
    $kept = New-Object System.Collections.ArrayList
    $used = 0
    $fitsAll = $true
    foreach ($l in $allLines) {
        $add = $utf8NoBom.GetByteCount($l)
        if ($kept.Count -gt 0) { $add += 2 }
        if (($used + $add) -gt ($MaxBytes - $reserve)) { $fitsAll = $false; break }
        [void]$kept.Add($l)
        $used += $add
    }
    if ($fitsAll) { return ($kept -join "`r`n") }

    while ($kept.Count -gt 0 -and $kept[$kept.Count - 1] -match '^\[.*\]$') {
        [void]$kept.RemoveAt($kept.Count - 1)
    }
    $keptItems = @($kept | Where-Object { $_ -match '^- ' }).Count
    $omitted = $totalItems - $keptItems
    if ($omitted -lt 1) { return ($kept -join "`r`n") }
    $suffix = "`r`n…외 ${omitted}건"
    while ($kept.Count -gt 0 -and ($utf8NoBom.GetByteCount((($kept -join "`r`n") + $suffix)) -gt $MaxBytes)) {
        [void]$kept.RemoveAt($kept.Count - 1)
        while ($kept.Count -gt 0 -and $kept[$kept.Count - 1] -match '^\[.*\]$') { [void]$kept.RemoveAt($kept.Count - 1) }
        $keptItems = @($kept | Where-Object { $_ -match '^- ' }).Count
        $omitted = $totalItems - $keptItems
        $suffix = "`r`n…외 ${omitted}건"
    }
    return (($kept -join "`r`n") + $suffix)
}

function Write-HookOutput {
    param([string]$Text, [string]$PendingMessage)
    if ([string]::IsNullOrEmpty($Text) -and [string]::IsNullOrEmpty($PendingMessage)) { return }
    if ($Format -eq 'gemini') {
        $eventName = if ($Event -eq 'Start') { 'SessionStart' } else { 'BeforeAgent' }
        $payload = @{ hookSpecificOutput = @{ hookEventName = $eventName; additionalContext = $Text } }
        [Console]::Out.Write(($payload | ConvertTo-Json -Depth 4 -Compress))
    } elseif ($Format -eq 'claude') {
        # SessionStart 사용자 표시용 처리 대기 목록은 systemMessage로, 인계 전문은
        # hookSpecificOutput.additionalContext로 내보낸다.  대기 항목이 0건이면
        # systemMessage 키를 아예 두지 않는다(스키마 유지, 소음 방지).
        $eventName = if ($Event -eq 'Start') { 'SessionStart' } else { 'BeforeAgent' }
        $hookOutput = @{ hookEventName = $eventName; additionalContext = $Text }
        if ([string]::IsNullOrEmpty($PendingMessage)) {
            $payload = @{ hookSpecificOutput = $hookOutput }
        } else {
            $payload = @{ systemMessage = $PendingMessage; hookSpecificOutput = $hookOutput }
        }
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

# A repository could commit a symlink/junction at .agents\briefs\logs (gitignore
# does not stop a committed link) and redirect these writes outside the project.
# Refuse to write through any reparse point.
function Assert-NotReparsePoint {
    param([string]$Path)
    if ((Test-Path -LiteralPath $Path) -and ((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "reparse point refused: $Path"
    }
}

function Save-SessionState {
    param([string]$Path, [hashtable]$Seen, [datetime]$NowUtc)
    if (-not $Path) { return }
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Assert-NotReparsePoint $dir
    Assert-NotReparsePoint $Path
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
    Assert-NotReparsePoint $path
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
        Assert-NotReparsePoint $logsDir
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

    # -Format claude only: the user-facing pending list is built on its own
    # 4096-byte budget, then both strings are serialised once at the very end.
    # List-generation failure degrades to context injection only.
    $pendingMessage = $null
    if ($Format -eq 'claude') {
        try { $pendingMessage = Get-CarryoverPendingMessage -Files $sorted } catch { $pendingMessage = $null }
    }
    Write-HookOutput -Text $output -PendingMessage $pendingMessage
} catch {
    Exit-Silent
}

exit 0
