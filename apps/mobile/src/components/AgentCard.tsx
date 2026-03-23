import React from "react";
import { View, Text, StyleSheet, Pressable } from "react-native";
import { Ionicons } from "@expo/vector-icons";
import { COLORS, FONT_SIZES, SPACING } from "@/lib/constants";
import { StatusBadge } from "./StatusBadge";
import { formatAgentStatus } from "@/lib/formatters";
import type { Agent } from "@/lib/types";

interface AgentCardProps {
  agent: Agent;
  onPress?: (agent: Agent) => void;
  onReply?: (agent: Agent) => void;
  onBroadcast?: (agent: Agent) => void;
  testID?: string;
}

export function AgentCard({
  agent,
  onPress,
  onReply,
  onBroadcast,
  testID = "agent-card",
}: AgentCardProps) {
  return (
    <Pressable
      style={({ pressed }) => [
        styles.container,
        pressed && onPress && styles.pressed,
      ]}
      onPress={() => onPress?.(agent)}
      disabled={!onPress}
      testID={testID}
    >
      <View style={styles.iconContainer}>
        <Ionicons
          name="person-circle-outline"
          size={40}
          color={COLORS.primary}
        />
      </View>

      <View style={styles.info}>
        <Text style={styles.name}>{agent.name}</Text>
        <Text style={styles.role}>{agent.role}</Text>
      </View>

      <StatusBadge
        status={agent.status}
        testID={`${testID}-status-badge`}
      />

      {(onReply || onBroadcast) && (
        <View style={styles.actions}>
          {onReply && (
            <Pressable
              style={styles.actionButton}
              onPress={() => onReply(agent)}
              testID={`${testID}-reply-button`}
            >
              <Ionicons name="chatbubble-outline" size={16} color={COLORS.primary} />
            </Pressable>
          )}
          {onBroadcast && (
            <Pressable
              style={styles.actionButton}
              onPress={() => onBroadcast(agent)}
              testID={`${testID}-broadcast-button`}
            >
              <Ionicons name="megaphone-outline" size={16} color={COLORS.secondary} />
            </Pressable>
          )}
        </View>
      )}
    </Pressable>
  );
}

const styles = StyleSheet.create({
  container: {
    flexDirection: "row",
    alignItems: "center",
    backgroundColor: COLORS.surface,
    borderRadius: 12,
    padding: SPACING.lg,
    marginHorizontal: SPACING.lg,
    marginVertical: SPACING.xs,
    borderWidth: 1,
    borderColor: COLORS.border,
    gap: SPACING.md,
  },
  pressed: {
    opacity: 0.7,
    backgroundColor: COLORS.surfaceLight,
  },
  iconContainer: {
    width: 44,
    height: 44,
    alignItems: "center",
    justifyContent: "center",
  },
  info: {
    flex: 1,
    gap: 2,
  },
  name: {
    fontSize: FONT_SIZES.md,
    fontWeight: "600",
    color: COLORS.text,
  },
  role: {
    fontSize: FONT_SIZES.sm,
    color: COLORS.textSecondary,
  },
  actions: {
    flexDirection: "row",
    gap: SPACING.xs,
  },
  actionButton: {
    width: 32,
    height: 32,
    borderRadius: 16,
    backgroundColor: COLORS.surfaceLight,
    alignItems: "center",
    justifyContent: "center",
  },
});
