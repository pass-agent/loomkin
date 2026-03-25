import React, { useState } from "react";
import { Box, Text, useInput } from "ink";
import TextInput from "ink-text-input";
import type { AskUserQuestion } from "../lib/types.js";

interface Props {
  question: AskUserQuestion;
  onAnswer: (questionId: string, answer: string) => void;
}

export function AskUserPrompt({ question, onAnswer }: Props) {
  const [selected, setSelected] = useState(0);
  const [freeText, setFreeText] = useState("");
  const hasOptions = question.options.length > 0;

  useInput(
    (input, key) => {
      if (!hasOptions) return;

      if (key.upArrow) {
        setSelected((s) => Math.max(0, s - 1));
      } else if (key.downArrow) {
        setSelected((s) => Math.min(question.options.length - 1, s + 1));
      } else if (key.return) {
        onAnswer(question.question_id, question.options[selected]);
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
          {question.options.map((opt, i) => (
            <Text key={opt}>
              <Text color={i === selected ? "cyan" : undefined}>
                {i === selected ? "▸ " : "  "}
                {opt}
              </Text>
            </Text>
          ))}
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
