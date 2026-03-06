import Config

config :loomkin, ecto_repos: [Loomkin.Repo]

config :loomkin, Loomkin.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "loomkin_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

# Default model configuration
config :loomkin,
  default_model: "zai:glm-5",
  weak_model: "zai:glm-4.5",
  reserved_output_tokens: 4096,
  max_repo_map_tokens: 2048,
  max_decision_context_tokens: 1024

# Phoenix endpoint configuration
config :loomkin, LoomkinWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: LoomkinWeb.ErrorHTML, json: LoomkinWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Loomkin.PubSub,
  live_view: [signing_salt: "loomkin_lv_salt"]

# Esbuild configuration
config :esbuild,
  loomkin: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Tailwind configuration
config :tailwind,
  version: "3.4.17",
  loomkin: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

# Logger configuration
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# ReqLLM streaming configuration — extend timeouts for long LLM responses
config :req_llm,
  receive_timeout: 120_000,
  stream_receive_timeout: 120_000,
  finch: [
    name: ReqLLM.Finch,
    pools: %{
      :default => [
        protocols: [:http1],
        size: 1,
        count: 8,
        conn_opts: [transport_opts: [timeout: 120_000]]
      ]
    }
  ]

# Use Jason for JSON parsing
config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
