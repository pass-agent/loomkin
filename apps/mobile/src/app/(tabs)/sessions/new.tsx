import React, { useState, useEffect } from "react";
import { View, Text, StyleSheet, Pressable, Alert, ScrollView, TextInput } from "react-native";
import { useRouter } from "expo-router";
import { SafeAreaView } from "react-native-safe-area-context";
import { useCreateSession } from "@/hooks/useSessions";
import { ModelSelector } from "@/components/ModelSelector";
import { useModels } from "@/hooks/useModels";
import { LoadingSpinner } from "@/components/LoadingSpinner";
import { COLORS, FONT_SIZES, SPACING } from "@/lib/constants";
import type { Model } from "@/lib/types";

export default function NewSessionScreen() {
  const router = useRouter();
  const createSession = useCreateSession();
  const { data: models } = useModels();
  const [selectedModel, setSelectedModel] = useState<string | undefined>();
  const [projectPath, setProjectPath] = useState("");

  // Auto-select the first available model when models load
  useEffect(() => {
    if (!selectedModel && models && models.length > 0) {
      setSelectedModel(models[0].id);
    }
  }, [models, selectedModel]);

  // Derive the effective model: user-selected, first available, or session default
  const effectiveModel = selectedModel ?? models?.[0]?.id ?? "anthropic:claude-sonnet-4-20250514";

  const handleCreate = async () => {
    try {
      const session = await createSession.mutateAsync({
        model: effectiveModel,
        project_path: projectPath || undefined,
      });
      router.replace(`/(tabs)/sessions/${session.id}`);
    } catch (error: any) {
      const message = error?.response?.data?.error ?? error?.message ?? "Failed to create session.";
      Alert.alert("Error", message);
    }
  };

  return (
    <ScrollView style={styles.container} contentContainerStyle={styles.content}>
      <View style={styles.section}>
        <Text style={styles.sectionTitle}>Model</Text>
        <Text style={styles.sectionDescription}>Choose the AI model for this session.</Text>
        <ModelSelector
          selectedModelId={selectedModel}
          onSelect={(model: Model) => setSelectedModel(model.id)}
          testID="new-session-model-selector"
        />
      </View>

      <View style={styles.section}>
        <Text style={styles.sectionTitle}>Project Path</Text>
        <Text style={styles.sectionDescription}>
          Path to the project directory for this session.
        </Text>
        <TextInput
          style={styles.pathInput}
          placeholder="/path/to/project"
          placeholderTextColor={COLORS.textMuted}
          value={projectPath}
          onChangeText={setProjectPath}
          autoCapitalize="none"
          autoCorrect={false}
          testID="new-session-project-path-input"
        />
      </View>

      <Pressable
        style={[styles.createButton, createSession.isPending && styles.createButtonDisabled]}
        onPress={handleCreate}
        disabled={createSession.isPending}
        testID="new-session-create-button"
      >
        {createSession.isPending ? (
          <LoadingSpinner size="small" />
        ) : (
          <Text style={styles.createButtonText}>Create Session</Text>
        )}
      </Pressable>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: COLORS.background,
  },
  content: {
    padding: SPACING.xl,
    gap: SPACING["2xl"],
  },
  section: {
    gap: SPACING.sm,
  },
  sectionTitle: {
    fontSize: FONT_SIZES.md,
    fontWeight: "700",
    color: COLORS.text,
  },
  sectionDescription: {
    fontSize: FONT_SIZES.sm,
    color: COLORS.textSecondary,
    marginBottom: SPACING.sm,
  },
  pathInput: {
    backgroundColor: COLORS.surfaceLight,
    borderRadius: 8,
    paddingHorizontal: SPACING.md,
    paddingVertical: SPACING.md,
    fontSize: FONT_SIZES.base,
    color: COLORS.text,
    borderWidth: 1,
    borderColor: COLORS.border,
    fontFamily: "monospace",
  },
  createButton: {
    backgroundColor: COLORS.primary,
    height: 52,
    borderRadius: 12,
    alignItems: "center",
    justifyContent: "center",
  },
  createButtonDisabled: {
    opacity: 0.6,
  },
  createButtonText: {
    color: COLORS.white,
    fontSize: FONT_SIZES.md,
    fontWeight: "700",
  },
});
