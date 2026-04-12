defmodule SanityApi.Repo do
  use Ecto.Repo,
    otp_app: :sanity_api,
    adapter: Ecto.Adapters.Postgres
end
