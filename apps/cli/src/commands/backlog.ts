import pc from "picocolors";
import { register, type CommandContext } from "./registry.js";
import { extractErrorMessage } from "../lib/errors.js";
import {
  listBacklogItems,
  createBacklogItem,
  updateBacklogItem,
} from "../lib/api.js";
import type { BacklogItem } from "../lib/types.js";

const STATUS_ICONS: Record<string, string> = {
  todo: pc.white("○"),
  in_progress: pc.blue("◉"),
  done: pc.green("✔"),
  blocked: pc.red("✖"),
  cancelled: pc.dim("⊘"),
  icebox: pc.dim("❄"),
};

const PRIORITY_LABELS: Record<number, string> = {
  1: pc.red("P1"),
  2: pc.yellow("P2"),
  3: pc.white("P3"),
  4: pc.dim("P4"),
  5: pc.dim("P5"),
};

function formatItem(item: BacklogItem): string {
  const icon = STATUS_ICONS[item.status] || "○";
  const priority = PRIORITY_LABELS[item.priority] || pc.dim(`P${item.priority}`);
  const id = pc.dim(item.id.slice(0, 8));
  const title = item.status === "done" ? pc.strikethrough(item.title) : item.title;
  const assignee = item.assigned_to ? pc.cyan(` @${item.assigned_to}`) : "";
  const tags = item.tags?.length ? pc.dim(` [${item.tags.join(", ")}]`) : "";

  return `  ${icon} ${priority} ${id} ${title}${assignee}${tags}`;
}

register({
  name: "backlog",
  aliases: ["bl", "tasks"],
  description: "Manage backlog items",
  args: "[list|add|start|done|block|show] [args...]",
  handler: async (args: string, ctx: CommandContext) => {
    const parts = args.trim().split(/\s+/);
    const subcommand = parts[0] || "list";
    const rest = parts.slice(1).join(" ");

    switch (subcommand) {
      case "list":
      case "ls": {
        const status = rest || undefined;
        await handleList(ctx, status);
        break;
      }

      case "add":
      case "create": {
        if (!rest) {
          ctx.addSystemMessage(pc.red("Usage: /backlog add <title>"));
          return;
        }
        await handleCreate(ctx, rest);
        break;
      }

      case "start": {
        if (!rest) {
          ctx.addSystemMessage(pc.red("Usage: /backlog start <id>"));
          return;
        }
        await handleTransition(ctx, rest, "in_progress", "Started");
        break;
      }

      case "done":
      case "complete": {
        if (!rest) {
          ctx.addSystemMessage(pc.red("Usage: /backlog done <id>"));
          return;
        }
        await handleTransition(ctx, rest, "done", "Completed");
        break;
      }

      case "block": {
        if (!rest) {
          ctx.addSystemMessage(pc.red("Usage: /backlog block <id>"));
          return;
        }
        await handleTransition(ctx, rest, "blocked", "Blocked");
        break;
      }

      case "show": {
        if (!rest) {
          ctx.addSystemMessage(pc.red("Usage: /backlog show <id>"));
          return;
        }
        await handleShow(ctx, rest);
        break;
      }

      default:
        ctx.addSystemMessage(
          pc.dim(
            "Usage: /backlog [list|add|start|done|block|show]\n" +
              "  list [status]     List items (todo, in_progress, done, blocked, icebox)\n" +
              "  add <title>       Create a new item\n" +
              "  start <id>        Mark as in progress\n" +
              "  done <id>         Mark as complete\n" +
              "  block <id>        Mark as blocked\n" +
              "  show <id>         Show item details",
          ),
        );
    }
  },
});

async function handleList(ctx: CommandContext, status?: string) {
  try {
    const { items } = await listBacklogItems({ status, limit: 20 });

    if (items.length === 0) {
      ctx.addSystemMessage(
        pc.dim(
          status
            ? `No ${status} items found.`
            : "Backlog is empty. Create items with /backlog add <title>",
        ),
      );
      return;
    }

    const label = status || "actionable";
    const header = pc.bold(`Backlog — ${label} (${items.length})`);
    const lines = items.map(formatItem);
    ctx.addSystemMessage(`${header}\n${lines.join("\n")}`);
  } catch (error) {
    const msg = extractErrorMessage(error);
    ctx.addSystemMessage(pc.red(`Failed to list backlog: ${msg}`));
  }
}

async function handleCreate(ctx: CommandContext, title: string) {
  try {
    const { item } = await createBacklogItem({ title });
    ctx.addSystemMessage(
      `${pc.green("✔")} Created: ${pc.dim(item.id.slice(0, 8))} ${item.title}`,
    );
  } catch (error) {
    const msg = extractErrorMessage(error);
    ctx.addSystemMessage(pc.red(`Failed to create item: ${msg}`));
  }
}

async function handleTransition(
  ctx: CommandContext,
  id: string,
  status: string,
  label: string,
) {
  try {
    const { item } = await updateBacklogItem(id, { status } as Partial<BacklogItem>);
    ctx.addSystemMessage(
      `${pc.green("✔")} ${label}: ${pc.dim(item.id.slice(0, 8))} ${item.title}`,
    );
  } catch (error) {
    const msg = extractErrorMessage(error);
    ctx.addSystemMessage(pc.red(`Failed to update item: ${msg}`));
  }
}

async function handleShow(ctx: CommandContext, id: string) {
  try {
    const { items } = await listBacklogItems({ limit: 50 });
    const item = items.find(
      (i) => i.id === id || i.id.startsWith(id),
    );

    if (!item) {
      ctx.addSystemMessage(pc.red(`Item ${id} not found.`));
      return;
    }

    const lines = [
      `${pc.bold(item.title)}`,
      `${pc.dim("ID:")} ${item.id}`,
      `${pc.dim("Status:")} ${item.status}  ${pc.dim("Priority:")} ${PRIORITY_LABELS[item.priority] || item.priority}`,
    ];

    if (item.description) {
      lines.push(`${pc.dim("Description:")} ${item.description}`);
    }
    if (item.assigned_to) {
      lines.push(`${pc.dim("Assigned:")} ${item.assigned_to}`);
    }
    if (item.assigned_team) {
      lines.push(`${pc.dim("Team:")} ${item.assigned_team}`);
    }
    if (item.category) {
      lines.push(`${pc.dim("Category:")} ${item.category}`);
    }
    if (item.epic) {
      lines.push(`${pc.dim("Epic:")} ${item.epic}`);
    }
    if (item.tags?.length) {
      lines.push(`${pc.dim("Tags:")} ${item.tags.join(", ")}`);
    }
    if (item.acceptance_criteria?.length) {
      lines.push(
        `${pc.dim("Acceptance criteria:")}`,
        ...item.acceptance_criteria.map((c) => `  • ${c}`),
      );
    }
    if (item.scope_estimate) {
      lines.push(`${pc.dim("Scope:")} ${item.scope_estimate}`);
    }
    if (item.result) {
      lines.push(`${pc.dim("Result:")} ${item.result}`);
    }

    ctx.addSystemMessage(lines.join("\n"));
  } catch (error) {
    const msg = extractErrorMessage(error);
    ctx.addSystemMessage(pc.red(`Failed to show item: ${msg}`));
  }
}
