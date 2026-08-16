# Role profile resolution and command construction for the packet driver.
# This file deliberately accepts profile names, never executable command strings.

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { throw "Invalid JSON: $Path ($($_.Exception.Message))" }
}

function Test-ProfileGraph {
    param([object]$Config)
    if ($null -eq $Config -or $Config.schemaVersion -ne 2 -or $null -eq $Config.roles -or $null -eq $Config.profiles -or $null -eq $Config.routes -or $null -eq $Config.plannerRouting) { throw 'Invalid model profile schema.' }
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
    foreach ($route in @($Config.routes.psobject.Properties)) {
        $models = @($route.Value)
        if ($models.Count -eq 0 -or -not ($models -contains 'opencode/big-pickle')) { throw "Route $($route.Name) must retain opencode/big-pickle." }
        $openCodeFree = @($models | Where-Object { $_ -match '^opencode/' })
        if ($openCodeFree.Count -eq 0 -or $openCodeFree[0] -ne 'opencode/big-pickle') { throw 'Big Pickle must be the first OpenCode free fallback.' }
        if ($route.Name -eq 'independent-planned' -and $models[-1] -ne 'openai/gpt-5.6-terra') { throw 'Independent route must end with emergency GPT Terra.' }
        foreach ($model in $models) { if ([string]$model -notmatch '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$') { throw "Invalid route model: $model" } }
    }
    foreach ($adapter in @('claude', 'codex', 'gemini')) {
        $route = $Config.plannerRouting.$adapter
        $routeName = if ($route) { [string]$route.implementationRoute } else { '' }
        $qaName = if ($route) { [string]$route.qaProfile } else { '' }
        $integrationName = if ($route) { [string]$route.integrationProfile } else { '' }
        if ($null -eq $route -or $null -eq $Config.routes.$routeName -or $null -eq $Config.profiles.$qaName -or $null -eq $Config.profiles.$integrationName) { throw "Invalid planner routing for $adapter" }
        $qa = $Config.profiles.$qaName
        if ($qa.family -eq $adapter) { throw "Planner $adapter cannot use same-family QA profile $($route.qaProfile)" }
        if ($Config.profiles.$integrationName.family -ne $adapter) { throw "Planner $adapter must use its own family for Integration" }
    }
}

function Read-ModelProfileConfig {
    param([string]$CentralPath, [string]$LocalPath)
    $config = Read-JsonFile -Path $CentralPath; Test-ProfileGraph -Config $config
    $local = Read-JsonFile -Path $LocalPath
    if ($null -ne $local) {
        $unexpectedTopLevel = @($local.psobject.Properties.Name | Where-Object { $_ -ne 'roles' })
        if ($unexpectedTopLevel.Count -gt 0) { throw "Local model profile config only permits 'roles'." }
        if ($null -ne $local.roles) {
            $unexpectedRoles = @($local.roles.psobject.Properties.Name | Where-Object { $_ -notin @('planning', 'orchestration') })
            if ($unexpectedRoles.Count -gt 0) { throw 'Local model profile config contains an unsupported role.' }
            foreach ($role in @('planning', 'orchestration')) { if ($null -ne $local.roles.$role) { $config.roles.$role = [string]$local.roles.$role } }
        }
        Test-ProfileGraph -Config $config
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

function Resolve-PipelineRouting {
    param([object]$Config, [string]$PlanningProfile, [string]$PlanningAdapter)
    $planner = $Config.profiles.$PlanningProfile
    if ($null -eq $planner) { throw "Unknown actual planning profile: $PlanningProfile" }
    if ($planner.adapter -ne $PlanningAdapter) { throw "Actual planning adapter does not match profile: $PlanningProfile" }
    $route = $Config.plannerRouting.$PlanningAdapter
    if ($null -eq $route) { throw "No downstream route for planner adapter: $PlanningAdapter" }
    $qa = Resolve-RoleProfile -Role planning -Config $Config -ExplicitProfile ([string]$route.qaProfile)
    $integration = Resolve-RoleProfile -Role planning -Config $Config -ExplicitProfile ([string]$route.integrationProfile)
    if ($qa.Family -eq $planner.family) { throw "Same-family QA is forbidden for planner: $PlanningAdapter" }
    $routeName = [string]$route.implementationRoute
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
