defmodule Loomkin.Auth.OpenAICallbackServer do
  @moduledoc """
  On-demand Bandit server for OpenAI OAuth callback handling.

  OpenAI's shared Codex client redirects to `http://localhost:1455/auth/callback`.
  This server is started lazily when an OpenAI OAuth flow is initiated.
  """

  @entry_key {__MODULE__, :entry}
  @default_port 1455
  @default_idle_timeout_ms :timer.minutes(5)

  @type entry :: %{owner_pid: pid(), bandit_pid: pid(), nonce: reference()}

  @spec ensure_started() :: :ok | {:error, term()}
  def ensure_started do
    case current_entry() do
      %{owner_pid: owner_pid} = entry when is_pid(owner_pid) ->
        if Process.alive?(owner_pid) do
          touch_idle_timeout(entry)
          :ok
        else
          start_server()
        end

      _ ->
        start_server()
    end
  end

  @spec stop() :: :ok
  def stop do
    case current_entry() do
      %{owner_pid: owner_pid} when is_pid(owner_pid) ->
        if Process.alive?(owner_pid), do: send(owner_pid, :stop)

      _ ->
        :ok
    end

    :persistent_term.erase(@entry_key)
    :ok
  end

  @spec stop_async() :: :ok
  def stop_async do
    _ = Task.start(fn -> stop() end)
    :ok
  end

  defp start_server do
    parent = self()
    port = Application.get_env(:loomkin, :openai_callback_port, @default_port)

    owner_pid =
      spawn(fn ->
        Process.flag(:trap_exit, true)

        case Bandit.start_link(
               plug: Loomkin.Auth.OpenAICallbackPlug,
               scheme: :http,
               ip: {127, 0, 0, 1},
               port: port
             ) do
          {:ok, bandit_pid} ->
            send(parent, {:openai_callback_server_started, self(), bandit_pid})

            receive do
              :stop ->
                Process.exit(bandit_pid, :shutdown)
                await_bandit_exit(bandit_pid)
            end

          {:error, reason} ->
            send(parent, {:openai_callback_server_failed, reason})
        end
      end)

    receive do
      {:openai_callback_server_started, ^owner_pid, bandit_pid} ->
        entry = %{owner_pid: owner_pid, bandit_pid: bandit_pid, nonce: make_ref()}
        :persistent_term.put(@entry_key, entry)
        touch_idle_timeout(entry)
        :ok

      {:openai_callback_server_failed, reason} ->
        {:error, reason}
    after
      2_000 ->
        {:error, :start_timeout}
    end
  end

  defp await_bandit_exit(bandit_pid) do
    receive do
      {:EXIT, ^bandit_pid, _reason} -> :ok
    after
      1_000 -> :ok
    end
  end

  defp current_entry do
    :persistent_term.get(@entry_key, nil)
  end

  defp touch_idle_timeout(%{owner_pid: owner_pid, bandit_pid: bandit_pid}) do
    nonce = make_ref()
    updated = %{owner_pid: owner_pid, bandit_pid: bandit_pid, nonce: nonce}
    :persistent_term.put(@entry_key, updated)

    timeout_ms =
      Application.get_env(:loomkin, :openai_callback_idle_timeout_ms, @default_idle_timeout_ms)

    _ = :timer.apply_after(timeout_ms, __MODULE__, :stop_if_current, [owner_pid, nonce])
    :ok
  end

  @doc false
  def stop_if_current(owner_pid, nonce) do
    case current_entry() do
      %{owner_pid: ^owner_pid, nonce: ^nonce} -> stop()
      _ -> :ok
    end
  end
end
