import { register } from "./registry.js";
import { useAgentStore } from "../stores/agentStore.js";
import { useChannelStore } from "../stores/channelStore.js";

register({
  name: "delegate",
  description: "Delegate a task to a named agent",
  args: "<agent-name> <task>",
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

    useChannelStore.getState().channel?.push("peer_message", {
      to: agentName,
      content: task,
      from: "user",
    });
    ctx.addSystemMessage(`Task delegated to ${agentName}`);
  },
});
