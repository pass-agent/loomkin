defmodule Loomkin.Vault.Sources.Source do
  @moduledoc "Behaviour for content source adapters."

  @type fetch_result :: %{
          content: String.t(),
          title: String.t() | nil,
          content_type: String.t() | nil,
          byte_size: non_neg_integer()
        }

  @callback fetch(identifier :: String.t(), opts :: keyword()) ::
              {:ok, fetch_result()} | {:error, String.t()}
end
