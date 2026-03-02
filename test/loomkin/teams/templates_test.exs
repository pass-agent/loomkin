defmodule Loomkin.Teams.TemplatesTest do
  use ExUnit.Case, async: false

  alias Loomkin.Teams.{Manager, Templates, TableRegistry}

  setup do
    # Store original teams config
    original = Loomkin.Config.get(:teams)

    on_exit(fn ->
      if original do
        Loomkin.Config.put(:teams, original)
      else
        # Remove if didn't exist
        Loomkin.Config.put(:teams, nil)
      end
    end)

    :ok
  end

  defp setup_templates(templates_map) do
    teams_config = %{templates: templates_map}
    Loomkin.Config.put(:teams, teams_config)
  end

  describe "list_templates/0" do
    test "returns empty list when no templates configured" do
      Loomkin.Config.put(:teams, %{})
      assert Templates.list_templates() == []
    end

    test "returns empty list when teams config is nil" do
      Loomkin.Config.put(:teams, nil)
      assert Templates.list_templates() == []
    end

    test "lists all configured templates" do
      setup_templates(%{
        research: %{
          agents: [
            %{name: "lead", role: "lead"},
            %{name: "researcher", role: "researcher", count: 2}
          ]
        },
        dev: %{
          agents: [
            %{name: "lead", role: "lead"},
            %{name: "coder", role: "coder"}
          ]
        }
      })

      templates = Templates.list_templates()
      assert length(templates) == 2
      names = Enum.map(templates, & &1.name) |> Enum.sort()
      assert names == ["dev", "research"]
    end
  end

  describe "get_template/1" do
    test "returns template by name" do
      setup_templates(%{
        myteam: %{
          agents: [
            %{name: "lead", role: "lead"},
            %{name: "coder", role: "coder", model: "anthropic:claude-sonnet-4-6"}
          ]
        }
      })

      assert {:ok, template} = Templates.get_template("myteam")
      assert template.name == "myteam"
      assert length(template.agents) == 2

      coder = Enum.find(template.agents, &(&1.name == "coder"))
      assert coder.role == :coder
      assert coder.model == "anthropic:claude-sonnet-4-6"
    end

    test "returns error for nonexistent template" do
      setup_templates(%{})
      assert {:error, :not_found} = Templates.get_template("nope")
    end

    test "parses count field" do
      setup_templates(%{
        scaled: %{
          agents: [
            %{name: "worker", role: "coder", count: 3}
          ]
        }
      })

      {:ok, template} = Templates.get_template("scaled")
      assert length(template.agents) == 1
      assert hd(template.agents).count == 3
    end
  end

  describe "spawn_from_template/3" do
    test "creates team and spawns agents from template" do
      setup_templates(%{
        basic: %{
          agents: [
            %{name: "lead", role: "lead"},
            %{name: "coder", role: "coder"}
          ]
        }
      })

      {:ok, team_id, agents} = Templates.spawn_from_template("test-team", "basic")
      assert is_binary(team_id)
      assert length(agents) == 2

      ok_agents = Enum.filter(agents, &(&1.status == :ok))
      assert length(ok_agents) == 2

      names = Enum.map(agents, & &1.name) |> Enum.sort()
      assert names == ["coder", "lead"]

      # Clean up
      Manager.dissolve_team(team_id)
    end

    test "expands agents with count > 1" do
      setup_templates(%{
        multi: %{
          agents: [
            %{name: "lead", role: "lead"},
            %{name: "worker", role: "coder", count: 3}
          ]
        }
      })

      {:ok, team_id, agents} = Templates.spawn_from_template("multi-team", "multi")
      assert length(agents) == 4

      worker_names =
        agents
        |> Enum.filter(&(&1.role == :coder))
        |> Enum.map(& &1.name)
        |> Enum.sort()

      assert worker_names == ["worker-1", "worker-2", "worker-3"]

      Manager.dissolve_team(team_id)
    end

    test "returns error for nonexistent template" do
      setup_templates(%{})

      assert {:error, :template_not_found} =
               Templates.spawn_from_template("my-team", "nonexistent")
    end
  end

  describe "save_template/2" do
    test "generates valid TOML string" do
      agents = [
        %{name: "lead", role: "lead"},
        %{name: "coder", role: "coder", count: 2}
      ]

      {:ok, toml} = Templates.save_template("my_template", agents)
      assert String.contains?(toml, "[teams.templates.my_template]")
      assert String.contains?(toml, "role = \"lead\"")
      assert String.contains?(toml, "role = \"coder\"")
    end
  end
end
