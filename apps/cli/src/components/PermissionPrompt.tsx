import React, { useState, useEffect } from "react";
import { Box, Text, useInput } from "ink";
import { useStore } from "zustand";
import { useAppStore } from "../stores/appStore.js";
import type { PermissionRequest } from "../lib/types.js";

interface Props {
  request: PermissionRequest;
  onRespond: (id: string, action: "allow_once" | "allow_always" | "deny") => void;
}

const CATEGORY_COLORS: Record<string, string> = {
  read: "green",
  write: "yellow",
  execute: "red",
  coordination: "cyan",
};

export function PermissionPrompt({ request, onRespond }: Props) {
  const skipPermissions = useStore(useAppStore, (s) => s.skipPermissions);
  const [selected, setSelected] = useState(0);
  const actions = ["allow_once", "allow_always", "deny"] as const;
  const labels = ["Allow once", "Allow always", "Deny"];

  // Auto-approve when --dangerously-skip-permissions is set
  useEffect(() => {
    if (skipPermissions) {
      onRespond(request.id, "allow_once");
    }
  }, [skipPermissions, request.id, onRespond]);

  if (skipPermissions) return null;

  useInput((input, key) => {
    if (key.leftArrow) {
      setSelected((s) => Math.max(0, s - 1));
    } else if (key.rightArrow) {
      setSelected((s) => Math.min(actions.length - 1, s + 1));
    } else if (key.return) {
      onRespond(request.id, actions[selected]);
    } else if (input === "y" || input === "a") {
      onRespond(request.id, "allow_once");
    } else if (input === "A") {
      onRespond(request.id, "allow_always");
    } else if (input === "n" || input === "d") {
      onRespond(request.id, "deny");
    }
  });

  const color = CATEGORY_COLORS[request.category] || "yellow";

  return (
    <Box
      borderStyle="round"
      borderColor={color}
      paddingX={1}
      flexDirection="column"
    >
      <Text bold color={color}>
        Permission required
      </Text>
      <Text>
        {request.agent_name ? (
          <Text dimColor>{request.agent_name} wants to use </Text>
        ) : (
          <Text dimColor>Agent wants to use </Text>
        )}
        <Text bold>{request.tool_name}</Text>
      </Text>
      {request.tool_path && (
        <Text dimColor>  {request.tool_path}</Text>
      )}
      <Box gap={2} marginTop={1}>
        {labels.map((label, i) => (
          <Text
            key={label}
            inverse={i === selected}
            color={i === 2 ? "red" : i === 1 ? "green" : undefined}
          >
            {` ${label} `}
          </Text>
        ))}
        <Text dimColor>[y] once  [A] always  [n] deny</Text>
      </Box>
    </Box>
  );
}
