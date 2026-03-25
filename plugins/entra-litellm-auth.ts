import { existsSync, mkdirSync, readFileSync, writeFileSync, chmodSync } from "node:fs"
import os from "node:os"
import path from "node:path"

const PROVIDER_ID = "litellm"
const DEVICE_CODE_KEY = "device-code"
const DUMMY_API_KEY = "opencode-entra-plugin-placeholder"
const TOKEN_REFRESH_SKEW_SECONDS = 300
const DEFAULT_TOKEN_CACHE_PATH = path.join(os.homedir(), ".config", "opencode", "entra-device-token.json")

type EntraSettings = {
  tenantId: string
  clientId: string
  publicClientId: string
  scope: string
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

class InteractionRequiredError extends Error {}

function resolveRoot(input: any): string {
  const raw = input?.worktree || input?.directory || process.cwd()
  return path.resolve(String(raw))
}

function loadDotEnv(filePath: string): Record<string, string> {
  if (!existsSync(filePath)) return {}

  const env: Record<string, string> = {}
  for (const rawLine of readFileSync(filePath, "utf8").split(/\r?\n/)) {
    const line = rawLine.trim()
    if (!line || line.startsWith("#")) continue
    const separator = line.indexOf("=")
    if (separator < 0) continue
    const key = line.slice(0, separator).trim()
    const value = line.slice(separator + 1).trim()
    env[key] = value
  }
  return env
}

function normalizeScope(scope: string): string {
  const scopes = scope.split(/\s+/).map((part) => part.trim()).filter(Boolean)
  if (!scopes.includes("offline_access")) {
    scopes.push("offline_access")
  }
  return scopes.join(" ")
}

function resolveEntraSettings(root: string): EntraSettings | null {
  const envFilePath = process.env.ENTRA_ENV_PATH || path.join(root, ".entra.env")
  const fileEnv = loadDotEnv(envFilePath)
  const merged = { ...fileEnv, ...process.env }

  const tenantId = String(merged.ENTRA_TENANT_ID ?? "").trim()
  const clientId = String(merged.ENTRA_CLIENT_ID ?? "").trim()
  const publicClientId = String(merged.ENTRA_PUBLIC_CLIENT_ID ?? "").trim()

  if (!tenantId || !clientId || !publicClientId) {
    return null
  }

  const scope = String(merged.ENTRA_SCOPE ?? `api://${clientId}/access_as_user`).trim() || `api://${clientId}/access_as_user`
  const tokenCachePath = String(merged.ENTRA_TOKEN_CACHE_PATH ?? DEFAULT_TOKEN_CACHE_PATH).trim() || DEFAULT_TOKEN_CACHE_PATH

  return {
    tenantId,
    clientId,
    publicClientId,
    scope,
    tokenCachePath,
  }
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
    throw new Error(formatEntraError("Microsoft Entra device-code request failed.", payload))
  }
  return payload
}

function printDeviceCodePrompt(payload: any): void {
  const message = String(payload?.message ?? "").trim()
  const verificationUri = String(payload?.verification_uri ?? "").trim()
  const userCode = String(payload?.user_code ?? "").trim()
  const verificationUriComplete = String(payload?.verification_uri_complete ?? "").trim()

  if (message) {
    console.error(message)
  } else {
    console.error("Microsoft Entra device-code login is required.")
    console.error(`Open: ${verificationUri}`)
    console.error(`Code: ${userCode}`)
  }

  if (verificationUriComplete) {
    console.error(`Direct URL: ${verificationUriComplete}`)
  }
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
      throw new Error("Microsoft Entra device-code login was declined by the user.")
    }
    if (errorCode === "expired_token") {
      throw new Error("Microsoft Entra device-code login expired before it was completed.")
    }

    throw new Error(formatEntraError("Microsoft Entra device-code login failed.", payload))
  }

  throw new Error("Microsoft Entra device-code login timed out before authorization completed.")
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
    throw new InteractionRequiredError("Microsoft Entra requires the user to log in again.")
  }
  throw new Error(formatEntraError("Microsoft Entra refresh-token request failed.", payload))
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

async function acquireAccessToken(settings: EntraSettings, allowInteraction: boolean): Promise<TokenPayload> {
  const cacheRecord = readTokenCache(settings)
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
      writeTokenCache(settings, {
        tenantId: settings.tenantId,
        clientId: settings.clientId,
        publicClientId: settings.publicClientId,
        scope: normalizeScope(settings.scope),
        accessToken: token.accessToken,
        expiresOnEpoch: token.expiresOnEpoch,
        refreshToken: String(refreshed?.refresh_token ?? cacheRecord.refreshToken).trim() || cacheRecord.refreshToken,
      })
      return token
    } catch (error) {
      if (!(error instanceof InteractionRequiredError)) {
        throw error
      }
    }
  }

  if (!allowInteraction) {
    throw new Error("No reusable Entra device-code token is available. Run `opencode providers login --provider litellm` first.")
  }

  const deviceCodePayload = await requestDeviceCode(settings)
  printDeviceCodePrompt(deviceCodePayload)
  const tokenResponse = await pollForDeviceCodeToken(settings, deviceCodePayload)
  const token = buildTokenPayload(tokenResponse)
  writeTokenCache(settings, {
    tenantId: settings.tenantId,
    clientId: settings.clientId,
    publicClientId: settings.publicClientId,
    scope: normalizeScope(settings.scope),
    accessToken: token.accessToken,
    expiresOnEpoch: token.expiresOnEpoch,
    refreshToken: String(tokenResponse?.refresh_token ?? "").trim() || undefined,
  })
  return token
}

export const EntraLiteLLMAuthPlugin = async (input: any) => {
  const root = resolveRoot(input)
  let cachedToken: TokenPayload | undefined
  let cachedTokenKey = ""
  let pendingToken: Promise<TokenPayload> | undefined

  const getToken = async (settings: EntraSettings, allowInteraction: boolean): Promise<TokenPayload> => {
    const settingsKey = JSON.stringify(settings)
    if (!allowInteraction && cachedTokenKey === settingsKey && isFreshToken(cachedToken)) {
      return cachedToken!
    }
    if (pendingToken) {
      return pendingToken
    }

    pendingToken = Promise.resolve()
      .then(() => acquireAccessToken(settings, allowInteraction))
      .then((token) => {
        cachedToken = token
        cachedTokenKey = settingsKey
        return token
      })
      .finally(() => {
        pendingToken = undefined
      })

    return pendingToken
  }

  return {
    auth: {
      provider: PROVIDER_ID,
      async loader(getAuth: () => Promise<any>) {
        return {
          apiKey: process.env.LITELLM_API_KEY || DUMMY_API_KEY,
          async fetch(requestInput: RequestInfo | URL, init?: RequestInit) {
            if (isPluginDisabled()) {
              return fetch(requestInput, init)
            }

            const auth = await getAuth()
            const settings = resolveEntraSettings(root)
            if (!auth || !settings) {
              return fetch(requestInput, init)
            }

            const token = await getToken(settings, false).catch((error) => {
              throw new Error(
                `Unable to refresh the Entra token for LiteLLM. ${error instanceof Error ? error.message : String(error)}`,
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
          type: "api" as const,
          label: "Device Code",
          async authorize() {
            const settings = resolveEntraSettings(root)
            if (!settings) {
              throw new Error(
                "Missing Entra config. Export ENTRA_TENANT_ID, ENTRA_CLIENT_ID, ENTRA_PUBLIC_CLIENT_ID, or create .entra.env first.",
              )
            }

            await getToken(settings, true)
            return {
              type: "success" as const,
              key: DEVICE_CODE_KEY,
            }
          },
        },
      ],
    },
  }
}

export default EntraLiteLLMAuthPlugin
