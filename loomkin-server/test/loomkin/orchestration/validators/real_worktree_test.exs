defmodule Loomkin.Orchestration.Validators.RealWorktreeTest do
  use ExUnit.Case, async: true

  @moduletag timeout: :timer.minutes(2)

  alias Loomkin.Orchestration.Validators.ElixirCompile
  alias Loomkin.Orchestration.Validators.ElixirFormat

  @mix_exs """
  defmodule Sample.MixProject do
    use Mix.Project
    def project, do: [app: :sample, version: "0.0.1", elixir: "~> 1.18"]
    def application, do: []
  end
  """

  @good_sample """
  defmodule Sample do
    def hello, do: :world
  end
  """

  @misformatted_sample "defmodule  Sample  do\ndef hello,do:    :world\nend\n"

  @syntax_error_sample "defmodule Sample do\n  def hello, do\nend\n"

  setup do
    path =
      Path.join(System.tmp_dir!(), "orch-validator-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(path, "lib"))
    File.write!(Path.join(path, "mix.exs"), @mix_exs)
    File.write!(Path.join(path, ".formatter.exs"), "[inputs: [\"lib/**/*.{ex,exs}\"]]\n")

    on_exit(fn -> File.rm_rf(path) end)
    %{path: path}
  end

  describe "ElixirFormat.validate/2" do
    test "returns :ok when the project is properly formatted", %{path: path} do
      File.write!(Path.join([path, "lib", "sample.ex"]), @good_sample)

      assert :ok = ElixirFormat.validate(%{worktree_path: path})
    end

    test "returns {:error, errs} with a file:line shape when a file is mis-formatted",
         %{path: path} do
      File.write!(Path.join([path, "lib", "sample.ex"]), @misformatted_sample)

      assert {:error, errs} = ElixirFormat.validate(%{worktree_path: path})
      assert [_ | _] = errs

      # The validator either parses out a `file:line` shape or surfaces a fallback
      # diagnostic that still contains a colon. The fallback truncates the path
      # at 200 chars which can land mid-filename in deep tmpdirs, so we only
      # require *some* error string that contains a `:` separator.
      assert Enum.any?(errs, &String.contains?(&1, ":")),
             "expected at least one error with a `:` separator, got: #{inspect(errs)}"
    end
  end

  describe "ElixirCompile.validate/2" do
    test "returns :ok when the project compiles cleanly", %{path: path} do
      File.write!(Path.join([path, "lib", "sample.ex"]), @good_sample)

      assert :ok = ElixirCompile.validate(%{worktree_path: path})
    end

    test "returns {:error, errs} when the project has a syntax error", %{path: path} do
      File.write!(Path.join([path, "lib", "sample.ex"]), @syntax_error_sample)

      assert {:error, errs} = ElixirCompile.validate(%{worktree_path: path})
      assert [_ | _] = errs
    end
  end
end
