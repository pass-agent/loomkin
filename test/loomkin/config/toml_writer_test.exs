defmodule Loomkin.Config.TomlWriterTest do
  use ExUnit.Case, async: true

  alias Loomkin.Config.TomlWriter

  describe "encode/1" do
    test "encodes simple key-value pairs" do
      result = TomlWriter.encode(%{name: "test", count: 42, enabled: true})

      assert result =~ ~s(name = "test")
      assert result =~ "count = 42"
      assert result =~ "enabled = true"
    end

    test "encodes nested tables" do
      result = TomlWriter.encode(%{model: %{default: "zai:glm-5", editor: nil}})

      assert result =~ "[model]"
      assert result =~ ~s(default = "zai:glm-5")
    end

    test "encodes deeply nested tables" do
      result =
        TomlWriter.encode(%{
          teams: %{consensus: %{quorum: "majority", max_rounds: 3}}
        })

      assert result =~ "[teams.consensus]"
      assert result =~ ~s(quorum = "majority")
      assert result =~ "max_rounds = 3"
    end

    test "encodes lists" do
      result = TomlWriter.encode(%{permissions: %{auto_approve: ["file_read", "shell"]}})

      assert result =~ "[permissions]"
      assert result =~ ~s(auto_approve = ["file_read", "shell"])
    end

    test "encodes booleans" do
      result = TomlWriter.encode(%{flags: %{on: true, off: false}})

      assert result =~ "on = true"
      assert result =~ "off = false"
    end

    test "encodes floats" do
      result = TomlWriter.encode(%{budget: %{amount: 5.0}})

      assert result =~ "[budget]"
      assert result =~ "amount = 5.0"
    end

    test "escapes strings with special characters" do
      result = TomlWriter.encode(%{path: "C:\\Users\\test"})

      assert result =~ ~s(path = "C:\\\\Users\\\\test")
    end

    test "round-trips through Toml parser" do
      original = %{
        model: %{default: "zai:glm-5"},
        permissions: %{auto_approve: ["file_read", "shell"]},
        context: %{max_repo_map_tokens: 2048, reserved_output_tokens: 4096},
        decisions: %{enabled: true, enforce_pre_edit: false}
      }

      toml_string = TomlWriter.encode(original)
      {:ok, parsed} = Toml.decode(toml_string)

      assert parsed["model"]["default"] == "zai:glm-5"
      assert parsed["permissions"]["auto_approve"] == ["file_read", "shell"]
      assert parsed["context"]["max_repo_map_tokens"] == 2048
      assert parsed["decisions"]["enabled"] == true
    end
  end
end
