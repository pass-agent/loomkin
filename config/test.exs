import Config

config :loomkin, Loomkin.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "loomkin_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

# We don't start the web server during test
config :loomkin, LoomkinWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4202],
  secret_key_base:
    "test_only_secret_key_base_that_is_at_least_64_bytes_long_for_testing_purposes_only!!",
  server: false

config :logger, level: :warning

# Disable auto-start of nervous system (AutoLogger/Broadcaster) in tests.
# Tests that need them start them explicitly with sandbox-aware setup.
config :loomkin, start_nervous_system: false
