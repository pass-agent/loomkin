defmodule Loomkin.MixProject do
  use Mix.Project

  @version "0.1.0"

  # Auto-clean when LOOMKIN_SELF_EDIT changes to avoid confusing
  # Phoenix code_reloader compile-time mismatch errors.
  @self_edit_marker Path.join(["_build", to_string(Mix.env()), ".self_edit_mode"])
  @self_edit_current System.get_env("LOOMKIN_SELF_EDIT") == "1"

  if File.exists?(@self_edit_marker) do
    previous = File.read!(@self_edit_marker) |> String.trim() == "true"

    if previous != @self_edit_current do
      mode =
        if @self_edit_current,
          do: "self-edit (code reloader off)",
          else: "normal dev (code reloader on)"

      Mix.shell().info([
        :yellow,
        "⚡ LOOMKIN_SELF_EDIT changed → auto-cleaning build for #{mode} mode…"
      ])

      build_dir = Path.join(["_build", to_string(Mix.env()), "lib", "loomkin"])
      File.rm_rf!(build_dir)
    end
  end

  File.mkdir_p!(Path.join("_build", to_string(Mix.env())))
  File.write!(@self_edit_marker, to_string(@self_edit_current))

  def project do
    [
      app: :loomkin,
      version: @version,
      elixir: "~> 1.20-rc",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
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
      {:bcrypt_elixir, "~> 3.0"},
      {:swoosh, "~> 1.4"},
      # Jido ecosystem
      {:jido, "~> 2.0"},
      {:jido_action, "~> 2.0"},
      {:jido_signal, "~> 2.0"},
      {:jido_ai, github: "agentjido/jido_ai", branch: "main"},
      {:jido_mcp, github: "agentjido/jido_mcp", branch: "main"},

      # LLM client
      {:req_llm, "~> 1.6"},
      {:llm_db, ">= 0.0.0"},

      # Storage
      {:postgrex, ">= 0.0.0"},
      {:ecto_sql, "~> 3.12"},
      {:phoenix_ecto, "~> 4.6"},

      # Git
      {:git_cli, "~> 0.3"},

      # Text processing
      {:diff_match_patch, "~> 0.3"},
      {:mdex, "~> 0.6"},

      # CLI
      {:owl, "~> 0.13"},

      # Config
      {:toml, github: "vinnymac/toml-elixir", ref: "ae7f122", override: true},
      {:abacus, github: "vinnymac/abacus", ref: "de9f489", override: true},
      {:sched_ex, github: "vinnymac/SchedEx", ref: "938861d", override: true},
      {:yaml_elixir, "~> 2.12"},

      # OAuth
      {:assent, "~> 0.3.1"},

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
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.1.1",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:plug_cowboy, "~> 2.7"},
      {:jason, "~> 1.4"},
      {:dns_cluster, "~> 0.1"},
      {:bandit, "~> 1.6"},

      # Channel adapters
      {:telegex, github: "vinnymac/telegex", ref: "5c02566"},
      {:nostrum, "~> 0.10", runtime: false},

      # Binary packaging
      {:burrito, "~> 1.0"},

      # Dev/Test
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:live_debugger, "~> 0.6.0", only: :dev},
      {:tidewave, "~> 0.5", only: :dev},
      {:mox, "~> 1.0", only: :test},
      {:floki, "~> 0.37", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      "assets.setup": ["cmd --cd assets npm install"],
      "assets.build": ["esbuild loomkin", "tailwind loomkin"],
      "assets.deploy": [
        "cmd --cd assets npm install",
        "esbuild loomkin --minify",
        "tailwind loomkin --minify",
        "phx.digest"
      ],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
