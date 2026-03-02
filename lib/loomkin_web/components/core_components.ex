defmodule LoomkinWeb.CoreComponents do
  @moduledoc """
  Provides core UI components for LoomkinWeb.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:info} phx-mounted={show("#flash")}>Welcome!</.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages"
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :title, :string, default: nil
  attr :rest, :global

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class={[
        "fixed top-2 right-2 mr-2 w-80 sm:w-96 z-50 rounded-lg p-3 ring-1",
        @kind == :info && "bg-emerald-900/80 text-emerald-200 ring-emerald-500/50 fill-emerald-400",
        @kind == :error && "bg-rose-900/80 text-rose-200 ring-rose-500/50 fill-rose-400"
      ]}
      {@rest}
    >
      <p class="text-sm leading-5 font-semibold">
        {msg}
      </p>
    </div>
    """
  end

  @doc """
  Shows the flash group with standard info and error flash messages.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group"

  def flash_group(assigns) do
    ~H"""
    <div id={@id}>
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />
    </div>
    """
  end

  @doc """
  Renders a simple form.
  """
  attr :for, :any, required: true, doc: "the data structure for the form"
  attr :as, :any, default: nil, doc: "the server side parameter to collect all input under"

  attr :rest, :global,
    include: ~w(autocomplete name rel action enctype method novalidate target multipart),
    doc: "the arbitrary HTML attributes to apply to the form tag"

  slot :inner_block, required: true
  slot :actions, doc: "the slot for form actions, such as a submit button"

  def simple_form(assigns) do
    ~H"""
    <.form :let={f} for={@for} as={@as} {@rest}>
      <div class="space-y-4">
        {render_slot(@inner_block, f)}
        <div :for={action <- @actions} class="mt-2 flex items-center justify-between gap-6">
          {render_slot(action, f)}
        </div>
      </div>
    </.form>
    """
  end

  @doc """
  Renders an input with label and error messages.
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file hidden month number password
               range search select tel text textarea time url week)

  attr :field, Phoenix.HTML.FormField, doc: "a form field struct"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"

  attr :rest, :global, include: ~w(accept autocomplete capture cols disabled form list max maxlength
                                    min minlength multiple pattern placeholder readonly required
                                    rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error/1))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div>
      <label :if={@label} for={@id} class="block text-sm font-semibold text-gray-300">
        {@label}
      </label>
      <textarea
        id={@id}
        name={@name}
        class="mt-1 block w-full rounded-lg bg-gray-800 border-gray-700 text-gray-100 focus:ring-violet-500 focus:border-violet-500 sm:text-sm"
        {@rest}
      >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(assigns) do
    ~H"""
    <div>
      <label :if={@label} for={@id} class="block text-sm font-semibold text-gray-300">
        {@label}
      </label>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        class="mt-1 block w-full rounded-lg bg-gray-800 border-gray-700 text-gray-100 focus:ring-violet-500 focus:border-violet-500 sm:text-sm"
        {@rest}
      />
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  @doc """
  Renders a button.
  """
  attr :type, :string, default: nil
  attr :class, :string, default: nil
  attr :rest, :global, include: ~w(disabled form name value)

  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <button
      type={@type}
      class={[
        "phx-submit-loading:opacity-75 rounded-lg bg-violet-600 hover:bg-violet-500",
        "py-2 px-3 text-sm font-semibold text-white active:text-white/80",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used.

  ## Examples

      <.icon name="hero-x-mark-solid" />
      <.icon name="hero-arrow-path" class="ml-1 w-3 h-3 animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :string, default: nil

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  @doc """
  Renders error text below form fields.
  """
  slot :inner_block, required: true

  def error(assigns) do
    ~H"""
    <p class="mt-1 flex gap-2 text-sm text-rose-400">
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Translates an error message using gettext (or returns as-is).
  """
  def translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end

  defp hide(js, selector) do
    JS.hide(js, to: selector, transition: {"transition-opacity duration-200", "opacity-100", "opacity-0"})
  end
end
