defmodule Loomkin.Kindred.Resolver do
  @moduledoc """
  Layered resolution of kin agents from kindred bundles.

  Resolution order:
  1. If workspace has an organization → load org's active kindred
  2. If user has personal active kindred → load it
  3. Fall back to `Kin.list_by_potency/1` (current behavior)

  Merge strategy when org kindred exists:
  - Enforcement "required": ONLY org kindred items
  - Enforcement "defaults": org kindred as base, user overrides by name
  """

  alias Loomkin.Kindred, as: KindredContext
  alias Loomkin.Schemas.Organization

  @doc """
  Resolve kin agents for a workspace+user combination.

  Returns a list of maps compatible with `Manager.spawn_agent/4` kin_agents parameter.
  """
  @spec resolve(map() | nil, map() | nil) :: [map()]
  def resolve(workspace, user)

  def resolve(nil, nil), do: fallback()
  def resolve(nil, user), do: resolve_for_user(user)

  def resolve(%{organization_id: nil} = _workspace, nil), do: fallback()
  def resolve(%{organization_id: nil} = _workspace, user), do: resolve_for_user(user)

  def resolve(%{organization_id: org_id} = _workspace, user) when is_binary(org_id) do
    org = Loomkin.Organizations.get_organization(org_id)
    resolve_with_org(org, user)
  end

  def resolve(_workspace, user), do: resolve_for_user(user)

  # --- Private ---

  defp resolve_with_org(nil, user), do: resolve_for_user(user)

  defp resolve_with_org(%Organization{} = org, user) do
    case KindredContext.active_kindred_for_org(org) do
      nil ->
        resolve_for_user(user)

      org_kindred ->
        enforcement = get_in(org.settings, ["kindred_enforcement"]) || "defaults"
        org_agents = items_to_kin_agents(org_kindred.items)

        case enforcement do
          "required" ->
            org_agents

          _ ->
            # "defaults" — org base, user overrides by name
            user_agents =
              if user do
                case KindredContext.active_kindred_for_user(user) do
                  nil -> []
                  user_kindred -> items_to_kin_agents(user_kindred.items)
                end
              else
                []
              end

            merge_agents(org_agents, user_agents)
        end
    end
  end

  defp resolve_for_user(nil), do: fallback()

  defp resolve_for_user(user) do
    case KindredContext.active_kindred_for_user(user) do
      nil -> fallback()
      kindred -> items_to_kin_agents(kindred.items)
    end
  end

  defp fallback do
    try do
      Loomkin.Kin.list_by_potency(21)
    rescue
      _ -> []
    end
  end

  defp items_to_kin_agents(items) do
    items
    |> Enum.filter(&(&1.item_type == :kin_config))
    |> Enum.map(&item_to_kin_agent/1)
  end

  defp item_to_kin_agent(item) do
    content = item.content || %{}

    %{
      name: content["name"] || "agent-#{item.id}",
      role: parse_role(content["role"]),
      potency: content["potency"] || 50,
      auto_spawn: content["auto_spawn"] || false,
      model_override: content["model_override"],
      system_prompt_extra: content["system_prompt_extra"],
      tool_overrides: content["tool_overrides"] || %{},
      tags: content["tags"] || [],
      enabled: true
    }
  end

  defp parse_role(nil), do: :coder
  defp parse_role(role) when is_atom(role), do: role

  defp parse_role(role) when is_binary(role) do
    String.to_existing_atom(role)
  rescue
    _ -> :coder
  end

  defp merge_agents(org_agents, user_agents) do
    org_by_name = Map.new(org_agents, &{&1.name, &1})
    user_by_name = Map.new(user_agents, &{&1.name, &1})

    # User overrides org by name, new user agents are appended
    merged = Map.merge(org_by_name, user_by_name)
    Map.values(merged)
  end

  @doc """
  Resolve skills for a workspace+user combination.

  Extends the standard Skills.Resolver with kindred skill references.
  """
  @spec resolve_skills(map() | nil, map() | nil) :: [map()]
  def resolve_skills(workspace, user) do
    kindred = resolve_active_kindred(workspace, user)

    case kindred do
      nil ->
        []

      k ->
        k.items
        |> Enum.filter(&(&1.item_type == :skill_ref))
        |> Enum.map(fn item ->
          %{
            name: item.content["skill_name"] || "skill-#{item.id}",
            snippet_id: item.content["snippet_id"],
            inline_body: item.content["inline_body"]
          }
        end)
    end
  end

  defp resolve_active_kindred(nil, nil), do: nil

  defp resolve_active_kindred(nil, user) when not is_nil(user),
    do: KindredContext.active_kindred_for_user(user)

  defp resolve_active_kindred(%{organization_id: org_id}, user) when is_binary(org_id) do
    org = Loomkin.Organizations.get_organization(org_id)

    if org do
      KindredContext.active_kindred_for_org(org) || user_kindred_or_nil(user)
    else
      user_kindred_or_nil(user)
    end
  end

  defp resolve_active_kindred(_workspace, nil), do: nil

  defp resolve_active_kindred(_workspace, user) do
    KindredContext.active_kindred_for_user(user)
  end

  defp user_kindred_or_nil(nil), do: nil
  defp user_kindred_or_nil(user), do: KindredContext.active_kindred_for_user(user)
end
