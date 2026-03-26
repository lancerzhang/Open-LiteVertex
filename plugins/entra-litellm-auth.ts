import { existsSync, mkdirSync, readFileSync, writeFileSync, chmodSync } from "node:fs"
import os from "node:os"
import path from "node:path"

const DUMMY_API_KEY = "opencode-entra-plugin-placeholder"
const TOKEN_REFRESH_SKEW_SECONDS = 300

type EntraSettings = {
  providerId: string
  providerName: string
  tenantId: string
  clientId: string
  publicClientId: string
  scope: string
  baseURL: string
  tokenCachePath: string
}

type TokenPayload = {
  accessToken: string
  expiresOnEpoch?: number
}

type TokenCacheRecord = TokenPayload & {
  tenantId: string
  clientId: string
  publicClientId: string
  scope: string
  refreshToken?: string
}

type StoredOAuthAuth = {
  type: "oauth"
  refresh?: string
  access?: string
  expires?: number
}

class InteractionRequiredError extends Error {}

const PROVIDER_SETTINGS: Record<string, EntraSettings> = {
  litellm: {
    providerId: "litellm",
    providerName: "Entra LiteVertex",
    tenantId: "2647159d-89f7-4c5e-aa37-c3218de7b638",
    clientId: "f5f8f478-9688-4984-a83e-2136b3871838",
    publicClientId: "ab845a82-90aa-4fff-967f-77a6f9766687",
    scope: "api://f5f8f478-9688-4984-a83e-2136b3871838/access_as_user offline_access",
    baseURL: "http://35.229.226.109/v1",
    tokenCachePath: path.join(os.homedir(), ".config", "opencode", "entra-device-token.json"),
  },
  "litellm-dev": {
    providerId: "litellm-dev",
    providerName: "Entra LiteVertex - dev",
    tenantId: "2647159d-89f7-4c5e-aa37-c3218de7b638",
    clientId: "f5f8f478-9688-4984-a83e-2136b3871838",
    publicClientId: "ab845a82-90aa-4fff-967f-77a6f9766687",
    scope: "api://f5f8f478-9688-4984-a83e-2136b3871838/access_as_user offline_access",
    baseURL: "http://35.229.226.109/v1",
    tokenCachePath: path.join(os.homedir(), ".config", "opencode", "entra-device-token.dev.json"),
  },
}

function normalizeScope(scope: string): string {
  const scopes = scope.split(/\s+/).map((part) => part.trim()).filter(Boolean)
  if (!scopes.includes("offline_access")) scopes.push("offline_access")
  return scopes.join(" ")
}

function isPluginDisabled(): boolean {
  const raw = String(process.env.ENTRA_OPENCODE_PLUGIN_DISABLED ?? "").trim().toLowerCase()
  return raw === "1" || raw === "true" || raw === "yes"
}

function readTokenCache(settings: EntraSettings): TokenCacheRecord | undefined {
  if (!existsSync(settings.tokenCachePath)) return undefined

  try {
    const payload = JSON.parse(readFileSync(settings.tokenCachePath, "utf8")) as Partial<TokenCacheRecord>
    if (
      String(payload.tenantId ?? "").trim() !== settings.tenantId ||
      String(payload.clientId ?? "").trim() !== settings.clientId ||
      String(payload.publicClientId ?? "").trim() !== settings.publicClientId ||
      String(payload.scope ?? "").trim() !== normalizeScope(settings.scope)
    ) {
      return undefined
    }

    const accessToken = String(payload.accessToken ?? "").trim()
    if (!accessToken) return undefined

    return {
      tenantId: settings.tenantId,
      clientId: settings.clientId,
      publicClientId: settings.publicClientId,
      scope: normalizeScope(settings.scope),
      accessToken,
      expiresOnEpoch: Number(payload.expiresOnEpoch ?? 0) || undefined,
      refreshToken: String(payload.refreshToken ?? "").trim() || undefined,
    }
  } catch {
    return undefined
  }
}

function writeTokenCache(settings: EntraSettings, payload: TokenCacheRecord): void {
  mkdirSync(path.dirname(settings.tokenCachePath), { recursive: true })
  writeFileSync(settings.tokenCachePath, JSON.stringify(payload, null, 2), "utf8")
  if (process.platform !== "win32") {
    try {
      chmodSync(settings.tokenCachePath, 0o600)
    } catch {}
  }
}

function isFreshToken(token?: TokenPayload): boolean {
  if (!token) return false
  const expiresOnEpoch = Number(token.expiresOnEpoch ?? 0)
  if (!Number.isFinite(expiresOnEpoch) || expiresOnEpoch <= 0) return false
  return expiresOnEpoch > Math.floor(Date.now() / 1000) + TOKEN_REFRESH_SKEW_SECONDS
}

async function postForm(url: string, data: Record<string, string>): Promise<{ status: number; payload: any }> {
  const response = await fetch(url, {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
    },
    body: new URLSearchParams(data),
  })

  const rawBody = await response.text()
  let payload: any = {}
  if (rawBody.trim()) {
    try {
      payload = JSON.parse(rawBody)
    } catch {
      payload = { error_description: rawBody.trim() }
    }
  }

  return { status: response.status, payload }
}

function formatEntraError(prefix: string, payload: any): string {
  const errorCode = String(payload?.error ?? "").trim()
  const description = String(payload?.error_description ?? "").trim()
  if (errorCode && description) return `${prefix} ${errorCode}: ${description}`
  if (errorCode) return `${prefix} ${errorCode}`
  if (description) return `${prefix} ${description}`
  return prefix
}

async function requestDeviceCode(settings: EntraSettings): Promise<any> {
  const url = `https://login.microsoftonline.com/${settings.tenantId}/oauth2/v2.0/devicecode`
  const { status, payload } = await postForm(url, {
    client_id: settings.publicClientId,
    scope: normalizeScope(settings.scope),
  })
  if (status !== 200) {
    throw new Error(formatEntraError(`Microsoft Entra device-code request failed for ${settings.providerName}.`, payload))
  }
  return payload
}

async function pollForDeviceCodeToken(settings: EntraSettings, deviceCodePayload: any): Promise<any> {
  const url = `https://login.microsoftonline.com/${settings.tenantId}/oauth2/v2.0/token`
  const deviceCode = String(deviceCodePayload?.device_code ?? "").trim()
  const expiresInSeconds = Math.max(Number(deviceCodePayload?.expires_in ?? 900) || 900, 1)
  let intervalSeconds = Math.max(Number(deviceCodePayload?.interval ?? 5) || 5, 1)
  const deadline = Date.now() + expiresInSeconds * 1000

  while (Date.now() < deadline) {
    const { status, payload } = await postForm(url, {
      client_id: settings.publicClientId,
      grant_type: "urn:ietf:params:oauth:grant-type:device_code",
      device_code: deviceCode,
    })
    if (status === 200) {
      return payload
    }

    const errorCode = String(payload?.error ?? "").trim()
    if (errorCode === "authorization_pending") {
      await new Promise((resolve) => setTimeout(resolve, intervalSeconds * 1000))
      continue
    }
    if (errorCode === "slow_down") {
      intervalSeconds += 5
      await new Promise((resolve) => setTimeout(resolve, intervalSeconds * 1000))
      continue
    }
    if (errorCode === "authorization_declined") {
      throw new Error(`Microsoft Entra device-code login was declined for ${settings.providerName}.`)
    }
    if (errorCode === "expired_token") {
      throw new Error(`Microsoft Entra device-code login expired before completion for ${settings.providerName}.`)
    }

    throw new Error(formatEntraError(`Microsoft Entra device-code login failed for ${settings.providerName}.`, payload))
  }

  throw new Error(`Microsoft Entra device-code login timed out for ${settings.providerName}.`)
}

async function refreshToken(settings: EntraSettings, refreshTokenValue: string): Promise<any> {
  const url = `https://login.microsoftonline.com/${settings.tenantId}/oauth2/v2.0/token`
  const { status, payload } = await postForm(url, {
    client_id: settings.publicClientId,
    grant_type: "refresh_token",
    refresh_token: refreshTokenValue,
    scope: normalizeScope(settings.scope),
  })
  if (status === 200) {
    return payload
  }

  const errorCode = String(payload?.error ?? "").trim()
  if (errorCode === "invalid_grant" || errorCode === "interaction_required") {
    throw new InteractionRequiredError(`Microsoft Entra requires the user to log in again for ${settings.providerName}.`)
  }
  throw new Error(formatEntraError(`Microsoft Entra refresh-token request failed for ${settings.providerName}.`, payload))
}

function buildTokenPayload(payload: any): TokenPayload {
  const accessToken = String(payload?.access_token ?? payload?.accessToken ?? "").trim()
  if (!accessToken) {
    throw new Error("Microsoft Entra did not return an access token.")
  }

  const expiresOnEpoch =
    Number(payload?.expiresOnEpoch ?? 0) ||
    (Number(payload?.expires_in ?? 0) > 0 ? Math.floor(Date.now() / 1000) + Number(payload.expires_in) : undefined)

  return {
    accessToken,
    expiresOnEpoch: Number.isFinite(Number(expiresOnEpoch)) && Number(expiresOnEpoch) > 0 ? Number(expiresOnEpoch) : undefined,
  }
}

function buildTokenCacheRecord(
  settings: EntraSettings,
  token: TokenPayload,
  refreshTokenValue?: string,
): TokenCacheRecord {
  return {
    tenantId: settings.tenantId,
    clientId: settings.clientId,
    publicClientId: settings.publicClientId,
    scope: normalizeScope(settings.scope),
    accessToken: token.accessToken,
    expiresOnEpoch: token.expiresOnEpoch,
    refreshToken: refreshTokenValue,
  }
}

function getRefreshToken(payload: any, fallback?: string): string | undefined {
  return String(payload?.refresh_token ?? fallback ?? "").trim() || undefined
}

function tokenCacheFromAuth(settings: EntraSettings, auth: unknown): TokenCacheRecord | undefined {
  if (!auth || typeof auth !== "object" || (auth as StoredOAuthAuth).type !== "oauth") {
    return undefined
  }

  const accessToken = String((auth as StoredOAuthAuth).access ?? "").trim()
  if (!accessToken) return undefined

  const expiresMs = Number((auth as StoredOAuthAuth).expires ?? 0)
  const expiresOnEpoch = Number.isFinite(expiresMs) && expiresMs > 0 ? Math.floor(expiresMs / 1000) : undefined

  return buildTokenCacheRecord(
    settings,
    { accessToken, expiresOnEpoch },
    String((auth as StoredOAuthAuth).refresh ?? "").trim() || undefined,
  )
}

async function acquireAccessToken(settings: EntraSettings, allowInteraction: boolean, auth?: unknown): Promise<TokenPayload> {
  let cacheRecord = readTokenCache(settings)
  const authRecord = tokenCacheFromAuth(settings, auth)
  if (
    authRecord &&
    (!cacheRecord ||
      !cacheRecord.refreshToken ||
      (Number(authRecord.expiresOnEpoch ?? 0) > Number(cacheRecord.expiresOnEpoch ?? 0) &&
        authRecord.accessToken !== cacheRecord.accessToken))
  ) {
    cacheRecord = authRecord
    writeTokenCache(settings, authRecord)
  }

  if (isFreshToken(cacheRecord)) {
    return {
      accessToken: cacheRecord!.accessToken,
      expiresOnEpoch: cacheRecord!.expiresOnEpoch,
    }
  }

  if (cacheRecord?.refreshToken) {
    try {
      const refreshed = await refreshToken(settings, cacheRecord.refreshToken)
      const token = buildTokenPayload(refreshed)
      writeTokenCache(settings, buildTokenCacheRecord(settings, token, getRefreshToken(refreshed, cacheRecord.refreshToken)))
      return token
    } catch (error) {
      if (!(error instanceof InteractionRequiredError)) {
        throw error
      }
    }
  }

  if (!allowInteraction) {
    throw new Error(`No reusable Entra device-code token is available for ${settings.providerName}. Run \`opencode auth login\` first.`)
  }

  throw new InteractionRequiredError(`Microsoft Entra requires interactive device-code login for ${settings.providerName}.`)
}

async function completeDeviceCodeLogin(settings: EntraSettings, deviceCodePayload: any) {
  const tokenResponse = await pollForDeviceCodeToken(settings, deviceCodePayload)
  const token = buildTokenPayload(tokenResponse)
  const refreshTokenValue = getRefreshToken(tokenResponse)
  writeTokenCache(settings, buildTokenCacheRecord(settings, token, refreshTokenValue))
  return {
    token,
    refreshToken: refreshTokenValue,
  }
}

function createEntraAuthPlugin(settings: EntraSettings) {
  return async () => {
    let cachedToken: TokenPayload | undefined
    let pendingToken: Promise<TokenPayload> | undefined

    const getToken = async (allowInteraction: boolean, auth?: unknown): Promise<TokenPayload> => {
      if (!allowInteraction && isFreshToken(cachedToken)) {
        return cachedToken!
      }
      if (pendingToken) {
        return pendingToken
      }

      pendingToken = Promise.resolve()
        .then(() => acquireAccessToken(settings, allowInteraction, auth))
        .then((token) => {
          cachedToken = token
          return token
        })
        .finally(() => {
          pendingToken = undefined
        })

      return pendingToken
    }

    return {
      auth: {
        provider: settings.providerId,
        async loader(getAuth: () => Promise<any>) {
          return {
            baseURL: settings.baseURL,
            apiKey: DUMMY_API_KEY,
            async fetch(requestInput: RequestInfo | URL, init?: RequestInit) {
              if (isPluginDisabled()) {
                return fetch(requestInput, init)
              }

              const auth = await getAuth()
              if (!auth) {
                return fetch(requestInput, init)
              }

              const token = await getToken(false, auth).catch((error) => {
                throw new Error(
                  `Unable to refresh the Entra token for ${settings.providerName}. ${error instanceof Error ? error.message : String(error)}`,
                )
              })

              const request = new Request(requestInput, init)
              request.headers.delete("authorization")
              request.headers.delete("Authorization")
              request.headers.delete("x-api-key")
              request.headers.delete("X-API-Key")
              request.headers.set("Authorization", `Bearer ${token.accessToken}`)

              return fetch(request)
            },
          }
        },
        methods: [
          {
            type: "oauth" as const,
            label: "Microsoft Entra Device Code",
            async authorize() {
              const deviceCodePayload = await requestDeviceCode(settings)
              const verificationUrl =
                String(deviceCodePayload?.verification_uri_complete ?? "").trim() ||
                String(deviceCodePayload?.verification_uri ?? "").trim()
              const userCode = String(deviceCodePayload?.user_code ?? "").trim()

              return {
                url: verificationUrl,
                instructions: `Enter code: ${userCode}`,
                method: "auto" as const,
                callback: async () => {
                  const { token, refreshToken } = await completeDeviceCodeLogin(settings, deviceCodePayload)
                  return {
                    type: "success" as const,
                    refresh: refreshToken || token.accessToken,
                    access: token.accessToken,
                    expires: Number(token.expiresOnEpoch ?? 0) > 0 ? Number(token.expiresOnEpoch) * 1000 : Date.now(),
                  }
                },
              }
            },
          },
        ],
      },
    }
  }
}

const prodPlugin = createEntraAuthPlugin(PROVIDER_SETTINGS.litellm)
const devPlugin = createEntraAuthPlugin(PROVIDER_SETTINGS["litellm-dev"])

export const EntraLiteVertexAuthPlugin = prodPlugin
export const EntraLiteVertexDevAuthPlugin = devPlugin
