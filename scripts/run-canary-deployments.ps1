param(
  [string]$ConfigPath = 'readiness-config.json',
  [string]$ReadinessReport,
  [string]$ArtifactDirectory = 'artifacts\deployment-readiness',
  [string]$AzCommand = 'az',
  [switch]$Execute,
  [ValidateRange(1, 1440)][int]$TimeoutMinutes = 60,
  [string]$ResourceGroupName,
  [ValidateRange(0, 60)][int]$PollIntervalSeconds = 10
)

$ErrorActionPreference = 'Stop'
$started = [DateTime]::UtcNow
$runId = $started.ToString('yyyyMMdd-HHmmss') + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 10))
$secrets = [System.Collections.Generic.List[string]]::new()
$services = [System.Collections.Generic.List[object]]::new()
$cleanupErrors = [System.Collections.Generic.List[string]]::new()
$runErrors = [System.Collections.Generic.List[string]]::new()
$leftovers = [System.Collections.Generic.List[string]]::new()
$groupAttempted = $false
$temporaryDirectory = $null
$subscriptionId = $null
$prerequisites = @()
$locations = @()

function Protect-Message([string]$Text) {
  foreach ($secret in $secrets) { $Text = $Text.Replace($secret, '[REDACTED]') }
  return $Text -replace '(?i)("?(?:administratorLoginPassword|password|accessToken|apiKey)"?\s*[:=]\s*)"[^"]*"', '$1"[REDACTED]"'
}

function Invoke-CanaryAz([string[]]$Arguments) {
  $argumentsWithContext = $Arguments + @('--only-show-errors', '--output', 'json')
  if ($subscriptionId) { $argumentsWithContext += @('--subscription', $subscriptionId) }
  $output = & $AzCommand @argumentsWithContext 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw (Protect-Message ($output -join [Environment]::NewLine))
  }
  $text = ($output -join [Environment]::NewLine).Trim()
  if ($text) { return ($text | ConvertFrom-Json) }
}

function Get-FailureVerdict([string]$Text) {
  if ($Text -match '(?i)\b(QuotaExceeded|InsufficientQuota|SubscriptionQuotaExceeded|ResourceQuotaExceeded|CapacityUnavailable|InsufficientCapacity|CapacityExceeded|SkuNotAvailable|AllocationFailed|ZonalAllocationFailed|InsufficientResources|LocationNotAvailableForResourceType|RegionNotAvailable)\b' -or
    $Text -match '(?i)"code"\s*:\s*"[^"]*(Quota|Capacity)[^"]*"' -or
    $Text -match '(?i)(\((Quota|Capacity)[A-Za-z]*\)|Code:\s*[A-Za-z]*(Quota|Capacity)[A-Za-z]*)') {
    return 'not-deployable'
  }
  return 'needs-review'
}

function Get-NextAction($Service) {
  if ($Service.finalVerdict -eq 'verified-deployable') { return 'Proceed with deployment planning; recheck quota and full-scale capacity before rollout.' }
  if ($Service.cleanupResult -eq 'failed') { return 'URGENT: remove the listed leftover resources and purge soft-deleted OpenAI accounts.' }
  if ($Service.finalVerdict -eq 'needs-review') { return 'Review the ARM error and permissions with the platform team; open an Azure support request if unresolved.' }
  if ($Service.finalVerdict -eq 'not-tested') { return 'Resolve unknown prerequisites or run the opt-in canary stage; generic and VM quota entries require a separate deployment test.' }
  if ($Service.message -match '(?i)restrict|RegionNotAvailable|LocationNotAvailable') { return 'Choose an alternate region or open an Azure support request for the regional subscription restriction.' }
  if ($Service.message -match '(?i)quota') {
    switch ($Service.serviceType) {
      'app-service' { return 'Request regional App Service plan quota through Azure Help + support, then rerun readiness.' }
      'postgresql' { return 'Request PostgreSQL Flexible Server regional vCore quota through Azure Help + support, then rerun readiness.' }
      'openai' { return 'Request the model/deployment-type quota through Azure AI Foundry quota management, then rerun readiness.' }
      'search' { return 'Request Azure AI Search regional service-count quota through Azure Help + support, then rerun readiness.' }
      default { return 'Use the service-specific quota/support path, then rerun readiness.' }
    }
  }
  return 'Choose an alternate region/SKU or request Azure support for the allocation failure.'
}

function New-CanaryTemplate($Service, $Entry) {
  $name = $Service.resourceName
  $location = $Service.location
  $resources = @()
  $parameters = @{}
  switch ($Service.serviceType) {
    'app-service' {
      if (-not $Entry.appServicePlanTier) { throw 'appServicePlanTier is required for an App Service canary.' }
      $resources += @{
        type = 'Microsoft.Web/serverfarms'; apiVersion = '2024-11-01'; name = $name; location = $location; kind = 'linux'
        sku = @{ name = $Entry.appServicePlanSku; tier = $Entry.appServicePlanTier; capacity = 1 }
        properties = @{ reserved = $true }
      }
    }
    'postgresql' {
      if ($Entry.postgresFlexibleSku -notmatch '^(GP|MO|B)_(.+)$') { throw 'postgresFlexibleSku must use a GP_, MO_, or B_ prefix.' }
      $tier = @{ GP = 'GeneralPurpose'; MO = 'MemoryOptimized'; B = 'Burstable' }[$Matches[1]]
      $sku = $Matches[2]
      $parameters = @{ administratorPassword = @{ type = 'secureString' } }
      $properties = @{
        administratorLogin = 'canaryadmin'; administratorLoginPassword = "[parameters('administratorPassword')]"
        version = '16'; createMode = 'Default'; storage = @{ storageSizeGB = 32 }
        highAvailability = @{ mode = 'Disabled' }; network = @{ publicNetworkAccess = 'Disabled' }
        backup = @{ backupRetentionDays = 7; geoRedundantBackup = 'Disabled' }
      }
      if ($Entry.availabilityZone -and $Entry.availabilityZone -ne 'auto') { $properties.availabilityZone = [string]$Entry.availabilityZone }
      $resources += @{
        type = 'Microsoft.DBforPostgreSQL/flexibleServers'; apiVersion = '2024-08-01'; name = $name; location = $location
        sku = @{ name = $sku; tier = $tier }; properties = $properties
      }
    }
    'openai' {
      if (-not $Entry.azureOpenAIModel -or -not $Entry.azureOpenAIDeploymentType) { throw 'OpenAI model and deployment type are required.' }
      $catalog = Invoke-CanaryAz @('rest', '--method', 'get', '--uri',
        "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.CognitiveServices/locations/$location/models?api-version=2025-06-01")
      $models = @($catalog.value | Where-Object {
        $_.kind -eq 'OpenAI' -and $_.skuName -eq $Entry.azureOpenAISku -and $_.model.name -eq $Entry.azureOpenAIModel -and
        @($_.model.skus | Where-Object name -eq $Entry.azureOpenAIDeploymentType).Count -gt 0
      })
      if ($Entry.azureOpenAIModelVersion) {
        $models = @($models | Where-Object { $_.model.version -eq $Entry.azureOpenAIModelVersion })
      }
      $model = $models | Sort-Object @{ Expression = { $_.model.isDefaultVersion -eq $true }; Descending = $true }, @{ Expression = { $_.model.version }; Descending = $true } | Select-Object -First 1
      if (-not $model) { throw 'No compatible OpenAI model version was returned for this account SKU and deployment type.' }
      $modelSku = $model.model.skus | Where-Object name -eq $Entry.azureOpenAIDeploymentType | Select-Object -First 1
      if ($modelSku.capacity.minimum -gt 1) { throw 'The selected OpenAI deployment type requires capacity greater than 1; it is not a minimal canary.' }
      $Service.modelVersion = [string]$model.model.version
      $resources += @{
        type = 'Microsoft.CognitiveServices/accounts'; apiVersion = '2025-06-01'; name = $name; location = $location
        kind = 'OpenAI'; sku = @{ name = $Entry.azureOpenAISku }
        properties = @{ customSubDomainName = $name; publicNetworkAccess = 'Disabled'; disableLocalAuth = $true }
      }
      $resources += @{
        type = 'Microsoft.CognitiveServices/accounts/deployments'; apiVersion = '2025-06-01'; name = "$name/canary"
        dependsOn = @("[resourceId('Microsoft.CognitiveServices/accounts', '$name')]")
        sku = @{ name = $Entry.azureOpenAIDeploymentType; capacity = 1 }
        properties = @{ model = @{ format = 'OpenAI'; name = $Entry.azureOpenAIModel; version = $Service.modelVersion } }
      }
    }
    'search' {
      $resources += @{
        type = 'Microsoft.Search/searchServices'; apiVersion = '2025-05-01'; name = $name; location = $location
        sku = @{ name = $Entry.aiSearchSku }
        properties = @{ replicaCount = 1; partitionCount = 1; publicNetworkAccess = 'disabled'; disableLocalAuth = $true }
      }
    }
    'redis' {
      $resources += @{
        type = 'Microsoft.Cache/redisEnterprise'; apiVersion = '2025-04-01'; name = $name; location = $location
        sku = @{ name = $Entry.redisEnterpriseSku }
        properties = @{ highAvailability = 'Disabled'; minimumTlsVersion = '1.2' }
      }
      $resources += @{
        type = 'Microsoft.Cache/redisEnterprise/databases'; apiVersion = '2025-04-01'; name = "$name/default"
        dependsOn = @("[resourceId('Microsoft.Cache/redisEnterprise', '$name')]")
        properties = @{
          clientProtocol = 'Encrypted'; clusteringPolicy = 'OSSCluster'; evictionPolicy = 'VolatileLRU'
          accessKeysAuthentication = 'Disabled'; port = 10000
        }
      }
    }
  }
  return @{
    '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
    contentVersion = '1.0.0.0'; parameters = $parameters; resources = $resources
  }
}

function Get-DeploymentFailure($Service, $Deployment) {
  $details = @($Deployment.properties.error | ConvertTo-Json -Depth 30 -Compress)
  try {
    $operations = @(Invoke-CanaryAz @('deployment', 'operation', 'group', 'list', '--resource-group', $ResourceGroupName, '--name', $Service.deploymentName))
    foreach ($operation in $operations) {
      if ($operation.properties.provisioningState -eq 'Failed') {
        $details += $operation.properties.statusMessage | ConvertTo-Json -Depth 30 -Compress
      }
    }
  } catch { $details += "Failed to collect deployment operations: $_" }
  return Protect-Message ($details -join '; ')
}

function Test-GroupExists {
  $exists = Invoke-CanaryAz @('group', 'exists', '--name', $ResourceGroupName)
  if ($exists -isnot [bool]) { throw 'Resource group existence query did not return a boolean.' }
  return $exists
}

try {
  $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
  $configurationHash = (Get-FileHash -LiteralPath $ConfigPath -Algorithm SHA256).Hash
  $locations = @(if ($config.locations) { $config.locations } else { $config.location })
  if (-not $locations.Count -or -not $config.quotas) { throw 'Configure locations and quotas before running canaries.' }
  if (@($config.quotas | Where-Object { [string]::IsNullOrWhiteSpace($_.name) }).Count) { throw 'Every config quota entry must have a nonblank name.' }
  if (@($config.quotas | Group-Object name | Where-Object Count -gt 1).Count) { throw 'Config quota names must be unique.' }
  if (-not $ReadinessReport) {
    $ReadinessReport = (Get-ChildItem -LiteralPath $ArtifactDirectory -Filter 'deployment-readiness-*.json' |
      Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).FullName
  }
  if (-not $ReadinessReport) { throw 'No readiness report found. Run check-deployment-readiness.ps1 first.' }
  $readiness = @(Get-Content -LiteralPath $ReadinessReport -Raw | ConvertFrom-Json)
  $prerequisites = @($readiness | Where-Object location -eq 'subscription')
  $account = Invoke-CanaryAz @('account', 'show')
  $subscriptionId = [string]$account.id
  if (-not $subscriptionId -or $account.state -ne 'Enabled') { throw 'An enabled Azure subscription is required.' }
  if ($config.subscriptionId -and $config.subscriptionId -ne $subscriptionId) { throw 'Config subscription does not match the active Azure subscription.' }
  if ($Execute -and (-not $readiness.Count -or @($readiness | Where-Object {
    $_.subscriptionId -ne $subscriptionId -or $_.configurationHash -ne $configurationHash
  }).Count)) { throw 'Readiness provenance is missing or differs from the subscription/configuration. Rerun readiness with this version of the checker.' }
  if (-not $ResourceGroupName) { $ResourceGroupName = "rg-readiness-canary-$runId" }
  if ($ResourceGroupName -notmatch '^[a-zA-Z0-9_-]{1,90}$') { throw 'Use a resource group name containing only letters, digits, underscores, and hyphens (maximum 90 characters).' }

  $index = 0
  foreach ($location in @($locations | Select-Object -Unique)) {
    if ([string]::IsNullOrWhiteSpace($location)) { throw 'Region names must not be blank.' }
    foreach ($entry in $config.quotas) {
      $index++
      $type = if ($entry.appServicePlanSku) { 'app-service' } elseif ($entry.postgresFlexibleSku) { 'postgresql' } elseif ($entry.azureOpenAISku) { 'openai' } elseif ($entry.aiSearchSku) { 'search' } elseif ($entry.redisEnterpriseSku) { 'redis' } else { 'unsupported' }
      $matchesForService = @($readiness | Where-Object { $_.name -eq $entry.name -and $_.location -eq $location })
      $result = if ($matchesForService.Count -eq 1) { $matchesForService[0] } else { $null }
      $status = if ($result -and $result.status -in @('ready', 'ready-with-risk', 'blocked', 'unknown')) { $result.status } else { 'unknown' }
      $resourceName = "canary-$($runId.Replace('-', ''))-$index"
      $resourceType = @{ 'app-service' = 'Microsoft.Web/serverfarms'; postgresql = 'Microsoft.DBforPostgreSQL/flexibleServers'; openai = 'Microsoft.CognitiveServices/accounts'; search = 'Microsoft.Search/searchServices'; redis = 'Microsoft.Cache/redisEnterprise' }[$type]
      $service = [pscustomobject]@{
        name = [string]$entry.name; location = [string]$location; serviceType = $type
        readinessStatus = $status; readinessCategory = $result.category
        canaryResult = 'skipped'; cleanupResult = 'not-required'; purgeResult = 'not-required'
        finalVerdict = 'not-tested'; nextAction = ''; message = if ($result) { [string]$result.message } else { 'Missing or ambiguous readiness result.' }
        resourceName = $resourceName; resourceIds = @(); resourceCleanup = @(); deploymentName = "canary-$index"; modelVersion = $null
        attempted = $false
      }
      if ($type -eq 'unsupported') { $service.canaryResult = 'canary-not-supported' }
      if ($status -eq 'blocked') { $service.finalVerdict = 'not-deployable' }
      elseif ($status -eq 'unknown') { $service.finalVerdict = 'needs-review' }
      elseif ($type -ne 'unsupported') {
        if ($prerequisites.Count -eq 0 -or @($prerequisites | Where-Object status -notin @('ready', 'ready-with-risk')).Count) {
          $service.message = 'Subscription prerequisites are missing, blocked, or unknown; canary skipped.'
          $service.finalVerdict = 'needs-review'
        } else {
          $service.canaryResult = if ($Execute) { 'planned' } else { 'dry-run' }
          $service.resourceIds = @("/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers/$resourceType/$resourceName")
          if ($type -eq 'openai') { $service.resourceIds += "$($service.resourceIds[0])/deployments/canary" }
          if ($type -eq 'redis') { $service.resourceIds += "$($service.resourceIds[0])/databases/default" }
        }
      }
      $services.Add($service)
    }
  }
  $services | Format-Table location, name, readinessStatus, canaryResult -AutoSize | Out-Host
  $planned = @($services | Where-Object canaryResult -eq 'planned')
  if ($Execute -and $planned.Count) {
    if (Test-GroupExists) { throw 'Refusing to use or delete an existing resource group. Choose a new temporary name.' }
    New-Item -ItemType Directory -Path $ArtifactDirectory -Force | Out-Null
    $recoveryPath = Join-Path $ArtifactDirectory "canary-recovery-$runId.json"
    @{
      subscriptionId = $subscriptionId; runId = $runId; startedAt = $started.ToString('o')
      resourceGroupName = $ResourceGroupName
      resources = @($planned | Select-Object location, serviceType, resourceName, resourceIds)
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $recoveryPath -Encoding utf8
    Write-Host "Temporary resource group: $ResourceGroupName (subscription $subscriptionId)"
    Write-Host "Recovery inventory: $recoveryPath"
    $temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "readiness-canary-$runId"
    New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null
    if ($IsWindows) {
      $acl = Get-Acl -LiteralPath $temporaryDirectory
      $acl.SetAccessRuleProtection($true, $false)
      $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
      $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
      Set-Acl -LiteralPath $temporaryDirectory -AclObject $acl
    } else { & chmod 700 $temporaryDirectory; if ($LASTEXITCODE -ne 0) { throw 'Failed to restrict temporary directory permissions.' } }
    # Arm cleanup before submission: a CLI error can occur after Azure has accepted the create.
    $groupAttempted = $true
    $null = Invoke-CanaryAz @('group', 'create', '--name', $ResourceGroupName, '--location', $locations[0], '--tags',
      'purpose=deployment-readiness-canary', 'createdBy=deployment-readiness-validator', "runId=$runId", "expiresAt=$($started.AddMinutes($TimeoutMinutes * 2).ToString('o'))")
    $deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
    foreach ($service in $planned) {
      $parameterPath = $null
      try {
        if ([DateTime]::UtcNow -ge $deadline) { throw 'Canary run timed out before submission.' }
        $entry = $config.quotas | Where-Object name -eq $service.name | Select-Object -First 1
        $template = New-CanaryTemplate $service $entry
        $templatePath = Join-Path $temporaryDirectory "$($service.deploymentName).json"
        $template | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $templatePath
        $arguments = @('deployment', 'group', 'create', '--resource-group', $ResourceGroupName, '--name', $service.deploymentName,
          '--mode', 'Incremental', '--template-file', $templatePath, '--no-wait')
        if ($service.serviceType -eq 'postgresql') {
          $password = 'Aa1!' + [Convert]::ToBase64String([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
          $secrets.Add($password)
          $parameterPath = Join-Path $temporaryDirectory "$($service.deploymentName).parameters.json"
          @{ parameters = @{ administratorPassword = @{ value = $password } } } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $parameterPath
          $arguments += @('--parameters', "@$parameterPath")
        }
        $service.attempted = $true
        $service.cleanupResult = 'pending'
        $null = Invoke-CanaryAz $arguments
        $service.canaryResult = 'running'
      } catch {
        $service.canaryResult = 'failed'
        $service.message = Protect-Message ([string]$_)
        $service.finalVerdict = Get-FailureVerdict $service.message
      } finally {
        if ($parameterPath -and (Test-Path -LiteralPath $parameterPath)) { Remove-Item -LiteralPath $parameterPath -Force }
      }
    }
    while (@($planned | Where-Object canaryResult -eq 'running').Count) {
      foreach ($service in @($planned | Where-Object canaryResult -eq 'running')) {
        try {
          if ([DateTime]::UtcNow -ge $deadline) { throw 'Canary deployment timed out.' }
          $deployment = Invoke-CanaryAz @('deployment', 'group', 'show', '--resource-group', $ResourceGroupName, '--name', $service.deploymentName)
          if ($deployment.properties.provisioningState -eq 'Succeeded') {
            $service.canaryResult = 'succeeded'; $service.finalVerdict = 'verified-deployable'
            $service.message = 'Minimal ARM deployment succeeded. No data-plane connectivity or full-scale capacity was tested.'
          } elseif ($deployment.properties.provisioningState -in @('Failed', 'Canceled')) {
            $service.canaryResult = 'failed'
            $service.message = Get-DeploymentFailure $service $deployment
            $service.finalVerdict = Get-FailureVerdict $service.message
          }
        } catch {
          $service.canaryResult = 'needs-review'; $service.finalVerdict = 'needs-review'
          $service.message = Protect-Message ([string]$_)
        }
      }
      if (@($planned | Where-Object canaryResult -eq 'running').Count) { Start-Sleep -Seconds $PollIntervalSeconds }
    }
  }
} catch {
  $runErrors.Add((Protect-Message ([string]$_)))
  [Console]::Error.WriteLine($runErrors[-1])
} finally {
  if ($groupAttempted) {
    $groupId = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName"
    $groupDeleted = $false
    try {
      foreach ($service in @($services | Where-Object attempted)) {
        try {
          $deployment = Invoke-CanaryAz @('deployment', 'group', 'show', '--resource-group', $ResourceGroupName, '--name', $service.deploymentName)
          if ($deployment.properties.provisioningState -notin @('Succeeded', 'Failed', 'Canceled')) {
            $null = Invoke-CanaryAz @('deployment', 'group', 'cancel', '--resource-group', $ResourceGroupName, '--name', $service.deploymentName)
          }
        } catch {
          # Deletion below remains mandatory even when cancellation/lookup fails.
          if ([string]$_ -notmatch '(?i)DeploymentNotFound|ResourceNotFound') {
            $cleanupErrors.Add((Protect-Message "Deployment cancellation/lookup failed for $($service.deploymentName): $_"))
          }
        }
      }
      if (Test-GroupExists) {
        $group = Invoke-CanaryAz @('group', 'show', '--name', $ResourceGroupName)
        if ($group.tags.runId -ne $runId -or $group.tags.purpose -ne 'deployment-readiness-canary') {
          throw 'Refusing deletion: resource group ownership tags do not match this run.'
        }
        $null = Invoke-CanaryAz @('group', 'delete', '--name', $ResourceGroupName, '--yes', '--no-wait')
        $cleanupDeadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
        while (Test-GroupExists) {
          if ([DateTime]::UtcNow -ge $cleanupDeadline) { throw 'Resource group deletion timed out.' }
          Start-Sleep -Seconds $PollIntervalSeconds
        }
      }
      $groupDeleted = $true
    } catch {
      $cleanupErrors.Add((Protect-Message "Resource group cleanup failed: $_"))
      $leftovers.Add($groupId)
      foreach ($service in @($services | Where-Object attempted)) {
        foreach ($id in $service.resourceIds) { $leftovers.Add($id) }
      }
      try {
        $remaining = @(Invoke-CanaryAz @('resource', 'list', '--resource-group', $ResourceGroupName))
        foreach ($resource in $remaining) { $leftovers.Add([string]$resource.id) }
      } catch { $cleanupErrors.Add((Protect-Message "Could not enumerate leftover resources: $_")) }
    }
    foreach ($service in @($services | Where-Object attempted)) {
      $service.cleanupResult = if ($groupDeleted) { 'succeeded' } else { 'failed' }
      if ($service.serviceType -eq 'openai') {
        $service.purgeResult = 'failed'
        $deletedId = "/subscriptions/$subscriptionId/providers/Microsoft.CognitiveServices/locations/$($service.location)/resourceGroups/$ResourceGroupName/deletedAccounts/$($service.resourceName)"
        try {
          if (-not $groupDeleted) { throw 'Cannot confirm account deletion while resource group cleanup is incomplete.' }
          try {
            $null = Invoke-CanaryAz @('cognitiveservices', 'account', 'purge', '--location', $service.location, '--resource-group', $ResourceGroupName, '--name', $service.resourceName)
          } catch {
            if ([string]$_ -notmatch '(?i)ResourceNotFound|DeletedAccountNotFound') { throw }
          }
          $deletedAccounts = @(Invoke-CanaryAz @('cognitiveservices', 'account', 'list-deleted'))
          if (@($deletedAccounts | Where-Object { $_.id -eq $deletedId }).Count) { throw 'The account remains soft-deleted after purge.' }
          $service.purgeResult = 'purged-or-absent'
        } catch {
          $service.cleanupResult = 'failed'
          $cleanupErrors.Add((Protect-Message "OpenAI purge failed for $($service.resourceName): $_"))
          $leftovers.Add($deletedId)
        }
      }
    }
  }
  if ($temporaryDirectory -and (Test-Path -LiteralPath $temporaryDirectory)) {
    try { Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force }
    catch { $cleanupErrors.Add("Failed to remove protected temporary files at ${temporaryDirectory}: $_") }
  }
}

foreach ($service in $services) {
  if ($service.canaryResult -in @('planned', 'running')) { $service.canaryResult = 'needs-review'; $service.finalVerdict = 'needs-review' }
  if ($service.cleanupResult -eq 'failed') { $service.finalVerdict = 'needs-review' }
  $service.resourceCleanup = @($service.resourceIds | ForEach-Object {
    [pscustomobject]@{ id = $_; result = $service.cleanupResult }
  })
  $service.nextAction = Get-NextAction $service
}
$exitCode = if ($cleanupErrors.Count) { 4 } elseif ($runErrors.Count -or
  @($services | Where-Object finalVerdict -eq 'needs-review').Count -or
  @($prerequisites | Where-Object status -eq 'unknown').Count) { 3 } elseif (
  @($services | Where-Object finalVerdict -eq 'not-deployable').Count -or
  @($prerequisites | Where-Object status -eq 'blocked').Count) { 2 } else { 0 }
$counts = [ordered]@{}
foreach ($verdict in @('verified-deployable', 'not-deployable', 'needs-review', 'not-tested')) {
  $counts[$verdict] = @($services | Where-Object finalVerdict -eq $verdict).Count
}
$limitations = 'Minimal footprints only; point-in-time results reserve no capacity and do not prove full-scale capacity (for example, 14 App Service instances or 8 PostgreSQL servers). Data-plane behavior, networking, performance, and application functionality are not tested. Expiry tags do not automatically delete resources.'
$report = [ordered]@{
  schemaVersion = 1; subscriptionId = $subscriptionId; runId = $runId; startedAt = $started.ToString('o')
  completedAt = [DateTime]::UtcNow.ToString('o'); mode = if ($Execute) { 'execute' } else { 'dry-run' }
  readinessReport = $ReadinessReport; configurationHash = $configurationHash; regions = $locations
  resourceGroupName = $ResourceGroupName
  resourceGroupCleanup = if (-not $groupAttempted) { 'not-required' } elseif ($groupDeleted) { 'succeeded' } else { 'failed' }
  prerequisites = $prerequisites
  executiveSummary = $counts; services = @($services); runErrors = @($runErrors)
  cleanupErrors = @($cleanupErrors); leftoverResourceIds = @($leftovers | Select-Object -Unique)
  limitations = $limitations; exitCode = $exitCode
}
New-Item -ItemType Directory -Path $ArtifactDirectory -Force | Out-Null
$jsonPath = Join-Path $ArtifactDirectory "subscription-readiness-$runId.json"
$markdownPath = Join-Path $ArtifactDirectory "subscription-readiness-$runId.md"
Protect-Message ($report | ConvertTo-Json -Depth 40) | Set-Content -LiteralPath $jsonPath -Encoding utf8
function ConvertTo-MarkdownCell([string]$Text) { return $Text.Replace('|', '\|').Replace("`r", ' ').Replace("`n", ' ') }
$markdown = [System.Collections.Generic.List[string]]::new()
$markdown.Add("# Subscription readiness - $runId")
$markdown.Add("")
$markdown.Add("Subscription: $subscriptionId | Mode: $($report.mode) | Started (UTC): $($report.startedAt) | Completed (UTC): $($report.completedAt) | Regions: $($locations -join ', ') | Exit: $exitCode")
$markdown.Add("")
$markdown.Add("## Executive summary")
$markdown.Add("")
$markdown.Add(($counts.GetEnumerator() | ForEach-Object { "$($_.Key): $($_.Value)" }) -join ' | ')
$markdown.Add("")
if ($cleanupErrors.Count) {
  $markdown.Add("**URGENT: CLEANUP FAILED. Resources may still incur charges.**")
  foreach ($errorMessage in $cleanupErrors) { $markdown.Add("- $(ConvertTo-MarkdownCell $errorMessage)") }
  foreach ($id in $report.leftoverResourceIds) { $markdown.Add("- Leftover or unverified resource: $id") }
}
foreach ($errorMessage in $runErrors) { $markdown.Add("Run error: $(ConvertTo-MarkdownCell $errorMessage)") }
$markdown.Add("")
$markdown.Add("## Service hand-off")
$markdown.Add("")
$markdown.Add('| Region | Service | Readiness | Canary | Cleanup / purge | Verdict | Detail | Next action |')
$markdown.Add('|---|---|---|---|---|---|---|---|')
foreach ($service in $services) {
  $cells = @($service.location, $service.name, $service.readinessStatus, $service.canaryResult,
    "$($service.cleanupResult) / $($service.purgeResult)", $service.finalVerdict, $service.message, $service.nextAction) |
    ForEach-Object { ConvertTo-MarkdownCell ([string]$_) }
  $markdown.Add('| ' + ($cells -join ' | ') + ' |')
}
$markdown.Add("")
$markdown.Add("## Subscription prerequisites")
$markdown.Add("")
foreach ($prerequisite in $prerequisites) {
  $markdown.Add("- $(ConvertTo-MarkdownCell $prerequisite.name): $($prerequisite.status) - $(ConvertTo-MarkdownCell $prerequisite.message)")
}
$markdown.Add("")
$markdown.Add($limitations)
Protect-Message ($markdown -join [Environment]::NewLine) | Set-Content -LiteralPath $markdownPath -Encoding utf8
if ($cleanupErrors.Count) { [Console]::Error.WriteLine("URGENT: CLEANUP FAILED. Inspect $jsonPath. Leftover/unverified IDs: $($report.leftoverResourceIds -join ', ')") }
Write-Host "Hand-off JSON: $jsonPath"
Write-Host "Hand-off Markdown: $markdownPath"
exit $exitCode
