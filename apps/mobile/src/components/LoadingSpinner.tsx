import React from "react";
import { ActivityIndicator, View, StyleSheet, Text } from "react-native";
import { COLORS, FONT_SIZES } from "@/lib/constants";

interface LoadingSpinnerProps {
  message?: string;
  size?: "small" | "large";
  fullScreen?: boolean;
}

export function LoadingSpinner({
  message,
  size = "large",
  fullScreen = false,
}: LoadingSpinnerProps) {
  return (
    <View
      style={[styles.container, fullScreen && styles.fullScreen]}
      testID="loading-spinner"
    >
      <ActivityIndicator size={size} color={COLORS.primary} />
      {message && <Text style={styles.message}>{message}</Text>}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    alignItems: "center",
    justifyContent: "center",
    padding: 20,
  },
  fullScreen: {
    flex: 1,
    backgroundColor: COLORS.background,
  },
  message: {
    marginTop: 12,
    fontSize: FONT_SIZES.base,
    color: COLORS.textSecondary,
  },
});
