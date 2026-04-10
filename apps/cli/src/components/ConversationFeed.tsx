import React from "react";
import { Box, Text } from "ink";
import type { ConversationInfo, ConversationTurn } from "../lib/types.js";

interface Props {
  conversation: ConversationInfo;
  maxLines?: number;
}

const REACTION_ICONS: Record<string, string> = {
  agree: "+1",
  disagree: "-1",
  question: "?",
  laugh: ":)",
  think: "...",
};

function TurnRow({ turn }: { turn: ConversationTurn }) {
  if (turn.type === "reaction") {
    const icon = REACTION_ICONS[turn.reaction_type ?? ""] ?? turn.reaction_type;
    return (
      <Box>
        <Text dimColor>
          {"  "}[{icon}] {turn.speaker}: {turn.content}
        </Text>
      </Box>
    );
  }

  if (turn.type === "yield") {
    return (
      <Box>
        <Text dimColor italic>
          {"  "}
          {turn.speaker} yields{turn.reason ? `: ${turn.reason}` : ""}
        </Text>
      </Box>
    );
  }

  return (
    <Box flexDirection="column">
      <Text bold color="magenta">
        {turn.speaker}:
      </Text>
      <Box marginLeft={2}>
        <Text wrap="wrap">{turn.content}</Text>
      </Box>
    </Box>
  );
}

export function ConversationFeed({ conversation, maxLines = 100 }: Props) {
  const statusColor =
    conversation.status === "active"
      ? "green"
      : conversation.status === "summarizing"
        ? "yellow"
        : conversation.status === "completed"
          ? "cyan"
          : "red";

  // Group turns by round for display
  let currentRound = 0;
  const elements: React.ReactNode[] = [];

  // Only show the most recent turns to avoid overflowing
  const startIndex = Math.max(0, conversation.turns.length - maxLines);
  const visibleTurns = conversation.turns.slice(startIndex);

  for (let i = 0; i < visibleTurns.length; i++) {
    const turn = visibleTurns[i];
    if (turn.round > currentRound) {
      currentRound = turn.round;
      elements.push(
        <Box key={`round-${currentRound}`} marginTop={currentRound > 1 ? 1 : 0}>
          <Text dimColor>
            {"── Round "}
            {currentRound}
            {" ──"}
          </Text>
        </Box>,
      );
    }
    elements.push(<TurnRow key={`turn-${startIndex + i}-${turn.speaker}`} turn={turn} />);
  }

  // Show summary if completed
  if (conversation.status === "completed" && conversation.summary) {
    const s = conversation.summary;
    elements.push(
      <Box key="summary" flexDirection="column" marginTop={1}>
        <Text bold color="cyan">
          Summary
        </Text>
        {s.key_points?.map((p, i) => (
          <Text key={`kp-${i}`}> - {p}</Text>
        ))}
        {s.consensus && s.consensus.length > 0 && (
          <>
            <Text bold color="green">
              Consensus
            </Text>
            {s.consensus.map((c, i) => (
              <Text key={`c-${i}`}> - {c}</Text>
            ))}
          </>
        )}
        {s.disagreements && s.disagreements.length > 0 && (
          <>
            <Text bold color="red">
              Disagreements
            </Text>
            {s.disagreements.map((d, i) => (
              <Text key={`d-${i}`}> - {d}</Text>
            ))}
          </>
        )}
        {s.recommended_actions && s.recommended_actions.length > 0 && (
          <>
            <Text bold color="yellow">
              Actions
            </Text>
            {s.recommended_actions.map((a, i) => (
              <Text key={`a-${i}`}> - {a}</Text>
            ))}
          </>
        )}
      </Box>,
    );
  }

  return (
    <Box flexDirection="column" flexGrow={1} paddingX={1}>
      <Box>
        <Text bold color="magenta">
          {conversation.topic}
        </Text>
        <Text> </Text>
        <Text color={statusColor}>[{conversation.status}]</Text>
        <Text dimColor> R{conversation.current_round}</Text>
      </Box>
      <Box marginBottom={1}>
        <Text dimColor>{conversation.participants.join(", ")}</Text>
      </Box>
      <Box flexDirection="column" flexGrow={1}>
        {elements}
      </Box>
    </Box>
  );
}
