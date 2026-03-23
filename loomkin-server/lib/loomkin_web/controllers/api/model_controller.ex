defmodule LoomkinWeb.Api.ModelController do
  use LoomkinWeb, :controller

  alias Loomkin.Models

  @doc "GET /api/v1/models"
  def index(conn, _params) do
    models =
      Models.available_models_enriched()
      |> Enum.map(fn {provider_name, model_list} ->
        %{
          provider: provider_name,
          models:
            Enum.map(model_list, fn {label, id, ctx_label} ->
              %{label: label, id: id, context: ctx_label}
            end)
        }
      end)

    json(conn, %{models: models})
  end

  @doc "GET /api/v1/models/providers"
  def providers(conn, _params) do
    providers =
      Models.all_providers_enriched()
      |> Enum.map(fn {provider_atom, display_name, status, model_list} ->
        %{
          id: provider_atom,
          name: display_name,
          status: serialize_status(status),
          models:
            Enum.map(model_list, fn {label, id, ctx_label} ->
              %{label: label, id: id, context: ctx_label}
            end)
        }
      end)

    json(conn, %{providers: providers})
  end

  defp serialize_status({:set, env_var}), do: %{type: "api_key", status: "set", env_var: env_var}

  defp serialize_status({:oauth, status}),
    do: %{type: "oauth", status: to_string(status)}

  defp serialize_status({:missing, env_var}),
    do: %{type: "api_key", status: "missing", env_var: env_var}

  defp serialize_status(:local), do: %{type: "local", status: "available"}
  defp serialize_status(:local_offline), do: %{type: "local", status: "offline"}
end
