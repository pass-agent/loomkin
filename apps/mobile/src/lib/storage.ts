import * as SecureStore from "expo-secure-store";
import { Platform } from "react-native";

/**
 * Secure storage wrapper that falls back to in-memory storage on web.
 */
const memoryStore = new Map<string, string>();

export const storage = {
  async getItem(key: string): Promise<string | null> {
    if (Platform.OS === "web") {
      return memoryStore.get(key) ?? null;
    }
    try {
      return await SecureStore.getItemAsync(key);
    } catch {
      return null;
    }
  },

  async setItem(key: string, value: string): Promise<void> {
    if (Platform.OS === "web") {
      memoryStore.set(key, value);
      return;
    }
    try {
      await SecureStore.setItemAsync(key, value);
    } catch (error) {
      console.error("Failed to save to secure store:", error);
    }
  },

  async removeItem(key: string): Promise<void> {
    if (Platform.OS === "web") {
      memoryStore.delete(key);
      return;
    }
    try {
      await SecureStore.deleteItemAsync(key);
    } catch (error) {
      console.error("Failed to remove from secure store:", error);
    }
  },
};
