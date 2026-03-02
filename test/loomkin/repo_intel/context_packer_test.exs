defmodule Loomkin.RepoIntel.ContextPackerTest do
  use ExUnit.Case, async: true

  alias Loomkin.RepoIntel.ContextPacker

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, "lib"))

    File.write!(Path.join(tmp_dir, "lib/important.ex"), """
    defmodule Important do
      def critical_function, do: :ok
    end
    """)

    File.write!(Path.join(tmp_dir, "lib/medium.ex"), """
    defmodule Medium do
      def helper, do: :ok
    end
    """)

    File.write!(Path.join(tmp_dir, "lib/low.ex"), "defmodule Low do end\n")

    %{tmp_dir: tmp_dir}
  end

  describe "pack/3" do
    test "includes full content for high-score files", %{tmp_dir: tmp_dir} do
      ranked = [
        {"lib/important.ex", %{language: :elixir, size: 60}, 150},
        {"lib/medium.ex", %{language: :elixir, size: 40}, 15},
        {"lib/low.ex", %{language: :elixir, size: 20}, 3}
      ]

      result = ContextPacker.pack(ranked, 2048, project_path: tmp_dir)

      # High-relevance file should have full content with code block
      assert result =~ "```elixir"
      assert result =~ "critical_function"
      assert result =~ "relevance: high"
    end

    test "includes symbols for medium-score files", %{tmp_dir: tmp_dir} do
      ranked = [
        {"lib/medium.ex", %{language: :elixir, size: 40}, 15}
      ]

      result = ContextPacker.pack(ranked, 2048, project_path: tmp_dir)

      assert result =~ "relevance: medium"
      assert result =~ "Medium"
    end

    test "includes only path for low-score files", %{tmp_dir: tmp_dir} do
      ranked = [
        {"lib/low.ex", %{language: :elixir, size: 20}, 3}
      ]

      result = ContextPacker.pack(ranked, 2048, project_path: tmp_dir)

      assert result =~ "lib/low.ex"
    end

    test "respects token budget", %{tmp_dir: tmp_dir} do
      # Create a file with lots of content
      big_content = String.duplicate("defmodule Big do\n  def f, do: :ok\nend\n", 100)
      File.write!(Path.join(tmp_dir, "lib/big.ex"), big_content)

      ranked = [
        {"lib/big.ex", %{language: :elixir, size: byte_size(big_content)}, 150},
        {"lib/important.ex", %{language: :elixir, size: 60}, 120},
        {"lib/medium.ex", %{language: :elixir, size: 40}, 15}
      ]

      # Very small budget — should truncate
      result = ContextPacker.pack(ranked, 50, project_path: tmp_dir)

      # Should stay within budget (50 tokens * 4 chars = 200 chars)
      assert byte_size(result) <= 200 + 50
    end

    test "handles empty ranked list" do
      result = ContextPacker.pack([], 2048)
      assert result =~ "## Project Context"
    end
  end
end
