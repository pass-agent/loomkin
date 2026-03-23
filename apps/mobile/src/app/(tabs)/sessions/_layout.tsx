import React from "react";
import { Stack } from "expo-router";
import { COLORS } from "@/lib/constants";

export default function SessionsLayout() {
  return (
    <Stack
      screenOptions={{
        headerStyle: {
          backgroundColor: COLORS.surface,
        },
        headerTintColor: COLORS.text,
        headerTitleStyle: {
          fontWeight: "700",
        },
        contentStyle: {
          backgroundColor: COLORS.background,
        },
      }}
    >
      <Stack.Screen
        name="index"
        options={{
          title: "Sessions",
          headerShown: true,
        }}
      />
      <Stack.Screen
        name="[id]"
        options={{
          title: "Session",
          headerShown: true,
        }}
      />
      <Stack.Screen
        name="new"
        options={{
          title: "New Session",
          headerShown: true,
          presentation: "modal",
        }}
      />
    </Stack>
  );
}
