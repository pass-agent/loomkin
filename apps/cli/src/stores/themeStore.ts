import { createStore } from "zustand";
import { getConfig, setConfig } from "../lib/config.js";
import { getTheme, type Theme } from "../lib/themes.js";

export interface ThemeState {
  theme: Theme;
  setTheme: (name: string) => void;
}

const initial = getConfig().theme || "default";

export const themeStore = createStore<ThemeState>((set) => ({
  theme: getTheme(initial),

  setTheme: (name) => {
    const theme = getTheme(name);
    setConfig({ theme: theme.name });
    set({ theme });
  },
}));

export const useThemeStore = themeStore;
