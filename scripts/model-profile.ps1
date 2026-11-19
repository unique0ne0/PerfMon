# Role profile resolution and command construction for the packet driver.
# This file deliberately accepts profile names, never executable command strings.

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { throw "Invalid JSON: $Path ($($_.Exception.Message))" }
}

function Test-ProfileGraph {
    param([object]$Config, [System.Collections.ArrayList]$Warnings = $null)
    if ($null -eq $Config -or $Config.schemaVersion -ne 2 -or $null -eq $Config.roles -or $null -eq $Config.profiles -or $null -eq $Config.routes -or $null -eq $Config.plannerRouting -or $null -eq $Config.modelCatalog) { throw 'Invalid model profile schema.' }
    foreach ($role in @('planning', 'orchestration')) { if ([string]::IsNullOrWhiteSpace([string]$Config.roles.$role)) { throw "Missing role profile: $role" } }
    foreach ($property in @($Config.profiles.psobject.Properties)) {
        $profile = $property.Value
        if ($property.Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') { throw "Invalid profile name: $($property.Name)" }
        if ($profile.adapter -notin @('claude', 'codex', 'opencode', 'gemini', 'antigravity')) { throw "Unsupported adapter in profile: $($property.Name)" }
        if ([string]::IsNullOrWhiteSpace([string]$profile.family) -or [string]$profile.family -notmatch '^[a-z][a-z0-9-]*$') { throw "Invalid family in profile: $($property.Name)" }
        if ([string]::IsNullOrWhiteSpace([string]$profile.model) -or [string]$profile.model -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$') { throw "Invalid model in profile: $($property.Name)" }
        foreach ($fallback in @($profile.fallbackProfiles)) { if ($null -eq $Config.profiles.$fallback) { throw "Unknown fallback profile '$fallback' in $($property.Name)" } }
        if ($property.Name -match '-(qa|integration)$') {
            foreach ($fallback in @($profile.fallbackProfiles)) {
                $fbProfile = $Config.profiles.$fallback
                if ($null -ne $fbProfile -and [string]$fbProfile.family -ne [string]$profile.family) {
                    throw "Profile '$($property.Name)' (family=$([string]$profile.family)) has cross-family fallback '$fallback' (family=$([string]$fbProfile.family)) — pipeline role fallback must be provider swap only (same family)"
                }
            }
        }
    }
    function Visit-ProfileFallback {
        param([string]$Name, [hashtable]$Visiting, [hashtable]$Visited)
        if ($Visiting.ContainsKey($Name)) { throw "Profile fallback cycle: $Name" }
        if ($Visited.ContainsKey($Name)) { return }
        $Visiting[$Name] = $true
        foreach ($fallback in @($Config.profiles.$Name.fallbackProfiles)) { Visit-ProfileFallback -Name ([string]$fallback) -Visiting $Visiting -Visited $Visited }
        $Visiting.Remove($Name); $Visited[$Name] = $true
    }
    $visitedProfiles = @{}
    foreach ($property in @($Config.profiles.psobject.Properties)) { Visit-ProfileFallback -Name $property.Name -Visiting @{} -Visited $visitedProfiles }
    foreach ($catalogEntry in @($Config.modelCatalog.psobject.Properties)) {
        $meta = $catalogEntry.Value
        if ([string]$meta.family -notmatch '^[a-z][a-z0-9-]*$') { throw "Invalid family in modelCatalog: $($catalogEntry.Name)" }
        if ([string]::IsNullOrWhiteSpace([string]$meta.principal)) { throw "Missing principal in modelCatalog: $($catalogEntry.Name)" }
        # adapter/invokeModel은 선택 항목이다 — 없으면 opencode 어댑터에 식별자 그대로가 모델명이다.
        # 개발1팀(구현) 슬롯도 어댑터가 고정이 아니어야 하므로(모든 팀이 모든 역할 수행) 여기서 검증만 하고
        # 기본값은 디스패처가 채운다.
        if ($meta.adapter -and ([string]$meta.adapter -notin @('claude', 'codex', 'opencode', 'gemini', 'antigravity'))) { throw "Unsupported adapter in modelCatalog: $($catalogEntry.Name)" }
        if ($meta.invokeModel -and ([string]$meta.invokeModel -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$')) { throw "Invalid invokeModel in modelCatalog: $($catalogEntry.Name)" }
    }
    foreach ($route in @($Config.routes.psobject.Properties)) {
        $models = @($route.Value)
        if ($models.Count -eq 0) { throw "Route $($route.Name) must have at least one model." }
        foreach ($model in $models) {
            if ([string]$model -notmatch '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$') { throw "Invalid route model: $model" }
            if ($null -eq $Config.modelCatalog.$model) { throw "Route $($route.Name) contains unregistered model: $model" }
        }
        $opencodeSlots = @($models | Where-Object {
            $cat = $Config.modelCatalog.$_
            $null -ne $cat -and ($null -eq $cat.adapter -or [string]::IsNullOrWhiteSpace([string]$cat.adapter) -or [string]$cat.adapter -eq 'opencode')
        })
        if ($opencodeSlots.Count -ge 2) {
            $lastModel = $models[-1]
            $lastCatalog = $Config.modelCatalog.$lastModel
            if ($null -eq $lastCatalog -or [string]$lastCatalog.cost -ne 'free') {
                throw "Route $($route.Name) with 2 or more opencode slots must end with a free model."
            }
        }
        $unique = @($models | Sort-Object -Unique)
        if ($unique.Count -ne $models.Count) { throw "Route $($route.Name) contains duplicate models." }
    }
    # 검사 대상 어댑터를 하드코딩하지 않고 plannerRouting 자체에서 읽는다. 다만 실제로 기획을 맡을 수
    # 있는 어댑터는 항목이 빠지면 안 되므로 존재만 강제한다(gemini는 agy로 대체되어 선택 항목이다).
    foreach ($requiredAdapter in @('claude', 'codex', 'antigravity', 'opencode')) {
        if ($null -eq $Config.plannerRouting.$requiredAdapter) { throw "Missing planner routing for $requiredAdapter" }
    }
    # CFG046 Done When 1: every supported team must be executable in every pipeline role.
    foreach ($adapter in @('claude', 'codex', 'antigravity', 'opencode')) {
        foreach ($roleSuffix in @('planning', 'driver', 'qa', 'integration')) {
            $matches = @($Config.profiles.psobject.Properties | Where-Object {
                [string]$_.Value.adapter -eq $adapter -and $_.Name -match ("-{0}$" -f $roleSuffix)
            })
            if ($matches.Count -eq 0) { throw "Missing $roleSuffix profile for $adapter" }
        }
    }
    foreach ($routingProperty in @($Config.plannerRouting.psobject.Properties)) {
        $adapter = [string]$routingProperty.Name
        $route = $routingProperty.Value
        $routeName = if ($route) { [string]$route.implementationRoute } else { '' }
        $qaName = if ($route) { [string]$route.qaProfile } else { '' }
        $integrationName = if ($route) { [string]$route.integrationProfile } else { '' }
        if ($null -eq $route -or $null -eq $Config.routes.$routeName -or $null -eq $Config.profiles.$qaName -or $null -eq $Config.profiles.$integrationName) { throw "Invalid planner routing for $adapter" }
        $qa = $Config.profiles.$qaName
        # 어댑터 이름과 family 이름은 같지 않다 — antigravity 어댑터의 family는 gemini다. 교차 원칙은
        # 이름이 아니라 그 어댑터를 쓰는 프로필들의 family로 판정한다. 프로필이 하나도 없는 어댑터는
        # (호환을 위해 남겨둔 gemini처럼) 기획을 맡을 수 없으므로 선호 검사를 건너뛴다.
        $adapterFamilies = @($Config.profiles.psobject.Properties | Where-Object { [string]$_.Value.adapter -eq $adapter } | ForEach-Object { [string]$_.Value.family } | Sort-Object -Unique)
        if ($adapterFamilies.Count -gt 0) {
            if ([string]$qa.family -in $adapterFamilies) {
                $msg = "Planner $adapter uses same-family QA profile $($route.qaProfile) (prefer violation)"
                if ($null -ne $Warnings) { $null = $Warnings.Add($msg) } else { throw $msg }
            }
            if ([string]$Config.profiles.$integrationName.family -notin $adapterFamilies) {
                $msg = "Planner $adapter does not use its own family for Integration (prefer violation)"
                if ($null -ne $Warnings) { $null = $Warnings.Add($msg) } else { throw $msg }
            }
        }
        $implModels = @($Config.routes.$routeName)
        foreach ($m in $implModels) {
            $mFamily = if ($Config.modelCatalog.$m) { [string]$Config.modelCatalog.$m.family } else { '' }
            if ($mFamily -ne '' -and $mFamily -ne 'unknown' -and $mFamily -eq $qa.family) {
                throw "Implementation model $m (family=$mFamily) shares family with QA profile $($route.qaProfile) (family=$($qa.family)) — must violation"
            }
        }
        $planningProfilesForAdapter = @($Config.profiles.psobject.Properties | Where-Object { [string]$_.Value.adapter -eq $adapter -and $_.Name -match '-planning$' })
        if ($planningProfilesForAdapter.Count -gt 0) {
            $plannerFamily = [string]$planningProfilesForAdapter[0].Value.family
            if ($plannerFamily -ne '' -and $plannerFamily -ne 'unknown') {
                foreach ($adjM in $implModels) {
                    $adjMFam = if ($Config.modelCatalog.$adjM) { [string]$Config.modelCatalog.$adjM.family } else { '' }
                    if ($adjMFam -ne '' -and $adjMFam -ne 'unknown' -and $adjMFam -eq $plannerFamily) {
                        $adjMsg = "Planner $adapter : planning (family=$plannerFamily) and implementation model $adjM (family=$adjMFam) are adjacent same-family (prefer violation)"
                        if ($null -ne $Warnings) { $null = $Warnings.Add($adjMsg) } else { throw $adjMsg }
                    }
                }
            }
        }
        $qaFamAdj = [string]$qa.family
        $intFamAdj = [string]$Config.profiles.$integrationName.family
        if ($qaFamAdj -ne '' -and $qaFamAdj -ne 'unknown' -and $qaFamAdj -eq $intFamAdj) {
            $adjMsg45 = "Planner $adapter : QA profile $($route.qaProfile) (family=$qaFamAdj) and Integration profile $($route.integrationProfile) (family=$intFamAdj) are adjacent same-family (prefer violation)"
            if ($null -ne $Warnings) { $null = $Warnings.Add($adjMsg45) } else { throw $adjMsg45 }
        }
    }
}

function Read-ModelProfileConfig {
    # CFG121(C): -LocalOverrides([ref])로 로컬 오버레이 적용 내역("roles.qa=gemini-qa" 등)을 돌려준다.
    # 호출부가 로그·chain-summary에 오버레이 적용 사실을 드러내기 위한 단일 출처다.
    param([string]$CentralPath, [string]$LocalPath, [ref]$LocalOverrides)
    $config = Read-JsonFile -Path $CentralPath
    $graphWarnings = [System.Collections.ArrayList]@()
    Test-ProfileGraph -Config $config -Warnings $graphWarnings
    foreach ($w in $graphWarnings) { Write-Warning $w }
    $graphWarnings.Clear()
    $overrides = New-Object System.Collections.Generic.List[string]
    $local = Read-JsonFile -Path $LocalPath
    if ($null -ne $local) {
        $unexpectedTopLevel = @($local.psobject.Properties.Name | Where-Object { $_ -notin @('roles', 'plannerRouting', 'preferCost') })
        if ($unexpectedTopLevel.Count -gt 0) { throw "Local model profile config only permits 'roles', 'plannerRouting', and 'preferCost'." }
        $forbiddenFields = @('command', 'apiKey', 'token', 'secret', 'password')
        foreach ($prop in @($local.psobject.Properties)) {
            if ($prop.Name -in $forbiddenFields) { throw "Local model profile config contains forbidden field: $($prop.Name)" }
        }
        if ($null -ne $local.preferCost) {
            $costVal = [string]$local.preferCost
            if ($costVal -ne 'free') { throw "Unsupported preferCost value '$costVal'. Only 'free' is supported." }
            $config | Add-Member -NotePropertyName preferCost -NotePropertyValue $costVal -Force
            $overrides.Add("preferCost=$costVal")
        }
        if ($null -ne $local.roles) {
            $unexpectedRoles = @($local.roles.psobject.Properties.Name | Where-Object { $_ -notin @('planning', 'orchestration', 'impl', 'qa', 'integration') })
            if ($unexpectedRoles.Count -gt 0) { throw 'Local model profile config contains an unsupported role.' }
            foreach ($role in @('planning', 'orchestration', 'impl', 'qa', 'integration')) {
                if ($null -ne $local.roles.$role) {
                    $config.roles | Add-Member -NotePropertyName $role -NotePropertyValue ([string]$local.roles.$role) -Force
                    $overrides.Add("roles.$role=$([string]$local.roles.$role)")
                }
            }
        }
        if ($null -ne $local.plannerRouting) {
            foreach ($adapter in @($local.plannerRouting.psobject.Properties)) {
                if ($null -eq $config.plannerRouting) { $config.plannerRouting = [pscustomobject]@{} }
                $centralRoute = $config.plannerRouting.($adapter.Name)
                if ($null -eq $centralRoute) {
                    $config.plannerRouting | Add-Member -NotePropertyName $adapter.Name -NotePropertyValue $adapter.Value
                    foreach ($prop in @($adapter.Value.psobject.Properties)) {
                        $overrides.Add("plannerRouting.$($adapter.Name).$($prop.Name)=$([string]$prop.Value)")
                    }
                }
                else {
                    foreach ($prop in @($adapter.Value.psobject.Properties)) {
                        $centralRoute | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value -Force
                        $overrides.Add("plannerRouting.$($adapter.Name).$($prop.Name)=$([string]$prop.Value)")
                    }
                }
            }
            foreach ($adapter in @($local.plannerRouting.psobject.Properties)) {
                if ($null -ne $adapter.Value) {
                    foreach ($prop in @($adapter.Value.psobject.Properties)) {
                        if ($prop.Name -in $forbiddenFields) { throw "Local plannerRouting for '$($adapter.Name)' contains forbidden field: $($prop.Name)" }
                    }
                }
            }
        }
        Test-ProfileGraph -Config $config -Warnings $graphWarnings
        foreach ($w in $graphWarnings) { Write-Warning $w }
    }
    if ($null -ne $LocalOverrides) { $LocalOverrides.Value = @($overrides) }
    return $config
}

function Get-QuotaTelemetryPath {
    # CFG124: 주간 쿼터 텔레메트리(계정 전역) 기본 경로. statusline.js가 원자적으로 기록한다.
    # 주의: $home은 PowerShell 자동 변수($HOME)라 쓸 수 없다.
    $userHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
    if ([string]::IsNullOrWhiteSpace($userHome)) { return $null }
    return (Join-Path $userHome '.agents\harness\logs\claude-quota.json')
}

function ConvertTo-QuotaLocalTime {
    # CFG124 R4: 판정 기준 시각 정규화. ISO 'Z'(UTC)는 로컬로 변환하고 Kind=Unspecified는
    # 로컬 시각으로 간주한다(문자열이면 invariant + RoundtripKind로 파싱).
    param([object]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTime]) {
        $dt = [DateTime]$Value
    } else {
        $text = [string]$Value
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        $parsed = [DateTime]::MinValue
        if (-not [DateTime]::TryParse($text, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) { return $null }
        $dt = $parsed
    }
    if ($dt.Kind -eq [DateTimeKind]::Utc) { return $dt.ToLocalTime() }
    if ($dt.Kind -eq [DateTimeKind]::Unspecified) { return [DateTime]::SpecifyKind($dt, [DateTimeKind]::Local) }
    return $dt
}

function ConvertTo-QuotaPercent {
    param([object]$Value)
    if ($null -eq $Value) { return $null }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $parsed = 0.0
    if ([double]::TryParse($text, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) { return $parsed }
    return $null
}

function Get-QuotaPlanningDecision {
    # CFG124 P1/R4: 주간 쿼터 → 기획 담당 무상태 판정. 순수 함수다 — 시각을 인자로만 받는다
    # (내부에서 Get-Date 호출 금지). 반환 프로퍼티: Profile / Source / Cap / WindowDay / Percent / Reason.
    # Source='quota-policy'만 실제 전환 판정이고, 'config-fallback'은 호출부가 roles.planning을 쓰라는 뜻이다.
    param([object]$Policy, [object]$SevenDayPercent, [object]$ObservedAt, [object]$Now)
    $decision = [pscustomobject]@{
        Profile   = $null
        Source    = 'config-fallback'
        Cap       = $null
        WindowDay = $null
        Percent   = $null
        Reason    = $null
    }
    if ($null -eq $Policy -or $Policy.enabled -ne $true) { $decision.Reason = 'policy-disabled'; return $decision }

    $nowLocal = ConvertTo-QuotaLocalTime -Value $Now
    if ($null -eq $nowLocal) { $decision.Reason = 'invalid-now'; return $decision }

    $boundaryHour = 17
    $parsedBoundary = ConvertTo-QuotaPercent -Value $Policy.boundaryHour
    if ($null -ne $parsedBoundary) { $boundaryHour = [int]$parsedBoundary }

    # 창 판정(P1): 경계 시각 이후면 창 끝 = 다음날 경계, 이전이면 당일 경계.
    # 상한은 "창이 끝나는 날"의 요일 값이다 — 17:00 정각은 다음 창에 속한다.
    $windowEnd = if ($nowLocal.TimeOfDay -ge [TimeSpan]::FromHours($boundaryHour)) { $nowLocal.Date.AddDays(1).AddHours($boundaryHour) } else { $nowLocal.Date.AddHours($boundaryHour) }
    $windowDay = $windowEnd.DayOfWeek.ToString()
    $decision.WindowDay = $windowDay

    $hardCap = 95
    $parsedHardCap = ConvertTo-QuotaPercent -Value $Policy.hardCapPercent
    if ($null -ne $parsedHardCap) { $hardCap = $parsedHardCap }

    $cap = $null
    if ($null -ne $Policy.dailyCapPercent) { $cap = ConvertTo-QuotaPercent -Value $Policy.dailyCapPercent.$windowDay }
    if ($null -eq $cap) {
        # 상한표에 없는 요일은 추측 전환하지 않는다(P4) — 판정 불가로 돌려준다.
        $decision.Reason = 'missing-cap'
        return $decision
    }
    $decision.Cap = $cap

    # 주간 리셋 = Now 이전(포함)의 가장 최근 "일요일 경계 시각". 관측값이 그 이전이면 지난 주 값이다.
    $daysSinceSunday = [int]$nowLocal.DayOfWeek
    $lastReset = $nowLocal.Date.AddDays(-$daysSinceSunday).AddHours($boundaryHour)
    if ($lastReset -gt $nowLocal) { $lastReset = $lastReset.AddDays(-7) }

    $weeklyPercent = ConvertTo-QuotaPercent -Value $SevenDayPercent
    if ($null -eq $weeklyPercent -or [double]::IsNaN($weeklyPercent) -or [double]::IsInfinity($weeklyPercent) -or $weeklyPercent -lt 0 -or $weeklyPercent -gt 100) { $decision.Reason = 'no-telemetry'; return $decision }

    $observedLocal = ConvertTo-QuotaLocalTime -Value $ObservedAt
    if ($null -eq $observedLocal) { $decision.Reason = 'no-telemetry'; return $decision }

    if ($observedLocal -lt $lastReset) { $decision.Reason = 'stale-telemetry'; return $decision }
    if ($observedLocal -gt $nowLocal.AddMinutes(5)) { $decision.Reason = 'future-telemetry'; return $decision }

    $maxAgeMinutes = 360
    $parsedMaxAge = ConvertTo-QuotaPercent -Value $Policy.telemetryMaxAgeMinutes
    if ($null -ne $parsedMaxAge) { $maxAgeMinutes = $parsedMaxAge }
    if (($nowLocal - $observedLocal).TotalMinutes -gt $maxAgeMinutes) { $decision.Reason = 'stale-telemetry'; return $decision }

    $overCapProfile = if ($Policy.overCapProfile) { [string]$Policy.overCapProfile } else { 'codex-planning' }
    $underCapProfile = if ($Policy.underCapProfile) { [string]$Policy.underCapProfile } else { 'claude-planning' }

    $decision.Percent = $weeklyPercent
    $decision.Source = 'quota-policy'
    $decision.Reason = if ($weeklyPercent -ge $hardCap) { 'hard-cap' } elseif ($weeklyPercent -ge $cap) { 'over-cap' } else { 'under-cap' }
    $decision.Profile = if ($weeklyPercent -ge $hardCap -or $weeklyPercent -ge $cap) { $overCapProfile } else { $underCapProfile }
    return $decision
}

function Read-QuotaTelemetry {
    # CFG124 P3/P4: statusline.js가 남긴 계정 전역 주간 쿼터 스냅샷. 없거나 깨졌으면 $null.
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return $null }
    try { $telemetry = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
    if ($null -eq $telemetry) { return $null }
    return [pscustomobject]@{
        SevenDayPercent = $telemetry.sevenDayUsedPercentage
        ObservedAt      = $telemetry.observedAt
    }
}

function Get-ClaudeQuotaHeaderValue {
    # CFG125 P1/R2: IDictionary·WebHeaderCollection 공통 조회. 값이 배열이면 첫 원소를 쓴다.
    # $Headers[$name]은 두 타입 모두 지원하고 대소문자도 구분하지 않는다(PS 해시테이블 기본).
    param([object]$Headers, [string]$Name)
    if ($null -eq $Headers -or [string]::IsNullOrWhiteSpace($Name)) { return $null }
    $value = $null
    try { $value = $Headers[$Name] } catch { $value = $null }
    if ($value -is [array]) {
        if ($value.Count -eq 0) { return $null }
        $value = $value[0]
    }
    if ($null -eq $value) { return $null }
    $text = [string]$value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text.Trim()
}

function ConvertTo-ClaudeQuotaUtilizationPercent {
    # CFG125 P1: unified-*-utilization은 0~1 비율이다. 범위 밖·파싱 실패는 $null.
    param([object]$Value)
    $ratio = ConvertTo-QuotaPercent -Value $Value
    if ($null -eq $ratio -or [double]::IsNaN($ratio) -or [double]::IsInfinity($ratio)) { return $null }
    if ($ratio -lt 0 -or $ratio -gt 1) { return $null }
    return [math]::Round($ratio * 100, 4)
}

function ConvertFrom-ClaudeQuotaHeaders {
    # CFG125 P1: Claude OAuth 요청 응답 헤더 → 주간/5시간 쿼터 퍼센트.
    # 7d-utilization 헤더 자체가 없으면 $null이다(비200 응답 포함 — 있으면 기록한다).
    # 반환 프로퍼티: SevenDayPercent / FiveHourPercent / SevenDayReset(epoch 초).
    param([object]$Headers)
    $sevenDayRaw = Get-ClaudeQuotaHeaderValue -Headers $Headers -Name 'anthropic-ratelimit-unified-7d-utilization'
    if ($null -eq $sevenDayRaw) { return $null }
    $fiveHourRaw = Get-ClaudeQuotaHeaderValue -Headers $Headers -Name 'anthropic-ratelimit-unified-5h-utilization'
    $resetRaw = Get-ClaudeQuotaHeaderValue -Headers $Headers -Name 'anthropic-ratelimit-unified-7d-reset'
    $sevenDayReset = $null
    if ($null -ne $resetRaw) {
        $epochSeconds = 0L
        if ([long]::TryParse($resetRaw, [ref]$epochSeconds)) { $sevenDayReset = $epochSeconds }
    }
    return [pscustomobject]@{
        SevenDayPercent = ConvertTo-ClaudeQuotaUtilizationPercent -Value $sevenDayRaw
        FiveHourPercent = ConvertTo-ClaudeQuotaUtilizationPercent -Value $fiveHourRaw
        SevenDayReset   = $sevenDayReset
    }
}

function ConvertTo-ClaudeQuotaHeaderTable {
    # CFG125 P2: 응답 헤더를 해시테이블로 복사한다 — HttpWebResponse를 Dispose한 뒤에도
    # 값을 안전하게 읽기 위해서다(대소문자 무시 비교도 유지된다).
    param([object]$Headers)
    $table = @{}
    if ($null -eq $Headers) { return $table }
    if ($Headers -is [System.Net.WebHeaderCollection]) {
        foreach ($key in @($Headers.AllKeys)) {
            if ([string]::IsNullOrWhiteSpace($key)) { continue }
            $table[$key] = $Headers[$key]
        }
        return $table
    }
    if ($Headers -is [System.Collections.IDictionary]) {
        foreach ($key in @($Headers.Keys)) { $table[[string]$key] = $Headers[$key] }
        return $table
    }
    foreach ($prop in @($Headers.PSObject.Properties)) { $table[$prop.Name] = $prop.Value }
    return $table
}

function Get-ClaudeQuotaCredentialsPath {
    # CFG125 P2: 자격 증명 기본 경로. $home은 PowerShell 자동 변수($HOME)라 쓸 수 없다.
    $userHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
    if ([string]::IsNullOrWhiteSpace($userHome)) { return $null }
    return (Join-Path $userHome '.claude\.credentials.json')
}

function Invoke-ClaudeQuotaProbeRequest {
    # CFG125 P2/R2: 실제 OAuth 1토큰 요청. 보안 — 토큰·Authorization 헤더·요청 객체를
    # 로그·예외 메시지에 절대 남기지 않는다. 상태 코드만 Verbose로 허용한다.
    # 비200(429 등)도 응답 헤더에 7d가 있으면 기록 대상이므로 헤더를 돌려준다.
    param([string]$Token, [int]$TimeoutSec = 10)
    if ([string]::IsNullOrWhiteSpace($Token)) { return $null }
    $body = '{"model":"claude-haiku-4-5","max_tokens":1,"messages":[{"role":"user","content":"."}]}'
    $requestHeaders = @{
        'anthropic-version' = '2023-06-01'
        'authorization'     = "Bearer $Token"
    }
    $response = $null
    try {
        # 보안(P5): -Verbose:$false로 전역 VerbosePreference가 켜져 있어도 요청 헤더(토큰)가
        # Verbose 스트림에 찍히지 않게 한다.
        $response = Invoke-WebRequest -UseBasicParsing -Verbose:$false -ErrorAction Stop -Method Post -Uri 'https://api.anthropic.com/v1/messages' -ContentType 'application/json' -Headers $requestHeaders -Body $body -TimeoutSec $TimeoutSec
        $collected = ConvertTo-ClaudeQuotaHeaderTable -Headers $response.Headers
        Write-Verbose "Claude quota probe status: $([int]$response.StatusCode)"
        return $collected
    } catch [System.Net.WebException] {
        $webResponse = $_.Exception.Response
        if ($null -eq $webResponse) { return $null }
        try {
            $collected = ConvertTo-ClaudeQuotaHeaderTable -Headers $webResponse.Headers
            Write-Verbose "Claude quota probe status: $([int]$webResponse.StatusCode)"
            return $collected
        } finally {
            $webResponse.Dispose()
        }
    } catch {
        Write-Verbose 'Claude quota probe failed before a response was received.'
        return $null
    } finally {
        if ($null -ne $response) {
            try { $response.Dispose() } catch { }
        }
    }
}

function Update-ClaudeQuotaTelemetry {
    # CFG125 P2/R3/R6: OAuth 1토큰 요청의 응답 헤더로 CFG124와 같은 형식의 스냅샷을 갱신한다.
    # 반환값: 캐시 스킵/기록 성공 $true, 그 외(자격 증명 없음·만료·헤더 없음·쓰기 실패) $false.
    # 모든 실패는 예외를 삼킨다 — 호출부의 기존 fallback 경로가 그대로 동작해야 한다.
    # -Invoker는 param($Token,$TimeoutSec)을 받아 헤더 객체(또는 $null)를 돌려주는 스크립트블록이다.
    param(
        [string]$Path,
        [object]$Policy,
        [DateTime]$Now = (Get-Date),
        [string]$CredentialsPath,
        [scriptblock]$Invoker,
        [int]$TimeoutSec = 10
    )
    try {
        if ([string]::IsNullOrWhiteSpace($Path)) { return $false }

        $maxAgeMinutes = 10
        if ($null -ne $Policy) {
            $parsedMaxAge = ConvertTo-QuotaPercent -Value $Policy.probeMaxAgeMinutes
            if ($null -ne $parsedMaxAge) { $maxAgeMinutes = $parsedMaxAge }
        }

        # (a) 캐시: 7d가 0~100이고 관측 시각이 미래(+5분)가 아니며 maxAge 이내면 네트워크 0회.
        $existing = Read-QuotaTelemetry -Path $Path
        if ($null -ne $existing) {
            $existingPercent = ConvertTo-QuotaPercent -Value $existing.SevenDayPercent
            $observedLocal = ConvertTo-QuotaLocalTime -Value $existing.ObservedAt
            $nowLocal = ConvertTo-QuotaLocalTime -Value $Now
            if ($null -ne $existingPercent -and $existingPercent -ge 0 -and $existingPercent -le 100 -and $null -ne $observedLocal -and $null -ne $nowLocal) {
                if ($observedLocal -le $nowLocal.AddMinutes(5) -and ($nowLocal - $observedLocal).TotalMinutes -lt $maxAgeMinutes) { return $true }
            }
        }

        # (b) 자격 증명: 없거나 만료면 중단한다(만료 판정은 UTC 기준).
        if ([string]::IsNullOrWhiteSpace($CredentialsPath)) { $CredentialsPath = Get-ClaudeQuotaCredentialsPath }
        if ([string]::IsNullOrWhiteSpace($CredentialsPath) -or -not (Test-Path -LiteralPath $CredentialsPath)) { return $false }
        $credentials = $null
        try { $credentials = Get-Content -LiteralPath $CredentialsPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { return $false }
        if ($null -eq $credentials -or $null -eq $credentials.claudeAiOauth) { return $false }
        $oauth = $credentials.claudeAiOauth
        $token = [string]$oauth.accessToken
        if ([string]::IsNullOrWhiteSpace($token)) { return $false }
        $expiresAtMilliseconds = 0L
        if ($null -ne $oauth.expiresAt -and [long]::TryParse([string]$oauth.expiresAt, [ref]$expiresAtMilliseconds) -and $expiresAtMilliseconds -gt 0) {
            $expiresUtc = [DateTimeOffset]::FromUnixTimeMilliseconds($expiresAtMilliseconds).UtcDateTime
            if ($expiresUtc -le $Now.ToUniversalTime()) { return $false }
        }

        # (c) 프로브 → 헤더 파싱. 7d 값이 없거나 파싱 불가면 기존 파일을 건드리지 않는다.
        $headers = $null
        if ($null -eq $Invoker) {
            $headers = Invoke-ClaudeQuotaProbeRequest -Token $token -TimeoutSec $TimeoutSec
        } else {
            try { $headers = & $Invoker $token $TimeoutSec } catch { $headers = $null }
        }
        $parsed = ConvertFrom-ClaudeQuotaHeaders -Headers $headers
        if ($null -eq $parsed -or $null -eq $parsed.SevenDayPercent) { return $false }

        # (d) CFG124와 같은 형식 + UTF-8 무BOM + temp→Move 원자 쓰기.
        $telemetry = [ordered]@{
            sevenDayUsedPercentage = $parsed.SevenDayPercent
            fiveHourUsedPercentage = $parsed.FiveHourPercent
            observedAt             = $Now.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        }
        $parent = Split-Path -Parent $Path
        if (-not [string]::IsNullOrWhiteSpace($parent)) { New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null }
        $tempPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
        try {
            [System.IO.File]::WriteAllText($tempPath, ($telemetry | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
            Move-Item -LiteralPath $tempPath -Destination $Path -Force -ErrorAction Stop
        } catch {
            if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
            return $false
        }
        return $true
    } catch {
        return $false
    }
}

function Format-PlanningQuotaSource {
    # CFG124 P6/R2: 기획 담당 판정 출처 1줄. 포맷은 계약이다 —
    # quota-policy: [source: quota-policy weekly=<p>% cap=<c>% window=<Day>]
    # config-fallback: [source: config-fallback reason=<Reason>]
    param([object]$Resolution)
    if ($null -eq $Resolution) { return '[source: config]' }
    $culture = [Globalization.CultureInfo]::InvariantCulture
    switch ([string]$Resolution.Source) {
        'quota-policy' {
            $decision = $Resolution.QuotaDecision
            $percentText = if ($decision -and $null -ne $decision.Percent) { ([double]$decision.Percent).ToString('0.####', $culture) } else { 'unknown' }
            $capText = if ($decision -and $null -ne $decision.Cap) { ([double]$decision.Cap).ToString('0.####', $culture) } else { 'unknown' }
            $dayText = if ($decision -and $decision.WindowDay) { [string]$decision.WindowDay } else { 'unknown' }
            return "[source: quota-policy weekly=${percentText}% cap=${capText}% window=${dayText}]"
        }
        'config-fallback' {
            $reason = if ($Resolution.QuotaDecision -and $Resolution.QuotaDecision.Reason) { [string]$Resolution.QuotaDecision.Reason } else { 'unknown' }
            return "[source: config-fallback reason=${reason}]"
        }
        'local-override' { return '[source: local-override]' }
        'explicit' { return '[source: explicit]' }
        default { return '[source: config]' }
    }
}

function Resolve-RoleProfile {
    # CFG124 R1/R2: -Role planning 경로에서만 주간 쿼터 정책을 적용한다.
    # 우선순위: ExplicitProfile > 로컬 오버레이 roles.planning > 쿼터 정책 > 정본 roles.planning.
    # 패킷 Runtime Role Binding 우선은 호출부(디스패처) 몫이며 Source='packet'을 여기서 만들지 않는다.
    param(
        [ValidateSet('planning','orchestration','qa','integration')][string]$Role,
        [object]$Config,
        [string]$ExplicitProfile,
        [string[]]$LocalOverrides,
        [DateTime]$Now = (Get-Date),
        [string]$QuotaTelemetryPath
    )
    $name = if ($ExplicitProfile) { $ExplicitProfile } else { [string]$Config.roles.$Role }
    $source = if ($ExplicitProfile) { 'explicit' } else { 'config' }
    $quotaDecision = $null
    if (-not $ExplicitProfile -and $Role -eq 'planning') {
        $policy = $Config.planningQuotaPolicy
        if ($null -ne $policy -and $policy.enabled -eq $true) {
            $hasLocalOverride = @($LocalOverrides | Where-Object { $_ -like 'roles.planning=*' }).Count -gt 0
            if ($hasLocalOverride) {
                # 명시적 수동 지정은 정책보다 우선한다(P5).
                $source = 'local-override'
            } else {
                if ([string]::IsNullOrWhiteSpace($QuotaTelemetryPath)) { $QuotaTelemetryPath = Get-QuotaTelemetryPath }
                $telemetry = Read-QuotaTelemetry -Path $QuotaTelemetryPath
                $percent = if ($telemetry) { $telemetry.SevenDayPercent } else { $null }
                $observedAt = if ($telemetry) { $telemetry.ObservedAt } else { $null }
                $quotaDecision = Get-QuotaPlanningDecision -Policy $policy -SevenDayPercent $percent -ObservedAt $observedAt -Now $Now
                if ($quotaDecision.Source -eq 'quota-policy' -and $quotaDecision.Profile) {
                    $source = 'quota-policy'
                    $name = [string]$quotaDecision.Profile
                } else {
                    $source = 'config-fallback'
                }
            }
        }
    }
    $profile = $Config.profiles.$name
    if ($null -eq $profile) { throw "Unknown profile: $name" }
    return [pscustomobject]@{
        Name             = $name
        Adapter          = [string]$profile.adapter
        Family           = [string]$profile.family
        Model            = [string]$profile.model
        FallbackProfiles = @($profile.fallbackProfiles)
        Source           = $source
        QuotaDecision    = $quotaDecision
    }
}

function Resolve-ProfileChain {
    param([string]$ProfileName, [object]$Config)
    $visited = @{}
    $chain = @()
    $visit = {
        param([string]$name)
        if ($visited.ContainsKey($name)) { return }
        $visited[$name] = $true
        $p = $Config.profiles.$name
        if ($null -eq $p) { return }
        $script:resolvedProfileChain += $name
        foreach ($fb in @($p.fallbackProfiles)) {
            & $visit ([string]$fb)
        }
    }
    $script:resolvedProfileChain = @()
    & $visit $ProfileName
    return $script:resolvedProfileChain
}

function Resolve-PipelineRouting {
    param(
        [object]$Config,
        [string]$PlanningProfile,
        [string]$PlanningAdapter,
        [string]$QaProfile,
        [string]$QaAdapter,
        [string]$IntegrationProfile,
        [string]$IntegrationAdapter,
        [string]$ImplementationRoute
    )
    $planner = $Config.profiles.$PlanningProfile
    if ($null -eq $planner) { throw "Unknown actual planning profile: $PlanningProfile" }
    if ($planner.adapter -ne $PlanningAdapter) { throw "Actual planning adapter does not match profile: $PlanningProfile" }
    $route = $Config.plannerRouting.$PlanningAdapter
    if ($null -eq $route) { throw "No downstream route for planner adapter: $PlanningAdapter" }

    $qaProfileName = if ($QaProfile) { $QaProfile } elseif ($Config.roles.qa) { [string]$Config.roles.qa } else { [string]$route.qaProfile }
    $integrationProfileName = if ($IntegrationProfile) { $IntegrationProfile } elseif ($Config.roles.integration) { [string]$Config.roles.integration } else { [string]$route.integrationProfile }
    $routeName = if ($ImplementationRoute) { $ImplementationRoute } elseif ($Config.roles.impl) { [string]$Config.roles.impl } else { [string]$route.implementationRoute }

    if ($null -eq $Config.routes.$routeName) { throw "Unknown implementation route: $routeName" }
    # CFG096: 라우터 다음 단계 라벨이 구현 담당팀을 유도할 수 있도록 구현 슬롯의 어댑터를
    # 함께 반환한다. modelCatalog에 adapter가 없으면 하네스 기본 실행 어댑터(opencode)로 둔다.
    $implModels = @($Config.routes.$routeName)
    $implFirstModelForAdapter = if ($implModels.Count -gt 0) { [string]$implModels[0] } else { '' }
    $implAdapter = 'opencode'
    if ($implFirstModelForAdapter -and $Config.modelCatalog.$implFirstModelForAdapter -and $Config.modelCatalog.$implFirstModelForAdapter.adapter) {
        $implAdapter = [string]$Config.modelCatalog.$implFirstModelForAdapter.adapter
    }
    $qa = Resolve-RoleProfile -Role qa -Config $Config -ExplicitProfile $qaProfileName
    $integration = Resolve-RoleProfile -Role integration -Config $Config -ExplicitProfile $integrationProfileName
    if ($QaAdapter -and $qa.Adapter -ne $QaAdapter) {
        throw "Actual QA adapter does not match profile: $qaProfileName"
    }
    if ($IntegrationAdapter -and $integration.Adapter -ne $IntegrationAdapter) {
        throw "Actual Integration adapter does not match profile: $integrationProfileName"
    }

    foreach ($m in @($Config.routes.$routeName)) {
        $mFamily = if ($Config.modelCatalog.$m) { [string]$Config.modelCatalog.$m.family } else { '' }
        if ($mFamily -ne '' -and $mFamily -ne 'unknown' -and $mFamily -eq $qa.Family) {
            throw "Implementation model $m (family=$mFamily) shares family with QA profile $($qa.Name) (family=$($qa.Family)) — must violation"
        }
    }
    if ($qa.Family -eq $planner.family) {
        Write-Warning "Planner $PlanningAdapter uses same-family QA profile $($qa.Name) (prefer violation)"
    }
    return [pscustomobject]@{ PlanningProfile = $PlanningProfile; PlanningAdapter = $PlanningAdapter; ImplementationRoute = $routeName; ImplementationAdapter = $implAdapter; ImplementationModels = @($Config.routes.$routeName); QaProfile = $qa; IntegrationProfile = $integration }
}

# CFG028 / CFG054: Antigravity 프로젝트 ID 해석 단일 정본 구현.
# projects/*.json 에서 RepositoryRoot 와 일치하는 매핑을 탐색한다.
# 결정성을 위해 파일명 순(Sort-Object Name)으로 정렬하고, 다중 매핑 시 WARN 경고를 남긴다.
function Resolve-AntigravityProjectId {
    param([string]$RepositoryRoot)
    if (-not $env:USERPROFILE) { throw 'Antigravity project resolution requires USERPROFILE.' }
    $projectsDir = Join-Path $env:USERPROFILE '.gemini\config\projects'
    if (-not (Test-Path -LiteralPath $projectsDir)) { throw "Antigravity projects directory not found: $projectsDir" }
    $wanted = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\').Replace('\','/').ToLowerInvariant()
    $matchedProjects = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $projectsDir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        try { $project = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        foreach ($resource in @($project.projectResources.resources)) {
            $uri = if ($resource.folderUri) { [string]$resource.folderUri } elseif ($resource.gitFolder.folderUri) { [string]$resource.gitFolder.folderUri } else { '' }
            if (-not $uri.StartsWith('file:', [StringComparison]::OrdinalIgnoreCase)) { continue }
            $decoded = [Uri]::UnescapeDataString(($uri -replace '^file:/+', ''))
            $candidate = $decoded.TrimEnd('/').ToLowerInvariant()
            if ($candidate -eq $wanted) {
                $id = [string]$project.id
                if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,127}$') { throw "Invalid Antigravity project id in $($file.FullName)" }
                $matchedProjects += [pscustomobject]@{ Id = $id; File = $file.Name; FullPath = $file.FullName }
                break
            }
        }
    }
    if ($matchedProjects.Count -eq 0) {
        throw "No Antigravity project maps repository '$RepositoryRoot'. Run 'agy --new-project' from that repository root after explicit user approval."
    }
    if ($matchedProjects.Count -gt 1) {
        $candidateList = ($matchedProjects | ForEach-Object { "$($_.Id) ($($_.File))" }) -join ', '
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log "Multiple Antigravity projects ($($matchedProjects.Count)) map '$RepositoryRoot': $candidateList - using first ($($matchedProjects[0].Id))" WARN
        }
        Write-Warning "Multiple Antigravity projects ($($matchedProjects.Count)) map '$RepositoryRoot': $candidateList - using first ($($matchedProjects[0].Id))"
    }
    return $matchedProjects[0].Id
}

function Get-AdapterExecutable {
    param([ValidateSet('claude','codex','opencode','gemini','antigravity')][string]$Adapter)
    switch ($Adapter) {
        'antigravity' { return 'agy' }
        'claude' { return 'claude' }
        'codex' { return 'codex' }
        'opencode' { return 'opencode' }
        'gemini' { return 'gemini' }
    }
}

# CFG054: 어댑터 실행 플래그 단일 테이블(SSOT).
# 프롬프트 자리에 '<PROMPT>' 센티널 토큰을 포함한 argv 배열을 반환한다.
# orchestrate-packet(ConvertTo-CoordinatorArgv), model-profile(Build-AntigravityCommand),
# dispatch-with-hang-detect(Build-ToolCommand) 세 소비자가 이 공용 테이블을 공유한다.
# (opencode: 'opencode run --pure --auto' allow-all 승인 계약을 고정한다)
function Get-AdapterInvocationArgv {
    param(
        [ValidateSet('claude','codex','opencode','gemini','antigravity')][string]$Adapter,
        [string]$Model,
        [string]$ReportFile,
        [string]$ProjectId,
        [string]$PrintTimeout = '25m'
    )
    switch ($Adapter) {
        'antigravity' {
            if ([string]::IsNullOrWhiteSpace($ProjectId)) { throw 'Antigravity ProjectId is required.' }
            $argv = @('--project', $ProjectId, '--model', $Model)
            $argv += @('--mode', 'accept-edits', '--dangerously-skip-permissions', '--output-format', 'stream-json', '--print-timeout', $PrintTimeout, '--print', '<PROMPT>')
            return @($argv)
        }
        'claude' {
            return @('-p', '<PROMPT>', '--model', $Model, '--output-format', 'stream-json', '--verbose', '--dangerously-skip-permissions')
        }
        'codex' {
            return @('exec', '<PROMPT>', '-m', $Model, '-s', 'danger-full-access', '-o', $ReportFile)
        }
        'opencode' {
            return @('run', '--pure', '--auto', '-m', $Model, '<PROMPT>')
        }
        'gemini' {
            return @('--approval-mode', 'yolo', '-m', $Model, '<PROMPT>')
        }
    }
    throw "Unsupported adapter: $Adapter"
}

function ConvertTo-DriverQuoted { param([string]$Text) return '"' + ($Text -replace '"', '\"') + '"' }

# bash 작은따옴표 리터럴로 감싼다 — 프롬프트·실행 파일 경로 안의 $·백틱·"가 bash에서 확장되지
# 않도록. dispatch-with-hang-detect.ps1 의 ConvertTo-BashSingleQuoted 와 같은 구현이며,
# model-profile.ps1 이 단독으로 dot-source 되는 컨텍스트(테스트)에서도 antigravity 커맨드 빌더가
# 자립하도록 여기에도 정의해 둔다.
function ConvertTo-BashSingleQuoted {
    param([string]$Text)
    return "'" + ($Text -replace "'", "'\''") + "'"
}

# CFG046 R11 / CFG054: Antigravity(agy) 커맨드는 Get-AdapterInvocationArgv 공용 테이블을 bash 문자열로 렌더링한다.
# 프로젝트 매핑(ProjectId)이 없으면 agy 는 헤드리스 디스패치에서 실행 불가하므로 즉시 실패한다.
function Build-AntigravityCommand {
    param([string]$Model, [string]$Prompt, [string]$ProjectId, [string]$Executable, [string]$PrintTimeout = '25m')
    $argv = Get-AdapterInvocationArgv -Adapter 'antigravity' -Model $Model -ProjectId $ProjectId -PrintTimeout $PrintTimeout
    $agyBase = if ([string]::IsNullOrWhiteSpace($Executable)) { 'agy' } else { ConvertTo-BashSingleQuoted ([string]$Executable).Replace('\','/') }
    $quotedPrompt = ConvertTo-BashSingleQuoted $Prompt
    $tailTokens = @()
    for ($i = 0; $i -lt $argv.Count; $i++) {
        $tok = $argv[$i]
        if ($tok -eq '<PROMPT>') {
            $tailTokens += $quotedPrompt
        } else {
            $tailTokens += $tok
        }
    }
    $joined = $tailTokens -join ' '
    return "$agyBase $joined"
}
