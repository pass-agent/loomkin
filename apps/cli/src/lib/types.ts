export interface User {
  id: string;
  email: string;
  username: string | null;
  confirmed_at: string | null;
  inserted_at: string;
}

export interface Session {
  id: string;
  title: string | null;
  status: "active" | "archived";
  model: string;
  fast_model: string | null;
  project_path: string;
  prompt_tokens: number;
  completion_tokens: number;
  cost_usd: number | null;
  team_id: string | null;
  inserted_at: string;
  updated_at: string;
}

export interface Message {
  id: string;
  role: "system" | "user" | "assistant" | "tool";
  content: string | null;
  tool_calls: ToolCall[] | null;
  tool_call_id: string | null;
  token_count: number | null;
  agent_name: string | null;
  inserted_at: string;
}

export interface ToolCall {
  id: string;
  name: string;
  arguments: Record<string, unknown>;
  output?: string;
}

export interface PermissionRequest {
  id: string;
  tool_name: string;
  tool_path: string;
  agent_name: string | null;
  category: "read" | "write" | "execute" | "coordination";
}

export interface AskUserQuestion {
  question_id: string;
  agent_name: string;
  question: string;
  options: string[];
}

export interface Team {
  id: string;
  agents: Agent[];
  tasks: Task[];
}

export interface Agent {
  name: string;
  role: string;
  status: string;
}

export interface Task {
  id: string;
  title: string;
  status: string;
  assigned_to: string | null;
}

export interface ModelProvider {
  id: string;
  name: string;
  status: {
    type: string;
    status: string;
    env_var?: string;
  };
  models: Model[];
}

export interface Model {
  label: string;
  id: string;
  context: string | null;
}

export interface ProviderModels {
  provider: string;
  models: Model[];
}

export interface Setting {
  key: string;
  label: string;
  description: string;
  type: string;
  default: unknown;
  value: unknown;
  tab: string;
  section: string;
  options: string[] | null;
  range: { min: number; max: number } | null;
  unit: string | null;
  step: number | null;
}

export interface DecisionNode {
  id: string;
  node_type: string;
  title: string;
  description: string | null;
  status: string;
  confidence: number | null;
  agent_name: string | null;
  session_id: string | null;
  inserted_at: string;
}

export interface PulseReport {
  summary: string;
  health_score: number;
}

export interface BacklogItem {
  id: string;
  title: string;
  description: string | null;
  status: string;
  priority: number;
  category: string | null;
  epic: string | null;
  tags: string[];
  created_by: string | null;
  assigned_to: string | null;
  assigned_team: string | null;
  acceptance_criteria: string[] | null;
  result: string | null;
  scope_estimate: string | null;
  sort_order: number | null;
  inserted_at: string;
  updated_at: string;
}

export interface AuthResponse {
  token: string;
  user: User;
}

export interface LoginRequest {
  email: string;
  password: string;
}

export interface RegisterRequest {
  email: string;
  password: string;
  username?: string;
}

export interface ConfirmRequest {
  token: string;
}

export interface CreateSessionRequest {
  model?: string;
  fast_model?: string;
  project_path?: string;
}

export interface SendMessageRequest {
  content: string;
}

export interface McpClientInfo {
  name: string;
  transport: { type: string; url?: string; command?: string };
  status: string;
  tool_count: number;
}

export interface McpServerTool {
  name: string;
  module: string;
}

export interface McpServerInfo {
  enabled: boolean;
  tools: McpServerTool[];
}

export interface McpStatus {
  server: McpServerInfo;
  clients: McpClientInfo[];
}

export interface FileEntry {
  name: string;
  type: string;
  size: string;
  modified: string;
  is_dir: boolean;
}

export interface GrepMatch {
  file: string;
  line: number;
  content: string;
}

export interface PaginatedResponse<T> {
  data: T[];
  meta?: {
    total: number;
    page: number;
    per_page: number;
  };
}

export interface OAuthStartResponse {
  url: string;
  flow_type: "redirect" | "paste_back";
}

export interface OAuthStatusResponse {
  connected: boolean;
  flow_active: boolean;
}

// --- Conversation types ---

export interface ConversationTurn {
  conversation_id: string;
  speaker: string;
  content: string;
  round: number;
  type: "speech" | "reaction" | "yield";
  reaction_type?: string;
  reason?: string;
  timestamp: string;
}

export interface ConversationInfo {
  conversation_id: string;
  topic: string;
  participants: string[];
  strategy?: string;
  team_id: string;
  current_round: number;
  status: "active" | "summarizing" | "completed" | "terminated";
  turns: ConversationTurn[];
  summary?: ConversationSummary;
  started_at: string;
  ended_at?: string;
}

export interface ConversationSummary {
  topic?: string;
  rounds?: number;
  participants?: string[];
  key_points?: string[];
  consensus?: string[];
  disagreements?: string[];
  open_questions?: string[];
  recommended_actions?: string[];
}

// --- Approval gate types ---

export interface ApprovalRequest {
  gate_id: string;
  agent_name: string;
  question: string;
  timeout_ms: number;
  team_id: string;
  received_at: number;
}

export interface SpawnGateRequest {
  gate_id: string;
  agent_name: string;
  team_name: string;
  roles: Array<{ role: string; name?: string }>;
  estimated_cost: number;
  purpose: string | null;
  timeout_ms: number;
  limit_warning: string | null;
  team_id: string;
  received_at: number;
}

// --- Plan mode types ---

export interface PlanMessage {
  plan_id: string;
  agent_name: string;
  plan: string;
  timeout_ms: number;
  received_at: number;
}

// --- Kin types ---

export interface KinAgent {
  id: string;
  name: string;
  role: string;
  display_name: string | null;
  potency: number;
  auto_spawn: boolean;
  spawn_context: string | null;
  model_override: string | null;
  system_prompt_extra: string | null;
  budget_limit: number | null;
  tags: string[];
  enabled: boolean;
}

export interface KindredBundle {
  id: string;
  name: string;
  version: number;
  status: string;
  item_count: number;
}

// --- Cloud / Device Code types ---

export interface DeviceCodeResponse {
  device_code: string;
  user_code: string;
  verification_uri: string;
  verification_uri_complete: string;
  expires_in: number;
  interval: number;
}

export interface DeviceTokenResponse {
  access_token: string;
  token_type: string;
  expires_in: number;
  scope: string;
}

export interface DeviceTokenError {
  error: "authorization_pending" | "slow_down" | "expired_token" | "access_denied";
  error_description?: string;
}

export interface CloudVault {
  vault_id: string;
  name: string;
  description: string | null;
  entry_count: number;
  organization_id: string | null;
}

export interface VaultSearchResult {
  path: string;
  title: string;
  entry_type: string;
  tags: string[];
}
