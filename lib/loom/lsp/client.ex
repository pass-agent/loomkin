defmodule Loom.LSP.Client do
  @moduledoc """
  GenServer LSP client that communicates with a language server over stdio.

  Manages the lifecycle of a language server process, sends requests/notifications,
  and collects diagnostics published by the server.
  """

  use GenServer

  require Logger

  alias Loom.LSP.Protocol

  defstruct [
    :name,
    :command,
    :args,
    :port,
    :root_uri,
    :request_id,
    :pending_requests,
    :diagnostics,
    :buffer,
    :initialized,
    :status
  ]

  # --- Public API ---

  @doc "Start a named LSP client."
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: via(name))
  end

  @doc "Initialize the LSP server connection."
  def initialize(name, root_path) do
    GenServer.call(via(name), {:initialize, root_path}, 30_000)
  end

  @doc "Notify the server that a file was opened."
  def did_open(name, file_path, language_id) do
    GenServer.cast(via(name), {:did_open, file_path, language_id})
  end

  @doc "Notify the server that a file was closed."
  def did_close(name, file_path) do
    GenServer.cast(via(name), {:did_close, file_path})
  end

  @doc "Get current diagnostics for a file."
  def get_diagnostics(name, file_path) do
    GenServer.call(via(name), {:get_diagnostics, file_path})
  end

  @doc "Get all diagnostics across all files."
  def all_diagnostics(name) do
    GenServer.call(via(name), :all_diagnostics)
  end

  @doc "Check if the client is connected and initialized."
  def status(name) do
    GenServer.call(via(name), :status)
  catch
    :exit, _ -> :not_running
  end

  @doc "Shut down the LSP server gracefully."
  def shutdown(name) do
    GenServer.call(via(name), :shutdown, 10_000)
  catch
    :exit, _ -> :ok
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    state = %__MODULE__{
      name: Keyword.fetch!(opts, :name),
      command: Keyword.fetch!(opts, :command),
      args: Keyword.get(opts, :args, []),
      request_id: 0,
      pending_requests: %{},
      diagnostics: %{},
      buffer: "",
      initialized: false,
      status: :idle
    }

    if root_path = Keyword.get(opts, :root_path) do
      {:ok, Map.put(state, :root_uri, nil), {:continue, {:auto_initialize, root_path}}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_continue({:auto_initialize, root_path}, state) do
    case start_server(state) do
      {:ok, port} ->
        root_uri = Protocol.path_to_uri(root_path)
        {id, state} = next_id(%{state | port: port, root_uri: root_uri, status: :starting})

        params = Protocol.initialize_params(root_uri)
        send_request(port, id, "initialize", params)

        state = %{state | pending_requests: Map.put(state.pending_requests, id, {:initialize, nil})}
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("[LSP:#{state.name}] Auto-initialize failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_call({:initialize, root_path}, from, state) do
    case start_server(state) do
      {:ok, port} ->
        root_uri = Protocol.path_to_uri(root_path)
        {id, state} = next_id(%{state | port: port, root_uri: root_uri, status: :starting})

        params = Protocol.initialize_params(root_uri)
        send_request(port, id, "initialize", params)

        state = %{state | pending_requests: Map.put(state.pending_requests, id, {:initialize, from})}
        {:noreply, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:get_diagnostics, file_path}, _from, state) do
    uri = Protocol.path_to_uri(file_path)
    diags = Map.get(state.diagnostics, uri, [])
    {:reply, {:ok, diags}, state}
  end

  def handle_call(:all_diagnostics, _from, state) do
    {:reply, {:ok, state.diagnostics}, state}
  end

  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  def handle_call(:shutdown, from, state) do
    if state.port do
      {id, state} = next_id(state)
      send_request(state.port, id, "shutdown", nil)
      state = %{state | pending_requests: Map.put(state.pending_requests, id, {:shutdown, from})}
      {:noreply, state}
    else
      {:reply, :ok, %{state | status: :stopped}}
    end
  end

  @impl true
  def handle_cast({:did_open, file_path, language_id}, state) do
    if state.initialized do
      uri = Protocol.path_to_uri(file_path)

      text =
        case File.read(file_path) do
          {:ok, content} -> content
          {:error, _} -> ""
        end

      params = Protocol.did_open_params(uri, language_id, text)
      send_notification(state.port, "textDocument/didOpen", params)
    end

    {:noreply, state}
  end

  def handle_cast({:did_close, file_path}, state) do
    if state.initialized do
      uri = Protocol.path_to_uri(file_path)
      params = Protocol.did_close_params(uri)
      send_notification(state.port, "textDocument/didClose", params)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    buffer = state.buffer <> IO.iodata_to_binary(data)
    state = process_buffer(%{state | buffer: buffer})
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    Logger.warning("[LSP:#{state.name}] Server exited with code #{code}")

    # Reply to any pending requests with error
    Enum.each(state.pending_requests, fn {_id, {_type, from}} ->
      if from, do: GenServer.reply(from, {:error, :server_exited})
    end)

    {:noreply, %{state | port: nil, status: :stopped, initialized: false, pending_requests: %{}}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.port do
      try do
        Port.close(state.port)
      catch
        _, _ -> :ok
      end
    end

    :ok
  end

  # --- Private ---

  defp via(name) do
    {:via, Registry, {Loom.LSP.Registry, name}}
  end

  defp start_server(state) do
    cmd = state.command
    args = state.args

    try do
      port =
        Port.open({:spawn_executable, find_executable(cmd)}, [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          args: args
        ])

      {:ok, port}
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  defp find_executable(cmd) do
    case System.find_executable(cmd) do
      nil -> raise "executable not found: #{cmd}"
      path -> path
    end
  end

  defp send_request(port, id, method, params) do
    msg = Protocol.encode_request(id, method, params || %{})
    Port.command(port, msg)
  end

  defp send_notification(port, method, params) do
    msg = Protocol.encode_notification(method, params)
    Port.command(port, msg)
  end

  defp next_id(state) do
    id = state.request_id + 1
    {id, %{state | request_id: id}}
  end

  defp process_buffer(state) do
    case Protocol.extract_message(state.buffer) do
      {:ok, msg, remaining} ->
        state = handle_lsp_message(msg, %{state | buffer: remaining})
        # There might be more messages in the buffer
        process_buffer(state)

      {:incomplete, _} ->
        state

      {:error, reason} ->
        Logger.warning("[LSP:#{state.name}] Failed to decode message: #{inspect(reason)}")
        state
    end
  end

  defp handle_lsp_message(%{:type => :response, "id" => id} = msg, state) do
    case Map.pop(state.pending_requests, id) do
      {{:initialize, from}, pending} ->
        # Send initialized notification
        send_notification(state.port, "initialized", %{})
        if from, do: GenServer.reply(from, {:ok, msg["result"]})
        Logger.info("[LSP:#{state.name}] Initialized successfully")

        %{state | pending_requests: pending, initialized: true, status: :ready}

      {{:shutdown, from}, pending} ->
        # Send exit notification
        send_notification(state.port, "exit", %{})
        GenServer.reply(from, :ok)

        %{state | pending_requests: pending, status: :stopped}

      {nil, _} ->
        Logger.debug("[LSP:#{state.name}] Response for unknown request #{id}")
        state
    end
  end

  defp handle_lsp_message(
         %{:type => :notification, "method" => "textDocument/publishDiagnostics", "params" => params},
         state
       ) do
    uri = params["uri"]

    diagnostics =
      (params["diagnostics"] || [])
      |> Enum.map(fn diag ->
        range = diag["range"] || %{}
        start_pos = range["start"] || %{}

        %{
          line: (start_pos["line"] || 0) + 1,
          character: (start_pos["character"] || 0) + 1,
          severity: Protocol.severity_name(diag["severity"] || 0),
          message: diag["message"] || "",
          source: diag["source"] || "",
          code: diag["code"]
        }
      end)

    %{state | diagnostics: Map.put(state.diagnostics, uri, diagnostics)}
  end

  defp handle_lsp_message(%{:type => :error_response, "id" => id, "error" => error}, state) do
    case Map.pop(state.pending_requests, id) do
      {{_type, from}, pending} ->
        if from, do: GenServer.reply(from, {:error, error})
        %{state | pending_requests: pending}

      {nil, _} ->
        Logger.warning("[LSP:#{state.name}] Error response for unknown request: #{inspect(error)}")
        state
    end
  end

  defp handle_lsp_message(%{"method" => method}, state) do
    Logger.debug("[LSP:#{state.name}] Unhandled notification: #{method}")
    state
  end

  defp handle_lsp_message(_msg, state), do: state
end
