import { getCloudToken } from "./cloudConfig.js";
import type {
  DeviceCodeResponse,
  DeviceTokenResponse,
  DeviceTokenError,
  CloudVault,
  VaultSearchResult,
} from "./types.js";

const CLOUD_BASE_URL = process.env.LOOMKIN_CLOUD_URL ?? "https://loomkin.dev";

export function getCloudBaseUrl(): string {
  return CLOUD_BASE_URL;
}

export class CloudApiError extends Error {
  constructor(
    public status: number,
    public body: string,
  ) {
    super(`${status} ${body.length <= 120 ? body : body.slice(0, 120) + "..."}`);
    this.name = "CloudApiError";
  }

  get parsedBody(): Record<string, unknown> | null {
    try {
      return JSON.parse(this.body);
    } catch {
      return null;
    }
  }
}

async function cloudRequest<T>(
  path: string,
  options: RequestInit = {},
  authenticated = false,
): Promise<T> {
  const url = `${CLOUD_BASE_URL}${path}`;

  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    ...(options.headers as Record<string, string>),
  };

  if (authenticated) {
    const token = getCloudToken();
    if (token) {
      headers["Authorization"] = `Bearer ${token}`;
    }
  }

  const response = await fetch(url, { ...options, headers });

  if (!response.ok) {
    const body = await response.text();
    throw new CloudApiError(response.status, body);
  }

  return response.json() as Promise<T>;
}

// --- Device code endpoints (public, no auth) ---

export async function requestDeviceCode(): Promise<DeviceCodeResponse> {
  return cloudRequest<DeviceCodeResponse>("/api/v1/device/code", {
    method: "POST",
    body: JSON.stringify({
      client_id: "loomkin-cli",
      scope: "vault:read vault:write",
    }),
  });
}

export async function pollDeviceToken(
  deviceCode: string,
): Promise<DeviceTokenResponse> {
  return cloudRequest<DeviceTokenResponse>("/api/v1/device/token", {
    method: "POST",
    body: JSON.stringify({
      device_code: deviceCode,
      grant_type: "urn:ietf:params:oauth:grant-type:device_code",
    }),
  });
}

/**
 * Poll that handles the RFC 8628 error responses.
 * Returns the token response on success, or throws on terminal errors.
 * Returns null for authorization_pending (caller should keep polling).
 * Returns "slow_down" when the server asks to back off.
 */
export async function pollDeviceTokenSafe(
  deviceCode: string,
): Promise<DeviceTokenResponse | "pending" | "slow_down"> {
  const url = `${CLOUD_BASE_URL}/api/v1/device/token`;

  const response = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      device_code: deviceCode,
      grant_type: "urn:ietf:params:oauth:grant-type:device_code",
    }),
  });

  if (response.ok) {
    return response.json() as Promise<DeviceTokenResponse>;
  }

  const body = await response.text();
  let parsed: DeviceTokenError | null = null;
  try {
    parsed = JSON.parse(body) as DeviceTokenError;
  } catch {
    throw new CloudApiError(response.status, body);
  }

  if (parsed?.error === "authorization_pending") return "pending";
  if (parsed?.error === "slow_down") return "slow_down";

  // Terminal errors
  throw new CloudApiError(
    response.status,
    parsed?.error_description ?? parsed?.error ?? body,
  );
}

// --- Vault endpoints (authenticated) ---

export async function listVaults(): Promise<{ vaults: CloudVault[] }> {
  return cloudRequest<{ vaults: CloudVault[] }>("/api/v1/vaults", {}, true);
}

export async function getVault(vaultId: string): Promise<{ vault: CloudVault }> {
  return cloudRequest<{ vault: CloudVault }>(
    `/api/v1/vaults/${encodeURIComponent(vaultId)}`,
    {},
    true,
  );
}

export async function searchVault(
  vaultId: string,
  query: string,
): Promise<{ results: VaultSearchResult[] }> {
  const params = new URLSearchParams({ q: query });
  return cloudRequest<{ results: VaultSearchResult[] }>(
    `/api/v1/vaults/${encodeURIComponent(vaultId)}/search?${params}`,
    {},
    true,
  );
}
