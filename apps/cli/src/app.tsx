import React, { useCallback, useEffect, useMemo, useState } from "react";
import { Box, useApp, useInput, useStdout } from "ink";
import { useStore } from "zustand";
import { StatusBar } from "./components/StatusBar.js";
import { MessageList } from "./components/MessageList.js";
import { SplitPaneLayout } from "./components/SplitPaneLayout.js";
import { ErrorBanner } from "./components/ErrorBanner.js";
import { PermissionPrompt } from "./components/PermissionPrompt.js";
import { AskUserPrompt } from "./components/AskUserPrompt.js";
import { ApprovalGatePrompt } from "./components/ApprovalGatePrompt.js";
import { PlanApprovalPrompt } from "./components/PlanApprovalPrompt.js";
import { InputArea } from "./components/InputArea.js";
import { ProcessingStatus } from "./components/ProcessingStatus.js";
import { useConnection } from "./hooks/useConnection.js";
import { useChannelLifecycle } from "./hooks/useChannelLifecycle.js";
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
import "./commands/focus.js";
import "./commands/provider.js";
import "./commands/dashboard.js";
import "./commands/conversations.js";
import "./commands/kin.js";
import "./commands/kindred.js";
import "./commands/pause.js";
import "./commands/resume.js";
import "./commands/steer.js";
import "./commands/inject.js";
import "./commands/cancel.js";
import "./commands/gates.js";
import "./commands/update.js";
import "./commands/plan.js";
import "./commands/think.js";
import "./commands/remember.js";
import "./commands/plugins.js";

let messageCounter = 0;

function useTerminalSize() {
  const { stdout } = useStdout();
  const [size, setSize] = useState({
    cols: stdout?.columns ?? 80,
    rows: stdout?.rows ?? 24,
  });

  useEffect(() => {
    if (!stdout) return;
    const onResize = () => {
      setSize({ cols: stdout.columns ?? 80, rows: stdout.rows ?? 24 });
    };
    stdout.on("resize", onResize);
    return () => {
      stdout.off("resize", onResize);
    };
  }, [stdout]);

  return size;
}

export function App() {
  const { exit } = useApp();
  const { cols: termWidth, rows: termHeight } = useTerminalSize();
  const { isConnected } = useConnection();

  // Single channel lifecycle owner — must be before useSessionChannel/useAgentChannel
  useChannelLifecycle();

  const {
    messages,
    isStreaming,
    pendingToolCalls,
    pendingPermissions,
    pendingQuestions,
    sendMessage,
    setModel,
    respondPermission,
    answerQuestion,
    respondApproval,
    respondSpawnGate,
    respondPlan,
  } = useSessionChannel();

  const pendingApprovals = useStore(useSessionStore, (s) => s.pendingApprovals);
  const pendingSpawnGates = useStore(useSessionStore, (s) => s.pendingSpawnGates);
  const pendingPlans = useStore(useSessionStore, (s) => s.pendingPlans);

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
      setSessionModel: setModel,
    }),
    [appState, sessionState, addSystemMessage, sendMessage, clearMessages, exit, setModel],
  );

  const handleSubmit = useCallback(
    (text: string, targetAgent?: string) => {
      // Guard against sending while disconnected
      if (!isConnected) {
        addSystemMessage("Not connected. Message not sent.");
        return;
      }

      // Send to server — the broadcast will add the message to the list
      sendMessage(text, targetAgent);
    },
    [sendMessage, isConnected, addSystemMessage],
  );

  return (
    <Box flexDirection="column" height={termHeight} width={termWidth}>
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
          maxLines={termHeight - 6}
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
      {pendingApprovals.length > 0 &&
        !pendingPermissions.length &&
        !pendingQuestions.length && (
          <ApprovalGatePrompt
            key={pendingApprovals[0].gate_id}
            type="approval"
            gate={pendingApprovals[0]}
            onRespond={respondApproval}
          />
        )}
      {pendingSpawnGates.length > 0 &&
        !pendingPermissions.length &&
        !pendingQuestions.length &&
        !pendingApprovals.length && (
          <ApprovalGatePrompt
            key={pendingSpawnGates[0].gate_id}
            type="spawn_gate"
            gate={pendingSpawnGates[0]}
            onRespond={respondSpawnGate}
          />
        )}
      {pendingPlans.length > 0 &&
        !pendingPermissions.length &&
        !pendingQuestions.length &&
        !pendingApprovals.length &&
        !pendingSpawnGates.length && (
          <PlanApprovalPrompt
            key={pendingPlans[0].plan_id}
            plan={pendingPlans[0]}
            onRespond={respondPlan}
          />
        )}
      <InputArea onSubmit={handleSubmit} commandContext={commandContext} />
      <ProcessingStatus />
      <StatusBar />
    </Box>
  );
}
