import React from "react";
import {
  View,
  Text,
  StyleSheet,
  ScrollView,
  Pressable,
  Alert,
  RefreshControl,
} from "react-native";
import { useRouter } from "expo-router";
import { Ionicons } from "@expo/vector-icons";
import { useAuthStore } from "@/stores/authStore";
import { useSettings } from "@/hooks/useSettings";
import { useModelProviders } from "@/hooks/useModels";
import { authApi } from "@/api/auth";
import { disconnectSocket } from "@/channels/socket";
import { LoadingSpinner } from "@/components/LoadingSpinner";
import { StatusBadge } from "@/components/StatusBadge";
import { COLORS, FONT_SIZES, SPACING } from "@/lib/constants";

export default function SettingsScreen() {
  const router = useRouter();
  const user = useAuthStore((s) => s.user);
  const logoutAction = useAuthStore((s) => s.logout);
  const {
    data: settings,
    isLoading,
    refetch,
    isRefetching,
  } = useSettings();
  const { data: providers } = useModelProviders();

  // Get unique section names from settings
  const sectionNames = React.useMemo(() => {
    if (!settings) return [];
    const seen = new Set<string>();
    return settings.reduce<string[]>((acc, setting) => {
      const section = setting.section || "General";
      if (!seen.has(section)) {
        seen.add(section);
        acc.push(section);
      }
      return acc;
    }, []);
  }, [settings]);

  const handleLogout = async () => {
    Alert.alert("Sign Out", "Are you sure you want to sign out?", [
      { text: "Cancel", style: "cancel" },
      {
        text: "Sign Out",
        style: "destructive",
        onPress: async () => {
          try {
            await authApi.logout();
          } catch {
            // Ignore logout API errors
          }
          disconnectSocket();
          await logoutAction();
          router.replace("/(auth)/login");
        },
      },
    ]);
  };

  return (
    <View style={styles.outerContainer} testID="settings-screen">
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
        {/* Profile Section */}
        <View style={styles.profileCard}>
          <Ionicons
            name="person-circle-outline"
            size={56}
            color={COLORS.primary}
          />
          <View style={styles.profileInfo}>
            <Text style={styles.profileName}>
              {user?.username ?? user?.email ?? "User"}
            </Text>
            <Text style={styles.profileEmail}>{user?.email}</Text>
          </View>
        </View>

        {/* Model Providers Status */}
        {providers && providers.length > 0 && (
          <View style={styles.section}>
            <Text style={styles.sectionTitle}>Model Providers</Text>
            {providers.map((provider) => (
              <View key={provider.id} style={styles.providerRow}>
                <Text style={styles.providerName}>{provider.name}</Text>
                <StatusBadge
                  status={provider.status.status}
                  testID={`settings-provider-${provider.id}-status-badge`}
                />
              </View>
            ))}
          </View>
        )}

        {/* Settings Sections */}
        {isLoading ? (
          <LoadingSpinner message="Loading settings..." />
        ) : (
          <View style={styles.section}>
            <Text style={styles.sectionTitle}>Settings</Text>
            {sectionNames.map((sectionName) => (
              <Pressable
                key={sectionName}
                style={styles.sectionRow}
                onPress={() =>
                  router.push(`/(tabs)/settings/${encodeURIComponent(sectionName)}`)
                }
                testID={`settings-section-${sectionName}-button`}
              >
                <Text style={styles.sectionRowText}>{sectionName}</Text>
                <Ionicons
                  name="chevron-forward"
                  size={20}
                  color={COLORS.textMuted}
                />
              </Pressable>
            ))}
          </View>
        )}
      </ScrollView>

      {/* Logout — fixed footer outside ScrollView */}
      <Pressable
        style={styles.logoutButton}
        onPress={handleLogout}
        testID="settings-logout-button"
      >
        <Ionicons name="log-out-outline" size={20} color={COLORS.error} />
        <Text style={styles.logoutText}>Sign Out</Text>
      </Pressable>

      <View style={styles.versionContainer}>
        <Text style={styles.versionText}>Loomkin v1.0.0</Text>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  outerContainer: {
    flex: 1,
    backgroundColor: COLORS.background,
  },
  container: {
    flex: 1,
  },
  content: {
    padding: SPACING.lg,
    paddingBottom: SPACING["4xl"],
    gap: SPACING.xl,
  },
  profileCard: {
    flexDirection: "row",
    alignItems: "center",
    backgroundColor: COLORS.surface,
    borderRadius: 16,
    padding: SPACING.xl,
    gap: SPACING.lg,
    borderWidth: 1,
    borderColor: COLORS.border,
  },
  profileInfo: {
    flex: 1,
    gap: 2,
  },
  profileName: {
    fontSize: FONT_SIZES.lg,
    fontWeight: "700",
    color: COLORS.text,
  },
  profileEmail: {
    fontSize: FONT_SIZES.sm,
    color: COLORS.textSecondary,
  },
  section: {
    gap: SPACING.md,
  },
  sectionTitle: {
    fontSize: FONT_SIZES.md,
    fontWeight: "700",
    color: COLORS.text,
    textTransform: "uppercase",
    letterSpacing: 0.5,
  },
  providerRow: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    backgroundColor: COLORS.surface,
    borderRadius: 12,
    padding: SPACING.lg,
    borderWidth: 1,
    borderColor: COLORS.border,
  },
  providerName: {
    fontSize: FONT_SIZES.base,
    fontWeight: "600",
    color: COLORS.text,
  },
  sectionRow: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    backgroundColor: COLORS.surface,
    borderRadius: 12,
    padding: SPACING.lg,
    borderWidth: 1,
    borderColor: COLORS.border,
  },
  sectionRowText: {
    fontSize: FONT_SIZES.base,
    fontWeight: "600",
    color: COLORS.text,
  },
  logoutButton: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
    gap: SPACING.sm,
    backgroundColor: COLORS.surface,
    borderRadius: 12,
    padding: SPACING.lg,
    borderWidth: 1,
    borderColor: COLORS.error,
    marginHorizontal: SPACING.lg,
  },
  logoutText: {
    fontSize: FONT_SIZES.md,
    fontWeight: "600",
    color: COLORS.error,
  },
  versionContainer: {
    alignItems: "center",
    paddingVertical: SPACING.lg,
  },
  versionText: {
    fontSize: FONT_SIZES.xs,
    color: COLORS.textMuted,
  },
});
