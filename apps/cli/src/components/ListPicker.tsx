import React, { useState, useEffect } from "react";
import { Box, Text, useInput } from "ink";
import type { ListPickerOptions } from "../commands/registry.js";

const VISIBLE_COUNT = 8;

export function ListPicker({ title, items, currentValue, onSelect, onCancel }: ListPickerOptions) {
  const initialIndex = Math.max(0, items.findIndex((i) => i.value === currentValue));
  const [selectedIndex, setSelectedIndex] = useState(initialIndex);
  const [windowStart, setWindowStart] = useState(() =>
    Math.max(0, initialIndex - Math.floor(VISIBLE_COUNT / 2)),
  );

  useEffect(() => {
    setWindowStart((ws) => {
      if (selectedIndex < ws) return selectedIndex;
      if (selectedIndex >= ws + VISIBLE_COUNT) return selectedIndex - VISIBLE_COUNT + 1;
      return ws;
    });
  }, [selectedIndex]);

  useInput((input, key) => {
    if (key.upArrow) {
      setSelectedIndex((i) => Math.max(0, i - 1));
      return;
    }
    if (key.downArrow) {
      setSelectedIndex((i) => Math.min(items.length - 1, i + 1));
      return;
    }
    if (key.return) {
      const item = items[selectedIndex];
      if (item) onSelect(item.value, item.label);
      return;
    }
    if (key.escape || (key.ctrl && input === "c")) {
      onCancel();
      return;
    }
  });

  return (
    <Box flexDirection="column" borderStyle="single" borderColor="cyan" paddingX={1}>
      <Text bold color="cyan">
        {title}{" "}
        <Text dimColor>(↑↓ · Enter · Esc cancel)</Text>
      </Text>
      {windowStart > 0 && <Text dimColor>  ▲ {windowStart} more above</Text>}
      {items.slice(windowStart, windowStart + VISIBLE_COUNT).map((item, offset) => {
        const i = windowStart + offset;
        const isSelected = i === selectedIndex;
        const isCurrent = item.value === currentValue;
        return (
          <Box key={item.value} gap={1}>
            <Text color={isSelected ? "cyan" : undefined} bold={isSelected}>
              {isSelected ? "▸" : " "}
              {isCurrent ? "✔" : " "} {item.label}
            </Text>
            {item.hint && <Text dimColor>{item.hint}</Text>}
          </Box>
        );
      })}
      {windowStart + VISIBLE_COUNT < items.length && (
        <Text dimColor>  ▼ {items.length - windowStart - VISIBLE_COUNT} more below</Text>
      )}
    </Box>
  );
}
