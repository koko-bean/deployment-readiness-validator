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

  Write-Host 'All deployment readiness tests passed.'
} finally {
  Remove-Item -Path $tempRoot -Recurse -Force
  Remove-Item Env:FAKE_AZ_LOG -ErrorAction SilentlyContinue
  Remove-Item Env:FAKE_AZ_SCENARIO -ErrorAction SilentlyContinue
}
