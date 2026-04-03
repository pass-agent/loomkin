import Conf from "conf";

interface CloudAuth {
  accessToken: string;
  expiresAt: string; // ISO 8601
  scope: string;
  serverUrl: string;
}

interface CloudConfigSchema {
  auth: CloudAuth | null;
}

const cloudConfig = new Conf<CloudConfigSchema>({
  projectName: "loomkin",
  configName: "cloud",
  defaults: {
    auth: null,
  },
});

export function getCloudAuth(): CloudAuth | null {
  return cloudConfig.get("auth") ?? null;
}

export function setCloudAuth(auth: CloudAuth): void {
  cloudConfig.set("auth", auth);
}

export function clearCloudAuth(): void {
  cloudConfig.set("auth", null);
}

export function isCloudAuthenticated(): boolean {
  const auth = getCloudAuth();
  if (!auth) return false;
  // Check expiry
  if (new Date(auth.expiresAt) <= new Date()) return false;
  return true;
}

export function getCloudToken(): string | null {
  if (!isCloudAuthenticated()) return null;
  return getCloudAuth()!.accessToken;
}
