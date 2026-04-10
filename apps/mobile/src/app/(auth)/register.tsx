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

export default function RegisterScreen() {
  const router = useRouter();
  const login = useAuthStore((s) => s.login);
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [username, setUsername] = useState("");
  const [isLoading, setIsLoading] = useState(false);
  const [showPassword, setShowPassword] = useState(false);

  const handleRegister = async () => {
    if (!email.trim() || !password.trim()) {
      Alert.alert("Error", "Email and password are required.");
      return;
    }

    setIsLoading(true);
    try {
      const response = await authApi.register({
        email,
        password,
        username: username.trim() || undefined,
      });
      await login(response.token, response.user);
      router.replace("/(tabs)");
    } catch (error: unknown) {
      const message =
        error instanceof Error ? error.message : "Registration failed. Please try again.";
      Alert.alert("Registration Failed", message);
    } finally {
      setIsLoading(false);
    }
  };

  return (
    <KeyboardAvoidingView
      style={styles.container}
      behavior={Platform.OS === "ios" ? "padding" : "height"}
      testID="register-screen"
    >
      <View style={styles.content}>
        <View style={styles.header}>
          <Ionicons name="code-slash-outline" size={56} color={COLORS.primary} />
          <Text style={styles.title}>Create Account</Text>
          <Text style={styles.subtitle}>Get started with Loomkin</Text>
        </View>

        <View style={styles.form}>
          <View style={styles.inputContainer}>
            <Ionicons
              name="person-outline"
              size={20}
              color={COLORS.textMuted}
              style={styles.inputIcon}
            />
            <TextInput
              style={styles.input}
              placeholder="Username (optional)"
              placeholderTextColor={COLORS.textMuted}
              value={username}
              onChangeText={setUsername}
              autoCapitalize="none"
              autoCorrect={false}
              testID="register-username-input"
            />
          </View>

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
              testID="register-email-input"
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
              testID="register-password-input"
            />
            <Pressable
              onPress={() => setShowPassword(!showPassword)}
              testID="register-toggle-password-button"
            >
              <Ionicons
                name={showPassword ? "eye-off-outline" : "eye-outline"}
                size={20}
                color={COLORS.textMuted}
              />
            </Pressable>
          </View>

          <Pressable
            style={[styles.registerButton, isLoading && styles.registerButtonDisabled]}
            onPress={handleRegister}
            disabled={isLoading}
            testID="register-submit-button"
          >
            {isLoading ? (
              <LoadingSpinner size="small" />
            ) : (
              <Text style={styles.registerButtonText}>Create Account</Text>
            )}
          </Pressable>
        </View>

        <View style={styles.footer}>
          <Text style={styles.footerText}>Already have an account?</Text>
          <Link href="/(auth)/login" asChild>
            <Pressable testID="register-login-link-button">
              <Text style={styles.linkText}>Sign In</Text>
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
  registerButton: {
    backgroundColor: COLORS.primary,
    height: 52,
    borderRadius: 12,
    alignItems: "center",
    justifyContent: "center",
    marginTop: SPACING.sm,
  },
  registerButtonDisabled: {
    opacity: 0.6,
  },
  registerButtonText: {
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
