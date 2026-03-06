import Config

# Use Docker Postgres port by default; override with DB_PORT for system-installed Postgres
config :loomkin, Loomkin.Repo,
  port: String.to_integer(System.get_env("DB_PORT") || "5488")

# Development endpoint configuration
config :loomkin, LoomkinWeb.Endpoint,
  url: [host: "loom.test", port: 4200],
  http: [ip: {127, 0, 0, 1}, port: 4200],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base:
    "dev_only_secret_key_base_that_is_at_least_64_bytes_long_for_development_purposes_only",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:loomkin, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:loomkin, ~w(--watch)]}
  ]

# Live reload configuration
config :loomkin, LoomkinWeb.Endpoint,
  live_reload: [
    patterns: [
      ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"lib/loomkin_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]

config :logger, level: :debug

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime

# Include HEEx debug annotations as HTML comments in rendered markup
config :phoenix_live_view,
  debug_heex_annotations: true,
  debug_attributes: true
