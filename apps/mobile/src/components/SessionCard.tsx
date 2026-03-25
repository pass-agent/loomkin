import React from "react";
import { View, Text, StyleSheet, Pressable } from "react-native";
import { Ionicons } from "@expo/vector-icons";
import { COLORS, FONT_SIZES, SPACING } from "@/lib/constants";
import { formatRelativeTime, sessionTitle, formatCost } from "@/lib/formatters";
import { StatusBadge } from "./StatusBadge";
import type { Session } from "@/lib/types";

interface SessionCardProps {
  session: Session;
  onPress: (session: Session) => void;
  testID?: string;
}

export function SessionCard({
  session,
  onPress,
  testID = "session-card",
}: SessionCardProps) {
  return (
    <Pressable
      style={({ pressed }) => [
        styles.container,
        pressed && styles.pressed,
      ]}
      onPress={() => onPress(session)}
      testID={testID}
    >
      <View style={styles.header}>
        <Ionicons
          name="chatbubbles-outline"
          size={18}
          color={COLORS.primary}
        />
        <Text style={styles.title} numberOfLines={1}>
          {sessionTitle(session.title, session.id)}
        </Text>
        <StatusBadge
          status={session.status}
          testID={`${testID}-status-badge`}
        />
      </View>

      <View style={styles.details}>
        <View style={styles.detailItem}>
          <Ionicons
            name="cube-outline"
            size={12}
            color={COLORS.textMuted}
          />
          <Text style={styles.detailText} numberOfLines={1}>
            {session.model}
          </Text>
        </View>

        {session.cost_usd != null && (
          <View style={styles.detailItem}>
            <Ionicons
              name="flash-outline"
              size={12}
              color={COLORS.warning}
            />
            <Text style={[styles.detailText, { color: COLORS.warning }]}>
              {formatCost(session.cost_usd)}
            </Text>
          </View>
        )}

        <Text style={styles.time}>
          {formatRelativeTime(session.updated_at)}
        </Text>
      </View>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  container: {
    backgroundColor: COLORS.surface,
    borderRadius: 12,
    padding: SPACING.lg,
    marginHorizontal: SPACING.lg,
    marginVertical: SPACING.xs,
    borderWidth: 1,
    borderColor: COLORS.border,
  },
  pressed: {
    opacity: 0.7,
    backgroundColor: COLORS.surfaceLight,
  },
  header: {
    flexDirection: "row",
    alignItems: "center",
    gap: SPACING.sm,
    marginBottom: SPACING.sm,
  },
  title: {
    flex: 1,
    fontSize: FONT_SIZES.md,
    fontWeight: "600",
    color: COLORS.text,
  },
  details: {
    flexDirection: "row",
    alignItems: "center",
    gap: SPACING.md,
  },
  detailItem: {
    flexDirection: "row",
    alignItems: "center",
    gap: SPACING.xs,
  },
  detailText: {
    fontSize: FONT_SIZES.sm,
    color: COLORS.textSecondary,
    maxWidth: 120,
  },
  time: {
    flex: 1,
    fontSize: FONT_SIZES.xs,
    color: COLORS.textMuted,
    textAlign: "right",
  },
});
