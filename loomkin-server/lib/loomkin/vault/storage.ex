defmodule Loomkin.Vault.Storage do
  @moduledoc "Behaviour for vault storage backends."

  @type storage_opts :: keyword()

  @callback get(path :: String.t(), opts :: storage_opts()) ::
              {:ok, binary()} | {:error, term()}
  @callback put(path :: String.t(), content :: binary(), opts :: storage_opts()) ::
              :ok | {:error, term()}
  @callback delete(path :: String.t(), opts :: storage_opts()) ::
              :ok | {:error, term()}
  @callback list(prefix :: String.t(), opts :: storage_opts()) ::
              {:ok, [String.t()]} | {:error, term()}
  @callback exists?(path :: String.t(), opts :: storage_opts()) ::
              boolean()

  @doc "Resolve the storage adapter module from a storage_type string."
  @spec adapter(String.t()) :: module()
  def adapter("local"), do: Loomkin.Vault.Storage.Local
  def adapter("s3"), do: Loomkin.Vault.Storage.S3
  def adapter(type), do: raise(ArgumentError, "unknown storage type: #{type}")
end
