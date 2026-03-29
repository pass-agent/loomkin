import React, { useState, useMemo, useEffect } from "react";
import { Box, Text, useInput } from "ink";
import type { ModelProvider } from "../lib/types.js";

const VISIBLE_COUNT = 12;

const OAUTH_PROVIDERS = [
  { id: "anthropic", name: "Anthropic" },
  { id: "google", name: "Google" },
  { id: "openai", name: "OpenAI" },
] as const;

type FlatItem =
  | { kind: "separator"; label: string }
  | { kind: "model"; id: string; label: string; context?: string };

interface Props {
  providers: ModelProvider[];
  currentModel: string;
  onSelect: (id: string, label: string) => void;
  onCancel: () => void;
  onOAuth: (id: string, name: string) => void;
}

function buildFlatItems(providers: ModelProvider[]): FlatItem[] {
  const items: FlatItem[] = [];
  for (const provider of providers) {
    if (provider.models.length === 0) continue;
    items.push({ kind: "separator", label: `── ${provider.name} ──` });
    for (const model of provider.models) {
      items.push({ kind: "model", id: model.id, label: model.label, context: model.context ?? undefined });
    }
  }
  return items;
}

function firstModelIndex(items: FlatItem[]): number {
  return items.findIndex((item) => item.kind === "model");
}

function prevModelIndex(items: FlatItem[], from: number): number {
  for (let i = from - 1; i >= 0; i--) {
    if (items[i].kind === "model") return i;
  }
  return from;
}

function nextModelIndex(items: FlatItem[], from: number): number {
  for (let i = from + 1; i < items.length; i++) {
    if (items[i].kind === "model") return i;
  }
  return from;
}

export function ModelPicker({ providers, currentModel, onSelect, onCancel, onOAuth }: Props) {
  const flatItems = useMemo(() => buildFlatItems(providers), [providers]);

  const initialIndex = useMemo(() => {
    const currentIdx = flatItems.findIndex(
      (item) => item.kind === "model" && item.id === currentModel,
    );
    return currentIdx !== -1 ? currentIdx : firstModelIndex(flatItems);
  }, [flatItems, currentModel]);

  const [selectedIndex, setSelectedIndex] = useState(initialIndex);
  const [windowStart, setWindowStart] = useState(() => Math.max(0, initialIndex - Math.floor(VISIBLE_COUNT / 2)));
  const [oauthView, setOauthView] = useState(false);
  const [oauthIndex, setOauthIndex] = useState(0);

  // Keep selected item within the visible window
  useEffect(() => {
    setWindowStart((ws) => {
      if (selectedIndex < ws) return selectedIndex;
      if (selectedIndex >= ws + VISIBLE_COUNT) return selectedIndex - VISIBLE_COUNT + 1;
      return ws;
    });
  }, [selectedIndex]);

  useInput((input, key) => {
    // ctrl+o toggles between model list and OAuth provider picker
    if (key.ctrl && input === "o") {
      setOauthView((v) => !v);
      setOauthIndex(0);
      return;
    }

    if (oauthView) {
      if (key.upArrow) {
        setOauthIndex((i) => Math.max(0, i - 1));
        return;
      }
      if (key.downArrow) {
        setOauthIndex((i) => Math.min(OAUTH_PROVIDERS.length - 1, i + 1));
        return;
      }
      if (key.return) {
        const prov = OAUTH_PROVIDERS[oauthIndex];
        if (prov) onOAuth(prov.id, prov.name);
        return;
      }
      if (key.escape) {
        setOauthView(false);
        return;
      }
      return;
    }

    if (key.upArrow) {
      setSelectedIndex((i) => prevModelIndex(flatItems, i));
      return;
    }
    if (key.downArrow) {
      setSelectedIndex((i) => nextModelIndex(flatItems, i));
      return;
    }
    if (key.return) {
      const item = flatItems[selectedIndex];
      if (item?.kind === "model") {
        onSelect(item.id, item.label);
      }
      return;
    }
    if (key.escape || (key.ctrl && input === "c")) {
      onCancel();
      return;
    }
  });

  if (oauthView) {
    return (
      <Box flexDirection="column" borderStyle="single" borderColor="magenta" paddingX={1}>
        <Text bold color="magenta">
          Connect an OAuth provider{" "}
          <Text dimColor>(↑↓ navigate · Enter connect · Esc back)</Text>
        </Text>
        {OAUTH_PROVIDERS.map((prov, i) => (
          <Box key={prov.id} gap={1}>
            <Text color={i === oauthIndex ? "magenta" : undefined} bold={i === oauthIndex}>
              {i === oauthIndex ? "▸" : " "} {prov.name}
            </Text>
          </Box>
        ))}
      </Box>
    );
  }

  if (flatItems.length === 0) {
    return (
      <Box flexDirection="column" borderStyle="single" borderColor="gray" paddingX={1}>
        <Text dimColor>No models available — connect a provider first</Text>
        <Text dimColor>ctrl+o to connect via OAuth</Text>
      </Box>
    );
  }

  return (
    <Box flexDirection="column" borderStyle="single" borderColor="blue" paddingX={1}>
      <Text bold color="blue">
        Select a model{" "}
        <Text dimColor>(↑↓ · Enter · Esc cancel · ctrl+o oauth)</Text>
      </Text>
      {windowStart > 0 && (
        <Text dimColor>  ▲ {windowStart} more above</Text>
      )}
      {flatItems.slice(windowStart, windowStart + VISIBLE_COUNT).map((item, offset) => {
        const i = windowStart + offset;
        if (item.kind === "separator") {
          return (
            <Text key={i} dimColor>
              {item.label}
            </Text>
          );
        }

        const isSelected = i === selectedIndex;
        const isCurrent = item.id === currentModel;

        return (
          <Box key={item.id} gap={1}>
            <Text color={isSelected ? "blue" : undefined} bold={isSelected}>
              {isSelected ? "▸" : " "}
              {isCurrent ? "✔" : " "}
              {item.label}
            </Text>
            {item.context && (
              <Text dimColor>{item.context}</Text>
            )}
          </Box>
        );
      })}
      {windowStart + VISIBLE_COUNT < flatItems.length && (
        <Text dimColor>  ▼ {flatItems.length - windowStart - VISIBLE_COUNT} more below</Text>
      )}
    </Box>
  );
}
