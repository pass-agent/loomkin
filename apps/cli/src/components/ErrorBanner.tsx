import React from "react";
import { Box, Text } from "ink";
import type { AppError } from "../stores/appStore.js";

interface Props {
  error: AppError;
}

export function ErrorBanner({ error }: Props) {
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
      {error.recoverable && (
        <Text dimColor>
          {error.action === "reauth" && "Restart to re-authenticate."}
          {error.action === "retry" && "[r] retry  [d] dismiss"}
          {error.action === "new_session" && "Creating a new session..."}
          {!error.action && "[d] dismiss"}
        </Text>
      )}
    </Box>
  );
}
