const DEFAULT_MAX_CHARS = parseInt(process.env.MCP_MAX_OUTPUT_CHARS ?? "100000", 10);

export function isMcpTool(toolName: string): boolean {
  return toolName.startsWith("mcp__");
}

export function truncateMcpOutput(
  output: string,
  maxChars = DEFAULT_MAX_CHARS,
): { output: string; truncated: boolean; removedChars: number } {
  if (output.length <= maxChars) return { output, truncated: false, removedChars: 0 };

  // Keep first 45% and last 45%, remove middle
  const keepEach = Math.floor(maxChars * 0.45);
  const removed = output.length - keepEach * 2;
  const truncated =
    output.slice(0, keepEach) +
    `\n[... ${removed} chars truncated by Loomkin to prevent context overflow ...]\n` +
    output.slice(output.length - keepEach);
  return { output: truncated, truncated: true, removedChars: removed };
}
