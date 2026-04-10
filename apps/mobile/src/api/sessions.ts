import apiClient from "./client";
import type { Session, CreateSessionRequest } from "@/lib/types";

export const sessionsApi = {
  async list(): Promise<Session[]> {
    const response = await apiClient.get<{ sessions: Session[] }>("/sessions");
    return response.data.sessions;
  },

  async get(id: string): Promise<Session> {
    const response = await apiClient.get<{ session: Session }>(`/sessions/${id}`);
    return response.data.session;
  },

  async create(data?: CreateSessionRequest): Promise<Session> {
    const response = await apiClient.post<{ session: Session }>(
      "/sessions",
      data ? { session: data } : undefined,
    );
    return response.data.session;
  },

  async archive(id: string): Promise<Session> {
    const response = await apiClient.patch<{ session: Session }>(`/sessions/${id}/archive`);
    return response.data.session;
  },
};
