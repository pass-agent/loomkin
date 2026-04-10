import pc from "picocolors";
import { register, type CommandContext } from "./registry.js";
import { useSessionStore } from "../stores/sessionStore.js";
import {
  listTemplates,
  getTemplate,
  saveTemplate,
  deleteTemplate,
  renderTemplate,
} from "../lib/prompts.js";

register({
  name: "prompt",
  aliases: ["p"],
  description: "Manage and use prompt templates",
  args: "[list|save|load|show|delete|edit] [args...]",
  handler: (args: string, ctx: CommandContext) => {
    const parts = args.trim().split(/\s+/);
    const subcommand = parts[0] || "list";
    const rest = parts.slice(1);

    switch (subcommand) {
      case "list":
      case "ls":
        handleList(ctx);
        break;

      case "save": {
        const name = rest[0];
        if (!name) {
          ctx.addSystemMessage(
            pc.red("Usage: /prompt save <name> [description]\n") +
              pc.dim("Saves your last message as a template. Use {{var}} for placeholders."),
          );
          return;
        }
        handleSave(ctx, name, rest.slice(1).join(" "));
        break;
      }

      case "load":
      case "use": {
        const name = rest[0];
        if (!name) {
          ctx.addSystemMessage(pc.red("Usage: /prompt load <name> [var=value ...]"));
          return;
        }
        handleLoad(ctx, name, rest.slice(1));
        break;
      }

      case "show": {
        const name = rest[0];
        if (!name) {
          ctx.addSystemMessage(pc.red("Usage: /prompt show <name>"));
          return;
        }
        handleShow(ctx, name);
        break;
      }

      case "delete":
      case "rm": {
        const name = rest[0];
        if (!name) {
          ctx.addSystemMessage(pc.red("Usage: /prompt delete <name>"));
          return;
        }
        handleDelete(ctx, name);
        break;
      }

      case "edit": {
        const name = rest[0];
        const content = rest.slice(1).join(" ");
        if (!name || !content) {
          ctx.addSystemMessage(pc.red("Usage: /prompt edit <name> <new content>"));
          return;
        }
        handleEdit(ctx, name, content);
        break;
      }

      default:
        // If the subcommand matches a template name, treat as /prompt load <name>
        const template = getTemplate(subcommand);
        if (template) {
          handleLoad(ctx, subcommand, rest);
        } else {
          ctx.addSystemMessage(
            pc.dim(
              "Usage: /prompt [list|save|load|show|delete|edit]\n" +
                "  list                     List saved templates\n" +
                "  save <name> [desc]       Save last message as template\n" +
                "  load <name> [var=val]    Load and send a template\n" +
                "  show <name>              Preview a template\n" +
                "  delete <name>            Delete a template\n" +
                "  edit <name> <content>    Update template content\n" +
                "  <name> [var=val]         Shorthand for load\n\n" +
                "Templates support {{variable}} placeholders:\n" +
                '  /prompt save review "Code review template"\n' +
                "  Then edit ~/.loomkin/prompts/review.json\n" +
                "  /prompt load review lang=typescript file=app.ts",
            ),
          );
        }
    }
  },
});

function handleList(ctx: CommandContext) {
  const templates = listTemplates();

  if (templates.length === 0) {
    ctx.addSystemMessage(
      pc.dim("No prompt templates saved yet.\n") + pc.dim("Save one with: /prompt save <name>"),
    );
    return;
  }

  const lines = templates.map((t) => {
    const vars = t.variables.length
      ? pc.dim(` (${t.variables.map((v) => `{{${v}}}`).join(", ")})`)
      : "";
    const desc = t.description ? `  ${pc.dim(t.description)}` : "";
    return `  ${pc.bold(t.name)}${vars}${desc}`;
  });

  ctx.addSystemMessage(`${pc.bold(`Prompt templates (${templates.length})`)}\n${lines.join("\n")}`);
}

function handleSave(ctx: CommandContext, name: string, description: string) {
  // Find the last user message in the session
  const messages = ctx.sessionStore.messages;
  const lastUserMsg = [...messages].reverse().find((m) => m.role === "user");

  if (!lastUserMsg?.content) {
    ctx.addSystemMessage(pc.red("No user message found to save as template."));
    return;
  }

  const template = saveTemplate(name, lastUserMsg.content, description);
  const vars = template.variables.length
    ? pc.dim(` with variables: ${template.variables.map((v) => `{{${v}}}`).join(", ")}`)
    : "";

  ctx.addSystemMessage(
    `${pc.green("✔")} Saved template ${pc.bold(name)}${vars}\n` +
      pc.dim(`  ~/.loomkin/prompts/${name}.json`),
  );
}

function handleLoad(ctx: CommandContext, name: string, varArgs: string[]) {
  const template = getTemplate(name);
  if (!template) {
    ctx.addSystemMessage(
      pc.red(`Template "${name}" not found. Use /prompt list to see available templates.`),
    );
    return;
  }

  // Parse var=value pairs
  const vars: Record<string, string> = {};
  for (const arg of varArgs) {
    const eq = arg.indexOf("=");
    if (eq > 0) {
      vars[arg.slice(0, eq)] = arg.slice(eq + 1);
    }
  }

  // Check for missing variables
  const missing = template.variables.filter((v) => !(v in vars));
  if (missing.length > 0) {
    ctx.addSystemMessage(
      pc.yellow(`Missing variables: ${missing.map((v) => `{{${v}}}`).join(", ")}\n`) +
        pc.dim(`Provide them: /prompt load ${name} ${missing.map((v) => `${v}=...`).join(" ")}`),
    );
    return;
  }

  const content = renderTemplate(template.content, vars);

  // Show what we're sending
  const preview = content.length > 100 ? content.slice(0, 100) + "…" : content;
  ctx.addSystemMessage(pc.dim(`Sending template "${name}": ${preview}`));

  // Add locally and send to server
  const msg = {
    id: `user-prompt-${Date.now()}`,
    role: "user" as const,
    content,
    tool_calls: null,
    tool_call_id: null,
    token_count: null,
    agent_name: null,
    inserted_at: new Date().toISOString(),
  };
  useSessionStore.getState().addMessage(msg);
  ctx.sendMessage(content);
}

function handleShow(ctx: CommandContext, name: string) {
  const template = getTemplate(name);
  if (!template) {
    ctx.addSystemMessage(pc.red(`Template "${name}" not found.`));
    return;
  }

  const lines = [
    pc.bold(template.name),
    template.description ? pc.dim(template.description) : "",
    "",
    template.content,
    "",
    template.variables.length
      ? pc.dim(`Variables: ${template.variables.map((v) => `{{${v}}}`).join(", ")}`)
      : pc.dim("No variables"),
    pc.dim(`Created: ${new Date(template.createdAt).toLocaleString()}`),
    pc.dim(`Updated: ${new Date(template.updatedAt).toLocaleString()}`),
  ].filter(Boolean);

  ctx.addSystemMessage(lines.join("\n"));
}

function handleDelete(ctx: CommandContext, name: string) {
  if (deleteTemplate(name)) {
    ctx.addSystemMessage(`${pc.green("✔")} Deleted template ${pc.bold(name)}`);
  } else {
    ctx.addSystemMessage(pc.red(`Template "${name}" not found.`));
  }
}

function handleEdit(ctx: CommandContext, name: string, content: string) {
  const existing = getTemplate(name);
  if (!existing) {
    ctx.addSystemMessage(pc.red(`Template "${name}" not found. Use /prompt save to create it.`));
    return;
  }

  const template = saveTemplate(name, content, existing.description);
  const vars = template.variables.length
    ? pc.dim(` with variables: ${template.variables.map((v) => `{{${v}}}`).join(", ")}`)
    : "";

  ctx.addSystemMessage(`${pc.green("✔")} Updated template ${pc.bold(name)}${vars}`);
}
