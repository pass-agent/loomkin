defmodule LoomkinCli.Main do
  @moduledoc """
  Escript entry point for the Loomkin CLI.
  """

  def main(args) do
    {opts, rest, _invalid} =
      OptionParser.parse(args,
        strict: [
          model: :string,
          project: :string,
          yes: :boolean,
          resume: :string,
          help: :boolean,
          version: :boolean
        ],
        aliases: [
          m: :model,
          p: :project,
          y: :yes,
          r: :resume,
          h: :help,
          v: :version
        ]
      )

    cond do
      opts[:help] ->
        print_help()

      opts[:version] ->
        IO.puts("loom v#{Loomkin.version()}")

      true ->
        boot(opts, rest)
    end
  end

  defp boot(opts, rest) do
    # Ensure the application is started (Repo, Config, supervisors)
    Application.ensure_all_started(:loomkin)

    project_path = opts[:project] || File.cwd!()
    Loomkin.Config.load(project_path)

    # Initialize repo index with the actual project path.
    # Start the Index if it wasn't started by the supervision tree.
    case GenServer.whereis(Loomkin.RepoIntel.Index) do
      nil -> Loomkin.RepoIntel.Index.start_link(project_path: project_path)
      _pid -> Loomkin.RepoIntel.Index.set_project(project_path)
    end

    # Apply CLI overrides
    if model = opts[:model] do
      Loomkin.Config.put(:model, %{
        default: model,
        editor: Loomkin.Config.get(:model, :editor)
      })
    end

    cli_opts = %{
      project_path: project_path,
      auto_approve: opts[:yes] || false,
      resume: opts[:resume]
    }

    case rest do
      [] ->
        # Interactive mode
        LoomkinCli.Interactive.start(cli_opts)

      prompt_parts ->
        # Oneshot mode — join remaining args as the prompt
        prompt = Enum.join(prompt_parts, " ")
        LoomkinCli.Interactive.oneshot(prompt, cli_opts)
    end
  end

  defp print_help do
    IO.puts("""
    loom - An Elixir-native AI coding assistant

    Usage:
      loom [options] [prompt]

    Options:
      -m, --model MODEL      Model to use (default from config)
      -p, --project PATH     Project path (default: current directory)
      -y, --yes              Auto-approve all permission prompts
      -r, --resume ID        Resume a previous session by ID
      -h, --help             Show this help message
      -v, --version          Show version

    Examples:
      loom                          Start interactive session
      loom "explain this codebase"  Run a single prompt
      loom -m anthropic:claude-opus-4-6 "refactor this function"
      loom -r abc123                Resume session abc123

    Interactive commands:
      /quit, /exit    Exit the session
      /history        Show conversation history
      /sessions       List all sessions
      /model          Show or change the model
      /help           Show available commands
      /clear          Clear the terminal
    """)
  end
end
