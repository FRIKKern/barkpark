defmodule Barkpark.Repo do
  use Ecto.Repo,
    otp_app: :barkpark,
    adapter: Ecto.Adapters.Postgres
end
