export function formatTokens(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}k`;
  return String(n);
}

export function formatCost(usd: number | null): string {
  if (usd === null || usd === 0) return "$0.00";
  return `$${usd.toFixed(4)}`;
}
