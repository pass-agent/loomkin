import { sendMessageRest, createSession } from "./api.js";
import { useAppStore } from "../stores/appStore.js";

export interface PrintOptions {
  prompt: string;
  outputFormat: "text" | "json";
  sessionId?: string;
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

  // Send the message and get the response
  const { message } = await sendMessageRest(sessionId, prompt);

  if (outputFormat === "json") {
    process.stdout.write(JSON.stringify(message, null, 2) + "\n");
  } else {
    process.stdout.write((message.content ?? "") + "\n");
  }
}
