# OpenCode + LiteLLM OSS + Entra ID + Vertex AI 流程文档

## 1. 目标

这套方案的目标是：

- 用户使用 Microsoft Entra ID 登录
- 只有在指定 Entra Group 里的用户才能使用
- 用户在 OpenCode 里选择不同的 Vertex AI 模型
- 每个用户每周最多使用 50 美元
- LiteLLM 使用开源版，不使用 LiteLLM Enterprise

## 2. 最终架构

推荐架构如下：

`OpenCode -> LiteLLM OSS(custom_auth) -> Vertex AI`

说明：

- OpenCode 直接连 LiteLLM
- LiteLLM OSS 用 `custom_auth` 校验 Entra Token 和 Group 准入
- LiteLLM 负责模型路由、预算和花费记录
- Vertex AI 负责实际模型推理

## 3. 为什么不用额外的 Gateway

因为 LiteLLM 开源版不提供原生的 Entra OIDC/JWT 登录能力，但它提供了 `custom_auth` 扩展点。

所以当前项目的做法不是额外部署一个认证服务，而是在 LiteLLM 容器里加载一段认证代码。它只做最少的事情：

- 校验 Entra Access Token
- 判断用户是否在允许的 Group 中
- 用 Token 里的 `oid` 映射到 LiteLLM 用户表
- 首次请求时自动创建或更新该用户的 LiteLLM Internal User

这段代码不负责模型推理，也不负责计费计算。

### 3.1 本地 Broker 的作用

在 Linux 无界面或长生命周期会话里，OpenCode 直接自己管理 Entra token 会比较麻烦，所以项目里提供了一个本地 broker 作为客户端辅助层。

这个 broker 运行在用户自己的机器上，不部署在 GKE 上，职责很窄：

- 优先通过单独的 Entra public client app 走原生 device code flow 登录
- 把 device code flow 拿到的 refresh token 缓存在本地，后续自动刷新 access token
- 如果没有 `ENTRA_PUBLIC_CLIENT_ID`，或者用户显式要求兼容模式，就回退到 Azure CLI
- 监听一个本地 OpenAI-compatible endpoint
- 收到请求后先补上 `Authorization: Bearer <entra_access_token>`
- 再把请求转发给真正的 LiteLLM 服务

这样做的结果是：

- OpenCode 只需要连本地 `localhost`
- token 刷新逻辑从 OpenCode 配置里剥离出来
- 服务端认证模型仍然保持不变，还是 LiteLLM `custom_auth`

本地 broker 的请求链路如下：

`OpenCode -> local broker -> LiteLLM OSS(custom_auth) -> Vertex AI`

## 4. 各组件职责

### 4.1 OpenCode

- 给用户提供聊天入口
- 展示可选模型列表
- 把请求直接发给 LiteLLM

### 4.2 LiteLLM custom_auth

- 校验 `Authorization: Bearer <entra_access_token>`
- 校验 token 的 `iss`、`aud`、`exp`、`tid`
- 校验 token 的 `groups` 是否包含允许访问的 Group ID
- 用 Entra 用户的 `oid` 作为用户唯一标识
- 在 LiteLLM 用户表里创建或更新该用户
- 把请求继续交给 LiteLLM 原生预算和模型权限逻辑

### 4.3 LiteLLM OSS

- 提供 OpenAI Compatible API
- 管理模型映射
- 管理虚拟 Key
- 控制预算
- 记录花费

### 4.4 Vertex AI

- 执行 Gemini 模型请求
- 返回模型结果

### 4.5 Entra ID

- 负责登录认证
- 在 Access Token 中下发用户身份信息
- 在 Token 中下发 `groups`

### 4.6 Local Broker

- 从原生 device code flow 或 Azure CLI 获取 Entra access token
- 在 token 快过期时自动刷新
- 把 `OpenCode` 的请求转发到 LiteLLM
- 为请求补上 `Authorization: Bearer <entra_access_token>`
- 让 headless Linux 上的 `OpenCode` 仍然能用 Entra 登录

## 5. 当前项目已经完成的部分

当前已经在 GCP 上部署并验证：

- GKE Autopilot 集群
- LiteLLM OSS
- 自定义 LiteLLM 镜像
- Postgres
- LiteLLM 到 Vertex AI 的调用
- 每周 50 美元预算 Key

当前还没有部署的是：

- 真实的 Entra Tenant / App / Group 配置值
- OpenCode 用 Entra Access Token 调 LiteLLM 的正式认证链路
- 本地 broker 默认运行方式的长期运维规范

## 6. 管理员初始化流程

### 6.1 GCP 初始化

管理员先完成基础部署：

1. 创建或复用 GKE 集群
2. 部署 Postgres
3. 部署 LiteLLM OSS
4. 给 LiteLLM 的 Kubernetes ServiceAccount 绑定 GCP Workload Identity
5. 给对应 GCP Service Account 授予 `roles/aiplatform.user`
6. 在 LiteLLM 中配置允许使用的 Vertex 模型

完成后，LiteLLM 就可以直接访问 Vertex AI。

### 6.2 Entra 初始化

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

### 6.3 LiteLLM custom_auth 初始化

管理员把下面这些变量配置到 LiteLLM Deployment：

- `ENTRA_TENANT_ID`
- `ENTRA_CLIENT_ID`
- `ENTRA_ISSUER`
- `ENTRA_JWKS_URI`
- `ENTRA_ALLOWED_GROUP_ID`
- `ENTRA_ALLOWED_MODELS`
- `ENTRA_USER_MAX_BUDGET`
- `ENTRA_USER_BUDGET_DURATION`

## 7. 用户完整使用流程

### 7.1 用户首次登录

1. 用户打开 OpenCode
2. OpenCode 需要拿到一个 Entra Access Token
3. 如果本地已有 refresh token，就直接静默刷新
4. 如果没有，就在终端显示 Microsoft Entra 返回的验证链接和 user code
5. 用户在任意有浏览器的设备上完成验证
6. Entra 返回 Access Token 和 Refresh Token
7. 客户端把 Refresh Token 安全地缓存在本地，后续自动刷新
8. OpenCode 后续请求都把这个 Token 当成 LiteLLM 的 Bearer Token

请求头示例：

```http
Authorization: Bearer <entra_access_token>
```

### 7.2 用户第一次发起模型请求

1. 用户在 OpenCode 中选择模型
2. 用户输入 Prompt
3. OpenCode 将请求直接发送给 LiteLLM
4. LiteLLM 的 `custom_auth` 校验 Entra Token
5. `custom_auth` 校验用户是否属于允许的 Group
6. 如果不在允许的 Group 中，返回 `403 Forbidden`
7. 如果在允许的 Group 中，`custom_auth` 读取 Token 中的 `oid`
8. `custom_auth` 用 `oid` 在 LiteLLM 用户表里做 upsert
9. 如果用户不存在，就创建 LiteLLM Internal User
10. 创建用户时设置：

- `user_id = Entra oid`
- `max_budget = 50`
- `budget_duration = 7d`
- `models = 允许访问的模型列表`

11. LiteLLM 检查该用户的预算
12. LiteLLM 将请求转发到 Vertex AI
13. Vertex AI 返回结果
14. LiteLLM 记录该 `user_id` 的花费
15. LiteLLM 将结果返回给 OpenCode
16. 用户看到模型输出

如果用户选择兼容模式，客户端也可以继续走 Azure CLI。区别只是 token 的获取方式不同，服务端校验逻辑完全不变。

### 7.3 用户后续请求

后续流程基本一样，只是不再重复创建 Key：

1. LiteLLM 校验 Token
2. LiteLLM 根据 `oid` 找到已有用户记录
3. LiteLLM 继续累计该用户的每周花费

## 8. Group 准入逻辑

只有满足以下条件的用户才能访问：

- Token 有效
- `aud` 匹配我们的 API App
- `iss` 来自指定 Tenant
- Token 未过期
- `groups` 中包含 `ENTRA_ALLOWED_GROUP_ID`

以下情况会拒绝访问：

- Token 无效
- Token 过期
- `aud` 不匹配
- `iss` 不匹配
- 用户不在允许的 Group 里

## 9. 每周 50 美元额度如何生效

额度由 LiteLLM 控制，不由 Entra 控制。

每个用户第一次进入系统时，`custom_auth` 会为其创建一个独立的 LiteLLM Internal User，并设置：

- `max_budget = 50`
- `budget_duration = 7d`
- `timezone = Asia/Shanghai`

这样效果就是：

- 每个用户独立记账
- 每个用户每周最多 50 美元
- 每周一上海时间 00:00 自动重置

## 10. 模型选择逻辑

模型选择分两层：

### 10.1 OpenCode 展示层

OpenCode 里展示你允许用户看到的模型名称，例如：

- `vertex-gemini-2.5-flash`
- `vertex-gemini-2.5-flash-lite`
- `vertex-gemini-2.5-pro`
- `vertex-gemini-3-pro-preview`
- `vertex-claude-sonnet-4-6`

### 10.2 LiteLLM 执行层

LiteLLM 把这些模型别名映射到真实的 Vertex AI 模型，例如：

- `vertex-gemini-2.5-flash -> vertex_ai/gemini-2.5-flash`
- `vertex-gemini-2.5-flash-lite -> vertex_ai/gemini-2.5-flash-lite`
- `vertex-gemini-2.5-pro -> vertex_ai/gemini-2.5-pro`
- `vertex-gemini-3-pro-preview -> vertex_ai/gemini-3-pro-preview`
- `vertex-claude-sonnet-4-6 -> vertex_ai/claude-sonnet-4-6@default`

## 11. 时序图

```text
User
  |
  | 1. 打开 OpenCode
  v
OpenCode
  |
  | 2. 获取 Entra Token
  v
Entra ID
  |
  | 3. 返回 Access Token
  v
OpenCode
  |
  | 4. 带 Token 请求 LiteLLM
  v
LiteLLM OSS
  |
  | 5. custom_auth 校验 JWT 和 Group
  | 6. 查找或创建 LiteLLM User
  | 7. 检查预算
  | 8. 转发到 Vertex AI
  v
Vertex AI
  |
  | 9. 返回结果
  v
LiteLLM OSS
  |
  | 10. 记录花费
  v
OpenCode
  |
  | 11. 展示结果
  v
User
```

## 12. 失败场景

### 12.1 用户不在允许的 Group 中

- LiteLLM `custom_auth` 返回 `403 Forbidden`

### 12.2 用户预算用完

- LiteLLM 拒绝请求
- 用户看到预算超限错误

### 12.3 Token 过期

- LiteLLM `custom_auth` 返回 `401 Unauthorized`
- 用户需要重新登录

### 12.4 Vertex AI 调用失败

- LiteLLM 返回模型调用错误
- OpenCode 直接收到错误

## 13. 当前项目中的相关文件

- LiteLLM 配置：[config/litellm-config.yaml](D:/ws/vertex-dev/config/litellm-config.yaml)
- LiteLLM 自定义认证：[config/auth_handler.py](D:/ws/vertex-dev/config/auth_handler.py)
- OpenCode 示例配置：[config/opencode.example.json](D:/ws/vertex-dev/config/opencode.example.json)
- GKE 部署脚本：[scripts/deploy-demo.ps1](D:/ws/vertex-dev/scripts/deploy-demo.ps1)
- Entra 初始化脚本：[scripts/setup-entra-oss.ps1](D:/ws/vertex-dev/scripts/setup-entra-oss.ps1)
- 获取 Token 脚本：[scripts/get-entra-token.ps1](D:/ws/vertex-dev/scripts/get-entra-token.ps1)
- JWT 解码脚本：[scripts/decode-jwt.ps1](D:/ws/vertex-dev/scripts/decode-jwt.ps1)

## 14. 建议的落地顺序

建议按两步推进：

第一步：

- 保留当前已经跑通的 LiteLLM OSS + Vertex AI + 每周预算
- 部署带 `custom_auth` 的自定义 LiteLLM 镜像

第二步：

- 补齐真实 Entra Tenant / Client / Group 配置
- 让 OpenCode 直接用 Entra Access Token 调 LiteLLM

这样做的好处是：

- 继续使用 LiteLLM 开源版
- 不需要自研计费模块
- 不需要额外的认证服务
- 保持架构清晰，后续也容易扩展
