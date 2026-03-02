defmodule Loomkin.Release do
  @moduledoc """
  Release-time tasks for Loomkin.

  Used when running as a standalone binary to ensure the database
  exists and migrations are applied before the application starts.

  ## Usage

  From the binary:

      loom eval "Loomkin.Release.migrate()"
      loom eval "Loomkin.Release.create_db()"

  Or called automatically on startup via Application.
  """

  @app :loomkin

  @doc """
  Ensures the SQLite database file and directory exist.
  """
  def create_db do
    db_path = db_path()
    db_dir = Path.dirname(db_path)

    unless File.dir?(db_dir) do
      File.mkdir_p!(db_dir)
    end

    :ok
  end

  @doc """
  Runs all pending Ecto migrations.
  """
  def migrate do
    ensure_started()
    create_db()

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

  @doc """
  Returns the database path, using ~/.loomkin/loom.db for release mode.
  """
  def db_path do
    Application.get_env(@app, Loomkin.Repo)[:database] ||
      Path.join([System.user_home!(), ".loomkin", "loomkin.db"])
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp ensure_started do
    Application.ensure_all_started(:ecto_sql)
  end
end
