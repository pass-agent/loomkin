import React, { useState } from "react";
import { View, Text, StyleSheet, Pressable, ScrollView } from "react-native";
import { Ionicons } from "@expo/vector-icons";
import { COLORS, FONT_SIZES, SPACING } from "@/lib/constants";
import type { ToolCall } from "@/lib/types";

interface ToolCallViewProps {
  toolCall: ToolCall;
  testID?: string;
}

export function ToolCallView({ toolCall, testID = "tool-call-view" }: ToolCallViewProps) {
  const [isExpanded, setIsExpanded] = useState(false);

  return (
    <View style={styles.container} testID={testID}>
      <Pressable
        style={styles.header}
        onPress={() => setIsExpanded(!isExpanded)}
        testID={`${testID}-toggle-button`}
      >
        <Ionicons name="construct-outline" size={14} color={COLORS.primaryLight} />
        <Text style={styles.toolName} numberOfLines={1}>
          {toolCall.name}
        </Text>
        <Ionicons
          name={isExpanded ? "chevron-up" : "chevron-down"}
          size={14}
          color={COLORS.textMuted}
        />
      </Pressable>

      {isExpanded && (
        <View style={styles.body}>
          <Text style={styles.sectionLabel}>Input:</Text>
          <ScrollView
            horizontal
            style={styles.codeScrollView}
            showsHorizontalScrollIndicator={false}
          >
            <Text style={styles.code} selectable>
              {JSON.stringify(toolCall.arguments, null, 2)}
            </Text>
          </ScrollView>

          {toolCall.output != null && (
            <>
              <Text style={styles.sectionLabel}>Output:</Text>
              <ScrollView
                horizontal
                style={styles.codeScrollView}
                showsHorizontalScrollIndicator={false}
              >
                <Text style={styles.code} selectable>
                  {toolCall.output}
                </Text>
              </ScrollView>
            </>
          )}
        </View>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    backgroundColor: COLORS.toolBubble,
    borderRadius: 8,
    borderWidth: 1,
    borderColor: COLORS.border,
    overflow: "hidden",
    marginVertical: SPACING.xs,
  },
  header: {
    flexDirection: "row",
    alignItems: "center",
    padding: SPACING.sm,
    gap: SPACING.sm,
  },
  toolName: {
    flex: 1,
    fontSize: FONT_SIZES.sm,
    fontWeight: "600",
    color: COLORS.primaryLight,
    fontFamily: "monospace",
  },
  body: {
    padding: SPACING.sm,
    borderTopWidth: 1,
    borderTopColor: COLORS.border,
    gap: SPACING.sm,
  },
  sectionLabel: {
    fontSize: FONT_SIZES.xs,
    fontWeight: "600",
    color: COLORS.textSecondary,
    textTransform: "uppercase",
  },
  codeScrollView: {
    backgroundColor: COLORS.background,
    borderRadius: 4,
    padding: SPACING.sm,
    maxHeight: 200,
  },
  code: {
    fontSize: FONT_SIZES.xs,
    color: COLORS.text,
    fontFamily: "monospace",
    lineHeight: 16,
  },
});
