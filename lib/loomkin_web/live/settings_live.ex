defmodule LoomkinWeb.SettingsLive do
  use LoomkinWeb, :live_view

  alias Loomkin.Settings.Registry
  import LoomkinWeb.SettingsComponents

  def mount(_params, _session, socket) do
    values = Registry.current_values()
    tabs = Registry.tabs()
    active_tab = List.first(tabs)

    {:ok,
     assign(socket,
       page_title: "Loomkin - Settings",
       active_tab: active_tab,
       tabs: tabs,
       sections: Registry.by_tab(active_tab),
       values: values,
       original_values: values,
       dirty: MapSet.new(),
       errors: %{}
     )}
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, active_tab: tab, sections: Registry.by_tab(tab))}
  end

  def handle_event("update_setting", params, socket) do
    {key_string, raw_value} = extract_setting_param(params)

    case Registry.by_key(key_string) do
      nil ->
        {:noreply, socket}

      setting ->
        value = cast_value(setting, raw_value)

        case Registry.validate(setting, value) do
          :ok ->
            values = Map.put(socket.assigns.values, key_string, value)
            errors = Map.delete(socket.assigns.errors, key_string)

            dirty =
              if value == Map.get(socket.assigns.original_values, key_string) do
                MapSet.delete(socket.assigns.dirty, key_string)
              else
                MapSet.put(socket.assigns.dirty, key_string)
              end

            {:noreply, assign(socket, values: values, dirty: dirty, errors: errors)}

          {:error, msg} ->
            values = Map.put(socket.assigns.values, key_string, value)
            errors = Map.put(socket.assigns.errors, key_string, msg)
            dirty = MapSet.put(socket.assigns.dirty, key_string)
            {:noreply, assign(socket, values: values, dirty: dirty, errors: errors)}
        end
    end
  end

  def handle_event("save_settings", _params, socket) do
    if MapSet.size(socket.assigns.dirty) == 0 or map_size(socket.assigns.errors) > 0 do
      {:noreply, socket}
    else
      Enum.each(socket.assigns.dirty, fn key_string ->
        setting = Registry.by_key(key_string)
        value = Map.get(socket.assigns.values, key_string)
        Loomkin.Config.put_nested(setting.key, value)
      end)

      project_path =
        case Loomkin.Config.get(:project_path) do
          nil -> File.cwd!()
          path -> path
        end

      case Loomkin.Config.save_to_file(project_path) do
        :ok ->
          values = Registry.current_values()

          socket =
            socket
            |> assign(
              values: values,
              original_values: values,
              dirty: MapSet.new(),
              errors: %{}
            )
            |> put_flash(:info, "Settings saved")

          {:noreply, socket}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to save: #{inspect(reason)}")}
      end
    end
  end

  def handle_event("discard_changes", _params, socket) do
    {:noreply,
     assign(socket,
       values: socket.assigns.original_values,
       dirty: MapSet.new(),
       errors: %{}
     )}
  end

  def handle_event("reset_setting", %{"key" => key_string}, socket) do
    default = Registry.default_for(key_string)

    values = Map.put(socket.assigns.values, key_string, default)
    errors = Map.delete(socket.assigns.errors, key_string)

    dirty =
      if default == Map.get(socket.assigns.original_values, key_string) do
        MapSet.delete(socket.assigns.dirty, key_string)
      else
        MapSet.put(socket.assigns.dirty, key_string)
      end

    {:noreply, assign(socket, values: values, dirty: dirty, errors: errors)}
  end

  def handle_event("reset_section", %{"section" => section_name}, socket) do
    settings =
      Registry.all()
      |> Enum.filter(&(&1.section == section_name))

    {values, dirty, errors} =
      Enum.reduce(
        settings,
        {socket.assigns.values, socket.assigns.dirty, socket.assigns.errors},
        fn setting, {vals, drt, errs} ->
          key_str = Registry.key_string(setting.key)
          default = setting.default

          new_dirty =
            if default == Map.get(socket.assigns.original_values, key_str) do
              MapSet.delete(drt, key_str)
            else
              MapSet.put(drt, key_str)
            end

          {Map.put(vals, key_str, default), new_dirty, Map.delete(errs, key_str)}
        end
      )

    {:noreply, assign(socket, values: values, dirty: dirty, errors: errors)}
  end

  def handle_event("add_tag", %{"key" => key_string, "tag" => tag}, socket) do
    tag = String.trim(tag)

    if tag == "" do
      {:noreply, socket}
    else
      current = Map.get(socket.assigns.values, key_string, [])

      if tag in current do
        {:noreply, socket}
      else
        new_value = current ++ [tag]
        values = Map.put(socket.assigns.values, key_string, new_value)

        dirty =
          if new_value == Map.get(socket.assigns.original_values, key_string) do
            MapSet.delete(socket.assigns.dirty, key_string)
          else
            MapSet.put(socket.assigns.dirty, key_string)
          end

        {:noreply, assign(socket, values: values, dirty: dirty)}
      end
    end
  end

  def handle_event("remove_tag", %{"key" => key_string, "tag" => tag}, socket) do
    current = Map.get(socket.assigns.values, key_string, [])
    new_value = List.delete(current, tag)
    values = Map.put(socket.assigns.values, key_string, new_value)

    dirty =
      if new_value == Map.get(socket.assigns.original_values, key_string) do
        MapSet.delete(socket.assigns.dirty, key_string)
      else
        MapSet.put(socket.assigns.dirty, key_string)
      end

    {:noreply, assign(socket, values: values, dirty: dirty)}
  end

  def handle_event("keydown", %{"key" => key}, socket)
      when key in ["ArrowUp", "ArrowDown"] do
    tabs = socket.assigns.tabs
    current_index = Enum.find_index(tabs, &(&1 == socket.assigns.active_tab))

    new_index =
      case key do
        "ArrowUp" -> max(current_index - 1, 0)
        "ArrowDown" -> min(current_index + 1, length(tabs) - 1)
      end

    tab = Enum.at(tabs, new_index)
    {:noreply, assign(socket, active_tab: tab, sections: Registry.by_tab(tab))}
  end

  def handle_event("keydown", _params, socket), do: {:noreply, socket}

  def render(assigns) do
    assigns = assign(assigns, :dirty_tabs, compute_dirty_tabs(assigns.dirty))

    ~H"""
    <.settings_layout
      active_tab={@active_tab}
      tabs={@tabs}
      dirty_count={MapSet.size(@dirty)}
      dirty_tabs={@dirty_tabs}
      has_errors={map_size(@errors) > 0}
    >
      <.settings_tab
        tab={@active_tab}
        sections={@sections}
        values={@values}
        dirty={@dirty}
        errors={@errors}
      />
    </.settings_layout>
    """
  end

  # --- Helpers ---

  defp extract_setting_param(params) do
    # For select elements, the key comes as the input name
    # For toggle buttons, key and value come as phx-value-* attrs
    case params do
      %{"key" => key, "value" => value} ->
        {key, value}

      %{"_target" => [key]} ->
        {key, Map.get(params, key)}

      _ ->
        # Find the setting key in the params map (excluding Phoenix meta keys)
        {key, value} =
          params
          |> Map.drop(["_target"])
          |> Enum.find({"", ""}, fn {k, _v} -> Registry.by_key(k) != nil end)

        {key, value}
    end
  end

  defp cast_value(%{type: :toggle}, "true"), do: true
  defp cast_value(%{type: :toggle}, "false"), do: false
  defp cast_value(%{type: :toggle}, value) when is_boolean(value), do: value

  defp cast_value(%{type: type}, value) when type in [:number, :duration] and is_binary(value) do
    case Integer.parse(value) do
      {int, ""} ->
        int

      _ ->
        case Float.parse(value) do
          {float, _} -> round(float)
          :error -> value
        end
    end
  end

  defp cast_value(%{type: :currency}, value) when is_binary(value) do
    case Float.parse(value) do
      {float, _} -> Float.round(float, 2)
      :error -> value
    end
  end

  defp cast_value(_setting, value), do: value

  defp compute_dirty_tabs(dirty) do
    dirty
    |> Enum.reduce(MapSet.new(), fn key_string, acc ->
      case Registry.by_key(key_string) do
        nil -> acc
        setting -> MapSet.put(acc, setting.tab)
      end
    end)
  end
end
