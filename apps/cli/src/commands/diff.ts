import pc from "picocolors";
import { register, type CommandContext } from "./registry.js";
import { getDiff, ApiError } from "../lib/api.js";

function colorizeDiff(raw: string): string {
  return raw
    .split("\n")
    .map((line) => {
      if (line.startsWith("+++") || line.startsWith("---")) {
        return pc.bold(line);
      }
      if (line.startsWith("@@")) {
        return pc.cyan(line);
      }
      if (line.startsWith("+")) {
        return pc.green(line);
      }
      if (line.startsWith("-")) {
        return pc.red(line);
      }
      if (line.startsWith("diff ")) {
        return pc.bold(pc.yellow(line));
      }
      if (line.startsWith("index ")) {
        return pc.dim(line);
      }
      return line;
    })
    .join("\n");
}

function parseDiffStats(raw: string): {
  files: number;
  additions: number;
  deletions: number;
} {
  let files = 0;
  let additions = 0;
  let deletions = 0;

  for (const line of raw.split("\n")) {
    if (line.startsWith("diff ")) files++;
    else if (line.startsWith("+") && !line.startsWith("+++")) additions++;
    else if (line.startsWith("-") && !line.startsWith("---")) deletions++;
  }

  return { files, additions, deletions };
}

function formatStats(stats: { files: number; additions: number; deletions: number }): string {
  const parts = [
    `${stats.files} file(s)`,
    pc.green(`+${stats.additions}`),
    pc.red(`-${stats.deletions}`),
  ];
  return parts.join("  ");
}

register({
  name: "diff",
  aliases: ["d"],
  description: "Show git diff with syntax highlighting",
  args: "[file] [--staged]",
  handler: async (args: string, ctx: CommandContext) => {
    const parts = args.trim().split(/\s+/).filter(Boolean);

    let file: string | undefined;
    let staged = false;

    for (const part of parts) {
      if (part === "--staged" || part === "-s" || part === "staged") {
        staged = true;
      } else if (!file) {
        file = part;
      }
    }

    try {
      const { diff } = await getDiff({ file, staged });

      // "No differences found." from the git tool
      if (diff.startsWith("No differences")) {
        const label = staged ? "staged" : "unstaged";
        const target = file ? ` for ${pc.cyan(file)}` : "";
        ctx.addSystemMessage(pc.dim(`No ${label} changes${target}.`));
        return;
      }

      const stats = parseDiffStats(diff);
      const header = `${pc.bold("Diff")} ${staged ? pc.yellow("[staged]") : ""} ${formatStats(stats)}`;
      const colored = colorizeDiff(diff);

      ctx.addSystemMessage(`${header}\n\n${colored}`);
    } catch (err) {
      const msg = err instanceof ApiError ? `Diff failed: ${err.body}` : "Diff failed.";
      ctx.addSystemMessage(pc.red(msg));
    }
  },
});

export { colorizeDiff, parseDiffStats };
