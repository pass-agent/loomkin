import { Platform } from "react-native";

/**
 * In development, use the dev server URL.
 * For physical devices on iOS/Android, you may need to replace with your machine's IP.
 */
const DEV_API_URL = Platform.select({
  // Android emulator uses 10.0.2.2 to reach host machine
  android: "http://10.0.2.2:4200",
  // iOS simulator shares the host network — localhost works directly
  ios: "http://localhost:4200",
  default: "http://localhost:4200",
});

export const API_BASE_URL = __DEV__
  ? DEV_API_URL
  : "https://api.loomkin.com";

export const API_URL = `${API_BASE_URL}/api/v1`;

export const WS_URL = __DEV__
  ? `ws://${DEV_API_URL?.replace(/^https?:\/\//, "")}/socket`
  : "wss://api.loomkin.com/socket";

export const SECURE_STORE_KEYS = {
  AUTH_TOKEN: "loomkin_auth_token",
  USER_DATA: "loomkin_user_data",
} as const;

export const QUERY_KEYS = {
  sessions: ["sessions"] as const,
  session: (id: string) => ["sessions", id] as const,
  sessionMessages: (id: string) => ["sessions", id, "messages"] as const,
  teams: ["teams"] as const,
  team: (id: string) => ["teams", id] as const,
  teamAgents: (teamId: string) => ["teams", teamId, "agents"] as const,
  models: ["models"] as const,
  modelProviders: ["modelProviders"] as const,
  settings: ["settings"] as const,
  backlog: ["backlog"] as const,
  me: ["me"] as const,
} as const;

export const COLORS = {
  primary: "#6366f1",
  primaryDark: "#4f46e5",
  primaryLight: "#818cf8",
  secondary: "#8b5cf6",
  background: "#0f0f23",
  surface: "#1a1a2e",
  surfaceLight: "#252547",
  text: "#e2e8f0",
  textSecondary: "#94a3b8",
  textMuted: "#64748b",
  border: "#334155",
  success: "#22c55e",
  warning: "#f59e0b",
  error: "#ef4444",
  info: "#3b82f6",
  userBubble: "#6366f1",
  assistantBubble: "#1e293b",
  systemBubble: "#374151",
  toolBubble: "#1e1e3a",
  white: "#ffffff",
  black: "#000000",
} as const;

export const FONT_SIZES = {
  xs: 10,
  sm: 12,
  base: 14,
  md: 16,
  lg: 18,
  xl: 20,
  "2xl": 24,
  "3xl": 30,
} as const;

export const SPACING = {
  xs: 4,
  sm: 8,
  md: 12,
  lg: 16,
  xl: 20,
  "2xl": 24,
  "3xl": 32,
  "4xl": 40,
} as const;
