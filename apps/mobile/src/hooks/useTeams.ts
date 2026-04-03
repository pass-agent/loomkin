import { useQuery } from "@tanstack/react-query";
import { teamsApi } from "@/api/teams";
import { QUERY_KEYS } from "@/lib/constants";
import type { Team, Agent } from "@/lib/types";

export function useTeam(teamId: string | undefined) {
  return useQuery<Team>({
    queryKey: QUERY_KEYS.team(teamId!),
    queryFn: () => teamsApi.get(teamId!),
    enabled: !!teamId,
  });
}

export function useTeamAgents(teamId: string | undefined) {
  return useQuery<Agent[]>({
    queryKey: QUERY_KEYS.teamAgents(teamId!),
    queryFn: () => teamsApi.getAgents(teamId!),
    enabled: !!teamId,
  });
}
