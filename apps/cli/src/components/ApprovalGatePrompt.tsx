import React, { useState, useEffect } from "react";
import { Box, Text, useInput } from "ink";
import TextInput from "ink-text-input";
import type { ApprovalRequest, SpawnGateRequest } from "../lib/types.js";

type Props =
  | {
      type: "approval";
      gate: ApprovalRequest;
      onRespond: (gateId: string, outcome: "approved" | "denied", context?: string, reason?: string) => void;
    }
  | {
      type: "spawn_gate";
      gate: SpawnGateRequest;
      onRespond: (gateId: string, outcome: "approved" | "denied", reason?: string) => void;
    };

export function ApprovalGatePrompt(props: Props) {
  const [mode, setMode] = useState<"choose" | "context" | "reason">("choose");
  const [text, setText] = useState("");
  const { gate } = props;

  // Live countdown timer
  const [remaining, setRemaining] = useState(() => {
    const elapsed = (Date.now() - gate.received_at) / 1000;
    return Math.max(0, Math.round(gate.timeout_ms / 1000 - elapsed));
  });

  useEffect(() => {
    const interval = setInterval(() => {
      const elapsed = (Date.now() - gate.received_at) / 1000;
      const left = Math.max(0, Math.round(gate.timeout_ms / 1000 - elapsed));
      setRemaining(left);

      // Auto-expire: remove from UI when timeout reaches zero
      if (left <= 0) {
        clearInterval(interval);
      }
    }, 1000);

    return () => clearInterval(interval);
  }, [gate.gate_id, gate.received_at, gate.timeout_ms]);

  useInput(
    (input) => {
      if (mode !== "choose") return;

      if (input === "y") {
        props.onRespond(gate.gate_id, "approved");
      } else if (input === "n") {
        setMode("reason");
      } else if (input === "c" && props.type === "approval") {
        setMode("context");
      }
    },
    { isActive: mode === "choose" },
  );

  const handleTextSubmit = (value: string) => {
    if (mode === "context" && props.type === "approval") {
      props.onRespond(gate.gate_id, "approved", value);
    } else if (mode === "reason") {
      if (props.type === "approval") {
        props.onRespond(gate.gate_id, "denied", undefined, value || "denied by user");
      } else {
        props.onRespond(gate.gate_id, "denied", value || "denied by user");
      }
    }
  };

  const timeColor = remaining <= 10 ? "red" : remaining <= 30 ? "yellow" : "gray";

  return (
    <Box
      borderStyle="round"
      borderColor="magenta"
      paddingX={1}
      flexDirection="column"
    >
      {props.type === "approval" ? (
        <>
          <Text bold color="magenta">
            {props.gate.agent_name} requests approval
          </Text>
          <Text>{props.gate.question}</Text>
        </>
      ) : (
        <>
          <Text bold color="magenta">
            {props.gate.agent_name} wants to spawn agents
          </Text>
          {props.gate.purpose && (
            <Text dimColor>Purpose: {props.gate.purpose}</Text>
          )}
          <Box marginTop={1} flexDirection="column">
            {props.gate.roles.map((r, i) => (
              <Text key={`role-${i}`}>
                {"  "}• {r.name ? `${r.name} (${r.role})` : r.role}
              </Text>
            ))}
          </Box>
          <Text>
            Estimated cost:{" "}
            <Text
              color={
                props.gate.estimated_cost >= 1
                  ? "red"
                  : props.gate.estimated_cost >= 0.1
                    ? "yellow"
                    : "green"
              }
            >
              ${props.gate.estimated_cost.toFixed(4)}
            </Text>
          </Text>
          {props.gate.limit_warning && (
            <Text color="yellow">⚠ {props.gate.limit_warning}</Text>
          )}
        </>
      )}

      <Text color={timeColor}>{remaining}s remaining</Text>

      {mode === "choose" && (
        <Box marginTop={1}>
          <Text>
            <Text bold color="green">[y]</Text> approve{"  "}
            <Text bold color="red">[n]</Text> deny
            {props.type === "approval" && (
              <>
                {"  "}
                <Text bold color="cyan">[c]</Text> approve with context
              </>
            )}
          </Text>
        </Box>
      )}

      {(mode === "context" || mode === "reason") && (
        <Box marginTop={1} flexDirection="column">
          <Text dimColor>
            {mode === "context" ? "Add context:" : "Reason for denial:"}
          </Text>
          <Box>
            <Text dimColor>{"› "}</Text>
            <TextInput
              value={text}
              onChange={setText}
              onSubmit={handleTextSubmit}
              placeholder={mode === "context" ? "Optional context..." : "Reason..."}
            />
          </Box>
        </Box>
      )}
    </Box>
  );
}
