import pc from "picocolors";
import { register, type CommandContext } from "./registry.js";
import {
  getMcpStatus,
  refreshMcp,
  addMcpServer,
  removeMcpServer,
  restartMcpServer,
  ApiError,
} from "../lib/api.js";
import type { McpClientInfo, McpServerInfo } from "../lib/types.js";

function statusDot(status: string): string {
  if (status === "connected") return pc.green("●");
  if (status.startsWith("error")) return pc.red("●");
  return pc.yellow("●");
}

function transportLabel(transport: McpClientInfo["transport"]): string {
  if (transport.type === "http") return pc.dim(`http → ${transport.url}`);
  if (transport.type === "stdio") return pc.dim(`stdio → ${transport.command}`);
  return pc.dim(transport.type);
}

function showOverview(server: McpServerInfo, clients: McpClientInfo[], ctx: CommandContext): void {
  const lines: string[] = [pc.bold("MCP"), ""];

  lines.push(pc.bold(pc.underline("Server")));
  if (server.enabled) {
    lines.push(`  ${pc.green("●")} enabled ${pc.dim(`(${server.tools.length} tools exposed)`)}`);
  } else {
    lines.push(`  ${pc.dim("○")} disabled`);
  }
  lines.push("");

  lines.push(pc.bold(pc.underline("Connected Servers")));
  if (clients.length === 0) {
    lines.push(pc.dim("  No MCP servers connected."));
    lines.push(pc.dim("  Configure in .loomkin.toml:"));
    lines.push(pc.dim("    [mcp]"));
    lines.push(pc.dim("    servers = ["));
    lines.push(pc.dim('      { name = "example", url = "http://localhost:3001/sse" }'));
    lines.push(pc.dim("    ]"));
  } else {
    for (const client of clients) {
      const isDisconnected = client.status !== "connected";
      lines.push(
        `  ${statusDot(client.status)} ${pc.cyan(client.name)} ${pc.dim(`(${client.tool_count} tools)`)}` +
          (isDisconnected ? pc.dim(" [disconnected]") : ""),
      );
      lines.push(`    ${transportLabel(client.transport)}`);
    }
  }
  lines.push("");

  lines.push(
    pc.dim(
      "Usage: /mcp tools, /mcp server, /mcp refresh [name], /mcp add <url>, /mcp remove <name>, /mcp restart <name>",
    ),
  );
  ctx.addSystemMessage(lines.join("\n"));
}

function showTools(server: McpServerInfo, clients: McpClientInfo[], ctx: CommandContext): void {
  const lines: string[] = [pc.bold("MCP Tools"), ""];

  if (server.enabled && server.tools.length > 0) {
    lines.push(pc.bold(pc.underline("Loom Server Tools")));
    for (const tool of server.tools) {
      lines.push(`  ${pc.cyan(tool.name)} ${pc.dim(tool.module)}`);
    }
    lines.push("");
  }

  if (clients.length > 0) {
    lines.push(pc.bold(pc.underline("External Server Tools")));
    for (const client of clients) {
      if (client.tool_count > 0) {
        lines.push(`  ${pc.cyan(client.name)}: ${client.tool_count} tools available`);
      } else {
        lines.push(`  ${pc.cyan(client.name)}: ${pc.dim("no tools discovered")}`);
      }
    }
    lines.push("");
  }

  if (!server.enabled && clients.length === 0) {
    lines.push(pc.dim("No MCP tools available."));
  }

  ctx.addSystemMessage(lines.join("\n"));
}

function showServer(server: McpServerInfo, ctx: CommandContext): void {
  const lines: string[] = [pc.bold("MCP Server"), ""];

  if (!server.enabled) {
    lines.push(`  ${pc.dim("Server is disabled.")}`);
    lines.push(pc.dim("  Enable in .loomkin.toml:"));
    lines.push(pc.dim("    [mcp]"));
    lines.push(pc.dim("    server_enabled = true"));
    ctx.addSystemMessage(lines.join("\n"));
    return;
  }

  lines.push(`  ${pc.green("●")} enabled`);
  lines.push("");
  lines.push(pc.bold(pc.underline("Published Tools")));
  for (const tool of server.tools) {
    lines.push(`  ${pc.cyan(tool.name)}`);
    lines.push(`    ${pc.dim(tool.module)}`);
  }

  ctx.addSystemMessage(lines.join("\n"));
}

register({
  name: "mcp",
  description: "Manage MCP servers and view tools",
  args: "[tools|server|refresh|add|remove|restart [name]] [--name <n>] [--transport http|stdio]",
  handler: async (args: string, ctx: CommandContext) => {
    const parts = args.trim().split(/\s+/);
    const subcommand = parts[0]?.toLowerCase() ?? "";

    if (subcommand === "refresh") {
      const name = parts[1];
      try {
        const result = await refreshMcp(name);
        ctx.addSystemMessage(pc.green(result.message));
      } catch (err) {
        const msg = err instanceof ApiError ? `Refresh failed: ${err.body}` : "Refresh failed.";
        ctx.addSystemMessage(pc.red(msg));
      }
      return;
    }

    if (subcommand === "add") {
      // /mcp add <url> [--name <n>] [--transport http|stdio]
      const url = parts[1];
      if (!url) {
        ctx.addSystemMessage(
          pc.red("Usage: /mcp add <url> [--name <name>] [--transport http|stdio]"),
        );
        return;
      }
      let name: string | undefined;
      let transport: string | undefined;
      for (let i = 2; i < parts.length; i++) {
        if (parts[i] === "--name" && parts[i + 1]) {
          name = parts[++i];
        } else if (parts[i] === "--transport" && parts[i + 1]) {
          transport = parts[++i];
        }
      }
      try {
        const result = await addMcpServer(url, name, transport);
        ctx.addSystemMessage(pc.green(result.message));
      } catch (err) {
        const msg =
          err instanceof ApiError
            ? `Failed to add MCP server: ${err.body}`
            : "Failed to add MCP server.";
        ctx.addSystemMessage(pc.red(msg));
      }
      return;
    }

    if (subcommand === "remove") {
      const name = parts[1];
      if (!name) {
        ctx.addSystemMessage(pc.red("Usage: /mcp remove <name>"));
        return;
      }
      try {
        const result = await removeMcpServer(name);
        ctx.addSystemMessage(pc.green(result.message));
      } catch (err) {
        const msg =
          err instanceof ApiError
            ? `Failed to remove MCP server: ${err.body}`
            : "Failed to remove MCP server.";
        ctx.addSystemMessage(pc.red(msg));
      }
      return;
    }

    if (subcommand === "restart") {
      const name = parts[1];
      if (!name) {
        ctx.addSystemMessage(pc.red("Usage: /mcp restart <name>"));
        return;
      }
      try {
        const result = await restartMcpServer(name);
        ctx.addSystemMessage(pc.green(result.message));
      } catch (err) {
        const msg =
          err instanceof ApiError
            ? `Failed to restart MCP server: ${err.body}`
            : "Failed to restart MCP server.";
        ctx.addSystemMessage(pc.red(msg));
      }
      return;
    }

    let server: McpServerInfo;
    let clients: McpClientInfo[];
    try {
      const status = await getMcpStatus();
      server = status.server;
      clients = status.clients;
    } catch (err) {
      const msg =
        err instanceof ApiError
          ? `Failed to fetch MCP status: ${err.body}`
          : "Failed to fetch MCP status.";
      ctx.addSystemMessage(pc.red(msg));
      return;
    }

    switch (subcommand) {
      case "tools":
        showTools(server, clients, ctx);
        break;
      case "server":
        showServer(server, ctx);
        break;
      default:
        showOverview(server, clients, ctx);
        break;
    }
  },
});
