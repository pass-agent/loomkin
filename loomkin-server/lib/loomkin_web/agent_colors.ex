defmodule LoomkinWeb.AgentColors do
  @moduledoc "Consistent agent color assignment by name hash and role-based visual identity."

  @agent_colors [
    "#818cf8",
    "#34d399",
    "#f472b6",
    "#fb923c",
    "#22d3ee",
    "#a78bfa",
    "#fbbf24",
    "#f87171",
    "#4ade80",
    "#60a5fa"
  ]

  @agent_colors_count length(@agent_colors)

  @role_icons %{
    "lead" => "👑",
    "concierge" => "🌟",
    "researcher" => "🔬",
    "coder" => "⚡",
    "reviewer" => "🔍",
    "tester" => "🧪"
  }

  @doc "Return a deterministic hex color for the given agent name."
  def agent_color(name) when is_binary(name) do
    index = :erlang.phash2(name, @agent_colors_count)
    Enum.at(@agent_colors, index)
  end

  def agent_color(_), do: "#a1a1aa"

  @doc "Return a role icon emoji for the given role."
  def role_icon(role) when is_atom(role) do
    role |> to_string() |> role_icon()
  end

  def role_icon(role) when is_binary(role) do
    base = role |> String.downcase() |> String.split([" ", "-", "_"]) |> List.first()
    Map.get(@role_icons, base, "◆")
  end

  def role_icon(_), do: "◆"
end
