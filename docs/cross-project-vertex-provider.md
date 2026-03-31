# Cross-Project Vertex Provider Deployment

This repository can run `Entra + LiteLLM + GKE` in one Google Cloud project while another team owns the `Vertex AI` project.

That split is useful when:

- your team owns the user-facing gateway, Entra integration, budgets, and audit flow
- another team owns the Google Cloud project where Gemini is billed and governed
- you need a documented handoff instead of sharing full project ownership

## Architecture

The preferred layout is:

- Team A project: GKE Autopilot, LiteLLM, Postgres, container image, and the Google service account bound to the LiteLLM Kubernetes service account
- Team B project: Vertex AI APIs, quota, model access, and optional Model Armor templates

Runtime flow:

1. Users authenticate to LiteLLM with Microsoft Entra tokens.
2. LiteLLM runs in Team A's GKE cluster.
3. LiteLLM calls Vertex AI in Team B's project.
4. If configured, Vertex AI applies Model Armor in the same regional project as the Gemini call.

GKE does not need to be in the same region as Vertex AI. Cross-region calls work normally over Google-managed endpoints. The important regional rule is that `Vertex AI` and `Model Armor` should use matching supported regions when you want request sanitization to apply.

## Supported Auth Patterns

### Option 1: Preferred, cross-project IAM with Workload Identity

Use this when Team B can grant Team A's Google service account access to the Vertex project.

In this mode:

- LiteLLM keeps using the local Google service account created by `scripts/deploy-demo.ps1`
- the local service account is granted `roles/aiplatform.user` on the remote Vertex project
- no JSON key is stored in the LiteLLM pod

This repository now supports that by separating:

- deployment project: `ProjectId`
- Vertex provider project: `VertexProjectId` or `.vertex.env -> VERTEX_PROJECT_ID`

### Option 2: Fallback, explicit shared service-account JSON

Use this when Team B does not want to grant Team A's service account direct access to the Vertex project.

In this mode:

- Team B creates a dedicated service account inside the Vertex project
- Team B grants that service account the required Vertex permissions
- Team A stores that JSON in a local file and points `.vertex.env` at it with `VERTEXAI_CREDENTIALS_FILE`
- LiteLLM passes the JSON to the Vertex SDK through `VERTEXAI_CREDENTIALS`

This is easier to hand off, but it has the normal operational cost of key rotation and secure secret handling.

## Team Responsibilities

### Team A: Entra + LiteLLM owner

Team A owns:

- `Entra` application registration and group design
- the GKE cluster and LiteLLM deployment
- `.entra.env`
- `.vertex.env`
- optional `.modelarmor.env`

Team A runs:

```powershell
Copy-Item .vertex.example.env .vertex.env
Copy-Item .modelarmor.example.env .modelarmor.env
.\scripts\deploy-demo.ps1 -ProjectId "<team-a-deploy-project>"
```

If `.vertex.env` points to a different `VERTEX_PROJECT_ID`, the deploy script defaults to `VERTEX_SKIP_PROJECT_SETUP=true` behavior unless you explicitly override it. That means the script will deploy LiteLLM, but it will not try to modify the remote team's project by default.

### Team B: Vertex provider owner

Team B owns:

- the Vertex project
- Vertex model access and quota
- optional Model Armor templates
- the IAM grant back to Team A

For the preferred Workload Identity pattern, Team B needs the Team A service account email:

```text
litellm-vertex@<TEAM_A_DEPLOY_PROJECT>.iam.gserviceaccount.com
```

Then Team B runs:

```powershell
gcloud services enable aiplatform.googleapis.com --project "<TEAM_B_VERTEX_PROJECT>"
gcloud projects add-iam-policy-binding "<TEAM_B_VERTEX_PROJECT>" `
  --member="serviceAccount:litellm-vertex@<TEAM_A_DEPLOY_PROJECT>.iam.gserviceaccount.com" `
  --role="roles/aiplatform.user"
```

If Team B also provides Model Armor for Gemini traffic:

```powershell
$vertexProjectNumber = gcloud projects describe "<TEAM_B_VERTEX_PROJECT>" --format="value(projectNumber)"
gcloud services enable modelarmor.googleapis.com --project "<TEAM_B_VERTEX_PROJECT>"
gcloud projects add-iam-policy-binding "<TEAM_B_VERTEX_PROJECT>" `
  --member="serviceAccount:service-$vertexProjectNumber@gcp-sa-aiplatform.iam.gserviceaccount.com" `
  --role="roles/modelarmor.user"
```

For the explicit JSON credential pattern, Team B instead creates a dedicated service account in the Vertex project, grants it `roles/aiplatform.user`, and shares the JSON key securely with Team A.

## Local Configuration

Start from:

```powershell
Copy-Item .vertex.example.env .vertex.env
```

Available settings:

- `VERTEX_PROJECT_ID`: remote or local project that owns Vertex AI
- `VERTEX_LOCATION`: default regional endpoint for models that are not hard-pinned in `config/litellm-config.yaml`
- `VERTEX_SKIP_PROJECT_SETUP`: when `true`, `deploy-demo.ps1` will not try to enable APIs or add IAM bindings on the Vertex provider project
- `VERTEXAI_CREDENTIALS_FILE`: optional path to a shared service-account JSON file
- `VERTEXAI_CREDENTIALS`: optional inline JSON string if a file path is not practical

Example:

```dotenv
VERTEX_PROJECT_ID=team-b-vertex-project
VERTEX_LOCATION=us-central1
VERTEX_SKIP_PROJECT_SETUP=true
```

Example with shared credentials:

```dotenv
VERTEX_PROJECT_ID=team-b-vertex-project
VERTEX_LOCATION=us-central1
VERTEX_SKIP_PROJECT_SETUP=true
VERTEXAI_CREDENTIALS_FILE=.secrets/team-b-vertex-sa.json
```

## Deploy Command

Deploy from Team A's repo checkout:

```powershell
.\scripts\deploy-demo.ps1 `
  -ProjectId "<team-a-deploy-project>" `
  -Region "asia-east1" `
  -VertexProjectId "<team-b-vertex-project>" `
  -VertexLocation "us-central1"
```

The script now writes both the deployment and Vertex settings into `.demo.env`, including:

- `GCP_DEPLOY_PROJECT_ID`
- `VERTEX_PROJECT_ID`
- `VERTEX_LOCATION`

## Region Notes

For this repository:

- most Gemini 2.5 aliases inherit `VERTEXAI_LOCATION`
- `vertex-gemini-3-pro-preview`, `vertex-gemini-3.1-pro-preview`, and `vertex-claude-sonnet-4-6` are still pinned to `global` in `config/litellm-config.yaml`

That means a regional `VERTEX_LOCATION=us-central1` does not automatically change every alias. If you need all traffic to stay regional for governance reasons, update the pinned aliases after confirming model availability in the target region.

If you use Model Armor:

- keep the Model Armor template region aligned with the Vertex regional endpoint
- remember that this repository only injects Model Armor on the Gemini `generateContent` path
- partner models such as the Claude route do not use that injected Gemini request shape

## Operational Notes

- Cross-project deployment is supported even when GKE and Vertex AI are in different regions.
- Cross-project deployment is also supported when the two teams are in different Google Cloud organizations, as long as the required IAM grant or JSON credential exchange is possible.
- The recommended operational model is still `Workload Identity + cross-project IAM`, because it avoids long-lived service-account keys inside the LiteLLM pod.
