import React, { useMemo, useState } from "react";
import {
  View,
  Text,
  StyleSheet,
  ScrollView,
  Pressable,
  Switch,
  TextInput,
  Alert,
} from "react-native";
import { useLocalSearchParams, Stack } from "expo-router";
import { useSettings, useUpdateSettings } from "@/hooks/useSettings";
import { LoadingSpinner } from "@/components/LoadingSpinner";
import { COLORS, FONT_SIZES, SPACING } from "@/lib/constants";
import type { Setting } from "@/lib/types";

export default function SettingSectionScreen() {
  const { section } = useLocalSearchParams<{ section: string }>();
  const decodedSection = decodeURIComponent(section ?? "");
  const { data: settings, isLoading } = useSettings();
  const updateSettings = useUpdateSettings();
  const [pendingChanges, setPendingChanges] = useState<Record<string, unknown>>({});

  const sectionSettings = useMemo(() => {
    if (!settings) return [];
    return settings.filter((s) => (s.section || "General") === decodedSection);
  }, [settings, decodedSection]);

  const handleSettingChange = (key: string, value: unknown) => {
    setPendingChanges((prev) => ({ ...prev, [key]: value }));
  };

  const handleSave = async () => {
    if (Object.keys(pendingChanges).length === 0) return;

    try {
      await updateSettings.mutateAsync(pendingChanges);
      setPendingChanges({});
      Alert.alert("Success", "Settings saved.");
    } catch (error: any) {
      Alert.alert("Error", error?.message ?? "Failed to save settings.");
    }
  };

  const getCurrentValue = (setting: Setting) => {
    return pendingChanges[setting.key] ?? setting.value ?? setting.default;
  };

  const renderSettingInput = (setting: Setting) => {
    const currentValue = getCurrentValue(setting);

    switch (setting.type) {
      case "boolean":
        return (
          <Switch
            value={!!currentValue}
            onValueChange={(val) => handleSettingChange(setting.key, val)}
            trackColor={{
              false: COLORS.surfaceLight,
              true: COLORS.primary,
            }}
            thumbColor={COLORS.white}
            testID={`settings-${setting.key}-switch`}
          />
        );

      case "select":
        return (
          <View style={styles.selectContainer}>
            {setting.options?.map((option) => (
              <Pressable
                key={option}
                style={[styles.selectOption, currentValue === option && styles.selectOptionActive]}
                onPress={() => handleSettingChange(setting.key, option)}
                testID={`settings-${setting.key}-${option}-button`}
              >
                <Text
                  style={[
                    styles.selectOptionText,
                    currentValue === option && styles.selectOptionTextActive,
                  ]}
                >
                  {option}
                </Text>
              </Pressable>
            ))}
          </View>
        );

      case "string":
      case "number":
      default:
        return (
          <TextInput
            style={styles.settingInput}
            value={String(currentValue ?? "")}
            onChangeText={(val) =>
              handleSettingChange(setting.key, setting.type === "number" ? Number(val) : val)
            }
            keyboardType={setting.type === "number" ? "numeric" : "default"}
            placeholderTextColor={COLORS.textMuted}
            testID={`settings-${setting.key}-input`}
          />
        );
    }
  };

  return (
    <>
      <Stack.Screen
        options={{
          title: decodedSection,
        }}
      />

      <ScrollView style={styles.container} contentContainerStyle={styles.content}>
        {isLoading ? (
          <LoadingSpinner message="Loading settings..." />
        ) : (
          sectionSettings.map((setting) => (
            <View key={setting.key} style={styles.settingRow}>
              <View style={styles.settingInfo}>
                <Text style={styles.settingLabel}>{setting.label}</Text>
                {setting.description && (
                  <Text style={styles.settingDescription}>{setting.description}</Text>
                )}
              </View>
              {renderSettingInput(setting)}
            </View>
          ))
        )}

        {/* Save Button */}
        {Object.keys(pendingChanges).length > 0 && (
          <Pressable
            style={styles.saveButton}
            onPress={handleSave}
            disabled={updateSettings.isPending}
            testID="settings-save-button"
          >
            {updateSettings.isPending ? (
              <LoadingSpinner size="small" />
            ) : (
              <Text style={styles.saveButtonText}>Save Changes</Text>
            )}
          </Pressable>
        )}
      </ScrollView>
    </>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: COLORS.background,
  },
  content: {
    padding: SPACING.lg,
    paddingBottom: SPACING["4xl"],
    gap: SPACING.md,
  },
  settingRow: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    backgroundColor: COLORS.surface,
    borderRadius: 12,
    padding: SPACING.lg,
    borderWidth: 1,
    borderColor: COLORS.border,
    gap: SPACING.md,
  },
  settingInfo: {
    flex: 1,
    gap: 2,
  },
  settingLabel: {
    fontSize: FONT_SIZES.base,
    fontWeight: "600",
    color: COLORS.text,
  },
  settingDescription: {
    fontSize: FONT_SIZES.xs,
    color: COLORS.textMuted,
    lineHeight: 16,
  },
  settingInput: {
    backgroundColor: COLORS.surfaceLight,
    borderRadius: 8,
    paddingHorizontal: SPACING.md,
    paddingVertical: SPACING.sm,
    fontSize: FONT_SIZES.sm,
    color: COLORS.text,
    minWidth: 100,
    textAlign: "right",
    borderWidth: 1,
    borderColor: COLORS.border,
  },
  selectContainer: {
    flexDirection: "row",
    gap: SPACING.xs,
    flexWrap: "wrap",
    justifyContent: "flex-end",
  },
  selectOption: {
    paddingHorizontal: SPACING.md,
    paddingVertical: SPACING.xs,
    borderRadius: 16,
    backgroundColor: COLORS.surfaceLight,
    borderWidth: 1,
    borderColor: COLORS.border,
  },
  selectOptionActive: {
    backgroundColor: COLORS.primary,
    borderColor: COLORS.primary,
  },
  selectOptionText: {
    fontSize: FONT_SIZES.xs,
    color: COLORS.textSecondary,
    fontWeight: "600",
  },
  selectOptionTextActive: {
    color: COLORS.white,
  },
  saveButton: {
    backgroundColor: COLORS.primary,
    height: 48,
    borderRadius: 12,
    alignItems: "center",
    justifyContent: "center",
    marginTop: SPACING.md,
  },
  saveButtonText: {
    color: COLORS.white,
    fontSize: FONT_SIZES.md,
    fontWeight: "700",
  },
});
