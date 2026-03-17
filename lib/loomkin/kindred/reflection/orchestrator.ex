defmodule Loomkin.Kindred.Reflection.Orchestrator do
  @moduledoc """
  Coordinates reflection runs at trigger points.

  NOT a long-running GenServer — a module called at trigger points:
  - run_on_demand/2: User clicks "Run Reflection"
  - run_on_milestone/2: Workspace milestone detected
  - run_checkpoint/1: Periodic workspace checkpoint
  """

  require Logger

  alias Loomkin.Kindred.Reflection.Agent, as: ReflectionAgent
  alias Loomkin.Kindred.Reflection.Collector
  alias Loomkin.Repo

  @doc "Run reflection on demand (user-triggered). Runs async via TaskSupervisor."
  @spec run_on_demand(String.t(), map()) :: :ok
  def run_on_demand(workspace_id, scope) do
    Task.Supervisor.start_child(Loomkin.Teams.TaskSupervisor, fn ->
      case run_reflection(workspace_id, scope, :on_demand) do
        {:ok, _result} ->
          Logger.info("[Reflection] On-demand reflection complete workspace=#{workspace_id}")

        {:error, reason} ->
          Logger.warning(
            "[Reflection] On-demand reflection failed workspace=#{workspace_id} reason=#{inspect(reason)}"
          )
      end
    end)

    :ok
  end

  @doc "Run reflection on workspace milestone."
  @spec run_on_milestone(String.t(), atom()) :: :ok
  def run_on_milestone(workspace_id, milestone_type) do
    Task.Supervisor.start_child(Loomkin.Teams.TaskSupervisor, fn ->
      case run_reflection(workspace_id, nil, milestone_type) do
        {:ok, _result} ->
          Logger.info(
            "[Reflection] Milestone reflection complete workspace=#{workspace_id} milestone=#{milestone_type}"
          )

        {:error, reason} ->
          Logger.warning(
            "[Reflection] Milestone reflection failed workspace=#{workspace_id} reason=#{inspect(reason)}"
          )
      end
    end)

    :ok
  end

  @doc "Run reflection at checkpoint."
  @spec run_checkpoint(String.t()) :: :ok
  def run_checkpoint(workspace_id) do
    run_on_milestone(workspace_id, :checkpoint)
  end

  # --- Private ---

  defp run_reflection(workspace_id, scope, trigger_type) do
    Logger.info(
      "[Reflection] Starting reflection workspace=#{workspace_id} trigger=#{trigger_type}"
    )

    # 1. Collect data
    collected = Collector.collect(workspace_id)

    # Skip if there's no meaningful data
    if collected.metrics_summary.total == 0 && collected.task_journal == [] do
      Logger.info("[Reflection] No data to reflect on, skipping")
      {:ok, %{skipped: true, reason: :no_data}}
    else
      # 2. Run reflection agent
      case ReflectionAgent.run(collected) do
        {:ok, result} ->
          # 3. Store report as snippet
          snippet_id = store_report_snippet(workspace_id, result, scope)

          # 4. Publish completion signal
          publish_completion(workspace_id, result, snippet_id)

          # 5. Create kindred proposal if applicable
          maybe_create_proposal(workspace_id, result, snippet_id, scope)

          {:ok, Map.put(result, :snippet_id, snippet_id)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp store_report_snippet(workspace_id, result, scope) do
    user_id = if scope, do: scope.user && scope.user.id, else: nil

    attrs = %{
      title: "Reflection Report #{DateTime.utc_now() |> Calendar.strftime("%Y-%m-%d %H:%M")}",
      type: :reflection_report,
      visibility: :private,
      content: %{
        "report" => result.report,
        "recommendations" => result.recommendations,
        "confidence" => result.confidence,
        "workspace_id" => workspace_id
      },
      user_id: user_id
    }

    case %Loomkin.Schemas.Snippet{}
         |> Loomkin.Schemas.Snippet.changeset(attrs)
         |> Repo.insert() do
      {:ok, snippet} -> snippet.id
      {:error, _} -> nil
    end
  end

  defp publish_completion(workspace_id, result, snippet_id) do
    Phoenix.PubSub.broadcast(
      Loomkin.PubSub,
      "workspace:#{workspace_id}",
      {:reflection_complete,
       %{
         workspace_id: workspace_id,
         snippet_id: snippet_id,
         confidence: result.confidence,
         recommendation_count: length(result.recommendations)
       }}
    )
  rescue
    _ -> :ok
  end

  defp maybe_create_proposal(workspace_id, result, snippet_id, scope) do
    if result.recommendations != [] && result.confidence >= 0.5 do
      # Find the workspace's active kindred
      workspace = Repo.get(Loomkin.Workspace, workspace_id)

      kindred =
        cond do
          workspace && workspace.organization_id ->
            org = Loomkin.Organizations.get_organization(workspace.organization_id)
            org && Loomkin.Kindred.active_kindred_for_org(org)

          scope && scope.user ->
            Loomkin.Kindred.active_kindred_for_user(scope.user)

          true ->
            nil
        end

      if kindred do
        Loomkin.Kindred.Proposals.create_proposal(
          scope || %{user: nil},
          %{
            kindred_id: kindred.id,
            reflection_snippet_id: snippet_id,
            proposed_by: "reflection_kin",
            changes: %{"recommendations" => result.recommendations},
            status: :pending
          }
        )
      end
    end
  end
end
