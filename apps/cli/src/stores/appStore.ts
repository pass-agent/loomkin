import { createStore } from "zustand";
import type { Mode } from "../lib/constants.js";
import { getConfig } from "../lib/config.js";
import type { KeybindMode, VimMode } from "../lib/keymap.js";

export type ConnectionState =
  | "disconnected"
  | "connecting"
  | "connected"
  | "reconnecting";

export interface AppError {
  type: "network" | "auth" | "session" | "api";
  message: string;
  recoverable: boolean;
  action?: "retry" | "reauth" | "new_session";
}

export interface RetryState {
  attempt: number;
  total: number;
  path: string;
}

export interface AppState {
  serverUrl: string;
  token: string | null;
  mode: Mode;
  model: string;
  modelProviderStatus: "idle" | "loading" | "loaded" | "error";
  configuredProviderIds: Set<string>;
  connectionState: ConnectionState;
  isConnected: boolean;
  reconnectAttempts: number;
  errors: AppError[];
  retryState: RetryState | null;

  // CLI flags
  verbose: boolean;
  debug: boolean;
  skipPermissions: boolean;
  allowedTools: string[] | null;
  disallowedTools: string[] | null;
  maxTurns: number | null;

  // Automation / CI flags
  noColor: boolean;
  quiet: boolean;
  timeout: number | null;
  logFile: string | null;
  promptFile: string | null;
  continueSession: boolean;
  toolTimeout: number | null;
  dryRun: boolean;
  costLimit: number | null;
  jsonStream: boolean;

  // Keybindings
  keybindMode: KeybindMode;
  vimMode: VimMode;

  // Show model picker once after first connect (set on startup)
  showModelPickerOnConnect: boolean;
  setShowModelPickerOnConnect: (show: boolean) => void;

  setRetryState: (state: RetryState) => void;
  clearRetryState: () => void;
  setConnectionState: (state: ConnectionState) => void;
  incrementReconnectAttempts: () => void;
  setMode: (mode: Mode) => void;
  setModel: (model: string) => void;
  setToken: (token: string | null) => void;
  addError: (error: AppError) => void;
  dismissError: (index: number) => void;
  clearErrors: () => void;
  setVerbose: (verbose: boolean) => void;
  setDebug: (debug: boolean) => void;
  setSkipPermissions: (skip: boolean) => void;
  setAllowedTools: (tools: string[] | null) => void;
  setDisallowedTools: (tools: string[] | null) => void;
  setMaxTurns: (turns: number | null) => void;
  setNoColor: (noColor: boolean) => void;
  setQuiet: (quiet: boolean) => void;
  setTimeout: (ms: number | null) => void;
  setLogFile: (path: string | null) => void;
  setPromptFile: (path: string | null) => void;
  setContinueSession: (val: boolean) => void;
  setToolTimeout: (ms: number | null) => void;
  setDryRun: (val: boolean) => void;
  setCostLimit: (usd: number | null) => void;
  setJsonStream: (val: boolean) => void;
  setKeybindMode: (mode: KeybindMode) => void;
  setVimMode: (mode: VimMode) => void;
  setModelProviderStatus: (status: "idle" | "loading" | "loaded" | "error") => void;
  setConfiguredProviderIds: (ids: Set<string>) => void;
}

const config = getConfig();

export const appStore = createStore<AppState>((set) => ({
  serverUrl: config.serverUrl,
  token: config.token,
  mode: (config.defaultMode as Mode) || "code",
  model: config.defaultModel || "",
  modelProviderStatus: "idle" as const,
  configuredProviderIds: new Set<string>(),
  connectionState: "disconnected",
  isConnected: false,
  reconnectAttempts: 0,
  errors: [],
  retryState: null,

  verbose: false,
  debug: false,
  skipPermissions: false,
  allowedTools: null,
  disallowedTools: null,
  maxTurns: null,

  noColor: false,
  quiet: false,
  timeout: null,
  logFile: null,
  promptFile: null,
  continueSession: false,
  toolTimeout: null,
  dryRun: false,
  costLimit: null,
  jsonStream: false,

  keybindMode: (config.keybindMode as KeybindMode) || "default",
  vimMode: "normal" as VimMode,

  showModelPickerOnConnect: false,
  setShowModelPickerOnConnect: (show) => set({ showModelPickerOnConnect: show }),

  setRetryState: (retryState) => set({ retryState }),
  clearRetryState: () => set({ retryState: null }),

  setConnectionState: (connectionState) =>
    set((state) => ({
      connectionState,
      isConnected: connectionState === "connected",
      // Reset reconnect attempts and clear network errors on connect
      ...(connectionState === "connected"
        ? {
            reconnectAttempts: 0,
            errors: state.errors.filter((e) => e.type !== "network"),
          }
        : {}),
    })),

  incrementReconnectAttempts: () =>
    set((state) => ({ reconnectAttempts: state.reconnectAttempts + 1 })),

  setMode: (mode) => set({ mode }),
  setModel: (model) => set({ model }),
  setToken: (token) => set({ token }),

  addError: (error) =>
    set((state) => ({ errors: [...state.errors, error] })),

  dismissError: (index) =>
    set((state) => ({
      errors: state.errors.filter((_, i) => i !== index),
    })),

  clearErrors: () => set({ errors: [] }),

  setVerbose: (verbose) => set({ verbose }),
  setDebug: (debug) => set({ debug }),
  setSkipPermissions: (skipPermissions) => set({ skipPermissions }),
  setAllowedTools: (allowedTools) => set({ allowedTools }),
  setDisallowedTools: (disallowedTools) => set({ disallowedTools }),
  setMaxTurns: (maxTurns) => set({ maxTurns }),
  setNoColor: (noColor) => set({ noColor }),
  setQuiet: (quiet) => set({ quiet }),
  setTimeout: (timeout) => set({ timeout }),
  setLogFile: (logFile) => set({ logFile }),
  setPromptFile: (promptFile) => set({ promptFile }),
  setContinueSession: (continueSession) => set({ continueSession }),
  setToolTimeout: (toolTimeout) => set({ toolTimeout }),
  setDryRun: (dryRun) => set({ dryRun }),
  setCostLimit: (costLimit) => set({ costLimit }),
  setJsonStream: (jsonStream) => set({ jsonStream }),
  setKeybindMode: (keybindMode) =>
    set({ keybindMode, vimMode: keybindMode === "vim" ? "normal" : "normal" }),
  setVimMode: (vimMode) => set({ vimMode }),
  setModelProviderStatus: (modelProviderStatus) => set({ modelProviderStatus }),
  setConfiguredProviderIds: (configuredProviderIds) => set({ configuredProviderIds }),
}));

export const useAppStore = appStore;
