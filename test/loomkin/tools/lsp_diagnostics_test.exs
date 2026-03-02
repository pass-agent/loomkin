defmodule Loomkin.Tools.LspDiagnosticsTest do
  use ExUnit.Case, async: false

  alias Loomkin.Tools.LspDiagnostics

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    # Create a test file
    File.write!(Path.join(tmp_dir, "test.ex"), """
    defmodule Test do
      def hello, do: :world
    end
    """)

    # The LSP Registry is already started by Loomkin.LSP.Supervisor in the application.

    %{project_path: tmp_dir}
  end

  test "action metadata is correct" do
    assert LspDiagnostics.name() == "lsp_diagnostics"
    assert is_binary(LspDiagnostics.description())
  end

  test "returns helpful message when no LSP servers are connected", %{project_path: proj} do
    params = %{file_path: "test.ex"}
    context = %{project_path: proj}

    assert {:ok, %{result: result}} = LspDiagnostics.run(params, context)
    assert result =~ "No LSP servers connected"
    assert result =~ ".loomkin.toml"
  end

  test "rejects paths outside project directory", %{project_path: proj} do
    params = %{file_path: "../../../etc/passwd"}
    context = %{project_path: proj}

    assert {:error, _} = LspDiagnostics.run(params, context)
  end
end
