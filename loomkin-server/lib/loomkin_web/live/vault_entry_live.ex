defmodule LoomkinWeb.VaultEntryLive do
  @moduledoc "Vault entry viewer — renders a single vault entry with markdown, frontmatter, and backlinks."

  use LoomkinWeb, :live_view

  alias Loomkin.Vault
  alias Loomkin.Vault.Index

  @wiki_link_regex ~r/\[\[([^\]|]+)(?:\|([^\]]+))?\]\]/

  @type_colors %{
    "note" => "--accent-cyan",
    "topic" => "--accent-mauve",
    "project" => "--accent-amber",
    "person" => "--accent-emerald",
    "decision" => "--accent-rose",
    "meeting" => "--accent-peach",
    "checkin" => "--accent-emerald",
    "idea" => "--accent-amber",
    "source" => "--accent-cyan",
    "spec" => "--accent-mauve",
    "milestone" => "--accent-peach",
    "okr" => "--accent-rose"
  }

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
          headings = extract_headings(entry.body)

          {:ok,
           assign(socket,
             vault: vault,
             slug: slug,
             path: path,
             entry: entry,
             backlinks: backlinks,
             rendered_html: rendered_html,
             headings: headings,
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
    <div class="vault-entry min-h-screen" style="background: var(--surface-0);">
      <%!-- Breadcrumb bar --%>
      <header class="vault-entry-header sticky top-0 z-30">
        <div class="max-w-6xl mx-auto px-6 flex items-center gap-3 py-3">
          <.link
            navigate={~p"/vault/#{@slug}"}
            class="vault-breadcrumb-link"
          >
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class="w-3.5 h-3.5"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
              stroke-width="2"
            >
              <path stroke-linecap="round" stroke-linejoin="round" d="M15 19l-7-7 7-7" />
            </svg>
            {@vault.name}
          </.link>

          <span class="text-[10px]" style="color: var(--text-muted);">/</span>

          <span
            :if={@entry.entry_type}
            class="vault-entry-type-badge"
            style={"border-color: var(#{type_color_var(@entry.entry_type)}); color: var(#{type_color_var(@entry.entry_type)});"}
          >
            {@entry.entry_type}
          </span>

          <span class="text-sm truncate font-medium" style="color: var(--text-primary);">
            {@entry.title || Path.basename(@path, ".md")}
          </span>
        </div>
        <div class="vault-header-thread" />
      </header>

      <%!-- Content — 2-column --%>
      <div class="max-w-6xl mx-auto px-6 py-10 flex gap-12">
        <%!-- Article --%>
        <div
          class="min-w-0 flex-1 max-w-3xl"
          style="animation: fadeUp 0.5s cubic-bezier(0.16, 1, 0.3, 1) both;"
        >
          <%!-- Entry title block --%>
          <div class="mb-10">
            <div class="flex items-center gap-2.5 mb-4">
              <span
                class="vault-type-dot"
                style={"background: var(#{type_color_var(@entry.entry_type)});"}
              />
              <span
                class="text-[10px] font-mono uppercase tracking-[0.15em]"
                style={"color: var(#{type_color_var(@entry.entry_type)});"}
              >
                {@entry.entry_type}
              </span>
              <span
                :if={meta_val(@entry, "status")}
                class="vault-status-pill"
                style={"background: #{status_bg(meta_val(@entry, "status"))}; color: #{status_fg(meta_val(@entry, "status"))};"}
              >
                {meta_val(@entry, "status")}
              </span>
            </div>
            <h1 class="vault-entry-title">
              {@entry.title || Path.basename(@path, ".md")}
            </h1>
            <div class="flex items-center gap-4 mt-3">
              <span
                :if={meta_date(@entry)}
                class="text-xs font-mono"
                style="color: var(--text-muted);"
              >
                {meta_date(@entry)}
              </span>
              <span :if={meta_author(@entry)} class="text-xs" style="color: var(--text-muted);">
                by <span style="color: var(--text-secondary);">{meta_author(@entry)}</span>
              </span>
            </div>
            <%!-- Tags inline --%>
            <div :if={(@entry.tags || []) != []} class="flex flex-wrap gap-1.5 mt-3">
              <span :for={tag <- @entry.tags} class="vault-tag">{tag}</span>
            </div>
            <%!-- Thread divider --%>
            <div
              class="vault-title-thread mt-8"
              style={"--thread-color: var(#{type_color_var(@entry.entry_type)});"}
            />
          </div>

          <%!-- Rendered body --%>
          <article class="vault-prose" id="vault-entry-body">
            {raw(@rendered_html)}
          </article>

          <%!-- Backlinks --%>
          <div
            :if={@backlinks != []}
            class="vault-backlinks"
          >
            <div class="flex items-center gap-2 mb-4">
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="w-3.5 h-3.5"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
                stroke-width="1.5"
                style="color: var(--accent-cyan);"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  d="M13.828 10.172a4 4 0 00-5.656 0l-4 4a4 4 0 105.656 5.656l1.102-1.101m-.758-4.899a4 4 0 005.656 0l4-4a4 4 0 00-5.656-5.656l-1.1 1.1"
                />
              </svg>
              <span
                class="text-[10px] font-mono uppercase tracking-[0.15em]"
                style="color: var(--text-muted);"
              >
                Linked from ({length(@backlinks)})
              </span>
              <div class="flex-1 h-px" style="background: var(--border-subtle);" />
            </div>
            <div class="space-y-1">
              <.link
                :for={bl <- @backlinks}
                navigate={~p"/vault/#{@slug}/#{bl.path}"}
                class="vault-backlink-row"
              >
                <span class="vault-backlink-type">{bl.link_type}</span>
                <span class="vault-backlink-title">
                  {bl.title || Path.basename(bl.path, ".md")}
                </span>
              </.link>
            </div>
          </div>
        </div>

        <%!-- Sidebar --%>
        <aside
          class="hidden lg:block w-52 shrink-0 sticky top-20 self-start space-y-5"
          style="animation: fadeUp 0.5s 0.1s cubic-bezier(0.16, 1, 0.3, 1) both;"
        >
          <%!-- Metadata card --%>
          <div class="vault-meta-card">
            <div :if={meta_val(@entry, "id")} class="vault-meta-row">
              <span class="vault-meta-label">ID</span>
              <span class="font-mono text-[11px]" style="color: var(--text-secondary);">
                {meta_val(@entry, "id")}
              </span>
            </div>
            <div :if={meta_val(@entry, "status")} class="vault-meta-row">
              <span class="vault-meta-label">Status</span>
              <span
                class="vault-status-pill"
                style={"background: #{status_bg(meta_val(@entry, "status"))}; color: #{status_fg(meta_val(@entry, "status"))};"}
              >
                {meta_val(@entry, "status")}
              </span>
            </div>
            <div :if={meta_date(@entry)} class="vault-meta-row">
              <span class="vault-meta-label">Date</span>
              <span class="font-mono text-[11px]" style="color: var(--text-secondary);">
                {meta_date(@entry)}
              </span>
            </div>
            <div :if={meta_author(@entry)} class="vault-meta-row">
              <span class="vault-meta-label">Author</span>
              <span class="text-[11px]" style="color: var(--text-secondary);">
                {meta_author(@entry)}
              </span>
            </div>
            <div class="vault-meta-row">
              <span class="vault-meta-label">Path</span>
              <span
                class="font-mono text-[10px] break-all leading-relaxed"
                style="color: var(--text-muted);"
              >
                {@path}
              </span>
            </div>
          </div>

          <%!-- TOC --%>
          <div :if={@headings != []} class="vault-toc">
            <p class="vault-toc-heading">On this page</p>
            <a
              :for={%{level: level, text: text, anchor: anchor} <- @headings}
              href={"##{anchor}"}
              class="vault-toc-link"
              style={"padding-left: #{(level - 1) * 0.75}rem;"}
            >
              {text}
            </a>
          </div>
        </aside>
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
    |> add_heading_ids()
  end

  @heading_tag_regex ~r/<(h[1-4])>(.+?)<\/h[1-4]>/

  defp add_heading_ids(html) do
    Regex.replace(@heading_tag_regex, html, fn _, tag, text ->
      plain = String.replace(text, ~r/<[^>]+>/, "")
      anchor = slugify_heading(plain)
      ~s(<#{tag} id="#{anchor}">#{text}</#{tag}>)
    end)
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

  defp meta_val(%{metadata: meta}, key) when is_map(meta) do
    case Map.get(meta, key) do
      val when is_binary(val) and val != "" -> val
      _ -> nil
    end
  end

  defp meta_val(_, _), do: nil

  defp type_color_var(type), do: Map.get(@type_colors, type, "--text-muted")

  defp status_bg("draft"), do: "rgba(249, 226, 175, 0.15)"
  defp status_bg("published"), do: "rgba(166, 227, 161, 0.15)"
  defp status_bg("approved"), do: "rgba(166, 227, 161, 0.15)"
  defp status_bg("implemented"), do: "rgba(137, 220, 235, 0.15)"
  defp status_bg("planned"), do: "rgba(249, 226, 175, 0.15)"
  defp status_bg("in-progress"), do: "rgba(250, 179, 135, 0.15)"
  defp status_bg("done"), do: "rgba(166, 227, 161, 0.15)"
  defp status_bg("archived"), do: "rgba(110, 104, 98, 0.15)"
  defp status_bg("accepted"), do: "rgba(166, 227, 161, 0.15)"
  defp status_bg("rejected"), do: "rgba(243, 139, 168, 0.15)"
  defp status_bg(_), do: "rgba(110, 104, 98, 0.1)"

  defp status_fg("draft"), do: "var(--accent-amber)"
  defp status_fg("published"), do: "var(--accent-emerald)"
  defp status_fg("approved"), do: "var(--accent-emerald)"
  defp status_fg("implemented"), do: "var(--accent-cyan)"
  defp status_fg("planned"), do: "var(--accent-amber)"
  defp status_fg("in-progress"), do: "var(--accent-peach)"
  defp status_fg("done"), do: "var(--accent-emerald)"
  defp status_fg("archived"), do: "var(--text-muted)"
  defp status_fg("accepted"), do: "var(--accent-emerald)"
  defp status_fg("rejected"), do: "var(--accent-rose)"
  defp status_fg(_), do: "var(--text-muted)"

  # --- Heading extraction for TOC ---

  @heading_regex ~r/^(\#{1,4})\s+(.+)$/m

  defp extract_headings(nil), do: []

  defp extract_headings(body) do
    Regex.scan(@heading_regex, body)
    |> Enum.map(fn [_, hashes, text] ->
      %{
        level: String.length(hashes),
        text: text |> String.trim(),
        anchor: text |> String.trim() |> slugify_heading()
      }
    end)
  end

  defp slugify_heading(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\w\s-]/u, "")
    |> String.replace(~r/[\s]+/, "-")
    |> String.trim("-")
  end
end
