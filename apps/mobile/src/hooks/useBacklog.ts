import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { backlogApi } from "@/api/backlog";
import { QUERY_KEYS } from "@/lib/constants";
import type { BacklogItem } from "@/lib/types";

export function useBacklog() {
  return useQuery<BacklogItem[]>({
    queryKey: QUERY_KEYS.backlog,
    queryFn: backlogApi.list,
  });
}

export function useCreateBacklogItem() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (data: Partial<BacklogItem>) => backlogApi.create(data),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: QUERY_KEYS.backlog });
    },
  });
}

export function useUpdateBacklogItem() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: ({ id, data }: { id: string; data: Partial<BacklogItem> }) =>
      backlogApi.update(id, data),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: QUERY_KEYS.backlog });
    },
  });
}

export function useDeleteBacklogItem() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (id: string) => backlogApi.delete(id),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: QUERY_KEYS.backlog });
    },
  });
}
