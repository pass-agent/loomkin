import Config

# Multi-tenant mode is enabled in development for testing social features
config :loomkin, :multi_tenant, true

# Use Docker Postgres port by default; override with DB_PORT for system-installed Postgres
config :loomkin, Loomkin.Repo, port: String.to_integer(System.get_env("DB_PORT") || "5488")

# Self-edit mode — set LOOMKIN_SELF_EDIT=1 when loomkin agents edit this codebase.
# Disables code reloader, file watchers, and live reload to prevent restart loops
# and module-unavailability crashes during edits. Restart the server to pick up changes.
#
# Switching modes:  The mix.exs guard auto-cleans the build when this env var
# changes, so you can just toggle and recompile — no manual `mix clean` needed.
#
#   make self-edit     # start server in self-edit mode
#   make dev           # start server in normal dev mode
self_edit? = System.get_env("LOOMKIN_SELF_EDIT") == "1"

# Development endpoint configuration
config :loomkin, LoomkinWeb.Endpoint,
  url: [host: "loom.test", port: 4200],
  http: [ip: {0, 0, 0, 0}, port: 4200],
  check_origin: false,
  code_reloader: not self_edit?,
  debug_errors: true,
  secret_key_base:
    "dev_only_secret_key_base_that_is_at_least_64_bytes_long_for_development_purposes_only",
  watchers:
    if(self_edit?,
      do: [],
      else: [
        esbuild: {Esbuild, :install_and_run, [:loomkin, ~w(--sourcemap=inline --watch)]},
        tailwind: {Tailwind, :install_and_run, [:loomkin, ~w(--watch)]}
      ]
    )

# Live reload configuration (disabled in self-edit mode)
unless self_edit? do
  config :loomkin, LoomkinWeb.Endpoint,
    live_reload: [
      patterns: [
        ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
        ~r"lib/loomkin_web/(controllers|live|components)/.*(ex|heex)$"
      ]
    ]
end

config :logger, level: :debug

# anubis_mcp (transitive dep via jido_mcp) logs a spurious warning at startup when no
# session store adapter is configured, even when the session store is intentionally disabled.
# Suppress its logging entirely since we don't debug this transitive dependency directly.
config :anubis_mcp, log: false

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime

# Include HEEx debug annotations as HTML comments in rendered markup
config :phoenix_live_view,
  debug_heex_annotations: true,
  debug_attributes: true
