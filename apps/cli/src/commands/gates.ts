import pc from "picocolors";
import { register, type CommandContext } from "./registry.js";
import { useSessionStore } from "../stores/sessionStore.js";

register({
  name: "gates",
  description: "List pending approval and spawn gates",
  handler: async (_args: string, ctx: CommandContext) => {
    const { pendingApprovals, pendingSpawnGates } = useSessionStore.getState();

    if (pendingApprovals.length === 0 && pendingSpawnGates.length === 0) {
      ctx.addSystemMessage("No pending approval gates.");
      return;
    }

    const lines: string[] = [];

    if (pendingApprovals.length > 0) {
      lines.push(pc.bold("Approval Gates"));
      for (const gate of pendingApprovals) {
        const elapsed = Math.round((Date.now() - gate.received_at) / 1000);
        const remaining = Math.max(0, Math.round(gate.timeout_ms / 1000) - elapsed);
        const id = pc.dim(gate.gate_id.slice(0, 8));
        lines.push(
          `  ${id} ${pc.magenta(gate.agent_name)}: ${gate.question} ${pc.dim(`(${remaining}s remaining)`)}`,
        );
      }
    }

    if (pendingSpawnGates.length > 0) {
      if (lines.length > 0) lines.push("");
      lines.push(pc.bold("Spawn Gates"));
      for (const gate of pendingSpawnGates) {
        const elapsed = Math.round((Date.now() - gate.received_at) / 1000);
        const remaining = Math.max(0, Math.round(gate.timeout_ms / 1000) - elapsed);
        const id = pc.dim(gate.gate_id.slice(0, 8));
        const roles = gate.roles.map((r) => r.role).join(", ");
        const cost = gate.estimated_cost.toFixed(4);
        const costColor = gate.estimated_cost >= 1 ? pc.red : gate.estimated_cost >= 0.1 ? pc.yellow : pc.green;
        lines.push(
          `  ${id} ${pc.magenta(gate.agent_name)}: spawn ${pc.cyan(roles)} ${costColor(`$${cost}`)} ${pc.dim(`(${remaining}s)`)}`,
        );
        if (gate.purpose) {
          lines.push(`    ${pc.dim(gate.purpose)}`);
        }
        if (gate.limit_warning) {
          lines.push(`    ${pc.yellow(`⚠ ${gate.limit_warning}`)}`);
        }
      }
    }

    ctx.addSystemMessage(lines.join("\n"));
  },
});
