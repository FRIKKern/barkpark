defmodule BarkparkCloud.Repo do
  use Ecto.Repo,
    otp_app: :barkpark_cloud,
    adapter: Ecto.Adapters.Postgres
end
