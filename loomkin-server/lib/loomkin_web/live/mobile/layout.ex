defmodule LoomkinWeb.Mobile.Layout do
  @moduledoc "Shared mobile layout component for /m routes."

  use Phoenix.Component

  attr :page_title, :string, default: "Loomkin"
  attr :back_path, :string, default: nil
  slot :inner_block, required: true

  def mobile_layout(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-950 text-white">
      <header class="sticky top-0 z-10 bg-gray-900/95 backdrop-blur-sm border-b border-gray-800 px-4 py-3 flex items-center gap-3">
        <.link
          :if={@back_path}
          navigate={@back_path}
          class="text-gray-400 hover:text-white p-1 -ml-1"
        >
          <svg
            xmlns="http://www.w3.org/2000/svg"
            viewBox="0 0 20 20"
            fill="currentColor"
            class="w-5 h-5"
          >
            <path
              fill-rule="evenodd"
              d="M17 10a.75.75 0 01-.75.75H5.612l4.158 3.96a.75.75 0 11-1.04 1.08l-5.5-5.25a.75.75 0 010-1.08l5.5-5.25a.75.75 0 111.04 1.08L5.612 9.25H16.25A.75.75 0 0117 10z"
              clip-rule="evenodd"
            />
          </svg>
        </.link>
        <h1 class="text-lg font-semibold truncate">{@page_title}</h1>
      </header>
      <main class="pb-8">
        {render_slot(@inner_block)}
      </main>
    </div>
    """
  end
end
