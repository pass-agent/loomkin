# Loomkin - AI Instructions

Read and follow [CONTRIBUTING.md](CONTRIBUTING.md) for all conventions, including commit message format, build commands, and code style.

## Monorepo Layout

- **`loomkin-server/`** — Elixir/Phoenix app (mix.exs, lib/, config/, priv/, test/, assets/)
- **`apps/`** — Client applications (desktop, mobile) — future
- **`packages/`** — Shared JS/TS libraries — future
- **`services/`** — Polyglot backend services — future

All `mix` commands must be run from the `loomkin-server/` directory (or use `make` targets from root).

Key reminders:
- Commit subjects must be **fully lowercase** (no acronyms like UI or API — use `ui`, `api`)
- Run `cd loomkin-server && mix format` before committing
- Run `cd loomkin-server && mix precommit` to validate everything before pushing
- **Never run slow commands** (e.g. `mix test`, `mix precommit`, `mix compile`) without piping output to a `/tmp` log file (e.g. `mix test 2>&1 | tee /tmp/mix_test.log`). This avoids rerunning the entire command just to grep for a specific string — search the log file instead.


<!-- phoenix-gen-auth-start -->
## Authentication

- **Always** handle authentication flow at the router level with proper redirects
- **Always** be mindful of where to place routes. `phx.gen.auth` creates multiple router plugs:
  - A plug `:fetch_current_scope_for_user` that is included in the default browser pipeline
  - A plug `:require_authenticated_user` that redirects to the log in page when the user is not authenticated
  - In both cases, a `@current_scope` is assigned to the Plug connection
  - A plug `redirect_if_user_is_authenticated` that redirects to a default path in case the user is authenticated - useful for a registration page that should only be shown to unauthenticated users
- **Always let the user know in which router scopes and pipeline you are placing the route, AND SAY WHY**
- `phx.gen.auth` assigns the `current_scope` assign - it **does not assign a `current_user` assign**
- Always pass the assign `current_scope` to context modules as first argument. When performing queries, use `current_scope.user` to filter the query results
- To derive/access `current_user` in templates, **always use the `@current_scope.user`**, never use **`@current_user`** in templates
- Anytime you hit `current_scope` errors or the logged in session isn't displaying the right content, **always double check the router and ensure you are using the correct plug as described below**

### Routes that require authentication

Controller routes must be placed in a scope that sets the `:require_authenticated_user` plug:

    scope "/", AppWeb do
      pipe_through [:browser, :require_authenticated_user]

      get "/", MyControllerThatRequiresAuth, :index
    end

### Routes that work with or without authentication

Controllers automatically have the `current_scope` available if they use the `:browser` pipeline.

<!-- phoenix-gen-auth-end -->
