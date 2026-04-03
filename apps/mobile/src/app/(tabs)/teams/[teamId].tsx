import React, { useCallback, useState } from "react";
import {
  View,
  Text,
  StyleSheet,
  ScrollView,
  RefreshControl,
  TextInput,
  Pressable,
  KeyboardAvoidingView,
  Platform,
} from "react-native";
import { useLocalSearchParams, Stack } from "expo-router";
import { Ionicons } from "@expo/vector-icons";
import { useTeam, useTeamAgents } from "@/hooks/useTeams";
import { useTeamChannel } from "@/channels/useTeamChannel";
import { AgentCard } from "@/components/AgentCard";
import { StatusBadge } from "@/components/StatusBadge";
import { LoadingSpinner } from "@/components/LoadingSpinner";
import { EmptyState } from "@/components/EmptyState";
import { COLORS, FONT_SIZES, SPACING } from "@/lib/constants";
import type { Agent } from "@/lib/types";
import { useQueryClient } from "@tanstack/react-query";
import { QUERY_KEYS } from "@/lib/constants";

export default function TeamDetailScreen() {
  const { teamId } = useLocalSearchParams<{ teamId: string }>();
  const queryClient = useQueryClient();
  const { data: team, isLoading, refetch, isRefetching } = useTeam(teamId);

  const [selectedAgent, setSelectedAgent] = useState<Agent | null>(null);
  const [composerText, setComposerText] = useState("");

  // Real-time team updates
  const { channel } = useTeamChannel({
    teamId,
    onAgentStatusChange: () => {
      queryClient.invalidateQueries({
        queryKey: QUERY_KEYS.team(teamId!),
      });
    },
    onTaskUpdate: () => {
      queryClient.invalidateQueries({
        queryKey: QUERY_KEYS.team(teamId!),
      });
    },
  });

  const handleReply = useCallback((agent: Agent) => {
    setSelectedAgent(agent);
  }, []);

  const handleBroadcast = useCallback(
    (agent: Agent) => {
      setSelectedAgent(null);
    },
    []
  );

  const handleSend = useCallback(() => {
    const text = composerText.trim();
    if (!text || !channel) return;

    if (selectedAgent) {
      channel.push("send_to_agent", {
        agent_name: selectedAgent.name,
        message: text,
      });
    } else {
      channel.push("broadcast", { message: text });
    }

    setComposerText("");
    setSelectedAgent(null);
  }, [composerText, channel, selectedAgent]);

  if (isLoading) {
    return <LoadingSpinner fullScreen message="Loading team..." />;
  }

  if (!team) {
    return (
      <EmptyState
        icon="people-outline"
        title="Team not found"
        description="This team could not be loaded."
        testID="team-detail-empty-state"
      />
    );
  }

  return (
    <>
      <Stack.Screen
        options={{
          title: `Team ${teamId?.slice(0, 8)}`,
        }}
      />

      <ScrollView
        style={styles.container}
        contentContainerStyle={styles.content}
        refreshControl={
          <RefreshControl
            refreshing={isRefetching}
            onRefresh={refetch}
            tintColor={COLORS.primary}
          />
        }
      >
        {/* Team Stats */}
        <View style={styles.statsRow}>
          <View style={styles.statCard}>
            <Text style={styles.statValue}>{team.agents.length}</Text>
            <Text style={styles.statLabel}>Agents</Text>
          </View>
          <View style={styles.statCard}>
            <Text style={styles.statValue}>{team.tasks.length}</Text>
            <Text style={styles.statLabel}>Tasks</Text>
          </View>
          <View style={styles.statCard}>
            <Text style={styles.statValue}>
              {team.agents.filter((a) => a.status === "active").length}
            </Text>
            <Text style={styles.statLabel}>Active</Text>
          </View>
        </View>

        {/* Agents */}
        <View style={styles.section}>
          <Text style={styles.sectionTitle}>Agents</Text>
          {team.agents.length === 0 ? (
            <Text style={styles.emptyText}>No agents in this team.</Text>
          ) : (
            team.agents.map((agent) => (
              <AgentCard
                key={agent.name}
                agent={agent}
                onReply={handleReply}
                onBroadcast={() => handleBroadcast(agent)}
                testID={`team-agent-card-${agent.name}`}
              />
            ))
          )}
        </View>

        {/* Tasks */}
        <View style={styles.section}>
          <Text style={styles.sectionTitle}>Tasks</Text>
          {team.tasks.length === 0 ? (
            <Text style={styles.emptyText}>No tasks assigned.</Text>
          ) : (
            team.tasks.map((task) => (
              <View
                key={task.id}
                style={styles.taskCard}
              >
                <View style={styles.taskInfo}>
                  <Text style={styles.taskTitle}>{task.title}</Text>
                  {task.assigned_to && (
                    <Text style={styles.taskAssigned}>
                      Assigned to: {task.assigned_to}
                    </Text>
                  )}
                </View>
                <StatusBadge
                  status={task.status}
                  testID={`team-task-${task.id}-status-badge`}
                />
              </View>
            ))
          )}
        </View>
      </ScrollView>

      {/* Composer Bar */}
      <KeyboardAvoidingView
        behavior={Platform.OS === "ios" ? "padding" : "height"}
        keyboardVerticalOffset={Platform.OS === "ios" ? 90 : 0}
      >
        <View style={styles.composerContainer}>
          {selectedAgent && (
            <View style={styles.replyIndicator}>
              <Ionicons name="chatbubble-outline" size={12} color={COLORS.primary} />
              <Text style={styles.replyText}>
                Replying to {selectedAgent.name}
              </Text>
              <Pressable
                onPress={() => setSelectedAgent(null)}
                testID="team-composer-clear-reply-button"
              >
                <Ionicons name="close" size={16} color={COLORS.textMuted} />
              </Pressable>
            </View>
          )}
          <View style={styles.composer}>
            <TextInput
              style={styles.composerInput}
              placeholder={
                selectedAgent
                  ? `Message ${selectedAgent.name}...`
                  : "Broadcast to team..."
              }
              placeholderTextColor={COLORS.textMuted}
              value={composerText}
              onChangeText={setComposerText}
              multiline
              maxLength={5000}
              testID="team-composer-input"
            />
            <Pressable
              style={[
                styles.sendButton,
                !composerText.trim() && styles.sendButtonDisabled,
              ]}
              onPress={handleSend}
              disabled={!composerText.trim()}
              testID="team-composer-send-button"
            >
              <Ionicons
                name={selectedAgent ? "send" : "megaphone"}
                size={18}
                color={COLORS.white}
              />
            </Pressable>
          </View>
        </View>
      </KeyboardAvoidingView>
    </>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: COLORS.background,
  },
  content: {
    paddingVertical: SPACING.lg,
    gap: SPACING.xl,
  },
  statsRow: {
    flexDirection: "row",
    paddingHorizontal: SPACING.lg,
    gap: SPACING.md,
  },
  statCard: {
    flex: 1,
    backgroundColor: COLORS.surface,
    borderRadius: 12,
    padding: SPACING.lg,
    alignItems: "center",
    gap: SPACING.xs,
    borderWidth: 1,
    borderColor: COLORS.border,
  },
  statValue: {
    fontSize: FONT_SIZES["2xl"],
    fontWeight: "700",
    color: COLORS.text,
  },
  statLabel: {
    fontSize: FONT_SIZES.xs,
    color: COLORS.textMuted,
  },
  section: {
    gap: SPACING.md,
  },
  sectionTitle: {
    fontSize: FONT_SIZES.lg,
    fontWeight: "700",
    color: COLORS.text,
    paddingHorizontal: SPACING.xl,
  },
  emptyText: {
    fontSize: FONT_SIZES.base,
    color: COLORS.textMuted,
    paddingHorizontal: SPACING.xl,
  },
  taskCard: {
    flexDirection: "row",
    alignItems: "center",
    backgroundColor: COLORS.surface,
    borderRadius: 12,
    padding: SPACING.lg,
    marginHorizontal: SPACING.lg,
    borderWidth: 1,
    borderColor: COLORS.border,
    gap: SPACING.md,
  },
  taskInfo: {
    flex: 1,
    gap: 2,
  },
  taskTitle: {
    fontSize: FONT_SIZES.base,
    fontWeight: "600",
    color: COLORS.text,
  },
  taskAssigned: {
    fontSize: FONT_SIZES.sm,
    color: COLORS.textSecondary,
  },
  composerContainer: {
    backgroundColor: COLORS.surface,
    borderTopWidth: 1,
    borderTopColor: COLORS.border,
    paddingHorizontal: SPACING.md,
    paddingVertical: SPACING.md,
    paddingBottom: Platform.OS === "ios" ? SPACING.xl : SPACING.md,
  },
  replyIndicator: {
    flexDirection: "row",
    alignItems: "center",
    gap: SPACING.xs,
    paddingBottom: SPACING.sm,
    marginBottom: SPACING.sm,
    borderBottomWidth: 1,
    borderBottomColor: COLORS.border,
  },
  replyText: {
    flex: 1,
    fontSize: FONT_SIZES.xs,
    color: COLORS.primary,
    fontWeight: "600",
  },
  composer: {
    flexDirection: "row",
    alignItems: "flex-end",
    gap: SPACING.sm,
  },
  composerInput: {
    flex: 1,
    backgroundColor: COLORS.surfaceLight,
    borderRadius: 20,
    paddingHorizontal: SPACING.lg,
    paddingVertical: SPACING.md,
    fontSize: FONT_SIZES.base,
    color: COLORS.text,
    maxHeight: 100,
    borderWidth: 1,
    borderColor: COLORS.border,
  },
  sendButton: {
    width: 40,
    height: 40,
    borderRadius: 20,
    backgroundColor: COLORS.primary,
    alignItems: "center",
    justifyContent: "center",
  },
  sendButtonDisabled: {
    opacity: 0.4,
  },
});
