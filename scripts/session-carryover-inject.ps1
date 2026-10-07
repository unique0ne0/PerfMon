param(
    [string]$ProjectRoot,
    [int]$MaxTotalBytes = 16384
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
    # -File excludes it; the hook never moves, edits, or deletes any file.
    $files = @(Get-ChildItem -LiteralPath $briefsDir -Filter 'session-carryover-*.md' -File -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) { Exit-Silent }

    $sorted = @($files | Sort-Object -Property @{ Expression = { Get-CarryoverSortTime $_ }; Ascending = $true })

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('=== Session Carry-over ===')
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
    [Console]::Out.Write($output)
} catch {
    Exit-Silent
}

exit 0
