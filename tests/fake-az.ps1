param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$CliArgs
)

$command = $CliArgs -join ' '
Add-Content -Path $env:FAKE_AZ_LOG -Value $command
$scenario = $env:FAKE_AZ_SCENARIO

function Get-Argument([string]$Name) {
  $index = [array]::IndexOf($CliArgs, $Name)
  if ($index -ge 0) { return $CliArgs[$index + 1] }
}

if ($command -match '^(group |deployment |resource list |cognitiveservices account )') {
  $statePath = "$($env:FAKE_AZ_LOG).state.json"
  $state = if (Test-Path $statePath) { Get-Content $statePath -Raw | ConvertFrom-Json -AsHashtable } else {
    @{ groupExists = ($scenario -eq 'canary-existing-group'); deployments = @{}; deleted = @(); passwords = @(); canceled = @() }
  }
  $result = $null
  $name = Get-Argument '--name'
  if ($command -like 'group exists *') { $result = $state.groupExists }
  elseif ($command -like 'group create *') {
    $state.groupExists = $true
    $state.tags = @{ runId = ($CliArgs | Where-Object { $_ -like 'runId=*' }).Substring(6); purpose = 'deployment-readiness-canary' }
    $result = @{ id = 'test-group' }
    if ($scenario -eq 'canary-group-error') {
      $state | ConvertTo-Json -Depth 30 | Set-Content $statePath
      Write-Error 'Create failed after acceptance'
      exit 1
    }
  }
  elseif ($command -like 'group show *') {
    $result = @{ tags = if ($scenario -eq 'canary-ownership-error') { @{ runId = 'another-run'; purpose = 'deployment-readiness-canary' } } else { $state.tags } }
  }
  elseif ($command -like 'deployment group create *') {
    $templatePath = Get-Argument '--template-file'
    $template = Get-Content $templatePath -Raw | ConvertFrom-Json -AsHashtable
    $template | ConvertTo-Json -Depth 30 -Compress | Add-Content "$($env:FAKE_AZ_LOG).templates.jsonl"
    $parameters = Get-Argument '--parameters'
    if ($parameters) {
      $parameterFile = Get-Content $parameters.Substring(1) -Raw | ConvertFrom-Json
      $state.passwords += $parameterFile.parameters.administratorPassword.value
    }
    $state.deployments[$name] = @{ template = $template; observations = 0 }
    $result = @{}
  }
  elseif ($command -like 'deployment group show *') {
    if (-not $state.deployments.ContainsKey($name)) { Write-Error 'DeploymentNotFound'; exit 1 }
    $state.deployments[$name].observations++
    if ($scenario -eq 'canary-poll-error' -and $state.deployments[$name].observations -eq 1) {
      $state | ConvertTo-Json -Depth 30 | Set-Content $statePath
      Write-Error 'Poll failed'
      exit 1
    }
    $provisioningState = if ($scenario -eq 'canary-capacity' -or $scenario -eq 'canary-secret-error') { 'Failed' }
      elseif ($scenario -eq 'canary-poll-error' -and $state.canceled -notcontains $name) { 'Running' }
      elseif ($scenario -eq 'canary-async' -and $state.deployments[$name].observations -eq 1) { 'Running' }
      else { 'Succeeded' }
    $result = @{ properties = @{ provisioningState = $provisioningState; error = @{ code = 'DeploymentFailed'; message = 'See nested operations' } } }
  }
  elseif ($command -like 'deployment operation group list *') {
    $message = if ($scenario -eq 'canary-secret-error') { "Unexpected server error: $($state.passwords[0])" } else { 'AllocationFailed: regional capacity exhausted' }
    $result = @(@{ properties = @{ provisioningState = 'Failed'; statusMessage = @{ error = @{ code = 'DeploymentFailed'; details = @(@{ code = 'NestedError'; message = $message }) } } } })
  }
  elseif ($command -like 'deployment group cancel *') { $state.canceled += $name; $result = @{} }
  elseif ($command -like 'group delete *') {
    if ($scenario -eq 'canary-cleanup-error') { Write-Error 'AuthorizationFailed: cannot delete'; exit 1 }
    $state.groupExists = $false
    $groupName = Get-Argument '--name'
    foreach ($deployment in $state.deployments.Values) {
      foreach ($resource in $deployment.template.resources) {
        if ($resource.type -eq 'Microsoft.CognitiveServices/accounts') {
          $state.deleted += @{ id = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.CognitiveServices/locations/$($resource.location)/resourceGroups/$groupName/deletedAccounts/$($resource.name)" }
        }
      }
    }
    $result = @{}
  }
  elseif ($command -like 'resource list *') { $result = @(@{ id = '/subscriptions/test/resourceGroups/leftover/providers/Microsoft.Search/searchServices/leftover' }) }
  elseif ($command -like 'cognitiveservices account purge *') {
    if ($scenario -eq 'canary-purge-error') { Write-Error 'AuthorizationFailed: cannot purge'; exit 1 }
    $state.deleted = @($state.deleted | Where-Object { $_.id -notlike "*/deletedAccounts/$name" })
    $result = @{}
  }
  elseif ($command -like 'cognitiveservices account list-deleted *') { $result = @($state.deleted) }
  else { Write-Error "Unexpected canary command: $command"; exit 9 }
  $state | ConvertTo-Json -Depth 30 | Set-Content $statePath
  ConvertTo-Json -InputObject $result -Depth 30 -Compress
  exit 0
}

if ($command -eq 'version --output json') {
  $version = if ($scenario -eq 'old-cli') { '2.59.0' } else { '2.60.0' }
  Write-Output "{`"azure-cli`":`"$version`"}"
  exit 0
}

if ($command -like 'account show *') {
  Write-Output '{"id":"00000000-0000-0000-0000-000000000000","state":"Enabled","user":{"name":"test@example.com","type":"user"}}'
  exit 0
}

if ($command -like 'rest *Microsoft.CognitiveServices/locations/*/models*') {
  Write-Output '{"value":[{"kind":"OpenAI","skuName":"S0","model":{"format":"OpenAI","name":"gpt-5.1","version":"2025-01-01","isDefaultVersion":true,"skus":[{"name":"DataZoneStandard","capacity":{"minimum":1}}]}},{"kind":"OpenAI","skuName":"S0","model":{"format":"OpenAI","name":"gpt-5.1","version":"2025-11-13","isDefaultVersion":false,"skus":[{"name":"DataZoneStandard","capacity":{"minimum":1}}]}}]}'
  exit 0
}

if ($command -like 'provider show *') {
  $state = if ($scenario -eq 'provider-blocked' -and $command -like '*Microsoft.Cache*') { 'NotRegistered' } else { 'Registered' }
  Write-Output "{`"state`":`"$state`"}"
  exit 0
}

if ($command -like 'rest *Microsoft.Authorization/permissions*') {
  Write-Output '{"value":[{"actions":["*"],"notActions":[]}]}'
  exit 0
}

if ($command -like 'appservice list-locations *') {
  if ($scenario -eq 'appservice-unavailable') { Write-Output '[]'; exit 0 }
  Write-Output '["East US"]'
  exit 0
}

if ($command -like 'account list-locations *') {
  if ($CliArgs -contains '--subscription') { Write-Error 'unrecognized arguments: --subscription'; exit 2 }
  Write-Output '[{"name":"eastus","displayName":"East US"}]'
  exit 0
}

if ($command -like 'rest *Microsoft.Web/locations/eastus/usages*') {
  if ($command -notlike '*api-version=2024-11-01*' -or $scenario -eq 'appservice-api-error') {
    Write-Error 'MethodNotAllowed: The requested method is not implemented.'
    exit 1
  }
  $skuCounter = @{ name = @{ value = 'B1'; localizedValue = 'B1 VMs' }; limit = 20; currentValue = 1 }
  $totalCounter = @{ name = @{ value = '*'; localizedValue = 'Total Regional VMs' }; limit = 100; currentValue = 2 }
  switch ($scenario) {
    'appservice-sku-deficit' { $skuCounter.limit = 14 }
    'appservice-regional-deficit' { $totalCounter.limit = 15 }
    'appservice-boundary' { $skuCounter.limit = 15; $totalCounter.limit = 16 }
    'appservice-zero' { $skuCounter.limit = 0; $skuCounter.currentValue = 0 }
    'appservice-negative-limit' { $skuCounter.limit = -1 }
    'appservice-negative-usage' { $skuCounter.currentValue = -1 }
    'appservice-invalid-limit' { $skuCounter.limit = 'invalid' }
    'appservice-null-usage' { $skuCounter.currentValue = $null }
  }
  $counters = @($skuCounter, $totalCounter)
  if ($scenario -eq 'appservice-missing-sku') { $counters = @($totalCounter) }
  if ($scenario -eq 'appservice-missing-total') { $counters = @($skuCounter) }
  if ($scenario -eq 'appservice-missing-sku-deficit') { $totalCounter.limit = 0; $totalCounter.currentValue = 0; $counters = @($totalCounter) }
  if ($scenario -eq 'appservice-duplicate') { $counters += $skuCounter }
  if ($scenario -eq 'appservice-legacy') {
    $counters = @(@{ name = @{ value = 'standardDADSv5Family'; localizedValue = 'Basic' }; limit = -1; currentValue = 1 })
  }
  @{ value = $counters } | ConvertTo-Json -Depth 8 -Compress
  exit 0
}

if ($command -like 'postgres flexible-server list-skus *') {
  Write-Output '{"supportedZones":["1","2","3"],"supportedServerEditions":[{"name":"GeneralPurpose","supportedServerSkus":[{"name":"Standard_D2ds_v5"}]}]}'
  exit 0
}

if ($command -like 'rest *Microsoft.DBforPostgreSQL/locations/eastus/resourceType/flexibleServers/usages*') {
  Write-Output '{"value":[{"name":{"value":"standardDDSv5Family","localizedValue":"Standard DDSv5 Family"},"limit":100,"currentValue":5}]}'
  exit 0
}

if ($command -like 'rest *Microsoft.CognitiveServices/skus*') {
  Write-Output '{"value":[{"name":"S0","resourceType":"accounts","kind":"OpenAI","locations":["EastUS"],"restrictions":[]}]}'
  exit 0
}

if ($command -like 'cognitiveservices usage list *') {
  Write-Output '[{"name":{"value":"OpenAI.DataZoneStandard.gpt-5.1"},"limit":100,"currentValue":0}]'
  exit 0
}

if ($command -like 'rest *Microsoft.Search/locations/eastus/usages*') {
  if ($scenario -eq 'search-blocked') {
    Write-Output '{"value":[{"name":{"value":"standard","localizedValue":"Standard"},"limit":1,"currentValue":1}]}'
  } else {
    Write-Output '{"value":[{"name":{"value":"standard","localizedValue":"Standard"},"limit":5,"currentValue":1}]}'
  }
  exit 0
}

if ($command -like 'rest *Microsoft.Cache/skus*') {
  Write-Output '{"value":[{"name":"Balanced_B1","resourceType":"redisEnterprise","locations":["EASTUS"],"restrictions":[]}]}'
  exit 0
}

Write-Error "Unexpected az command: $command"
exit 9
