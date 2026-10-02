param(
  [string]$ConfigPath = "readiness-config.json",
  [string]$ArtifactDirectory = "artifacts\deployment-readiness",
  [string]$AzCommand = "az",
  [switch]$VerboseOutput
)

$ErrorActionPreference = 'Stop'

function Write-Step([string]$Message) {
  Write-Host "`n=== $Message ===" -ForegroundColor Cyan
}

function Invoke-AzJson {
  param(
    [Parameter(Mandatory)][string[]]$Arguments,
    [Parameter(Mandatory)][string]$Description
  )

  if ($VerboseOutput) {
    Write-Host "az $($Arguments -join ' ')" -ForegroundColor DarkGray
  }

  $output = & $AzCommand @Arguments 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "$Description failed: $($output -join [Environment]::NewLine)"
  }

  return ($output -join [Environment]::NewLine) | ConvertFrom-Json
}

function New-ReadinessResult {
  param(
    [Parameter(Mandatory)][string]$Location,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][ValidateSet('ready', 'blocked', 'ready-with-risk', 'unknown')][string]$Status,
    [Parameter(Mandatory)][string]$Category,
    [Parameter(Mandatory)][string]$Message
  )

  return [pscustomobject]@{
    location = $Location
    name = $Name
    status = $Status
    category = $Category
    message = $Message
  }
}

function Test-ArmActionAllowed {
  param(
    [Parameter(Mandatory)][object[]]$PermissionBlocks,
    [Parameter(Mandatory)][string]$Action
  )

  foreach ($permission in $PermissionBlocks) {
    $allowed = @($permission.actions | Where-Object { $Action -like [string]$_ }).Count -gt 0
    $denied = @($permission.notActions | Where-Object { $Action -like [string]$_ }).Count -gt 0
    if ($allowed -and -not $denied) {
      return $true
    }
  }
  return $false
}

Write-Step "Loading configuration"
if (-not (Test-Path $ConfigPath)) {
  [Console]::Error.WriteLine("Config not found at $ConfigPath. Copy readiness-config.sample.json to readiness-config.json and edit it.")
  exit 2
}

try {
  $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
} catch {
  [Console]::Error.WriteLine("Failed to parse config JSON: $_")
  exit 2
}

if (-not $config.location -and (-not $config.locations -or $config.locations.Count -eq 0)) {
  [Console]::Error.WriteLine("Set either location or at least one entry in locations.")
  exit 2
}
if (-not $config.quotas -or $config.quotas.Count -eq 0) {
  [Console]::Error.WriteLine("At least one entry must be present in the quotas array.")
  exit 2
}

$locations = if ($config.locations) {
  @($config.locations | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
} else {
  @([string]$config.location)
}
if ($locations.Count -eq 0) {
  [Console]::Error.WriteLine("No valid Azure locations were configured.")
  exit 2
}

$prerequisiteResults = @()

Write-Step "Validating Azure prerequisites"
if (-not (Get-Command $AzCommand -ErrorAction SilentlyContinue)) {
  [Console]::Error.WriteLine("Azure CLI is not installed or is not available on PATH.")
  exit 3
}

try {
  $cliVersionResult = Invoke-AzJson -Arguments @('version', '--output', 'json') -Description 'Azure CLI version lookup'
  $minimumCliVersion = if ($config.prerequisites.minimumAzureCliVersion) {
    [version][string]$config.prerequisites.minimumAzureCliVersion
  } else {
    [version]'2.60.0'
  }
  $installedCliVersion = [version][string]$cliVersionResult.'azure-cli'
  if ($installedCliVersion -lt $minimumCliVersion) {
    $prerequisiteResults += New-ReadinessResult -Location subscription -Name 'Azure CLI version' -Status unknown -Category 'cli-version-unsupported' -Message "Azure CLI $installedCliVersion is installed; version $minimumCliVersion or later is required."
  } else {
    $prerequisiteResults += New-ReadinessResult -Location subscription -Name 'Azure CLI version' -Status ready -Category 'prerequisite' -Message "Azure CLI $installedCliVersion meets the minimum version $minimumCliVersion."
  }
} catch {
  $prerequisiteResults += New-ReadinessResult -Location subscription -Name 'Azure CLI version' -Status unknown -Category 'cli-version-unknown' -Message ([string]$_)
}

try {
  $account = Invoke-AzJson -Arguments @('account', 'show', '--output', 'json') -Description 'Azure account lookup'
} catch {
  [Console]::Error.WriteLine([string]$_)
  exit 3
}

$subscriptionId = if ($config.subscriptionId) { [string]$config.subscriptionId } else { [string]$account.id }
if ($account.id -ne $subscriptionId) {
  [Console]::Error.WriteLine("Active subscription $($account.id) does not match configured subscription $subscriptionId. Run 'az account set --subscription $subscriptionId'.")
  exit 3
}
if ($account.state -and [string]$account.state -ne 'Enabled') {
  $prerequisiteResults += New-ReadinessResult -Location subscription -Name 'Subscription state' -Status blocked -Category 'subscription-disabled' -Message "Subscription $subscriptionId is $($account.state)."
} else {
  $prerequisiteResults += New-ReadinessResult -Location subscription -Name 'Subscription state' -Status ready -Category 'prerequisite' -Message "Subscription $subscriptionId is enabled."
}

# App Service, PostgreSQL Flexible Server, Azure OpenAI, Azure AI Search, and
# Azure Managed Redis entries use service-specific APIs. The quota extension
# and Microsoft.Quota provider are only required for generic quota entries.
$needsQuotaApi = @($config.quotas | Where-Object {
  -not $_.appServicePlanSku -and
  -not $_.postgresFlexibleSku -and
  -not $_.azureOpenAISku -and
  -not $_.aiSearchSku -and
  -not $_.redisEnterpriseSku
}).Count -gt 0

if ($needsQuotaApi) {
  $quotaExtension = & $AzCommand extension show --name quota --output none 2>&1
  if ($LASTEXITCODE -ne 0) {
    $prerequisiteResults += New-ReadinessResult -Location subscription -Name 'Azure CLI quota extension' -Status unknown -Category 'extension-missing' -Message "The Azure CLI quota extension is required. Install it with 'az extension add --name quota'."
  } else {
    $prerequisiteResults += New-ReadinessResult -Location subscription -Name 'Azure CLI quota extension' -Status ready -Category 'prerequisite' -Message 'The Azure CLI quota extension is installed.'
  }
} else {
  $prerequisiteResults += New-ReadinessResult -Location subscription -Name 'Azure CLI quota extension' -Status ready -Category 'not-required' -Message 'The configured checks use service-specific APIs and do not require the quota extension.'
}

$derivedProviders = @(
  $config.quotas | ForEach-Object {
    if ($_.providerNamespace) { [string]$_.providerNamespace }
    elseif ($_.appServicePlanSku) { 'Microsoft.Web' }
    elseif ($_.postgresFlexibleSku) { 'Microsoft.DBforPostgreSQL' }
    elseif ($_.azureOpenAISku) { 'Microsoft.CognitiveServices' }
    elseif ($_.aiSearchSku) { 'Microsoft.Search' }
    elseif ($_.redisEnterpriseSku) { 'Microsoft.Cache' }
  } | Where-Object { $_ }
)
$configuredProviders = @($config.prerequisites.requiredProviders | ForEach-Object { [string]$_ } | Where-Object { $_ })
$requiredProviders = @($derivedProviders + $configuredProviders + $(if ($needsQuotaApi) { 'Microsoft.Quota' }) | Select-Object -Unique)
$providerStates = @{}
foreach ($providerNamespace in $requiredProviders) {
  try {
    $provider = Invoke-AzJson -Arguments @(
      'provider', 'show',
      '--namespace', $providerNamespace,
      '--query', '{state:registrationState}',
      '--output', 'json'
    ) -Description "$providerNamespace provider registration lookup"
    $providerStates[$providerNamespace] = [string]$provider.state
    if ($provider.state -eq 'Registered') {
      $prerequisiteResults += New-ReadinessResult -Location subscription -Name "Provider $providerNamespace" -Status ready -Category 'provider-registered' -Message "$providerNamespace is registered."
    } else {
      $prerequisiteResults += New-ReadinessResult -Location subscription -Name "Provider $providerNamespace" -Status blocked -Category 'provider-not-registered' -Message "$providerNamespace is $($provider.state)."
    }
  } catch {
    $providerStates[$providerNamespace] = 'Unknown'
    $prerequisiteResults += New-ReadinessResult -Location subscription -Name "Provider $providerNamespace" -Status unknown -Category 'provider-state-unknown' -Message ([string]$_)
  }
}

$requiredPermissions = @(
  'Microsoft.Resources/subscriptions/read'
  'Microsoft.Resources/subscriptions/providers/read'
)
if ($needsQuotaApi) {
  $requiredPermissions += 'Microsoft.Quota/quotas/read'
  $requiredPermissions += 'Microsoft.Quota/usages/read'
}
$requiredPermissions += @($config.prerequisites.requiredPermissions | ForEach-Object { [string]$_ } | Where-Object { $_ })
$requiredPermissions = @($requiredPermissions | Select-Object -Unique)

try {
  $permissionsUri = "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.Authorization/permissions?api-version=2022-04-01"
  $permissionsResult = Invoke-AzJson -Arguments @('rest', '--method', 'get', '--uri', $permissionsUri, '--output', 'json') -Description 'Effective ARM permissions lookup'
  $permissionBlocks = @($permissionsResult.value)
  foreach ($requiredPermission in $requiredPermissions) {
    if (Test-ArmActionAllowed -PermissionBlocks $permissionBlocks -Action $requiredPermission) {
      $prerequisiteResults += New-ReadinessResult -Location subscription -Name "Permission $requiredPermission" -Status ready -Category 'permission-granted' -Message "The active principal can perform $requiredPermission."
    } else {
      $prerequisiteResults += New-ReadinessResult -Location subscription -Name "Permission $requiredPermission" -Status blocked -Category 'permission-missing' -Message "The active principal does not have $requiredPermission at subscription scope."
    }
  }
} catch {
  $prerequisiteResults += New-ReadinessResult -Location subscription -Name 'Effective ARM permissions' -Status unknown -Category 'permissions-unknown' -Message ([string]$_)
}

foreach ($feature in @($config.prerequisites.requiredFeatures)) {
  $featureNamespace = [string]$feature.namespace
  $featureName = [string]$feature.name
  if ([string]::IsNullOrWhiteSpace($featureNamespace) -or [string]::IsNullOrWhiteSpace($featureName)) {
    $prerequisiteResults += New-ReadinessResult -Location subscription -Name 'Azure feature registration' -Status unknown -Category 'invalid-configuration' -Message 'Each requiredFeatures entry must set namespace and name.'
    continue
  }

  $featureOutput = & $AzCommand feature show --namespace $featureNamespace --name $featureName --query properties.state --output tsv 2>&1
  if ($LASTEXITCODE -ne 0) {
    $prerequisiteResults += New-ReadinessResult -Location subscription -Name "Feature $featureNamespace/$featureName" -Status unknown -Category 'feature-state-unknown' -Message ($featureOutput -join [Environment]::NewLine)
  } elseif (($featureOutput -join '').Trim() -eq 'Registered') {
    $prerequisiteResults += New-ReadinessResult -Location subscription -Name "Feature $featureNamespace/$featureName" -Status ready -Category 'feature-registered' -Message "$featureNamespace/$featureName is registered."
  } else {
    $state = ($featureOutput -join '').Trim()
    $prerequisiteResults += New-ReadinessResult -Location subscription -Name "Feature $featureNamespace/$featureName" -Status blocked -Category 'feature-not-registered' -Message "$featureNamespace/$featureName is $state."
  }
}

Write-Host "Subscription: $subscriptionId"
Write-Host "Locations:    $($locations -join ', ')"
Write-Host "Principal:    $($account.user.name) ($($account.user.type))"

function Test-VmSkuAvailability {
  param(
    [Parameter(Mandatory)][string]$Sku,
    [Parameter(Mandatory)][string]$Location
  )

  $skuResult = Invoke-AzJson -Arguments @(
    'vm', 'list-skus',
    '--location', $Location,
    '--query', "[?name=='$Sku']",
    '--output', 'json'
  ) -Description "SKU availability lookup for $Sku in $Location"

  if (-not $skuResult -or $skuResult.Count -eq 0) {
    return [pscustomobject]@{ Found = $false; Family = $null; Available = $false; Restrictions = @() }
  }

  $skuInfo = $skuResult[0]
  $locationRestrictions = @($skuInfo.restrictions | Where-Object { $_.type -eq 'Location' })
  $zoneRestrictions = @($skuInfo.restrictions | Where-Object { $_.type -eq 'Zone' })

  return [pscustomobject]@{
    Found = $true
    Family = [string]$skuInfo.family
    Available = ($locationRestrictions.Count -eq 0)
    Restrictions = @($skuInfo.restrictions)
    ZoneRestricted = ($zoneRestrictions.Count -gt 0)
  }
}

function Test-AppServicePlanQuota {
  param(
    [Parameter(Mandatory)][string]$Sku,
    [Parameter(Mandatory)][string]$Tier,
    [Parameter(Mandatory)][string]$Family,
    [Parameter(Mandatory)][string]$Location,
    [Parameter(Mandatory)][string]$SubscriptionId
  )

  # App Service Plan quota is not exposed via 'az quota' (Microsoft.Web is not
  # onboarded to that API), so region availability and quota/usage are read
  # from the classic appservice CLI and the Microsoft.Web usages REST API.
  $locationsOutput = & $AzCommand appservice list-locations --sku $Sku --output json 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "App Service Plan SKU location lookup for $Sku failed: $($locationsOutput -join [Environment]::NewLine)"
  }
  $locations = @(($locationsOutput -join [Environment]::NewLine) | ConvertFrom-Json)

  $candidateNames = @($Location)
  $displayNameLookup = Invoke-AzJson -Arguments @(
    'account', 'list-locations',
    '--query', "[?name=='$Location' || displayName=='$Location']",
    '--output', 'json'
  ) -Description "Location display name lookup for $Location"
  if ($displayNameLookup -and $displayNameLookup.Count -gt 0) {
    $candidateNames += [string]$displayNameLookup[0].displayName
    $candidateNames += [string]$displayNameLookup[0].name
  }
  $normalize = { param($value) ($value -replace '[\s_-]', '').ToLowerInvariant() }
  $normalizedCandidates = @($candidateNames | ForEach-Object { & $normalize $_ } | Select-Object -Unique)

  $regionAvailable = $false
  foreach ($loc in $locations) {
    $locName = if ($loc -is [string]) { $loc } else { [string]$loc.name }
    if ($normalizedCandidates -contains (& $normalize $locName)) {
      $regionAvailable = $true
      break
    }
  }

  if (-not $regionAvailable) {
    return [pscustomobject]@{ RegionAvailable = $false; Limit = $null; Usage = $null }
  }

  $usagesUri = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Web/locations/$Location/usages?api-version=2023-12-01"
  $usagesOutput = & $AzCommand rest --method get --uri $usagesUri --output json 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "Microsoft.Web usage lookup in $Location failed: $($usagesOutput -join [Environment]::NewLine)"
  }
  $usages = @((($usagesOutput -join [Environment]::NewLine) | ConvertFrom-Json).value)
  $normalizedTier = & $normalize $Tier

  $match = $usages | Where-Object {
    $_.name.value -eq $Family -and (& $normalize $_.name.localizedValue) -eq $normalizedTier
  } | Select-Object -First 1

  if (-not $match) {
    return [pscustomobject]@{ RegionAvailable = $true; Limit = $null; Usage = $null }
  }

  return [pscustomobject]@{
    RegionAvailable = $true
    Limit = [int]$match.limit
    Usage = [int]$match.currentValue
  }
}

function Test-PostgreSqlFlexibleServerSku {
  param(
    [Parameter(Mandatory)][string]$Sku,
    [Parameter(Mandatory)][string]$Location,
    [Parameter(Mandatory)][string]$Family,
    [Parameter(Mandatory)][string]$SubscriptionId,
    [int]$RequiredAvailable = 0,
    [string]$AvailabilityZone
  )

  $skuResult = Invoke-AzJson -Arguments @(
    'postgres', 'flexible-server', 'list-skus',
    '--location', $Location,
    '--only-show-errors',
    '--output', 'json'
  ) -Description "PostgreSQL Flexible Server SKU lookup for $Sku in $Location"

  $skuEntries = @()
  foreach ($skuRoot in @($skuResult)) {
    if ($skuRoot.PSObject.Properties.Name -contains 'supportedServerEditions') {
      foreach ($edition in @($skuRoot.supportedServerEditions)) {
        foreach ($serverSku in @($edition.supportedServerSkus)) {
          $zones = if ($serverSku.supportedZones) { @($serverSku.supportedZones) } else { @($skuRoot.supportedZones) }
          $skuEntries += [pscustomobject]@{ Sku = $serverSku; SupportedZones = $zones }
        }
      }
    } else {
      $skuEntries += [pscustomobject]@{ Sku = $skuRoot; SupportedZones = @($skuRoot.supportedZones) }
    }
  }

  $configuredSku = $Sku.Trim().ToLowerInvariant()
  $skuInfoEntry = @($skuEntries | Where-Object {
    $candidate = [string]$_.Sku.name
    if (-not $candidate) { $candidate = [string]$_.Sku.skuName }
    $normalizedCandidate = $candidate.Trim().ToLowerInvariant()
    $configuredSku -eq $normalizedCandidate -or $configuredSku.EndsWith("_$normalizedCandidate")
  }) | Select-Object -First 1

  if (-not $skuInfoEntry) {
    return [pscustomobject]@{
      Available = $false
      ZonesKnown = $true
      SupportedZones = @()
      ZoneAvailable = $false
      QuotaKnown = $false
      Limit = $null
      Usage = $null
      HasQuota = $false
    }
  }

  $skuInfo = $skuInfoEntry.Sku
  $hasSupportedZones = $skuInfoEntry.SupportedZones.Count -gt 0
  $supportedZones = @($skuInfoEntry.SupportedZones | ForEach-Object { [string]$_ })
  $zoneRequested = -not [string]::IsNullOrWhiteSpace($AvailabilityZone) -and $AvailabilityZone -ne 'auto'

  $usageUri = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.DBforPostgreSQL/locations/$Location/resourceType/flexibleServers/usages?api-version=2024-11-01-preview"
  $usageResult = Invoke-AzJson -Arguments @(
    'rest', '--method', 'get',
    '--uri', $usageUri,
    '--output', 'json'
  ) -Description "PostgreSQL Flexible Server family quota lookup in $Location"
  $familyUsage = @($usageResult.value | Where-Object {
    [string]$_.name.value -ieq $Family
  }) | Select-Object -First 1
  $limit = if ($familyUsage) { [int]$familyUsage.limit } else { $null }
  $usage = if ($familyUsage) { [int]$familyUsage.currentValue } else { $null }

  return [pscustomobject]@{
    Available = $true
    ZonesKnown = $hasSupportedZones
    SupportedZones = $supportedZones
    ZoneAvailable = (-not $zoneRequested -or ($supportedZones -contains [string]$AvailabilityZone))
    QuotaKnown = ($null -ne $familyUsage)
    Limit = $limit
    Usage = $usage
    HasQuota = ($null -ne $familyUsage -and (($limit - $usage) -ge $RequiredAvailable))
  }
}

function Test-AzureOpenAISku {
  param(
    [Parameter(Mandatory)][string]$Sku,
    [Parameter(Mandatory)][string]$Location,
    [Parameter(Mandatory)][string]$SubscriptionId
  )

  $uri = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.CognitiveServices/skus?api-version=2024-10-01"
  $skuResult = Invoke-AzJson -Arguments @(
    'rest', '--method', 'get',
    '--uri', $uri,
    '--output', 'json'
  ) -Description "Azure OpenAI SKU eligibility lookup for $Sku in $Location"

  $matches = @($skuResult.value | Where-Object {
    [string]$_.name -ieq $Sku -and
    [string]$_.resourceType -ieq 'accounts' -and
    (
      [string]$_.kind -ieq 'OpenAI' -or
      @($_.capabilities | Where-Object { [string]$_.name -ieq 'Kind' -and [string]$_.value -ieq 'OpenAI' }).Count -gt 0
    ) -and
    @($_.locations | Where-Object { [string]$_ -ieq $Location }).Count -gt 0
  })

  if ($matches.Count -eq 0) {
    return [pscustomobject]@{ Available = $false; Restricted = $false }
  }

  $restricted = @($matches.restrictions | Where-Object {
    [string]$_.type -ieq 'Location' -and
    @($_.values | Where-Object { [string]$_ -ieq $Location }).Count -gt 0
  }).Count -gt 0

  return [pscustomobject]@{ Available = $true; Restricted = $restricted }
}

function Test-AzureOpenAIModelQuota {
  param(
    [Parameter(Mandatory)][string]$Model,
    [Parameter(Mandatory)][string]$DeploymentType,
    [Parameter(Mandatory)][string]$Location,
    [Parameter(Mandatory)][string]$SubscriptionId,
    [int]$RequiredAvailable = 0
  )

  $usageOutput = & $AzCommand cognitiveservices usage list --location $Location --subscription $SubscriptionId --output json 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "Azure OpenAI model quota lookup in $Location failed: $($usageOutput -join [Environment]::NewLine)"
  }
  $usages = @(($usageOutput -join [Environment]::NewLine) | ConvertFrom-Json)
  $normalize = { param($value) ([string]$value -replace '[^A-Za-z0-9]', '').ToLowerInvariant() }
  $normalizedModel = & $normalize $Model
  $normalizedDeploymentType = & $normalize $DeploymentType

  $match = @($usages | Where-Object {
    $quotaName = & $normalize $_.name.value
    $quotaName.Contains($normalizedModel) -and $quotaName.Contains($normalizedDeploymentType)
  }) | Select-Object -First 1

  if (-not $match) {
    return [pscustomobject]@{
      Found = $false
      Limit = $null
      Usage = $null
      HasQuota = $false
      QuotaName = $null
    }
  }

  $limit = [int]$match.limit
  $usage = [int]$match.currentValue
  return [pscustomobject]@{
    Found = $true
    Limit = $limit
    Usage = $usage
    HasQuota = (($limit - $usage) -ge $RequiredAvailable)
    QuotaName = [string]$match.name.value
  }
}

function Test-AISearchReadiness {
  param(
    [Parameter(Mandatory)][string]$Sku,
    [Parameter(Mandatory)][string]$Location,
    [Parameter(Mandatory)][string]$SubscriptionId,
    [int]$RequiredAvailable = 1
  )

  $usageUri = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Search/locations/$Location/usages?api-version=2025-05-01"
  $usageResult = Invoke-AzJson -Arguments @(
    'rest', '--method', 'get',
    '--uri', $usageUri,
    '--output', 'json'
  ) -Description "Azure AI Search usage lookup in $Location"

  $normalize = { param($value) ([string]$value -replace '[^A-Za-z0-9]', '').ToLowerInvariant() }
  $normalizedSku = & $normalize $Sku
  $serviceUsage = @($usageResult.value | Where-Object {
    $valueName = & $normalize $_.name.value
    $localizedName = & $normalize $_.name.localizedValue
    $valueName -eq $normalizedSku -or
    $valueName -eq "${normalizedSku}sku" -or
    $localizedName -eq $normalizedSku -or
    $localizedName -eq "${normalizedSku}sku"
  }) | Select-Object -First 1

  if (-not $serviceUsage) {
    return [pscustomobject]@{
      SkuAvailable = $false
      QuotaKnown = $false
      Limit = $null
      Usage = $null
      HasQuota = $false
    }
  }

  $limit = [int]$serviceUsage.limit
  $usage = [int]$serviceUsage.currentValue
  return [pscustomobject]@{
    SkuAvailable = $true
    QuotaKnown = $true
    Limit = $limit
    Usage = $usage
    HasQuota = (($limit - $usage) -ge $RequiredAvailable)
  }
}

function Test-ManagedRedisSku {
  param(
    [Parameter(Mandatory)][string]$Sku,
    [Parameter(Mandatory)][string]$Location,
    [Parameter(Mandatory)][string]$SubscriptionId
  )

  $skuUri = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Cache/skus?api-version=2025-04-01"
  $skuResult = Invoke-AzJson -Arguments @(
    'rest', '--method', 'get',
    '--uri', $skuUri,
    '--output', 'json'
  ) -Description "Azure Managed Redis SKU lookup for $Sku in $Location"

  $matches = @($skuResult.value | Where-Object {
    [string]$_.name -ieq $Sku -and
    [string]$_.resourceType -ieq 'redisEnterprise' -and
    (
      -not $_.locations -or
      @($_.locations | Where-Object { [string]$_ -ieq $Location }).Count -gt 0
    )
  })
  if ($matches.Count -eq 0) {
    return [pscustomobject]@{ Available = $false; Restricted = $false }
  }

  $restricted = @($matches.restrictions | Where-Object {
    [string]$_.type -ieq 'Location' -and
    @($_.values | Where-Object { [string]$_ -ieq $Location }).Count -gt 0
  }).Count -gt 0

  return [pscustomobject]@{ Available = $true; Restricted = $restricted }
}

$checkErrors = @()
$readinessResults = @($prerequisiteResults)

Write-Step "Checking deployment readiness"
foreach ($location in $locations) {
  Write-Step "Region: $location"

  foreach ($quota in $config.quotas) {
    $displayName = if ($quota.name) { [string]$quota.name } else { [string]$quota.resourceName }
    $providerNamespace = [string]$quota.providerNamespace
    $resourceName = [string]$quota.resourceName
    $vmSku = [string]$quota.vmSku
    $appServicePlanSku = [string]$quota.appServicePlanSku
    $appServicePlanTier = [string]$quota.appServicePlanTier
    $postgresFlexibleSku = [string]$quota.postgresFlexibleSku
    $availabilityZone = [string]$quota.availabilityZone
    $azureOpenAISku = [string]$quota.azureOpenAISku
    $azureOpenAIModel = [string]$quota.azureOpenAIModel
    $azureOpenAIDeploymentType = [string]$quota.azureOpenAIDeploymentType
    $aiSearchSku = [string]$quota.aiSearchSku
    $redisEnterpriseSku = [string]$quota.redisEnterpriseSku
    $requiredAvailable = if ($null -ne $quota.requiredAvailable) { [int]$quota.requiredAvailable } else { 0 }
    $resourceType = if ($quota.resourceType) { [string]$quota.resourceType } else { 'dedicated' }

    if (-not $providerNamespace) {
      $providerNamespace = if ($appServicePlanSku) { 'Microsoft.Web' }
      elseif ($postgresFlexibleSku) { 'Microsoft.DBforPostgreSQL' }
      elseif ($azureOpenAISku) { 'Microsoft.CognitiveServices' }
      elseif ($aiSearchSku) { 'Microsoft.Search' }
      elseif ($redisEnterpriseSku) { 'Microsoft.Cache' }
    }

    if ($postgresFlexibleSku -and $requiredAvailable -eq 0 -and $quota.instanceCount -and $quota.vCoresPerInstance) {
      $requiredAvailable = [int]$quota.instanceCount * [int]$quota.vCoresPerInstance
    }

    Write-Host "`n[$displayName]" -ForegroundColor Yellow
    Write-Host "Provider:           $providerNamespace"

    if ($providerNamespace -and $providerStates[$providerNamespace] -ne 'Registered') {
      $state = if ($providerStates.ContainsKey($providerNamespace)) { $providerStates[$providerNamespace] } else { 'Unknown' }
      $reason = "Resource provider $providerNamespace is $state for this subscription."
      $status = if ($state -eq 'Unknown') { 'unknown' } else { 'blocked' }
      $category = if ($state -eq 'Unknown') { 'provider-state-unknown' } else { 'provider-not-registered' }
      $readinessResults += New-ReadinessResult -Location $location -Name $displayName -Status $status -Category $category -Message $reason
      Write-Warning $reason
      continue
    }

    if ($azureOpenAISku) {
      Write-Host "Azure OpenAI SKU:   $azureOpenAISku"
      try {
        $openAICheck = Test-AzureOpenAISku -Sku $azureOpenAISku -Location $location -SubscriptionId $subscriptionId
      } catch {
        $message = "$displayName Azure OpenAI eligibility lookup failed in ${location}: $_"
        $checkErrors += $message
        $readinessResults += New-ReadinessResult -Location $location -Name $displayName -Status unknown -Category 'eligibility-check-failed' -Message $message
        Write-Warning $message
        continue
      }

      if (-not $openAICheck.Available -or $openAICheck.Restricted) {
        $reason = "Azure OpenAI SKU $azureOpenAISku is not enabled or is restricted for this subscription in $location."
        $readinessResults += New-ReadinessResult -Location $location -Name $displayName -Status blocked -Category 'subscription-not-enabled' -Message $reason
        Write-Warning $reason
      } else {
        if ($azureOpenAIModel -or $azureOpenAIDeploymentType) {
          if (-not $azureOpenAIModel -or -not $azureOpenAIDeploymentType) {
            $message = "$displayName must set both azureOpenAIModel and azureOpenAIDeploymentType."
            $checkErrors += $message
            $readinessResults += New-ReadinessResult -Location $location -Name $displayName -Status unknown -Category 'invalid-configuration' -Message $message
            Write-Warning $message
            continue
          }

          try {
            $modelQuota = Test-AzureOpenAIModelQuota -Model $azureOpenAIModel -DeploymentType $azureOpenAIDeploymentType -Location $location -SubscriptionId $subscriptionId -RequiredAvailable $requiredAvailable
          } catch {
            $message = "$displayName Azure OpenAI model quota lookup failed in ${location}: $_"
            $checkErrors += $message
            $readinessResults += New-ReadinessResult -Location $location -Name $displayName -Status unknown -Category 'quota-check-failed' -Message $message
            Write-Warning $message
            continue
          }

          if (-not $modelQuota.Found) {
            $reason = "Azure OpenAI model $azureOpenAIModel with deployment type $azureOpenAIDeploymentType is not enabled or has no quota entry in $location."
            $readinessResults += New-ReadinessResult -Location $location -Name $displayName -Status blocked -Category 'model-not-enabled' -Message $reason
            Write-Warning $reason
          } elseif (-not $modelQuota.HasQuota) {
            $reason = "Azure OpenAI quota $($modelQuota.QuotaName) is insufficient in $location. Usage is $($modelQuota.Usage) of $($modelQuota.Limit); $requiredAvailable additional quota units are required."
            $readinessResults += New-ReadinessResult -Location $location -Name $displayName -Status blocked -Category 'quota-deficit' -Message $reason
            Write-Warning $reason
          } else {
            $message = "Azure OpenAI account eligibility and model quota checks passed for $azureOpenAIModel ($azureOpenAIDeploymentType)."
            $readinessResults += New-ReadinessResult -Location $location -Name $displayName -Status ready -Category 'verified' -Message $message
            Write-Host "PASS: $message" -ForegroundColor Green
          }
        } else {
          $message = "Azure OpenAI SKU $azureOpenAISku is enabled for this subscription and region. No model-specific quota was requested."
          $readinessResults += New-ReadinessResult -Location $location -Name $displayName -Status ready -Category 'eligible' -Message $message
          Write-Host "PASS: $message" -ForegroundColor Green
        }
      }
      continue
    }

    if ($aiSearchSku) {
      $searchRequired = if ($requiredAvailable -gt 0) { $requiredAvailable } else { 1 }
      Write-Host "AI Search SKU:      $aiSearchSku"
      try {
        $searchCheck = Test-AISearchReadiness -Sku $aiSearchSku -Location $location -SubscriptionId $subscriptionId -RequiredAvailable $searchRequired
      } catch {
        $message = "$displayName Azure AI Search readiness lookup failed in ${location}: $_"
        $checkErrors += $message
        $readinessResults += New-ReadinessResult -Location $location -Name $displayName -Status unknown -Category 'eligibility-check-failed' -Message $message
        Write-Warning $message
        continue
      }

      if (-not $searchCheck.SkuAvailable) {
        $reason = "Azure AI Search SKU $aiSearchSku is not offered to this subscription in $location."
        $readinessResults += New-ReadinessResult -Location $location -Name $displayName -Status blocked -Category 'sku-unavailable' -Message $reason
        Write-Warning $reason
        continue
      }

      if (-not $searchCheck.QuotaKnown) {
        $message = "Azure AI Search SKU $aiSearchSku is offered in $location, but the service-count quota could not be identified. Runtime capacity is not verifiable."
        $readinessResults += New-ReadinessResult -Location $location -Name $displayName -Status unknown -Category 'quota-not-exposed' -Message $message
        Write-Warning $message
        continue
      }

      Write-Host "Current usage:      $($searchCheck.Usage)"
      Write-Host "Current limit:      $($searchCheck.Limit)"
      if (-not $searchCheck.HasQuota) {
        $reason = "Azure AI Search service-count quota is insufficient in $location. Usage is $($searchCheck.Usage) of $($searchCheck.Limit); $searchRequired additional service(s) are required."
        $readinessResults += New-ReadinessResult -Location $location -Name $displayName -Status blocked -Category 'quota-deficit' -Message $reason
        Write-Warning $reason
      } else {
        $message = "Azure AI Search SKU and service-count quota checks passed. Physical regional capacity cannot be verified before provisioning."
        $readinessResults += New-ReadinessResult -Location $location -Name $displayName -Status 'ready-with-risk' -Category 'runtime-capacity-unverifiable' -Message $message
        Write-Host "PASS WITH RISK: $message" -ForegroundColor Yellow
      }
      continue
    }

    if ($postgresFlexibleSku) {
      Write-Host "PostgreSQL SKU:     $postgresFlexibleSku"
      Write-Host "Availability zone:  $(if ($availabilityZone) { $availabilityZone } else { 'auto' })"
      if (-not $resourceName) {
        $message = "$displayName sets postgresFlexibleSku but is missing resourceName."
        $checkErrors += $message
        $readinessResults += New-ReadinessResult -Location $location -Name $displayName -Status unknown -Category 'invalid-configuration' -Message $message
        Write-Warning $message
        continue
      }
      try {
        $postgresCheck = Test-PostgreSqlFlexibleServerSku -Sku $postgresFlexibleSku -Location $location -Family $resourceName -SubscriptionId $subscriptionId -RequiredAvailable $requiredAvailable -AvailabilityZone $availabilityZone
      } catch {
        $message = "$displayName PostgreSQL SKU lookup failed in ${location}: $_"
        $checkErrors += $message
        $readinessResults += New-ReadinessResult -Location $location -Name $displayName -Status unknown -Category 'eligibility-check-failed' -Message $message
        Write-Warning $message
        continue
      }

      if (-not $postgresCheck.Available) {
        $reason = "PostgreSQL Flexible Server SKU $postgresFlexibleSku is not offered in $location."
        $readinessResults += New-ReadinessResult -Location $location -Name $displayName -Status blocked -Category 'sku-unavailable' -Message $reason
        Write-Warning $reason
        continue
      }

      if ($availabilityZone -and $availabilityZone -ne 'auto') {
        if (-not $postgresCheck.ZonesKnown) {
          $message = "PostgreSQL SKU $postgresFlexibleSku is offered in $location, but zone support was not returned by Azure CLI."
          $checkErrors += $message
          $readinessResults += New-ReadinessResult -Location $location -Name $displayName -Status unknown -Category 'zone-support-unknown' -Message $message
          Write-Warning $message
          continue
        }
        if (-not $postgresCheck.ZoneAvailable) {
          $reason = "PostgreSQL availability zone $availabilityZone is not supported for SKU $postgresFlexibleSku in $location. Supported zones: $($postgresCheck.SupportedZones -join ', ')."
          $readinessResults += New-ReadinessResult -Location $location -Name $displayName -Status blocked -Category 'zone-unavailable' -Message $reason
          Write-Warning $reason
          continue
        }
      }

      if (-not $postgresCheck.QuotaKnown) {
        $message = "PostgreSQL SKU $postgresFlexibleSku is offered in $location, but family quota '$resourceName' was not returned by the Flexible Server usages API."
        $checkErrors += $message
        $readinessResults += New-ReadinessResult -Location $location -Name $displayName -Status unknown -Category 'quota-not-exposed' -Message $message
        Write-Warning $message
        continue
      }

      Write-Host "Current usage:      $($postgresCheck.Usage)"
      Write-Host "Current limit:      $($postgresCheck.Limit)"
      if (-not $postgresCheck.HasQuota) {
        $reason = "PostgreSQL Flexible Server quota is insufficient in $location. Usage is $($postgresCheck.Usage) of $($postgresCheck.Limit); $requiredAvailable additional vCores are required."
        $readinessResults += New-ReadinessResult -Location $location -Name $displayName -Status blocked -Category 'quota-deficit' -Message $reason
        Write-Warning $reason
      } else {
        $message = "PostgreSQL Flexible Server SKU, zone, and family quota checks passed."
        $readinessResults += New-ReadinessResult -Location $location -Name $displayName -Status ready -Category 'verified' -Message $message
        Write-Host "PASS: $message" -ForegroundColor Green
      }
      continue
    }

    if ($redisEnterpriseSku) {
      Write-Host "Managed Redis SKU:  $redisEnterpriseSku"
      try {
        $redisCheck = Test-ManagedRedisSku -Sku $redisEnterpriseSku -Location $location -SubscriptionId $subscriptionId
      } catch {
        $message = "$displayName Azure Managed Redis SKU lookup failed in ${location}: $_"
        $checkErrors += $message
        $readinessResults += New-ReadinessResult -Location $location -Name $displayName -Status unknown -Category 'eligibility-check-failed' -Message $message
        Write-Warning $message
        continue
      }

      if (-not $redisCheck.Available -or $redisCheck.Restricted) {
        $reason = "Azure Managed Redis SKU $redisEnterpriseSku is unavailable or restricted for this subscription in $location."
        $readinessResults += New-ReadinessResult -Location $location -Name $displayName -Status blocked -Category 'sku-unavailable' -Message $reason
        Write-Warning $reason
      } else {
        $message = "Azure Managed Redis SKU $redisEnterpriseSku is offered in $location. Physical capacity and service-count quota are not guaranteed by the SKU API."
        $readinessResults += New-ReadinessResult -Location $location -Name $displayName -Status 'ready-with-risk' -Category 'runtime-capacity-unverifiable' -Message $message
        Write-Host "PASS WITH RISK: $message" -ForegroundColor Yellow
      }
      continue
    }

    if ($appServicePlanSku) {
      Write-Host "App Service SKU:    $appServicePlanSku"
      Write-Host "App Service tier:   $appServicePlanTier"

      if (-not $appServicePlanTier -or -not $resourceName) {
        $message = "$displayName sets appServicePlanSku but is missing appServicePlanTier or resourceName."
        $checkErrors += $message
        $readinessResults += New-ReadinessResult -Location $location -Name $displayName -Status unknown -Category 'invalid-configuration' -Message $message
        Write-Warning $message
        continue
      }

      try {
        $planCheck = Test-AppServicePlanQuota -Sku $appServicePlanSku -Tier $appServicePlanTier -Family $resourceName -Location $location -SubscriptionId $subscriptionId
      } catch {
        $message = "$displayName App Service Plan availability lookup failed in ${location}: $_"
        $checkErrors += $message
        $readinessResults += New-ReadinessResult -Location $location -Name $displayName -Status unknown -Category 'eligibility-check-failed' -Message $message
        Write-Warning $message
        continue
      }

      if (-not $planCheck.RegionAvailable) {
        $reason = "App Service Plan SKU $appServicePlanSku ($appServicePlanTier) is not offered in $location."
        $readinessResults += New-ReadinessResult -Location $location -Name $displayName -Status blocked -Category 'sku-unavailable' -Message $reason
        Write-Warning $reason
        continue
      }

      if ($null -eq $planCheck.Limit) {
        $message = "${displayName}: no Microsoft.Web quota entry matched family '$resourceName' and tier '$appServicePlanTier' in $location."
        $checkErrors += $message
        $readinessResults += New-ReadinessResult -Location $location -Name $displayName -Status unknown -Category 'quota-not-exposed' -Message $message
        Write-Warning $message
        continue
      }

      $limit = $planCheck.Limit
      $usage = $planCheck.Usage
      $available = $limit - $usage
      Write-Host "Current usage:      $usage"
      Write-Host "Current limit:      $limit"
      Write-Host "Available:          $available"

      if ($available -lt $requiredAvailable) {
        $reason = "App Service quota is insufficient in $location. Available: $available; required: $requiredAvailable."
        $readinessResults += New-ReadinessResult -Location $location -Name $displayName -Status blocked -Category 'quota-deficit' -Message $reason
        Write-Warning $reason
      } else {
        $message = "App Service quota and SKU checks passed. Physical scale-unit capacity cannot be verified before provisioning."
        $readinessResults += New-ReadinessResult -Location $location -Name $displayName -Status 'ready-with-risk' -Category 'runtime-capacity-unverifiable' -Message $message
        Write-Host "PASS WITH RISK: $message" -ForegroundColor Yellow
      }
      continue
    }

    if ($vmSku) {
      Write-Host "VM SKU:             $vmSku"
      try {
        $skuCheck = Test-VmSkuAvailability -Sku $vmSku -Location $location
      } catch {
        $message = "$displayName SKU availability lookup failed in ${location}: $_"
        $checkErrors += $message
        $readinessResults += New-ReadinessResult -Location $location -Name $displayName -Status unknown -Category 'eligibility-check-failed' -Message $message
        Write-Warning $message
        continue
      }

      if (-not $skuCheck.Found -or -not $skuCheck.Available) {
        $reason = "VM SKU $vmSku is unavailable or restricted for this subscription in $location."
        $readinessResults += New-ReadinessResult -Location $location -Name $displayName -Status blocked -Category 'sku-unavailable' -Message $reason
        Write-Warning $reason
        continue
      }

      if ($skuCheck.ZoneRestricted) {
        Write-Warning "SKU $vmSku has availability-zone restrictions in $location."
      }
      Write-Host "VM family:          $($skuCheck.Family)"
      if (-not $resourceName) { $resourceName = $skuCheck.Family }
    }

    $scope = if ($quota.scope) {
      ([string]$quota.scope).Replace('{location}', $location).Replace('{subscriptionId}', $subscriptionId)
    } else {
      "/subscriptions/$subscriptionId/providers/$providerNamespace/locations/$location"
    }

    Write-Host "Quota resource:     $resourceName"
    Write-Host "Required available: $requiredAvailable"
    Write-Host "Scope:              $scope"

    if (-not $providerNamespace -or -not $resourceName -or $requiredAvailable -lt 0) {
      $message = "$displayName has an invalid providerNamespace, resourceName, or requiredAvailable value."
      $checkErrors += $message
      $readinessResults += New-ReadinessResult -Location $location -Name $displayName -Status unknown -Category 'invalid-configuration' -Message $message
      Write-Warning $message
      continue
    }

    try {
      $limitResult = Invoke-AzJson -Arguments @(
        'quota', 'show',
        '--resource-name', $resourceName,
        '--scope', $scope,
        '--output', 'json'
      ) -Description "Quota limit lookup for $displayName"

      $usageResult = Invoke-AzJson -Arguments @(
        'quota', 'usage', 'show',
        '--resource-name', $resourceName,
        '--scope', $scope,
        '--output', 'json'
      ) -Description "Quota usage lookup for $displayName"

      $limit = [int]$limitResult.properties.limit.value
      $usage = [int]$usageResult.properties.usages.value
      $available = $limit - $usage
      Write-Host "Current usage:      $usage"
      Write-Host "Current limit:      $limit"
      Write-Host "Available:          $available"

      if ($available -lt $requiredAvailable) {
        $reason = "Quota is insufficient in $location. Available: $available; required: $requiredAvailable."
        $readinessResults += New-ReadinessResult -Location $location -Name $displayName -Status blocked -Category 'quota-deficit' -Message $reason
        Write-Warning $reason
      } else {
        $message = "Quota and eligibility checks passed."
        $readinessResults += New-ReadinessResult -Location $location -Name $displayName -Status ready -Category 'verified' -Message $message
        Write-Host "PASS: $message" -ForegroundColor Green
      }
    } catch {
      $message = "$displayName could not be checked in ${location}: $_"
      $checkErrors += $message
      $readinessResults += New-ReadinessResult -Location $location -Name $displayName -Status unknown -Category 'quota-check-failed' -Message $message
      Write-Warning $message
    }
  }
}

New-Item -ItemType Directory -Path $ArtifactDirectory -Force | Out-Null
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$readinessJsonPath = Join-Path $ArtifactDirectory "deployment-readiness-$timestamp.json"
$readinessMarkdownPath = Join-Path $ArtifactDirectory "deployment-readiness-$timestamp.md"

$readinessResults | ConvertTo-Json -Depth 8 -AsArray | Out-File -FilePath $readinessJsonPath -Encoding utf8
$readinessSummary = New-Object System.Text.StringBuilder
$readinessSummary.AppendLine("# Deployment readiness - $timestamp") | Out-Null
$readinessSummary.AppendLine() | Out-Null
$readinessSummary.AppendLine("| Region | Check | Status | Category | Detail |") | Out-Null
$readinessSummary.AppendLine("|---|---|---|---|---|") | Out-Null
foreach ($result in $readinessResults) {
  $safeMessage = ([string]$result.message).Replace('|', '\|').Replace("`r", ' ').Replace("`n", ' ')
  $readinessSummary.AppendLine("| $($result.location) | $($result.name) | $($result.status) | $($result.category) | $safeMessage |") | Out-Null
}
$readinessSummary.AppendLine() | Out-Null
$readinessSummary.AppendLine('`ready-with-risk` means all verifiable checks passed, but Azure does not expose a reliable predeployment physical-capacity signal for the service.') | Out-Null
$readinessSummary.ToString() | Out-File -FilePath $readinessMarkdownPath -Encoding utf8

Write-Step "Deployment readiness summary"
$readinessResults | Format-Table location, name, status, category -AutoSize
Write-Host "Readiness JSON: $readinessJsonPath"
Write-Host "Readiness summary: $readinessMarkdownPath"

if (@($readinessResults | Where-Object status -eq 'unknown').Count -gt 0) {
  $checkErrors | ForEach-Object { Write-Host "- $_" -ForegroundColor Red }
  [Console]::Error.WriteLine("One or more readiness checks are unknown. No deployment decision should be made from partial results.")
  exit 3
}

if (@($readinessResults | Where-Object status -eq 'blocked').Count -eq 0) {
  $hasResidualRisk = @($readinessResults | Where-Object status -eq 'ready-with-risk').Count -gt 0
  if ($hasResidualRisk) {
    Write-Host "All verifiable quota, eligibility, and configuration checks passed. One or more services retain unverifiable runtime-capacity risk." -ForegroundColor Yellow
  } else {
    Write-Host "All configured quota, eligibility, and configuration checks passed." -ForegroundColor Green
  }
  exit 0
}

[Console]::Error.WriteLine("One or more known readiness blockers were found.")
exit 2
