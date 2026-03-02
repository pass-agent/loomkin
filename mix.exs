defmodule Loomkin.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :loomkin,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      escript: escript(),
      releases: releases(),
      elixirc_paths: elixirc_paths(Mix.env()),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :runtime_tools],
      mod: {Loomkin.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp escript do
    [main_module: LoomkinCli.Main]
  end

  defp releases do
    [
      loomkin: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            macos_aarch64: [os: :darwin, cpu: :aarch64],
            macos_x86_64: [os: :darwin, cpu: :x86_64],
            linux_x86_64: [os: :linux, cpu: :x86_64],
            linux_aarch64: [os: :linux, cpu: :aarch64]
          ]
        ],
        applications: [runtime_tools: :permanent],
        cookie: "loomkin_#{@version}"
      ]
    ]
  end

  defp deps do
    [
      # Jido ecosystem
      {:jido, "~> 2.0"},
      {:jido_action, "~> 2.0"},
      {:jido_signal, "~> 2.0"},
      {:jido_ai, github: "agentjido/jido_ai", branch: "main"},
      {:jido_mcp, github: "agentjido/jido_mcp", branch: "main"},
      {:jido_shell, github: "agentjido/jido_shell"},

      # LLM client
      {:req_llm, "~> 1.6"},
      {:llm_db, ">= 0.0.0"},

      # Storage
      {:ecto_sqlite3, "~> 0.17"},
      {:ecto_sql, "~> 3.12"},

      # Git
      {:git_cli, "~> 0.3"},

      # Text processing
      {:diff_match_patch, "~> 0.3"},
      {:mdex, "~> 0.6"},

      # CLI
      {:owl, "~> 0.13"},

      # Config
      {:toml, "~> 0.7"},
      {:yaml_elixir, "~> 2.12"},

      # File watching
      {:file_system, "~> 1.1"},

      # Telemetry
      {:telemetry, "~> 1.3"},

      # Phoenix / LiveView
      {:phoenix, "~> 1.7"},
      {:phoenix_html, "~> 4.2"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_live_reload, "~> 1.5", only: :dev},
      {:phoenix_live_dashboard, "~> 0.8"},
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.2", runtime: Mix.env() == :dev},
      {:heroicons, github: "tailwindlabs/heroicons", tag: "v2.1.1", sparse: "optimized", app: false, compile: false, depth: 1},
      {:plug_cowboy, "~> 2.7"},
      {:jason, "~> 1.4"},
      {:dns_cluster, "~> 0.1"},
      {:bandit, "~> 1.6"},

      # Binary packaging
      {:burrito, "~> 1.0"},

      # Dev/Test
      {:mox, "~> 1.0", only: :test},
      {:floki, "~> 0.37", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
