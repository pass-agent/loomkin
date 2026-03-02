defmodule Loomkin.Repo do
  use Ecto.Repo,
    otp_app: :loomkin,
    adapter: Ecto.Adapters.SQLite3
end
