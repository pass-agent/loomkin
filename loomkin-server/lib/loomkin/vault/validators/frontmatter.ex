defmodule Loomkin.Vault.Validators.Frontmatter do
  @moduledoc """
  Validates that vault entries have required frontmatter fields for their type.
  Returns :ok or {:warn, %{path, missing_fields, type}}.
  """

  @required_fields %{
    "decision" => ["id", "date", "status"],
    "meeting" => ["date"],
    "checkin" => ["date", "author"],
    "person" => ["role"],
    "okr" => ["cycle", "scope", "status"],
    "spec" => ["status"],
    "milestone" => ["status"]
  }

  @doc """
  Validate an entry map for required frontmatter fields.
  Returns :ok or {:warn, %{path, missing_fields, type}}.
  """
  @spec validate(map()) :: :ok | {:warn, map()}
  def validate(%{entry_type: type, metadata: metadata, path: path})
      when is_binary(type) and is_map(metadata) do
    required = Map.get(@required_fields, type, [])
    missing = Enum.reject(required, &Map.has_key?(metadata, &1))

    case missing do
      [] -> :ok
      fields -> {:warn, %{path: path, missing_fields: fields, type: type}}
    end
  end

  def validate(_entry), do: :ok
end
