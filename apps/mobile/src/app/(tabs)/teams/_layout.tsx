import React from "react";
import { Stack } from "expo-router";
import { COLORS } from "@/lib/constants";

export default function TeamsLayout() {
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
          title: "Teams",
          headerShown: true,
        }}
      />
      <Stack.Screen
        name="[teamId]"
        options={{
          title: "Team Details",
          headerShown: true,
        }}
      />
    </Stack>
  );
}
