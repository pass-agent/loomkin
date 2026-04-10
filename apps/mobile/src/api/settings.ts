import apiClient from "./client";
import type { Setting } from "@/lib/types";

export const settingsApi = {
  async list(): Promise<Setting[]> {
    const response = await apiClient.get<{ settings: Setting[] }>("/settings");
    return response.data.settings;
  },

  async update(settings: Record<string, unknown>): Promise<Setting[]> {
    const response = await apiClient.put<{ values: Setting[] }>("/settings", { settings });
    return response.data.values;
  },
};
