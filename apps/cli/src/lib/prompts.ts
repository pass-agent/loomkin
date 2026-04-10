import {
  existsSync,
  mkdirSync,
  readFileSync,
  writeFileSync,
  unlinkSync,
  readdirSync,
} from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

export interface PromptTemplate {
  name: string;
  description: string;
  content: string;
  variables: string[];
  createdAt: string;
  updatedAt: string;
}

const PROMPTS_DIR = join(homedir(), ".loomkin", "prompts");

function ensureDir() {
  if (!existsSync(PROMPTS_DIR)) {
    mkdirSync(PROMPTS_DIR, { recursive: true });
  }
}

function templatePath(name: string): string {
  return join(PROMPTS_DIR, `${name}.json`);
}

/** Extract {{variable}} placeholders from content */
function extractVariables(content: string): string[] {
  const matches = content.match(/\{\{(\w+)\}\}/g);
  if (!matches) return [];
  return [...new Set(matches.map((m) => m.slice(2, -2)))];
}

/** Replace {{variable}} placeholders with provided values */
export function renderTemplate(content: string, vars: Record<string, string>): string {
  return content.replace(/\{\{(\w+)\}\}/g, (match, key) => {
    return vars[key] ?? match;
  });
}

export function listTemplates(): PromptTemplate[] {
  ensureDir();
  const files = readdirSync(PROMPTS_DIR).filter((f) => f.endsWith(".json"));

  return files
    .map((f) => {
      try {
        const raw = readFileSync(join(PROMPTS_DIR, f), "utf-8");
        return JSON.parse(raw) as PromptTemplate;
      } catch {
        return null;
      }
    })
    .filter((t): t is PromptTemplate => t !== null)
    .sort((a, b) => a.name.localeCompare(b.name));
}

export function getTemplate(name: string): PromptTemplate | null {
  const path = templatePath(name);
  if (!existsSync(path)) return null;

  try {
    const raw = readFileSync(path, "utf-8");
    return JSON.parse(raw) as PromptTemplate;
  } catch {
    return null;
  }
}

export function saveTemplate(name: string, content: string, description = ""): PromptTemplate {
  ensureDir();
  const existing = getTemplate(name);
  const now = new Date().toISOString();

  const template: PromptTemplate = {
    name,
    description,
    content,
    variables: extractVariables(content),
    createdAt: existing?.createdAt || now,
    updatedAt: now,
  };

  writeFileSync(templatePath(name), JSON.stringify(template, null, 2), "utf-8");
  return template;
}

export function deleteTemplate(name: string): boolean {
  const path = templatePath(name);
  if (!existsSync(path)) return false;
  unlinkSync(path);
  return true;
}
