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

export interface PaginatedResponse<T> {
  data: T[];
  meta?: {
    total: number;
    page: number;
    per_page: number;
  };
}
