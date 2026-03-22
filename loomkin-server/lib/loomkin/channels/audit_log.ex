defmodule Loomkin.Channels.AuditLog do
  @moduledoc """
  Command audit log for channel adapters.

  Logs every command execution with structured metadata and maintains
  an ETS ring buffer of recent entries for the `/audit` command.
  """

  use GenServer

  @table :channel_audit_log
  @max_entries 200

  defstruct [:counter]

  @type entry :: %{
          timestamp: DateTime.t(),
          channel: atom(),
          channel_id: String.t(),
          user_id: term(),
          command: String.t(),
          args: String.t(),
          result: :ok | :error,
          response: String.t() | nil
        }

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Log a command execution."
  @spec log_command(
          atom(),
          String.t(),
          map(),
          String.t(),
          String.t(),
          :ok | :error,
          String.t() | nil
        ) ::
          :ok
  def log_command(channel, channel_id, metadata, command, args, result, response \\ nil) do
    entry = %{
      timestamp: DateTime.utc_now(),
      channel: channel,
      channel_id: channel_id,
      user_id: extract_user_id(channel, metadata),
      command: command,
      args: args,
      result: result,
      response: response
    }

    GenServer.cast(__MODULE__, {:log, entry})
  end

  @doc "Get recent audit entries, newest first."
  @spec recent(non_neg_integer()) :: [entry()]
  def recent(limit \\ 20) do
    case :ets.info(@table) do
      :undefined ->
        []

      _ ->
        @table
        |> :ets.tab2list()
        |> Enum.sort_by(fn {idx, _entry} -> idx end, :desc)
        |> Enum.take(limit)
        |> Enum.map(fn {_idx, entry} -> entry end)
    end
  end

  @doc "Format recent entries for display in a channel."
  @spec format_recent(non_neg_integer()) :: String.t()
  def format_recent(limit \\ 10) do
    entries = recent(limit)

    if entries == [] do
      "No commands logged yet."
    else
      lines =
        Enum.map(entries, fn entry ->
          time = Calendar.strftime(entry.timestamp, "%H:%M:%S")
          status = if entry.result == :ok, do: "OK", else: "ERR"
          user = entry.user_id || "?"

          "  [#{time}] #{entry.channel}/#{entry.channel_id} user=#{user} /#{entry.command} #{entry.args} -> #{status}"
        end)

      "Recent commands (#{length(entries)}):\n" <> Enum.join(lines, "\n")
    end
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %__MODULE__{counter: 0}}
  end

  @impl true
  def handle_cast({:log, entry}, state) do
    idx = rem(state.counter, @max_entries)
    :ets.insert(@table, {idx, entry})
    {:noreply, %{state | counter: state.counter + 1}}
  end

  # --- Private ---

  defp extract_user_id(:telegram, metadata), do: Map.get(metadata, :from_id)
  defp extract_user_id(:discord, metadata), do: Map.get(metadata, :user_id)
  defp extract_user_id(_, _), do: nil
end
