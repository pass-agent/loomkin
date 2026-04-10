import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { sessionsApi } from "@/api/sessions";
import { messagesApi } from "@/api/messages";
import { QUERY_KEYS } from "@/lib/constants";
import type { Session, Message, CreateSessionRequest } from "@/lib/types";

export function useSessions() {
  return useQuery<Session[]>({
    queryKey: QUERY_KEYS.sessions,
    queryFn: sessionsApi.list,
  });
}

export function useSession(id: string | undefined) {
  return useQuery<Session>({
    queryKey: QUERY_KEYS.session(id!),
    queryFn: () => sessionsApi.get(id!),
    enabled: !!id,
  });
}

export function useSessionMessages(sessionId: string | undefined) {
  return useQuery<Message[]>({
    queryKey: QUERY_KEYS.sessionMessages(sessionId!),
    queryFn: () => messagesApi.list(sessionId!),
    enabled: !!sessionId,
    refetchInterval: false,
  });
}

export function useCreateSession() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (data?: CreateSessionRequest) => sessionsApi.create(data),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: QUERY_KEYS.sessions });
    },
  });
}

export function useSendMessage(sessionId: string) {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (content: string) => messagesApi.send(sessionId, { content }),
    onSuccess: (newMessage) => {
      // Optimistically add the message to the cache
      queryClient.setQueryData<Message[]>(QUERY_KEYS.sessionMessages(sessionId), (old) =>
        old ? [...old, newMessage] : [newMessage],
      );
    },
  });
}

export function useArchiveSession() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (id: string) => sessionsApi.archive(id),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: QUERY_KEYS.sessions });
    },
  });
}
