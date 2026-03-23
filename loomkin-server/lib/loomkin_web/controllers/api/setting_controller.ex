defmodule LoomkinWeb.Api.SettingController do
  use LoomkinWeb, :controller

  alias Loomkin.Settings.Registry

  @doc "GET /api/v1/settings"
  def index(conn, _params) do
    values = Registry.current_values()

    settings =
      Registry.all()
      |> Enum.map(fn setting ->
        key_str = Registry.key_string(setting.key)

        %{
          key: key_str,
          label: setting.label,
          description: setting.description,
          type: setting.type,
          default: setting.default,
          value: Map.get(values, key_str),
          tab: setting.tab,
          section: setting.section,
          options: setting.options,
          range: serialize_range(setting.range),
          unit: setting.unit,
          step: setting.step
        }
      end)

    json(conn, %{settings: settings})
  end

  @doc "PUT /api/v1/settings"
  def update(conn, %{"settings" => settings_map}) when is_map(settings_map) do
    results =
      Enum.map(settings_map, fn {key, value} ->
        case Registry.by_key(key) do
          nil ->
            {key, {:error, "unknown setting"}}

          setting ->
            case Registry.validate(setting, value) do
              :ok ->
                Loomkin.Config.put(setting.key, value)
                {key, :ok}

              {:error, reason} ->
                {key, {:error, reason}}
            end
        end
      end)

    errors =
      results
      |> Enum.filter(fn {_key, result} -> match?({:error, _}, result) end)
      |> Map.new(fn {key, {:error, reason}} -> {key, reason} end)

    if map_size(errors) == 0 do
      json(conn, %{message: "settings updated", values: Registry.current_values()})
    else
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{error: "validation_failed", errors: errors})
    end
  end

  defp serialize_range(nil), do: nil
  defp serialize_range({min, max}), do: %{min: min, max: max}
end
