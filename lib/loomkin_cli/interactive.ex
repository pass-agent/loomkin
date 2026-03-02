defmodule LoomkinCli.Interactive do
  @moduledoc """
  Interactive REPL loop for Loomkin CLI.
  """

  alias LoomkinCli.Renderer
  alias Loomkin.Session
  alias Loomkin.Session.Manager
  alias Loomkin.Tools.Registry

  @doc """
  Start an interactive REPL session.
  """
  def start(opts) do
    Renderer.render_welcome(opts)

    session_pid = start_or_resume_session(opts)
    loop(session_pid, opts)
  end

  @doc """
  Execute a single prompt and exit.
  """
  def oneshot(prompt, opts) do
    Renderer.render_welcome(opts)

    IO.puts(IO.ANSI.faint() <> "  Prompt: " <> IO.ANSI.reset() <> prompt)
    IO.puts("")

    session_pid = start_or_resume_session(opts)

    case session_pid do
      nil ->
        Renderer.render_error("Failed to start session.")

      pid ->
        run_message(pid, prompt)
        GenServer.stop(pid, :normal)
    end
  end

  # --- Session Setup ---

  defp start_or_resume_session(opts) do
    project_path = opts[:project_path] || File.cwd!()
    model = Loomkin.Config.get(:model, :default) || "anthropic:claude-sonnet-4-6"

    session_opts = [
      model: model,
      project_path: project_path,
      tools: Registry.all(),
      auto_approve: opts[:auto_approve] || false
    ]

    session_opts =
      if resume_id = opts[:resume] do
        Keyword.put(session_opts, :session_id, resume_id)
      else
        session_opts
      end

    case Manager.start_session(session_opts) do
      {:ok, pid} ->
        IO.puts(
          IO.ANSI.faint() <>
            "  Session started (model: #{model})" <>
            IO.ANSI.reset()
        )

        IO.puts("")
        pid

      {:error, reason} ->
        Renderer.render_error("Failed to start session: #{inspect(reason)}")
        nil
    end
  end

  # --- REPL loop ---

  defp loop(nil, _opts) do
    Renderer.render_error("No active session. Exiting.")
  end

  defp loop(session_pid, opts) do
    prompt_text = IO.ANSI.cyan() <> "loom> " <> IO.ANSI.reset()

    case IO.gets(prompt_text) do
      :eof ->
        IO.puts("\nGoodbye!")

      {:error, _reason} ->
        IO.puts("\nGoodbye!")

      input ->
        input
        |> to_string()
        |> String.trim()
        |> handle_input(session_pid, opts)
    end
  end

  defp handle_input("", session_pid, opts), do: loop(session_pid, opts)

  defp handle_input(command, _session_pid, _opts) when command in ["/quit", "/exit"] do
    IO.puts(IO.ANSI.faint() <> "Goodbye!" <> IO.ANSI.reset())
  end

  defp handle_input("/help", session_pid, opts) do
    IO.puts("""

    #{IO.ANSI.bright()}Available commands:#{IO.ANSI.reset()}
      /quit, /exit    Exit the session
      /history        Show conversation history
      /sessions       List all sessions
      /model          Show or change the current model
      /model          Show current model configuration
      /help           Show this help message
      /clear          Clear the terminal

    Type anything else to chat with the AI.
    """)

    loop(session_pid, opts)
  end

  defp handle_input("/clear", session_pid, opts) do
    IO.write(IO.ANSI.clear() <> IO.ANSI.home())
    loop(session_pid, opts)
  end

  defp handle_input("/model", session_pid, opts) do
    model = Loomkin.Config.get(:model, :default)
    editor = Loomkin.Config.get(:model, :editor)

    IO.puts("""

    #{IO.ANSI.bright()}Current models:#{IO.ANSI.reset()}
      Primary: #{model}
      Editor:  #{editor || "(same as primary)"}
    """)

    loop(session_pid, opts)
  end

  defp handle_input("/history", session_pid, opts) do
    case Session.get_history(session_pid) do
      {:ok, messages} ->
        if messages == [] do
          IO.puts(IO.ANSI.faint() <> "  No messages yet." <> IO.ANSI.reset())
        else
          Enum.each(messages, fn msg ->
            role_color =
              case msg.role do
                :user -> IO.ANSI.cyan()
                :assistant -> IO.ANSI.green()
                :tool -> IO.ANSI.yellow()
                :system -> IO.ANSI.faint()
                _ -> ""
              end

            IO.puts(role_color <> "  [#{msg.role}] " <> IO.ANSI.reset() <> String.slice(msg.content || "", 0, 120))
          end)
        end

      _ ->
        IO.puts(IO.ANSI.yellow() <> "  Could not retrieve history." <> IO.ANSI.reset())
    end

    IO.puts("")
    loop(session_pid, opts)
  end

  defp handle_input("/sessions", session_pid, opts) do
    sessions = Manager.list_active()

    if sessions == [] do
      IO.puts(IO.ANSI.faint() <> "  No active sessions." <> IO.ANSI.reset())
    else
      IO.puts(IO.ANSI.bright() <> "  Active sessions:" <> IO.ANSI.reset())

      Enum.each(sessions, fn s ->
        IO.puts("    #{s.id} (#{s.status})")
      end)
    end

    IO.puts("")
    loop(session_pid, opts)
  end

  defp handle_input("/" <> unknown, session_pid, opts) do
    Renderer.render_error("Unknown command: /#{unknown}. Type /help for available commands.")
    loop(session_pid, opts)
  end

  defp handle_input(input, session_pid, opts) do
    run_message(session_pid, input)
    loop(session_pid, opts)
  end

  # --- Message Handling ---

  defp run_message(pid, text) do
    IO.puts("")
    IO.write(IO.ANSI.faint() <> "  Thinking..." <> IO.ANSI.reset())

    case Session.send_message(pid, text) do
      {:ok, response} ->
        # Clear the "Thinking..." line
        IO.write("\r" <> String.duplicate(" ", 40) <> "\r")
        Renderer.render_markdown(response)
        IO.puts("")

      {:error, reason} ->
        IO.write("\r" <> String.duplicate(" ", 40) <> "\r")
        Renderer.render_error("Error: #{inspect(reason)}")
        IO.puts("")
    end
  end
end
