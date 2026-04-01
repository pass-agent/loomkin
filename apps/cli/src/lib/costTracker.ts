// Model pricing per 1k tokens (USD), based on published rates per provider.
// Prices are approximate — update as providers revise their pricing.
export const MODEL_PRICING: Record<string, { inputPer1k: number; outputPer1k: number }> = {
  // Anthropic Claude 4 family
  "claude-opus-4-5": { inputPer1k: 0.015, outputPer1k: 0.075 },
  "claude-opus-4-6": { inputPer1k: 0.015, outputPer1k: 0.075 },
  "claude-sonnet-4-5": { inputPer1k: 0.003, outputPer1k: 0.015 },
  "claude-sonnet-4-6": { inputPer1k: 0.003, outputPer1k: 0.015 },
  "claude-haiku-4-5": { inputPer1k: 0.001, outputPer1k: 0.005 },
  // Anthropic Claude 3 family
  "claude-3-opus-20240229": { inputPer1k: 0.015, outputPer1k: 0.075 },
  "claude-3-5-sonnet-20241022": { inputPer1k: 0.003, outputPer1k: 0.015 },
  "claude-3-5-haiku-20241022": { inputPer1k: 0.0008, outputPer1k: 0.004 },
  "claude-3-haiku-20240307": { inputPer1k: 0.00025, outputPer1k: 0.00125 },

  // OpenAI
  "gpt-4o": { inputPer1k: 0.0025, outputPer1k: 0.010 },
  "gpt-4o-mini": { inputPer1k: 0.000150, outputPer1k: 0.000600 },
  "gpt-4-turbo": { inputPer1k: 0.010, outputPer1k: 0.030 },
  "gpt-3.5-turbo": { inputPer1k: 0.000500, outputPer1k: 0.001500 },
  "o1": { inputPer1k: 0.015, outputPer1k: 0.060 },
  "o1-mini": { inputPer1k: 0.001100, outputPer1k: 0.004400 },
  "o3-mini": { inputPer1k: 0.001100, outputPer1k: 0.004400 },
  // OpenAI — 2025/2026 models
  "gpt-5":        { inputPer1k: 0.001250, outputPer1k: 0.010 },
  "gpt-4.1":      { inputPer1k: 0.002,    outputPer1k: 0.008 },
  "gpt-4.1-mini": { inputPer1k: 0.0004,   outputPer1k: 0.0016 },
  "gpt-4.1-nano": { inputPer1k: 0.0001,   outputPer1k: 0.0004 },
  "o3":           { inputPer1k: 0.002,    outputPer1k: 0.008 },
  "o3-pro":       { inputPer1k: 0.020,    outputPer1k: 0.080 },
  "o4-mini":      { inputPer1k: 0.001100, outputPer1k: 0.004400 },
  "gpt-5-nano":          { inputPer1k: 0.000050, outputPer1k: 0.000400 },
  "gpt-5-mini":          { inputPer1k: 0.000250, outputPer1k: 0.002000 },
  "gpt-5.1":             { inputPer1k: 0.001250, outputPer1k: 0.010000 },
  "gpt-5.1-codex-max":   { inputPer1k: 0.001250, outputPer1k: 0.010000 },
  "gpt-5.2":             { inputPer1k: 0.001750, outputPer1k: 0.014000 },
  "gpt-5.3":             { inputPer1k: 0.001750, outputPer1k: 0.014000 },
  "gpt-5.4":             { inputPer1k: 0.002500, outputPer1k: 0.015000 },

  // Google Gemini
  "gemini-2.5-pro": { inputPer1k: 0.001000, outputPer1k: 0.010 },
  "gemini-2.0-flash": { inputPer1k: 0.000100, outputPer1k: 0.000400 },
  "gemini-1.5-pro": { inputPer1k: 0.003500, outputPer1k: 0.010500 },
  "gemini-1.5-flash": { inputPer1k: 0.000075, outputPer1k: 0.000300 },
  "gemini-1.5-flash-8b": { inputPer1k: 0.0000375, outputPer1k: 0.000150 },
  // Google Gemini — 2025/2026 models
  "gemini-2.5-flash":      { inputPer1k: 0.000300, outputPer1k: 0.002500 },
  "gemini-2.5-flash-lite": { inputPer1k: 0.000100, outputPer1k: 0.000400 },
  "gemini-3-flash":        { inputPer1k: 0.000500, outputPer1k: 0.003000 },
  "gemini-3.1-pro":        { inputPer1k: 0.002000, outputPer1k: 0.015000 },
  "gemini-2.0-flash-lite":  { inputPer1k: 0.000075, outputPer1k: 0.000300 },
  "gemini-3-pro":           { inputPer1k: 0.002000, outputPer1k: 0.012000 },
  "gemini-3.1-flash-lite":  { inputPer1k: 0.000250, outputPer1k: 0.001500 },

  // Groq (hosted inference)
  "llama-3.3-70b-versatile": { inputPer1k: 0.000590, outputPer1k: 0.000790 },
  "llama-3.1-70b-versatile": { inputPer1k: 0.000590, outputPer1k: 0.000790 },
  "llama-3.1-8b-instant": { inputPer1k: 0.000050, outputPer1k: 0.000080 },
  "mixtral-8x7b-32768": { inputPer1k: 0.000240, outputPer1k: 0.000240 },
  "gemma2-9b-it": { inputPer1k: 0.000200, outputPer1k: 0.000200 },
  "llama-4-scout": { inputPer1k: 0.000110, outputPer1k: 0.000340 },
  "qwen3-32b":     { inputPer1k: 0.000290, outputPer1k: 0.000590 },

  // xAI Grok
  "grok-2": { inputPer1k: 0.002, outputPer1k: 0.010 },
  "grok-2-mini": { inputPer1k: 0.0002, outputPer1k: 0.0004 },
  "grok-beta":  { inputPer1k: 0.005,  outputPer1k: 0.015 },
  "grok-3":     { inputPer1k: 0.003,  outputPer1k: 0.015 },
  "grok-3-mini":  { inputPer1k: 0.0003,  outputPer1k: 0.0005  },
  "grok-3-fast":  { inputPer1k: 0.005000, outputPer1k: 0.025000 },
  "grok-4":       { inputPer1k: 0.003000, outputPer1k: 0.015000 },
  "grok-4-fast":  { inputPer1k: 0.000200, outputPer1k: 0.000500 },
  "grok-4.1":     { inputPer1k: 0.003000, outputPer1k: 0.015000 },
  "grok-4.1-fast": { inputPer1k: 0.000200, outputPer1k: 0.000500 },

  // Mistral
  "mistral-large-latest": { inputPer1k: 0.000500, outputPer1k: 0.001500 },
  "mistral-medium-3.1":   { inputPer1k: 0.000400, outputPer1k: 0.002000 },
  "mistral-small-latest": { inputPer1k: 0.000070, outputPer1k: 0.000200 },
  "codestral-latest":     { inputPer1k: 0.000300, outputPer1k: 0.000900 },

  // DeepSeek
  "deepseek-chat":            { inputPer1k: 0.000014, outputPer1k: 0.000028 },  // V3 — $0.014/$0.028 per 1M
  "deepseek-v3":              { inputPer1k: 0.000014, outputPer1k: 0.000028 },
  "deepseek-reasoner":        { inputPer1k: 0.000550, outputPer1k: 0.002000 },  // R1 — $0.55/$2.00 per 1M
  "deepseek-r1":              { inputPer1k: 0.000550, outputPer1k: 0.002000 },
  "deepseek-v3.1":            { inputPer1k: 0.000150, outputPer1k: 0.000750 },  // $0.15/$0.75 per 1M
  "deepseek-v3.2":            { inputPer1k: 0.000260, outputPer1k: 0.000380 },  // $0.26/$0.38 per 1M

  // Zhipu AI (ZAI) GLM
  "glm-4.5":  { inputPer1k: 0.000600, outputPer1k: 0.002200 },  // $0.60/$2.20 per 1M
  "glm-4.6":  { inputPer1k: 0.000390, outputPer1k: 0.001700 },  // $0.39/$1.70 per 1M
  "glm-4.7":  { inputPer1k: 0.000600, outputPer1k: 0.002200 },  // $0.60/$2.20 per 1M

  // Fallback for unknown models — mid-tier estimate; update as providers revise pricing
  _default: { inputPer1k: 0.003, outputPer1k: 0.015 },
};

function getPricing(model: string): { inputPer1k: number; outputPer1k: number } {
  // Exact match
  if (model in MODEL_PRICING) return MODEL_PRICING[model];

  // Strip provider prefix (e.g. "anthropic:claude-sonnet-4-6" → "claude-sonnet-4-6")
  const bare = model.replace(/^[^:]+:/, "");
  if (bare in MODEL_PRICING) return MODEL_PRICING[bare];

  // Prefix match — find longest matching key
  let best: { inputPer1k: number; outputPer1k: number } | null = null;
  let bestLen = 0;
  for (const [key, price] of Object.entries(MODEL_PRICING)) {
    if (key === "_default") continue;
    if (bare.startsWith(key) && key.length > bestLen) {
      best = price;
      bestLen = key.length;
    }
  }
  if (best) return best;

  return MODEL_PRICING["_default"];
}

export function calculateCost(model: string, inputTokens: number, outputTokens: number): number {
  const { inputPer1k, outputPer1k } = getPricing(model);
  return (inputTokens / 1000) * inputPer1k + (outputTokens / 1000) * outputPer1k;
}

export function formatCost(usd: number): string {
  if (usd < 0.01) {
    // Show sub-cent amounts with more precision
    return `~$${usd.toFixed(4)}`;
  }
  return `~$${usd.toFixed(2)}`;
}

export function formatTokens(count: number): string {
  if (count >= 1_000_000) {
    return `${(count / 1_000_000).toFixed(1)}M`;
  }
  if (count >= 1000) {
    return `${(count / 1000).toFixed(1)}k`;
  }
  return String(count);
}
