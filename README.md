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

App Service uses the Microsoft.Web usages API version `2024-11-01` and checks
both the exact `appServicePlanSku` counter (for example, `B1`) and the total
regional `*` counter against `requiredAvailable` additional instances.
`appServicePlanTier` remains required; `resourceName` is no longer needed for
App Service (existing values are ignored). Legacy family/tier quota responses
are not interchangeable with the newer SKU counters. Missing, duplicated,
malformed, or negative counters produce `unknown`, unless another usable
counter already proves a quota deficit. API errors, including
`MethodNotAllowed`, remain `unknown`; there is no silent legacy API fallback.

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

The workflow runs readiness checks only. Infrastructure deployment is available
through the separate **opt-in canary stage** below; it is not enabled in CI.
There is no quota-request submission, support ticket generation, dashboard, or
quota-utilization reporting.

## Opt-in deployment canaries

Run readiness first, even when it returns exit `2` because some services are
blocked. Then plan or execute canaries for the remaining `ready` or
`ready-with-risk` services:

```powershell
pwsh -NoProfile -File scripts\check-deployment-readiness.ps1 `
  -ConfigPath readiness-config.sample.json

# Dry run (default): plan only; no Azure resources are created.
pwsh -NoProfile -File scripts\run-canary-deployments.ps1 `
  -ConfigPath readiness-config.sample.json

# Creates temporary resources, polls ARM, and destroys them.
pwsh -NoProfile -File scripts\run-canary-deployments.ps1 `
  -ConfigPath readiness-config.sample.json -Execute
```

`-ReadinessReport` selects an explicit JSON report; otherwise the newest
`deployment-readiness-*.json` in `-ArtifactDirectory` is used. The artifact
directory defaults to `artifacts\deployment-readiness`. `-TimeoutMinutes`
defaults to 60 for deployment polling, with a separate cleanup polling budget
of the same length. `-PollIntervalSeconds` defaults to 10. Azure CLI calls
themselves may take longer than the polling deadline.

Use the same unchanged configuration and active `az login` subscription for
both stages. The readiness JSON remains an array, with additive
`subscriptionId` and SHA-256 `configurationHash` fields on each row. Execution
rejects reports without matching provenance; regenerate older reports. The
script pins Azure calls to that subscription. Reports remain point-in-time
snapshots; rerun readiness immediately before executing canaries.

### Footprints and scope

Each eligible service/region gets a separate incremental ARM deployment:

| Service | Minimal canary |
|---|---|
| App Service | Configured SKU and tier, one Linux plan instance (no web app) |
| PostgreSQL Flexible Server | Configured prefixed SKU (`GP_`, `MO_`, or `B_`), 32 GB storage, HA disabled, PostgreSQL 16, public access disabled; explicit non-`auto` zone honored |
| OpenAI | Configured account SKU, public access and local authentication disabled, model deployment capacity 1 |
| AI Search | Configured SKU, one replica and partition, public access and local authentication disabled |
| Managed Redis | Configured SKU, HA disabled, TLS default database, access-key authentication disabled |

OpenAI resolves a compatible default model version from the regional models
API, with the latest compatible version as fallback. Set
`azureOpenAIModelVersion` on the quota entry to pin a version. Deployment types
requiring capacity above 1 are rejected for review rather than silently
provisioning a larger, expensive footprint. VM and generic quota entries
produce `canary-not-supported`; blocked/unknown services are skipped. Missing,
blocked, or unknown subscription prerequisites prevent canary submission.
Redis's selected ARM API does not expose a public-network-access switch; no
credentials or data are loaded, and key authentication is disabled.

### Safety, cost, and permissions

Execution **incurs normal Azure charges** for the selected SKUs until deletion.
No application traffic, inference, or customer data is sent. Minimal footprints
are not necessarily cheap when the configured SKU is large. Review the dry-run
plan and SKU prices before opting in.

The runner creates one new group tagged with `purpose`, `createdBy`, `runId`,
and `expiresAt`. `-ResourceGroupName` overrides the generated name but **must
not already exist**. The runner refuses to delete a group whose ownership tags
do not match its run. Never add other resources to this group while it runs.
Expiry tags are informational, not an automatic deletion policy.

Use **Contributor on the subscription**, or a custom role granting resource
group creation/read/deletion, ARM deployment/operation read/write/cancel,
resource enumeration, and the selected service resource/child-resource actions.
OpenAI cleanup additionally requires
`Microsoft.CognitiveServices/locations/resourceGroups/deletedAccounts/delete`
and the corresponding deleted-account read/list permissions. Reader alone
cannot execute canaries. Organizational policies/locks can block creation,
deletion, or purge even with Contributor.

A `finally` block cancels nonterminal deployments, deletes the group, polls
until it no longer exists, and purges/verifies soft-deleted OpenAI accounts.
PostgreSQL passwords are cryptographically generated, passed as ARM
`secureString` through protected temporary parameter files, redacted from
errors, and removed immediately after submission. They are never written into
reports or command arguments.

**Do not force-kill the process or close its host while it runs.** Power loss,
host termination, Azure permissions, locks, or outages can prevent cleanup.
Keep the group name from the JSON report and remove any remaining group/accounts
manually when necessary. Before provisioning, the runner writes a secret-free
`canary-recovery-<runId>.json` inventory so group/account identifiers remain
available even if the process is terminated before the hand-off is generated.
Cleanup failures return exit `4`, with a prominent
warning and leftover or unverified resource IDs in the reports.

### Customer/business-unit hand-off

Both modes generate `subscription-readiness-<runId>.json` and `.md` in the
artifact directory. They include subscription, UTC timestamps, regions,
subscription prerequisites, executive counts, per-service readiness/canary/
cleanup/purge results, ARM failure details, final verdicts, and next actions.

| Final verdict | Meaning |
|---|---|
| `verified-deployable` | Minimal ARM deployment succeeded and resource cleanup succeeded |
| `not-deployable` | Known readiness blocker or ARM quota/capacity/region failure |
| `needs-review` | Unknown readiness, missing prerequisites, noncapacity error, timeout, or failed cleanup |
| `not-tested` | Dry-run eligible entry or unsupported canary type |

Canary exit codes are separate from readiness exit codes:

| Code | Meaning |
|---|---|
| `0` | Every tested canary and cleanup succeeded (dry runs/unsupported entries may remain untested) |
| `2` | Known not-deployable result, including skipped readiness blockers |
| `3` | Needs-review, unknown, or execution/configuration error; takes priority over `2` |
| `4` | Cleanup/cancellation/purge failure; highest priority |

These are **minimal, point-in-time deployment results**. They reserve no
capacity and do **not** prove full-scale capacity (such as 14 App Service
instances or 8 PostgreSQL servers), connectivity, data-plane functionality,
performance, or application correctness. Reassess quota and capacity before
production rollout. Generated artifacts are ignored by Git; review their
subscription/resource identifiers before distributing them.
