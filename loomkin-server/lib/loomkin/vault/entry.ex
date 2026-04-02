defmodule Loomkin.Vault.Entry do
  @moduledoc "In-memory representation of a vault entry (parsed from markdown with YAML frontmatter)."

  defstruct [
    :vault_id,
    :path,
    :title,
    :entry_type,
    :body,
    metadata: %{},
    tags: []
  ]

  @type t :: %__MODULE__{
          vault_id: String.t() | nil,
          path: String.t() | nil,
          title: String.t() | nil,
          entry_type: String.t() | nil,
          body: String.t() | nil,
          metadata: map(),
          tags: [String.t()]
        }
end
