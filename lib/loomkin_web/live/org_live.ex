defmodule LoomkinWeb.OrgLive do
  @moduledoc "Organization management LiveView."
  use LoomkinWeb, :live_view

  alias Loomkin.Organizations

  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope && socket.assigns.current_scope.user

    unless user do
      {:ok, push_navigate(socket, to: ~p"/projects")}
    else
      orgs = Organizations.list_user_organizations(user)

      {:ok,
       assign(socket,
         page_title: "Organizations",
         user: user,
         view: :list,
         org: nil,
         orgs: orgs,
         form: nil,
         members: [],
         member_email: "",
         member_role: "member"
       )}
    end
  end

  def handle_params(%{"slug" => slug}, _uri, socket) do
    case Organizations.get_organization_by_slug(slug) do
      nil ->
        {:noreply,
         put_flash(socket, :error, "Organization not found") |> push_navigate(to: ~p"/orgs")}

      org ->
        role = Organizations.member_role(org, socket.assigns.user)

        if role do
          members = Organizations.list_members(org)

          {:noreply,
           assign(socket,
             view: :show,
             org: org,
             members: members,
             page_title: org.name,
             can_admin: role in [:owner, :admin],
             can_owner: role == :owner
           )}
        else
          {:noreply, put_flash(socket, :error, "Access denied") |> push_navigate(to: ~p"/orgs")}
        end
    end
  end

  def handle_params(_params, _uri, %{assigns: %{live_action: :new}} = socket) do
    form = %Loomkin.Schemas.Organization{} |> Ecto.Changeset.change() |> to_form()
    {:noreply, assign(socket, view: :new, form: form)}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  def handle_event("new_org", _params, socket) do
    form = %Loomkin.Schemas.Organization{} |> Ecto.Changeset.change() |> to_form()
    {:noreply, assign(socket, view: :new, form: form)}
  end

  def handle_event("create_org", %{"organization" => attrs}, socket) do
    scope = socket.assigns.current_scope

    case Organizations.create_organization(scope, attrs) do
      {:ok, org} ->
        {:noreply,
         socket
         |> put_flash(:info, "Organization created")
         |> push_navigate(to: ~p"/orgs/#{org.slug}")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_event("back", _params, socket) do
    orgs = Organizations.list_user_organizations(socket.assigns.user)
    {:noreply, assign(socket, view: :list, orgs: orgs, org: nil, form: nil)}
  end

  def handle_event("update_member_email", %{"value" => val}, socket) do
    {:noreply, assign(socket, member_email: val)}
  end

  def handle_event("update_member_role", %{"value" => val}, socket) do
    {:noreply, assign(socket, member_role: val)}
  end

  @allowed_ui_roles %{"member" => :member, "admin" => :admin}

  def handle_event("add_member", _params, socket) do
    email = String.trim(socket.assigns.member_email)

    case Map.fetch(@allowed_ui_roles, socket.assigns.member_role) do
      {:ok, role} ->
        case Loomkin.Repo.get_by(Loomkin.Accounts.User, email: email) do
          nil ->
            {:noreply, put_flash(socket, :error, "User not found: #{email}")}

          user ->
            scope = socket.assigns.current_scope

            case Organizations.add_member(scope, socket.assigns.org, user, role) do
              {:ok, _} ->
                members = Organizations.list_members(socket.assigns.org)

                {:noreply,
                 assign(socket, members: members, member_email: "")
                 |> put_flash(:info, "Member added")}

              {:error, :invalid_role} ->
                {:noreply, put_flash(socket, :error, "Invalid role")}

              {:error, _} ->
                {:noreply, put_flash(socket, :error, "Failed to add member")}
            end
        end

      :error ->
        {:noreply, put_flash(socket, :error, "Invalid role")}
    end
  end

  def handle_event("remove_member", %{"user-id" => user_id}, socket) do
    user = Loomkin.Repo.get!(Loomkin.Accounts.User, user_id)
    scope = socket.assigns.current_scope

    case Organizations.remove_member(scope, socket.assigns.org, user) do
      :ok ->
        members = Organizations.list_members(socket.assigns.org)
        {:noreply, assign(socket, members: members) |> put_flash(:info, "Member removed")}

      {:error, :cannot_remove_owner} ->
        {:noreply, put_flash(socket, :error, "Cannot remove the organization owner")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to remove member")}
    end
  end

  def handle_event("update_enforcement", %{"value" => val}, socket) do
    scope = socket.assigns.current_scope
    org = socket.assigns.org
    settings = Map.put(org.settings || %{}, "kindred_enforcement", val)

    case Organizations.update_organization(scope, org, %{settings: settings}) do
      {:ok, updated_org} ->
        {:noreply, assign(socket, org: updated_org) |> put_flash(:info, "Settings updated")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update settings")}
    end
  end

  def handle_event("toggle_reflection", _params, socket) do
    scope = socket.assigns.current_scope
    org = socket.assigns.org
    current = get_in(org.settings, ["reflection_enabled"]) || false
    settings = Map.put(org.settings || %{}, "reflection_enabled", !current)

    case Organizations.update_organization(scope, org, %{settings: settings}) do
      {:ok, updated_org} ->
        {:noreply, assign(socket, org: updated_org)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update settings")}
    end
  end

  # --- Template ---

  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-zinc-950 text-zinc-200 p-6 max-w-4xl mx-auto">
      <%= case @view do %>
        <% :list -> %>
          <div class="flex items-center justify-between mb-8">
            <h1 class="text-2xl font-bold">Organizations</h1>
            <button
              phx-click="new_org"
              class="px-4 py-2 bg-violet-600 hover:bg-violet-500 rounded-lg text-sm font-medium"
            >
              New Organization
            </button>
          </div>

          <%= if @orgs == [] do %>
            <div class="text-center py-16 text-zinc-500">
              <p class="text-lg">No organizations yet</p>
              <p class="text-sm mt-2">Create one to share agent configurations with your team.</p>
            </div>
          <% else %>
            <div class="space-y-3">
              <.link
                :for={org <- @orgs}
                navigate={~p"/orgs/#{org.slug}"}
                class="block p-4 bg-zinc-900 border border-zinc-800 rounded-lg hover:border-violet-600/50 transition-colors"
              >
                <div class="flex items-center gap-3">
                  <%= if org.avatar_url do %>
                    <img src={org.avatar_url} class="w-10 h-10 rounded-full" />
                  <% else %>
                    <div class="w-10 h-10 rounded-full bg-violet-600/20 flex items-center justify-center text-violet-400 font-bold">
                      {String.first(org.name) |> String.upcase()}
                    </div>
                  <% end %>
                  <div>
                    <h3 class="font-semibold">{org.name}</h3>
                    <p :if={org.description} class="text-sm text-zinc-500 mt-0.5">
                      {String.slice(org.description, 0, 100)}
                    </p>
                  </div>
                </div>
              </.link>
            </div>
          <% end %>
        <% :new -> %>
          <div class="mb-6">
            <button phx-click="back" class="text-zinc-400 hover:text-white text-sm">
              &larr; Back
            </button>
          </div>
          <h1 class="text-2xl font-bold mb-6">Create Organization</h1>

          <.form for={@form} id="org-form" phx-submit="create_org" class="space-y-4 max-w-md">
            <div>
              <label class="block text-sm font-medium text-zinc-400 mb-1">Name</label>
              <input
                type="text"
                name="organization[name]"
                value={@form[:name].value}
                required
                class="w-full bg-zinc-900 border border-zinc-700 rounded-lg px-3 py-2 text-white focus:border-violet-500 focus:ring-1 focus:ring-violet-500"
              />
            </div>
            <div>
              <label class="block text-sm font-medium text-zinc-400 mb-1">
                Description (optional)
              </label>
              <textarea
                name="organization[description]"
                rows="3"
                class="w-full bg-zinc-900 border border-zinc-700 rounded-lg px-3 py-2 text-white focus:border-violet-500 focus:ring-1 focus:ring-violet-500"
              >{@form[:description].value}</textarea>
            </div>
            <button
              type="submit"
              class="px-4 py-2 bg-violet-600 hover:bg-violet-500 rounded-lg text-sm font-medium"
            >
              Create
            </button>
          </.form>
        <% :show -> %>
          <div class="mb-6">
            <.link navigate={~p"/orgs"} class="text-zinc-400 hover:text-white text-sm">
              &larr; All Organizations
            </.link>
          </div>

          <div class="flex items-center gap-4 mb-8">
            <%= if @org.avatar_url do %>
              <img src={@org.avatar_url} class="w-14 h-14 rounded-full" />
            <% else %>
              <div class="w-14 h-14 rounded-full bg-violet-600/20 flex items-center justify-center text-violet-400 font-bold text-xl">
                {String.first(@org.name) |> String.upcase()}
              </div>
            <% end %>
            <div>
              <h1 class="text-2xl font-bold">{@org.name}</h1>
              <p :if={@org.description} class="text-zinc-400 text-sm mt-1">{@org.description}</p>
            </div>
          </div>

          <%!-- Members section --%>
          <div class="mb-8">
            <h2 class="text-lg font-semibold mb-4">Members ({length(@members)})</h2>
            <div class="space-y-2">
              <div
                :for={m <- @members}
                class="flex items-center justify-between p-3 bg-zinc-900 border border-zinc-800 rounded-lg"
              >
                <div class="flex items-center gap-3">
                  <div class="w-8 h-8 rounded-full bg-zinc-700 flex items-center justify-center text-xs font-bold text-zinc-300">
                    {String.first(m.user.email) |> String.upcase()}
                  </div>
                  <div>
                    <span class="text-sm">{m.user.email}</span>
                    <span class={["ml-2 text-xs px-2 py-0.5 rounded-full", role_badge_class(m.role)]}>
                      {m.role}
                    </span>
                  </div>
                </div>
                <button
                  :if={@can_admin && m.role != :owner}
                  phx-click="remove_member"
                  phx-value-user-id={m.user.id}
                  class="text-xs text-red-400 hover:text-red-300"
                >
                  Remove
                </button>
              </div>
            </div>

            <%!-- Add member form (admin+ only) --%>
            <div :if={@can_admin} class="mt-4 flex gap-2">
              <input
                type="email"
                phx-change="update_member_email"
                phx-debounce="300"
                value={@member_email}
                placeholder="user@example.com"
                class="flex-1 bg-zinc-900 border border-zinc-700 rounded-lg px-3 py-2 text-sm text-white"
              />
              <select
                phx-change="update_member_role"
                class="bg-zinc-900 border border-zinc-700 rounded-lg px-3 py-2 text-sm text-white"
              >
                <option value="member" selected={@member_role == "member"}>Member</option>
                <option value="admin" selected={@member_role == "admin"}>Admin</option>
              </select>
              <button
                phx-click="add_member"
                class="px-3 py-2 bg-violet-600 hover:bg-violet-500 rounded-lg text-sm"
              >
                Add
              </button>
            </div>
          </div>

          <%!-- Settings section (admin+ only) --%>
          <div :if={@can_admin} class="mb-8">
            <h2 class="text-lg font-semibold mb-4">Settings</h2>
            <div class="space-y-4 p-4 bg-zinc-900 border border-zinc-800 rounded-lg">
              <div class="flex items-center justify-between">
                <div>
                  <p class="font-medium text-sm">Kindred Enforcement</p>
                  <p class="text-xs text-zinc-500 mt-0.5">How org kindred is applied to workspaces</p>
                </div>
                <select
                  phx-change="update_enforcement"
                  class="bg-zinc-800 border border-zinc-700 rounded px-3 py-1.5 text-sm"
                >
                  <option
                    value="defaults"
                    selected={get_in(@org.settings, ["kindred_enforcement"]) != "required"}
                  >
                    Defaults (user overrides allowed)
                  </option>
                  <option
                    value="required"
                    selected={get_in(@org.settings, ["kindred_enforcement"]) == "required"}
                  >
                    Required (org only)
                  </option>
                </select>
              </div>

              <div class="flex items-center justify-between">
                <div>
                  <p class="font-medium text-sm">Reflection</p>
                  <p class="text-xs text-zinc-500 mt-0.5">
                    Enable automatic kindred evolution via reflection
                  </p>
                </div>
                <button
                  phx-click="toggle_reflection"
                  class={[
                    "relative inline-flex h-6 w-11 items-center rounded-full transition-colors",
                    if(get_in(@org.settings, ["reflection_enabled"]),
                      do: "bg-violet-600",
                      else: "bg-zinc-700"
                    )
                  ]}
                >
                  <span class={[
                    "inline-block h-4 w-4 transform rounded-full bg-white transition-transform",
                    if(get_in(@org.settings, ["reflection_enabled"]),
                      do: "translate-x-6",
                      else: "translate-x-1"
                    )
                  ]} />
                </button>
              </div>
            </div>
          </div>
      <% end %>
    </div>
    """
  end

  defp role_badge_class(:owner), do: "bg-amber-600/20 text-amber-400"
  defp role_badge_class(:admin), do: "bg-blue-600/20 text-blue-400"
  defp role_badge_class(_), do: "bg-zinc-700/50 text-zinc-400"
end
