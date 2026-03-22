defmodule Loomkin.Tools.RegistryTest do
  use ExUnit.Case, async: true

  alias Loomkin.Tools.Registry

  test "all/0 returns a list of tool modules" do
    tools = Registry.all()
    assert is_list(tools)
    assert length(tools) >= 6
    assert Loomkin.Tools.FileRead in tools
    assert Loomkin.Tools.FileWrite in tools
    assert Loomkin.Tools.FileEdit in tools
    assert Loomkin.Tools.FileSearch in tools
    assert Loomkin.Tools.ContentSearch in tools
    assert Loomkin.Tools.DirectoryList in tools
  end

  test "definitions/0 returns tool definitions" do
    defs = Registry.definitions()
    assert is_list(defs)
    names = Enum.map(defs, fn d -> d.name end)
    assert "file_read" in names
    assert "file_write" in names
    assert "file_edit" in names
    assert "file_search" in names
    assert "content_search" in names
    assert "directory_list" in names
  end

  test "find/1 returns tool module by name" do
    assert {:ok, Loomkin.Tools.FileRead} = Registry.find("file_read")
    assert {:ok, Loomkin.Tools.FileWrite} = Registry.find("file_write")
  end

  test "find/1 returns error for unknown tool" do
    assert {:error, msg} = Registry.find("nonexistent_tool")
    assert msg =~ "Unknown tool"
  end

  @tag :tmp_dir
  test "execute/3 runs a tool by name", %{tmp_dir: tmp_dir} do
    file = Path.join(tmp_dir, "exec_test.txt")
    File.write!(file, "test content\n")

    assert {:ok, %{result: result}} =
             Registry.execute("file_read", %{"file_path" => "exec_test.txt"}, %{
               project_path: tmp_dir
             })

    assert result =~ "test content"
  end

  @tag :tmp_dir
  test "execute/3 returns error for unknown tool", %{tmp_dir: tmp_dir} do
    assert {:error, msg} = Registry.execute("bad_tool", %{}, %{project_path: tmp_dir})
    assert msg =~ "Unknown tool"
  end

  describe "atomize_keys/1 (bounded atom creation)" do
    test "converts known tool parameter keys to atoms" do
      input = %{"file_path" => "foo.ex", "content" => "bar"}
      result = Registry.atomize_keys(input)
      assert result == %{file_path: "foo.ex", content: "bar"}
    end

    test "keeps unknown keys as strings" do
      input = %{"file_path" => "foo.ex", "hallucinated_param" => "value"}
      result = Registry.atomize_keys(input)
      assert result[:file_path] == "foo.ex"
      assert result["hallucinated_param"] == "value"
    end

    test "does not create atoms for arbitrary LLM output" do
      # Simulate LLM sending random keys that shouldn't become atoms
      random_keys = for i <- 1..100, do: {"random_key_#{i}", "val_#{i}"}
      input = Map.new(random_keys)
      result = Registry.atomize_keys(input)

      # All keys should remain strings since they're not in the known set
      Enum.each(result, fn {k, _v} -> assert is_binary(k) end)
    end

    test "handles nested maps" do
      input = %{"args" => %{"file_path" => "test.ex"}}
      result = Registry.atomize_keys(input)
      assert result[:args] == %{file_path: "test.ex"}
    end

    test "handles lists of maps" do
      input = [%{"command" => "echo hi"}, %{"unknown" => "stays string"}]
      result = Registry.atomize_keys(input)
      assert [%{command: "echo hi"}, %{"unknown" => "stays string"}] = result
    end

    test "passes through non-map non-list values" do
      assert Registry.atomize_keys("hello") == "hello"
      assert Registry.atomize_keys(42) == 42
      assert Registry.atomize_keys(nil) == nil
    end
  end
end
