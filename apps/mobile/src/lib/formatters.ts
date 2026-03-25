import { formatDistanceToNow, format } from "date-fns";

/**
 * Format a cost in USD to a readable string.
 */
export function formatCost(costUsd: number | null | undefined): string {
  if (costUsd == null) return "--";
  if (costUsd < 0.01) return `$${costUsd.toFixed(4)}`;
  if (costUsd < 1) return `$${costUsd.toFixed(3)}`;
  return `$${costUsd.toFixed(2)}`;
}

/**
 * Format a token count to a readable string.
 */
export function formatTokens(count: number | null | undefined): string {
  if (count == null) return "--";
  if (count < 1000) return String(count);
  if (count < 1_000_000) return `${(count / 1000).toFixed(1)}k`;
  return `${(count / 1_000_000).toFixed(2)}M`;
}

/**
 * Format a date string to relative time (e.g., "2 hours ago").
 */
export function formatRelativeTime(dateString: string): string {
  try {
    return formatDistanceToNow(new Date(dateString), { addSuffix: true });
  } catch {
    return dateString;
  }
}

/**
 * Format a date string to a short date format.
 */
export function formatShortDate(dateString: string): string {
  try {
    return format(new Date(dateString), "MMM d, yyyy");
  } catch {
    return dateString;
  }
}

/**
 * Format a date string to time only.
 */
export function formatTime(dateString: string): string {
  try {
    return format(new Date(dateString), "HH:mm");
  } catch {
    return dateString;
  }
}

/**
 * Truncate a string to a maximum length.
 */
export function truncate(str: string, maxLength: number = 50): string {
  if (str.length <= maxLength) return str;
  return str.slice(0, maxLength - 3) + "...";
}

/**
 * Generate a display title for a session.
 */
export function sessionTitle(title: string | null, id: string): string {
  if (title) return title;
  return `Session ${id.slice(0, 8)}`;
}

/**
 * Format agent status to a human-readable string.
 */
export function formatAgentStatus(status: string): string {
  return status.charAt(0).toUpperCase() + status.slice(1).replace(/_/g, " ");
}
