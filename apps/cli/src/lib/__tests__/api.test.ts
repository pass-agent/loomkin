import { expect, test } from "vitest";
import { ApiError } from "../api.js";

test.each<{
  status: number;
  isAuth: boolean;
  isNotFound: boolean;
  isServer: boolean;
}>([
  { status: 200, isAuth: false, isNotFound: false, isServer: false },
  { status: 400, isAuth: false, isNotFound: false, isServer: false },
  { status: 401, isAuth: true, isNotFound: false, isServer: false },
  { status: 403, isAuth: true, isNotFound: false, isServer: false },
  { status: 404, isAuth: false, isNotFound: true, isServer: false },
  { status: 500, isAuth: false, isNotFound: false, isServer: true },
  { status: 502, isAuth: false, isNotFound: false, isServer: true },
  { status: 503, isAuth: false, isNotFound: false, isServer: true },
])(
  "ApiError($status) → isAuth=$isAuth, isNotFound=$isNotFound, isServer=$isServer",
  ({ status, isAuth, isNotFound, isServer }) => {
    const error = new ApiError(status, "test body");
    expect(error.isAuth).toBe(isAuth);
    expect(error.isNotFound).toBe(isNotFound);
    expect(error.isServer).toBe(isServer);
  },
);

test("ApiError message includes status and body", () => {
  const error = new ApiError(422, "Unprocessable Entity");
  expect(error.message).toBe("422 Unprocessable Entity");
  expect(error.name).toBe("ApiError");
  expect(error.status).toBe(422);
  expect(error.body).toBe("Unprocessable Entity");
});

test("ApiError extracts message from JSON body", () => {
  const error = new ApiError(400, '{"error":"validation_failed","message":"title is required"}');
  expect(error.message).toBe("400 title is required");
});

test("ApiError extracts title from HTML error page", () => {
  const html =
    "<!DOCTYPE html><html><head><title>Ecto.Query.CastError at GET /api/v1/sessions/bad-id</title></head><body>...</body></html>";
  const error = new ApiError(400, html);
  expect(error.message).toBe("400 Ecto.Query.CastError at GET /api/v1/sessions/bad-id");
});

test("ApiError truncates long plain-text body", () => {
  const longBody = "x".repeat(200);
  const error = new ApiError(500, longBody);
  expect(error.message.length).toBeLessThanOrEqual(125);
  expect(error.message).toContain("…");
});
