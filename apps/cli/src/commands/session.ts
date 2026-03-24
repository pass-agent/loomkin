import pc from "picocolors";
import { register, type CommandContext } from "./registry.js";
import {
  listSessions,
  getSession,
  getSessionMessages,
  createSession,
  updateSession,
  archiveSession,
} from "../lib/api.js";
import { setLastSessionId } from "../lib/config.js";
import { formatTokens } from "../lib/format.js";
import { extractErrorMessage } from "../lib/errors.js";
import type { Session } from "../lib/types.js";

function formatSessionLine(session: Session, isCurrent: boolean): string {
  const marker = isCurrent ? pc.green("▸ ") : "  ";
  const id = pc.dim(session.id.slice(0, 8));
  const title = session.title
    ? pc.bold(session.title)
    : pc.dim("(untitled)");
  const model = pc.cyan(session.model);
  const date = new Date(session.updated_at).toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
  const status =
    session.status === "archived" ? pc.yellow(" [archived]") : "";

  return `${marker}${id}  ${title}  ${model}  ${pc.dim(date)}${status}`;
}

register({
  name: "session",
  aliases: ["s"],
  description: "Manage sessions: list, switch, create, archive, rename, search",
  args: "[list|new|archive|info|rename|search] [args...]",
  handler: async (args: string, ctx: CommandContext) => {
    const parts = args.trim().split(/\s+/);
    const subcommand = parts[0] || "";
    const rest = parts.slice(1).join(" ");

    switch (subcommand) {
      case "":
        // /session — show current
        await handleCurrent(ctx);
        break;

      case "list":
      case "ls":
        await handleList(ctx);
        break;

      case "new":
        await handleNew(ctx);
        break;

      case "archive":
        await handleArchive(ctx, rest);
        break;

      case "info":
        await handleInfo(ctx, rest);
        break;

      case "rename":
        await handleRename(ctx, rest);
        break;

      case "search":
        await handleSearch(ctx, rest);
        break;

      default:
        // /session <id> — switch
        await handleSwitch(ctx, subcommand);
    }
  },
});

async function handleCurrent(ctx: CommandContext) {
  const id = ctx.sessionStore.sessionId;
  if (!id) {
    ctx.addSystemMessage("No active session.");
    return;
  }

  try {
    const { session } = await getSession(id);
    const title = session.title ? pc.bold(session.title) : pc.dim("(untitled)");
    const tokens = formatTokens(session.prompt_tokens + session.completion_tokens);
    ctx.addSystemMessage(
      `${title}  ${pc.dim(id.slice(0, 8))}  ${pc.cyan(session.model)}  ${pc.dim(tokens + " tokens")}`,
    );
  } catch {
    ctx.addSystemMessage(`Current session: ${pc.bold(id)}`);
  }
}

async function handleList(ctx: CommandContext) {
  try {
    const { sessions } = await listSessions();

    if (sessions.length === 0) {
      ctx.addSystemMessage("No sessions found.");
      return;
    }

    const currentId = ctx.sessionStore.sessionId;
    const lines = sessions.map((s) =>
      formatSessionLine(s, s.id === currentId),
    );

    const header = pc.bold("Recent sessions");
    const hint = pc.dim(
      "  /session <id> to switch  /session info <id>  /session search <query>",
    );

    ctx.addSystemMessage(`${header}\n${lines.join("\n")}\n${hint}`);
  } catch (error) {
    const msg = extractErrorMessage(error);
    ctx.addSystemMessage(pc.red(`Failed to list sessions: ${msg}`));
  }
}

async function handleNew(ctx: CommandContext) {
  try {
    const { session } = await createSession({
      project_path: process.cwd(),
    });
    ctx.sessionStore.clearMessages();
    ctx.sessionStore.clearPendingToolCalls();
    ctx.sessionStore.clearPendingPermissions();
    ctx.sessionStore.clearPendingQuestions();
    ctx.sessionStore.setSessionId(session.id);
    setLastSessionId(session.id);
    ctx.addSystemMessage(
      `New session ${pc.bold(session.id.slice(0, 8))} created.`,
    );
  } catch (error) {
    const msg = extractErrorMessage(error);
    ctx.addSystemMessage(pc.red(`Failed to create session: ${msg}`));
  }
}

async function handleArchive(ctx: CommandContext, id?: string) {
  const targetId = id || ctx.sessionStore.sessionId;
  if (!targetId) {
    ctx.addSystemMessage("No active session to archive.");
    return;
  }

  try {
    await archiveSession(targetId);
    ctx.addSystemMessage(`Archived session ${pc.bold(targetId.slice(0, 8))}.`);

    // If archiving the current session, create a fresh one
    if (targetId === ctx.sessionStore.sessionId) {
      const { session } = await createSession({
        project_path: process.cwd(),
      });
      ctx.sessionStore.clearMessages();
      ctx.sessionStore.clearPendingToolCalls();
      ctx.sessionStore.clearPendingPermissions();
      ctx.sessionStore.clearPendingQuestions();
      ctx.sessionStore.setSessionId(session.id);
      setLastSessionId(session.id);
      ctx.addSystemMessage(
        `New session ${pc.bold(session.id.slice(0, 8))} created.`,
      );
    }
  } catch (error) {
    const msg = extractErrorMessage(error);
    ctx.addSystemMessage(pc.red(`Failed to archive session: ${msg}`));
  }
}

async function handleInfo(ctx: CommandContext, id?: string) {
  const targetId = id || ctx.sessionStore.sessionId;
  if (!targetId) {
    ctx.addSystemMessage(pc.red("Usage: /session info [session-id]"));
    return;
  }

  try {
    // Resolve short IDs
    let session: Session;
    try {
      const resp = await getSession(targetId);
      session = resp.session;
    } catch {
      // Try matching short ID from list
      const { sessions } = await listSessions();
      const match = sessions.find(
        (s) => s.id.startsWith(targetId),
      );
      if (!match) {
        ctx.addSystemMessage(pc.red(`Session ${targetId} not found.`));
        return;
      }
      session = match;
    }

    const totalTokens = session.prompt_tokens + session.completion_tokens;
    const isCurrent = session.id === ctx.sessionStore.sessionId;

    const lines = [
      pc.bold(session.title || "(untitled)") + (isCurrent ? pc.green(" ← active") : ""),
      "",
      `${pc.dim("ID:")}         ${session.id}`,
      `${pc.dim("Status:")}     ${session.status}`,
      `${pc.dim("Model:")}      ${session.model}${session.fast_model ? pc.dim(` / ${session.fast_model}`) : ""}`,
      `${pc.dim("Project:")}    ${session.project_path}`,
      `${pc.dim("Tokens:")}     ${formatTokens(totalTokens)} (${pc.dim(`${formatTokens(session.prompt_tokens)} prompt + ${formatTokens(session.completion_tokens)} completion`)})`,
      `${pc.dim("Cost:")}       ${session.cost_usd != null ? `$${session.cost_usd.toFixed(4)}` : pc.dim("$0.00")}`,
      `${pc.dim("Team:")}       ${session.team_id ? session.team_id.slice(0, 8) : pc.dim("none")}`,
      `${pc.dim("Created:")}    ${new Date(session.inserted_at).toLocaleString()}`,
      `${pc.dim("Updated:")}    ${new Date(session.updated_at).toLocaleString()}`,
    ];

    ctx.addSystemMessage(lines.join("\n"));
  } catch (error) {
    const msg = extractErrorMessage(error);
    ctx.addSystemMessage(pc.red(`Failed to get session info: ${msg}`));
  }
}

async function handleRename(ctx: CommandContext, args: string) {
  const parts = args.split(/\s+/);
  let targetId: string | null = null;
  let title: string;

  // Check if first arg looks like a session ID (8+ hex chars or UUID)
  if (parts.length >= 2 && /^[0-9a-f]{8,}$/i.test(parts[0])) {
    targetId = parts[0];
    title = parts.slice(1).join(" ");
  } else {
    targetId = ctx.sessionStore.sessionId;
    title = args;
  }

  if (!targetId) {
    ctx.addSystemMessage(pc.red("No active session. Usage: /session rename <title>"));
    return;
  }

  if (!title) {
    ctx.addSystemMessage(pc.red("Usage: /session rename [session-id] <new title>"));
    return;
  }

  try {
    const { session } = await updateSession(targetId, { title });
    ctx.addSystemMessage(
      `${pc.green("✔")} Session ${pc.dim(session.id.slice(0, 8))} renamed to ${pc.bold(title)}`,
    );
  } catch (error) {
    const msg = extractErrorMessage(error);
    ctx.addSystemMessage(pc.red(`Failed to rename session: ${msg}`));
  }
}

async function handleSearch(ctx: CommandContext, query: string) {
  if (!query) {
    ctx.addSystemMessage(pc.red("Usage: /session search <query>"));
    return;
  }

  try {
    const { sessions } = await listSessions();
    const lower = query.toLowerCase();

    const matches = sessions.filter((s) => {
      const title = (s.title || "").toLowerCase();
      const model = s.model.toLowerCase();
      const id = s.id.toLowerCase();
      const path = (s.project_path || "").toLowerCase();
      return (
        title.includes(lower) ||
        model.includes(lower) ||
        id.startsWith(lower) ||
        path.includes(lower)
      );
    });

    if (matches.length === 0) {
      ctx.addSystemMessage(pc.dim(`No sessions matching "${query}".`));
      return;
    }

    const currentId = ctx.sessionStore.sessionId;
    const lines = matches.map((s) =>
      formatSessionLine(s, s.id === currentId),
    );

    ctx.addSystemMessage(
      `${pc.bold(`Search: "${query}" (${matches.length} results)`)}\n${lines.join("\n")}`,
    );
  } catch (error) {
    const msg = extractErrorMessage(error);
    ctx.addSystemMessage(pc.red(`Search failed: ${msg}`));
  }
}

async function handleSwitch(ctx: CommandContext, requested: string) {
  try {
    ctx.addSystemMessage(
      pc.dim(`Loading session ${requested.slice(0, 8)}…`),
    );

    const { messages } = await getSessionMessages(requested);

    ctx.sessionStore.clearMessages();
    ctx.sessionStore.clearPendingToolCalls();
    ctx.sessionStore.clearPendingPermissions();
    ctx.sessionStore.clearPendingQuestions();
    ctx.sessionStore.setSessionId(requested);
    ctx.sessionStore.loadMessages(messages);
    setLastSessionId(requested);

    ctx.addSystemMessage(
      `Switched to session ${pc.bold(requested.slice(0, 8))} (${messages.length} messages loaded).`,
    );
  } catch (error) {
    const msg = extractErrorMessage(error);
    ctx.addSystemMessage(
      pc.red(`Failed to switch session: ${msg}`),
    );
  }
}
