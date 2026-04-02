defmodule Loomkin.Vault.Storage.Local do
  @moduledoc "Filesystem-based vault storage for development and testing."
  @behaviour Loomkin.Vault.Storage

  @impl true
  def get(path, opts) do
    full = full_path(path, opts)

    case File.read(full) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def put(path, content, opts) do
    full = full_path(path, opts)
    full |> Path.dirname() |> File.mkdir_p!()
    File.write(full, content)
  end

  @impl true
  def delete(path, opts) do
    full = full_path(path, opts)

    case File.rm(full) do
      :ok -> :ok
      # Already gone — idempotent
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def list(prefix, opts) do
    root = Keyword.fetch!(opts, :root)
    dir = Path.join(root, prefix)

    if File.dir?(dir) do
      files =
        dir
        |> Path.join("**/*")
        |> Path.wildcard()
        |> Enum.filter(&File.regular?/1)
        |> Enum.map(&Path.relative_to(&1, root))

      {:ok, files}
    else
      {:ok, []}
    end
  end

  @impl true
  def exists?(path, opts) do
    path |> full_path(opts) |> File.exists?()
  end

  defp full_path(path, opts) do
    root = Keyword.fetch!(opts, :root)
    Path.join(root, path)
  end
end
