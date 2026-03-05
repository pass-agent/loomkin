import Config

# Runtime configuration for Loomkin
# Environment variables can override compile-time config here

if model = System.get_env("LOOMKIN_MODEL") do
  config :loomkin, default_model: model
end

if database_url = System.get_env("DATABASE_URL") do
  config :loomkin, Loomkin.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")
end

if config_env() == :prod do
  # In production, DATABASE_URL is required
  unless System.get_env("DATABASE_URL") do
    raise """
    environment variable DATABASE_URL is missing.
    For example: ecto://USER:PASS@HOST/DATABASE
    """
  end

  # Generate a stable secret for local binary usage, or use env var for server deploy
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      Base.encode64(:crypto.hash(:sha256, System.user_home!() <> "loomkin_secret_salt"),
        padding: false
      )

  host = System.get_env("PHX_HOST") || "localhost"
  port = String.to_integer(System.get_env("PORT") || "4200")

  config :loomkin, LoomkinWeb.Endpoint,
    url: [host: host, port: port, scheme: "http"],
    http: [ip: {127, 0, 0, 1}, port: port],
    secret_key_base: secret_key_base,
    server: true
end
