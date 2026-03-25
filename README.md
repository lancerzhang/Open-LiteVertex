# Open LiteVertex

Open LiteVertex deploys a minimal `LiteLLM -> Vertex AI` gateway on `GKE Autopilot` and creates a weekly-budgeted API key suitable for `OpenCode`.

What Open LiteVertex does now:

- Creates or reuses a `GKE Autopilot` cluster.
- Deploys `Postgres` inside the cluster for LiteLLM state.
- Builds a thin custom LiteLLM image on top of the official stable image.
- Uses `Workload Identity` so LiteLLM can call `Vertex AI` without a JSON key.
- Loads `custom_auth` inside the LiteLLM pod for `Entra JWT groups` validation.
- Creates a demo key with a `$50 / 7d` budget.
- Writes the endpoint and key to `.demo.env`.

What still needs your input:

- `Microsoft Entra ID` tenant / app values if you want to turn on Entra JWT auth.

## Files

- `config/litellm-config.yaml`: base LiteLLM config for Vertex AI.
- `config/litellm-config.entra-example.yaml`: older Enterprise-only reference snippet.
- `config/auth_handler.py`: OSS `custom_auth` handler for Entra groups plus LiteLLM keys.
- `config/opencode.example.json`: example `OpenCode` provider config.
- `k8s/`: Kubernetes manifests.
- `scripts/deploy-demo.ps1`: cluster bootstrap + deployment.
- `scripts/bootstrap-user-key.ps1`: create a weekly-budgeted LiteLLM key.
- `scripts/create-entra-team.ps1`: create a LiteLLM team whose `team_id` matches an Entra group ID.
- `scripts/setup-entra-oss.ps1`: create a dedicated Entra API app + allowed security group for the OSS path.
- `scripts/get-entra-token.ps1`: fetch a delegated access token for the API app via Azure CLI.
- `scripts/decode-jwt.ps1`: inspect a JWT locally and confirm `aud`, `iss`, and `groups`.
- `scripts/start-opencode-entra-direct.ps1`: launch `OpenCode` using a fresh Entra access token directly against LiteLLM.
- `scripts/start-entra-broker.ps1`: start a local auto-refresh broker on `127.0.0.1`.
- `scripts/start-opencode-entra-broker.ps1`: launch `OpenCode` against the local broker.
- `scripts/stop-entra-broker.ps1`: stop the local broker.
- `scripts/entra_litellm_broker.py`: local FastAPI broker that refreshes Entra tokens with Azure CLI and forwards to LiteLLM.

## Quick Start

From `D:\ws\vertex-dev`:

```powershell
.\scripts\deploy-demo.ps1
Get-Content .demo.env
```

Then point `OpenCode` at the generated endpoint/key using `config/opencode.example.json`.

For the full OSS architecture and user flow, see:

- [docs/opencode-litellm-entra-vertex-flow.md](D:/ws/vertex-dev/docs/opencode-litellm-entra-vertex-flow.md)

## Entra Notes

LiteLLM's built-in `OIDC - JWT-based Auth` is documented as an Enterprise feature. Open LiteVertex stays on LiteLLM OSS and uses `general_settings.custom_auth` instead, so there is still only one LiteLLM service in the cluster.

If `.entra.env` exists when you run `.\scripts\deploy-demo.ps1`, the script injects these values into the LiteLLM deployment:

- `ENTRA_TENANT_ID`
- `ENTRA_CLIENT_ID`
- `ENTRA_ALLOWED_GROUP_ID` or `ENTRA_ALLOWED_GROUP_IDS`
- optional `ENTRA_ISSUER`
- optional `ENTRA_JWKS_URI`

## Entra OSS Setup

The open-source path uses LiteLLM `custom_auth` inside the LiteLLM pod. To create the Entra values it needs:

```powershell
.\scripts\setup-entra-oss.ps1 `
  -TenantId "<your-tenant-id>" `
  -AllowedGroupName "opencode-users" `
  -MemberUpns "alice@contoso.com","bob@contoso.com"
```

This script writes `.entra.env` with:

- `ENTRA_TENANT_ID`
- `ENTRA_CLIENT_ID`
- `ENTRA_ALLOWED_GROUP_ID`
- `ENTRA_SCOPE`
- `ENTRA_ISSUER`
- `ENTRA_JWKS_URI`

To get a token for testing:

```powershell
$resp = .\scripts\get-entra-token.ps1 -TenantId "<tenant-id>" -ClientId "<client-id>" | ConvertFrom-Json
.\scripts\decode-jwt.ps1 -Token $resp.accessToken
```

## OpenCode with Entra

For a quick direct test, launch `OpenCode` with a fresh Entra access token:

```powershell
.\scripts\start-opencode-entra-direct.ps1
```

This reuses the project `opencode.json` and injects:

- `LITELLM_OPENAI_BASE_URL=<litellm>/v1`
- `LITELLM_API_KEY=<entra_access_token>`

For a smoother local dev loop, start the local broker once and point `OpenCode` at `localhost`:

```powershell
.\scripts\start-entra-broker.ps1
.\scripts\start-opencode-entra-broker.ps1
```

The broker uses Azure CLI to refresh the Entra token before expiry and forwards requests to LiteLLM. To stop it:

```powershell
.\scripts\stop-entra-broker.ps1
```
