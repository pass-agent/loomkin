import React, { useState, useEffect } from "react";
import { Box, Text, useInput } from "ink";
import TextInput from "ink-text-input";
import type { PlanMessage } from "../lib/types.js";

interface Props {
  plan: PlanMessage;
  onRespond: (planId: string, outcome: "approved" | "rejected", reason?: string) => void;
}

export function PlanApprovalPrompt({ plan, onRespond }: Props) {
  const [mode, setMode] = useState<"choose" | "reason">("choose");
  const [text, setText] = useState("");

  // Live countdown
  const [remaining, setRemaining] = useState(() => {
    const elapsed = (Date.now() - plan.received_at) / 1000;
    return Math.max(0, Math.round(plan.timeout_ms / 1000 - elapsed));
  });

  useEffect(() => {
    const interval = setInterval(() => {
      const elapsed = (Date.now() - plan.received_at) / 1000;
      const left = Math.max(0, Math.round(plan.timeout_ms / 1000 - elapsed));
      setRemaining(left);
      if (left <= 0) {
        clearInterval(interval);
        // Auto-reject when timer expires so the prompt doesn't become a zombie
        onRespond(plan.plan_id, "rejected", "expired — no response within time limit");
      }
    }, 1000);
    return () => clearInterval(interval);
  }, [plan.plan_id, plan.received_at, plan.timeout_ms, onRespond]);

  useInput(
    (input) => {
      if (mode !== "choose") return;
      if (input === "y") {
        onRespond(plan.plan_id, "approved");
      } else if (input === "n") {
        setMode("reason");
      }
    },
    { isActive: mode === "choose" },
  );

  const handleTextSubmit = (value: string) => {
    onRespond(plan.plan_id, "rejected", value || "rejected by user");
  };

  const timeColor = remaining <= 10 ? "red" : remaining <= 30 ? "yellow" : "gray";

  return (
    <Box borderStyle="round" borderColor="cyan" paddingX={1} flexDirection="column">
      <Text bold color="cyan">
        {plan.agent_name} proposes a plan
      </Text>
      <Box marginTop={1} flexDirection="column">
        {plan.plan.split("\n").map((line, i) => (
          <Text key={i}>{line}</Text>
        ))}
      </Box>
      <Text color={timeColor}>{remaining}s remaining</Text>

      {mode === "choose" && (
        <Box marginTop={1}>
          <Text>
            <Text bold color="green">
              [y]
            </Text>{" "}
            approve{"  "}
            <Text bold color="red">
              [n]
            </Text>{" "}
            reject
          </Text>
        </Box>
      )}

      {mode === "reason" && (
        <Box marginTop={1} flexDirection="column">
          <Text dimColor>Reason for rejection:</Text>
          <Box>
            <Text dimColor>{"› "}</Text>
            <TextInput
              value={text}
              onChange={setText}
              onSubmit={handleTextSubmit}
              placeholder="Reason..."
            />
          </Box>
        </Box>
      )}
    </Box>
  );
}
