import pc from "picocolors";
import { register, type CommandContext } from "./registry.js";
import { useConversationStore } from "../stores/conversationStore.js";
import { usePaneStore } from "../stores/paneStore.js";

register({
  name: "conversations",
  aliases: ["convos", "conv"],
  description: "List and view ongoing kin conversations",
  args: "[list | view <id> | focus <id>]",
  handler: async (args: string, ctx: CommandContext) => {
    const store = useConversationStore.getState();
    const conversations = store.getList();
    const parts = args.trim().split(/\s+/);
    const subcommand = parts[0] || "list";

    if (subcommand === "list" || subcommand === "") {
      if (conversations.length === 0) {
        ctx.addSystemMessage("No conversations yet.");
        return;
      }

      const lines = conversations.map((c) => {
        const statusColor =
          c.status === "active"
            ? pc.green
            : c.status === "summarizing"
              ? pc.yellow
              : c.status === "completed"
                ? pc.cyan
                : pc.red;

        const active =
          c.conversation_id === store.activeConversationId ? pc.bold("* ") : "  ";
        const id = pc.dim(c.conversation_id.slice(0, 8));
        const topic = pc.bold(c.topic);
        const status = statusColor(`[${c.status}]`);
        const round = pc.dim(`R${c.current_round}`);
        const participants = pc.dim(c.participants.join(", "));

        return `${active}${id} ${topic} ${status} ${round}\n    ${participants}`;
      });

      ctx.addSystemMessage(lines.join("\n"));
      return;
    }

    if (subcommand === "view") {
      const targetId = parts[1];
      if (!targetId) {
        ctx.addSystemMessage(pc.red("Usage: /conversations view <id-prefix>"));
        return;
      }

      const conv = conversations.find((c) =>
        c.conversation_id.startsWith(targetId),
      );
      if (!conv) {
        ctx.addSystemMessage(pc.red(`No conversation matching "${targetId}"`));
        return;
      }

      const header = `${pc.bold(pc.magenta(conv.topic))} ${pc.dim(`[${conv.status}]`)} R${conv.current_round}\n${pc.dim(conv.participants.join(", "))}`;

      const turnLines = conv.turns.map((t) => {
        if (t.type === "reaction") {
          return pc.dim(`  [${t.reaction_type}] ${t.speaker}: ${t.content}`);
        }
        if (t.type === "yield") {
          return pc.dim(
            `  ${t.speaker} yields${t.reason ? `: ${t.reason}` : ""}`,
          );
        }
        return `${pc.bold(pc.magenta(t.speaker))}: ${t.content}`;
      });

      const summaryLines: string[] = [];
      if (conv.summary) {
        summaryLines.push("", pc.bold(pc.cyan("Summary:")));
        for (const kp of conv.summary.key_points ?? []) {
          summaryLines.push(`  - ${kp}`);
        }
        if (conv.summary.consensus?.length) {
          summaryLines.push(pc.bold(pc.green("Consensus:")));
          for (const c of conv.summary.consensus) {
            summaryLines.push(`  - ${c}`);
          }
        }
      }

      ctx.addSystemMessage(
        [header, "", ...turnLines, ...summaryLines].join("\n"),
      );
      return;
    }

    if (subcommand === "focus") {
      const targetId = parts[1];

      if (!targetId || targetId === "off") {
        store.setActiveConversation(null);
        ctx.addSystemMessage("Conversation focus cleared.");
        return;
      }

      const conv = conversations.find((c) =>
        c.conversation_id.startsWith(targetId),
      );
      if (!conv) {
        ctx.addSystemMessage(pc.red(`No conversation matching "${targetId}"`));
        return;
      }

      store.setActiveConversation(conv.conversation_id);
      // Auto-open split pane if not already open
      const pane = usePaneStore.getState();
      if (!pane.splitMode) {
        pane.toggleSplitMode();
      }
      ctx.addSystemMessage(
        `Focused on: ${pc.bold(pc.magenta(conv.topic))} — showing in right pane`,
      );
      return;
    }

    ctx.addSystemMessage(
      `Usage: /conversations [list | view <id> | focus <id|off>]`,
    );
  },
});
