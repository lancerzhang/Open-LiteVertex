# Open LiteVertex

Open LiteVertex deploys a minimal `LiteLLM -> Vertex AI` gateway on `GKE Autopilot` and creates a weekly-budgeted API key suitable for `OpenCode`.

What Open LiteVertex does now:

- Creates or reuses a `GKE Autopilot` cluster.
- Deploys `Postgres` inside the cluster for LiteLLM state.
- Builds a thin custom LiteLLM image on top of the official stable image.
- Uses `Workload Identity` so LiteLLM can call `Vertex AI` without a JSON key.
- Loads `custom_auth` inside the LiteLLM pod for `Entra JWT groups` validation.
- Auto-creates a LiteLLM internal user per Entra `oid` and places Entra users into a shared LiteLLM team.
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
- `scripts/setup-entra-oss.ps1`: create a dedicated Entra API app, a separate public client app for device code login, and the allowed security group.
- `scripts/get-entra-token.ps1`: fetch a delegated access token for the API app via native device code or Azure CLI fallback.
- `scripts/get-entra-token.sh`: Linux wrapper for delegated Entra token acquisition, preferring native device code.
- `scripts/decode-jwt.ps1`: inspect a JWT locally and confirm `aud`, `iss`, and `groups`.
- `scripts/start-opencode-entra-direct.ps1`: launch `OpenCode` using a fresh Entra access token directly against LiteLLM.
- `scripts/start-opencode-entra-direct.sh`: Linux wrapper for direct Entra token mode.
- `scripts/start-entra-broker.ps1`: start a local auto-refresh broker on `127.0.0.1`.
- `scripts/start-entra-broker.sh`: Linux wrapper for the local auto-refresh broker.
- `scripts/start-opencode-entra-broker.ps1`: launch `OpenCode` against the local broker.
- `scripts/start-opencode-entra-broker.sh`: Linux wrapper for broker mode.
- `scripts/stop-entra-broker.ps1`: stop the local broker.
- `scripts/stop-entra-broker.sh`: Linux wrapper to stop the local broker.
- `scripts/entra_client.py`: shared cross-platform client entrypoint used by the Windows and Linux wrappers.
- `scripts/entra_auth.py`: shared Entra auth helper for native device code, refresh-token cache, and Azure CLI fallback.
- `scripts/entra_litellm_broker.py`: local FastAPI broker that refreshes Entra tokens and forwards to LiteLLM.

## Quick Start

From the repo root:

```powershell
.\scripts\deploy-demo.ps1
Get-Content .demo.env
```

Then point `OpenCode` at the generated endpoint/key using `config/opencode.example.json`.

For the full OSS architecture and user flow, see:

- [docs/opencode-litellm-entra-vertex-flow.md](docs/opencode-litellm-entra-vertex-flow.md)

## Entra Notes

LiteLLM's built-in `OIDC - JWT-based Auth` is documented as an Enterprise feature. Open LiteVertex stays on LiteLLM OSS and uses `general_settings.custom_auth` instead, so there is still only one LiteLLM service in the cluster.

If `.entra.env` exists when you run `.\scripts\deploy-demo.ps1`, the script injects these values into the LiteLLM deployment:

- `ENTRA_TENANT_ID`
- `ENTRA_CLIENT_ID`
- `ENTRA_ALLOWED_GROUP_ID` or `ENTRA_ALLOWED_GROUP_IDS`
- optional `ENTRA_ISSUER`
- optional `ENTRA_JWKS_URI`
- optional `ENTRA_SHARED_TEAM_ID`
- optional `ENTRA_SHARED_TEAM_ALIAS`
- optional `ENTRA_SHARED_TEAM_MAX_BUDGET`
- optional `ENTRA_SHARED_TEAM_BUDGET_DURATION`
- optional `ENTRA_SHARED_TEAM_MEMBER_MAX_BUDGET`

With the default OSS `custom_auth` path:

- LiteLLM upserts one internal user per Entra `oid`
- the user keeps personal spend tracking and a personal budget
- the same user is also added to one shared LiteLLM team
- requests are tagged with that `team_id`, so team spend and team budget work in the LiteLLM UI

## Local Broker

The local broker is a client-side helper for headless or long-running Linux sessions. It sits between `OpenCode` and LiteLLM and does two things:

- Prefers native Microsoft Entra device code login with a separate public client app, then refreshes with the cached refresh token.
- Falls back to Azure CLI when `ENTRA_PUBLIC_CLIENT_ID` is not available or when you explicitly force `--auth-mode azure-cli`.
- Forwards OpenAI-compatible requests to the real LiteLLM endpoint, adding `Authorization: Bearer <entra_access_token>` on the way out.

Use it when you want a stable local endpoint for `OpenCode` instead of minting a new token for every run. It does not change the server-side auth model and does not replace LiteLLM `custom_auth`.

Request flow:

`OpenCode -> local broker -> LiteLLM OSS(custom_auth) -> Vertex AI`

The broker is started by `scripts/start-entra-broker.ps1` or `scripts/start-entra-broker.sh`. The combined launcher `scripts/start-opencode-entra-broker.ps1` or `scripts/start-opencode-entra-broker.sh` starts the broker and then launches `OpenCode` against it.

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
- `ENTRA_PUBLIC_CLIENT_ID`
- `ENTRA_ALLOWED_GROUP_ID`
- `ENTRA_SCOPE`
- `ENTRA_ISSUER`
- `ENTRA_JWKS_URI`

To get a token for testing:

```powershell
$resp = .\scripts\get-entra-token.ps1 | ConvertFrom-Json
.\scripts\decode-jwt.ps1 -Token $resp.accessToken
```

On Linux or a headless server, the wrapper prefers native device code login. It prints a verification URL and user code returned by Microsoft Entra, and stores the refresh token in `.secrets/entra-device-token.json` for later reuse:

```bash
./scripts/get-entra-token.sh
```

## OpenCode with Entra

For a quick direct test, launch `OpenCode` with a fresh Entra access token:

```powershell
.\scripts\start-opencode-entra-direct.ps1
```

```bash
./scripts/start-opencode-entra-direct.sh
```

This reuses the project `opencode.json` and injects:

- `LITELLM_OPENAI_BASE_URL=<litellm>/v1`
- `LITELLM_API_KEY=<entra_access_token>`

For a smoother local dev loop, start the local broker once and point `OpenCode` at `localhost`:

```powershell
.\scripts\start-entra-broker.ps1
.\scripts\start-opencode-entra-broker.ps1
```

```bash
./scripts/start-entra-broker.sh
./scripts/start-opencode-entra-broker.sh
```

With the new `.entra.env`, both Windows and Linux wrappers prefer native device code first. If you need the old path, pass `--auth-mode azure-cli` to the bash wrappers or `-AuthMode azure-cli` to the PowerShell wrappers.

The broker refreshes the Entra token before expiry and forwards requests to LiteLLM. To stop it:

```powershell
.\scripts\stop-entra-broker.ps1
```

```bash
./scripts/stop-entra-broker.sh
```

If you need the broker to bind beyond localhost on Linux, pass `--host 0.0.0.0` to `scripts/start-entra-broker.sh` or `-Host 0.0.0.0` to `scripts/start-entra-broker.ps1`.
