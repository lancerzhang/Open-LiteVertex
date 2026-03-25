# AGENT.md

## Project Overview

This repository provisions and operates an `OpenCode -> LiteLLM OSS -> Vertex AI` gateway on `GKE Autopilot`, with optional `Microsoft Entra ID` access control.

The current project goals are:

- expose an OpenAI-compatible endpoint through LiteLLM OSS
- route requests to Vertex AI Gemini and Claude models
- enforce per-user and shared-team budget controls
- validate Entra access tokens and group membership through LiteLLM `custom_auth`
- keep the deployment lightweight by using LiteLLM OSS plus a user-level OpenCode plugin

## Architecture

Core flow:

`OpenCode(global plugin auth) -> LiteLLM OSS(custom_auth) -> Vertex AI`

Supporting components:

- `GKE Autopilot` runs LiteLLM and Postgres
- `Postgres` stores LiteLLM state
- `Workload Identity` lets LiteLLM call Vertex AI without a JSON service account key
- `custom_auth` in `config/auth_handler.py` validates Entra JWTs and maps users into LiteLLM
- a global OpenCode plugin in `~/.config/opencode/plugins/` injects Entra bearer tokens on the client side

## Important Files

- `README.md`: quick start and high-level setup notes
- `docs/opencode-litellm-entra-vertex-flow.md`: architecture and end-to-end user flow
- `config/litellm-config.yaml`: base LiteLLM routing and model config
- `config/auth_handler.py`: Entra JWT validation, group gating, user upsert, and shared-team helpers
- `config/opencode.example.json`: example OpenCode provider configuration
- `plugins/entra-litellm-auth.ts`: canonical source for the global OpenCode plugin
- `docker/`: Dockerfiles for the custom LiteLLM image
- `k8s/`: Kubernetes manifests for namespace, Postgres, and LiteLLM resources
- `scripts/deploy-demo.ps1`: end-to-end bootstrap and deployment entrypoint
- `scripts/setup-entra-oss.ps1`: Entra app and group bootstrap for OSS auth flow
- `scripts/install-opencode-entra-plugin.ps1`: install the global OpenCode plugin on Windows
- `scripts/install-opencode-entra-plugin.sh`: install the global OpenCode plugin on Linux
- `scripts/start-opencode-entra-plugin.ps1`: start OpenCode through the global plugin auth flow
- `scripts/start-opencode-entra-direct.ps1`: direct token-based OpenCode startup

## Working Rules

- preserve the core `OpenCode -> LiteLLM OSS(custom_auth) -> Vertex AI` architecture unless there is an explicit request to redesign it
- prefer extending LiteLLM OSS `custom_auth` or the global OpenCode plugin over introducing a separate auth gateway
- do not commit `.demo.env`, `.entra.env`, `.secrets/`, `.venv/`, or generated Python artifacts
- keep model aliases consistent across `opencode.json`, LiteLLM config, and auth allowlists
- preserve budget semantics unless explicitly asked to change them
- treat Entra configuration as optional at deploy time, but keep the code path functional

## Expected Tooling

The repository is primarily operated with:

- `PowerShell` scripts
- `gcloud`
- `kubectl`
- `docker` and `gcloud builds`
- Python for device-code token helpers and LiteLLM auth extension
- TypeScript for the user-level OpenCode plugin

## Common Tasks

### Deploy the demo

```powershell
.\scripts\deploy-demo.ps1
```

### Inspect generated endpoint and key

```powershell
Get-Content .demo.env
```

### Set up Entra OSS auth

```powershell
.\scripts\setup-entra-oss.ps1 -TenantId "<tenant-id>" -AllowedGroupName "opencode-users"
```

### Install the global OpenCode plugin

```powershell
.\scripts\install-opencode-entra-plugin.ps1
```

### Start OpenCode with plugin auth

```powershell
.\scripts\login-opencode-entra-plugin.ps1
.\scripts\start-opencode-entra-plugin.ps1
```

### Start OpenCode with a direct Entra token

```powershell
.\scripts\start-opencode-entra-direct.ps1
```

## Change Guidance

When editing this repository:

- verify whether a change affects deployment, auth, budget control, or model routing
- update both docs and scripts if the operational flow changes
- prefer small, explicit changes over broad refactors
- keep both Windows and Linux client paths in mind
- document any new environment variables in `README.md`

## Naming Direction

The project is best described as a lightweight, OSS-first gateway for `OpenCode + LiteLLM + Entra + Vertex AI`.
