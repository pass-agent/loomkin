import React from "react";
import { View, Text, StyleSheet, ScrollView, Pressable } from "react-native";
import { useRouter } from "expo-router";
import { Ionicons } from "@expo/vector-icons";
import { SafeAreaView } from "react-native-safe-area-context";
import { useSessions } from "@/hooks/useSessions";
import { EmptyState } from "@/components/EmptyState";
import { StatusBadge } from "@/components/StatusBadge";
import { COLORS, FONT_SIZES, SPACING } from "@/lib/constants";

export default function TeamsListScreen() {
  const router = useRouter();
  const { data: sessions } = useSessions();

  // Extract unique team IDs from sessions
  const teamIds = [
    ...new Set(
      sessions
        ?.filter((s) => s.team_id != null)
        .map((s) => s.team_id!) ?? []
    ),
  ];

  if (teamIds.length === 0) {
    return (
      <View style={styles.container} testID="teams-screen">
        <EmptyState
          icon="people-outline"
          title="No teams yet"
          description="Teams will appear here when sessions are assigned to teams."
          testID="teams-empty-state"
        />
      </View>
    );
  }

  return (
    <ScrollView
      style={styles.container}
      contentContainerStyle={styles.content}
      testID="teams-screen"
    >
      {teamIds.map((teamId) => {
        const teamSessions = sessions?.filter(
          (s) => s.team_id === teamId
        );
        const activeCount =
          teamSessions?.filter((s) => s.status === "active").length ?? 0;

        return (
          <Pressable
            key={teamId}
            style={({ pressed }) => [
              styles.teamCard,
              pressed && styles.teamCardPressed,
            ]}
            onPress={() => router.push(`/(tabs)/teams/${teamId}`)}
            testID={`teams-card-${teamId}-button`}
          >
            <View style={styles.teamIcon}>
              <Ionicons
                name="people-circle-outline"
                size={40}
                color={COLORS.primary}
              />
            </View>

            <View style={styles.teamInfo}>
              <Text style={styles.teamName}>Team {teamId.slice(0, 8)}</Text>
              <Text style={styles.teamMeta}>
                {teamSessions?.length ?? 0} sessions
              </Text>
            </View>

            <View style={styles.teamStats}>
              {activeCount > 0 && (
                <StatusBadge
                  status="active"
                  testID={`teams-card-${teamId}-status-badge`}
                />
              )}
              <Ionicons
                name="chevron-forward"
                size={20}
                color={COLORS.textMuted}
              />
            </View>
          </Pressable>
        );
      })}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: COLORS.background,
  },
  content: {
    padding: SPACING.lg,
    gap: SPACING.sm,
  },
  teamCard: {
    flexDirection: "row",
    alignItems: "center",
    backgroundColor: COLORS.surface,
    borderRadius: 12,
    padding: SPACING.lg,
    borderWidth: 1,
    borderColor: COLORS.border,
    gap: SPACING.md,
  },
  teamCardPressed: {
    opacity: 0.7,
    backgroundColor: COLORS.surfaceLight,
  },
  teamIcon: {
    width: 44,
    height: 44,
    alignItems: "center",
    justifyContent: "center",
  },
  teamInfo: {
    flex: 1,
    gap: 2,
  },
  teamName: {
    fontSize: FONT_SIZES.md,
    fontWeight: "700",
    color: COLORS.text,
  },
  teamMeta: {
    fontSize: FONT_SIZES.sm,
    color: COLORS.textSecondary,
  },
  teamStats: {
    flexDirection: "row",
    alignItems: "center",
    gap: SPACING.sm,
  },
});
