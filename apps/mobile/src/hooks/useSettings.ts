import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { settingsApi } from "@/api/settings";
import { QUERY_KEYS } from "@/lib/constants";
import type { Setting } from "@/lib/types";

export function useSettings() {
  return useQuery<Setting[]>({
    queryKey: QUERY_KEYS.settings,
    queryFn: settingsApi.list,
  });
}

export function useUpdateSettings() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (settings: Record<string, unknown>) => settingsApi.update(settings),
    onSuccess: (data) => {
      queryClient.setQueryData(QUERY_KEYS.settings, data);
    },
  });
}
