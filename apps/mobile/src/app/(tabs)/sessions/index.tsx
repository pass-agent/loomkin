import React, { useState, useCallback } from "react";
import { View, Text, StyleSheet, FlatList, Pressable, RefreshControl } from "react-native";
import { useRouter } from "expo-router";
import { Ionicons } from "@expo/vector-icons";
import { SafeAreaView } from "react-native-safe-area-context";
import { useSessions } from "@/hooks/useSessions";
import { SessionCard } from "@/components/SessionCard";
import { EmptyState } from "@/components/EmptyState";
import { LoadingSpinner } from "@/components/LoadingSpinner";
import { COLORS, FONT_SIZES, SPACING } from "@/lib/constants";
import type { Session } from "@/lib/types";

type Filter = "all" | "active" | "archived";

export default function SessionsListScreen() {
  const router = useRouter();
  const { data: sessions, isLoading, refetch, isRefetching } = useSessions();
  const [filter, setFilter] = useState<Filter>("all");

  const filteredSessions =
    sessions?.filter((s) => {
      if (filter === "all") return true;
      return s.status === filter;
    }) ?? [];

  const handleSessionPress = useCallback(
    (session: Session) => {
      router.push(`/(tabs)/sessions/${session.id}`);
    },
    [router],
  );

  const renderSession = useCallback(
    ({ item }: { item: Session }) => (
      <SessionCard
        session={item}
        onPress={handleSessionPress}
        testID={`sessions-list-card-${item.id}`}
      />
    ),
    [handleSessionPress],
  );

  if (isLoading) {
    return <LoadingSpinner fullScreen message="Loading sessions..." />;
  }

  return (
    <View style={styles.container} testID="sessions-screen">
      {/* Filter Tabs */}
      <View style={styles.filterRow}>
        {(["all", "active", "archived"] as Filter[]).map((f) => (
          <Pressable
            key={f}
            style={[styles.filterTab, filter === f && styles.filterTabActive]}
            onPress={() => setFilter(f)}
            testID={`sessions-filter-${f}-button`}
          >
            <Text style={[styles.filterText, filter === f && styles.filterTextActive]}>
              {f.charAt(0).toUpperCase() + f.slice(1)}
            </Text>
          </Pressable>
        ))}
      </View>

      {/* Sessions List */}
      <FlatList
        data={filteredSessions}
        keyExtractor={(item) => item.id}
        renderItem={renderSession}
        contentContainerStyle={styles.listContent}
        refreshControl={
          <RefreshControl
            refreshing={isRefetching}
            onRefresh={refetch}
            tintColor={COLORS.primary}
          />
        }
        ListEmptyComponent={
          <EmptyState
            icon="chatbubbles-outline"
            title="No sessions found"
            description={
              filter !== "all"
                ? `No ${filter} sessions. Try a different filter.`
                : "Create your first session to get started."
            }
            actionLabel="New Session"
            onAction={() => router.push("/(tabs)/sessions/new")}
            testID="sessions-empty-state"
          />
        }
      />

      {/* FAB */}
      <Pressable
        style={styles.fab}
        onPress={() => router.push("/(tabs)/sessions/new")}
        testID="sessions-new-session-button"
      >
        <Ionicons name="add" size={28} color={COLORS.white} />
      </Pressable>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: COLORS.background,
  },
  filterRow: {
    flexDirection: "row",
    paddingHorizontal: SPACING.lg,
    paddingVertical: SPACING.md,
    gap: SPACING.sm,
  },
  filterTab: {
    paddingHorizontal: SPACING.lg,
    paddingVertical: SPACING.sm,
    borderRadius: 20,
    backgroundColor: COLORS.surface,
    borderWidth: 1,
    borderColor: COLORS.border,
  },
  filterTabActive: {
    backgroundColor: COLORS.primary,
    borderColor: COLORS.primary,
  },
  filterText: {
    fontSize: FONT_SIZES.sm,
    fontWeight: "600",
    color: COLORS.textSecondary,
  },
  filterTextActive: {
    color: COLORS.white,
  },
  listContent: {
    paddingVertical: SPACING.sm,
    flexGrow: 1,
  },
  fab: {
    position: "absolute",
    right: SPACING.xl,
    bottom: SPACING.xl,
    width: 56,
    height: 56,
    borderRadius: 28,
    backgroundColor: COLORS.primary,
    alignItems: "center",
    justifyContent: "center",
    elevation: 8,
    shadowColor: COLORS.primary,
    shadowOffset: { width: 0, height: 4 },
    shadowOpacity: 0.3,
    shadowRadius: 8,
  },
});
