import React from "react";
import { Text } from "ink";
import { renderMarkdown } from "../lib/markdown.js";

interface Props {
  content: string;
}

export function MarkdownText({ content }: Props) {
  const rendered = renderMarkdown(content);
  // marked-terminal returns ANSI-styled strings; Ink's Text can render them directly
  return <Text>{rendered}</Text>;
}
