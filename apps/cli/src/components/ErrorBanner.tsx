import React from "react";
import { Box, Text } from "ink";
import { useStore } from "zustand";
import { useAppStore } from "../stores/appStore.js";
import type { AppError } from "../stores/appStore.js";

interface Props {
  error: AppError;
}

export function ErrorBanner({ error }: Props) {
  const retryState = useStore(useAppStore, (s) => s.retryState);

  const displayMessage =
    error.message.length > 200
      ? error.message.slice(0, 200) + "…"
      : error.message;

  return (
    <Box
      borderStyle="single"
      borderColor="red"
      paddingX={1}
      flexDirection="column"
    >
      <Text color="red" bold>
        {error.type}: {displayMessage}
      </Text>
      {retryState && (
        <Text color="yellow">
          Retrying... (attempt {retryState.attempt}/{retryState.total})
        </Text>
      )}
      {error.recoverable && !retryState && (
        <Text dimColor>
          {error.action === "reauth" && "Restart to re-authenticate.  [c] copy"}
          {error.action === "retry" && "[r] retry  [d] dismiss  [c] copy"}
          {error.action === "new_session" && "Creating a new session...  [c] copy"}
          {!error.action && "[d] dismiss  [c] copy"}
        </Text>
      )}
      {!error.recoverable && (
        <Text dimColor>[c] copy</Text>
      )}
    </Box>
  );
}
