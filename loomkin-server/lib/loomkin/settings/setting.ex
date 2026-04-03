defmodule Loomkin.Settings.Setting do
  @moduledoc """
  Struct describing a single configurable setting.

  Every setting carries enough metadata for the UI to render the correct
  input control, validate user input, and display contextual help.
  """

  @type setting_type :: :number | :toggle | :select | :duration | :currency | :tag_list

  @type t :: %__MODULE__{
          key: list(atom()),
          label: String.t(),
          description: String.t(),
          why_change: String.t(),
          type: setting_type(),
          options: list(String.t()) | nil,
          default: term(),
          range: {number(), number()} | nil,
          unit: String.t() | nil,
          step: number() | nil,
          tab: String.t(),
          section: String.t(),
          applies_to_new: boolean()
        }

  defstruct [
    :key,
    :label,
    :description,
    :why_change,
    :type,
    :options,
    :default,
    :range,
    :unit,
    :step,
    :tab,
    :section,
    applies_to_new: false
  ]
end
