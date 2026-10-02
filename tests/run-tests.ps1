$ErrorActionPreference = 'Stop'

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) {
    throw $Message
  }
}

$repoRoot = Split-Path $PSScriptRoot -Parent
$checker = Join-Path $repoRoot 'scripts\check-deployment-readiness.ps1'
$fakeAz = Join-Path $PSScriptRoot 'fake-az.ps1'
$canary = Join-Path $repoRoot 'scripts\run-canary-deployments.ps1'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "readiness-validator-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $tempRoot | Out-Null

function Invoke-TestRun {
  param(
    [Parameter(Mandatory)][object]$Config,
    [Parameter(Mandatory)][string]$Name,
    [string]$Scenario = 'ready'
  )

  $runDirectory = Join-Path $tempRoot $Name
  $artifactDirectory = Join-Path $runDirectory 'artifacts'
  $configPath = Join-Path $runDirectory 'config.json'
  $logPath = Join-Path $runDirectory 'az.log'
  New-Item -ItemType Directory -Path $runDirectory | Out-Null
  $Config | ConvertTo-Json -Depth 20 | Set-Content -Path $configPath
  $env:FAKE_AZ_LOG = $logPath
  $env:FAKE_AZ_SCENARIO = $Scenario

  $output = & pwsh -NoProfile -File $checker -ConfigPath $configPath -ArtifactDirectory $artifactDirectory -AzCommand $fakeAz 2>&1
  return [pscustomobject]@{
    ExitCode = $LASTEXITCODE
    Output = $output -join [Environment]::NewLine
    Log = if (Test-Path $logPath) { Get-Content $logPath -Raw } else { '' }
    Artifacts = $artifactDirectory
  }
}

function Invoke-CanaryTest {
  param(
    [string]$Name, [string]$Scenario = 'canary-success', [switch]$Execute,
    [object]$Config, [object[]]$Results, [switch]$Mismatch
  )
  $runDirectory = Join-Path $tempRoot $Name
  New-Item -ItemType Directory -Path $runDirectory | Out-Null
  $configPath = Join-Path $runDirectory 'config.json'
  $artifactDirectory = Join-Path $runDirectory 'artifacts'
  New-Item -ItemType Directory -Path $artifactDirectory | Out-Null
  $Config | ConvertTo-Json -Depth 30 | Set-Content $configPath
  $hash = (Get-FileHash $configPath).Hash
  $Results = $Results | ConvertTo-Json -Depth 30 | ConvertFrom-Json
  foreach ($row in $Results) {
    $row | Add-Member subscriptionId '00000000-0000-0000-0000-000000000000' -Force
    $row | Add-Member configurationHash $(if ($Mismatch) { 'wrong-hash' } else { $hash }) -Force
  }
  $readinessPath = Join-Path $artifactDirectory 'deployment-readiness-fixture.json'
  ConvertTo-Json -InputObject @($Results) -Depth 30 | Set-Content $readinessPath
  $env:FAKE_AZ_LOG = Join-Path $runDirectory 'az.log'
  $env:FAKE_AZ_SCENARIO = $Scenario
  $arguments = @('-NoProfile', '-File', $canary, '-ConfigPath', $configPath, '-ArtifactDirectory', $artifactDirectory,
    '-AzCommand', $fakeAz, '-PollIntervalSeconds', '0')
  if ($Execute) { $arguments += '-Execute' }
  $output = & pwsh @arguments 2>&1
  $code = $LASTEXITCODE
  $reportFile = Get-ChildItem $artifactDirectory -Filter 'subscription-readiness-*.json' | Select-Object -First 1
  $state = if (Test-Path "$($env:FAKE_AZ_LOG).state.json") { Get-Content "$($env:FAKE_AZ_LOG).state.json" -Raw | ConvertFrom-Json } else { $null }
  return [pscustomobject]@{
    ExitCode = $code; Output = $output -join "`n"; Log = Get-Content $env:FAKE_AZ_LOG -Raw
    Report = Get-Content $reportFile.FullName -Raw | ConvertFrom-Json
    ReportText = (Get-ChildItem $artifactDirectory -Filter 'subscription-readiness-*' | Get-Content -Raw) -join "`n"
    Templates = if (Test-Path "$($env:FAKE_AZ_LOG).templates.jsonl") { @(Get-Content "$($env:FAKE_AZ_LOG).templates.jsonl" | ConvertFrom-Json) } else { @() }
    State = $state
  }
}

try {
  $sample = Get-Content (Join-Path $repoRoot 'readiness-config.sample.json') -Raw | ConvertFrom-Json
  $sample.locations = @('eastus')

  $ready = Invoke-TestRun -Config $sample -Name 'ready'
  Assert-True ($ready.ExitCode -eq 0) "Expected ready scenario exit 0, got $($ready.ExitCode).`n$($ready.Output)"
  Assert-True ($ready.Log -match 'postgres flexible-server list-skus .*--only-show-errors') 'PostgreSQL SKU lookup did not use --only-show-errors.'
  Assert-True ($ready.Log -match 'Microsoft.DBforPostgreSQL/locations/eastus/resourceType/flexibleServers/usages\?api-version=2024-11-01-preview') 'PostgreSQL did not use the Flexible Server usages API.'
  Assert-True ($ready.Log -match 'Microsoft.Search/locations/eastus/usages\?api-version=2025-05-01') 'AI Search did not use the regional usages API.'
  Assert-True ($ready.Log -match 'Microsoft.Cache/skus\?api-version=2025-04-01') 'Managed Redis did not use the SKU API.'
  Assert-True ($ready.Log -notmatch '(?m)^quota ') 'Service-specific checks incorrectly invoked az quota.'
  Assert-True ($ready.Log -notmatch 'search service list-sku') 'AI Search invoked the nonexistent list-sku command.'
  Assert-True ($ready.Log -notmatch 'extension show --name quota') 'Service-specific checks incorrectly required the quota extension.'

  $jsonArtifact = Get-ChildItem $ready.Artifacts -Filter '*.json' | Select-Object -First 1
  $markdownArtifact = Get-ChildItem $ready.Artifacts -Filter '*.md' | Select-Object -First 1
  $results = @(Get-Content $jsonArtifact.FullName -Raw | ConvertFrom-Json)
  Assert-True (@($results | Where-Object { $_.name -eq 'PostgreSQL Flexible Server General Purpose vCores' -and $_.status -eq 'ready' }).Count -eq 1) 'PostgreSQL prefixed SKU was not accepted.'
  Assert-True (@($results | Where-Object { $_.name -eq 'Azure OpenAI' -and $_.status -eq 'ready' }).Count -eq 1) 'Azure OpenAI case-insensitive location or model quota validation failed.'
  Assert-True (@($results | Where-Object { $_.name -eq 'Azure Managed Redis' -and $_.status -eq 'ready-with-risk' }).Count -eq 1) 'Managed Redis did not return ready-with-risk.'
  Assert-True ((Get-Content $markdownArtifact.FullName -Raw) -match '`ready-with-risk` means') 'Markdown footer did not preserve literal ready-with-risk.'

  $blocked = Invoke-TestRun -Config $sample -Name 'blocked' -Scenario 'search-blocked'
  Assert-True ($blocked.ExitCode -eq 2) "Expected Azure quota blocker exit 2, got $($blocked.ExitCode)."

  $malformed = $sample | ConvertTo-Json -Depth 20 | ConvertFrom-Json
  $malformed.quotas = @([pscustomobject]@{
    name = 'Malformed PostgreSQL'
    providerNamespace = 'Microsoft.DBforPostgreSQL'
    postgresFlexibleSku = 'GP_Standard_D2ds_v5'
  })
  $invalid = Invoke-TestRun -Config $malformed -Name 'invalid'
  Assert-True ($invalid.ExitCode -eq 3) "Expected malformed configuration exit 3, got $($invalid.ExitCode)."
  Assert-True ($invalid.Output -match 'invalid-configuration') 'Malformed configuration was not identified as a checker/configuration failure.'

  $oldCli = Invoke-TestRun -Config $sample -Name 'old-cli' -Scenario 'old-cli'
  Assert-True ($oldCli.ExitCode -eq 3) "Expected unsupported CLI exit 3, got $($oldCli.ExitCode)."
  Assert-True ($oldCli.Output -match 'cli-version-unsupported') 'Minimum Azure CLI version was not enforced.'

  $providerBlocked = Invoke-TestRun -Config $sample -Name 'provider-blocked' -Scenario 'provider-blocked'
  Assert-True ($providerBlocked.ExitCode -eq 2) "Expected provider blocker exit 2, got $($providerBlocked.ExitCode)."
  Assert-True ($providerBlocked.Output -match 'provider-not-registered') 'Configured provider registration was not validated.'

  $fixtureRows = @([pscustomobject]@{ location = 'subscription'; name = 'Prerequisites'; status = 'ready'; category = 'prerequisite'; message = 'Enabled' })
  foreach ($entry in $sample.quotas) {
    $fixtureRows += [pscustomobject]@{ location = 'eastus'; name = $entry.name; status = 'ready-with-risk'; category = 'runtime-capacity-unverifiable'; message = 'Eligible' }
  }
  $dry = Invoke-CanaryTest -Name 'canary-dry' -Config $sample -Results $fixtureRows
  Assert-True ($dry.ExitCode -eq 0) "Dry run failed: $($dry.Output)"
  Assert-True ($dry.Log -notmatch 'group create|deployment group create|group delete|account purge') 'Dry run mutated Azure.'
  Assert-True (@($dry.Report.services | Where-Object canaryResult -eq 'dry-run').Count -eq 5) 'Dry run did not plan all eligible services.'

  $success = Invoke-CanaryTest -Name 'canary-success' -Config $sample -Results $fixtureRows -Execute
  Assert-True ($success.ExitCode -eq 0) "Successful canaries failed: $($success.Output)"
  Assert-True (@($success.Report.services | Where-Object finalVerdict -eq 'verified-deployable').Count -eq 5) 'Canaries were not verified.'
  Assert-True (@($success.Report.services | Where-Object cleanupResult -ne 'succeeded').Count -eq 0) 'Cleanup was not verified for every canary.'
  Assert-True ($success.Log -match 'account purge .*--location eastus' -and $success.Log -match 'account list-deleted') 'OpenAI purge was not performed and verified.'
  Assert-True (-not $success.State.groupExists -and $success.State.deleted.Count -eq 0) 'Fixture resources or soft-deleted accounts remain.'
  Assert-True ($success.Templates.Count -eq 5) 'Expected a template for every supported service.'
  $postgres = $success.Templates.resources | Where-Object type -eq 'Microsoft.DBforPostgreSQL/flexibleServers'
  Assert-True ($postgres.sku.name -eq 'Standard_D2ds_v5' -and $postgres.sku.tier -eq 'GeneralPurpose') 'PostgreSQL SKU prefix/tier was not derived.'
  Assert-True ($postgres.properties.storage.storageSizeGB -eq 32 -and $postgres.properties.network.publicNetworkAccess -eq 'Disabled' -and -not $postgres.properties.availabilityZone) 'PostgreSQL footprint/network/auto zone was incorrect.'
  $plan = $success.Templates.resources | Where-Object type -eq 'Microsoft.Web/serverfarms'
  Assert-True ($plan.sku.capacity -eq 1 -and $plan.properties.reserved) 'App Service canary was not a single Linux instance.'
  $openai = $success.Templates.resources | Where-Object type -eq 'Microsoft.CognitiveServices/accounts/deployments'
  Assert-True ($openai.properties.model.version -eq '2025-01-01' -and $openai.sku.capacity -eq 1) 'OpenAI default model version/capacity was not selected.'
  $redis = $success.Templates.resources | Where-Object type -eq 'Microsoft.Cache/redisEnterprise/databases'
  Assert-True ($redis.name -like '*/default' -and $redis.properties.clientProtocol -eq 'Encrypted') 'Managed Redis default database was omitted.'
  foreach ($password in $success.State.passwords) {
    Assert-True ($success.ReportText -notlike "*$password*" -and $success.Log -notlike "*$password*" -and $success.Output -notlike "*$password*") 'Secret leaked to report, CLI log, or console.'
  }
  $parameterMatch = [regex]::Match($success.Log, '--parameters @(.+?\.parameters\.json)')
  Assert-True (-not (Test-Path $parameterMatch.Groups[1].Value)) 'Temporary password parameter file remains.'

  $capacity = Invoke-CanaryTest -Name 'canary-capacity' -Scenario 'canary-capacity' -Config $sample -Results $fixtureRows -Execute
  Assert-True ($capacity.ExitCode -eq 2) "Capacity failures did not exit 2: $($capacity.Output)"
  Assert-True (@($capacity.Report.services | Where-Object finalVerdict -eq 'not-deployable').Count -eq 5) 'Nested capacity failures were not classified.'
  Assert-True ($capacity.Log -match 'deployment operation group list') 'Nested failed operations were not collected.'

  $cleanup = Invoke-CanaryTest -Name 'canary-cleanup' -Scenario 'canary-cleanup-error' -Config $sample -Results $fixtureRows -Execute
  Assert-True ($cleanup.ExitCode -eq 4 -and $cleanup.Report.leftoverResourceIds.Count -gt 0) 'Cleanup failure did not take priority or include leftover IDs.'
  Assert-True ($cleanup.ReportText -match 'URGENT: CLEANUP FAILED') 'Cleanup failure was not prominently reported.'

  $purge = Invoke-CanaryTest -Name 'canary-purge' -Scenario 'canary-purge-error' -Config $sample -Results $fixtureRows -Execute
  Assert-True ($purge.ExitCode -eq 4 -and @($purge.Report.services | Where-Object purgeResult -eq 'failed').Count -eq 1) 'Purge failure did not exit 4.'

  $blockedRows = $fixtureRows | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $blockedRows[1].status = 'blocked'; $blockedRows[1].message = 'App Service quota deficit'
  $skip = Invoke-CanaryTest -Name 'canary-skip' -Config $sample -Results $blockedRows -Execute
  Assert-True ($skip.ExitCode -eq 2 -and $skip.Templates.Count -eq 4) 'Blocked service was not skipped.'
  Assert-True ($skip.Report.services[0].canaryResult -eq 'skipped' -and $skip.Report.services[0].nextAction -match 'App Service') 'Skipped service did not preserve its service-specific blocker.'

  $secretFailure = Invoke-CanaryTest -Name 'canary-secret-error' -Scenario 'canary-secret-error' -Config $sample -Results $fixtureRows -Execute
  Assert-True ($secretFailure.ExitCode -eq 3 -and $secretFailure.ReportText -match '\[REDACTED\]') 'Noncapacity failures were not reviewed/redacted.'
  foreach ($password in $secretFailure.State.passwords) {
    Assert-True (-not $secretFailure.ReportText.Contains($password) -and -not $secretFailure.Output.Contains($password)) 'ARM error leaked the administrator password.'
  }

  $mismatch = Invoke-CanaryTest -Name 'canary-mismatch' -Config $sample -Results $fixtureRows -Execute -Mismatch
  Assert-True ($mismatch.ExitCode -eq 3 -and $mismatch.Log -notmatch 'group create') 'Mismatched report was allowed to deploy.'
  $existing = Invoke-CanaryTest -Name 'canary-existing' -Scenario 'canary-existing-group' -Config $sample -Results $fixtureRows -Execute
  Assert-True ($existing.ExitCode -eq 3 -and $existing.Log -notmatch 'group delete|group create') 'Existing resource group was mutated.'
  $async = Invoke-CanaryTest -Name 'canary-async' -Scenario 'canary-async' -Config $sample -Results $fixtureRows -Execute
  Assert-True ($async.ExitCode -eq 0) "Asynchronous deployment polling failed: $($async.Output)"
  $pollError = Invoke-CanaryTest -Name 'canary-poll-error' -Scenario 'canary-poll-error' -Config $sample -Results $fixtureRows -Execute
  Assert-True ($pollError.ExitCode -eq 3 -and $pollError.Log -match 'deployment group cancel' -and -not $pollError.State.groupExists) 'Polling failure did not cancel and clean up running deployments.'
  $groupError = Invoke-CanaryTest -Name 'canary-group-error' -Scenario 'canary-group-error' -Config $sample -Results $fixtureRows -Execute
  Assert-True ($groupError.ExitCode -eq 3 -and -not $groupError.State.groupExists) 'Group create error after acceptance did not trigger cleanup.'

  $ownership = Invoke-CanaryTest -Name 'canary-ownership' -Scenario 'canary-ownership-error' -Config $sample -Results $fixtureRows -Execute
  Assert-True ($ownership.ExitCode -eq 4 -and $ownership.Log -notmatch 'group delete') 'A resource group with changed ownership tags was deleted.'
  $unknownRows = $fixtureRows | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $unknownRows[0].status = 'unknown'
  $unknown = Invoke-CanaryTest -Name 'canary-unknown-prerequisite' -Config $sample -Results $unknownRows -Execute
  Assert-True ($unknown.ExitCode -eq 3 -and $unknown.Log -notmatch 'group create') 'Unknown subscription prerequisites did not prevent deployment.'
  $unknownRows = $fixtureRows | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $unknownRows[2].status = 'unknown'
  $unknown = Invoke-CanaryTest -Name 'canary-unknown-service' -Config $sample -Results $unknownRows -Execute
  Assert-True ($unknown.ExitCode -eq 3 -and $unknown.Templates.Count -eq 4 -and $unknown.Report.services[1].canaryResult -eq 'skipped') 'Unknown service was not skipped.'
  $unsupportedConfig = $sample | ConvertTo-Json -Depth 20 | ConvertFrom-Json
  $unsupportedConfig.quotas = @([pscustomobject]@{ name = 'VM quota'; vmSku = 'Standard_D2ds_v5'; providerNamespace = 'Microsoft.Compute'; requiredAvailable = 1 })
  $unsupportedRows = @($fixtureRows[0], [pscustomobject]@{ name = 'VM quota'; location = 'eastus'; status = 'ready'; message = 'Eligible' })
  $unsupported = Invoke-CanaryTest -Name 'canary-unsupported' -Config $unsupportedConfig -Results $unsupportedRows -Execute
  Assert-True ($unsupported.ExitCode -eq 0 -and $unsupported.Log -notmatch 'group create' -and $unsupported.Report.services[0].canaryResult -eq 'canary-not-supported') 'VM/generic quota entries deployed or were falsely verified.'

  $twoRegions = $sample | ConvertTo-Json -Depth 20 | ConvertFrom-Json
  $twoRegions.locations = @('eastus', 'westus3')
  $regionalRows = @($fixtureRows)
  foreach ($row in $fixtureRows | Where-Object location -eq 'eastus') {
    $regional = $row | ConvertTo-Json | ConvertFrom-Json
    $regional.location = 'westus3'; $regionalRows += $regional
  }
  $regional = Invoke-CanaryTest -Name 'canary-regions' -Config $twoRegions -Results $regionalRows -Execute
  Assert-True ($regional.ExitCode -eq 0 -and $regional.Templates.Count -eq 10) 'Readiness entries were not matched by both region and name.'
  Assert-True (@($regional.Report.services.resourceName | Select-Object -Unique).Count -eq 10) 'Canary names collided across regions.'
  Assert-True (@($regional.Report.services | Where-Object purgeResult -eq 'purged-or-absent').Count -eq 2) 'Both regional OpenAI accounts were not purged.'

  $pinnedConfig = $sample | ConvertTo-Json -Depth 20 | ConvertFrom-Json
  $pinnedConfig.quotas[2] | Add-Member azureOpenAIModelVersion '2025-11-13'
  $pinnedConfig.quotas[1].availabilityZone = '2'
  $pinned = Invoke-CanaryTest -Name 'canary-pinned' -Config $pinnedConfig -Results $fixtureRows -Execute
  Assert-True ($pinned.ExitCode -eq 0) "Pinned configuration failed: $($pinned.Output)"
  $pinnedModel = $pinned.Templates.resources | Where-Object type -eq 'Microsoft.CognitiveServices/accounts/deployments'
  $pinnedPostgres = $pinned.Templates.resources | Where-Object type -eq 'Microsoft.DBforPostgreSQL/flexibleServers'
  Assert-True ($pinnedModel.properties.model.version -eq '2025-11-13' -and $pinnedPostgres.properties.availabilityZone -eq '2') 'Explicit model version/zone was ignored.'

  Write-Host 'All deployment readiness and canary tests passed.'
} finally {
  Remove-Item -Path $tempRoot -Recurse -Force
  Remove-Item Env:FAKE_AZ_LOG -ErrorAction SilentlyContinue
  Remove-Item Env:FAKE_AZ_SCENARIO -ErrorAction SilentlyContinue
}
