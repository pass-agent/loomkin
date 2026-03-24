import React, { useCallback, useMemo } from "react";
import { Box, useApp, useInput } from "ink";
import { useStore } from "zustand";
import { StatusBar } from "./components/StatusBar.js";
import { MessageList } from "./components/MessageList.js";
import { SplitPaneLayout } from "./components/SplitPaneLayout.js";
import { ErrorBanner } from "./components/ErrorBanner.js";
import { PermissionPrompt } from "./components/PermissionPrompt.js";
import { AskUserPrompt } from "./components/AskUserPrompt.js";
import { InputArea } from "./components/InputArea.js";
import { useConnection } from "./hooks/useConnection.js";
import { useSessionChannel } from "./hooks/useSessionChannel.js";
import { useAgentChannel } from "./hooks/useAgentChannel.js";
import { useAppStore } from "./stores/appStore.js";
import { useSessionStore } from "./stores/sessionStore.js";
import { usePaneStore } from "./stores/paneStore.js";
import { reconnectSocket } from "./lib/socket.js";
import { defaultKeymap, matchKey } from "./lib/keymap.js";
import type { CommandContext } from "./commands/registry.js";
import type { Message } from "./lib/types.js";

// Register all slash commands (side-effect imports)
import "./commands/help.js";
import "./commands/clear.js";
import "./commands/mode.js";
import "./commands/model.js";
import "./commands/compact.js";
import "./commands/session.js";
import "./commands/quit.js";
import "./commands/mcp.js";
import "./commands/settings.js";
import "./commands/status.js";
import "./commands/agents.js";
import "./commands/backlog.js";
import "./commands/files.js";
import "./commands/diff.js";
import "./commands/logs.js";
import "./commands/spawn.js";
import "./commands/share.js";
import "./commands/export.js";
import "./commands/theme.js";
import "./commands/prompt.js";
import "./commands/keybinds.js";

let messageCounter = 0;

export function App() {
  const { exit } = useApp();
  const { isConnected } = useConnection();
  const {
    messages,
    isStreaming,
    pendingToolCalls,
    pendingPermissions,
    pendingQuestions,
    sendMessage,
    respondPermission,
    answerQuestion,
  } = useSessionChannel();

  // Subscribe to agent status updates
  useAgentChannel();

  const appState = useStore(useAppStore);
  const sessionState = useStore(useSessionStore);
  const errors = useStore(useAppStore, (s) => s.errors);
  const splitMode = useStore(usePaneStore, (s) => s.splitMode);

  const latestError = errors.length > 0 ? errors[errors.length - 1] : null;

  // Handle error banner key shortcuts
  useInput((input) => {
    if (!latestError) return;
    if (input === "d") {
      useAppStore.getState().dismissError(errors.length - 1);
    }
    if (input === "r" && latestError.recoverable) {
      useAppStore.getState().dismissError(errors.length - 1);
      if (latestError.action === "retry") {
        reconnectSocket();
      }
    }
  });

  // Handle split-pane keybindings
  useInput((input, key) => {
    const binding = defaultKeymap.find((b) => matchKey({ key: input, ...key }, b));
    if (!binding) return;

    const pane = usePaneStore.getState();

    switch (binding.action) {
      case "quit":
        exit();
        break;
      case "clear":
        useSessionStore.getState().clearMessages();
        break;
      case "toggleSplit":
        pane.toggleSplitMode();
        break;
      case "switchFocus":
        if (pane.splitMode) {
          pane.setFocusedPane(pane.focusedPane === "left" ? "right" : "left");
        }
        break;
      case "nextAgent":
        if (pane.splitMode && pane.focusedPane === "right") pane.cycleAgent(1);
        break;
      case "prevAgent":
        if (pane.splitMode && pane.focusedPane === "right") pane.cycleAgent(-1);
        break;
      case "scrollUp":
        if (pane.splitMode && pane.focusedPane === "right") {
          pane.setRightScrollOffset(pane.rightScrollOffset + 5);
        }
        break;
      case "scrollDown":
        if (pane.splitMode && pane.focusedPane === "right") {
          pane.setRightScrollOffset(pane.rightScrollOffset - 5);
        }
        break;
    }
  });

  const addSystemMessage = useCallback((content: string) => {
    const msg: Message = {
      id: `system-${++messageCounter}`,
      role: "system",
      content,
      tool_calls: null,
      tool_call_id: null,
      token_count: null,
      agent_name: null,
      inserted_at: new Date().toISOString(),
    };
    useSessionStore.getState().addMessage(msg);
  }, []);

  const clearMessages = useCallback(() => {
    useSessionStore.getState().clearMessages();
  }, []);

  const commandContext: CommandContext = useMemo(
    () => ({
      appStore: appState,
      sessionStore: sessionState,
      addSystemMessage,
      sendMessage,
      clearMessages,
      exit,
    }),
    [appState, sessionState, addSystemMessage, sendMessage, clearMessages, exit],
  );

  const handleSubmit = useCallback(
    (text: string) => {
      // Guard against sending while disconnected
      if (!isConnected) {
        addSystemMessage("Not connected. Message not sent.");
        return;
      }

      // Send to server — the broadcast will add the message to the list
      sendMessage(text);
    },
    [sendMessage, isConnected, addSystemMessage],
  );

  return (
    <Box flexDirection="column" height="100%">
      <StatusBar />
      {splitMode ? (
        <SplitPaneLayout
          messages={messages}
          pendingToolCalls={pendingToolCalls}
          isStreaming={isStreaming}
        />
      ) : (
        <MessageList
          messages={messages}
          pendingToolCalls={pendingToolCalls}
          isStreaming={isStreaming}
        />
      )}
      {latestError && <ErrorBanner error={latestError} />}
      {pendingPermissions.length > 0 && (
        <PermissionPrompt
          request={pendingPermissions[0]}
          onRespond={respondPermission}
        />
      )}
      {pendingQuestions.length > 0 && !pendingPermissions.length && (
        <AskUserPrompt
          question={pendingQuestions[0]}
          onAnswer={answerQuestion}
        />
      )}
      <InputArea onSubmit={handleSubmit} commandContext={commandContext} />
    </Box>
  );
}
