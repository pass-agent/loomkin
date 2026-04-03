import pc from "picocolors";
import { register, type CommandContext } from "./registry.js";
import { formatTokens, formatCost } from "../lib/format.js";
import {
  getMe,
  getSession,
  listModelProviders,
  listSessions,
  ApiError,
} from "../lib/api.js";
import { getApiBaseUrl } from "../lib/urls.js";
import type { ModelProvider, Session } from "../lib/types.js";

function connectionDot(state: string): string {
  switch (state) {
    case "connected":
      return pc.green("●");
    case "connecting":
    case "reconnecting":
      return pc.yellow("●");
    default:
      return pc.red("●");
  }
}

function providerStatus(provider: ModelProvider): string {
  const { status } = provider;
  if (status.status === "set" || status.status === "available") {
    return pc.green("✓");
  }
  if (status.status === "missing" || status.status === "offline") {
    return pc.red("✗");
  }
  return pc.yellow("?");
}


function formatSession(session: Session): string {
  const title = session.title ?? pc.dim("(untitled)");
  const tokens = formatTokens(session.prompt_tokens + session.completion_tokens);
  const cost = formatCost(session.cost_usd);
  return `  ${pc.cyan(session.id.slice(0, 8))} ${title} ${pc.dim(`${tokens} tokens`)} ${cost}`;
}

async function fetchStatus(ctx: CommandContext) {
  const lines: string[] = [pc.bold("Loomkin Status"), ""];

  // Connection
  const { connectionState, serverUrl, mode, model, reconnectAttempts } =
    ctx.appStore;
  lines.push(pc.bold(pc.underline("Connection")));
  lines.push(
    `  ${connectionDot(connectionState)} ${connectionState} → ${pc.dim(serverUrl)}`,
  );
  if (connectionState === "reconnecting") {
    lines.push(`  ${pc.dim(`Attempt ${reconnectAttempts}`)}`);
  }
  lines.push(`  ${pc.dim("Mode:")}  ${mode}`);
  lines.push(`  ${pc.dim("Model:")} ${model}`);
  lines.push("");

  // User
  try {
    const { user } = await getMe();
    lines.push(pc.bold(pc.underline("User")));
    lines.push(`  ${user.email}`);
    lines.push("");
  } catch {
    lines.push(pc.bold(pc.underline("User")));
    lines.push(`  ${pc.red("Unable to fetch user info")}`);
    lines.push("");
  }

  // Current session
  const { sessionId } = ctx.sessionStore;
  lines.push(pc.bold(pc.underline("Session")));
  if (sessionId) {
    try {
      const { session } = await getSession(sessionId);
      lines.push(formatSession(session));
    } catch {
      lines.push(`  ${pc.cyan(sessionId.slice(0, 8))} ${pc.dim("(details unavailable)")}`);
    }
  } else {
    lines.push(`  ${pc.dim("No active session")}`);
  }
  lines.push("");

  // Model providers
  try {
    const { providers } = await listModelProviders();
    lines.push(pc.bold(pc.underline("Providers")));
    for (const p of providers) {
      const modelCount = pc.dim(`(${p.models.length} models)`);
      lines.push(`  ${providerStatus(p)} ${p.name} ${modelCount}`);
    }
    lines.push("");
  } catch {
    lines.push(pc.bold(pc.underline("Providers")));
    lines.push(`  ${pc.red("Unable to fetch providers")}`);
    lines.push("");
  }

  // Recent sessions
  try {
    const { sessions } = await listSessions();
    const recent = sessions.slice(0, 5);
    if (recent.length > 0) {
      lines.push(pc.bold(pc.underline("Recent Sessions")));
      for (const s of recent) {
        const active = s.id === sessionId ? pc.green(" ← active") : "";
        lines.push(`${formatSession(s)}${active}`);
      }
      lines.push("");
    }
  } catch {
    // Skip recent sessions on error
  }

  // Errors
  const { errors } = ctx.appStore;
  if (errors.length > 0) {
    lines.push(pc.bold(pc.underline("Errors")));
    for (const err of errors) {
      lines.push(
        `  ${pc.red("●")} ${pc.dim(`[${err.type}]`)} ${err.message}`,
      );
    }
    lines.push("");
  }

  lines.push(pc.dim(`Server: ${getApiBaseUrl()}`));
  ctx.addSystemMessage(lines.join("\n"));
}

register({
  name: "status",
  aliases: ["st"],
  description: "Show server health, connection, and session info",
  args: "",
  handler: async (_args: string, ctx: CommandContext) => {
    try {
      await fetchStatus(ctx);
    } catch (err) {
      const msg =
        err instanceof ApiError
          ? `Status check failed: ${err.body}`
          : "Status check failed.";
      ctx.addSystemMessage(pc.red(msg));
    }
  },
});
