import { getApiUrl } from "./urls.js";
import { getConfig } from "./config.js";
import { useAppStore } from "../stores/appStore.js";
import { withRetry } from "./retry.js";
import { logger } from "./logger.js";
import type {
  AuthResponse,
  LoginRequest,
  RegisterRequest,
  Session,
  CreateSessionRequest,
  Message,
  ModelProvider,
  McpStatus,
  FileEntry,
  GrepMatch,
  DecisionNode,
  BacklogItem,
  Setting,
  OAuthStartResponse,
  OAuthStatusResponse,
} from "./types.js";

export class ApiError extends Error {
  constructor(
    public status: number,
    public body: string,
  ) {
    super(ApiError.formatMessage(status, body));
    this.name = "ApiError";
  }

  private static formatMessage(status: number, body: string): string {
    // Try JSON first — server returns { error: "...", message: "..." }
    try {
      const json = JSON.parse(body);
      const detail = json.message || json.error;
      if (detail) return `${status} ${detail}`;
    } catch {
      // not JSON
    }

    // HTML response (e.g. Phoenix debug page) — extract the <title> text
    if (body.trimStart().startsWith("<!DOCTYPE") || body.trimStart().startsWith("<html")) {
      const match = body.match(/<title[^>]*>([^<]+)<\/title>/i);
      if (match) return `${status} ${match[1].trim()}`;
      return `${status} Server returned an HTML error page`;
    }

    // Short plain-text body — use as-is
    if (body.length <= 120) return `${status} ${body}`;

    // Long body — truncate
    return `${status} ${body.slice(0, 120)}…`;
  }

  get isAuth() {
    return this.status === 401 || this.status === 403;
  }

  get isNotFound() {
    return this.status === 404;
  }

  get isServer() {
    return this.status >= 500;
  }

  get parsedBody(): { error?: string; message?: string; errors?: Record<string, string[]> } | null {
    try {
      return JSON.parse(this.body);
    } catch {
      return null;
    }
  }
}

async function requestOnce<T>(
  path: string,
  options: RequestInit = {},
): Promise<T> {
  const { token } = getConfig();
  const url = `${getApiUrl()}${path}`;

  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    ...(options.headers as Record<string, string>),
  };

  if (token) {
    headers["Authorization"] = `Bearer ${token}`;
  }

  if (useAppStore.getState().verbose) {
    logger.debug(`[api] ${options.method ?? "GET"} ${url}`);
  }

  const response = await fetch(url, { ...options, headers });

  if (!response.ok) {
    const body = await response.text();
    if (useAppStore.getState().verbose) {
      logger.debug(`[api] ${response.status} ${body}`);
    }
    throw new ApiError(response.status, body);
  }

  return response.json() as Promise<T>;
}

async function request<T>(
  path: string,
  options: RequestInit = {},
): Promise<T> {
  return withRetry(() => requestOnce<T>(path, options), {
    maxAttempts: 3,
    baseDelayMs: 500,
    maxDelayMs: 10_000,
    onRetry: (attempt, _err) => {
      if (useAppStore.getState().verbose) {
        logger.debug(`[api] retry attempt ${attempt}/3 for ${options.method ?? "GET"} ${path}`);
      }
      useAppStore.getState().setRetryState({ attempt, total: 3, path });
    },
  }).finally(() => {
    useAppStore.getState().clearRetryState();
  });
}

export async function login(credentials: LoginRequest): Promise<AuthResponse> {
  return request<AuthResponse>("/auth/login", {
    method: "POST",
    body: JSON.stringify(credentials),
  });
}

export async function register(credentials: RegisterRequest): Promise<AuthResponse> {
  return request<AuthResponse>("/auth/register", {
    method: "POST",
    body: JSON.stringify(credentials),
  });
}

export async function anonymousLogin(): Promise<AuthResponse> {
  return request<AuthResponse>("/auth/anonymous", { method: "POST" });
}

export async function bootstrapWithCloudToken(cloudToken: string): Promise<AuthResponse> {
  return request<AuthResponse>("/auth/bootstrap", {
    method: "POST",
    body: JSON.stringify({ cloud_token: cloudToken }),
  });
}

export async function confirmLogin(token: string): Promise<AuthResponse> {
  return request<AuthResponse>("/auth/login/confirm", {
    method: "POST",
    body: JSON.stringify({ token }),
  });
}

export async function getMe() {
  return request<{ user: { id: string; email: string } }>("/auth/me");
}

export async function listSessions(): Promise<{ sessions: Session[] }> {
  return request<{ sessions: Session[] }>("/sessions");
}

export async function getSession(
  sessionId: string,
): Promise<{ session: Session }> {
  return request<{ session: Session }>(`/sessions/${sessionId}`);
}

export async function createSession(
  params: CreateSessionRequest = {},
): Promise<{ session: Session }> {
  return request<{ session: Session }>("/sessions", {
    method: "POST",
    body: JSON.stringify({ session: params }),
  });
}

export async function updateSession(
  sessionId: string,
  params: { title?: string },
): Promise<{ session: Session }> {
  return request<{ session: Session }>(`/sessions/${sessionId}`, {
    method: "PATCH",
    body: JSON.stringify({ session: params }),
  });
}

export async function archiveSession(
  sessionId: string,
): Promise<{ session: Session }> {
  return request<{ session: Session }>(`/sessions/${sessionId}/archive`, {
    method: "PATCH",
  });
}

export async function getSessionMessages(
  sessionId: string,
): Promise<{ messages: Message[] }> {
  return request<{ messages: Message[] }>(
    `/sessions/${sessionId}/messages`,
  );
}

export async function sendMessageRest(
  sessionId: string,
  content: string,
  role: string = "user",
): Promise<{ message: Message }> {
  return request<{ message: Message }>(`/sessions/${sessionId}/messages`, {
    method: "POST",
    body: JSON.stringify({ message: { content, role } }),
  });
}

// --- Diff ---

export async function getDiff(
  opts: { file?: string; staged?: boolean } = {},
): Promise<{ diff: string }> {
  const params = new URLSearchParams();
  if (opts.file) params.set("file", opts.file);
  if (opts.staged) params.set("staged", "true");
  const qs = params.toString();
  return request<{ diff: string }>(`/diff${qs ? `?${qs}` : ""}`);
}

export async function listModelProviders(): Promise<{
  providers: ModelProvider[];
}> {
  return request<{ providers: ModelProvider[] }>("/models/providers");
}

// --- Files ---

export async function listFiles(
  path = ".",
): Promise<{ path: string; entries: FileEntry[] }> {
  return request<{ path: string; entries: FileEntry[] }>(
    `/files?path=${encodeURIComponent(path)}`,
  );
}

export async function readFile(
  path: string,
  opts: { offset?: number; limit?: number } = {},
): Promise<{ content: string }> {
  const params = new URLSearchParams({ path });
  if (opts.offset) params.set("offset", String(opts.offset));
  if (opts.limit) params.set("limit", String(opts.limit));
  return request<{ content: string }>(`/files/read?${params}`);
}

export async function searchFiles(
  pattern: string,
  path?: string,
): Promise<{ pattern: string; files: string[] }> {
  const params = new URLSearchParams({ pattern });
  if (path) params.set("path", path);
  return request<{ pattern: string; files: string[] }>(`/files/search?${params}`);
}

export async function grepFiles(
  pattern: string,
  opts: { path?: string; glob?: string } = {},
): Promise<{ pattern: string; matches: GrepMatch[] }> {
  const params = new URLSearchParams({ pattern });
  if (opts.path) params.set("path", opts.path);
  if (opts.glob) params.set("glob", opts.glob);
  return request<{ pattern: string; matches: GrepMatch[] }>(`/files/grep?${params}`);
}

export async function getMcpStatus(): Promise<McpStatus> {
  return request<McpStatus>("/mcp");
}

export async function refreshMcp(
  name?: string,
): Promise<{ message: string }> {
  return request<{ message: string }>("/mcp/refresh", {
    method: "POST",
    body: name ? JSON.stringify({ name }) : JSON.stringify({}),
  });
}

export async function addMcpServer(
  url: string,
  name?: string,
  transport?: string,
): Promise<{ message: string }> {
  return request<{ message: string }>("/mcp", {
    method: "POST",
    body: JSON.stringify({ url, name, transport: transport ?? "http" }),
  });
}

export async function removeMcpServer(name: string): Promise<{ message: string }> {
  return request<{ message: string }>(`/mcp/${encodeURIComponent(name)}`, {
    method: "DELETE",
  });
}

export async function restartMcpServer(name: string): Promise<{ message: string }> {
  return request<{ message: string }>(`/mcp/${encodeURIComponent(name)}/restart`, {
    method: "POST",
    body: JSON.stringify({}),
  });
}

// --- Decisions ---

export async function getDecisions(
  opts: { type?: string; q?: string; limit?: number } = {},
): Promise<{ type: string; nodes?: DecisionNode[]; query?: string; summary?: string; health_score?: number }> {
  const params = new URLSearchParams();
  if (opts.type) params.set("type", opts.type);
  if (opts.q) params.set("q", opts.q);
  if (opts.limit) params.set("limit", String(opts.limit));
  const qs = params.toString();
  return request(`/decisions${qs ? `?${qs}` : ""}`);
}

// --- Backlog ---

export async function listBacklogItems(
  opts: { status?: string; limit?: number } = {},
): Promise<{ items: BacklogItem[] }> {
  const params = new URLSearchParams();
  if (opts.status) params.set("status", opts.status);
  if (opts.limit) params.set("limit", String(opts.limit));
  const qs = params.toString();
  return request<{ items: BacklogItem[] }>(`/backlog${qs ? `?${qs}` : ""}`);
}

export async function getBacklogItem(
  id: string,
): Promise<{ item: BacklogItem }> {
  return request<{ item: BacklogItem }>(`/backlog/${id}`);
}

export async function createBacklogItem(
  attrs: Partial<BacklogItem>,
): Promise<{ item: BacklogItem }> {
  return request<{ item: BacklogItem }>("/backlog", {
    method: "POST",
    body: JSON.stringify({ item: attrs }),
  });
}

export async function updateBacklogItem(
  id: string,
  attrs: Partial<BacklogItem>,
): Promise<{ item: BacklogItem }> {
  return request<{ item: BacklogItem }>(`/backlog/${id}`, {
    method: "PUT",
    body: JSON.stringify({ item: attrs }),
  });
}

export async function deleteBacklogItem(
  id: string,
): Promise<void> {
  await request<void>(`/backlog/${id}`, { method: "DELETE" });
}

// --- Shares ---

export interface SessionShare {
  id: string;
  session_id: string;
  label: string | null;
  permission: "view" | "collaborate";
  expires_at: string | null;
  inserted_at: string;
}

export interface CreateShareResponse {
  share: SessionShare;
  url: string;
  token: string;
}

export async function createShare(
  sessionId: string,
  opts: { label?: string; permission?: "view" | "collaborate" } = {},
): Promise<CreateShareResponse> {
  return request<CreateShareResponse>(`/sessions/${sessionId}/shares`, {
    method: "POST",
    body: JSON.stringify({
      session_id: sessionId,
      label: opts.label,
      permission: opts.permission,
    }),
  });
}

export async function listShares(
  sessionId: string,
): Promise<{ shares: SessionShare[] }> {
  return request<{ shares: SessionShare[] }>(`/sessions/${sessionId}/shares`);
}

export async function revokeShare(shareId: string): Promise<void> {
  await request<{ message: string }>(`/shares/${shareId}`, {
    method: "DELETE",
  });
}

// --- Settings ---

export async function getSettings(): Promise<{ settings: Setting[] }> {
  return request<{ settings: Setting[] }>("/settings");
}

export async function updateSettings(
  values: Record<string, unknown>,
): Promise<{ message: string; values: Record<string, unknown> }> {
  return request<{ message: string; values: Record<string, unknown> }>(
    "/settings",
    {
      method: "PUT",
      body: JSON.stringify({ settings: values }),
    },
  );
}

// --- OAuth Providers ---

export async function startOAuthFlow(
  provider: string,
): Promise<OAuthStartResponse> {
  return request<OAuthStartResponse>(`/providers/oauth/${provider}/start`, {
    method: "POST",
    body: JSON.stringify({}),
  });
}

export async function getOAuthStatus(
  provider: string,
): Promise<OAuthStatusResponse> {
  return request<OAuthStatusResponse>(`/providers/oauth/${provider}/status`);
}

export async function submitOAuthPaste(
  provider: string,
  codeState: string,
): Promise<void> {
  await request(`/providers/oauth/${provider}/paste`, {
    method: "POST",
    body: JSON.stringify({ code_state: codeState }),
  });
}

export async function disconnectOAuth(provider: string): Promise<void> {
  await request(`/providers/oauth/${provider}`, { method: "DELETE" });
}
