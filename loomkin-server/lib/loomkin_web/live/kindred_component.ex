defmodule LoomkinWeb.KindredComponent do
  @moduledoc """
  Kindred management component. Used in org settings and user personal settings.

  Shows kindred items (kin configs, skills, prompts) with add/edit/remove.
  """
  use LoomkinWeb, :live_component

  alias Loomkin.Kindred, as: KindredContext

  def mount(socket) do
    {:ok,
     assign(socket,
       mode: :list,
       editing_item: nil,
       item_form: nil
     )}
  end

  def update(assigns, socket) do
    socket = assign(socket, assigns)

    kindreds =
      case assigns[:owner_type] do
        :organization ->
          KindredContext.list_org_kindreds(assigns.organization)

        _ ->
          if assigns[:user], do: KindredContext.list_user_kindreds(assigns.user), else: []
      end

    items =
      case assigns[:kindred] do
        nil -> []
        k -> KindredContext.list_items(k)
      end

    {:ok, assign(socket, kindreds: kindreds, items: items)}
  end

  def handle_event("select_kindred", %{"id" => id}, socket) do
    scope = socket.assigns.scope
    kindred = KindredContext.get_kindred_for_user!(scope, id)
    items = KindredContext.list_items(kindred)
    {:noreply, assign(socket, kindred: kindred, items: items)}
  rescue
    Ecto.NoResultsError ->
      {:noreply, put_flash(socket, :error, "Kindred not found")}
  end

  def handle_event("new_kindred", _params, socket) do
    scope = socket.assigns.scope

    attrs =
      case socket.assigns[:owner_type] do
        :organization ->
          %{
            name: "New Kindred",
            owner_type: :organization,
            organization_id: socket.assigns.organization.id
          }

        _ ->
          %{
            name: "New Kindred",
            owner_type: :user,
            user_id: scope.user.id
          }
      end

    case KindredContext.create_kindred(scope, attrs) do
      {:ok, kindred} ->
        send(self(), {:kindred_created, kindred})
        items = KindredContext.list_items(kindred)
        kindreds = refresh_kindreds(socket)
        {:noreply, assign(socket, kindred: kindred, items: items, kindreds: kindreds)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to create kindred")}
    end
  end

  def handle_event("publish", _params, socket) do
    scope = socket.assigns.scope

    case KindredContext.publish_kindred(scope, socket.assigns.kindred) do
      {:ok, kindred} ->
        kindreds = refresh_kindreds(socket)
        {:noreply, assign(socket, kindred: kindred, kindreds: kindreds)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to publish")}
    end
  end

  def handle_event("archive", _params, socket) do
    scope = socket.assigns.scope

    case KindredContext.archive_kindred(scope, socket.assigns.kindred) do
      {:ok, kindred} ->
        kindreds = refresh_kindreds(socket)
        {:noreply, assign(socket, kindred: kindred, kindreds: kindreds)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to archive")}
    end
  end

  def handle_event("add_item", %{"type" => type}, socket) do
    scope = socket.assigns.scope

    content =
      case type do
        "kin_config" -> %{"name" => "new-agent", "role" => "coder", "potency" => 50}
        "skill_ref" -> %{"skill_name" => "new-skill"}
        "prompt_template" -> %{"name" => "new-prompt", "template" => ""}
      end

    case KindredContext.add_item(scope, socket.assigns.kindred, %{
           item_type: String.to_existing_atom(type),
           content: content
         }) do
      {:ok, _item} ->
        items = KindredContext.list_items(socket.assigns.kindred)
        {:noreply, assign(socket, items: items)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to add item")}
    end
  end

  def handle_event("remove_item", %{"id" => item_id}, socket) do
    scope = socket.assigns.scope

    case KindredContext.remove_item(scope, socket.assigns.kindred, item_id) do
      {:ok, _} ->
        items = KindredContext.list_items(socket.assigns.kindred)
        {:noreply, assign(socket, items: items)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to remove item")}
    end
  end

  def handle_event("edit_item", %{"id" => item_id}, socket) do
    item = Enum.find(socket.assigns.items, &(&1.id == item_id))
    {:noreply, assign(socket, editing_item: item, mode: :edit_item)}
  end

  def handle_event("save_item", %{"content" => content_json}, socket) do
    scope = socket.assigns.scope

    case Jason.decode(content_json) do
      {:ok, content} ->
        case KindredContext.update_item(scope, socket.assigns.editing_item, %{content: content}) do
          {:ok, _} ->
            items = KindredContext.list_items(socket.assigns.kindred)
            {:noreply, assign(socket, items: items, editing_item: nil, mode: :list)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to save")}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Invalid JSON")}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, editing_item: nil, mode: :list)}
  end

  defp refresh_kindreds(socket) do
    case socket.assigns[:owner_type] do
      :organization -> KindredContext.list_org_kindreds(socket.assigns.organization)
      _ -> KindredContext.list_user_kindreds(socket.assigns.scope.user)
    end
  end

  def render(assigns) do
    ~H"""
    <div class="space-y-4">
      <%!-- Kindred list --%>
      <div class="flex items-center justify-between">
        <h3 class="text-sm font-semibold text-zinc-400 uppercase tracking-wider">Kindred Bundles</h3>
        <button
          phx-click="new_kindred"
          phx-target={@myself}
          class="text-xs px-2 py-1 bg-violet-600/20 text-violet-400 rounded hover:bg-violet-600/30"
        >
          + New
        </button>
      </div>

      <div class="space-y-2">
        <button
          :for={k <- @kindreds}
          phx-click="select_kindred"
          phx-value-id={k.id}
          phx-target={@myself}
          class={[
            "w-full text-left p-3 rounded-lg border transition-colors",
            if(@kindred && @kindred.id == k.id,
              do: "bg-violet-600/10 border-violet-600/50",
              else: "bg-zinc-900 border-zinc-800 hover:border-zinc-700"
            )
          ]}
        >
          <div class="flex items-center justify-between">
            <span class="font-medium text-sm">{k.name}</span>
            <span class={["text-xs px-2 py-0.5 rounded-full", status_class(k.status)]}>
              {k.status}
            </span>
          </div>
          <span class="text-xs text-zinc-500">v{k.version}</span>
        </button>
      </div>

      <%!-- Selected kindred details --%>
      <div :if={@kindred} class="mt-6 space-y-4">
        <div class="flex items-center justify-between">
          <h3 class="font-semibold">{@kindred.name}</h3>
          <div class="flex gap-2">
            <button
              :if={@kindred.status != :active}
              phx-click="publish"
              phx-target={@myself}
              class="text-xs px-2 py-1 bg-emerald-600/20 text-emerald-400 rounded hover:bg-emerald-600/30"
            >
              Publish
            </button>
            <button
              :if={@kindred.status == :active}
              phx-click="archive"
              phx-target={@myself}
              class="text-xs px-2 py-1 bg-zinc-700/50 text-zinc-400 rounded hover:bg-zinc-700"
            >
              Archive
            </button>
          </div>
        </div>

        <%!-- Items --%>
        <div class="space-y-2">
          <div :for={item <- @items} class="p-3 bg-zinc-900 border border-zinc-800 rounded-lg">
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-2">
                <span class={["text-xs px-2 py-0.5 rounded", item_type_class(item.item_type)]}>
                  {item.item_type}
                </span>
                <span class="text-sm font-medium">{item_name(item)}</span>
              </div>
              <div class="flex gap-1">
                <button
                  phx-click="edit_item"
                  phx-value-id={item.id}
                  phx-target={@myself}
                  class="text-xs text-zinc-400 hover:text-white px-1"
                >
                  Edit
                </button>
                <button
                  phx-click="remove_item"
                  phx-value-id={item.id}
                  phx-target={@myself}
                  class="text-xs text-red-400 hover:text-red-300 px-1"
                >
                  Remove
                </button>
              </div>
            </div>
          </div>
        </div>

        <%!-- Add item buttons --%>
        <div class="flex gap-2">
          <button
            phx-click="add_item"
            phx-value-type="kin_config"
            phx-target={@myself}
            class="text-xs px-2 py-1 border border-zinc-700 rounded hover:border-zinc-600 text-zinc-400"
          >
            + Kin Config
          </button>
          <button
            phx-click="add_item"
            phx-value-type="skill_ref"
            phx-target={@myself}
            class="text-xs px-2 py-1 border border-zinc-700 rounded hover:border-zinc-600 text-zinc-400"
          >
            + Skill
          </button>
          <button
            phx-click="add_item"
            phx-value-type="prompt_template"
            phx-target={@myself}
            class="text-xs px-2 py-1 border border-zinc-700 rounded hover:border-zinc-600 text-zinc-400"
          >
            + Prompt
          </button>
        </div>

        <%!-- Item editor --%>
        <div
          :if={@mode == :edit_item && @editing_item}
          class="p-4 bg-zinc-800 border border-zinc-700 rounded-lg"
        >
          <h4 class="text-sm font-semibold mb-2">Edit Item: {item_name(@editing_item)}</h4>
          <form phx-submit="save_item" phx-target={@myself}>
            <textarea
              name="content"
              rows="8"
              class="w-full bg-zinc-900 border border-zinc-700 rounded px-3 py-2 text-sm font-mono text-white"
            >{Jason.encode!(@editing_item.content, pretty: true)}</textarea>
            <div class="flex gap-2 mt-2">
              <button
                type="submit"
                class="text-xs px-3 py-1.5 bg-violet-600 rounded hover:bg-violet-500"
              >
                Save
              </button>
              <button
                type="button"
                phx-click="cancel_edit"
                phx-target={@myself}
                class="text-xs px-3 py-1.5 bg-zinc-700 rounded hover:bg-zinc-600"
              >
                Cancel
              </button>
            </div>
          </form>
        </div>
      </div>

      <div :if={@kindred == nil && @kindreds != []} class="text-center text-zinc-500 text-sm py-8">
        Select a kindred to view its items
      </div>
    </div>
    """
  end

  defp status_class(:active), do: "bg-emerald-600/20 text-emerald-400"
  defp status_class(:draft), do: "bg-amber-600/20 text-amber-400"
  defp status_class(:archived), do: "bg-zinc-700/50 text-zinc-400"
  defp status_class(_), do: "bg-zinc-700/50 text-zinc-400"

  defp item_type_class(:kin_config), do: "bg-blue-600/20 text-blue-400"
  defp item_type_class(:skill_ref), do: "bg-emerald-600/20 text-emerald-400"
  defp item_type_class(:prompt_template), do: "bg-amber-600/20 text-amber-400"
  defp item_type_class(_), do: "bg-zinc-700/50 text-zinc-400"

  defp item_name(item) do
    item.content["name"] || item.content["skill_name"] || "Item #{item.id}"
  end
end
