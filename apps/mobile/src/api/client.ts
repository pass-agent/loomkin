import { API_URL } from "@/lib/constants";
import { useAuthStore } from "@/stores/authStore";
import { router } from "expo-router";
import { ApiError } from "./errors";

interface ApiResponse<T> {
  data: T;
}

type HttpMethod = "GET" | "POST" | "PUT" | "PATCH" | "DELETE";

async function request<T>(
  method: HttpMethod,
  url: string,
  body?: unknown,
): Promise<ApiResponse<T>> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 30000);

  try {
    const token = useAuthStore.getState().token;
    const headers: Record<string, string> = {
      "Content-Type": "application/json",
      Accept: "application/json",
    };
    if (token) {
      headers.Authorization = `Bearer ${token}`;
    }

    const response = await fetch(`${API_URL}${url}`, {
      method,
      headers,
      body: body !== undefined ? JSON.stringify(body) : undefined,
      signal: controller.signal,
    });

    if (response.status === 401) {
      const authStore = useAuthStore.getState();
      if (authStore.token) {
        await authStore.logout();
        if (router.canGoBack()) {
          router.dismissAll();
        }
        router.replace("/(auth)/login");
      }
    }

    if (!response.ok) {
      let errorData: unknown;
      try {
        errorData = await response.json();
      } catch {
        // response body not JSON
      }
      const message =
        errorData && typeof errorData === "object"
          ? "message" in errorData &&
            typeof (errorData as { message: unknown }).message === "string"
            ? (errorData as { message: string }).message
            : "error" in errorData && typeof (errorData as { error: unknown }).error === "string"
              ? (errorData as { error: string }).error
              : response.statusText
          : response.statusText;
      throw new ApiError(response.status, message, errorData);
    }

    // Handle no-content responses (e.g. DELETE)
    if (response.status === 204 || response.headers.get("content-length") === "0") {
      return { data: undefined as T };
    }

    const data = (await response.json()) as T;
    return { data };
  } finally {
    clearTimeout(timeout);
  }
}

const apiClient = {
  get<T>(url: string) {
    return request<T>("GET", url);
  },
  post<T>(url: string, body?: unknown) {
    return request<T>("POST", url, body);
  },
  put<T>(url: string, body?: unknown) {
    return request<T>("PUT", url, body);
  },
  patch<T>(url: string, body?: unknown) {
    return request<T>("PATCH", url, body);
  },
  delete<T = void>(url: string) {
    return request<T>("DELETE", url);
  },
};

export default apiClient;
