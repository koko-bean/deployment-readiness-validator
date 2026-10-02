# Deployment Readiness Validator

Validate Azure deployment prerequisites before provisioning resources.

The validator surfaces issues that Azure exposes programmatically:

- quota deficits;
- missing effective ARM permissions;
- unregistered resource providers;
- unregistered subscription feature flags;
- unsupported Azure CLI or missing extension prerequisites;
- subscription and regional SKU restrictions;
- Azure OpenAI account eligibility and model quota;
- Azure AI Search SKU and service-count quota;
- Azure Managed Redis SKU eligibility;
- PostgreSQL Flexible Server SKU and availability-zone compatibility;
- App Service regional SKU and quota headroom;
- exact VM SKU restrictions.

It does not claim to predict physical PaaS capacity. App Service, Azure AI
Search, and Azure Managed Redis are returned as `ready-with-risk` when every
verifiable check passes but Azure does not expose a reliable allocation signal.

## Requirements

- PowerShell 7
- Azure CLI
- Azure CLI `quota` extension only when the configuration contains generic
  providers checked through Microsoft.Quota
- Reader access to the target subscription and quota APIs

```powershell
az login
az account set --subscription <subscription-id>
```

Install the quota extension only for configurations that include generic
Microsoft.Quota checks:

```powershell
az extension add --name quota --upgrade --yes
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
  "prerequisites": {
    "minimumAzureCliVersion": "2.60.0",
    "requiredProviders": [
      "Microsoft.Authorization",
      "Microsoft.Web",
      "Microsoft.DBforPostgreSQL",
      "Microsoft.CognitiveServices",
      "Microsoft.Search",
      "Microsoft.Cache"
    ],
    "requiredPermissions": [],
    "requiredFeatures": []
  },
  "locations": ["eastus", "westus3"],
  "quotas": [
    {
      "name": "Basic App Service Plan",
      "providerNamespace": "Microsoft.Web",
      "resourceName": "standardDADSv5Family",
      "appServicePlanSku": "B1",
      "appServicePlanTier": "Basic",
      "requiredAvailable": 14
    },
    {
      "name": "PostgreSQL Flexible Server General Purpose vCores",
      "providerNamespace": "Microsoft.DBforPostgreSQL",
      "resourceName": "standardDDSv5Family",
      "postgresFlexibleSku": "GP_Standard_D2ds_v5",
      "availabilityZone": "auto",
      "instanceCount": 8,
      "vCoresPerInstance": 2
    },
    {
      "name": "Azure OpenAI",
      "providerNamespace": "Microsoft.CognitiveServices",
      "azureOpenAISku": "S0",
      "azureOpenAIModel": "gpt-5.1",
      "azureOpenAIDeploymentType": "DataZoneStandard",
      "requiredAvailable": 10
    },
    {
      "name": "Azure AI Search",
      "providerNamespace": "Microsoft.Search",
      "aiSearchSku": "standard",
      "requiredAvailable": 1
    },
    {
      "name": "Azure Managed Redis",
      "providerNamespace": "Microsoft.Cache",
      "redisEnterpriseSku": "Balanced_B1",
      "requiredAvailable": 1
    }
  ]
}
```

Omit `subscriptionId` to use the active Azure CLI subscription. If
`subscriptionId` is set explicitly, the validator requires it to match the
active `az account show` context.

Custom quota scopes can contain `{subscriptionId}` and `{location}`
placeholders.

## Subscription prerequisites

The validator checks standard prerequisites before evaluating regions:

- minimum Azure CLI version;
- authenticated and enabled subscription;
- Azure CLI `quota` extension when Microsoft.Quota checks are configured;
- registration state for every provider derived from the resource checks;
- additional providers listed in `prerequisites.requiredProviders`;
- effective ARM permissions at subscription scope;
- optional Azure feature registrations.

The baseline permission checks include:

- `Microsoft.Resources/subscriptions/read`
- `Microsoft.Resources/subscriptions/providers/read`
- `Microsoft.Quota/quotas/read` when Microsoft.Quota is used
- `Microsoft.Quota/usages/read` when Microsoft.Quota is used

Add deployment-specific ARM actions to `requiredPermissions` when a custom role
must be validated:

```json
"requiredPermissions": [
  "Microsoft.Network/virtualNetworks/read"
]
```

Feature registrations are optional and use namespace/name pairs:

```json
"requiredFeatures": [
  {
    "namespace": "Microsoft.Example",
    "name": "RequiredPreviewFeature"
  }
]
```

Missing permissions, providers, disabled subscriptions, and unregistered
features are `blocked`. A prerequisite that cannot be queried is `unknown`.

PostgreSQL Flexible Server, App Service, Azure OpenAI, Azure AI Search, and
Azure Managed Redis use their service-specific APIs and do not require the
Microsoft.Quota provider or Azure CLI quota extension. Managed Redis can verify
that `Balanced_B1` is offered, but Azure does not expose a dependable
predeployment physical-capacity or service-count quota signal.

## Run

```powershell
pwsh ./scripts/check-deployment-readiness.ps1 `
  -ConfigPath ./readiness-config.json
```

Results are printed to the console and written to
`artifacts/deployment-readiness/` as JSON and Markdown.

Run the focused fixture tests with:

```powershell
pwsh ./tests/run-tests.ps1
```

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
