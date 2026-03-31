// Model pricing per 1k tokens (USD), based on Anthropic published rates.
// Prices are approximate — update as Anthropic revises them.
export const MODEL_PRICING: Record<string, { inputPer1k: number; outputPer1k: number }> = {
  // Claude 4 family
  "claude-opus-4-5": { inputPer1k: 0.015, outputPer1k: 0.075 },
  "claude-opus-4-6": { inputPer1k: 0.015, outputPer1k: 0.075 },
  "claude-sonnet-4-5": { inputPer1k: 0.003, outputPer1k: 0.015 },
  "claude-sonnet-4-6": { inputPer1k: 0.003, outputPer1k: 0.015 },
  "claude-haiku-4-5": { inputPer1k: 0.00025, outputPer1k: 0.00125 },
  // Claude 3 family
  "claude-3-opus-20240229": { inputPer1k: 0.015, outputPer1k: 0.075 },
  "claude-3-5-sonnet-20241022": { inputPer1k: 0.003, outputPer1k: 0.015 },
  "claude-3-5-haiku-20241022": { inputPer1k: 0.001, outputPer1k: 0.005 },
  "claude-3-haiku-20240307": { inputPer1k: 0.00025, outputPer1k: 0.00125 },
  // Fallback for unknown models — use mid-tier sonnet pricing
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
