import React, { useEffect, useState } from "react";
import { View, Text, StyleSheet, Alert } from "react-native";
import { useRouter, useLocalSearchParams } from "expo-router";
import { Ionicons } from "@expo/vector-icons";
import { authApi } from "@/api/auth";
import { useAuthStore } from "@/stores/authStore";
import { COLORS, FONT_SIZES, SPACING } from "@/lib/constants";
import { LoadingSpinner } from "@/components/LoadingSpinner";

/**
 * Deep link handler for magic link confirmation.
 * Handles loomkin://auth/confirm?token=xxx
 */
export default function ConfirmScreen() {
  const router = useRouter();
  const params = useLocalSearchParams<{ token: string }>();
  const loginAction = useAuthStore((s) => s.login);
  const [status, setStatus] = useState<"loading" | "success" | "error">(
    "loading"
  );
  const [errorMessage, setErrorMessage] = useState("");

  useEffect(() => {
    const confirmToken = async () => {
      if (!params.token) {
        setStatus("error");
        setErrorMessage("No confirmation token found.");
        return;
      }

      try {
        const response = await authApi.confirmLogin({
          token: params.token,
        });
        await loginAction(response.token, response.user);
        setStatus("success");

        // Brief delay to show success, then navigate
        setTimeout(() => {
          router.replace("/(tabs)");
        }, 1000);
      } catch (error: any) {
        setStatus("error");
        const message =
          error?.response?.data?.error ??
          error?.message ??
          "Confirmation failed. The link may have expired.";
        setErrorMessage(message);
      }
    };

    confirmToken();
  }, [params.token, loginAction, router]);

  return (
    <View style={styles.container} testID="confirm-screen">
      {status === "loading" && (
        <View style={styles.content}>
          <LoadingSpinner size="large" message="Confirming your login..." />
        </View>
      )}

      {status === "success" && (
        <View style={styles.content}>
          <Ionicons
            name="checkmark-circle"
            size={64}
            color={COLORS.success}
          />
          <Text style={styles.title}>Login Confirmed</Text>
          <Text style={styles.description}>Redirecting...</Text>
        </View>
      )}

      {status === "error" && (
        <View style={styles.content}>
          <Ionicons
            name="alert-circle"
            size={64}
            color={COLORS.error}
          />
          <Text style={styles.title}>Confirmation Failed</Text>
          <Text style={styles.description}>{errorMessage}</Text>
        </View>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: COLORS.background,
    justifyContent: "center",
    alignItems: "center",
  },
  content: {
    alignItems: "center",
    padding: SPACING["3xl"],
    gap: SPACING.md,
  },
  title: {
    fontSize: FONT_SIZES["2xl"],
    fontWeight: "700",
    color: COLORS.text,
    textAlign: "center",
  },
  description: {
    fontSize: FONT_SIZES.base,
    color: COLORS.textSecondary,
    textAlign: "center",
    maxWidth: 280,
  },
});
