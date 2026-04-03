import React, { useState, useEffect } from "react";
import { Box, Text, useInput } from "ink";
import TextInput from "ink-text-input";
import type { AskUserQuestion } from "../lib/types.js";

interface Props {
  question: AskUserQuestion;
  onAnswer: (questionId: string, answer: string) => void;
}

const COLLECTIVE_OPTION = "Let the collective decide";
const COLLECTIVE_ANSWER = "__collective__";

export function AskUserPrompt({ question, onAnswer }: Props) {
  const [selected, setSelected] = useState(0);
  const [freeText, setFreeText] = useState("");
  const hasOptions = question.options.length > 0;

  // Reset cursor when the question changes
  useEffect(() => {
    setSelected(0);
    setFreeText("");
  }, [question.question_id]);

  // Append the collective option to the agent-provided choices
  const allOptions = hasOptions
    ? [...question.options, COLLECTIVE_OPTION]
    : [];

  useInput(
    (input, key) => {
      if (!hasOptions) return;

      if (key.upArrow) {
        setSelected((s) => Math.max(0, s - 1));
      } else if (key.downArrow) {
        setSelected((s) => Math.min(allOptions.length - 1, s + 1));
      } else if (key.return) {
        const chosen = allOptions[selected];
        const answer =
          chosen === COLLECTIVE_OPTION ? COLLECTIVE_ANSWER : chosen;
        onAnswer(question.question_id, answer);
      }
    },
    { isActive: hasOptions },
  );

  return (
    <Box
      borderStyle="round"
      borderColor="cyan"
      paddingX={1}
      flexDirection="column"
    >
      <Text bold color="cyan">
        {question.agent_name} asks:
      </Text>
      <Text>{question.question}</Text>

      {hasOptions ? (
        <Box flexDirection="column" marginTop={1}>
          {allOptions.map((opt, i) => {
            const isCollective = opt === COLLECTIVE_OPTION;
            const isSelected = i === selected;
            const color = isCollective
              ? "yellow"
              : isSelected
                ? "cyan"
                : undefined;

            return (
              <Text key={opt}>
                <Text color={color}>
                  {isSelected ? "▸ " : "  "}
                  {opt}
                </Text>
              </Text>
            );
          })}
        </Box>
      ) : (
        <Box marginTop={1}>
          <Text dimColor>{"› "}</Text>
          <TextInput
            value={freeText}
            onChange={setFreeText}
            onSubmit={(value) => onAnswer(question.question_id, value)}
            placeholder="Type your answer..."
          />
        </Box>
      )}
    </Box>
  );
}
