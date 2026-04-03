import { spawnSync } from "child_process";

const GIT_TIMEOUT_MS = 500;

function runGit(args: string[], cwd: string): string | null {
  try {
    const result = spawnSync("git", args, {
      cwd,
      encoding: "utf-8",
      timeout: GIT_TIMEOUT_MS,
      stdio: ["ignore", "pipe", "ignore"],
    });
    if (result.status === 0 && result.stdout) {
      return result.stdout.trim();
    }
    return null;
  } catch {
    return null;
  }
}

/**
 * Checks if cwd is in a git repo and gathers context.
 * Returns a formatted string or null if not a git repo or git is unavailable.
 * Total timeout budget: 500ms.
 */
export function getGitContext(cwd: string): string | null {
  const start = Date.now();

  // Check if we are inside a git repo
  const gitDir = runGit(["rev-parse", "--git-dir"], cwd);
  if (!gitDir) return null;

  const lines: string[] = ["Git context:"];

  const elapsed = () => Date.now() - start;

  // Branch
  if (elapsed() < GIT_TIMEOUT_MS) {
    const branch = runGit(["branch", "--show-current"], cwd);
    if (branch) lines.push(`Branch: ${branch}`);
  }

  // Status
  if (elapsed() < GIT_TIMEOUT_MS) {
    const status = runGit(["status", "--short"], cwd);
    if (status) {
      lines.push("Status:");
      for (const line of status.split("\n")) {
        if (line.trim()) lines.push(`  ${line}`);
      }
    }
  }

  // Recent commits
  if (elapsed() < GIT_TIMEOUT_MS) {
    const log = runGit(["log", "--oneline", "-10"], cwd);
    if (log) {
      lines.push("Recent commits:");
      for (const line of log.split("\n")) {
        if (line.trim()) lines.push(`  ${line}`);
      }
    }
  }

  if (lines.length === 1) return null; // only header, nothing useful
  return lines.join("\n");
}

/**
 * Extract the current branch name from cwd git repo.
 * Returns null if not in a git repo.
 */
export function getGitBranch(cwd: string): string | null {
  return runGit(["branch", "--show-current"], cwd);
}
