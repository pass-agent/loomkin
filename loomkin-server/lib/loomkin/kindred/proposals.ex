defmodule Loomkin.Kindred.Proposals do
  @moduledoc "Manages kindred evolution proposals from reflection or users."

  import Ecto.Query

  alias Loomkin.Repo
  alias Loomkin.Schemas.KindredProposal

  def create_proposal(%{user: _user}, attrs) do
    %KindredProposal{}
    |> KindredProposal.changeset(attrs)
    |> Repo.insert()
  end

  def approve_proposal(%{user: user}, %KindredProposal{} = proposal) do
    with :ok <- authorize_proposal(user, proposal) do
      proposal
      |> KindredProposal.changeset(%{
        status: :approved,
        reviewed_by: user.id,
        reviewed_at: DateTime.utc_now()
      })
      |> Repo.update()
    end
  end

  def reject_proposal(%{user: user}, %KindredProposal{} = proposal, notes) do
    with :ok <- authorize_proposal(user, proposal) do
      proposal
      |> KindredProposal.changeset(%{
        status: :rejected,
        reviewed_by: user.id,
        reviewed_at: DateTime.utc_now(),
        review_notes: notes
      })
      |> Repo.update()
    end
  end

  def apply_proposal(%{user: _user} = scope, %KindredProposal{status: :approved} = proposal) do
    kindred = Loomkin.Kindred.get_kindred!(proposal.kindred_id)
    changes = proposal.changes || %{}

    Repo.transaction(fn ->
      case apply_item_changes(scope, kindred, changes) do
        :ok -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end

      case Loomkin.Kindred.publish_kindred(scope, kindred) do
        {:ok, _kindred} -> :ok
        {:error, changeset} -> Repo.rollback(changeset)
      end

      case proposal
           |> KindredProposal.changeset(%{status: :applied})
           |> Repo.update() do
        {:ok, applied} -> applied
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  def apply_proposal(_scope, _proposal), do: {:error, :not_approved}

  def list_pending_proposals(kindred_id) do
    KindredProposal
    |> where([p], p.kindred_id == ^kindred_id and p.status == :pending)
    |> order_by([p], desc: p.inserted_at)
    |> Repo.all()
  end

  def list_proposals_for_kindred(kindred_id) do
    KindredProposal
    |> where([p], p.kindred_id == ^kindred_id)
    |> order_by([p], desc: p.inserted_at)
    |> Repo.all()
  end

  def get_proposal(id), do: Repo.get(KindredProposal, id)

  # --- Private ---

  defp authorize_proposal(user, %KindredProposal{} = proposal) do
    kindred = Loomkin.Kindred.get_kindred(proposal.kindred_id)

    cond do
      is_nil(kindred) ->
        {:error, :not_found}

      kindred.user_id && kindred.user_id == user.id ->
        :ok

      kindred.organization_id ->
        role =
          Loomkin.Organizations.member_role(
            %Loomkin.Schemas.Organization{id: kindred.organization_id},
            user
          )

        if role in [:owner, :admin], do: :ok, else: {:error, :unauthorized}

      true ->
        {:error, :unauthorized}
    end
  end

  defp apply_item_changes(scope, kindred, changes) do
    results =
      for %{"type" => "kin_config_update", "target" => name} = change <-
            Map.get(changes, "recommendations", []) do
        items = Loomkin.Kindred.list_items(kindred)

        case Enum.find(items, fn i ->
               i.item_type == :kin_config && i.content["name"] == name
             end) do
          nil ->
            Loomkin.Kindred.add_item(scope, kindred, %{
              item_type: :kin_config,
              content: Map.get(change, "changes", %{}) |> Map.put("name", name)
            })

          item ->
            new_content = Map.merge(item.content, Map.get(change, "changes", %{}))
            Loomkin.Kindred.update_item(scope, item, %{content: new_content})
        end
      end

    skill_results =
      for %{"type" => "skill_addition"} = change <- Map.get(changes, "recommendations", []) do
        Loomkin.Kindred.add_item(scope, kindred, %{
          item_type: :skill_ref,
          content: %{
            "skill_name" => change["name"],
            "inline_body" => change["body"]
          }
        })
      end

    all_results = results ++ skill_results

    case Enum.find(all_results, fn
           {:error, _} -> true
           _ -> false
         end) do
      nil -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
