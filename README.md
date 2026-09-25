# Deployment Readiness Validator

Validate Azure deployment prerequisites before provisioning resources.

The validator surfaces issues that Azure exposes programmatically:

- quota deficits;
- unregistered resource providers;
- subscription and regional SKU restrictions;
- Azure OpenAI account eligibility and model quota;
- Azure AI Search SKU and service-count quota;
- PostgreSQL Flexible Server SKU and availability-zone compatibility;
- App Service regional SKU and quota headroom;
- exact VM SKU restrictions.

It does not claim to predict physical PaaS capacity. App Service and Azure AI
Search are returned as `ready-with-risk` when every verifiable check passes but
Azure does not expose a reliable allocation signal.

## Requirements

- PowerShell 7
- Azure CLI
- Azure CLI `quota` extension when the configuration contains providers checked
  through Microsoft.Quota
- Reader access to the target subscription and quota APIs

```powershell
az extension add --name quota --upgrade --yes
az login
az account set --subscription <subscription-id>
```

## Configure

Copy the sample and edit it for the deployment:

```powershell
Copy-Item readiness-config.sample.json readiness-config.json
```

Use `locations` to assess primary and fallback regions in one run. The legacy
single `location` property is also supported.

```json
{
  "subscriptionId": "<subscription-id>",
  "locations": ["centralus", "westus3"],
  "quotas": [
    {
      "name": "PostgreSQL Burstable fleet",
      "providerNamespace": "Microsoft.DBforPostgreSQL",
      "resourceName": "standardBSFamily",
      "postgresFlexibleSku": "Standard_B2ms",
      "availabilityZone": "auto",
      "instanceCount": 7,
      "vCoresPerInstance": 2
    },
    {
      "name": "Azure OpenAI model quota",
      "providerNamespace": "Microsoft.CognitiveServices",
      "azureOpenAISku": "S0",
      "azureOpenAIModel": "gpt-4o",
      "azureOpenAIDeploymentType": "GlobalStandard",
      "requiredAvailable": 10
    },
    {
      "name": "Azure AI Search",
      "providerNamespace": "Microsoft.Search",
      "aiSearchSku": "standard",
      "requiredAvailable": 1
    }
  ]
}
```

Custom quota scopes can contain `{subscriptionId}` and `{location}`
placeholders.

## Run

```powershell
pwsh ./scripts/check-deployment-readiness.ps1 `
  -ConfigPath ./readiness-config.json
```

Results are printed to the console and written to
`artifacts/deployment-readiness/` as JSON and Markdown.

## Result statuses

| Status | Meaning |
|---|---|
| `ready` | All verifiable checks passed |
| `blocked` | A known issue prevents deployment |
| `ready-with-risk` | Checks passed, but runtime capacity cannot be verified |
| `unknown` | Azure did not expose the information or a query failed |

## Exit codes

| Code | Meaning |
|---|---|
| `0` | No known blocker; results can include `ready-with-risk` |
| `2` | At least one known blocker |
| `3` | At least one check is unknown or incomplete |
| `4+` | Execution or Azure CLI failure |

## GitHub Actions

The included workflow uses the `AZURE_CREDENTIALS` repository secret. Create a
deployment-specific `readiness-config.json` before running it.

The repository intentionally contains no quota-request submission, support
ticket generation, infrastructure deployment, dashboards, or quota-utilization
reporting components.
