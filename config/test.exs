import Config

config :loomkin, Loomkin.Repo,
  database: Path.expand("../.loomkin/test.db", __DIR__),
  pool: Ecto.Adapters.SQL.Sandbox

# We don't start the web server during test
config :loomkin, LoomkinWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4202],
  secret_key_base: "test_only_secret_key_base_that_is_at_least_64_bytes_long_for_testing_purposes_only!!",
  server: false

config :logger, level: :warning
