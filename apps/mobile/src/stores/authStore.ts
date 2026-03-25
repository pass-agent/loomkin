import { create } from "zustand";
import { storage } from "@/lib/storage";
import { SECURE_STORE_KEYS } from "@/lib/constants";
import type { User } from "@/lib/types";

interface AuthState {
  token: string | null;
  user: User | null;
  isAuthenticated: boolean;
  isLoading: boolean;
  isHydrated: boolean;

  // Actions
  setToken: (token: string) => Promise<void>;
  setUser: (user: User) => Promise<void>;
  login: (token: string, user: User) => Promise<void>;
  logout: () => Promise<void>;
  hydrate: () => Promise<void>;
}

export const useAuthStore = create<AuthState>((set, get) => ({
  token: null,
  user: null,
  isAuthenticated: false,
  isLoading: true,
  isHydrated: false,

  setToken: async (token: string) => {
    await storage.setItem(SECURE_STORE_KEYS.AUTH_TOKEN, token);
    set({ token, isAuthenticated: true });
  },

  setUser: async (user: User) => {
    await storage.setItem(SECURE_STORE_KEYS.USER_DATA, JSON.stringify(user));
    set({ user });
  },

  login: async (token: string, user: User) => {
    await storage.setItem(SECURE_STORE_KEYS.AUTH_TOKEN, token);
    await storage.setItem(SECURE_STORE_KEYS.USER_DATA, JSON.stringify(user));
    set({ token, user, isAuthenticated: true });
  },

  logout: async () => {
    await storage.removeItem(SECURE_STORE_KEYS.AUTH_TOKEN);
    await storage.removeItem(SECURE_STORE_KEYS.USER_DATA);
    set({ token: null, user: null, isAuthenticated: false });
  },

  hydrate: async () => {
    try {
      const token = await storage.getItem(SECURE_STORE_KEYS.AUTH_TOKEN);
      const userJson = await storage.getItem(SECURE_STORE_KEYS.USER_DATA);
      const user = userJson ? (JSON.parse(userJson) as User) : null;

      set({
        token,
        user,
        isAuthenticated: !!token,
        isLoading: false,
        isHydrated: true,
      });
    } catch (error) {
      console.error("Failed to hydrate auth store:", error);
      set({ isLoading: false, isHydrated: true });
    }
  },
}));
