defmodule Loomkin.Vault.FileSync do
  @moduledoc """
  Bidirectional sync between vault entries (PostgreSQL) and markdown files (Obsidian).
  Write-through: every vault write also writes to disk when enabled.
  Watch: file system changes are picked up and upserted to the database.
  """

  use GenServer
  require Logger

  alias Loomkin.Repo
  alias Loomkin.Schemas.VaultLink
  alias Loomkin.Vault.Index
  alias Loomkin.Vault.Parser
  alias Loomkin.Vault.Storage
  alias Loomkin.Vault.Sync

  import Ecto.Query

  @debounce_ms 300

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Notify FileSync that a vault entry was written. Called by Vault context."
  def on_vault_write(vault_id, path, entry) do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:vault_write, vault_id, path, entry})
    end
  end

  @doc "Start watching an Obsidian vault directory."
  def start_watching(vault_id, obsidian_path) do
    GenServer.call(__MODULE__, {:start_watching, vault_id, obsidian_path})
  end

  @doc "Stop watching."
  def stop_watching do
    GenServer.call(__MODULE__, :stop_watching)
  end

  @doc "Get current sync status."
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    state = %{
      vault_id: nil,
      obsidian_path: nil,
      watcher_pid: nil,
      pending_changes: MapSet.new(),
      debounce_ref: nil,
      # Paths we're currently writing — ignore change events for these
      writing: MapSet.new()
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:vault_write, vault_id, path, entry}, state) do
    if state.obsidian_path && state.vault_id == vault_id do
      write_to_disk(state.obsidian_path, path, entry)
      {:noreply, %{state | writing: MapSet.put(state.writing, path)}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_call({:start_watching, vault_id, obsidian_path}, _from, state) do
    state = stop_watcher(state)

    case FileSystem.start_link(dirs: [obsidian_path], latency: 0) do
      {:ok, watcher_pid} ->
        FileSystem.subscribe(watcher_pid)
        Logger.info("[FileSync] Watching #{obsidian_path} for vault #{vault_id}")

        new_state = %{
          state
          | vault_id: vault_id,
            obsidian_path: obsidian_path,
            watcher_pid: watcher_pid
        }

        {:reply, :ok, new_state}

      {:error, reason} ->
        Logger.error("[FileSync] Failed to start watcher: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:stop_watching, _from, state) do
    {:reply, :ok, stop_watcher(state)}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      watching: state.watcher_pid != nil,
      vault_id: state.vault_id,
      obsidian_path: state.obsidian_path,
      pending_changes: MapSet.size(state.pending_changes)
    }

    {:reply, status, state}
  end

  # File system events from the watcher
  @impl true
  def handle_info({:file_event, _pid, {file_path, events}}, state) do
    if should_process?(file_path, events) do
      relative = Path.relative_to(file_path, state.obsidian_path)

      if MapSet.member?(state.writing, relative) do
        # Skip — we just wrote this file ourselves
        {:noreply, %{state | writing: MapSet.delete(state.writing, relative)}}
      else
        pending = MapSet.put(state.pending_changes, relative)
        state = %{state | pending_changes: pending}
        state = schedule_debounce(state)
        {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:file_event, _pid, :stop}, state) do
    {:noreply, %{state | watcher_pid: nil}}
  end

  @impl true
  def handle_info(:process_changes, state) do
    paths = state.pending_changes

    if MapSet.size(paths) > 0 do
      Enum.each(paths, fn path ->
        process_file_change(state.vault_id, path, state.obsidian_path)
      end)
    end

    {:noreply, %{state | pending_changes: MapSet.new(), debounce_ref: nil}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    stop_watcher(state)
    :ok
  end

  # --- Private helpers ---

  defp write_to_disk(obsidian_path, path, entry) do
    full_path = Path.join(obsidian_path, path)
    full_path |> Path.dirname() |> File.mkdir_p!()

    content = Parser.serialize(entry)
    File.write!(full_path, content)
  rescue
    e ->
      Logger.error("[FileSync] Failed to write #{path}: #{Exception.message(e)}")
  end

  defp process_file_change(vault_id, path, obsidian_path) do
    full_path = Path.join(obsidian_path, path)

    if File.exists?(full_path) do
      adapter = Storage.Local
      opts = [root: obsidian_path]

      case Sync.sync_entry(vault_id, path, adapter, opts) do
        {:ok, status} ->
          Logger.debug("[FileSync] Synced #{path}: #{status}")
          extract_wiki_links(vault_id, path, full_path)

        {:error, _path, reason} ->
          Logger.warning("[FileSync] Failed to sync #{path}: #{inspect(reason)}")
      end
    else
      case Index.delete(vault_id, path) do
        :ok -> Logger.debug("[FileSync] Removed #{path} from index")
        {:error, :not_found} -> :ok
      end
    end
  end

  @wiki_link_regex ~r/\[\[([^\]|]+)(?:\|([^\]]+))?\]\]/

  defp extract_wiki_links(vault_id, source_path, full_path) do
    case File.read(full_path) do
      {:ok, content} ->
        Regex.scan(@wiki_link_regex, content)
        |> Enum.each(fn
          [_full, target_path, display_text] ->
            upsert_wiki_link(
              vault_id,
              source_path,
              normalize_link_path(target_path),
              display_text
            )

          [_full, target_path] ->
            upsert_wiki_link(vault_id, source_path, normalize_link_path(target_path), nil)
        end)

      {:error, _} ->
        :ok
    end
  end

  defp normalize_link_path(path) do
    if String.ends_with?(path, ".md"), do: path, else: path <> ".md"
  end

  defp upsert_wiki_link(vault_id, source_path, target_path, display_text) do
    existing =
      Repo.one(
        from(l in VaultLink,
          where:
            l.vault_id == ^vault_id and l.source_path == ^source_path and
              l.target_path == ^target_path and l.link_type == :wiki_link
        )
      )

    if is_nil(existing) do
      %VaultLink{}
      |> VaultLink.changeset(%{
        vault_id: vault_id,
        source_path: source_path,
        target_path: target_path,
        link_type: :wiki_link,
        display_text: display_text
      })
      |> Repo.insert()
    else
      :ok
    end
  end

  defp should_process?(file_path, _events) do
    String.ends_with?(file_path, ".md") and
      not String.contains?(file_path, "/.") and
      not String.contains?(file_path, "/_")
  end

  defp schedule_debounce(state) do
    if state.debounce_ref, do: Process.cancel_timer(state.debounce_ref)
    ref = Process.send_after(self(), :process_changes, @debounce_ms)
    %{state | debounce_ref: ref}
  end

  defp stop_watcher(%{watcher_pid: nil} = state), do: state

  defp stop_watcher(%{watcher_pid: pid} = state) do
    GenServer.stop(pid, :normal)

    %{state | watcher_pid: nil, vault_id: nil, obsidian_path: nil}
  rescue
    _ -> %{state | watcher_pid: nil, vault_id: nil, obsidian_path: nil}
  end
end
