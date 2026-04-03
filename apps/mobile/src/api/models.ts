import apiClient from "./client";
import type { Model, ModelProvider, ProviderModels } from "@/lib/types";

export const modelsApi = {
  async list(): Promise<Model[]> {
    const response = await apiClient.get<{ models: ProviderModels[] }>("/models");
    // Backend returns models grouped by provider — flatten to a single list
    return response.data.models.flatMap((group) => group.models);
  },

  async providers(): Promise<ModelProvider[]> {
    const response = await apiClient.get<{ providers: ModelProvider[] }>(
      "/models/providers"
    );
    return response.data.providers;
  },
};
