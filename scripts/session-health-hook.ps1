param(
    [string]$ProjectRoot,
    [int]$ContextWindowSize = 200000
)

$ErrorActionPreference = 'Stop'

# Korean warning text must survive the hook boundary: Windows PowerShell 5.1
# defaults stdout to the ANSI/OEM code page, while Claude Code decodes hook
# stdout as UTF-8.  Pin UTF-8 (no BOM) so the warnings are not mangled.
try {
    $utf8Out = New-Object System.Text.UTF8Encoding($false)
    [Console]::OutputEncoding = $utf8Out
    $OutputEncoding = $utf8Out
} catch { }

# A1: warn every TurnWarnStep assistant turns (100, 200, 300, ...).  TurnWarnReissueHours
# re-fires the highest crossed threshold this many hours after its last issuance so a
# long /resume'd or abandoned session is re-nudged (challenge finding 5).
$TurnWarnStep = 100
$TurnWarnReissueHours = 6
# Turn dedup keeps only the first 12 chars of each message.id (per session), and only
# the 10 most-recently-used sessions, to bound the state file (A1 state schema).
$TurnIdPrefixLength = 12
$TurnMaxSessions = 10
# Cap a *fresh* scan of a huge transcript to the trailing 8MB (challenge finding 2):
# the turn count is then a lower bound (undercount allowed) but the hook never times out.
$TurnScanByteCap = 8MB

function Exit-Silent { exit 0 }

function Get-TurnWarningMessage {
    param([int]$TurnThreshold)
    $strongPrefix = if ($TurnThreshold -ge 300) { '[강한 경고] ' } else { '' }
    return "${strongPrefix}이 세션은 ${TurnThreshold}턴을 넘었다. 긴 세션은 매 턴 누적 컨텍스트를 다시 읽어 사용량이 커진다. 진행 중인 단계가 끝나는 지점에서 session-carryover 스킬로 인계 파일을 쓰고 새 세션 시작을 안내하라. remember 플러그인·auto-memory로 대체하지 않는다."
}

function Get-HookTargetIdentifier {
    param([string]$Command)
    if ([string]::IsNullOrWhiteSpace($Command)) { return 'unknown' }

    if ($Command -match '(?i)-File\s+("([^"]+)"|''([^'']+)''|(\S+))') {
        $rawPath = if ($matches[2]) { $matches[2] } elseif ($matches[3]) { $matches[3] } else { $matches[4] }
        try {
            $leaf = Split-Path -Path $rawPath -Leaf
            if (-not [string]::IsNullOrWhiteSpace($leaf)) { return $leaf }
        } catch { }
    }

    if ($Command.Length -gt 80) {
        return $Command.Substring(0, 80)
    }
    return $Command
}

# A hook failure must never reject a prompt.  This also covers state-directory
# creation and atomic-state replacement failures below, outside the parsing
# try/catch blocks.
trap { Exit-Silent }

try {
    $stdinText = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($stdinText)) { Exit-Silent }
    $hookPayload = $stdinText | ConvertFrom-Json
} catch { Exit-Silent }

$transcriptPath = $null
$sessionId = $null
if ($hookPayload.transcript_path) { $transcriptPath = [string]$hookPayload.transcript_path }
if ($hookPayload.session_id) { $sessionId = [string]$hookPayload.session_id }
if ([string]::IsNullOrWhiteSpace($transcriptPath) -or [string]::IsNullOrWhiteSpace($sessionId)) { Exit-Silent }
if (-not (Test-Path -LiteralPath $transcriptPath)) { Exit-Silent }

$isExplicitProjectRoot = -not [string]::IsNullOrWhiteSpace($ProjectRoot)

if (-not $isExplicitProjectRoot) {
    $searchDir = if ($hookPayload.cwd) { [string]$hookPayload.cwd } else { $null }
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

    if (-not $foundRoot) {
        Exit-Silent
    }
    $ProjectRoot = $foundRoot
}

$now = [datetime]::UtcNow
$logs = Join-Path $ProjectRoot '.agents\briefs\logs'
if (-not (Test-Path -LiteralPath $logs)) { New-Item -ItemType Directory -Path $logs -Force | Out-Null }
$statePath = Join-Path $logs '.session-health.json'

$state = $null
if (Test-Path -LiteralPath $statePath) {
    try { $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $state = $null }
}

$hookSessions = @{}
if ($state -and $state.hookSessions) {
    foreach ($prop in @($state.hookSessions.psobject.Properties)) {
        $hookSessions[$prop.Name] = $prop.Value
    }
}

$issued = @{}
if ($state -and $state.issuedWarnings) {
    foreach ($prop in @($state.issuedWarnings.psobject.Properties)) {
        $issued[$prop.Name] = [string]$prop.Value
    }
}

$transcriptScanOffsets = @{}
if ($state -and $state.transcriptScanOffsets) {
    foreach ($prop in @($state.transcriptScanOffsets.psobject.Properties)) {
        try { $transcriptScanOffsets[$prop.Name] = [long]$prop.Value } catch { }
    }
}

$reportedHookErrors = @{}
if ($state -and $state.reportedHookErrors) {
    foreach ($sessionProp in @($state.reportedHookErrors.psobject.Properties)) {
        $sessErrors = @{}
        if ($sessionProp.Value) {
            foreach ($errProp in @($sessionProp.Value.psobject.Properties)) {
                $sessErrors[$errProp.Name] = [string]$errProp.Value
            }
        }
        $reportedHookErrors[$sessionProp.Name] = $sessErrors
    }
}

# A1 turn dedup state.  turnIds[sessionId] is the set of *first 12 chars* of the
# assistant message.id (uuid fallback) seen this session.  A per-session HashSet
# gives O(1) membership so a 10MB first scan stays fast; the parallel ArrayList is
# what gets serialized.  Context compaction (compact_boundary) re-records past
# assistant records late in the transcript, so dedup must span the whole session
# (challenge finding 1), not just compare against the previous id.
$turnIdLists = [ordered]@{}
$turnIdSets = @{}
if ($state -and $state.turnIds) {
    foreach ($sessionProp in @($state.turnIds.psobject.Properties)) {
        $list = New-Object System.Collections.ArrayList
        $set = New-Object 'System.Collections.Generic.HashSet[string]'
        if ($sessionProp.Value) {
            foreach ($idVal in @($sessionProp.Value)) {
                $idText = [string]$idVal
                if ([string]::IsNullOrEmpty($idText)) { continue }
                if ($set.Add($idText)) { [void]$list.Add($idText) }
            }
        }
        $turnIdLists[$sessionProp.Name] = $list
        $turnIdSets[$sessionProp.Name] = $set
    }
}
if (-not $turnIdLists.Contains($sessionId)) {
    $turnIdLists[$sessionId] = New-Object System.Collections.ArrayList
    $turnIdSets[$sessionId] = New-Object 'System.Collections.Generic.HashSet[string]'
}

# Project-scoped (not session-scoped) counter: how many distinct sessions have
# hit the context-70 threshold since the last tool/MCP review suggestion was
# emitted. Mirrors the orchestration-runbook §7 idiom — observe, then only
# propose after 5 cumulative occurrences, never auto-apply. (5, not §7's 2:
# context-70 crossings have many innocent causes — long sessions, large file
# reads — so this needs a higher bar than the concurrency-observation idiom
# it borrows the cadence pattern from.)
$toolReviewOccurrences = 0
if ($state -and $state.toolReviewOccurrences) {
    try { $toolReviewOccurrences = [int]$state.toolReviewOccurrences } catch { $toolReviewOccurrences = 0 }
}

$sessionKey = "hook-$sessionId"
$firstTimestamp = $null
if ($hookSessions.ContainsKey($sessionKey)) {
    [datetime]$parsed = [datetime]::MinValue
    if ([datetime]::TryParse([string]$hookSessions[$sessionKey], [ref]$parsed)) { $firstTimestamp = $parsed.ToUniversalTime() }
}

$lastContextTokens = $null

try {
    if (-not $firstTimestamp) {
        $reader = [System.IO.StreamReader]::new($transcriptPath, [System.Text.Encoding]::UTF8)
        try {
            while ($null -ne ($line = $reader.ReadLine())) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try {
                    $obj = $line | ConvertFrom-Json
                    if ($obj.type -eq 'user' -and $obj.timestamp) {
                        $firstTimestamp = [datetime]::Parse([string]$obj.timestamp).ToUniversalTime()
                        break
                    }
                } catch { continue }
            }
        } finally { $reader.Close() }
    }

    $tailLines = 200
    $tailContent = $null
    # Get-Content -Tail walks a 17MB transcript in ~8s (> the 5s hook timeout), which would kill the
    # whole hook including the turn warning exactly for the long sessions it targets.  Read only the
    # last 1MB by seeking, dropping the first (possibly partial) line when we did not start at 0.
    try {
        $tailFs = [System.IO.File]::Open($transcriptPath, 'Open', 'Read', 'ReadWrite')
        try {
            $tailStart = [math]::Max(0, $tailFs.Length - 1MB)
            [void]$tailFs.Seek($tailStart, 'Begin')
            $tailBytes = New-Object byte[] ($tailFs.Length - $tailStart)
            $tailRead = 0
            while ($tailRead -lt $tailBytes.Length) {
                $n = $tailFs.Read($tailBytes, $tailRead, $tailBytes.Length - $tailRead)
                if ($n -le 0) { break }
                $tailRead += $n
            }
        } finally { $tailFs.Close() }
        $tailLinesAll = [System.Text.Encoding]::UTF8.GetString($tailBytes, 0, $tailRead).TrimStart([char]0xFEFF) -split "`r?`n"
        if ($tailStart -gt 0 -and $tailLinesAll.Count -gt 0) { $tailLinesAll = $tailLinesAll[1..($tailLinesAll.Count - 1)] }
        $tailContent = @($tailLinesAll | Select-Object -Last $tailLines)
    } catch { }
    if ($tailContent) {
        for ($i = $tailContent.Count - 1; $i -ge 0; $i--) {
            $line = $tailContent[$i]
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $obj = $line | ConvertFrom-Json
                if ($obj.type -eq 'assistant' -and $obj.message -and $obj.message.usage) {
                    $u = $obj.message.usage
                    $inputT = 0; $cacheCreateT = 0; $cacheReadT = 0
                    if ($u.input_tokens) { $inputT = [int]$u.input_tokens }
                    if ($u.cache_creation_input_tokens) { $cacheCreateT = [int]$u.cache_creation_input_tokens }
                    if ($u.cache_read_input_tokens) { $cacheReadT = [int]$u.cache_read_input_tokens }
                    $lastContextTokens = $inputT + $cacheCreateT + $cacheReadT
                    break
                }
            } catch { continue }
        }
    }
} catch { Exit-Silent }

$warnings = New-Object System.Collections.ArrayList

# Done When 1: every warning must name the session-carryover skill (not the
# remember plugin / auto-memory).  Shared suffix keeps the wording consistent.
$carryoverGuidance = 'At the next stage boundary use the session-carryover skill to write a carry-over file and start a new session. Do not substitute the remember plugin or auto-memory.'

try {
    $fileInfo = Get-Item -LiteralPath $transcriptPath -ErrorAction SilentlyContinue
    if ($fileInfo) {
        $fileLen = [long]$fileInfo.Length
        $scanOffset = 0L
        if ($transcriptScanOffsets.ContainsKey($sessionId)) {
            try { $scanOffset = [long]$transcriptScanOffsets[$sessionId] } catch { $scanOffset = 0L }
        }

        if ($scanOffset -gt $fileLen -or $scanOffset -lt 0) {
            $scanOffset = 0L
        }

        # A1 performance (challenge finding 2): a fresh (or reset) scan of a huge
        # transcript is capped to the trailing 8MB, aligned to the next newline so
        # no partial JSON line is scanned.  The resulting turn count is a lower
        # bound (undercount acceptable); this keeps the 5s hook timeout safe.
        if ($scanOffset -eq 0L -and $fileLen -gt $TurnScanByteCap) {
            $capStart = [long]($fileLen - $TurnScanByteCap)
            $capStream = $null
            try {
                $capStream = [System.IO.File]::Open($transcriptPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                [void]$capStream.Seek($capStart, [System.IO.SeekOrigin]::Begin)
                while (($capByte = $capStream.ReadByte()) -ne -1 -and $capByte -ne 10) { }
                $capStart = $capStream.Position
            } catch { $capStart = [long]($fileLen - $TurnScanByteCap) } finally {
                if ($capStream) { $capStream.Close() }
            }
            $scanOffset = $capStart
        }

        $bytesToRead = [long]($fileLen - $scanOffset)
        if ($bytesToRead -gt 0) {
            $rawBytes = $null
            $fs = [System.IO.FileStream]::new($transcriptPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                if ($scanOffset -gt 0) { [void]$fs.Seek($scanOffset, [System.IO.SeekOrigin]::Begin) }
                $readLen = [math]::Min($bytesToRead, [int]::MaxValue)
                $buffer = New-Object byte[] $readLen
                # FileStream.Read is permitted to return a partial buffer.  Keep
                # reading the snapshot range so a just-appended complete JSONL
                # record is not deferred (or intermittently missed by the hook).
                $actualRead = 0
                while ($actualRead -lt $readLen) {
                    $readNow = $fs.Read($buffer, $actualRead, $readLen - $actualRead)
                    if ($readNow -le 0) { break }
                    $actualRead += $readNow
                }
                if ($actualRead -gt 0) {
                    if ($actualRead -lt $readLen) {
                        $trimmed = New-Object byte[] $actualRead
                        [Array]::Copy($buffer, $trimmed, $actualRead)
                        $rawBytes = $trimmed
                    } else {
                        $rawBytes = $buffer
                    }
                }
            } finally {
                $fs.Close()
            }

            if ($rawBytes -and $rawBytes.Length -gt 0) {
                $lastNewlineIdx = [Array]::LastIndexOf($rawBytes, [byte]10)
                if ($lastNewlineIdx -ge 0) {
                    $validBytesCount = $lastNewlineIdx + 1
                    $transcriptScanOffsets[$sessionId] = $scanOffset + $validBytesCount

                    $text = [System.Text.Encoding]::UTF8.GetString($rawBytes, 0, $validBytesCount)
                    $lines = $text -split "\r?\n"

                    if (-not $reportedHookErrors.ContainsKey($sessionId)) {
                        $reportedHookErrors[$sessionId] = @{}
                    }
                    $sessReported = $reportedHookErrors[$sessionId]

                    foreach ($line in $lines) {
                        if ([string]::IsNullOrWhiteSpace($line)) { continue }

                        # Turn counting (A1): count assistant records that carry
                        # message.usage and a claude* model, deduped by the set of
                        # message.id (uuid fallback) prefixes seen this session --
                        # the same "turn" definition as scripts/measure-session-usage.py.
                        # IndexOf discriminators + a single regex avoid a per-line
                        # ConvertFrom-Json so a 10MB first scan stays within the 5s
                        # hook timeout (challenge finding 2).
                        try {
                            if ($line.IndexOf('"type":"assistant"', [System.StringComparison]::Ordinal) -ge 0 -and
                                $line.IndexOf('"usage"', [System.StringComparison]::Ordinal) -ge 0 -and
                                $line.IndexOf('"model":"claude', [System.StringComparison]::Ordinal) -ge 0) {
                                $idMatch = [regex]::Match($line, '"id":"(msg_[^"]{1,})"')
                                if ($idMatch.Success) {
                                    $turnIdText = $idMatch.Groups[1].Value
                                } else {
                                    $uuidMatch = [regex]::Match($line, '"uuid":"([^"]{1,})"')
                                    $turnIdText = if ($uuidMatch.Success) { $uuidMatch.Groups[1].Value } else { $null }
                                }
                                if ($turnIdText) {
                                    $turnIdPrefix = if ($turnIdText.Length -gt $TurnIdPrefixLength) { $turnIdText.Substring(0, $TurnIdPrefixLength) } else { $turnIdText }
                                    if ($turnIdSets[$sessionId].Add($turnIdPrefix)) {
                                        [void]$turnIdLists[$sessionId].Add($turnIdPrefix)
                                    }
                                }
                            }
                        } catch { }

                        if ($line.IndexOf('hook_non_blocking_error', [System.StringComparison]::Ordinal) -ge 0) {
                            try {
                                $obj = $line | ConvertFrom-Json
                                $attachments = @()
                                if ($obj.attachment) { $attachments += $obj.attachment }
                                if ($obj.attachments) {
                                    foreach ($att in @($obj.attachments)) { $attachments += $att }
                                }
                                if ($obj.type -eq 'hook_non_blocking_error') {
                                    $attachments += $obj
                                }

                                foreach ($att in $attachments) {
                                    if ($att.type -eq 'hook_non_blocking_error') {
                                        $hName = [string]$att.hookName
                                        $hExit = [string]$att.exitCode
                                        $hCmd  = [string]$att.command

                                        $dedupKey = "$hName|$hCmd"
                                        if (-not $sessReported.ContainsKey($dedupKey)) {
                                            $sessReported[$dedupKey] = $now.ToString('o')
                                            $targetId = Get-HookTargetIdentifier -Command $hCmd
                                            $warnMsg = "Hook failure detected: $hName (exit $hExit, target: $targetId)"
                                            [void]$warnings.Add($warnMsg)
                                        }
                                    }
                                }
                            } catch {
                                continue
                            }
                        }
                    }
                }
            }
        }
    }
} catch { Exit-Silent }

# A1 turn warnings: fire once per crossed 100-turn threshold, per session.  The
# issuedWarnings key persists in state, so a restart/`resume` never re-fires an
# already-announced threshold.  300+ thresholds are escalated as strong warnings.
$currentTurnCount = 0
if ($turnIdLists.Contains($sessionId)) {
    try { $currentTurnCount = [int]$turnIdLists[$sessionId].Count } catch { $currentTurnCount = 0 }
}
# Failure here must not block the context/time/hook-error warnings (challenge
# finding 2: keep turn counting in its own try/catch).
try {
    if ($currentTurnCount -ge $TurnWarnStep) {
        $highestTurnThreshold = [int]([math]::Floor($currentTurnCount / $TurnWarnStep) * $TurnWarnStep)
        for ($turnThreshold = $TurnWarnStep; $turnThreshold -le $highestTurnThreshold; $turnThreshold += $TurnWarnStep) {
            $turnKey = "${sessionKey}-turns-${turnThreshold}"
            if (-not $issued.ContainsKey($turnKey)) {
                [void]$warnings.Add((Get-TurnWarningMessage $turnThreshold))
                $issued[$turnKey] = $now.ToString('o')
            }
        }
        # '/'resume' keeps the sessionId, so a resumed/abandoned session that is
        # still over the highest threshold is re-nudged once every TurnWarnReissueHours
        # (challenge finding 5).
        $highestTurnKey = "${sessionKey}-turns-${highestTurnThreshold}"
        if ($issued.ContainsKey($highestTurnKey)) {
            [datetime]$parsedTurnLast = [datetime]::MinValue
            if ([datetime]::TryParse([string]$issued[$highestTurnKey], [ref]$parsedTurnLast)) {
                if (($now - $parsedTurnLast.ToUniversalTime()).TotalHours -ge $TurnWarnReissueHours) {
                    [void]$warnings.Add((Get-TurnWarningMessage $highestTurnThreshold))
                    $issued[$highestTurnKey] = $now.ToString('o')
                }
            }
        }
    }
} catch { }

$elapsedHours = if ($firstTimestamp) { [math]::Max(0, ($now - $firstTimestamp).TotalHours) } else { $null }

if ($null -ne $elapsedHours) {
    foreach ($threshold in @(4, 6, 8)) {
        if ($elapsedHours -ge $threshold) {
            $key = "${sessionKey}-activity-$threshold"
            $lastIssued = $null
            if ($issued.ContainsKey($key)) {
                [datetime]$parsedLast = [datetime]::MinValue
                if ([datetime]::TryParse([string]$issued[$key], [ref]$parsedLast)) { $lastIssued = $parsedLast }
            }
            if ($null -eq $lastIssued -or ($now - $lastIssued.ToUniversalTime()).TotalMinutes -ge 60) {
                $message = "Session has been active for $([math]::Round($elapsedHours, 1))h (>=${threshold}h). $carryoverGuidance"
                [void]$warnings.Add($message)
                $issued[$key] = $now.ToString('o')
            }
        }
    }
}

$toolReviewSuggestion = $null

if ($null -ne $lastContextTokens -and $ContextWindowSize -gt 0) {
    $usedPercentage = [math]::Round(($lastContextTokens / $ContextWindowSize) * 100, 1)
    if ($usedPercentage -ge 70) {
        $key = "${sessionKey}-context-70"
        $isFirstThisSession = -not $issued.ContainsKey($key)
        $lastIssued = $null
        if ($issued.ContainsKey($key)) {
            [datetime]$parsedLast = [datetime]::MinValue
            if ([datetime]::TryParse([string]$issued[$key], [ref]$parsedLast)) { $lastIssued = $parsedLast }
        }
        if ($null -eq $lastIssued -or ($now - $lastIssued.ToUniversalTime()).TotalMinutes -ge 60) {
            [void]$warnings.Add("Context usage is at ${usedPercentage}% ($lastContextTokens / $ContextWindowSize tokens). Consider /compact. $carryoverGuidance")
            $issued[$key] = $now.ToString('o')
        }
        if ($isFirstThisSession) {
            $toolReviewOccurrences += 1
            if ($toolReviewOccurrences -ge 5) {
                $toolReviewSuggestion = @'
=== Tool/MCP Review Suggested ===
이 프로젝트에서 컨텍스트 사용률이 여러 세션에 걸쳐 반복적으로 70%를 넘었습니다.
다음 세션 유휴 시점에:
1. 이 프로젝트의 .claude/settings.local.json permissions.deny와 현재 로드된 MCP/내장 도구 목록을 대조한다.
2. deny되지 않은 도구 중 이 프로젝트의 실제 코드/문서/패킷에서 사용 근거가 없는 것을 grep으로 확인한다
   (판단 기준은 프로젝트 스택에 따라 다르다 -- 고정 목록을 적용하지 말 것).
3. 근거가 있으면 .agents/briefs/backlog.md의 "## 미해결 (관찰 중)" 표에 CFG-BL-NNN 행을 추가해 건의한다.
   settings.local.json은 직접 수정하지 않는다 -- 건의만 하고 사용자 승인 후 반영한다.
4. 건의 행에는 재활성화 방법(해당 도구를 permissions.deny 배열에서 제거)을 명시한다.
'@
                $toolReviewOccurrences = 0
            }
        }
    }
}

if ($firstTimestamp) {
    $hookSessions[$sessionKey] = $firstTimestamp.ToString('o')
}

$updatedHookSessions = [ordered]@{}
foreach ($k in $hookSessions.Keys) { $updatedHookSessions[$k] = $hookSessions[$k] }
$updatedIssued = [ordered]@{}
foreach ($k in $issued.Keys) { $updatedIssued[$k] = $issued[$k] }
$updatedScanOffsets = [ordered]@{}
foreach ($k in $transcriptScanOffsets.Keys) { $updatedScanOffsets[$k] = $transcriptScanOffsets[$k] }
$updatedReportedErrors = [ordered]@{}
foreach ($k in $reportedHookErrors.Keys) {
    $sub = [ordered]@{}
    $inner = $reportedHookErrors[$k]
    if ($inner) {
        foreach ($ik in $inner.Keys) { $sub[$ik] = $inner[$ik] }
    }
    $updatedReportedErrors[$k] = $sub
}
# Serialize turnIds with the current session last (most recently used) and keep
# only the TurnMaxSessions most-recent sessions (A1 state schema).
$updatedTurnIds = [ordered]@{}
foreach ($k in $turnIdLists.Keys) {
    if ($k -eq $sessionId) { continue }
    $updatedTurnIds[$k] = @($turnIdLists[$k])
}
if ($turnIdLists.Contains($sessionId)) {
    $updatedTurnIds[$sessionId] = @($turnIdLists[$sessionId])
}
while ($updatedTurnIds.Count -gt $TurnMaxSessions) {
    $oldestTurnSession = @($updatedTurnIds.Keys)[0]
    $updatedTurnIds.Remove($oldestTurnSession)
}

$stateObj = [ordered]@{
    schemaVersion = 6;
    hookSessions = $updatedHookSessions;
    issuedWarnings = $updatedIssued;
    toolReviewOccurrences = $toolReviewOccurrences;
    transcriptScanOffsets = $updatedScanOffsets;
    reportedHookErrors = $updatedReportedErrors;
    turnIds = $updatedTurnIds
}
$preservedKeys = @('schemaVersion', 'hookSessions', 'issuedWarnings', 'toolReviewOccurrences', 'transcriptScanOffsets', 'reportedHookErrors', 'turnIds')
if ($state) {
    foreach ($prop in @($state.psobject.Properties)) {
        if ($prop.Name -notin $preservedKeys) {
            if (-not $stateObj.Contains($prop.Name)) { $stateObj[$prop.Name] = $prop.Value }
        }
    }
}

$tempPath = "$statePath.$([guid]::NewGuid().ToString('N')).tmp"
[System.IO.File]::WriteAllText($tempPath, ($stateObj | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($true)))
Move-Item -LiteralPath $tempPath -Destination $statePath -Force

if ($warnings.Count -gt 0) {
    $output = "=== Session Health Warning ==="
    foreach ($w in $warnings) { $output += "`n$w" }
    # Context-only warnings were silently absorbed by the model; make it relay them.
    $output += "`nRelay these warnings to the user at the top of your reply. For a packetless session use the session-carryover skill to record a carry-over file and recommend starting a new session; do not substitute the remember plugin or auto-memory."
    Write-Output $output
}

if ($toolReviewSuggestion) {
    Write-Output $toolReviewSuggestion
}

exit 0
