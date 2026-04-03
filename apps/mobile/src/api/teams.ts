import apiClient from "./client";
import type { Team, Agent } from "@/lib/types";

export const teamsApi = {
  async get(teamId: string): Promise<Team> {
    const response = await apiClient.get<{ team: Team }>(
      `/teams/${teamId}`
    );
    return response.data.team;
  },

  async getAgents(teamId: string): Promise<Agent[]> {
    const response = await apiClient.get<{ agents: Agent[] }>(
      `/teams/${teamId}/agents`
    );
    return response.data.agents;
  },
};
