import pc from "picocolors";
import { getApiUrl } from "./urls.js";
import { getConfig } from "./config.js";

type Epic = {
  id: string;
  title: string;
  status: string;
  current_phase: string | null;
  priority: number;
  inserted_at: string;
};

type WorkUnit = {
  id: string;
  title: string;
  status: string;
  iteration: number;
  commit_sha: string | null;
};

type GateResult = {
  id: string;
  kind: string;
  verdict: string;
  iteration: number;
  reviewer_count: number;
};

type EpicDetail = Epic & {
  work_units: WorkUnit[];
  gate_results: GateResult[];
};

function authHeaders(): Record<string, string> {
  const cfg = getConfig();
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (cfg.token) headers["Authorization"] = `Bearer ${cfg.token}`;
  return headers;
}

async function api<T>(path: string, init?: RequestInit): Promise<T> {
  const url = `${getApiUrl()}${path}`;
  const res = await fetch(url, { ...init, headers: { ...authHeaders(), ...(init?.headers ?? {}) } });
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`${res.status} ${res.statusText}: ${body}`);
  }
  return (await res.json()) as T;
}

function fmtPhase(phase: string | null): string {
  if (!phase) return "—";
  return phase;
}

function fmtStatus(status: string): string {
  switch (status) {
    case "closed":
      return pc.green(status);
    case "failed":
      return pc.red(status);
    case "awaiting_human":
      return pc.yellow(status);
    case "in_progress":
      return pc.cyan(status);
    default:
      return pc.dim(status);
  }
}

export async function runOrchestrationStatus(): Promise<number> {
  try {
    const { data: epics } = await api<{ data: Epic[] }>("/orchestration/epics");

    if (epics.length === 0) {
      console.log(pc.dim("no orchestration epics yet — try `loomkin orchestrate \"<spec>\"`"));
      return 0;
    }

    console.log(pc.bold("title".padEnd(40)), pc.bold("status".padEnd(16)), pc.bold("phase"));
    console.log(pc.dim("─".repeat(78)));

    for (const epic of epics) {
      const title = (epic.title ?? "").slice(0, 38).padEnd(40);
      const status = fmtStatus(epic.status).padEnd(28); // padded with ANSI codes is tricky
      console.log(title, status, fmtPhase(epic.current_phase));
    }
    return 0;
  } catch (err) {
    console.error(pc.red(`orchestration status failed: ${(err as Error).message}`));
    return 1;
  }
}

export async function runOrchestrate(spec: string, title?: string): Promise<number> {
  if (!spec || spec.trim().length === 0) {
    console.error(
      pc.red('orchestrate requires a non-empty spec. Usage: loomkin orchestrate "<spec>" [--title=...]'),
    );
    return 1;
  }

  const t = (title ?? spec.split("\n")[0].slice(0, 80)).trim();

  try {
    const { data: epic } = await api<{ data: Epic }>("/orchestration/epics", {
      method: "POST",
      body: JSON.stringify({ title: t, spec }),
    });

    console.log(pc.green("✓ orchestrated:"), pc.bold(epic.title));
    console.log(pc.dim(`  id:    ${epic.id}`));
    console.log(pc.dim(`  view:  ${getConfig().serverUrl}/orchestration/${epic.id}`));
    return 0;
  } catch (err) {
    console.error(pc.red(`orchestrate failed: ${(err as Error).message}`));
    return 1;
  }
}

export async function runOrchestrationShow(id: string): Promise<number> {
  try {
    const { data } = await api<{ data: EpicDetail }>(`/orchestration/epics/${id}`);

    console.log(pc.bold(data.title));
    console.log(pc.dim(`  id:           ${data.id}`));
    console.log(pc.dim(`  status:       `) + fmtStatus(data.status));
    console.log(pc.dim(`  phase:        ${fmtPhase(data.current_phase)}`));
    console.log(pc.dim(`  inserted_at:  ${data.inserted_at}`));
    console.log();

    console.log(pc.bold(`work units (${data.work_units.length})`));
    for (const wu of data.work_units) {
      console.log(`  • ${wu.title} [${fmtStatus(wu.status)}] iter=${wu.iteration}`);
    }
    console.log();

    console.log(pc.bold(`gate results (${data.gate_results.length})`));
    for (const g of data.gate_results) {
      const verdictColored =
        g.verdict === "pass" ? pc.green(g.verdict) : pc.red(g.verdict);
      console.log(
        `  • ${g.kind.padEnd(20)} [${verdictColored}] iter=${g.iteration} reviewers=${g.reviewer_count}`,
      );
    }
    return 0;
  } catch (err) {
    console.error(pc.red(`orchestration show failed: ${(err as Error).message}`));
    return 1;
  }
}
