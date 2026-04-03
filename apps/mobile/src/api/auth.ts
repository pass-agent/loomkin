import apiClient from "./client";
import type {
  AuthResponse,
  LoginRequest,
  RegisterRequest,
  ConfirmRequest,
  User,
} from "@/lib/types";

export const authApi = {
  async register(data: RegisterRequest): Promise<AuthResponse> {
    const response = await apiClient.post<AuthResponse>(
      "/auth/register",
      data
    );
    return response.data;
  },

  async login(
    data: LoginRequest
  ): Promise<{ message?: string; token?: string; user?: User }> {
    const response = await apiClient.post<{
      message?: string;
      token?: string;
      user?: User;
    }>("/auth/login", data);
    return response.data;
  },

  async confirmLogin(data: ConfirmRequest): Promise<AuthResponse> {
    const response = await apiClient.post<AuthResponse>(
      "/auth/login/confirm",
      data
    );
    return response.data;
  },

  async logout(): Promise<void> {
    await apiClient.post("/auth/logout");
  },

  async me(): Promise<User> {
    const response = await apiClient.get<{ user: User }>("/auth/me");
    return response.data.user;
  },
};
