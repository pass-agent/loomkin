import React, { useEffect } from "react";
import { useAuthStore } from "@/stores/authStore";
import { useRouter, useSegments } from "expo-router";

interface AuthProviderProps {
  children: React.ReactNode;
}

/**
 * AuthProvider handles:
 * 1. Hydrating auth state from secure storage on mount
 * 2. Redirecting to login when not authenticated
 * 3. Redirecting to home when authenticated and on auth screens
 */
export function AuthProvider({ children }: AuthProviderProps) {
  const { isAuthenticated, isHydrated, hydrate } = useAuthStore();
  const segments = useSegments();
  const router = useRouter();

  // Hydrate auth state on mount
  useEffect(() => {
    hydrate();
  }, [hydrate]);

  // Handle navigation based on auth state
  useEffect(() => {
    if (!isHydrated) return;

    const inAuthGroup = segments[0] === "(auth)";

    if (!isAuthenticated && !inAuthGroup) {
      // Not authenticated and not on auth screen -> redirect to login
      router.replace("/(auth)/login");
    } else if (isAuthenticated && inAuthGroup) {
      // Authenticated but on auth screen -> redirect to home
      router.replace("/(tabs)");
    }
  }, [isAuthenticated, isHydrated, segments, router]);

  return <>{children}</>;
}
