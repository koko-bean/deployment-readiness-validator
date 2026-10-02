param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$CliArgs
)

$command = $CliArgs -join ' '
Add-Content -Path $env:FAKE_AZ_LOG -Value $command
$scenario = $env:FAKE_AZ_SCENARIO

if ($command -eq 'version --output json') {
  $version = if ($scenario -eq 'old-cli') { '2.59.0' } else { '2.60.0' }
  Write-Output "{`"azure-cli`":`"$version`"}"
  exit 0
}

if ($command -eq 'account show --output json') {
  Write-Output '{"id":"00000000-0000-0000-0000-000000000000","state":"Enabled","user":{"name":"test@example.com","type":"user"}}'
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
  Write-Output '["East US"]'
  exit 0
}

if ($command -like 'account list-locations *') {
  Write-Output '[{"name":"eastus","displayName":"East US"}]'
  exit 0
}

if ($command -like 'rest *Microsoft.Web/locations/eastus/usages*') {
  Write-Output '{"value":[{"name":{"value":"standardDADSv5Family","localizedValue":"Basic"},"limit":20,"currentValue":1}]}'
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
