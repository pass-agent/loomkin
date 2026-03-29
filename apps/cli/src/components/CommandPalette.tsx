import React from "react";
import { Box, Text } from "ink";
import { getCompletions, type SlashCommand } from "../commands/registry.js";

const MAX_VISIBLE = 6;

interface Props {
  input: string;
  selectedIndex: number;
}

export function CommandPalette({ input, selectedIndex }: Props) {
  const stripped = input.replace(/^\//, "");
  const spaceIdx = stripped.indexOf(" ");
  const commandPart = spaceIdx === -1 ? stripped : stripped.slice(0, spaceIdx);
  const hasArgs = spaceIdx !== -1;
  const completions = hasArgs
    ? getCompletions(commandPart).filter((c) => c.name === commandPart || c.aliases?.includes(commandPart))
    : getCompletions(stripped);

  if (completions.length === 0) {
    return (
      <Box borderStyle="single" borderColor="gray" paddingX={1}>
        <Text dimColor>No matching commands</Text>
      </Box>
    );
  }

  // Keep the selected item within a MAX_VISIBLE window
  const windowStart = Math.min(
    Math.max(0, selectedIndex - MAX_VISIBLE + 1),
    Math.max(0, completions.length - MAX_VISIBLE),
  );
  const windowEnd = Math.min(windowStart + MAX_VISIBLE, completions.length);
  const visible = completions.slice(windowStart, windowEnd);

  return (
    <Box
      flexDirection="column"
      borderStyle="single"
      borderColor="gray"
      paddingX={1}
    >
      {windowStart > 0 && (
        <Text dimColor>  ▲ {windowStart} more above</Text>
      )}
      {visible.map((cmd: SlashCommand, offset: number) => {
        const i = windowStart + offset;
        return (
          <Box key={cmd.name} gap={1}>
            <Text
              color={i === selectedIndex ? "blue" : undefined}
              bold={i === selectedIndex}
            >
              {i === selectedIndex ? ">" : " "} /{cmd.name}
            </Text>
            {cmd.args && <Text color="cyan">{cmd.args}</Text>}
            <Text dimColor>{cmd.description}</Text>
          </Box>
        );
      })}
      {windowEnd < completions.length && (
        <Text dimColor>  ▼ {completions.length - windowEnd} more below</Text>
      )}
    </Box>
  );
}
