import React from "react";
import { View, Text, StyleSheet, Pressable } from "react-native";
import { Link, Stack } from "expo-router";
import { Ionicons } from "@expo/vector-icons";
import { COLORS, FONT_SIZES, SPACING } from "@/lib/constants";

export default function NotFoundScreen() {
  return (
    <>
      <Stack.Screen options={{ title: "Not Found" }} />
      <View style={styles.container}>
        <Ionicons name="warning-outline" size={64} color={COLORS.textMuted} />
        <Text style={styles.title}>Page Not Found</Text>
        <Text style={styles.description}>The page you're looking for doesn't exist.</Text>
        <Link href="/(tabs)" asChild>
          <Pressable style={styles.button} testID="not-found-home-button">
            <Text style={styles.buttonText}>Go Home</Text>
          </Pressable>
        </Link>
      </View>
    </>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    alignItems: "center",
    justifyContent: "center",
    backgroundColor: COLORS.background,
    padding: SPACING["3xl"],
    gap: SPACING.md,
  },
  title: {
    fontSize: FONT_SIZES["2xl"],
    fontWeight: "700",
    color: COLORS.text,
  },
  description: {
    fontSize: FONT_SIZES.base,
    color: COLORS.textSecondary,
    textAlign: "center",
  },
  button: {
    marginTop: SPACING.lg,
    backgroundColor: COLORS.primary,
    paddingHorizontal: SPACING.xl,
    paddingVertical: SPACING.md,
    borderRadius: 8,
  },
  buttonText: {
    color: COLORS.white,
    fontSize: FONT_SIZES.base,
    fontWeight: "600",
  },
});
