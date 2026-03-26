# Open LiteVertex

Open LiteVertex deploys a minimal `LiteLLM OSS -> Vertex AI` gateway on `GKE Autopilot` and can gate access with `Microsoft Entra ID` through LiteLLM `custom_auth`.

当前仓库的客户端路径已经收敛为两种：

- `OpenCode(global plugin auth) -> LiteLLM OSS(custom_auth) -> Vertex AI`
- `OpenCode(direct bearer token) -> LiteLLM OSS(custom_auth) -> Vertex AI`

本仓库不再保留本地 broker，也不再保留 Azure CLI 的客户端登录分支。

## What It Does

- Creates or reuses a `GKE Autopilot` cluster.
- Deploys `Postgres` inside the cluster for LiteLLM state.
- Builds a thin custom LiteLLM image on top of the official stable image.
- Uses `Workload Identity` so LiteLLM can call `Vertex AI` without a JSON key.
- Loads `custom_auth` inside the LiteLLM pod for `Entra JWT groups` validation.
- Auto-creates a LiteLLM internal user per Entra `oid` and places Entra users into a shared LiteLLM team.
- Creates a demo key with a `$50 / 7d` budget.
- Writes the endpoint and key to `.demo.env`.

## Files

- `config/auth_handler.py`: OSS `custom_auth` handler for Entra groups, user upsert, and shared-team assignment.
- `config/litellm-config.yaml`: base LiteLLM routing and model config.
- `config/opencode.example.json`: example `OpenCode` provider config.
- `config/opencode.global.json`: canonical global `OpenCode` provider config installed into `~/.config/opencode/opencode.json`.
- `docs/opencode-litellm-entra-vertex-flow.md`: architecture and end-to-end flow.
- `k8s/`: Kubernetes manifests.
- `plugins/entra-litellm-auth.ts`: canonical source for the global OpenCode Entra plugin.
- `scripts/setup-opencode-entra-client.ps1`: one-time user-machine setup for the global OpenCode plugin on Windows.
- `scripts/setup-opencode-entra-client.sh`: one-time user-machine setup for the global OpenCode plugin on Linux.
- `scripts/bootstrap-opencode-entra.ps1`: first-login helper for the global plugin flow on Windows.
- `scripts/bootstrap-opencode-entra.sh`: first-login helper for the global plugin flow on Linux.
- `scripts/start-opencode-entra-direct.ps1`: launch `OpenCode` with a fresh Entra bearer token directly.
- `scripts/start-opencode-entra-direct.sh`: Linux wrapper for direct-token mode.
- `scripts/get-entra-token.ps1`: fetch a delegated access token for the API app through native device code.
- `scripts/get-entra-token.sh`: Linux wrapper for delegated Entra token acquisition.
- `scripts/entra_auth.py`: shared native device-code helper with refresh-token cache support.
- `scripts/entra_client.py`: shared cross-platform client entrypoint used by direct-mode and token wrappers.
- `scripts/setup-entra-oss.ps1`: create the Entra API app, the public client app for device code login, and the allowed security group.

## Admin Init

Administrator setup is only for the platform owner. It provisions or updates the shared backend that all users connect to.

Step 1. Deploy the backend from the repo root:

```powershell
.\scripts\deploy-demo.ps1
Get-Content .demo.env
```

Step 2. Bootstrap Entra for LiteLLM OSS:

```powershell
.\scripts\setup-entra-oss.ps1 `
  -TenantId "<your-tenant-id>" `
  -AllowedGroupName "opencode-users"
```

## User Init

User setup is per machine, not per project.

Step 1. Run the one-time client setup:

```powershell
.\scripts\setup-opencode-entra-client.ps1
```

```bash
./scripts/setup-opencode-entra-client.sh
```

This step installs the global plugin into `~/.config/opencode/plugins/` and merges the fixed provider config into `~/.config/opencode/opencode.json`.

Step 2. Run the first-login helper once:

```powershell
.\scripts\bootstrap-opencode-entra.ps1
```

```bash
./scripts/bootstrap-opencode-entra.sh
```

This step refreshes the global client setup, opens `opencode auth login` if needed, and can continue into `opencode`.

Step 3. Day-to-day usage after the first login:

```bash
opencode
```

```bash
opencode auth login
```

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

## Entra OSS Setup

To create the Entra values required by the OSS `custom_auth` path:

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

To fetch a bearer token for testing:

```powershell
$resp = .\scripts\get-entra-token.ps1 | ConvertFrom-Json
.\scripts\decode-jwt.ps1 -Token $resp.accessToken
```

```bash
./scripts/get-entra-token.sh
```

The native device-code flow prints Microsoft Entra's verification URL and user code in the terminal, then stores the refresh token in the global cache file:

- `~/.config/opencode/entra-device-token.json`

## Client Usage

### Plugin Mode

The preferred path is the global OpenCode plugin plus a global OpenCode provider config. The runtime files are installed into:

- `~/.config/opencode/plugins/entra-litellm-auth.ts`
- `~/.config/opencode/opencode.json`

Run the one-time client setup:

```powershell
.\scripts\setup-opencode-entra-client.ps1
```

```bash
./scripts/setup-opencode-entra-client.sh
```

The client setup step:

- installs the user-level plugin
- installs two fixed providers into the global OpenCode config
- does not require `.demo.env`, `.entra.env`, or per-project environment variables for the plugin path
- is mainly a one-time machine setup or upgrade step; after it finishes, you can use native `opencode` commands directly

Bootstrap the client once:

```powershell
.\scripts\bootstrap-opencode-entra.ps1
```

```bash
./scripts/bootstrap-opencode-entra.sh
```

This bootstrap step:

- refreshes the one-time client setup
- opens `opencode auth login` if the user is not logged in yet
- can optionally launch `opencode` immediately

After the bootstrap step, users can use native OpenCode commands directly from any project:

```bash
opencode auth login
opencode
```

In plugin mode:

- `OpenCode` keeps talking directly to LiteLLM
- the plugin injects `Authorization: Bearer <entra_access_token>` on outbound `litellm` requests
- token refresh uses per-provider native device-code caches in `~/.config/opencode/entra-device-token.json` and `~/.config/opencode/entra-device-token.dev.json`
- the client config is global, so other projects can reuse it without extra env setup
- `/connect` and `opencode auth login` now show two providers: `Entra LiteVertex` and `Entra LiteVertex - dev`
- login uses OpenCode's built-in OAuth auto view, so the UI shows the Microsoft verification link and device code directly
- on the first run, the bootstrap script opens `opencode auth login`, where these providers appear as selectable entries

If you only want to refresh the provider login without starting the TUI:

```powershell
.\scripts\bootstrap-opencode-entra.ps1 --login-only
```

```bash
./scripts/bootstrap-opencode-entra.sh --login-only
```

### Direct Mode

For quick debugging, you can still launch `OpenCode` with a freshly minted bearer token:

```powershell
.\scripts\start-opencode-entra-direct.ps1
```

```bash
./scripts/start-opencode-entra-direct.sh
```

This mode:

- fetches a fresh token through native device code
- injects it into `LITELLM_API_KEY`
- disables the global plugin for that one process so the request path stays fully direct

## Model Config

The repo ships these model aliases in `opencode.json` and `config/opencode.example.json`:

- `vertex-gemini-2.5-flash`
- `vertex-gemini-2.5-flash-lite`
- `vertex-gemini-2.5-pro`
- `vertex-gemini-3-pro-preview`
- `vertex-claude-sonnet-4-6`
