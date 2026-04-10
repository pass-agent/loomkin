import type { ModelProvider } from "../lib/types.js";

export interface ModelPickerOption {
  providerId: string;
  providerName: string;
  id: string;
  label: string;
  context?: string;
}

export function buildModelOptions(providers: ModelProvider[]): ModelPickerOption[] {
  return providers.flatMap((provider) =>
    provider.models.map((model) => ({
      providerId: provider.id,
      providerName: provider.name,
      id: model.id,
      label: model.label,
      context: model.context ?? undefined,
    })),
  );
}

export function getInitialModelIndex(options: ModelPickerOption[], currentModel: string): number {
  const currentIndex = options.findIndex((item) => item.id === currentModel);
  return currentIndex >= 0 ? currentIndex : 0;
}

export function getCenteredWindowStart(selectedIndex: number, visibleCount: number): number {
  return Math.max(0, selectedIndex - Math.floor(visibleCount / 2));
}

export function getWindowStartForSelection(
  currentWindowStart: number,
  selectedIndex: number,
  visibleCount: number,
): number {
  if (selectedIndex < currentWindowStart) return selectedIndex;
  if (selectedIndex >= currentWindowStart + visibleCount) {
    return Math.max(0, selectedIndex - visibleCount + 1);
  }

  return currentWindowStart;
}
