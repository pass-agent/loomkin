defmodule Loomkin.Vault.Storage.S3 do
  @moduledoc """
  S3-compatible vault storage for production use.

  Works with AWS S3, Tigris (Fly), MinIO, and any S3-compatible service.

  Required opts:
    * `:bucket` — S3 bucket name

  Optional opts:
    * `:prefix` — key prefix (default `"vault/"`)
    * `:region` — AWS region (default `"auto"` for Tigris)
    * `:endpoint` — custom endpoint URL (e.g. `"https://fly.storage.tigris.dev"`)
    * `:access_key_id` — AWS access key
    * `:secret_access_key` — AWS secret key
  """
  @behaviour Loomkin.Vault.Storage

  @impl true
  def get(path, opts) do
    key = s3_key(path, opts)
    bucket = Keyword.fetch!(opts, :bucket)

    bucket
    |> ExAws.S3.get_object(key)
    |> request(opts)
    |> case do
      {:ok, %{body: body}} -> {:ok, body}
      {:error, {:http_error, 404, _}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def put(path, content, opts) do
    key = s3_key(path, opts)
    bucket = Keyword.fetch!(opts, :bucket)

    bucket
    |> ExAws.S3.put_object(key, content, content_type: "text/markdown")
    |> request(opts)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete(path, opts) do
    key = s3_key(path, opts)
    bucket = Keyword.fetch!(opts, :bucket)

    bucket
    |> ExAws.S3.delete_object(key)
    |> request(opts)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def list(prefix, opts) do
    bucket = Keyword.fetch!(opts, :bucket)
    full_prefix = s3_key(prefix, opts)
    full_prefix = ensure_trailing_slash(full_prefix)
    vault_prefix = Keyword.get(opts, :prefix, "vault/")

    bucket
    |> ExAws.S3.list_objects_v2(prefix: full_prefix)
    |> request(opts)
    |> case do
      {:ok, %{body: %{contents: contents}}} when is_list(contents) ->
        paths =
          contents
          |> Enum.map(& &1.key)
          |> Enum.map(fn key -> String.replace_prefix(key, vault_prefix, "") end)

        {:ok, paths}

      {:ok, %{body: %{contents: _}}} ->
        # nil or empty — no objects found
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def exists?(path, opts) do
    key = s3_key(path, opts)
    bucket = Keyword.fetch!(opts, :bucket)

    bucket
    |> ExAws.S3.head_object(key)
    |> request(opts)
    |> case do
      {:ok, _} -> true
      _ -> false
    end
  end

  # --- Helpers ---

  @doc false
  def s3_key(path, opts) do
    prefix = Keyword.get(opts, :prefix, "vault/")
    prefix <> path
  end

  @doc false
  def build_config(opts) do
    config = []

    config =
      if endpoint = Keyword.get(opts, :endpoint) do
        uri = URI.parse(endpoint)
        scheme = uri.scheme || "https"
        port = uri.port || if(scheme == "https", do: 443, else: 80)
        [{:host, uri.host}, {:scheme, "#{scheme}://"}, {:port, port} | config]
      else
        config
      end

    config =
      if region = Keyword.get(opts, :region) do
        [{:region, region} | config]
      else
        config
      end

    config =
      if key = Keyword.get(opts, :access_key_id) do
        [{:access_key_id, key} | config]
      else
        config
      end

    config =
      if secret = Keyword.get(opts, :secret_access_key) do
        [{:secret_access_key, secret} | config]
      else
        config
      end

    config
  end

  defp request(operation, opts) do
    config = build_config(opts)
    ExAws.request(operation, config)
  end

  defp ensure_trailing_slash(prefix) do
    if String.ends_with?(prefix, "/"), do: prefix, else: prefix <> "/"
  end
end
