import React from "react";
import { View, Text, StyleSheet } from "react-native";
import { COLORS, FONT_SIZES, SPACING } from "@/lib/constants";
import { formatTime } from "@/lib/formatters";
import { ToolCallView } from "./ToolCallView";
import type { Message } from "@/lib/types";

interface ChatBubbleProps {
  message: Message;
  testID?: string;
}

export function ChatBubble({ message, testID = "chat-bubble" }: ChatBubbleProps) {
  const isUser = message.role === "user";
  const isAssistant = message.role === "assistant";
  const isSystem = message.role === "system";
  const isTool = message.role === "tool";

  if (isSystem) {
    return (
      <View style={styles.systemContainer} testID={`${testID}-system`}>
        <Text style={styles.systemText}>{message.content}</Text>
      </View>
    );
  }

  if (isTool && message.tool_calls) {
    return (
      <View style={styles.toolContainer} testID={`${testID}-tool`}>
        {message.tool_calls.map((tc) => (
          <ToolCallView
            key={tc.id}
            toolCall={tc}
            testID={`${testID}-tool-call-${tc.id}`}
          />
        ))}
      </View>
    );
  }

  return (
    <View
      style={[
        styles.container,
        isUser ? styles.userContainer : styles.assistantContainer,
      ]}
      testID={`${testID}-${message.role}`}
    >
      <View
        style={[
          styles.bubble,
          isUser ? styles.userBubble : styles.assistantBubble,
        ]}
      >
        {!isUser && (
          <Text style={styles.roleLabel}>
            {message.agent_name ?? (message.role === "assistant" ? "Assistant" : message.role)}
          </Text>
        )}

        {message.content && (
          <Text
            style={[styles.content, isUser && styles.userContent]}
            selectable
          >
            {message.content}
          </Text>
        )}

        {isAssistant && message.tool_calls && message.tool_calls.length > 0 && (
          <View style={styles.toolCallsContainer}>
            {message.tool_calls.map((tc) => (
              <ToolCallView
                key={tc.id}
                toolCall={tc}
                testID={`${testID}-tool-call-${tc.id}`}
              />
            ))}
          </View>
        )}

        <Text style={[styles.time, isUser && styles.userTime]}>
          {formatTime(message.inserted_at)}
        </Text>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    paddingHorizontal: SPACING.md,
    paddingVertical: SPACING.xs,
    maxWidth: "85%",
  },
  userContainer: {
    alignSelf: "flex-end",
  },
  assistantContainer: {
    alignSelf: "flex-start",
  },
  bubble: {
    padding: SPACING.md,
    borderRadius: 16,
  },
  userBubble: {
    backgroundColor: COLORS.userBubble,
    borderBottomRightRadius: 4,
  },
  assistantBubble: {
    backgroundColor: COLORS.assistantBubble,
    borderBottomLeftRadius: 4,
  },
  roleLabel: {
    fontSize: FONT_SIZES.xs,
    fontWeight: "700",
    color: COLORS.primaryLight,
    marginBottom: SPACING.xs,
    textTransform: "uppercase",
    letterSpacing: 0.5,
  },
  content: {
    fontSize: FONT_SIZES.base,
    color: COLORS.text,
    lineHeight: 20,
  },
  userContent: {
    color: COLORS.white,
  },
  time: {
    fontSize: FONT_SIZES.xs,
    color: COLORS.textMuted,
    marginTop: SPACING.xs,
    alignSelf: "flex-end",
  },
  userTime: {
    color: "rgba(255, 255, 255, 0.6)",
  },
  systemContainer: {
    alignSelf: "center",
    paddingHorizontal: SPACING.lg,
    paddingVertical: SPACING.sm,
    marginVertical: SPACING.xs,
  },
  systemText: {
    fontSize: FONT_SIZES.sm,
    color: COLORS.textMuted,
    fontStyle: "italic",
    textAlign: "center",
  },
  toolContainer: {
    paddingHorizontal: SPACING.md,
    paddingVertical: SPACING.xs,
    alignSelf: "flex-start",
    maxWidth: "90%",
  },
  toolCallsContainer: {
    marginTop: SPACING.sm,
    gap: SPACING.xs,
  },
});
