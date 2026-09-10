# Harness verdict module — QA verdict validation, pipeline stage tracking, and synthetic verdict generation.
# Depends on: harness-io.ps1 (Write-AtomicJson, Write-AtomicRMW)
# Caller must provide: $LogDir, $TaskId, $TaskLogPrefix
# Also depends on main dispatcher functions: Resolve-RepoPath, Write-Log

function Write-SyntheticQaVerdict {
    param([string]$Stage, [object]$Result, [int]$CycleNumber)
    if ($Stage -ne 'qa') { return }
    $verdictRel = $StageConfig['qa'].VerdictFile
    $verdictAbs = Resolve-RepoPath $verdictRel
    if (Test-Path -LiteralPath $verdictAbs) { return }
    # CFG066 Done When 2: fail-open → fail-closed. verify 종료 코드만으로 pass를 합성하지 않는다.
    # QA 모델이 실제로 검토하지 않아도 pass가 만들어지는 결함을 차단한다.
    # CFG037/CFG038의 합성 원장·QA 무판단 집계 계약은 보존한다(synthetic/syntheticReason/findingsUnmeasured 필드 유지).
    $verdictValue = 'blocked'
    $reasonText = 'QA stage completed but no verdict file was written by the model'
    if ($Result.Success) {
        $reasonText = 'QA stage succeeded (verify passed) but model did not write verdict file — synthetic blocked recorded by harness (fail-closed: no actual QA judgment)'
    } elseif ($Result.FailureReason) {
        $reasonText = [string]$Result.FailureReason
    }
    $value = [ordered]@{
        schemaVersion = 2
        taskId = $TaskId
        stage = 'qa'
        cycle = $CycleNumber
        verdict = $verdictValue
        reason = $reasonText
        doneWhen = @()
        findings = @()
        # CFG038: 합성 pass는 findings:[] 로 "무결함"으로 오독될 수 있으므로, 집계기가
        # "결함 없음"과 "모델이 기록하지 않음"을 구분하도록 측정 불가 플래그를 남긴다.
        findingsUnmeasured = $true
        synthetic = $true
        syntheticReason = 'model did not write qa-verdict.json; harness recorded outcome'
        observedAt = [datetime]::UtcNow.ToString('o')
    }
    Write-AtomicJson -Path $verdictAbs -Value $value -Depth 6
    Write-Log "⚠️ [qa] 합성 qa-verdict 기록: verdict=$verdictValue ($reasonText)" WARN
}

# CFG037: 모든 QA 라운드에서 qa-ledger.json이 작성되도록 한다.
# 기존 Record-StageAttempt는 실패만 기록하므로, 성공 라운드에서는 ledger가 작성되지 않았다
# (실측: 589개 로그 중 qa-ledger.json 2개뿐). 이 함수가 성공·실패 모두에서 ledger를 보장한다.

function Ensure-QaLedger {
    param([string]$Stage, [object]$Result)
    if ($Stage -ne 'qa') { return }
    $ledger = Read-StageLedger -Stage 'qa'
    $hasEntries = @($ledger.attempts.psobject.Properties).Count -gt 0
    if (-not $hasEntries) {
        $outcome = if ($Result.Success) { 'ok' } else { 'qa_failed' }
        $sig = "success:qa:$outcome"
        $rec = Record-StageAttempt -Stage 'qa' -Signature $sig -FailureClass 'transient'
    }
}

# CFG027: 구조적 원인 수정을 확인한 뒤 원장을 감사 가능하게 초기화하는 유일한 공식 경로.
# 이전에는 CFG025 QA 원장을 Write 툴로 직접 덮어쓰는 수동 워크어라운드가 두 번 반복됐다 —
# 사유 없는 초기화를 막기 위해 -ResetReason을 필수로 요구하고 초기화 이력을 별도 로그에 남긴다.

function Set-CompletedStageApprovalsSuperseded {
    param([object]$PipelineStatus, [string]$Evidence)
    if ($null -eq $PipelineStatus -or -not $PipelineStatus.HasPipelineStatus) { return @() }
    $logDirAbs = Resolve-RepoPath $LogDir
    if (-not (Test-Path -LiteralPath $logDirAbs)) { return @() }
    $updated = @()
    foreach ($recordFile in @(Get-ChildItem -LiteralPath $logDirAbs -Filter "$TaskId-*-cycle*-approval.json" -File -ErrorAction SilentlyContinue)) {
        try {
            $record = Get-Content -LiteralPath $recordFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($record.status -ne 'pending') { continue }
            $indexes = Get-StagePipelineIndexes -Stage ([string]$record.stage)
            if ($indexes.Count -eq 0) { continue }
            $stageItems = @($PipelineStatus.Items | Where-Object { $indexes -contains $_.Index })
            if ($stageItems.Count -eq 0 -or @($stageItems | Where-Object { -not $_.Checked }).Count -gt 0) { continue }
            # QA completion has an independent durable gate. A mistakenly checked packet alone
            # must never suppress a genuine approval request.
            if ($record.stage -eq 'qa' -and -not (Test-QaVerdict -QaDispatchedAt $null)) { continue }
            $record.status = 'superseded'
            $record | Add-Member -NotePropertyName supersededAt -NotePropertyValue ([datetime]::UtcNow.ToString('o')) -Force
            $record | Add-Member -NotePropertyName supersededReason -NotePropertyValue 'packet stage completed; durable pipeline state outranks the pending runtime artifact' -Force
            $record | Add-Member -NotePropertyName supersededByEvidence -NotePropertyValue $Evidence -Force
            Write-AtomicJson -Path $recordFile.FullName -Value $record -Depth 8
            $updated += $recordFile.FullName
            Write-Log "✅ [$TaskId/$($record.stage)] 완료된 패킷 단계의 pending 승인 기록을 superseded 처리: $($recordFile.Name)" SUCCESS
        } catch {
            Write-Log "승인 기록 supersede 실패($($recordFile.FullName)): $($_.Exception.Message)" WARN
        }
    }
    return $updated
}


function Test-RequestedPipelineStage {
    param([string]$Stage, [string]$PacketPath)
    $status = Get-PacketPipelineStatus -PacketPath $PacketPath
    if (-not $status.HasPipelineStatus -or $status.Items.Count -eq 0) { return }
    $expected = Get-StagePipelineIndexes -Stage $Stage
    if ($null -eq $status.FirstUnchecked) {
        Write-Log "⚠️ [$Stage] 패킷 상태 경고 — 이미 완료된 단계를 재실행합니다" WARN
        return
    }
    if ($expected -contains $status.FirstUnchecked.Index) { return }
    $requested = @($status.Items | Where-Object { $expected -contains $_.Index } | Select-Object -First 1)
    if ($requested.Count -gt 0 -and $requested[0].Checked) {
        Write-Log "⚠️ [$Stage] 패킷 상태 경고 — 이미 완료된 단계를 재실행합니다: $($requested[0].Label)" WARN
    } else {
        Write-Log "⚠️ [$Stage] 패킷 상태 경고 — 선행 단계 $($status.FirstUnchecked.Index) 미완료: $($status.FirstUnchecked.Label)" WARN
    }
}


function Test-PipelineStageUpdated {
    param([string]$Stage, [string]$PacketPath)
    $status = Get-PacketPipelineStatus -PacketPath $PacketPath
    if (-not $status.HasPipelineStatus -or $status.Items.Count -eq 0) { return }
    $expected = Get-StagePipelineIndexes -Stage $Stage
    $unchecked = @($status.Items | Where-Object { $expected -contains $_.Index -and -not $_.Checked })
    if ($unchecked.Count -eq 0) { return }
    $labels = ($unchecked | ForEach-Object { $_.Label }) -join '; '
    Write-Log "⚠️ [$Stage] 성공했지만 패킷 Pipeline Status가 갱신되지 않았습니다 — 하네스가 대신 체크합니다: $labels" WARN
    # CFG027: 구현 에이전트가 체크박스 갱신을 누락해도 파이프라인이 실구현 상태와 어긋나지 않도록,
    # 하네스가 이미 확보한 "단계 성공(verify.ps1 통과)" 근거로 대신 체크한다 — WARN만 남기고 방치하지 않는다.
    $indexes = @($unchecked | ForEach-Object { [int]$_.Index })
    $updated = Set-PacketCheckboxes -PacketPath $PacketPath -Indexes $indexes -Annotation "(자동 갱신 — 하네스가 $Stage 단계 성공 확인 후 대신 체크, 구현 에이전트 누락분)"
    # CFG038: ④(QA)를 하네스가 대신 체크했으면 'QA 판단 없음'을 verdict에 남긴다 — QA가 아무
    # 판단도 쓰지 않아도 pass와 구분되도록(실측 CFG028·CFG032·CFG035).
    if ($Stage -eq 'qa') { Set-QaVerdictStageHarnessFlag -CheckedIndexes $indexes }
    if ($updated) { Write-Log "✅ [$Stage] Pipeline Status 자동 갱신 완료" SUCCESS }
}

# CFG038: 하네스가 ④(QA) 체크박스를 대신 체크한 경우, verdict에 stageCheckedByHarness=true 를 남긴다.
# verdict가 있으면 그 안에, 없으면 별도 상태 파일(.agents/briefs/logs/$TaskId-qa-stage-checked.json)에 기록한다.

function Set-QaVerdictStageHarnessFlag {
    param([int[]]$CheckedIndexes)
    if (4 -notin $CheckedIndexes) { return }
    $verdictRel = $StageConfig['qa'].VerdictFile
    $verdictAbs = Resolve-RepoPath $verdictRel
    if (Test-Path -LiteralPath $verdictAbs) {
        try {
            Write-AtomicRMW -Path $verdictAbs -Transform {
                param($obj)
                if ($null -eq $obj) { $obj = [ordered]@{} }
                $obj | Add-Member -NotePropertyName stageCheckedByHarness -NotePropertyValue $true -Force
                return $obj
            } -Depth 8
            Write-Log "⚠️ [qa] verdict에 stageCheckedByHarness=true 기록 — 하네스가 ④를 대신 체크했습니다" WARN
        } catch {
            Write-Log "[qa] stageCheckedByHarness 기록 실패($verdictAbs): $($_.Exception.Message)" WARN
        }
    } else {
        $stateAbs = Resolve-RepoPath "$LogDir/$TaskId-qa-stage-checked.json"
        $state = [ordered]@{ schemaVersion = 1; taskId = $TaskId; stage = 'qa'; stageCheckedByHarness = $true; checkedAt = [datetime]::UtcNow.ToString('o') }
        Write-AtomicJson -Path $stateAbs -Value $state -Depth 4
        Write-Log "⚠️ [qa] verdict 부재 — 별도 상태 파일에 stageCheckedByHarness=true 기록" WARN
    }
}

# CFG026: 착수 컨텍스트 바이트 수 측정. 모델이 실제로 로드하는 문서(전역 CLAUDE.md, 프로젝트
# CLAUDE.md, 라우터, 패킷 전문, Required Reading)와 DefaultPrompt의 합산 바이트를 잰다.
# 측정 자체가 컨텍스트를 늘리지 않도록, 이미 존재하는 파일의 크기만 읽는다.

function Repair-QaVerdictStageCycle {
    param([string]$VerdictPath, [object]$VerdictObj, [int]$ExpectedCycle)
    $actualStage = 'qa'
    $actualCycle = $null
    if ($ExpectedCycle -ge 0) {
        $actualCycle = $ExpectedCycle
    } else {
        $statePath = Resolve-RepoPath "$LogDir/$TaskId-stage-state.json"
        try {
            if (Test-Path -LiteralPath $statePath) {
                $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ([string]$state.stage -eq 'qa') {
                    $parsedCycle = 0
                    if ([int]::TryParse([string]$state.cycle, [ref]$parsedCycle)) {
                        $actualCycle = $parsedCycle
                    }
                }
            }
        } catch { }
    }
    # verdict는 Set-QaVerdictStageHarnessFlag/treeHash 봉인 경로와 공유된다. 호출자가
    # 읽어 온 $VerdictObj를 다시 쓰면 그 사이 추가된 필드를 잃을 수 있으므로, 파일 안의
    # 최신 객체를 같은 path RMW mutex 아래에서 보정한다.
    $changed = $false
    $script:cfg073RepairChanged = $false
    Write-AtomicRMW -Path $VerdictPath -Transform {
        param($current)
        if ($null -eq $current) { return $null }
        $currentStage = if ($current.PSObject.Properties.Name -contains 'stage') { [string]$current.stage } else { $null }
        if ($currentStage -ne $actualStage) {
            $current | Add-Member -NotePropertyName 'stage' -NotePropertyValue $actualStage -Force
            $script:cfg073RepairChanged = $true
        }
        if ($null -ne $actualCycle) {
            $currentCycle = $null
            if ($current.PSObject.Properties.Name -contains 'cycle') {
                $parsedCurrent = 0
                if ([int]::TryParse([string]$current.cycle, [ref]$parsedCurrent)) { $currentCycle = $parsedCurrent }
            }
            if ($null -eq $currentCycle -or $currentCycle -ne $actualCycle) {
                $current | Add-Member -NotePropertyName 'cycle' -NotePropertyValue $actualCycle -Force
                $script:cfg073RepairChanged = $true
            }
        }
        return $current
    } -Depth 8
    $changed = [bool]$script:cfg073RepairChanged
    Remove-Variable -Name cfg073RepairChanged -Scope Script -ErrorAction SilentlyContinue
    if ($changed) {
        Write-Log "✅ QA verdict stage/cycle 자동 보정 (stage=$actualStage, cycle=$actualCycle)" INFO
    }
    return $changed
}

# CFG077: taskId 자동 보정 — Validate-QaVerdict 호출 이전, Repair-QaVerdictStageCycle 직후.
# taskId가 없으면 디스패처가 이미 알고 있는 실제 값으로 채운다. taskId가 존재하지만 값이
# 다르면 보정하지 않는다(명백히 잘못된 값은 fail-closed로 거부 — CFG066 원칙 유지).

function Repair-QaVerdictTaskId {
    param([string]$VerdictPath, [string]$ExpectedTaskId)
    if ([string]::IsNullOrWhiteSpace($ExpectedTaskId)) { return $false }
    $currentObj = $null
    try {
        $currentObj = Get-Content -LiteralPath $VerdictPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return $false
    }
    if ($null -eq $currentObj) { return $false }
    $hasTaskId = $currentObj.PSObject.Properties.Name -contains 'taskId'
    if ($hasTaskId) { return $false }
    $script:cfg077RepairTaskIdChanged = $false
    Write-AtomicRMW -Path $VerdictPath -Transform {
        param($current)
        if ($null -eq $current) { return $null }
        if ($current.PSObject.Properties.Name -contains 'taskId') { return $current }
        $current | Add-Member -NotePropertyName 'taskId' -NotePropertyValue $ExpectedTaskId -Force
        $script:cfg077RepairTaskIdChanged = $true
        return $current
    } -Depth 8
    $changed = [bool]$script:cfg077RepairTaskIdChanged
    Remove-Variable -Name cfg077RepairTaskIdChanged -Scope Script -ErrorAction SilentlyContinue
    if ($changed) {
        Write-Log "✅ QA verdict taskId 자동 보정 (taskId=$ExpectedTaskId)" INFO
    }
    return $changed
}

# CFG066 Done When 1: QA 판정 심층 검증. Test-QaVerdict가 파일 존재·시각만 보던 것을
# doneWhen 모순·taskId/stage/cycle 일치·스키마 허용 목록·satisfied boolean·필수 ID 누락·중복·
# Git 지문·{verdict:"pass"}만으로 된 산출물 거부까지 확장한다.

function Validate-QaVerdict {
    param([object]$VerdictObj, [string]$ExpectedTaskId, [string]$ExpectedStage, [int]$ExpectedCycle, [switch]$SkipWorktreeFingerprint)
    $reasons = @()
    if ($null -eq $VerdictObj) { return @{ Valid = $false; Reasons = @('verdict object is null') } }

    # 스키마 버전 허용 목록
    $allowedSchemas = @(2, 3)
    $schemaVal = 0
    $hasSchema = $false
    if ($VerdictObj.PSObject.Properties.Name -contains 'schemaVersion') {
        $hasSchema = [int]::TryParse([string]$VerdictObj.schemaVersion, [ref]$schemaVal)
    }
    if (-not $hasSchema -or $allowedSchemas -notcontains $schemaVal) {
        $reasons += "schemaVersion missing or not in allowed list ($($allowedSchemas -join ','))"
    }

    # {verdict:"pass"}만 있는 산출물 거부 — doneWhen·findings 등 필수 필드 없이 verdict alone은 인정하지 않는다.
    $propNames = @($VerdictObj.PSObject.Properties.Name)
    if ($propNames.Count -le 1 -and $propNames -contains 'verdict') {
        $reasons += 'verdict-only output is not accepted; doneWhen and findings fields are required'
    }

    # taskId·stage·cycle 일치
    if ($VerdictObj.PSObject.Properties.Name -contains 'taskId') {
        if ([string]$VerdictObj.taskId -ne $ExpectedTaskId) {
            $reasons += "taskId mismatch: expected=$ExpectedTaskId actual=$($VerdictObj.taskId)"
        }
    } else {
        $reasons += 'taskId field missing'
    }
    if ($VerdictObj.PSObject.Properties.Name -contains 'stage') {
        if ([string]$VerdictObj.stage -ne $ExpectedStage) {
            $reasons += "stage mismatch: expected=$ExpectedStage actual=$($VerdictObj.stage)"
        }
    } else {
        $reasons += 'stage field missing'
    }
    if ($VerdictObj.PSObject.Properties.Name -contains 'cycle') {
        $verdictCycle = 0
        if (-not [int]::TryParse([string]$VerdictObj.cycle, [ref]$verdictCycle) -or $verdictCycle -ne $ExpectedCycle) {
            $reasons += "cycle mismatch: expected=$ExpectedCycle actual=$($VerdictObj.cycle)"
        }
    } else {
        $reasons += 'cycle field missing'
    }

    # doneWhen 검사: satisfied가 boolean이 아닌 값 거부, 하나라도 false면 verdict=pass 차단
    $seenItems = @{}
    if ($VerdictObj.PSObject.Properties.Name -contains 'doneWhen') {
        $doneWhenArr = @($VerdictObj.doneWhen)
        foreach ($dw in $doneWhenArr) {
            $itemId = $null
            if ($null -eq $dw) {
                $reasons += 'doneWhen contains null item'
                continue
            }
            if ($dw.PSObject.Properties.Name -contains 'item') { $itemId = [string]$dw.item }
            if ([string]::IsNullOrWhiteSpace($itemId)) { $reasons += 'doneWhen item field missing or empty' }
            if ($itemId -and $seenItems.ContainsKey($itemId)) {
                $reasons += "duplicate doneWhen item: $itemId"
            }
            if ($itemId) { $seenItems[$itemId] = $true }
            if ($dw.PSObject.Properties.Name -contains 'satisfied') {
                $satVal = $dw.satisfied
                if ($satVal -isnot [bool]) {
                    $reasons += "doneWhen.satisfied is not boolean for item=$itemId (value=$satVal, type=$($satVal.GetType().Name))"
                } elseif ($satVal -eq $false -and [string]$VerdictObj.verdict -eq 'pass') {
                    $reasons += "contradiction: verdict=pass but doneWhen.satisfied=false for item=$itemId"
                }
            } else {
                $reasons += "doneWhen.satisfied field missing for item=$itemId"
            }
        }
    } else {
        $reasons += 'doneWhen field missing'
    }

    # findings 필수 ID 누락·중복 검사
    if ($VerdictObj.PSObject.Properties.Name -contains 'findings') {
        $findingsArr = @($VerdictObj.findings)
        $seenIds = @{}
        foreach ($f in $findingsArr) {
            if ($f.PSObject.Properties.Name -contains 'id') {
                $fid = [string]$f.id
                if ($seenIds.ContainsKey($fid)) {
                    $reasons += "duplicate finding id: $fid"
                }
                $seenIds[$fid] = $true
            } else {
                $reasons += 'finding missing required id field'
            }
        }
    } else {
        $reasons += 'findings field missing'
    }

    # QA가 검토한 작업 트리 지문을 반드시 묶는다. HEAD만 비교하면 같은 커밋에서
    # uncommitted 변경 후 오래된 pass가 재사용될 수 있으므로 Get-TreeState의 내용 지문을 쓴다.
    # CFG078: 체인 완료 판정(Get-ChainDispositionState)처럼 QA 시점 이후 Integration이 작업 트리를
    # 커밋해 지문이 당연히 달라지는 소비자는 -SkipWorktreeFingerprint로 이 최신성 검사만 건너뛴다.
    # 판정 내용의 무결성(schema·taskId·stage·cycle·doneWhen·findings)은 그대로 검증한다.
    if (-not $SkipWorktreeFingerprint) {
        if ($VerdictObj.PSObject.Properties.Name -notcontains 'treeHash' -or [string]::IsNullOrWhiteSpace([string]$VerdictObj.treeHash)) {
            $reasons += 'treeHash field missing'
        } else {
            $treeState = Get-TreeState
            if ($null -eq $treeState -or -not $treeState.FingerprintOk) {
                $reasons += 'current worktree fingerprint could not be computed'
            } elseif ([string]$VerdictObj.treeHash -ne [string]$treeState.Fingerprint) {
                $reasons += "treeHash mismatch: verdict=$($VerdictObj.treeHash) current=$($treeState.Fingerprint)"
            }
        }
    }

    return @{ Valid = ($reasons.Count -eq 0); Reasons = $reasons }
}

# ④ QA verdict 게이트: 이번 실행에서 새로 쓴 verdict가 pass일 때만 ⑤ 진행.
# CFG066: Validate-QaVerdict로 판정 내용의 모순·일치성까지 검증한다.

function Test-QaVerdict {
    param([object]$QaDispatchedAt, [int]$ExpectedCycle = -1)
    $rel = $StageConfig['qa'].VerdictFile
    $vf = Resolve-RepoPath $rel
    if (-not (Test-Path $vf)) {
        Write-Log "⚠️ QA verdict 파일 없음($rel) — 안전상 ⑤ 중단" ERROR
        return $false
    }
    # 디스패치 이후에 쓰인 파일만 인정 — 이전 실행이 남긴 pass의 재사용을 막는다.
    if ($null -ne $QaDispatchedAt) {
        $written = (Get-Item $vf).LastWriteTime
        if ($written -lt $QaDispatchedAt) {
            Write-Log "⚠️ QA verdict가 이번 실행 이전 것($written < $QaDispatchedAt) — 이번 QA는 판정을 남기지 않았다. 안전상 ⑤ 중단" ERROR
            return $false
        }
    }
    $verdictObj = $null
    try {
        $verdictObj = Get-Content $vf -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Log "⚠️ QA verdict JSON 파싱 실패 — 안전상 ⑤ 중단" ERROR
        return $false
    }
    # CFG073: stage/cycle 자동 보정 — Validate-QaVerdict 호출 이전, treeHash 봉인 이전.
    # 이 두 필드만 수정하며, 다른 필드(taskId·schemaVersion·findings 등)는 절대 건드리지 않는다.
    Repair-QaVerdictStageCycle -VerdictPath $vf -VerdictObj $verdictObj -ExpectedCycle $ExpectedCycle | Out-Null
    # CFG077: taskId 자동 보정 — 누락만 채운다. 존재하지만 값이 다르면 보정하지 않는다(fail-closed).
    Repair-QaVerdictTaskId -VerdictPath $vf -ExpectedTaskId $TaskId | Out-Null
    $verdictObj = Get-Content -LiteralPath $vf -Raw -Encoding UTF8 | ConvertFrom-Json
    $verdictValue = [string]$verdictObj.verdict

    # 현 QA 실행이 막 끝났을 때에만 하네스가 실제 작업 트리 지문을 봉인한다.
    # 기존 산출물(Integration 단독 실행 등)은 절대 보완하지 않아, 오래된 pass를 새 상태에 재사용할 수 없다.
    if ($verdictValue -eq 'pass' -and $null -ne $QaDispatchedAt -and
        ($verdictObj.PSObject.Properties.Name -notcontains 'treeHash' -or [string]::IsNullOrWhiteSpace([string]$verdictObj.treeHash))) {
        $treeState = Get-TreeState
        if ($treeState -and $treeState.FingerprintOk) {
            # 다른 하네스 경로(Set-QaVerdictStageHarnessFlag 등)가 verdict를 동시에 보강할 수
            # 있으므로, treeHash 봉인도 반드시 동일한 path 단위 RMW mutex 안에서 수행한다.
            # 여기서 일반 원자 쓰기를 쓰면, 이미 읽어 둔 $verdictObj가 동시 갱신 필드를 덮어쓸 수 있다.
            Write-AtomicRMW -Path $vf -Transform {
                param($current)
                if ($null -eq $current) { return $null }
                if ([string]$current.verdict -ne 'pass') { return $current }
                if ($current.PSObject.Properties.Name -contains 'treeHash' -and -not [string]::IsNullOrWhiteSpace([string]$current.treeHash)) { return $current }
                $current | Add-Member -NotePropertyName treeHash -NotePropertyValue ([string]$treeState.Fingerprint) -Force
                return $current
            } -Depth 8
            # RMW 중 병행 보강된 필드까지 반영한 실제 파일을 이후 verdict 검증에 사용한다.
            $verdictObj = Get-Content -LiteralPath $vf -Raw -Encoding UTF8 | ConvertFrom-Json
            $verdictValue = [string]$verdictObj.verdict
        }
    }

    if ($ExpectedCycle -lt 0) {
        # 호출자가 방금 실행한 QA cycle을 모르는 일반 조회(예: Set-CompletedStageApprovalsSuperseded,
        # 통합 전 게이트)다. stage-state.json이 아직 'qa'를 가리키면 그 cycle을 신뢰하되, 파이프라인이
        # 이미 다음 단계로 넘어갔거나 상태 파일이 없어 외부 근거가 없으면 verdict 자신이 기록한 cycle을
        # 신뢰한다 — 무관한 단계로 전환됐다는 이유만으로 진짜 pass를 fail-closed 시키지 않는다.
        # cycle 필드 자체가 없는 verdict는 Validate-QaVerdict가 별도로 거부한다.
        $statePath = Resolve-RepoPath "$LogDir/$TaskId-stage-state.json"
        $stateCycle = -1
        try {
            $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $parsedStateCycle = 0
            if ([string]$state.stage -eq 'qa' -and [int]::TryParse([string]$state.cycle, [ref]$parsedStateCycle)) {
                $stateCycle = $parsedStateCycle
            }
        } catch { }
        if ($stateCycle -ge 0) {
            $ExpectedCycle = $stateCycle
        } else {
            $selfCycle = 0
            if ($verdictObj.PSObject.Properties.Name -contains 'cycle' -and [int]::TryParse([string]$verdictObj.cycle, [ref]$selfCycle)) {
                $ExpectedCycle = $selfCycle
            } else {
                Write-Log "⚠️ QA verdict의 기대 cycle을 읽을 수 없음 — 안전상 ⑤ 중단" ERROR
                return $false
            }
        }
    }

    # CFG066: 합성 pass 차단 — synthetic=true이면 실제 QA 판정이 아니다.
    if ([bool]$verdictObj.synthetic -eq $true -and $verdictValue -eq 'pass') {
        Write-Log "⚠️ QA verdict가 합성(synthetic=true)인데 pass — 실제 QA 판정 없으므로 ⑤ 중단" ERROR
        return $false
    }

    # CFG066 Done When 1: 심층 검증
    $validation = Validate-QaVerdict -VerdictObj $verdictObj -ExpectedTaskId $TaskId -ExpectedStage 'qa' -ExpectedCycle $ExpectedCycle
    if (-not $validation.Valid) {
        foreach ($r in $validation.Reasons) { Write-Log "⚠️ QA verdict 검증 실패: $r" ERROR }
        Write-Log "⚠️ QA verdict 심층 검증 실패($($validation.Reasons.Count)건) — 안전상 ⑤ 중단" ERROR
        return $false
    }

    if ($verdictValue -eq 'pass') { Write-Log "✅ QA verdict=pass → ⑤ 진행" SUCCESS; return $true }
    Write-Log "❌ QA verdict=$verdictValue → ⑤ 진행 중단 (QA 보고: $($StageConfig['qa'].ReportFile))" ERROR
    return $false
}

# ── CFG043: 수동 완료·안전 재개 ─────────────────────────────────────────────
# 실행 중('running'/'starting') lease가 아직 만료되지 않았거나 살아 있는 락이 있는지 판정한다.
# 자동 재개(-Chain)가 이들을 "건드리지 않고" 멈추기 위한 가드다. stale(만료) lease나 종결
# lease는 재개를 막지 않는다 — 그게 재개가 진행해야 할 대상이기 때문이다.
# CFG071: -StagesToCheck 매개변수로 검사할 스테이지 집합을 좁힐 수 있다(기본값: 전체 3종).

