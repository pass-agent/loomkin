import React from "react";
import { Box, Text } from "ink";
import { useStore } from "zustand";
import { useAppStore } from "../stores/appStore.js";
import { useSessionStore } from "../stores/sessionStore.js";
import { useAgentStore } from "../stores/agentStore.js";
import { usePaneStore } from "../stores/paneStore.js";
import { useConversationStore } from "../stores/conversationStore.js";
import { formatCost, formatTokens } from "../lib/costTracker.js";

export function StatusBar() {
  const connectionState = useStore(useAppStore, (s) => s.connectionState);
  const reconnectAttempts = useStore(useAppStore, (s) => s.reconnectAttempts);
  const mode = useStore(useAppStore, (s) => s.mode);
  const model = useStore(useAppStore, (s) => s.model);
  const modelProviderStatus = useStore(useAppStore, (s) => s.modelProviderStatus);
  const configuredProviderIds = useStore(useAppStore, (s) => s.configuredProviderIds);
  const sessionId = useStore(useSessionStore, (s) => s.sessionId);
  const estimatedCostUsd = useStore(useSessionStore, (s) => s.estimatedCostUsd);
  const totalInputTokens = useStore(useSessionStore, (s) => s.totalInputTokens);
  const totalOutputTokens = useStore(useSessionStore, (s) => s.totalOutputTokens);
  const contextBudgetPercent = useStore(useSessionStore, (s) => s.contextBudgetPercent);
  const agentCount = useStore(useAgentStore, (s) => s.agents.size);
  const workingCount = useStore(useAgentStore, (s) => {
    let count = 0;
    for (const agent of s.agents.values()) {
      if (agent.status === "working") count++;
    }
    return count;
  });
  const teamTotalCost = useStore(useAgentStore, (s) => {
    let total = 0;
    for (const agent of s.agents.values()) {
      if (agent.costUsd != null && agent.costUsd > 0) total += agent.costUsd;
    }
    return total;
  });
  const agentsWithCostCount = useStore(useAgentStore, (s) => {
    let count = 0;
    for (const agent of s.agents.values()) {
      if (agent.costUsd != null && agent.costUsd > 0) count++;
    }
    return count;
  });
  const splitMode = useStore(usePaneStore, (s) => s.splitMode);
  const selectedAgent = useStore(usePaneStore, (s) => s.selectedAgent);
  const focusedTarget = useStore(usePaneStore, (s) => s.focusedTarget);
  const keybindMode = useStore(useAppStore, (s) => s.keybindMode);
  const vimMode = useStore(useAppStore, (s) => s.vimMode);
  const gitBranch = useStore(useAppStore, (s) => s.gitBranch);
  const updateAvailable = useStore(useAppStore, (s) => s.updateAvailable);
  const autoCompact = useStore(useAppStore, (s) => s.autoCompact);
  const verboseToolOutput = useStore(useAppStore, (s) => s.verboseToolOutput);
  const activeConversation = useStore(useConversationStore, (s) => s.getActive());
  const extractionInProgress = useStore(useSessionStore, (s) => s.extractionInProgress);

  const isConnected = connectionState === "connected";
  const isReconnecting =
    connectionState === "reconnecting" || connectionState === "connecting";

  const dotColor = isConnected ? "green" : isReconnecting ? "yellow" : "red";
  const dotChar = isConnected ? "●" : isReconnecting ? "◐" : "○";

  // Model display: strip provider prefix for brevity
  const displayModel = model ? model.replace(/^[^:]+:/, "") : null;

  // Determine if model provider is actually configured
  const modelProviderPart = model?.split(":")[0] ?? "";
  const isModelConfigured =
    !model ||
    modelProviderStatus !== "loaded" ||
    configuredProviderIds.has(modelProviderPart);

  const hasActivityGroup = agentCount > 0 || keybindMode === "vim" || splitMode || !!focusedTarget;

  return (
    <Box
      paddingX={1}
      justifyContent="space-between"
      flexShrink={0}
    >
      <Box gap={2}>
        <Text color={dotColor}>{dotChar}</Text>
        {isReconnecting && (
          <Text color="yellow">
            reconnecting{reconnectAttempts > 0 ? ` (${reconnectAttempts})` : ""}...
          </Text>
        )}
        {connectionState === "disconnected" && !isConnected && (
          <Text color="red">disconnected</Text>
        )}
        <Text dimColor>
          mode:<Text bold>{mode}</Text>
        </Text>
        {!model ? (
          <Text color="yellow">model:<Text bold>none</Text></Text>
        ) : isModelConfigured ? (
          <Text dimColor>
            model:<Text bold>{displayModel}</Text>
          </Text>
        ) : (
          <Text color="yellow">
            ⚠ model:<Text bold>{displayModel}</Text>
          </Text>
        )}
        {sessionId && (
          <Text dimColor>
            session:<Text bold>{sessionId.slice(0, 8)}</Text>
          </Text>
        )}
        {gitBranch && (
          <Text dimColor>
            git:<Text bold>{gitBranch}</Text>
          </Text>
        )}
        {estimatedCostUsd > 0 && (
          <Text dimColor>
            <Text bold>{formatCost(estimatedCostUsd)}</Text>
          </Text>
        )}
        {(totalInputTokens + totalOutputTokens) > 0 && (
          <Text dimColor>
            <Text bold>{formatTokens(totalInputTokens + totalOutputTokens)}</Text>
            {" tok"}
          </Text>
        )}
        {contextBudgetPercent != null && contextBudgetPercent < 80 && (
          <Text color={contextBudgetPercent < 50 ? "red" : "yellow"}>
            ctx:<Text bold>{contextBudgetPercent}%</Text>
          </Text>
        )}
        {!autoCompact && <Text dimColor>no-ac</Text>}
        {!verboseToolOutput && <Text dimColor>▪ condensed</Text>}
        {extractionInProgress && <Text dimColor>mem:saving</Text>}
        {hasActivityGroup && <Text dimColor>│</Text>}
        {agentCount > 0 && (
          <Text dimColor>
            agents:<Text bold color={workingCount > 0 ? "green" : undefined}>
              {workingCount}/{agentCount}
            </Text>
          </Text>
        )}
        {agentCount >= 2 && agentsWithCostCount >= 2 && (
          <Text dimColor>
            team:<Text bold>
              {agentCount} | {formatCost(teamTotalCost)}
            </Text>
          </Text>
        )}
        {activeConversation && (
          <Text dimColor>
            conv:<Text bold color="magenta">
              {activeConversation.participants.length}
            </Text>
          </Text>
        )}
        {focusedTarget ? (
          <Text color="cyan">
            to:<Text bold>@{focusedTarget}</Text>
          </Text>
        ) : agentCount > 0 ? (
          <Text dimColor>
            to:<Text bold color="green">broadcast</Text>
          </Text>
        ) : null}
        {keybindMode === "vim" && (
          <Text dimColor>
            vim:<Text bold color={vimMode === "normal" ? "yellow" : "green"}>
              {vimMode.toUpperCase()}
            </Text>
          </Text>
        )}
        {splitMode && selectedAgent && (
          <Text dimColor>
            split:<Text bold color="cyan">{selectedAgent}</Text>
          </Text>
        )}
      </Box>
      {updateAvailable && (
        <Box>
          <Text color="yellow">
            {"↑ "}
            <Text bold>v{updateAvailable}</Text>
            <Text dimColor> available</Text>
          </Text>
        </Box>
      )}
    </Box>
  );
}
