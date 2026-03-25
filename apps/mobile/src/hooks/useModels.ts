import { useQuery } from "@tanstack/react-query";
import { modelsApi } from "@/api/models";
import { QUERY_KEYS } from "@/lib/constants";
import type { Model, ModelProvider } from "@/lib/types";

export function useModels() {
  return useQuery<Model[]>({
    queryKey: QUERY_KEYS.models,
    queryFn: modelsApi.list,
  });
}

export function useModelProviders() {
  return useQuery<ModelProvider[]>({
    queryKey: QUERY_KEYS.modelProviders,
    queryFn: modelsApi.providers,
  });
}
