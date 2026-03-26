# OpenCode + LiteLLM OSS + Entra ID + Vertex AI 流程文档

## 1. 目标

这套方案的目标是：

- 用户使用 Microsoft Entra ID 登录
- 只有在指定 Entra Group 里的用户才能使用
- 用户在 OpenCode 里选择不同的 Vertex AI 模型
- 每个用户有个人预算，同时还受共享 Team 预算约束
- LiteLLM 使用开源版，不使用 LiteLLM Enterprise

## 2. 最终架构

当前推荐架构如下：

`OpenCode(global plugin auth) -> LiteLLM OSS(custom_auth) -> Vertex AI`

调试时也可以走一次性直连：

`OpenCode(direct bearer token) -> LiteLLM OSS(custom_auth) -> Vertex AI`

这里没有单独的 broker，也没有额外的认证网关。

## 3. 为什么不再保留本地 Broker

因为客户端真正需要的事情只有两件：

- 通过 Entra device code flow 获取用户 access token
- 在请求发往 LiteLLM 前补上 `Authorization: Bearer <entra_access_token>`

这两件事完全可以放在 OpenCode provider plugin 内完成。这样有几个直接好处：

- `OpenCode` 仍然直接连 LiteLLM
- 客户端不再需要额外的 localhost 端口和 sidecar 进程
- token 刷新逻辑只保留一份
- Linux 无 UI 场景和 Windows 场景共用同一套登录方式

## 4. 各组件职责

### 4.1 OpenCode

- 给用户提供聊天入口
- 展示可选模型列表
- 把请求直接发给 LiteLLM

### 4.2 OpenCode Global Plugin

- 暴露 `litellm` provider 的登录方法
- 使用原生 device code flow 获取 Entra access token
- 复用本地 refresh token cache 自动刷新 access token
- 在真正发往 LiteLLM 的 HTTP 请求上补 `Authorization: Bearer <entra_access_token>`
- 作为用户级插件放在 `~/.config/opencode/plugins/entra-litellm-auth.ts`

### 4.3 LiteLLM custom_auth

- 校验 `Authorization: Bearer <entra_access_token>`
- 校验 token 的 `iss`、`aud`、`exp`、`tid`
- 校验 token 的 `groups` 是否包含允许访问的 Group ID
- 用 Entra 用户的 `oid` 作为用户唯一标识
- 在 LiteLLM 用户表里创建或更新该用户
- 把用户加入共享 Team，并让请求带上 `team_id`
- 把请求继续交给 LiteLLM 原生预算和模型权限逻辑

### 4.4 LiteLLM OSS

- 提供 OpenAI Compatible API
- 管理模型映射
- 管理用户、Team、预算和花费

### 4.5 Vertex AI

- 执行 Gemini 或 Claude 模型请求
- 返回模型结果

### 4.6 Entra ID

- 负责登录认证
- 在 Access Token 中下发用户身份信息
- 在 Token 中下发 `groups`

## 5. 管理员初始化流程

### 5.1 GCP 初始化

管理员先完成基础部署：

1. 创建或复用 GKE 集群
2. 部署 Postgres
3. 部署 LiteLLM OSS
4. 给 LiteLLM 的 Kubernetes ServiceAccount 绑定 GCP Workload Identity
5. 给对应 GCP Service Account 授予 `roles/aiplatform.user`
6. 在 LiteLLM 中配置允许使用的 Vertex 模型

完成后，LiteLLM 就可以直接访问 Vertex AI。

### 5.2 Entra 初始化

管理员运行：

[scripts/setup-entra-oss.ps1](../scripts/setup-entra-oss.ps1)

这个脚本会创建或复用：

- 一个 Entra API App
- 一个单独的 Entra public client app，专门给 device code 登录使用
- 一个允许访问的安全组，例如 `opencode-users`
- 可选把用户加入该组

脚本会输出这些值到 `.entra.env`：

- `ENTRA_TENANT_ID`
- `ENTRA_CLIENT_ID`
- `ENTRA_PUBLIC_CLIENT_ID`
- `ENTRA_ALLOWED_GROUP_ID`
- `ENTRA_SCOPE`
- `ENTRA_ISSUER`
- `ENTRA_JWKS_URI`

### 5.3 LiteLLM custom_auth 初始化

管理员把下面这些变量配置到 LiteLLM Deployment：

- `ENTRA_TENANT_ID`
- `ENTRA_CLIENT_ID`
- `ENTRA_ISSUER`
- `ENTRA_JWKS_URI`
- `ENTRA_ALLOWED_GROUP_ID`
- `ENTRA_ALLOWED_MODELS`
- `ENTRA_USER_MAX_BUDGET`
- `ENTRA_USER_BUDGET_DURATION`
- optional `ENTRA_SHARED_TEAM_ID`
- optional `ENTRA_SHARED_TEAM_ALIAS`
- optional `ENTRA_SHARED_TEAM_MAX_BUDGET`
- optional `ENTRA_SHARED_TEAM_BUDGET_DURATION`
- optional `ENTRA_SHARED_TEAM_MEMBER_MAX_BUDGET`

## 6. 用户完整使用流程

### 6.1 用户首次登录

1. 用户运行 `opencode auth login`，或者在 TUI 的 `/connect` 里选择 `Entra LiteVertex`
2. 全局 plugin 读取当前项目的 `.entra.env` 或同名环境变量
3. OpenCode 登录对话框显示 provider 名称 `Entra LiteVertex`
4. plugin 通过 OpenCode 的 `oauth/auto` 视图返回 Microsoft Entra 的验证链接和 user code
5. 用户在任意有浏览器的设备上完成验证
6. Entra 返回 Access Token 和 Refresh Token
7. plugin 把 Refresh Token 安全地缓存在 `~/.config/opencode/entra-device-token.json`
8. 登录状态会以 `oauth` 形式写入 OpenCode 自己的 auth store

### 6.2 用户第一次发起模型请求

1. 用户在 OpenCode 中选择模型
2. 用户输入 Prompt
3. OpenCode 将请求直接发送给 LiteLLM
4. 全局 plugin 在出站请求上补上 `Authorization: Bearer <entra_access_token>`
5. LiteLLM 的 `custom_auth` 校验 Entra Token
6. `custom_auth` 校验用户是否属于允许的 Group
7. 如果不在允许的 Group 中，返回 `403 Forbidden`
8. 如果在允许的 Group 中，`custom_auth` 读取 Token 中的 `oid`
9. `custom_auth` 用 `oid` 在 LiteLLM 用户表里做 upsert
10. 首次请求时自动创建或更新用户预算
11. `custom_auth` 确保存在一个共享 LiteLLM Team，并把该用户加入 Team
12. 当前请求返回的 `UserAPIKeyAuth` 会附带 `team_id`
13. LiteLLM 先检查 team member budget / team budget，再检查模型权限
14. LiteLLM 将请求转发到 Vertex AI
15. Vertex AI 返回结果
16. LiteLLM 同时累计 user spend 和 team spend
17. LiteLLM 将结果返回给 OpenCode

### 6.3 用户后续请求

后续流程与首次请求基本相同，只是客户端通常已经有 refresh token：

1. plugin 在 access token 快过期前自动刷新
2. 请求仍然直接发给 LiteLLM
3. LiteLLM 继续按用户预算、Team 预算和模型权限处理

## 7. 用户与 Team 预算

当前项目的 `custom_auth` 会同时处理两层预算：

- 用户层预算：每个 Entra 用户对应一个 LiteLLM user
- Team 层预算：所有被允许的 Entra 用户都放进同一个共享 Team

这样在 LiteLLM UI 中可以同时看到：

- 单个用户花费
- 共享 Team 花费
- 用户预算是否超限
- Team 预算是否超限

## 8. OpenCode 本地用法

### 8.1 安装全局 Plugin

Windows:

```powershell
.\scripts\install-opencode-entra-plugin.ps1
```

Linux:

```bash
./scripts/install-opencode-entra-plugin.sh
```

安装目标路径：

- `~/.config/opencode/plugins/entra-litellm-auth.ts`

### 8.2 启动 Plugin 模式

Windows:

```powershell
.\scripts\start-opencode-entra-plugin.ps1
```

Linux:

```bash
./scripts/start-opencode-entra-plugin.sh
```

第一次运行时，这个脚本会先自动执行 `opencode auth login`。在 OpenCode 的 provider 列表里会显示 `Entra LiteVertex`，用户选中后会直接看到 Microsoft 的 device code 链接和验证码，然后再进入 OpenCode。

如果只想单独刷新登录态，可以用：

```powershell
.\scripts\start-opencode-entra-plugin.ps1 --login-only
```

```bash
./scripts/start-opencode-entra-plugin.sh --login-only
```

### 8.3 直接 Token 模式

这个模式主要用于排障或快速验证：

Windows:

```powershell
.\scripts\start-opencode-entra-direct.ps1
```

Linux:

```bash
./scripts/start-opencode-entra-direct.sh
```

direct 模式会显式关闭全局 plugin 对该进程的拦截，让请求路径保持简单。

## 9. 当前实现边界

当前全局 plugin 负责的是 OpenCode 自己发出的 `litellm` provider 请求，包括：

- chat 请求
- `small_model` 请求
- skill 触发后的后续模型推理
- MCP 工具调用之后的后续模型推理

但如果某个 MCP server 自己内部再去调用别的 LLM，那是 MCP server 自己的出站流量，不在这个 plugin 或 LiteLLM `custom_auth` 的控制范围内。
