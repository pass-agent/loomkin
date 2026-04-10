// TODO: wire hookStarted/hookCompleted when server emits hook lifecycle events
import React from "react";
import { Box, Text } from "ink";
import { useStore } from "zustand";
import Spinner from "ink-spinner";
import { ToolCallSkeleton } from "./skeleton/ToolCallSkeleton.js";
import { HookProgressDisplay } from "./HookProgressDisplay.js";
import { sessionStore } from "../stores/sessionStore.js";
import { useAppStore } from "../stores/appStore.js";
import type { ToolCall } from "../lib/types.js";
import { getToolResultState, TOOL_REJECT_WITH_REASON_PREFIX } from "../lib/types.js";

interface Props {
  toolCall: ToolCall;
  isPending?: boolean;
  isError?: boolean;
}

function ToolResultOutput({ output, isError }: { output: string; isError?: boolean }) {
  const state = getToolResultState({ isError, content: output });

  switch (state) {
    case "canceled":
      return (
        <Box marginLeft={2}>
          <Text dimColor>○ Canceled</Text>
        </Box>
      );
    case "interrupted":
      return (
        <Box marginLeft={2}>
          <Text dimColor>⚡ Interrupted</Text>
        </Box>
      );
    case "rejected": {
      const reason = output.startsWith(TOOL_REJECT_WITH_REASON_PREFIX)
        ? output.slice(TOOL_REJECT_WITH_REASON_PREFIX.length)
        : "";
      return (
        <Box marginLeft={2}>
          <Text color="yellow">⊘ Rejected{reason ? ": " + reason : ""}</Text>
        </Box>
      );
    }
    case "error":
      return (
        <Box marginLeft={2}>
          <Text color="red">✗ Error: {output}</Text>
        </Box>
      );
    default:
      return (
        <Box marginLeft={2}>
          <Text dimColor wrap="truncate-end">
            {output.slice(0, 200)}
          </Text>
        </Box>
      );
  }
}

export function ToolCallDisplay({ toolCall, isPending, isError }: Props) {
  const verbose = useStore(useAppStore, (s) => s.verboseToolOutput);
  const argsPreview = JSON.stringify(toolCall.arguments).slice(0, 80);
  const facingName = toolCall.renderer?.userFacingName(toolCall.arguments);
  const displayName = facingName ? facingName : toolCall.name;

  const renderedResult =
    toolCall.output && toolCall.renderer?.renderToolResultMessage
      ? toolCall.renderer.renderToolResultMessage(toolCall.output, { verbose })
      : null;

  if (!verbose) {
    // Condensed mode: show tool name + 1-line summary of output
    const outputSummary = toolCall.output
      ? toolCall.output.split("\n")[0].slice(0, 80) +
        (toolCall.output.split("\n")[0].length > 80 || toolCall.output.includes("\n") ? "…" : "")
      : null;
    return (
      <Box flexDirection="row" marginLeft={2} gap={1}>
        {isPending && (
          <Text color="yellow">
            <Spinner type="dots" />
          </Text>
        )}
        <Text color="cyan" bold>
          {displayName}
        </Text>
        {outputSummary && <Text dimColor>{outputSummary}</Text>}
      </Box>
    );
  }

  return (
    <Box flexDirection="column" marginLeft={2}>
      <Box gap={1}>
        {isPending && (
          <Text color="yellow">
            <Spinner type="dots" />
          </Text>
        )}
        <Text color="cyan" bold>
          {displayName}
        </Text>
        <Text dimColor>{argsPreview}</Text>
      </Box>
      {isPending && (
        <HookProgressDisplay
          toolUseId={toolCall.id}
          getCount={(id) => sessionStore.getState().inProgressHookCounts.get(id) ?? 0}
        />
      )}
      {isPending && <ToolCallSkeleton width={30} />}
      {toolCall.output &&
        (renderedResult != null ? (
          <Box marginLeft={2}>{renderedResult}</Box>
        ) : (
          <ToolResultOutput output={toolCall.output} isError={isError} />
        ))}
    </Box>
  );
}
