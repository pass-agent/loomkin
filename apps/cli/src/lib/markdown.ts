import { Marked } from "marked";
// @ts-expect-error: types declare default-only but named export exists at runtime
import { markedTerminal } from "marked-terminal";

const marked = new Marked(markedTerminal() as never);

export function renderMarkdown(content: string): string {
  return marked.parse(content) as string;
}
