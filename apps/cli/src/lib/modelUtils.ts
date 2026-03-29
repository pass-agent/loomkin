import type { ModelProvider } from "./types.js";

export function isProviderConfigured(provider: ModelProvider): boolean {
  const s = provider.status;
  return (
    (s.type === "api_key" && s.status === "set") ||
    (s.type === "oauth" && s.status === "connected") ||
    (s.type === "local" && s.status === "available")
  );
}
