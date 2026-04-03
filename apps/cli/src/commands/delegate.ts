import { register } from "./registry.js";
import { useAgentStore } from "../stores/agentStore.js";
import { useChannelStore } from "../stores/channelStore.js";

register({
  name: "delegate",
  description: "Delegate a task to a named agent",
  args: "<agent-name> <task>",
  getArgCompletions: (partial: string) => {
    // Only complete the first argument (agent name).
    // If partial contains a space, the user is typing the task — no completions.
    if (partial.includes(" ")) return [];
    return useAgentStore
      .getState()
      .getAgentList()
      .map((a) => a.name)
      .filter((name) => name.startsWith(partial));
  },
  handler: (_args, ctx) => {
    const parts = _args.trim().split(" ");
    const agentName = parts[0];
    const task = parts.slice(1).join(" ");

    if (!agentName || !task) {
      ctx.addSystemMessage("Usage: /delegate <agent-name> <task>");
      return;
    }

    const agents = useAgentStore.getState().getAgentList();
    if (!agents.find((a) => a.name === agentName)) {
      ctx.addSystemMessage(
        `Agent "${agentName}" not found. Active agents: ${agents.map((a) => a.name).join(", ")}`,
      );
      return;
    }

    const channel = useChannelStore.getState().channel;
    if (!channel) {
      ctx.addSystemMessage("Not connected to server. Cannot delegate.");
      return;
    }

    channel
      .push("peer_message", {
        to: agentName,
        content: task,
        from: "user",
      })
      .receive("ok", () => {
        ctx.addSystemMessage(`Task delegated to ${agentName}`);
      })
      .receive("error", (resp: Record<string, unknown>) => {
        ctx.addSystemMessage(`Failed to delegate: ${JSON.stringify(resp)}`);
      });
  },
});
