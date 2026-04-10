import React, { useState } from "react";
import { View, Text, StyleSheet, Pressable, Modal, SectionList } from "react-native";
import { Ionicons } from "@expo/vector-icons";
import { COLORS, FONT_SIZES, SPACING } from "@/lib/constants";
import { useModels, useModelProviders } from "@/hooks/useModels";
import type { Model } from "@/lib/types";

interface ModelSelectorProps {
  selectedModelId: string | undefined;
  onSelect: (model: Model) => void;
  testID?: string;
}

export function ModelSelector({
  selectedModelId,
  onSelect,
  testID = "model-selector",
}: ModelSelectorProps) {
  const [isOpen, setIsOpen] = useState(false);
  const { data: models, isLoading } = useModels();
  const { data: providers } = useModelProviders();

  const selectedModel = models?.find((m) => m.id === selectedModelId);

  const sections = React.useMemo(() => {
    if (providers) {
      const filtered = providers
        .filter((p) => p.models.length > 0)
        .map((p) => ({
          title: p.name,
          data: p.models,
        }));
      if (filtered.length > 0) return filtered;
    }
    // Fallback: flat model list as a single section
    if (models && models.length > 0) {
      return [{ title: "Available Models", data: models }];
    }
    return [];
  }, [providers, models]);

  const handleSelect = (model: Model) => {
    onSelect(model);
    setIsOpen(false);
  };

  return (
    <>
      <Pressable
        style={styles.trigger}
        onPress={() => setIsOpen(true)}
        testID={`${testID}-trigger-button`}
      >
        <Ionicons name="cube-outline" size={16} color={COLORS.primaryLight} />
        <Text style={styles.triggerText} numberOfLines={1}>
          {selectedModel?.label ?? selectedModelId ?? "Select model"}
        </Text>
        <Ionicons name="chevron-down" size={14} color={COLORS.textMuted} />
      </Pressable>

      <Modal
        visible={isOpen}
        transparent
        animationType="slide"
        onRequestClose={() => setIsOpen(false)}
      >
        <Pressable
          style={styles.overlay}
          onPress={() => setIsOpen(false)}
          testID={`${testID}-overlay-button`}
        >
          <View style={styles.modalContent}>
            <View style={styles.modalHeader}>
              <Text style={styles.modalTitle}>Select Model</Text>
              <Pressable onPress={() => setIsOpen(false)} testID={`${testID}-close-button`}>
                <Ionicons name="close" size={24} color={COLORS.text} />
              </Pressable>
            </View>

            {isLoading ? (
              <Text style={styles.loadingText}>Loading models...</Text>
            ) : (
              <SectionList
                sections={sections}
                keyExtractor={(item) => item.id}
                renderSectionHeader={({ section }) => (
                  <View style={styles.sectionHeader} testID={`${testID}-provider-${section.title}`}>
                    <Text style={styles.sectionHeaderText}>{section.title}</Text>
                  </View>
                )}
                renderItem={({ item }) => (
                  <Pressable
                    style={[styles.modelItem, item.id === selectedModelId && styles.selectedItem]}
                    onPress={() => handleSelect(item)}
                    testID={`${testID}-model-${item.id}-button`}
                  >
                    <View style={styles.modelInfo}>
                      <Text style={styles.modelLabel}>{item.label}</Text>
                      <Text style={styles.modelId}>{item.id}</Text>
                    </View>
                    {item.context && <Text style={styles.contextBadge}>{item.context}</Text>}
                    {item.id === selectedModelId && (
                      <Ionicons name="checkmark-circle" size={20} color={COLORS.primary} />
                    )}
                  </Pressable>
                )}
              />
            )}
          </View>
        </Pressable>
      </Modal>
    </>
  );
}

const styles = StyleSheet.create({
  trigger: {
    flexDirection: "row",
    alignItems: "center",
    gap: SPACING.xs,
    backgroundColor: COLORS.surfaceLight,
    paddingHorizontal: SPACING.md,
    paddingVertical: SPACING.sm,
    borderRadius: 8,
    borderWidth: 1,
    borderColor: COLORS.border,
  },
  triggerText: {
    fontSize: FONT_SIZES.sm,
    color: COLORS.text,
    flex: 1,
  },
  overlay: {
    flex: 1,
    backgroundColor: "rgba(0, 0, 0, 0.5)",
    justifyContent: "flex-end",
  },
  modalContent: {
    backgroundColor: COLORS.surface,
    borderTopLeftRadius: 20,
    borderTopRightRadius: 20,
    maxHeight: "70%",
    paddingBottom: 40,
  },
  modalHeader: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    padding: SPACING.lg,
    borderBottomWidth: 1,
    borderBottomColor: COLORS.border,
  },
  modalTitle: {
    fontSize: FONT_SIZES.lg,
    fontWeight: "700",
    color: COLORS.text,
  },
  loadingText: {
    padding: SPACING.xl,
    textAlign: "center",
    color: COLORS.textSecondary,
  },
  modelItem: {
    flexDirection: "row",
    alignItems: "center",
    padding: SPACING.lg,
    borderBottomWidth: 1,
    borderBottomColor: COLORS.border,
    gap: SPACING.md,
  },
  selectedItem: {
    backgroundColor: COLORS.surfaceLight,
  },
  modelInfo: {
    flex: 1,
    gap: 2,
  },
  modelLabel: {
    fontSize: FONT_SIZES.base,
    fontWeight: "600",
    color: COLORS.text,
  },
  modelId: {
    fontSize: FONT_SIZES.xs,
    color: COLORS.textMuted,
    fontFamily: "monospace",
  },
  contextBadge: {
    fontSize: FONT_SIZES.xs,
    color: COLORS.textSecondary,
    backgroundColor: COLORS.background,
    paddingHorizontal: SPACING.sm,
    paddingVertical: 2,
    borderRadius: 4,
  },
  sectionHeader: {
    backgroundColor: COLORS.background,
    paddingHorizontal: SPACING.lg,
    paddingVertical: SPACING.sm,
  },
  sectionHeaderText: {
    fontSize: FONT_SIZES.xs,
    fontWeight: "700",
    color: COLORS.textMuted,
    textTransform: "uppercase",
    letterSpacing: 0.5,
  },
});
