import React from "react";
import {
  View,
  Text,
  StyleSheet,
  ScrollView,
  Pressable,
  RefreshControl,
} from "react-native";
import { useRouter } from "expo-router";
import { Ionicons } from "@expo/vector-icons";
import { SafeAreaView } from "react-native-safe-area-context";
import { useAuthStore } from "@/stores/authStore";
import { useSessions } from "@/hooks/useSessions";
import { SessionCard } from "@/components/SessionCard";
import { CostBadge } from "@/components/CostBadge";
import { LoadingSpinner } from "@/components/LoadingSpinner";
import { COLORS, FONT_SIZES, SPACING } from "@/lib/constants";
import type { Session } from "@/lib/types";

export default function DashboardScreen() {
  const router = useRouter();
  const user = useAuthStore((s) => s.user);
  const { data: sessions, isLoading, refetch, isRefetching } = useSessions();

  const activeSessions = sessions?.filter((s) => s.status === "active") ?? [];
  const totalCost = sessions?.reduce(
    (sum, s) => sum + (s.cost_usd ?? 0),
    0
  );
  const totalTokens = sessions?.reduce(
    (sum, s) => sum + s.prompt_tokens + s.completion_tokens,
    0
  );

  const handleSessionPress = (session: Session) => {
    router.push(`/(tabs)/sessions/${session.id}`);
  };

  return (
    <SafeAreaView style={styles.container} edges={["top"]} testID="dashboard-screen">
      <ScrollView
        contentContainerStyle={styles.scrollContent}
        refreshControl={
          <RefreshControl
            refreshing={isRefetching}
            onRefresh={refetch}
            tintColor={COLORS.primary}
          />
        }
      >
        {/* Header */}
        <View style={styles.header}>
          <View>
            <Text style={styles.greeting}>
              Welcome back{user?.username ? `, ${user.username}` : ""}
            </Text>
            <Text style={styles.headerSubtitle}>Loomkin Dashboard</Text>
          </View>
          <Pressable
            style={styles.profileButton}
            onPress={() => router.push("/(tabs)/settings")}
            testID="dashboard-profile-button"
          >
            <Ionicons
              name="person-circle-outline"
              size={36}
              color={COLORS.primary}
            />
          </Pressable>
        </View>

        {/* Stats Cards */}
        <View style={styles.statsRow}>
          <View style={styles.statCard}>
            <Ionicons
              name="chatbubbles-outline"
              size={24}
              color={COLORS.primary}
            />
            <Text style={styles.statValue}>{activeSessions.length}</Text>
            <Text style={styles.statLabel}>Active Sessions</Text>
          </View>

          <View style={styles.statCard}>
            <Ionicons
              name="flash-outline"
              size={24}
              color={COLORS.warning}
            />
            <Text style={styles.statValue}>
              {totalCost != null
                ? totalCost < 1
                  ? `$${totalCost.toFixed(3)}`
                  : `$${totalCost.toFixed(2)}`
                : "--"}
            </Text>
            <Text style={styles.statLabel}>Total Cost</Text>
          </View>

          <View style={styles.statCard}>
            <Ionicons
              name="analytics-outline"
              size={24}
              color={COLORS.info}
            />
            <Text style={styles.statValue}>
              {totalTokens != null
                ? totalTokens > 1000
                  ? `${(totalTokens / 1000).toFixed(1)}k`
                  : String(totalTokens)
                : "--"}
            </Text>
            <Text style={styles.statLabel}>Tokens Used</Text>
          </View>
        </View>

        {/* Quick Actions */}
        <View style={styles.section}>
          <Text style={styles.sectionTitle}>Quick Actions</Text>
          <View style={styles.actionsRow}>
            <Pressable
              style={styles.actionButton}
              onPress={() => router.push("/(tabs)/sessions/new")}
              testID="dashboard-new-session-button"
            >
              <Ionicons
                name="add-circle-outline"
                size={24}
                color={COLORS.primary}
              />
              <Text style={styles.actionText}>New Session</Text>
            </Pressable>

            <Pressable
              style={styles.actionButton}
              onPress={() => router.push("/(tabs)/sessions")}
              testID="dashboard-all-sessions-button"
            >
              <Ionicons
                name="list-outline"
                size={24}
                color={COLORS.secondary}
              />
              <Text style={styles.actionText}>All Sessions</Text>
            </Pressable>

            <Pressable
              style={styles.actionButton}
              onPress={() => router.push("/(tabs)/teams")}
              testID="dashboard-teams-button"
            >
              <Ionicons
                name="people-outline"
                size={24}
                color={COLORS.success}
              />
              <Text style={styles.actionText}>Teams</Text>
            </Pressable>
          </View>
        </View>

        {/* Recent Sessions */}
        <View style={styles.section}>
          <View style={styles.sectionHeader}>
            <Text style={styles.sectionTitle}>Recent Sessions</Text>
            <Pressable
              onPress={() => router.push("/(tabs)/sessions")}
              testID="dashboard-view-all-sessions-button"
            >
              <Text style={styles.viewAllText}>View All</Text>
            </Pressable>
          </View>

          {isLoading ? (
            <LoadingSpinner message="Loading sessions..." />
          ) : activeSessions.length === 0 ? (
            <View style={styles.emptyContainer}>
              <Text style={styles.emptyText}>No active sessions</Text>
              <Pressable
                style={styles.createButton}
                onPress={() => router.push("/(tabs)/sessions/new")}
                testID="dashboard-create-session-button"
              >
                <Text style={styles.createButtonText}>
                  Create your first session
                </Text>
              </Pressable>
            </View>
          ) : (
            activeSessions.slice(0, 5).map((session) => (
              <SessionCard
                key={session.id}
                session={session}
                onPress={handleSessionPress}
                testID={`dashboard-session-card-${session.id}`}
              />
            ))
          )}
        </View>
      </ScrollView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: COLORS.background,
  },
  scrollContent: {
    paddingBottom: SPACING["4xl"],
  },
  header: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
    padding: SPACING.xl,
    paddingTop: SPACING.lg,
  },
  greeting: {
    fontSize: FONT_SIZES["2xl"],
    fontWeight: "800",
    color: COLORS.text,
  },
  headerSubtitle: {
    fontSize: FONT_SIZES.base,
    color: COLORS.textSecondary,
    marginTop: 2,
  },
  profileButton: {
    padding: SPACING.xs,
  },
  statsRow: {
    flexDirection: "row",
    paddingHorizontal: SPACING.lg,
    gap: SPACING.md,
    marginBottom: SPACING.xl,
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
    fontSize: FONT_SIZES.xl,
    fontWeight: "700",
    color: COLORS.text,
  },
  statLabel: {
    fontSize: FONT_SIZES.xs,
    color: COLORS.textMuted,
    textAlign: "center",
  },
  section: {
    marginTop: SPACING.lg,
  },
  sectionHeader: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
    paddingHorizontal: SPACING.xl,
    marginBottom: SPACING.md,
  },
  sectionTitle: {
    fontSize: FONT_SIZES.lg,
    fontWeight: "700",
    color: COLORS.text,
    paddingHorizontal: SPACING.xl,
    marginBottom: SPACING.md,
  },
  viewAllText: {
    fontSize: FONT_SIZES.sm,
    color: COLORS.primary,
    fontWeight: "600",
  },
  actionsRow: {
    flexDirection: "row",
    paddingHorizontal: SPACING.lg,
    gap: SPACING.md,
    marginBottom: SPACING.md,
  },
  actionButton: {
    flex: 1,
    backgroundColor: COLORS.surface,
    borderRadius: 12,
    padding: SPACING.lg,
    alignItems: "center",
    gap: SPACING.sm,
    borderWidth: 1,
    borderColor: COLORS.border,
  },
  actionText: {
    fontSize: FONT_SIZES.sm,
    color: COLORS.text,
    fontWeight: "600",
  },
  emptyContainer: {
    alignItems: "center",
    padding: SPACING["3xl"],
    gap: SPACING.md,
  },
  emptyText: {
    fontSize: FONT_SIZES.base,
    color: COLORS.textMuted,
  },
  createButton: {
    backgroundColor: COLORS.primary,
    paddingHorizontal: SPACING.xl,
    paddingVertical: SPACING.md,
    borderRadius: 8,
  },
  createButtonText: {
    color: COLORS.white,
    fontSize: FONT_SIZES.base,
    fontWeight: "600",
  },
});
