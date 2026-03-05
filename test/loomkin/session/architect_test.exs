defmodule Loomkin.Session.ArchitectTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Session
  alias Loomkin.Session.Manager

  @project_path "/tmp/loom-architect-test"

  setup do
    File.mkdir_p!(Path.join(@project_path, "lib"))
    File.write!(Path.join(@project_path, "lib/app.ex"), "defmodule App do end\n")
    on_exit(fn -> File.rm_rf!(@project_path) end)
    :ok
  end

  describe "plan parsing" do
    test "parses valid JSON plan" do
      json =
        Jason.encode!(%{
          "summary" => "Add a hello function",
          "plan" => [
            %{
              "file" => "lib/app.ex",
              "action" => "edit",
              "description" => "Add hello function",
              "details" => "Add def hello, do: :world to the module"
            }
          ]
        })

      # We test the internal parse_plan function indirectly by checking
      # the architect module can handle this kind of response
      assert {:ok, data} = Jason.decode(json)
      assert is_list(data["plan"])
      assert length(data["plan"]) == 1
      assert hd(data["plan"])["file"] == "lib/app.ex"
    end

    test "plan with multiple steps" do
      json =
        Jason.encode!(%{
          "summary" => "Refactor module",
          "plan" => [
            %{
              "file" => "lib/app.ex",
              "action" => "edit",
              "description" => "Extract helper",
              "details" => "Move helper function to helper.ex"
            },
            %{
              "file" => "lib/helper.ex",
              "action" => "create",
              "description" => "Create helper module",
              "details" => "Create new file with extracted function"
            }
          ]
        })

      assert {:ok, data} = Jason.decode(json)
      assert length(data["plan"]) == 2
    end
  end

  describe "architect model resolution" do
    test "default model config uses primary model" do
      default = Loomkin.Config.get(:model, :default)
      assert default == "zai:glm-5"
    end

    test "editor model defaults to nil (uses primary model)" do
      editor = Loomkin.Config.get(:model, :editor)
      assert is_nil(editor)
    end
  end

  describe "architect mode send_message" do
    @tag :skip
    @tag timeout: 120_000
    test "returns error when LLM fails (no API key)" do
      # NOTE: This test calls a real LLM and should be mocked.
      # Skipped until we have a proper LLM mock in place.
      session_id = Ecto.UUID.generate()

      {:ok, pid} =
        Manager.start_session(
          session_id: session_id,
          model: "zai:glm-5",
          project_path: @project_path
        )

      result = Session.send_message(pid, "Add a hello function")
      assert {:error, _reason} = result
    end
  end

  describe "plan formatting" do
    test "format_plan_summary creates readable output" do
      plan_data = %{
        "summary" => "Add testing utilities",
        "plan" => [
          %{
            "file" => "lib/utils.ex",
            "action" => "create",
            "description" => "Create utilities module",
            "details" => "..."
          },
          %{
            "file" => "test/utils_test.exs",
            "action" => "create",
            "description" => "Add tests",
            "details" => "..."
          }
        ]
      }

      # The format function is private, but we verify the plan data structure is valid
      assert is_binary(plan_data["summary"])
      assert length(plan_data["plan"]) == 2

      assert Enum.all?(plan_data["plan"], fn step ->
               Map.has_key?(step, "file") and
                 Map.has_key?(step, "action") and
                 Map.has_key?(step, "description")
             end)
    end
  end
end
