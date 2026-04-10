import React, { useState } from "react";
import {
  View,
  Text,
  TextInput,
  StyleSheet,
  Pressable,
  KeyboardAvoidingView,
  Platform,
  Alert,
} from "react-native";
import { Link, useRouter } from "expo-router";
import { Ionicons } from "@expo/vector-icons";
import { authApi } from "@/api/auth";
import { useAuthStore } from "@/stores/authStore";
import { COLORS, FONT_SIZES, SPACING } from "@/lib/constants";
import { LoadingSpinner } from "@/components/LoadingSpinner";

export default function LoginScreen() {
  const router = useRouter();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [isLoading, setIsLoading] = useState(false);
  const [showPassword, setShowPassword] = useState(false);
  const [errorMessage, setErrorMessage] = useState("");

  const handleLogin = async () => {
    setErrorMessage("");
    if (!email.trim() || !password.trim()) {
      setErrorMessage("Please fill in all fields.");
      return;
    }

    setIsLoading(true);
    try {
      const response = await authApi.login({ email, password });

      if (response.token && response.user) {
        // Password login succeeded — store credentials and navigate to dashboard
        await useAuthStore.getState().login(response.token, response.user);
        router.replace("/(tabs)");
      } else {
        // Magic link flow — show informational alert
        Alert.alert(
          "Check Your Email",
          response.message || "A login link has been sent to your email.",
        );
      }
    } catch (error: unknown) {
      const message = error instanceof Error ? error.message : "Login failed. Please try again.";
      setErrorMessage(message);
    } finally {
      setIsLoading(false);
    }
  };

  return (
    <KeyboardAvoidingView
      style={styles.container}
      behavior={Platform.OS === "ios" ? "padding" : "height"}
      testID="login-screen"
    >
      <View style={styles.content}>
        <View style={styles.header}>
          <Ionicons name="code-slash-outline" size={56} color={COLORS.primary} />
          <Text style={styles.title}>Loomkin</Text>
          <Text style={styles.subtitle}>Sign in to your account</Text>
        </View>

        <View style={styles.form}>
          <View style={styles.inputContainer}>
            <Ionicons
              name="mail-outline"
              size={20}
              color={COLORS.textMuted}
              style={styles.inputIcon}
            />
            <TextInput
              style={styles.input}
              placeholder="Email"
              placeholderTextColor={COLORS.textMuted}
              value={email}
              onChangeText={setEmail}
              keyboardType="email-address"
              autoCapitalize="none"
              autoCorrect={false}
              textContentType="none"
              autoComplete="off"
              testID="login-email-input"
            />
          </View>

          <View style={styles.inputContainer}>
            <Ionicons
              name="lock-closed-outline"
              size={20}
              color={COLORS.textMuted}
              style={styles.inputIcon}
            />
            <TextInput
              style={styles.input}
              placeholder="Password"
              placeholderTextColor={COLORS.textMuted}
              value={password}
              onChangeText={setPassword}
              secureTextEntry={!showPassword}
              textContentType="none"
              autoComplete="off"
              testID="login-password-input"
            />
            <Pressable
              onPress={() => setShowPassword(!showPassword)}
              testID="login-toggle-password-button"
            >
              <Ionicons
                name={showPassword ? "eye-off-outline" : "eye-outline"}
                size={20}
                color={COLORS.textMuted}
              />
            </Pressable>
          </View>

          {errorMessage ? (
            <Text style={styles.errorText} testID="login-error-text">
              {errorMessage}
            </Text>
          ) : null}

          <Pressable
            style={[styles.loginButton, isLoading && styles.loginButtonDisabled]}
            onPress={handleLogin}
            disabled={isLoading}
            testID="login-submit-button"
          >
            {isLoading ? (
              <LoadingSpinner size="small" />
            ) : (
              <Text style={styles.loginButtonText}>Sign In</Text>
            )}
          </Pressable>
        </View>

        <View style={styles.footer}>
          <Text style={styles.footerText}>Don't have an account?</Text>
          <Link href="/(auth)/register" asChild testID="login-register-link">
            <Pressable testID="login-register-link-button">
              <Text style={styles.linkText}>Sign Up</Text>
            </Pressable>
          </Link>
        </View>
      </View>
    </KeyboardAvoidingView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: COLORS.background,
  },
  content: {
    flex: 1,
    justifyContent: "center",
    padding: SPACING["3xl"],
  },
  header: {
    alignItems: "center",
    marginBottom: SPACING["4xl"],
  },
  title: {
    fontSize: FONT_SIZES["3xl"],
    fontWeight: "800",
    color: COLORS.text,
    marginTop: SPACING.md,
  },
  subtitle: {
    fontSize: FONT_SIZES.md,
    color: COLORS.textSecondary,
    marginTop: SPACING.sm,
  },
  form: {
    gap: SPACING.lg,
  },
  inputContainer: {
    flexDirection: "row",
    alignItems: "center",
    backgroundColor: COLORS.surface,
    borderRadius: 12,
    borderWidth: 1,
    borderColor: COLORS.border,
    paddingHorizontal: SPACING.lg,
  },
  inputIcon: {
    marginRight: SPACING.md,
  },
  input: {
    flex: 1,
    height: 52,
    fontSize: FONT_SIZES.md,
    color: COLORS.text,
  },
  errorText: {
    fontSize: FONT_SIZES.sm,
    color: COLORS.error,
    textAlign: "center",
  },
  loginButton: {
    backgroundColor: COLORS.primary,
    height: 52,
    borderRadius: 12,
    alignItems: "center",
    justifyContent: "center",
    marginTop: SPACING.sm,
  },
  loginButtonDisabled: {
    opacity: 0.6,
  },
  loginButtonText: {
    color: COLORS.white,
    fontSize: FONT_SIZES.md,
    fontWeight: "700",
  },
  footer: {
    flexDirection: "row",
    justifyContent: "center",
    alignItems: "center",
    marginTop: SPACING["3xl"],
    gap: SPACING.sm,
  },
  footerText: {
    fontSize: FONT_SIZES.base,
    color: COLORS.textSecondary,
  },
  linkText: {
    fontSize: FONT_SIZES.base,
    color: COLORS.primary,
    fontWeight: "600",
  },
});
