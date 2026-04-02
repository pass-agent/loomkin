defmodule LoomkinWeb.VaultEntryLive do
  @moduledoc "Vault entry viewer — renders a single vault entry with markdown, frontmatter, and backlinks."

  use LoomkinWeb, :live_view

  alias Loomkin.Vault
  alias Loomkin.Vault.Index

  @wiki_link_regex ~r/\[\[([^\]|]+)(?:\|([^\]]+))?\]\]/

  @impl true
  def mount(%{"slug" => slug, "path" => path_parts}, _session, socket) do
    path = Enum.join(path_parts, "/")
    vault = Vault.get_vault_by_slug!(slug)
    user = socket.assigns.current_scope && socket.assigns.current_scope.user

    if Vault.user_can_access_vault?(user, vault) do
      case Vault.read(slug, path) do
        {:ok, entry} ->
          backlinks = Index.backlinks(slug, path)
          rendered_html = render_vault_markdown(entry.body, slug)

          {:ok,
           assign(socket,
             vault: vault,
             slug: slug,
             path: path,
             entry: entry,
             backlinks: backlinks,
             rendered_html: rendered_html,
             page_title: entry.title || Path.basename(path, ".md")
           )}

        {:error, :not_found} ->
          {:ok,
           socket
           |> put_flash(:error, "Entry not found: #{path}")
           |> redirect(to: ~p"/vault/#{slug}")}
      end
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have access to this vault.")
       |> redirect(to: "/")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen" style="background: var(--surface-0);">
      <%!-- Top bar with breadcrumb --%>
      <header
        class="sticky top-0 z-30 flex items-center gap-3 px-6 py-3 border-b"
        style="background: var(--surface-1); border-color: var(--border-default);"
      >
        <.link
          navigate={~p"/vault/#{@slug}"}
          class="flex items-center gap-1.5 text-sm transition-colors hover:text-[var(--brand)]"
          style="color: var(--text-secondary);"
        >
          <svg
            xmlns="http://www.w3.org/2000/svg"
            class="w-4 h-4"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
            stroke-width="1.5"
          >
            <path stroke-linecap="round" stroke-linejoin="round" d="M15 19l-7-7 7-7" />
          </svg>
          {@vault.name}
        </.link>

        <span style="color: var(--text-muted);">/</span>

        <span
          :if={@entry.entry_type}
          class="text-xs font-medium uppercase tracking-wider px-1.5 py-0.5 rounded"
          style="background: var(--surface-2); color: var(--text-muted);"
        >
          {@entry.entry_type}
        </span>

        <span class="text-sm truncate" style="color: var(--text-primary);">
          {@entry.title || Path.basename(@path, ".md")}
        </span>
      </header>

      <%!-- Content area --%>
      <div class="max-w-3xl mx-auto px-6 py-8 md:py-12">
        <%!-- Entry header --%>
        <div class="mb-8">
          <h1
            class="text-2xl md:text-3xl font-semibold leading-tight mb-4"
            style="color: var(--text-primary);"
          >
            {@entry.title || Path.basename(@path, ".md")}
          </h1>

          <div class="flex flex-wrap items-center gap-3">
            <span
              :if={@entry.entry_type}
              class="text-xs font-medium uppercase tracking-wider px-2 py-1 rounded-md"
              style="background: var(--brand-subtle); color: var(--text-brand);"
            >
              {@entry.entry_type}
            </span>

            <span
              :if={meta_date(@entry)}
              class="flex items-center gap-1.5 text-xs"
              style="color: var(--text-muted);"
            >
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="w-3.5 h-3.5"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
                stroke-width="1.5"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  d="M8 7V3m8 4V3m-9 8h10M5 21h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z"
                />
              </svg>
              {meta_date(@entry)}
            </span>

            <span
              :if={meta_author(@entry)}
              class="flex items-center gap-1.5 text-xs"
              style="color: var(--text-muted);"
            >
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="w-3.5 h-3.5"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
                stroke-width="1.5"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  d="M16 7a4 4 0 11-8 0 4 4 0 018 0zM12 14a7 7 0 00-7 7h14a7 7 0 00-7-7z"
                />
              </svg>
              {meta_author(@entry)}
            </span>

            <span
              :for={tag <- @entry.tags || []}
              class="text-xs px-2 py-0.5 rounded-full"
              style="background: var(--brand-muted); color: var(--text-brand);"
            >
              {tag}
            </span>
          </div>
        </div>

        <%!-- Rendered markdown body --%>
        <article class="vault-prose" id="vault-entry-body">
          {raw(@rendered_html)}
        </article>

        <%!-- Backlinks --%>
        <div
          :if={@backlinks != []}
          class="mt-12 pt-8 border-t"
          style="border-color: var(--border-subtle);"
        >
          <h2
            class="flex items-center gap-2 text-xs font-medium uppercase tracking-wider mb-4"
            style="color: var(--text-muted);"
          >
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class="w-3.5 h-3.5"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
              stroke-width="1.5"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                d="M13.828 10.172a4 4 0 00-5.656 0l-4 4a4 4 0 105.656 5.656l1.102-1.101m-.758-4.899a4 4 0 005.656 0l4-4a4 4 0 00-5.656-5.656l-1.1 1.1"
              />
            </svg>
            Linked from ({length(@backlinks)})
          </h2>

          <div class="space-y-1">
            <.link
              :for={bl <- @backlinks}
              navigate={~p"/vault/#{@slug}/#{bl.path}"}
              class="flex items-center gap-2 px-3 py-2 rounded-lg text-sm transition-colors hover:bg-[var(--surface-1)]"
              style="color: var(--text-secondary);"
            >
              <span
                class="text-[10px] uppercase tracking-wider px-1.5 py-0.5 rounded"
                style="background: var(--surface-2); color: var(--text-muted);"
              >
                {bl.link_type}
              </span>
              <span
                class="hover:text-[var(--brand)]"
                style="transition: color var(--transition-fast);"
              >
                {bl.title || Path.basename(bl.path, ".md")}
              </span>
            </.link>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # --- Markdown rendering ---

  defp render_vault_markdown(nil, _slug), do: ""

  defp render_vault_markdown(body, slug) do
    body
    |> convert_wiki_links(slug)
    |> MDEx.to_html!(
      extension: [table: true, strikethrough: true, tasklist: true, autolink: true]
    )
  end

  defp convert_wiki_links(body, slug) do
    Regex.replace(@wiki_link_regex, body, fn _, path, display ->
      display = if display == "", do: Path.basename(path, ".md"), else: display

      ~s(<a href="/vault/#{slug}/#{path}" class="vault-wiki-link">#{Phoenix.HTML.html_escape(display) |> Phoenix.HTML.safe_to_string()}</a>)
    end)
  end

  # --- Metadata helpers ---

  defp meta_date(%{metadata: %{"date" => date}}) when is_binary(date), do: date
  defp meta_date(_), do: nil

  defp meta_author(%{metadata: %{"author" => author}}) when is_binary(author), do: author
  defp meta_author(_), do: nil
end
