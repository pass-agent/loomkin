import React from "react";
import { View, Text, StyleSheet, Pressable } from "react-native";
import { Ionicons } from "@expo/vector-icons";
import { COLORS, FONT_SIZES, SPACING } from "@/lib/constants";
import { formatCost, formatTokens } from "@/lib/formatters";

interface CostBadgeProps {
  costUsd: number | null | undefined;
  tokens?: number | null;
  onPress?: () => void;
  testID?: string;
}

export function CostBadge({ costUsd, tokens, onPress, testID = "cost-badge" }: CostBadgeProps) {
  if (onPress) {
    return (
      <Pressable
        style={styles.container}
        onPress={onPress}
        hitSlop={{ top: 8, bottom: 8, left: 8, right: 8 }}
        testID={testID}
      >
        <Ionicons name="flash-outline" size={12} color={COLORS.warning} />
        <Text style={styles.cost}>{formatCost(costUsd)}</Text>
        {tokens != null && <Text style={styles.tokens}>({formatTokens(tokens)})</Text>}
      </Pressable>
    );
  }

  return (
    <View style={styles.container} testID={testID}>
      <Ionicons name="flash-outline" size={12} color={COLORS.warning} />
      <Text style={styles.cost}>{formatCost(costUsd)}</Text>
      {tokens != null && <Text style={styles.tokens}>({formatTokens(tokens)})</Text>}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flexDirection: "row",
    alignItems: "center",
    gap: SPACING.xs,
    backgroundColor: COLORS.surfaceLight,
    paddingHorizontal: SPACING.sm,
    paddingVertical: SPACING.xs,
    borderRadius: 8,
  },
  cost: {
    fontSize: FONT_SIZES.xs,
    fontWeight: "600",
    color: COLORS.warning,
  },
  tokens: {
    fontSize: FONT_SIZES.xs,
    color: COLORS.textMuted,
  },
});
