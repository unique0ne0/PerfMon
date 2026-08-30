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
    foreach ($requiredAdapter in @('claude', 'codex', 'antigravity')) {
        if ($null -eq $Config.plannerRouting.$requiredAdapter) { throw "Missing planner routing for $requiredAdapter" }
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
        $unexpectedTopLevel = @($local.psobject.Properties.Name | Where-Object { $_ -notin @('roles', 'plannerRouting') })
        if ($unexpectedTopLevel.Count -gt 0) { throw "Local model profile config only permits 'roles' and 'plannerRouting'." }
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
            $forbiddenFields = @('command', 'apiKey', 'token', 'secret', 'password')
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

function Build-AdapterCommand {
    param([ValidateSet('claude','codex','opencode','gemini','antigravity')][string]$Adapter, [string]$Model, [string]$Prompt, [string]$ReportFile)
    $quotedPrompt = ConvertTo-DriverQuoted $Prompt
    switch ($Adapter) {
        'claude' { return "claude -p $quotedPrompt --model $Model --output-format stream-json --verbose --dangerously-skip-permissions" }
        'codex' { return "codex exec $quotedPrompt -m $Model -s danger-full-access -o $(ConvertTo-DriverQuoted $ReportFile)" }
        'opencode' { return "opencode run --pure --auto -m $Model $quotedPrompt" }
        'gemini' { return "gemini --approval-mode yolo -m $Model $quotedPrompt" }
        'antigravity' { return "agy --model $Model --mode accept-edits --print $quotedPrompt" }
    }
}
