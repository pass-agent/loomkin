const isDev = !process.env.NODE_ENV || process.env.NODE_ENV === "development";
export const DEFAULT_SERVER_URL =
  process.env.LOOMKIN_SERVER_URL ??
  (isDev ? "https://loom.test" : "https://api.loomkin.dev");
export const DEV_FALLBACK_URL = isDev ? "http://localhost:4200" : null;
export const DEFAULT_MODE = "code";
export const DEFAULT_MODEL = "";

export const MODES = ["code", "plan", "chat"] as const;
export type Mode = (typeof MODES)[number];
