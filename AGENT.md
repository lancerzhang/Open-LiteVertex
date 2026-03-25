# AGENT.md

## Project Overview

This repository provisions and operates an `OpenCode -> LiteLLM OSS -> Vertex AI` gateway on `GKE Autopilot`, with optional `Microsoft Entra ID` access control.

The current project goals are:

- expose an OpenAI-compatible endpoint through LiteLLM OSS
- route requests to Vertex AI Gemini models
- enforce per-user or per-key budget controls
- optionally validate Entra access tokens and group membership
- keep the deployment lightweight by using LiteLLM `custom_auth` instead of LiteLLM Enterprise

## Architecture

Core flow:

`OpenCode -> LiteLLM OSS(custom_auth) -> Vertex AI`

Supporting components:

- `GKE Autopilot` runs LiteLLM and Postgres
- `Postgres` stores LiteLLM state
- `Workload Identity` lets LiteLLM call Vertex AI without a JSON service account key
- `custom_auth` in `config/auth_handler.py` validates Entra JWTs and maps users into LiteLLM
- local helper scripts support deployment, token acquisition, debugging, and OpenCode startup

## Important Files

- `README.md`: quick start and high-level setup notes
- `docs/opencode-litellm-entra-vertex-flow.md`: architecture and end-to-end user flow
- `config/litellm-config.yaml`: base LiteLLM routing and model config
- `config/auth_handler.py`: Entra JWT validation, group gating, user upsert, and request tracing helpers
- `config/opencode.example.json`: example OpenCode provider configuration
- `docker/`: Dockerfiles for the custom LiteLLM image
- `k8s/`: Kubernetes manifests for namespace, Postgres, and LiteLLM resources
- `scripts/deploy-demo.ps1`: end-to-end bootstrap and deployment entrypoint
- `scripts/setup-entra-oss.ps1`: Entra app and group bootstrap for OSS auth flow
- `scripts/start-opencode-entra-direct.ps1`: direct token-based OpenCode startup
- `scripts/start-entra-broker.ps1`: local broker for auto-refreshing Entra tokens

## Working Rules

- preserve the core architecture unless there is an explicit request to redesign it
- prefer extending LiteLLM OSS `custom_auth` over introducing a separate auth gateway
- do not commit `.demo.env`, `.entra.env`, `.secrets/`, `.venv/`, or generated Python artifacts
- keep model aliases consistent across `opencode.json`, LiteLLM config, and auth allowlists
- preserve budget semantics unless explicitly asked to change them
- treat Entra configuration as optional at deploy time, but keep the code path functional
- avoid adding dependencies or infrastructure components unless they clearly reduce operational complexity

## Expected Tooling

The repository is primarily operated with:

- `PowerShell` scripts
- `gcloud`
- `kubectl`
- `docker` and `gcloud builds`
- Python for the broker and LiteLLM auth extension

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

### Start OpenCode with direct Entra token usage

```powershell
.\scripts\start-opencode-entra-direct.ps1
```

### Start local broker mode

```powershell
.\scripts\start-entra-broker.ps1
.\scripts\start-opencode-entra-broker.ps1
```

## Change Guidance

When editing this repository:

- verify whether a change affects deployment, auth, budget control, or model routing
- update both docs and scripts if the operational flow changes
- prefer small, explicit changes over broad refactors
- keep local developer experience in mind for Windows and PowerShell users
- document any new environment variables in `README.md`

## Naming Direction

The project is best described as a lightweight, OSS-first gateway for `OpenCode + LiteLLM + Entra + Vertex AI`.
Names should reflect one or more of these ideas:

- Vertex AI access gateway
- Entra-guarded LLM access
- LiteLLM OSS control plane
- budgeted internal AI access
