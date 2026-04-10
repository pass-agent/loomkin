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
  "gpt-4o": { inputPer1k: 0.0025, outputPer1k: 0.01 },
  "gpt-4o-mini": { inputPer1k: 0.00015, outputPer1k: 0.0006 },
  "gpt-4-turbo": { inputPer1k: 0.01, outputPer1k: 0.03 },
  "gpt-3.5-turbo": { inputPer1k: 0.0005, outputPer1k: 0.0015 },
  o1: { inputPer1k: 0.015, outputPer1k: 0.06 },
  "o1-mini": { inputPer1k: 0.0011, outputPer1k: 0.0044 },
  "o3-mini": { inputPer1k: 0.0011, outputPer1k: 0.0044 },
  // OpenAI — 2025/2026 models
  "gpt-5": { inputPer1k: 0.00125, outputPer1k: 0.01 },
  "gpt-4.1": { inputPer1k: 0.002, outputPer1k: 0.008 },
  "gpt-4.1-mini": { inputPer1k: 0.0004, outputPer1k: 0.0016 },
  "gpt-4.1-nano": { inputPer1k: 0.0001, outputPer1k: 0.0004 },
  o3: { inputPer1k: 0.002, outputPer1k: 0.008 },
  "o3-pro": { inputPer1k: 0.02, outputPer1k: 0.08 },
  "o4-mini": { inputPer1k: 0.0011, outputPer1k: 0.0044 },
  "gpt-5-nano": { inputPer1k: 0.00005, outputPer1k: 0.0004 },
  "gpt-5-mini": { inputPer1k: 0.00025, outputPer1k: 0.002 },
  "gpt-5.1": { inputPer1k: 0.00125, outputPer1k: 0.01 },
  "gpt-5.1-codex-max": { inputPer1k: 0.00125, outputPer1k: 0.01 },
  "gpt-5.2": { inputPer1k: 0.00175, outputPer1k: 0.014 },
  "gpt-5.3": { inputPer1k: 0.00175, outputPer1k: 0.014 },
  "gpt-5.4": { inputPer1k: 0.0025, outputPer1k: 0.015 },

  // Google Gemini
  "gemini-2.5-pro": { inputPer1k: 0.001, outputPer1k: 0.01 },
  "gemini-2.0-flash": { inputPer1k: 0.0001, outputPer1k: 0.0004 },
  "gemini-1.5-pro": { inputPer1k: 0.0035, outputPer1k: 0.0105 },
  "gemini-1.5-flash": { inputPer1k: 0.000075, outputPer1k: 0.0003 },
  "gemini-1.5-flash-8b": { inputPer1k: 0.0000375, outputPer1k: 0.00015 },
  // Google Gemini — 2025/2026 models
  "gemini-2.5-flash": { inputPer1k: 0.0003, outputPer1k: 0.0025 },
  "gemini-2.5-flash-lite": { inputPer1k: 0.0001, outputPer1k: 0.0004 },
  "gemini-3-flash": { inputPer1k: 0.0005, outputPer1k: 0.003 },
  "gemini-3.1-pro": { inputPer1k: 0.002, outputPer1k: 0.015 },
  "gemini-2.0-flash-lite": { inputPer1k: 0.000075, outputPer1k: 0.0003 },
  "gemini-3-pro": { inputPer1k: 0.002, outputPer1k: 0.012 },
  "gemini-3.1-flash-lite": { inputPer1k: 0.00025, outputPer1k: 0.0015 },

  // Groq (hosted inference)
  "llama-3.3-70b-versatile": { inputPer1k: 0.00059, outputPer1k: 0.00079 },
  "llama-3.1-70b-versatile": { inputPer1k: 0.00059, outputPer1k: 0.00079 },
  "llama-3.1-8b-instant": { inputPer1k: 0.00005, outputPer1k: 0.00008 },
  "mixtral-8x7b-32768": { inputPer1k: 0.00024, outputPer1k: 0.00024 },
  "gemma2-9b-it": { inputPer1k: 0.0002, outputPer1k: 0.0002 },
  "llama-4-scout": { inputPer1k: 0.00011, outputPer1k: 0.00034 },
  "qwen3-32b": { inputPer1k: 0.00029, outputPer1k: 0.00059 },

  // xAI Grok
  "grok-2": { inputPer1k: 0.002, outputPer1k: 0.01 },
  "grok-2-mini": { inputPer1k: 0.0002, outputPer1k: 0.0004 },
  "grok-beta": { inputPer1k: 0.005, outputPer1k: 0.015 },
  "grok-3": { inputPer1k: 0.003, outputPer1k: 0.015 },
  "grok-3-mini": { inputPer1k: 0.0003, outputPer1k: 0.0005 },
  "grok-3-fast": { inputPer1k: 0.005, outputPer1k: 0.025 },
  "grok-4": { inputPer1k: 0.003, outputPer1k: 0.015 },
  "grok-4-fast": { inputPer1k: 0.0002, outputPer1k: 0.0005 },
  "grok-4.1": { inputPer1k: 0.003, outputPer1k: 0.015 },
  "grok-4.1-fast": { inputPer1k: 0.0002, outputPer1k: 0.0005 },

  // Mistral
  "mistral-large-latest": { inputPer1k: 0.0005, outputPer1k: 0.0015 },
  "mistral-medium-3.1": { inputPer1k: 0.0004, outputPer1k: 0.002 },
  "mistral-small-latest": { inputPer1k: 0.00007, outputPer1k: 0.0002 },
  "codestral-latest": { inputPer1k: 0.0003, outputPer1k: 0.0009 },

  // DeepSeek
  "deepseek-chat": { inputPer1k: 0.000014, outputPer1k: 0.000028 }, // V3 — $0.014/$0.028 per 1M
  "deepseek-v3": { inputPer1k: 0.000014, outputPer1k: 0.000028 },
  "deepseek-reasoner": { inputPer1k: 0.00055, outputPer1k: 0.002 }, // R1 — $0.55/$2.00 per 1M
  "deepseek-r1": { inputPer1k: 0.00055, outputPer1k: 0.002 },
  "deepseek-v3.1": { inputPer1k: 0.00015, outputPer1k: 0.00075 }, // $0.15/$0.75 per 1M
  "deepseek-v3.2": { inputPer1k: 0.00026, outputPer1k: 0.00038 }, // $0.26/$0.38 per 1M

  // Zhipu AI (ZAI) GLM
  "glm-4.5": { inputPer1k: 0.0006, outputPer1k: 0.0022 }, // $0.60/$2.20 per 1M
  "glm-4.6": { inputPer1k: 0.00039, outputPer1k: 0.0017 }, // $0.39/$1.70 per 1M
  "glm-4.7": { inputPer1k: 0.0006, outputPer1k: 0.0022 }, // $0.60/$2.20 per 1M

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
