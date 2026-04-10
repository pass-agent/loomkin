import React, { Component } from "react";
import { Box, Text, useApp, useInput } from "ink";
import { writeText } from "tinyclip";
import { useAppStore } from "../stores/appStore.js";
import { reconnectSocket } from "../lib/socket.js";

interface ErrorBoundaryState {
  hasError: boolean;
  error: Error | null;
}

interface ErrorBoundaryProps {
  children: React.ReactNode;
}

function ErrorFallback({ error, onRetry }: { error: Error; onRetry: () => void }) {
  const { exit } = useApp();
  const debug = useAppStore.getState().debug;

  useInput((input) => {
    if (input === "q") {
      exit();
      process.exit(1);
    }
    if (input === "r") {
      onRetry();
    }
    if (input === "c") {
      const content = debug && error.stack ? error.stack : error.message;
      writeText(content).catch(() => {});
    }
  });

  return (
    <Box flexDirection="column" borderStyle="round" borderColor="red" paddingX={1} paddingY={1}>
      <Text bold color="red">
        Loomkin encountered an unexpected error
      </Text>
      <Box marginTop={1}>
        <Text>{error.message}</Text>
      </Box>
      {debug && error.stack && (
        <Box marginTop={1}>
          <Text dimColor>{error.stack}</Text>
        </Box>
      )}
      <Box marginTop={1}>
        <Text dimColor>
          Press <Text bold>q</Text> to exit, <Text bold>r</Text> to retry, <Text bold>c</Text> to
          copy
        </Text>
      </Box>
    </Box>
  );
}

export class ErrorBoundary extends Component<ErrorBoundaryProps, ErrorBoundaryState> {
  constructor(props: ErrorBoundaryProps) {
    super(props);
    this.state = { hasError: false, error: null };
  }

  static getDerivedStateFromError(error: Error): ErrorBoundaryState {
    return { hasError: true, error };
  }

  handleRetry = () => {
    reconnectSocket();
    this.setState({ hasError: false, error: null });
  };

  render() {
    if (this.state.hasError && this.state.error) {
      return <ErrorFallback error={this.state.error} onRetry={this.handleRetry} />;
    }
    return this.props.children;
  }
}
