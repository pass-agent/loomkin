import React from "react";
import { View, Text, StyleSheet } from "react-native";
import { COLORS, FONT_SIZES, SPACING } from "@/lib/constants";

interface StatusBadgeProps {
  status: string;
  testID?: string;
}

const STATUS_COLORS: Record<string, { bg: string; text: string }> = {
  active: { bg: "#064e3b", text: COLORS.success },
  running: { bg: "#064e3b", text: COLORS.success },
  online: { bg: "#064e3b", text: COLORS.success },
  archived: { bg: "#1e293b", text: COLORS.textMuted },
  idle: { bg: "#422006", text: COLORS.warning },
  waiting: { bg: "#422006", text: COLORS.warning },
  pending: { bg: "#422006", text: COLORS.warning },
  error: { bg: "#450a0a", text: COLORS.error },
  failed: { bg: "#450a0a", text: COLORS.error },
  offline: { bg: "#1e293b", text: COLORS.textMuted },
};

export function StatusBadge({ status, testID = "status-badge" }: StatusBadgeProps) {
  const colors = STATUS_COLORS[status.toLowerCase()] ?? {
    bg: COLORS.surfaceLight,
    text: COLORS.textSecondary,
  };

  return (
    <View style={[styles.badge, { backgroundColor: colors.bg }]} testID={testID}>
      <View style={[styles.dot, { backgroundColor: colors.text }]} />
      <Text style={[styles.text, { color: colors.text }]}>{status}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  badge: {
    flexDirection: "row",
    alignItems: "center",
    paddingHorizontal: SPACING.sm,
    paddingVertical: SPACING.xs,
    borderRadius: 12,
    gap: SPACING.xs,
  },
  dot: {
    width: 6,
    height: 6,
    borderRadius: 3,
  },
  text: {
    fontSize: FONT_SIZES.xs,
    fontWeight: "600",
    textTransform: "capitalize",
  },
});
