import React, { useState, useMemo, useEffect } from "react";
import { Box, Text, useInput } from "ink";
import type { ModelProvider } from "../lib/types.js";
import {
  buildModelOptions,
  getCenteredWindowStart,
  getInitialModelIndex,
  getWindowStartForSelection,
} from "./modelPickerState.js";

const VISIBLE_COUNT = 12;

const OAUTH_PROVIDERS = [
  { id: "anthropic", name: "Anthropic" },
  { id: "google", name: "Google" },
  { id: "openai", name: "OpenAI" },
] as const;

interface Props {
  providers: ModelProvider[];
  currentModel: string;
  onSelect: (id: string, label: string) => void;
  onCancel: () => void;
  onOAuth: (id: string, name: string) => void;
}

export function ModelPicker({ providers, currentModel, onSelect, onCancel, onOAuth }: Props) {
  const modelOptions = useMemo(() => buildModelOptions(providers), [providers]);

  const initialIndex = useMemo(() => {
    return getInitialModelIndex(modelOptions, currentModel);
  }, [modelOptions, currentModel]);

  const [selectedIndex, setSelectedIndex] = useState(initialIndex);
  const [windowStart, setWindowStart] = useState(() =>
    getCenteredWindowStart(initialIndex, VISIBLE_COUNT),
  );
  const [oauthView, setOauthView] = useState(false);
  const [oauthIndex, setOauthIndex] = useState(0);

  useEffect(() => {
    setSelectedIndex(initialIndex);
    setWindowStart(getCenteredWindowStart(initialIndex, VISIBLE_COUNT));
  }, [initialIndex]);

  useEffect(() => {
    setWindowStart((ws) => {
      return getWindowStartForSelection(ws, selectedIndex, VISIBLE_COUNT);
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
      setSelectedIndex((i) => Math.max(0, i - 1));
      return;
    }
    if (key.downArrow) {
      setSelectedIndex((i) => Math.min(modelOptions.length - 1, i + 1));
      return;
    }
    if (key.return) {
      const item = modelOptions[selectedIndex];
      if (item) {
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
          Connect an OAuth provider <Text dimColor>(↑↓ navigate · Enter connect · Esc back)</Text>
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

  if (modelOptions.length === 0) {
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
        Select a model <Text dimColor>(↑↓ · Enter · Esc cancel · ctrl+o oauth)</Text>
      </Text>
      {windowStart > 0 && <Text dimColor> ▲ {windowStart} more above</Text>}
      {modelOptions.slice(windowStart, windowStart + VISIBLE_COUNT).map((item, offset) => {
        const i = windowStart + offset;
        const isSelected = i === selectedIndex;
        const isCurrent = item.id === currentModel;
        const previous = modelOptions[i - 1];
        const showProviderHeader = i === 0 || previous?.providerId !== item.providerId;

        return (
          <React.Fragment key={`${item.providerId}:${item.id}`}>
            {showProviderHeader && <Text dimColor>── {item.providerName} ──</Text>}
            <Box gap={1}>
              <Text color={isSelected ? "blue" : undefined} bold={isSelected}>
                {isSelected ? "▸" : " "}
                {isCurrent ? "✔" : " "}
                {item.label}
              </Text>
              {item.context && <Text dimColor>{item.context}</Text>}
            </Box>
          </React.Fragment>
        );
      })}
      {windowStart + VISIBLE_COUNT < modelOptions.length && (
        <Text dimColor> ▼ {modelOptions.length - windowStart - VISIBLE_COUNT} more below</Text>
      )}
    </Box>
  );
}
