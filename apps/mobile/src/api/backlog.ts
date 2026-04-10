import apiClient from "./client";
import type { BacklogItem } from "@/lib/types";

export const backlogApi = {
  async list(): Promise<BacklogItem[]> {
    const response = await apiClient.get<{ items: BacklogItem[] }>("/backlog");
    return response.data.items;
  },

  async get(id: string): Promise<BacklogItem> {
    const response = await apiClient.get<{ item: BacklogItem }>(`/backlog/${id}`);
    return response.data.item;
  },

  async create(data: Partial<BacklogItem>): Promise<BacklogItem> {
    const response = await apiClient.post<{ item: BacklogItem }>("/backlog", data);
    return response.data.item;
  },

  async update(id: string, data: Partial<BacklogItem>): Promise<BacklogItem> {
    const response = await apiClient.put<{ item: BacklogItem }>(`/backlog/${id}`, data);
    return response.data.item;
  },

  async delete(id: string): Promise<void> {
    await apiClient.delete(`/backlog/${id}`);
  },
};
