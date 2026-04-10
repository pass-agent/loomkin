import { sendMessageRest, createSession } from "./api.js";
import { useAppStore } from "../stores/appStore.js";

export interface PrintOptions {
  prompt: string;
  outputFormat: "text" | "json" | "stream-json";
  sessionId?: string;
}

// --- NDJSON types ---

type NdjsonEvent =
  | { type: "session_start"; session_id: string; timestamp: string }
  | { type: "stream_token"; delta: string; timestamp: string }
  | { type: "tool_call"; name: string; input: unknown; call_id: string; timestamp: string }
  | {
      type: "tool_result";
      name: string;
      output: unknown;
      call_id: string;
      is_error?: boolean;
      timestamp: string;
    }
  | { type: "message_end"; content: string; stop_reason?: string; timestamp: string }
  | {
      type: "cost";
      input_tokens: number;
      output_tokens: number;
      cost_usd: number;
      timestamp: string;
    }
  | { type: "error"; message: string; code?: string; timestamp: string };

function emitNdjson(event: NdjsonEvent): void {
  process.stdout.write(JSON.stringify(event) + "\n");
}

function now(): string {
  return new Date().toISOString();
}

export async function runPrintMode(opts: PrintOptions): Promise<void> {
  const { prompt, outputFormat, sessionId: existingSessionId } = opts;

  // Create a session if none provided
  const sessionId =
    existingSessionId ??
    (
      await createSession({
        model: useAppStore.getState().model,
        project_path: process.cwd(),
      })
    ).session.id;

  if (outputFormat === "stream-json") {
    // Emit session_start before sending message
    emitNdjson({ type: "session_start", session_id: sessionId, timestamp: now() });

    try {
      const { message } = await sendMessageRest(sessionId, prompt);

      const content = message.content ?? "";

      // Emit content as a stream_token event. For a REST response the full
      // content arrives at once, so we emit it as a single delta.
      if (content) {
        emitNdjson({ type: "stream_token", delta: content, timestamp: now() });
      }

      // Emit tool calls if present
      if (message.tool_calls && message.tool_calls.length > 0) {
        for (const tc of message.tool_calls) {
          emitNdjson({
            type: "tool_call",
            name: tc.name,
            input: tc.arguments,
            call_id: tc.id,
            timestamp: now(),
          });

          if (tc.output !== undefined) {
            emitNdjson({
              type: "tool_result",
              name: tc.name,
              output: tc.output,
              call_id: tc.id,
              timestamp: now(),
            });
          }
        }
      }

      // Emit cost if token info is available
      if (message.token_count != null) {
        emitNdjson({
          type: "cost",
          input_tokens: 0,
          output_tokens: message.token_count,
          cost_usd: 0,
          timestamp: now(),
        });
      }

      // Emit message_end
      emitNdjson({ type: "message_end", content, timestamp: now() });
    } catch (err) {
      emitNdjson({
        type: "error",
        message: err instanceof Error ? err.message : String(err),
        timestamp: now(),
      });
      throw err;
    }
    return;
  }

  // Send the message and get the response (text / json modes)
  const { message } = await sendMessageRest(sessionId, prompt);

  if (outputFormat === "json") {
    process.stdout.write(JSON.stringify(message, null, 2) + "\n");
  } else {
    process.stdout.write((message.content ?? "") + "\n");
  }
}
