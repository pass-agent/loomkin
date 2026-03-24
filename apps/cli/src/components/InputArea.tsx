import React, { useState, useCallback, useRef } from "react";
import { Box, Text, useInput } from "ink";
import TextInput from "ink-text-input";
import { useStore } from "zustand";
import { CommandPalette } from "./CommandPalette.js";
import { resolve, getCompletions } from "../commands/registry.js";
import type { CommandContext } from "../commands/registry.js";
import { useAppStore } from "../stores/appStore.js";
import {
  findAction,
  defaultKeymap,
  getVimKeymap,
} from "../lib/keymap.js";

interface Props {
  onSubmit: (text: string) => void;
  commandContext: CommandContext;
}

export function InputArea({ onSubmit, commandContext }: Props) {
  const [value, setValue] = useState("");
  const [history, setHistory] = useState<string[]>([]);
  const [historyIndex, setHistoryIndex] = useState(-1);
  const [paletteIndex, setPaletteIndex] = useState(0);
  const [cursor, setCursor] = useState(0);
  const undoStack = useRef<string[]>([]);

  const keybindMode = useStore(useAppStore, (s) => s.keybindMode);
  const vimMode = useStore(useAppStore, (s) => s.vimMode);
  const setVimMode = useStore(useAppStore, (s) => s.setVimMode);

  const isVim = keybindMode === "vim";
  const isNormal = isVim && vimMode === "normal";
  const isInsert = isVim && vimMode === "insert";

  const showPalette = value.startsWith("/") && value.indexOf(" ") === -1;
  const completions = showPalette ? getCompletions(value) : [];

  // Vim helper: find next word boundary
  const nextWordBoundary = (str: string, pos: number): number => {
    let i = pos;
    // Skip current word chars
    while (i < str.length && str[i] !== " ") i++;
    // Skip spaces
    while (i < str.length && str[i] === " ") i++;
    return i;
  };

  // Vim helper: find previous word boundary
  const prevWordBoundary = (str: string, pos: number): number => {
    let i = pos - 1;
    // Skip spaces
    while (i > 0 && str[i] === " ") i--;
    // Skip word chars
    while (i > 0 && str[i - 1] !== " ") i--;
    return Math.max(0, i);
  };

  const handleVimAction = useCallback(
    (action: string) => {
      switch (action) {
        // Mode transitions
        case "vim:insert":
          setVimMode("insert");
          break;
        case "vim:append":
          setVimMode("insert");
          setCursor((c) => Math.min(c + 1, value.length));
          break;
        case "vim:appendEnd":
          setVimMode("insert");
          setCursor(value.length);
          break;
        case "vim:insertStart":
          setVimMode("insert");
          setCursor(0);
          break;
        case "vim:openBelow":
          setVimMode("insert");
          break;
        case "vim:normal":
          setVimMode("normal");
          setCursor((c) => Math.max(0, Math.min(c, value.length - 1)));
          break;

        // Navigation
        case "vim:left":
          setCursor((c) => Math.max(0, c - 1));
          break;
        case "vim:right":
          setCursor((c) => Math.min(value.length - 1, c + 1));
          break;
        case "vim:wordForward":
          setCursor(nextWordBoundary(value, cursor));
          break;
        case "vim:wordBackward":
          setCursor(prevWordBoundary(value, cursor));
          break;
        case "vim:lineStart":
          setCursor(0);
          break;
        case "vim:lineEnd":
          setCursor(Math.max(0, value.length - 1));
          break;

        // Editing
        case "vim:deleteChar":
          if (value.length > 0 && cursor < value.length) {
            undoStack.current.push(value);
            setValue(value.slice(0, cursor) + value.slice(cursor + 1));
            setCursor((c) =>
              Math.min(c, Math.max(0, value.length - 2)),
            );
          }
          break;
        case "vim:undo":
          if (undoStack.current.length > 0) {
            const prev = undoStack.current.pop()!;
            setValue(prev);
            setCursor(Math.min(cursor, prev.length - 1));
          }
          break;

        // Submit
        case "submit":
          if (value.trim()) {
            handleSubmit(value);
          }
          break;

        // Command line mode (treat : as / for slash commands)
        case "vim:command":
          setValue("/");
          setVimMode("insert");
          setCursor(1);
          break;

        // History search
        case "vim:searchHistory":
          // Navigate backwards through history
          if (history.length > 0) {
            const idx =
              historyIndex === -1
                ? history.length - 1
                : Math.max(0, historyIndex - 1);
            setHistoryIndex(idx);
            setValue(history[idx]);
            setCursor(0);
          }
          break;
      }
    },
    [value, cursor, history, historyIndex, setVimMode],
  );

  useInput((input, key) => {
    // Command palette navigation (works in all modes)
    if (showPalette) {
      if (key.upArrow) {
        setPaletteIndex((i) => Math.max(0, i - 1));
        return;
      }
      if (key.downArrow) {
        setPaletteIndex((i) => Math.min(completions.length - 1, i + 1));
        return;
      }
      if (key.tab) {
        const selected = completions[paletteIndex];
        if (selected) {
          setValue(`/${selected.name} `);
          setPaletteIndex(0);
          if (isVim) setVimMode("insert");
        }
        return;
      }
    }

    // Vim normal mode: intercept all input
    if (isNormal) {
      const keymap = getVimKeymap("normal");
      const action = findAction(
        { key: key.escape ? "escape" : input || key.return ? "return" : "", ctrl: key.ctrl, shift: key.shift, meta: key.meta },
        keymap,
      );

      // Handle the raw input character for vim normal bindings
      const charAction = findAction(
        { key: input, shift: key.shift },
        keymap,
      );

      if (action && action !== "submit") {
        handleVimAction(action);
        return;
      }
      if (charAction) {
        handleVimAction(charAction);
        return;
      }

      // Enter in normal mode submits
      if (key.return) {
        handleVimAction("submit");
        return;
      }

      // Global ctrl bindings
      const globalAction = findAction(
        { key: input, ctrl: key.ctrl },
        defaultKeymap,
      );
      if (globalAction) return; // Let parent handle global bindings

      return; // Block all other input in normal mode
    }

    // Vim insert mode: only intercept escape and ctrl bindings
    if (isInsert) {
      if (key.escape) {
        handleVimAction("vim:normal");
        return;
      }
      const keymap = getVimKeymap("insert");
      const action = findAction(
        { key: input, ctrl: key.ctrl },
        keymap,
      );
      if (action === "vim:normal") {
        handleVimAction("vim:normal");
        return;
      }
      // Fall through to default text input handling
    }

    // Default mode: history navigation (only when not in palette)
    if (!showPalette && key.upArrow && history.length > 0) {
      const newIdx =
        historyIndex === -1 ? history.length - 1 : Math.max(0, historyIndex - 1);
      setHistoryIndex(newIdx);
      setValue(history[newIdx]);
      return;
    }
    if (!showPalette && key.downArrow && historyIndex !== -1) {
      const newIdx = historyIndex + 1;
      if (newIdx >= history.length) {
        setHistoryIndex(-1);
        setValue("");
      } else {
        setHistoryIndex(newIdx);
        setValue(history[newIdx]);
      }
    }
  });

  const handleSubmit = useCallback(
    (text: string) => {
      const trimmed = text.trim();
      if (!trimmed) return;

      // Save undo state
      undoStack.current = [];

      // Add to history
      setHistory((prev) => [...prev.slice(-100), trimmed]);
      setHistoryIndex(-1);
      setValue("");
      setCursor(0);
      setPaletteIndex(0);

      // Return to normal mode after submit in vim
      if (isVim) setVimMode("normal");

      // Check if it's a slash command
      const result = resolve(trimmed);
      if (result) {
        result.command.handler(result.args, commandContext);
        return;
      }

      onSubmit(trimmed);
    },
    [onSubmit, commandContext, isVim, setVimMode],
  );

  // Prompt indicator
  const promptChar = isVim
    ? isNormal
      ? ":"
      : isInsert
        ? ">"
        : "/"
    : ">";

  const promptColor = isVim
    ? isNormal
      ? "yellow"
      : isInsert
        ? "green"
        : "cyan"
    : "blue";

  const modeHint = isVim
    ? isNormal
      ? " NORMAL"
      : isInsert
        ? " INSERT"
        : " COMMAND"
    : "";

  const placeholder = isNormal
    ? "Press i to type, : for commands, Enter to send..."
    : "Send a message or type / for commands...";

  return (
    <Box flexDirection="column">
      {showPalette && completions.length > 0 && (
        <CommandPalette input={value} selectedIndex={paletteIndex} />
      )}
      <Box borderStyle="single" borderColor={promptColor} paddingX={1}>
        <Text color={promptColor} bold>
          {promptChar}{" "}
        </Text>
        {isNormal ? (
          // In normal mode, show value as static text with cursor highlight
          <Box flexGrow={1}>
            <Text>
              {value.length > 0 ? (
                <>
                  {value.slice(0, cursor)}
                  <Text inverse>{value[cursor] ?? " "}</Text>
                  {value.slice(cursor + 1)}
                </>
              ) : (
                <Text dimColor>{placeholder}</Text>
              )}
            </Text>
          </Box>
        ) : (
          <TextInput
            value={value}
            onChange={(v) => {
              if (isVim && value.length > 0) undoStack.current.push(value);
              setValue(v);
              setCursor(v.length);
              setPaletteIndex(0);
            }}
            onSubmit={handleSubmit}
            placeholder={placeholder}
          />
        )}
        {modeHint && (
          <Text color={promptColor} dimColor>
            {modeHint}
          </Text>
        )}
      </Box>
    </Box>
  );
}
