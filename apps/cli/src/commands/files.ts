import pc from "picocolors";
import { register, type CommandContext } from "./registry.js";
import { listFiles, readFile, searchFiles, grepFiles, ApiError } from "../lib/api.js";
import type { FileEntry, GrepMatch } from "../lib/types.js";

function formatEntry(entry: FileEntry): string {
  const icon = entry.is_dir ? pc.blue("📁") : "  ";
  const name = entry.is_dir ? pc.bold(pc.blue(entry.name + "/")) : pc.cyan(entry.name);
  const size = pc.dim(entry.size.padStart(8));
  const modified = pc.dim(entry.modified);
  return `${icon} ${name}  ${size}  ${modified}`;
}

function formatGrepMatch(match: GrepMatch): string {
  return `  ${pc.cyan(match.file)}${pc.dim(`:${match.line}:`)} ${match.content}`;
}

async function showDirectory(path: string, ctx: CommandContext) {
  const { path: dir, entries } = await listFiles(path);

  if (entries.length === 0) {
    ctx.addSystemMessage(`${pc.dim(dir + "/")} is empty.`);
    return;
  }

  // Sort: dirs first, then files
  const sorted = [...entries].sort((a, b) => {
    if (a.is_dir !== b.is_dir) return a.is_dir ? -1 : 1;
    return a.name.localeCompare(b.name);
  });

  const lines = [
    pc.bold(`${dir}/ `) + pc.dim(`(${entries.length} entries)`),
    "",
    ...sorted.map(formatEntry),
  ];

  ctx.addSystemMessage(lines.join("\n"));
}

async function showFileContent(
  path: string,
  opts: { offset?: number; limit?: number },
  ctx: CommandContext,
) {
  const { content } = await readFile(path, opts);
  ctx.addSystemMessage(content);
}

async function showSearchResults(pattern: string, path: string | undefined, ctx: CommandContext) {
  const { files } = await searchFiles(pattern, path);

  if (files.length === 0) {
    ctx.addSystemMessage(pc.dim(`No files matched: ${pattern}`));
    return;
  }

  const lines = [
    pc.bold(`Found ${files.length} file(s)`),
    "",
    ...files.slice(0, 50).map((f) => `  ${pc.cyan(f)}`),
  ];

  if (files.length > 50) {
    lines.push(pc.dim(`  ... and ${files.length - 50} more`));
  }

  ctx.addSystemMessage(lines.join("\n"));
}

async function showGrepResults(
  pattern: string,
  opts: { path?: string; glob?: string },
  ctx: CommandContext,
) {
  const { matches } = await grepFiles(pattern, opts);

  if (matches.length === 0) {
    ctx.addSystemMessage(pc.dim(`No matches for: ${pattern}`));
    return;
  }

  const lines = [pc.bold(`${matches.length} match(es)`), "", ...matches.map(formatGrepMatch)];

  ctx.addSystemMessage(lines.join("\n"));
}

register({
  name: "files",
  aliases: ["f", "ls"],
  description: "Browse files, search, and read",
  args: "[path|search <glob>|read <file>|grep <pattern>]",
  handler: async (args: string, ctx: CommandContext) => {
    const parts = args.trim().split(/\s+/);
    const subcommand = parts[0]?.toLowerCase() ?? "";

    try {
      switch (subcommand) {
        case "": {
          await showDirectory(".", ctx);
          break;
        }

        case "search":
        case "find": {
          const pattern = parts[1];
          if (!pattern) {
            ctx.addSystemMessage(
              `Usage: ${pc.cyan("/files search <glob>")} (e.g. /files search **/*.ts)`,
            );
            return;
          }
          const searchPath = parts[2];
          await showSearchResults(pattern, searchPath, ctx);
          break;
        }

        case "read":
        case "cat": {
          const filePath = parts[1];
          if (!filePath) {
            ctx.addSystemMessage(`Usage: ${pc.cyan("/files read <path>")} [offset] [limit]`);
            return;
          }
          const offset = parts[2] ? parseInt(parts[2], 10) : undefined;
          const limit = parts[3] ? parseInt(parts[3], 10) : undefined;
          await showFileContent(filePath, { offset, limit }, ctx);
          break;
        }

        case "grep": {
          const pattern = parts[1];
          if (!pattern) {
            ctx.addSystemMessage(`Usage: ${pc.cyan("/files grep <regex>")} [glob]`);
            return;
          }
          const glob = parts[2];
          await showGrepResults(pattern, { glob }, ctx);
          break;
        }

        default: {
          // Treat as a directory path
          await showDirectory(subcommand, ctx);
          break;
        }
      }
    } catch (err) {
      const msg =
        err instanceof ApiError
          ? err.isNotFound
            ? `Not found: ${parts[1] || subcommand}`
            : `Error: ${err.body}`
          : "File operation failed.";
      ctx.addSystemMessage(pc.red(msg));
    }
  },
});
