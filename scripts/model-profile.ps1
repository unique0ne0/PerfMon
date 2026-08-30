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
        $lastModel = $models[-1]
        $lastCatalog = $Config.modelCatalog.$lastModel
        if ($null -eq $lastCatalog -or [string]$lastCatalog.cost -ne 'free') { throw "Route $($route.Name) last slot must be a free model." }
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
    }
}

function Read-ModelProfileConfig {
    param([string]$CentralPath, [string]$LocalPath)
    $config = Read-JsonFile -Path $CentralPath
    $graphWarnings = [System.Collections.ArrayList]@()
    Test-ProfileGraph -Config $config -Warnings $graphWarnings
    foreach ($w in $graphWarnings) { Write-Warning $w }
    $graphWarnings.Clear()
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
        }
        if ($null -ne $local.roles) {
            $unexpectedRoles = @($local.roles.psobject.Properties.Name | Where-Object { $_ -notin @('planning', 'orchestration') })
            if ($unexpectedRoles.Count -gt 0) { throw 'Local model profile config contains an unsupported role.' }
            foreach ($role in @('planning', 'orchestration')) { if ($null -ne $local.roles.$role) { $config.roles.$role = [string]$local.roles.$role } }
        }
        if ($null -ne $local.plannerRouting) {
            foreach ($adapter in @($local.plannerRouting.psobject.Properties)) {
                if ($null -eq $config.plannerRouting) { $config.plannerRouting = [pscustomobject]@{} }
                $centralRoute = $config.plannerRouting.($adapter.Name)
                if ($null -eq $centralRoute) { $config.plannerRouting | Add-Member -NotePropertyName $adapter.Name -NotePropertyValue $adapter.Value }
                else { foreach ($prop in @($adapter.Value.psobject.Properties)) { $centralRoute | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value -Force } }
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
    return $config
}

function Resolve-RoleProfile {
    param([ValidateSet('planning','orchestration')][string]$Role, [object]$Config, [string]$ExplicitProfile)
    $name = if ($ExplicitProfile) { $ExplicitProfile } else { [string]$Config.roles.$Role }
    $profile = $Config.profiles.$name
    if ($null -eq $profile) { throw "Unknown profile: $name" }
    return [pscustomobject]@{ Name = $name; Adapter = [string]$profile.adapter; Family = [string]$profile.family; Model = [string]$profile.model; FallbackProfiles = @($profile.fallbackProfiles) }
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
    param([object]$Config, [string]$PlanningProfile, [string]$PlanningAdapter)
    $planner = $Config.profiles.$PlanningProfile
    if ($null -eq $planner) { throw "Unknown actual planning profile: $PlanningProfile" }
    if ($planner.adapter -ne $PlanningAdapter) { throw "Actual planning adapter does not match profile: $PlanningProfile" }
    $route = $Config.plannerRouting.$PlanningAdapter
    if ($null -eq $route) { throw "No downstream route for planner adapter: $PlanningAdapter" }
    $qa = Resolve-RoleProfile -Role planning -Config $Config -ExplicitProfile ([string]$route.qaProfile)
    $integration = Resolve-RoleProfile -Role planning -Config $Config -ExplicitProfile ([string]$route.integrationProfile)
    $routeName = [string]$route.implementationRoute
    foreach ($m in @($Config.routes.$routeName)) {
        $mFamily = if ($Config.modelCatalog.$m) { [string]$Config.modelCatalog.$m.family } else { '' }
        if ($mFamily -ne '' -and $mFamily -ne 'unknown' -and $mFamily -eq $qa.Family) {
            throw "Implementation model $m (family=$mFamily) shares family with QA profile $($qa.Name) (family=$($qa.Family)) — must violation"
        }
    }
    if ($qa.Family -eq $planner.family) {
        Write-Warning "Planner $PlanningAdapter uses same-family QA profile $($qa.Name) (prefer violation)"
    }
    return [pscustomobject]@{ PlanningProfile = $PlanningProfile; PlanningAdapter = $PlanningAdapter; ImplementationRoute = $routeName; ImplementationModels = @($Config.routes.$routeName); QaProfile = $qa; IntegrationProfile = $integration }
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

# CFG046 R11: Antigravity(agy) 커맨드는 여기 한 곳에서만 만든다. 이 함수가
#  - dispatch-with-hang-detect.ps1 의 Build-ToolCommand (qa·integration antigravity 분기)
#  - model-profile.ps1 의 Build-AdapterCommand (antigravity 분기)
# 양쪽이 공유하는 단일 구현이다. 프로젝트 매핑(ProjectId)이 없으면 agy 는 헤드리스 디스패치에서
# 실행 불가하므로 즉시 실패한다 — 조용히 매달리지 않는다(본문 Done When 3).
# 프롬프트의 인용(작은따옴표)은 dispatch 의 bash 래퍼 규약(CFG-BL-031)을 따른다.
function Build-AntigravityCommand {
    param([string]$Model, [string]$Prompt, [string]$ProjectId, [string]$Executable, [string]$PrintTimeout = '25m')
    if ([string]::IsNullOrWhiteSpace($ProjectId)) { throw 'Antigravity ProjectId is required.' }
    $agyBase = if ([string]::IsNullOrWhiteSpace($Executable)) { 'agy' } else { ConvertTo-BashSingleQuoted ([string]$Executable).Replace('\','/') }
    # agy 는 권한 프롬프트로 단계가 멈추는 일이 잦아, 사용자 지시(2026-08-31)에 따라 항상 사용자 권한으로 실행한다.
    $effortFlag = if ($Model -eq 'gemini-3.7-flash') { ' --effort medium' } else { '' }
    $quotedPrompt = ConvertTo-BashSingleQuoted $Prompt
    return "$agyBase --project $ProjectId --model $Model$effortFlag --mode accept-edits --dangerously-skip-permissions --output-format stream-json --print-timeout $PrintTimeout --print $quotedPrompt"
}

function Build-AdapterCommand {
    param([ValidateSet('claude','codex','opencode','gemini','antigravity')][string]$Adapter, [string]$Model, [string]$Prompt, [string]$ReportFile, [string]$ProjectId)
    $quotedPrompt = ConvertTo-DriverQuoted $Prompt
    switch ($Adapter) {
        'claude' { return "claude -p $quotedPrompt --model $Model --output-format stream-json --verbose --dangerously-skip-permissions" }
        'codex' { return "codex exec $quotedPrompt -m $Model -s danger-full-access -o $(ConvertTo-DriverQuoted $ReportFile)" }
        'opencode' { return "opencode run --pure --auto -m $Model $quotedPrompt" }
        'gemini' { return "gemini --approval-mode yolo -m $Model $quotedPrompt" }
        'antigravity' { return Build-AntigravityCommand -Model $Model -Prompt $Prompt -ProjectId $ProjectId }
    }
}
