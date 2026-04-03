defmodule Loomkin.Release do
  @moduledoc """
  Release-time tasks for Loomkin.

  Used when running as a standalone binary to ensure
  migrations are applied before the application starts.

  ## Usage

  From the binary:

      loom eval "Loomkin.Release.migrate()"

  Or called automatically on startup via Application.
  """

  @app :loomkin

  @doc """
  Runs all pending Ecto migrations.
  """
  def migrate do
    ensure_started()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc """
  Rolls back the last migration.
  """
  def rollback(repo, version) do
    ensure_started()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp ensure_started do
    Application.ensure_all_started(:ecto_sql)
  end
end
