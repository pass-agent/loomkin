defmodule LoomkinWeb.SnippetLive do
  @moduledoc """
  Snippet detail, create, and edit views.

  Routes:
    - `/@:username/:slug` — show (public detail view)
    - `/snippets/new` — create
    - `/snippets/:id/edit` — edit
  """
  use LoomkinWeb, :live_view

  alias Loomkin.Kin
  alias Loomkin.Repo
  alias Loomkin.Session.Persistence
  alias Loomkin.Social
  alias Loomkin.Social.SkillInstaller
  alias Loomkin.Schemas.Snippet

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Snippet",
       snippet: nil,
       snippet_type: :skill,
       form: nil,
       owner_username: nil,
       forked_from_username: nil,
       is_owner: false,
       is_favorited: false
     )}
  end

  def handle_params(params, _uri, socket) do
    if connected?(socket) do
      {:noreply, apply_action(socket, socket.assigns.live_action, params)}
    else
      {:noreply, socket}
    end
  end

  defp apply_action(socket, :show, %{"username" => username, "slug" => slug}) do
    current_user =
      case socket.assigns[:current_scope] do
        %{user: user} -> user
        _ -> nil
      end

    case Social.get_snippet_by_slug(username, slug, current_user) do
      nil ->
        socket
        |> put_flash(:error, "Snippet not found.")
        |> push_navigate(to: ~p"/explore")

      snippet ->
        snippet = Repo.preload(snippet, [:user, forked_from: :user])

        is_owner = current_user != nil and current_user.id == snippet.user_id
        is_favorited = current_user != nil and Social.favorited?(current_user, snippet)

        owner_username =
          if Ecto.assoc_loaded?(snippet.user),
            do: snippet.user.username,
            else: username

        forked_from_username =
          if snippet.forked_from_id && Ecto.assoc_loaded?(snippet.forked_from) &&
               snippet.forked_from do
            forked = snippet.forked_from

            if Ecto.assoc_loaded?(forked.user),
              do: forked.user.username,
              else: nil
          end

        socket
        |> assign(
          page_title: snippet.title,
          snippet: snippet,
          owner_username: owner_username,
          forked_from_username: forked_from_username,
          is_owner: is_owner,
          is_favorited: is_favorited
        )
    end
  end

  defp apply_action(socket, :new, _params) do
    changeset = Snippet.changeset(%Snippet{}, %{})

    socket
    |> assign(
      page_title: "New Snippet",
      snippet: nil,
      snippet_type: :skill,
      form: to_form(changeset)
    )
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    snippet = Social.get_snippet!(id)
    current_user = socket.assigns.current_scope.user

    if current_user.id != snippet.user_id do
      socket
      |> put_flash(:error, "You do not have permission to edit this snippet.")
      |> push_navigate(to: ~p"/")
    else
      changeset = Snippet.changeset(snippet, %{})

      socket
      |> assign(
        page_title: "Edit #{snippet.title}",
        snippet: snippet,
        snippet_type: snippet.type,
        form: to_form(changeset)
      )
    end
  end

  # ---------------------------------------------------------------------------
  # Fork / Favorite events
  # ---------------------------------------------------------------------------

  def handle_event("fork", _params, %{assigns: %{current_scope: nil}} = socket) do
    {:noreply,
     socket
     |> put_flash(:error, "Please log in to fork snippets.")
     |> push_navigate(to: ~p"/users/log-in")}
  end

  def handle_event("fork", _params, %{assigns: %{current_scope: %{user: nil}}} = socket) do
    {:noreply,
     socket
     |> put_flash(:error, "Please log in to fork snippets.")
     |> push_navigate(to: ~p"/users/log-in")}
  end

  def handle_event("fork", _params, socket) do
    current_user = socket.assigns.current_scope.user
    snippet = socket.assigns.snippet

    case Social.fork_snippet(current_user, snippet) do
      {:ok, fork} ->
        {:noreply,
         socket
         |> put_flash(:info, "Snippet forked!")
         |> push_navigate(to: ~p"/snippets/#{fork.id}/edit")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Cannot fork a private snippet")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not fork snippet")}
    end
  end

  def handle_event("toggle_favorite", _params, %{assigns: %{current_scope: nil}} = socket) do
    {:noreply,
     socket
     |> put_flash(:error, "Please log in to favorite snippets.")
     |> push_navigate(to: ~p"/users/log-in")}
  end

  def handle_event(
        "toggle_favorite",
        _params,
        %{assigns: %{current_scope: %{user: nil}}} = socket
      ) do
    {:noreply,
     socket
     |> put_flash(:error, "Please log in to favorite snippets.")
     |> push_navigate(to: ~p"/users/log-in")}
  end

  def handle_event("toggle_favorite", _params, socket) do
    current_user = socket.assigns.current_scope.user
    snippet = socket.assigns.snippet

    case Social.toggle_favorite(current_user, snippet) do
      {:ok, {:favorited, _}} ->
        {:noreply,
         assign(socket,
           is_favorited: true,
           snippet: %{snippet | favorite_count: snippet.favorite_count + 1}
         )}

      {:ok, {:already_favorited, _}} ->
        {:noreply, assign(socket, is_favorited: true)}

      {:ok, :unfavorited} ->
        {:noreply,
         assign(socket,
           is_favorited: false,
           snippet: %{snippet | favorite_count: snippet.favorite_count - 1}
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not update favorite")}
    end
  end

  # ---------------------------------------------------------------------------
  # Install events
  # ---------------------------------------------------------------------------

  def handle_event("install_skill", _params, %{assigns: %{current_scope: nil}} = socket) do
    {:noreply,
     socket
     |> put_flash(:error, "Please log in to install skills.")
     |> push_navigate(to: ~p"/users/log-in")}
  end

  def handle_event("install_skill", _params, %{assigns: %{current_scope: %{user: nil}}} = socket) do
    {:noreply,
     socket
     |> put_flash(:error, "Please log in to install skills.")
     |> push_navigate(to: ~p"/users/log-in")}
  end

  def handle_event("install_skill", _params, socket) do
    snippet = socket.assigns.snippet
    project_path = get_default_project_path(socket)

    case project_path do
      nil ->
        {:noreply,
         put_flash(socket, :error, "No active project found. Open a workspace session first.")}

      path ->
        case SkillInstaller.install_to_project(snippet, path) do
          {:ok, _install_path} ->
            Loomkin.Skills.Resolver.load_from_disk(path)

            {:noreply,
             put_flash(socket, :info, "Skill installed! Agents will see it in new sessions.")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Install failed: #{inspect(reason)}")}
        end
    end
  end

  def handle_event("install_kin", _params, %{assigns: %{current_scope: nil}} = socket) do
    {:noreply,
     socket
     |> put_flash(:error, "Please log in to install kin agents.")
     |> push_navigate(to: ~p"/users/log-in")}
  end

  def handle_event("install_kin", _params, %{assigns: %{current_scope: %{user: nil}}} = socket) do
    {:noreply,
     socket
     |> put_flash(:error, "Please log in to install kin agents.")
     |> push_navigate(to: ~p"/users/log-in")}
  end

  def handle_event("install_kin", _params, socket) do
    snippet = socket.assigns.snippet
    content = snippet.content || %{}
    current_user = socket.assigns.current_scope.user

    role = safe_to_role(content["role"])

    attrs = %{
      name: Snippet.slugify(snippet.title),
      display_name: snippet.title,
      role: role,
      system_prompt_extra: content["system_prompt_extra"],
      potency: content["potency"] || 50,
      spawn_context: content["spawn_context"],
      auto_spawn: false,
      enabled: true,
      user_id: current_user.id
    }

    case Kin.create_kin(attrs) do
      {:ok, _kin} ->
        {:noreply, put_flash(socket, :info, "Kin agent installed! Check your Kin panel.")}

      {:error, _changeset} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Could not install kin agent. It may already exist or have invalid configuration."
         )}
    end
  end

  def handle_event("install_prompt", _params, %{assigns: %{current_scope: nil}} = socket) do
    {:noreply,
     socket
     |> put_flash(:error, "Please log in to use this feature.")
     |> push_navigate(to: ~p"/users/log-in")}
  end

  def handle_event("install_prompt", _params, %{assigns: %{current_scope: %{user: nil}}} = socket) do
    {:noreply,
     socket
     |> put_flash(:error, "Please log in to use this feature.")
     |> push_navigate(to: ~p"/users/log-in")}
  end

  def handle_event("install_prompt", _params, socket) do
    {:noreply,
     put_flash(
       socket,
       :info,
       "To use this prompt, create a Kin agent and paste the content into its system prompt."
     )}
  end

  # ---------------------------------------------------------------------------
  # Form events
  # ---------------------------------------------------------------------------

  def handle_event("validate", params, socket) do
    snippet_params = params["snippet"] || %{}
    snippet_type = derive_snippet_type(snippet_params["type"], socket.assigns.snippet_type)
    merged = merge_type_fields(params, snippet_params, snippet_type)

    changeset =
      (socket.assigns.snippet || %Snippet{})
      |> Snippet.changeset(merged)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset), snippet_type: snippet_type)}
  end

  def handle_event("save", params, socket) do
    case socket.assigns.live_action do
      :new -> create_snippet(socket, params)
      :edit -> update_snippet(socket, params)
    end
  end

  defp create_snippet(socket, params) do
    current_user = socket.assigns.current_scope.user
    snippet_params = params["snippet"] || %{}
    merged = merge_type_fields(params, snippet_params, socket.assigns.snippet_type)

    case Social.create_snippet(current_user, merged) do
      {:ok, snippet} ->
        {:noreply,
         socket
         |> put_flash(:info, "Snippet created!")
         |> push_navigate(to: ~p"/@#{current_user.username}/#{snippet.slug}")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp update_snippet(socket, params) do
    snippet = socket.assigns.snippet
    current_user = socket.assigns.current_scope.user
    snippet_params = params["snippet"] || %{}
    merged = merge_type_fields(params, snippet_params, socket.assigns.snippet_type)

    case Social.update_snippet(current_user, snippet, merged) do
      {:ok, updated} ->
        updated = Repo.preload(updated, :user)
        username = updated.user.username

        {:noreply,
         socket
         |> put_flash(:info, "Snippet updated!")
         |> push_navigate(to: ~p"/@#{username}/#{updated.slug}")}

      {:error, :unauthorized} ->
        {:noreply,
         socket
         |> put_flash(:error, "You do not have permission to edit this snippet.")
         |> push_navigate(to: ~p"/")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp safe_to_role(role_str)
       when role_str in ~w(lead coder researcher reviewer tester concierge architect expert),
       do: String.to_existing_atom(role_str)

  defp safe_to_role(_), do: :coder

  defp derive_snippet_type("skill", _current), do: :skill
  defp derive_snippet_type("prompt", _current), do: :prompt
  defp derive_snippet_type("kin_agent", _current), do: :kin_agent
  defp derive_snippet_type("chat_log", _current), do: :chat_log
  defp derive_snippet_type(_, current), do: current

  defp merge_type_fields(params, snippet_params, :skill) do
    skill_name =
      case params["skill_name"] do
        name when is_binary(name) and name != "" ->
          name

        _ ->
          Snippet.slugify(snippet_params["title"] || "")
      end

    content = %{
      "frontmatter" => %{
        "name" => skill_name,
        "description" => snippet_params["description"] || ""
      },
      "body" => params["skill_body"] || ""
    }

    Map.put(snippet_params, "content", content)
  end

  defp merge_type_fields(params, snippet_params, :kin_agent) do
    potency =
      case Integer.parse(params["kin_potency"] || "50") do
        {n, _} -> n
        :error -> 50
      end

    content = %{
      "role" => params["kin_role"] || "coder",
      "system_prompt_extra" => params["kin_system_prompt_extra"] || "",
      "potency" => potency,
      "spawn_context" => params["kin_spawn_context"] || ""
    }

    Map.put(snippet_params, "content", content)
  end

  defp merge_type_fields(params, snippet_params, :prompt) do
    content = %{
      "system_prompt" => params["prompt_system"] || "",
      "user_prompt_template" => params["prompt_user_template"] || ""
    }

    Map.put(snippet_params, "content", content)
  end

  defp merge_type_fields(_params, snippet_params, _type), do: snippet_params

  defp get_default_project_path(socket) do
    # Prefer an explicit project_path assign set in the session (e.g. carried from WorkspaceLive).
    # Fall back to the most-recently-active project known to Persistence.
    case socket.assigns[:project_path] do
      path when is_binary(path) and path != "" ->
        path

      _ ->
        case Persistence.list_projects() do
          [%{project_path: path} | _] -> path
          [] -> nil
        end
    end
  end

  defp existing_skill_body(snippet) do
    case snippet do
      nil -> ""
      %Snippet{content: %{"body" => body}} when is_binary(body) -> body
      _ -> ""
    end
  end

  defp existing_skill_name(snippet) do
    case snippet do
      nil -> ""
      %Snippet{content: %{"frontmatter" => %{"name" => name}}} when is_binary(name) -> name
      _ -> ""
    end
  end

  defp existing_kin_field(snippet, field) do
    case snippet do
      nil -> nil
      %Snippet{content: content} when is_map(content) -> Map.get(content, field)
      _ -> nil
    end
  end

  defp existing_prompt_field(snippet, field) do
    case snippet do
      nil -> ""
      %Snippet{content: content} when is_map(content) -> Map.get(content, field) || ""
      _ -> ""
    end
  end

  # ---------------------------------------------------------------------------
  # Render — show
  # ---------------------------------------------------------------------------

  def render(%{live_action: :show, snippet: nil} = assigns) do
    ~H"""
    <div class="min-h-screen bg-surface-0 flex items-center justify-center">
      <p class="text-gray-500 text-sm">Loading...</p>
    </div>
    """
  end

  def render(%{live_action: :show} = assigns) do
    ~H"""
    <div class="min-h-screen bg-surface-0 relative overflow-hidden">
      <div class="home-aurora" aria-hidden="true" />

      <nav class="relative z-20 border-b border-border-subtle bg-surface-0/80 backdrop-blur-md">
        <div class="max-w-4xl mx-auto px-4 sm:px-6 lg:px-8">
          <div class="flex items-center justify-between h-14">
            <div class="flex items-center gap-3">
              <.link navigate={~p"/"} class="text-brand font-semibold text-lg tracking-tight">
                Loomkin
              </.link>
              <span class="text-gray-600">/</span>
              <.link
                navigate={~p"/@#{@owner_username}"}
                class="text-gray-400 text-sm hover:text-brand transition-colors"
              >
                @{@owner_username}
              </.link>
              <span class="text-gray-600">/</span>
              <span class="text-gray-200 text-sm font-medium">{@snippet.slug}</span>
            </div>
            <div class="flex items-center gap-2">
              <%= if @is_owner do %>
                <.link
                  navigate={~p"/snippets/#{@snippet.id}/edit"}
                  class="text-sm text-gray-400 hover:text-white transition-colors"
                >
                  Edit
                </.link>
              <% end %>
            </div>
          </div>
        </div>
      </nav>

      <div id="main-content" class="relative z-10 max-w-4xl mx-auto px-4 sm:px-6 lg:px-8 pt-8 pb-16">
        <%!-- Snippet header --%>
        <div class="mb-8 animate-fade-in">
          <div class="flex items-start justify-between gap-4">
            <div>
              <h1 class="text-2xl font-semibold text-white">{@snippet.title}</h1>
              <p :if={@snippet.description} class="text-gray-400 text-sm mt-1">
                {@snippet.description}
              </p>
              <div class="flex items-center gap-3 mt-3">
                <span class={[
                  "inline-flex items-center px-2 py-0.5 rounded-md text-xs font-medium uppercase tracking-wider",
                  snippet_badge_class(to_string(@snippet.type))
                ]}>
                  {to_string(@snippet.type)}
                </span>
                <span class="text-gray-500 text-xs">
                  by
                  <.link
                    navigate={~p"/@#{@owner_username}"}
                    class="text-brand hover:text-violet-300 transition-colors"
                  >
                    @{@owner_username}
                  </.link>
                </span>
                <span
                  :if={@forked_from_username}
                  class="text-gray-600 text-xs flex items-center gap-1"
                >
                  <span class="hero-arrow-path-mini w-3 h-3" /> forked from @{@forked_from_username}
                </span>
              </div>
            </div>

            <%!-- Actions --%>
            <div class="flex items-center gap-2 shrink-0">
              <%!-- Install button — type-aware, only for authenticated users --%>
              <%= if @current_scope && @current_scope.user do %>
                <%= case @snippet.type do %>
                  <% :skill -> %>
                    <button
                      id="install-skill-btn"
                      phx-click="install_skill"
                      class="flex items-center gap-1.5 px-3 py-2 rounded-lg text-sm bg-emerald-500/15 text-emerald-400 border border-emerald-500/30 hover:bg-emerald-500/25 transition-all"
                    >
                      <span class="hero-arrow-down-tray w-4 h-4" /> Install to Project
                    </button>
                  <% :kin_agent -> %>
                    <button
                      id="install-kin-btn"
                      phx-click="install_kin"
                      class="flex items-center gap-1.5 px-3 py-2 rounded-lg text-sm bg-violet-500/15 text-violet-400 border border-violet-500/30 hover:bg-violet-500/25 transition-all"
                    >
                      <span class="hero-user-plus w-4 h-4" /> Install as Kin
                    </button>
                  <% :prompt -> %>
                    <button
                      id="install-prompt-btn"
                      phx-click="install_prompt"
                      class="flex items-center gap-1.5 px-3 py-2 rounded-lg text-sm bg-amber-500/15 text-amber-400 border border-amber-500/30 hover:bg-amber-500/25 transition-all"
                    >
                      <span class="hero-clipboard-document w-4 h-4" /> Apply to Kin
                    </button>
                  <% _ -> %>
                <% end %>
              <% end %>

              <button
                id="toggle-favorite-btn"
                phx-click="toggle_favorite"
                class={[
                  "flex items-center gap-1.5 px-3 py-2 rounded-lg text-sm transition-all",
                  if(@is_favorited,
                    do: "bg-amber-500/15 text-amber-400 border border-amber-500/30",
                    else:
                      "bg-surface-2 text-gray-400 border border-border-subtle hover:border-border-hover hover:text-gray-300"
                  )
                ]}
              >
                <span class={[
                  "w-4 h-4",
                  if(@is_favorited, do: "hero-star-solid", else: "hero-star")
                ]} />
                {@snippet.favorite_count}
              </button>
              <button
                id="fork-btn"
                phx-click="fork"
                class={[
                  "flex items-center gap-1.5 px-3 py-2 rounded-lg text-sm transition-all",
                  "bg-surface-2 text-gray-400 border border-border-subtle",
                  "hover:border-border-hover hover:text-gray-300"
                ]}
              >
                <span class="hero-arrow-path w-4 h-4" /> Fork ({@snippet.fork_count})
              </button>
            </div>
          </div>
        </div>

        <%!-- Content area --%>
        <div class="glass rounded-xl p-6 animate-fade-in" style="animation-delay: 50ms">
          <.snippet_content snippet={@snippet} />
        </div>

        <%!-- Tags --%>
        <div
          :if={@snippet.tags != []}
          class="flex items-center gap-2 mt-4 animate-fade-in"
          style="animation-delay: 100ms"
        >
          <span
            :for={tag <- @snippet.tags}
            class="text-xs text-gray-400 bg-surface-2 border border-border-subtle px-2 py-1 rounded-md"
          >
            {tag}
          </span>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Render — new / edit
  # ---------------------------------------------------------------------------

  def render(%{live_action: action, form: nil} = assigns) when action in [:new, :edit] do
    ~H"""
    <div class="min-h-screen bg-surface-0 flex items-center justify-center">
      <p class="text-gray-500 text-sm">Loading...</p>
    </div>
    """
  end

  def render(%{live_action: action} = assigns) when action in [:new, :edit] do
    ~H"""
    <div class="min-h-screen bg-surface-0 relative overflow-hidden">
      <div class="home-aurora" aria-hidden="true" />

      <nav class="relative z-20 border-b border-border-subtle bg-surface-0/80 backdrop-blur-md">
        <div class="max-w-3xl mx-auto px-4 sm:px-6 lg:px-8">
          <div class="flex items-center justify-between h-14">
            <div class="flex items-center gap-3">
              <.link navigate={~p"/"} class="text-brand font-semibold text-lg tracking-tight">
                Loomkin
              </.link>
              <span class="text-gray-600">/</span>
              <span class="text-gray-300 text-sm font-medium">
                {if(@live_action == :new, do: "New Snippet", else: "Edit Snippet")}
              </span>
            </div>
          </div>
        </div>
      </nav>

      <div id="main-content" class="relative z-10 max-w-3xl mx-auto px-4 sm:px-6 lg:px-8 pt-8 pb-16">
        <h1 class="text-2xl font-semibold text-white mb-6 animate-fade-in">
          {if(@live_action == :new, do: "Create a Snippet", else: "Edit Snippet")}
        </h1>

        <.form
          for={@form}
          id="snippet-form"
          phx-change="validate"
          phx-submit="save"
          class="space-y-6 animate-fade-in"
          style="animation-delay: 50ms"
        >
          <.input field={@form[:title]} label="Title" placeholder="My awesome skill..." />
          <.input
            field={@form[:description]}
            type="textarea"
            label="Description"
            placeholder="What does this snippet do?"
          />

          <div class="grid grid-cols-2 gap-4">
            <.input
              field={@form[:type]}
              type="select"
              label="Type"
              options={[
                {"Skill", "skill"},
                {"Prompt", "prompt"},
                {"Kin Agent", "kin_agent"},
                {"Chat Log", "chat_log"}
              ]}
            />
            <.input
              field={@form[:visibility]}
              type="select"
              label="Visibility"
              options={[
                {"Private", "private"},
                {"Unlisted", "unlisted"},
                {"Public", "public"}
              ]}
            />
          </div>

          <%!-- Type-specific editor fields --%>
          <%= case @snippet_type do %>
            <% :skill -> %>
              <.skill_fields
                form={@form}
                snippet={@snippet}
                skill_name={existing_skill_name(@snippet)}
                skill_body={existing_skill_body(@snippet)}
              />
            <% :kin_agent -> %>
              <.kin_agent_fields form={@form} snippet={@snippet} />
            <% :prompt -> %>
              <.prompt_fields form={@form} snippet={@snippet} />
            <% :chat_log -> %>
              <.chat_log_fields snippet={@snippet} />
            <% _ -> %>
          <% end %>

          <.input
            field={@form[:tags]}
            label="Tags"
            placeholder="comma, separated, tags"
          />

          <div class="flex items-center justify-end gap-3 pt-4">
            <.link
              navigate={~p"/"}
              class="px-4 py-2 text-sm text-gray-400 hover:text-gray-300 transition-colors"
            >
              Cancel
            </.link>
            <.button type="submit">
              {if(@live_action == :new, do: "Create Snippet", else: "Save Changes")}
            </.button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Type-specific form field components
  # ---------------------------------------------------------------------------

  attr :form, :map, required: true
  attr :snippet, :map, required: true
  attr :skill_name, :string, default: ""
  attr :skill_body, :string, default: ""

  defp skill_fields(assigns) do
    ~H"""
    <div class="space-y-5">
      <div>
        <label
          for="skill_name"
          class="block text-sm font-medium text-gray-300 mb-1.5"
        >
          Skill Name
          <span class="ml-1 text-xs text-gray-500 font-normal">
            (kebab-case — auto-generated from title if blank)
          </span>
        </label>
        <input
          id="skill_name"
          type="text"
          name="skill_name"
          value={@skill_name}
          placeholder="my-skill-name"
          class="w-full bg-surface-1 border border-border-subtle rounded-lg px-3 py-2 text-sm text-gray-200 placeholder-gray-600 font-mono focus:outline-none focus:border-brand/60"
        />
      </div>

      <div>
        <label
          for="skill_body"
          class="block text-sm font-medium text-gray-300 mb-1.5"
        >
          Skill Content
          <span class="ml-1 text-xs text-gray-500 font-normal">
            (markdown — instructions for agents)
          </span>
        </label>
        <textarea
          id="skill_body"
          name="skill_body"
          placeholder="Describe what this skill teaches agents to do..."
          class="w-full min-h-[400px] bg-surface-1 border border-border-subtle rounded-lg px-3 py-2 text-sm text-gray-200 placeholder-gray-600 font-mono leading-relaxed focus:outline-none focus:border-brand/60 resize-y"
        ><%= @skill_body %></textarea>
      </div>
    </div>
    """
  end

  attr :form, :map, required: true
  attr :snippet, :map, required: true

  defp kin_agent_fields(assigns) do
    assigns =
      assign(assigns,
        kin_role: existing_kin_field(assigns.snippet, "role") || "coder",
        kin_system_prompt_extra: existing_kin_field(assigns.snippet, "system_prompt_extra") || "",
        kin_potency: existing_kin_field(assigns.snippet, "potency") || 50,
        kin_spawn_context: existing_kin_field(assigns.snippet, "spawn_context") || ""
      )

    ~H"""
    <div class="space-y-5">
      <div>
        <label for="kin_role" class="block text-sm font-medium text-gray-300 mb-1.5">
          Role
        </label>
        <select
          id="kin_role"
          name="kin_role"
          class="w-full bg-surface-1 border border-border-subtle rounded-lg px-3 py-2 text-sm text-gray-200 focus:outline-none focus:border-brand/60"
        >
          <%= for {label, value} <- [
            {"Lead", "lead"},
            {"Coder", "coder"},
            {"Researcher", "researcher"},
            {"Reviewer", "reviewer"},
            {"Tester", "tester"},
            {"Concierge", "concierge"},
          ] do %>
            <option value={value} selected={value == to_string(@kin_role)}>{label}</option>
          <% end %>
        </select>
      </div>

      <div>
        <label for="kin_system_prompt_extra" class="block text-sm font-medium text-gray-300 mb-1.5">
          System Prompt Extra
          <span class="ml-1 text-xs text-gray-500 font-normal">
            (custom instructions appended to the role prompt)
          </span>
        </label>
        <textarea
          id="kin_system_prompt_extra"
          name="kin_system_prompt_extra"
          placeholder="You are an expert in Elixir and Phoenix. Always suggest idiomatic Elixir patterns..."
          class="w-full min-h-[200px] bg-surface-1 border border-border-subtle rounded-lg px-3 py-2 text-sm text-gray-200 placeholder-gray-600 leading-relaxed focus:outline-none focus:border-brand/60 resize-y"
        ><%= @kin_system_prompt_extra %></textarea>
      </div>

      <div class="grid grid-cols-2 gap-4">
        <div>
          <label for="kin_potency" class="block text-sm font-medium text-gray-300 mb-1.5">
            Potency <span class="ml-1 text-xs text-gray-500 font-normal">(0–100)</span>
          </label>
          <input
            id="kin_potency"
            type="number"
            name="kin_potency"
            value={@kin_potency}
            min="0"
            max="100"
            class="w-full bg-surface-1 border border-border-subtle rounded-lg px-3 py-2 text-sm text-gray-200 focus:outline-none focus:border-brand/60"
          />
        </div>
      </div>

      <div>
        <label for="kin_spawn_context" class="block text-sm font-medium text-gray-300 mb-1.5">
          Spawn Context
          <span class="ml-1 text-xs text-gray-500 font-normal">
            (describe when this kin agent should be spawned)
          </span>
        </label>
        <textarea
          id="kin_spawn_context"
          name="kin_spawn_context"
          placeholder="Spawn this agent when the task involves database schema design or Ecto migrations..."
          class="w-full min-h-[100px] bg-surface-1 border border-border-subtle rounded-lg px-3 py-2 text-sm text-gray-200 placeholder-gray-600 leading-relaxed focus:outline-none focus:border-brand/60 resize-y"
        ><%= @kin_spawn_context %></textarea>
      </div>
    </div>
    """
  end

  attr :form, :map, required: true
  attr :snippet, :map, required: true

  defp prompt_fields(assigns) do
    assigns =
      assign(assigns,
        prompt_system: existing_prompt_field(assigns.snippet, "system_prompt"),
        prompt_user_template: existing_prompt_field(assigns.snippet, "user_prompt_template")
      )

    ~H"""
    <div class="space-y-5">
      <div>
        <label for="prompt_system" class="block text-sm font-medium text-gray-300 mb-1.5">
          System Prompt
        </label>
        <textarea
          id="prompt_system"
          name="prompt_system"
          placeholder="You are a helpful assistant specializing in..."
          class="w-full min-h-[300px] bg-surface-1 border border-border-subtle rounded-lg px-3 py-2 text-sm text-gray-200 placeholder-gray-600 leading-relaxed focus:outline-none focus:border-brand/60 resize-y"
        ><%= @prompt_system %></textarea>
      </div>

      <div>
        <label for="prompt_user_template" class="block text-sm font-medium text-gray-300 mb-1.5">
          User Prompt Template
          <span phx-no-curly-interpolation class="ml-1 text-xs text-gray-500 font-normal">
            (optional — use {variables} as placeholders)
          </span>
        </label>
        <textarea
          id="prompt_user_template"
          name="prompt_user_template"
          placeholder="Given the following {context}, please {task}..."
          class="w-full min-h-[150px] bg-surface-1 border border-border-subtle rounded-lg px-3 py-2 text-sm text-gray-200 placeholder-gray-600 leading-relaxed focus:outline-none focus:border-brand/60 resize-y"
        ><%= @prompt_user_template %></textarea>
      </div>
    </div>
    """
  end

  attr :snippet, :map, required: true

  defp chat_log_fields(assigns) do
    content = (assigns.snippet && assigns.snippet.content) || %{}
    messages = Map.get(content, "messages", [])
    assigns = assign(assigns, messages: messages)

    ~H"""
    <div>
      <%= if @messages == [] do %>
        <p class="text-sm text-gray-500 italic">
          Chat log content is set programmatically and cannot be edited here.
        </p>
      <% else %>
        <p class="text-sm text-gray-500 mb-3">
          Chat log content — {length(@messages)} messages (read-only)
        </p>
        <div class="space-y-2 max-h-[300px] overflow-y-auto rounded-lg border border-border-subtle p-3 bg-surface-1">
          <div
            :for={msg <- @messages}
            class={[
              "rounded-md px-3 py-2 text-sm",
              if(msg["role"] == "assistant",
                do: "bg-surface-2 text-gray-300",
                else: "bg-brand/10 text-gray-200"
              )
            ]}
          >
            <span class="text-xs font-medium text-gray-500 uppercase">{msg["role"]}</span>
            <p class="mt-0.5 whitespace-pre-wrap line-clamp-3">{msg["content"]}</p>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Snippet content display component (show page)
  # ---------------------------------------------------------------------------

  attr :snippet, :map, required: true

  defp snippet_content(assigns) do
    content = assigns.snippet.content || %{}
    type = assigns.snippet.type
    assigns = assign(assigns, content: content, type: type)

    ~H"""
    <%= case @type do %>
      <% :skill -> %>
        <div class="space-y-4">
          <%= if @content["frontmatter"] do %>
            <div class="flex flex-wrap gap-2 pb-3 border-b border-border-subtle">
              <%= for {key, val} <- @content["frontmatter"], is_binary(val) do %>
                <span class="text-xs bg-surface-2 border border-border-subtle rounded px-2 py-0.5 text-gray-400">
                  <span class="text-gray-500">{key}:</span> {val}
                </span>
              <% end %>
            </div>
          <% end %>
          <pre class="text-gray-300 text-sm whitespace-pre-wrap font-mono leading-relaxed"><%= Map.get(@content, "body", "") %></pre>
        </div>
      <% :kin_agent -> %>
        <div class="space-y-4">
          <div class="grid grid-cols-2 gap-3">
            <div class="bg-surface-2 rounded-lg px-3 py-2">
              <p class="text-xs text-gray-500 uppercase tracking-wider mb-0.5">Role</p>
              <p class="text-sm text-violet-300">{Map.get(@content, "role", "—")}</p>
            </div>
            <div class="bg-surface-2 rounded-lg px-3 py-2">
              <p class="text-xs text-gray-500 uppercase tracking-wider mb-0.5">Potency</p>
              <p class="text-sm text-violet-300">{Map.get(@content, "potency", 50)}</p>
            </div>
          </div>
          <%= if Map.get(@content, "system_prompt_extra") not in [nil, ""] do %>
            <div>
              <p class="text-xs text-gray-500 uppercase tracking-wider mb-1.5">System Prompt Extra</p>
              <pre class="text-gray-300 text-sm whitespace-pre-wrap leading-relaxed"><%= Map.get(@content, "system_prompt_extra") %></pre>
            </div>
          <% end %>
          <%= if Map.get(@content, "spawn_context") not in [nil, ""] do %>
            <div>
              <p class="text-xs text-gray-500 uppercase tracking-wider mb-1.5">Spawn Context</p>
              <p class="text-gray-400 text-sm">{Map.get(@content, "spawn_context")}</p>
            </div>
          <% end %>
        </div>
      <% :prompt -> %>
        <div class="space-y-4">
          <%= if Map.get(@content, "system_prompt") not in [nil, ""] do %>
            <div>
              <p class="text-xs text-gray-500 uppercase tracking-wider mb-1.5">System Prompt</p>
              <pre class="text-gray-300 text-sm whitespace-pre-wrap leading-relaxed"><%= Map.get(@content, "system_prompt") %></pre>
            </div>
          <% end %>
          <%= if Map.get(@content, "user_prompt_template") not in [nil, ""] do %>
            <div class="border-t border-border-subtle pt-4">
              <p class="text-xs text-gray-500 uppercase tracking-wider mb-1.5">
                User Prompt Template
              </p>
              <pre class="text-gray-300 text-sm whitespace-pre-wrap leading-relaxed"><%= Map.get(@content, "user_prompt_template") %></pre>
            </div>
          <% end %>
        </div>
      <% :chat_log -> %>
        <div class="space-y-3 max-h-[600px] overflow-y-auto">
          <%= for msg <- Map.get(@content, "messages", []) do %>
            <div class={[
              "rounded-lg px-3 py-2 text-sm",
              if(msg["role"] == "assistant",
                do: "bg-surface-2 text-gray-300",
                else: "bg-brand/10 text-gray-200"
              )
            ]}>
              <span class="text-xs font-medium text-gray-500 uppercase">{msg["role"]}</span>
              <p class="mt-1 whitespace-pre-wrap">{msg["content"]}</p>
            </div>
          <% end %>
        </div>
      <% _ -> %>
        <div class="chat-markdown">
          <pre class="text-gray-300 text-sm whitespace-pre-wrap"><%= cond do
            is_binary(@content) -> @content
            is_map(@content) -> Jason.encode!(@content, pretty: true)
            true -> inspect(@content)
          end %></pre>
        </div>
    <% end %>
    """
  end

  # ---------------------------------------------------------------------------
  # Badge helpers
  # ---------------------------------------------------------------------------

  defp snippet_badge_class("skill"), do: "bg-cyan-500/10 text-cyan-400 border border-cyan-500/20"

  defp snippet_badge_class("prompt"),
    do: "bg-amber-500/10 text-amber-400 border border-amber-500/20"

  defp snippet_badge_class("kin_agent"),
    do: "bg-violet-500/10 text-violet-400 border border-violet-500/20"

  defp snippet_badge_class("chat_log"),
    do: "bg-emerald-500/10 text-emerald-400 border border-emerald-500/20"

  defp snippet_badge_class(_), do: "bg-gray-500/10 text-gray-400 border border-gray-500/20"
end
