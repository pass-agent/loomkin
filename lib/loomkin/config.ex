defmodule Loomkin.Config do
  @moduledoc """
  Configuration manager for Loomkin.

  Loads settings from `.loomkin.toml` in the project directory,
  merges with defaults, and stores in ETS for fast access.
  """

  use GenServer

  @table :loomkin_config

  @defaults %{
    model: %{
      default: "anthropic:claude-sonnet-4-6",
      # Secondary model for editor tasks — nil means "use the primary model".
      # Only used when an agent determines a lesser model is acceptable.
      # Users can set this in .loomkin.toml: [model] editor = "anthropic:claude-haiku-4-5"
      editor: nil
    },
    repo: %{
      watch_enabled: true
    },
    permissions: %{
      auto_approve: ["file_read", "file_search", "content_search", "directory_list"]
    },
    context: %{
      max_repo_map_tokens: 2048,
      max_decision_context_tokens: 1024,
      reserved_output_tokens: 4096
    },
    decisions: %{
      enabled: true,
      enforce_pre_edit: false,
      auto_log_commits: true
    },
    shell: %{
      allowlist_enabled: false,
      allowlist: ~w(mix elixir iex git cat head tail ls find grep rg sed awk echo mkdir cp mv touch node npm npx yarn bun cargo rustc go python python3 pip ruby gem)
    }
  }

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Load configuration from `.loomkin.toml` in the given project path.
  Merges file config with defaults. If the file doesn't exist, uses defaults.
  """
  def load(project_path) do
    GenServer.call(__MODULE__, {:load, project_path})
  end

  @doc "Get a top-level config value."
  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> nil
    end
  end

  @doc "Get a nested config value."
  def get(key, subkey) do
    case get(key) do
      %{} = map -> Map.get(map, subkey)
      _ -> nil
    end
  end

  @doc "Override a config value for this session."
  def put(key, value) do
    GenServer.call(__MODULE__, {:put, key, value})
  end

  @doc "Return the full config map."
  def all do
    @table
    |> :ets.tab2list()
    |> Map.new()
  end

  def defaults, do: @defaults

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    store_config(@defaults)
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:load, project_path}, _from, state) do
    toml_path = Path.join(project_path, ".loomkin.toml")

    config =
      case Toml.decode_file(toml_path) do
        {:ok, parsed} ->
          deep_merge(@defaults, atomize_keys(parsed))

        {:error, _} ->
          @defaults
      end

    store_config(config)
    :ets.insert(@table, {:project_path, project_path})

    Phoenix.PubSub.broadcast(
      Loomkin.PubSub,
      "loom:system",
      {:config_loaded, Map.put(config, :project_path, project_path)}
    )

    {:reply, :ok, state}
  end

  def handle_call({:put, key, value}, _from, state) do
    :ets.insert(@table, {key, value})
    {:reply, :ok, state}
  end

  # --- Helpers ---

  defp store_config(config) do
    Enum.each(config, fn {key, value} ->
      :ets.insert(@table, {key, value})
    end)
  end

  # Known config keys that may appear in .loomkin.toml
  @known_keys ~w(model permissions context decisions mcp web lsp repo shell
    default weak architect editor auto_approve max_repo_map_tokens max_decision_context_tokens
    reserved_output_tokens enabled enforce_pre_edit auto_log_commits
    allowlist_enabled allowlist
    servers name command args url port server_enabled watch_enabled
    teams budget max_per_team_usd max_per_agent_usd max_per_agent_tokens provider_limits
    models grunt standard expert architect escalation
    templates agents role count)a

  # Pre-compute a string→atom lookup map so atomize_keys never raises
  @known_key_map Map.new(@known_keys, fn atom -> {Atom.to_string(atom), atom} end)

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) ->
        atom_key = Map.get(@known_key_map, key, key)
        {atom_key, atomize_keys(value)}

      {key, value} ->
        {key, atomize_keys(value)}
    end)
  end

  defp atomize_keys(list) when is_list(list), do: Enum.map(list, &atomize_keys/1)
  defp atomize_keys(value), do: value

  defp deep_merge(base, override) when is_map(base) and is_map(override) do
    Map.merge(base, override, fn
      _key, base_val, override_val when is_map(base_val) and is_map(override_val) ->
        deep_merge(base_val, override_val)

      _key, _base_val, override_val ->
        override_val
    end)
  end

  defp deep_merge(_base, override), do: override
end
