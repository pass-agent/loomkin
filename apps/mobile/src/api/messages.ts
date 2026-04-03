import apiClient from "./client";
import type { Message, SendMessageRequest } from "@/lib/types";

export const messagesApi = {
  async list(sessionId: string): Promise<Message[]> {
    const response = await apiClient.get<{ messages: Message[] }>(
      `/sessions/${sessionId}/messages`
    );
    return response.data.messages;
  },

  async send(
    sessionId: string,
    data: SendMessageRequest
  ): Promise<Message> {
    const response = await apiClient.post<{ message: Message }>(
      `/sessions/${sessionId}/messages`,
      { message: data }
    );
    return response.data.message;
  },
};
