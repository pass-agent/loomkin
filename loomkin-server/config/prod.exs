import Config

# Production configuration
# Runtime config (DATABASE_URL, SECRET_KEY_BASE, etc.) is in runtime.exs

config :loomkin, Loomkin.Repo, pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

config :logger, level: :info
