import React from "react";
import { Box, Text } from "ink";
import { getCompletions, type SlashCommand } from "../commands/registry.js";

interface Props {
  input: string;
  selectedIndex: number;
}

export function CommandPalette({ input, selectedIndex }: Props) {
  const query = input.replace(/^\//, "");
  const completions = getCompletions(query);

  if (completions.length === 0) {
    return (
      <Box borderStyle="single" borderColor="gray" paddingX={1}>
        <Text dimColor>No matching commands</Text>
      </Box>
    );
  }

  return (
    <Box
      flexDirection="column"
      borderStyle="single"
      borderColor="gray"
      paddingX={1}
    >
      {completions.map((cmd: SlashCommand, i: number) => (
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
      ))}
    </Box>
  );
}
