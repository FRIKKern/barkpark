defmodule Barkpark.Repo do
  @moduledoc """
  The Ecto repository — Barkpark's single Postgres connection pool. Every query,
  changeset, and migration in the app runs through it.
  """
  use Ecto.Repo,
    otp_app: :barkpark,
    adapter: Ecto.Adapters.Postgres

  @doc """
  Cast a caller-supplied id to a `:binary_id` UUID string, or `nil`.

  The one shared guard for every `Repo.get`/`where` keyed on a `:binary_id`
  primary key fed a raw path param: `Ecto.UUID.cast` on a non-UUID string
  returns `:error`, so binding it to a `:binary_id` column would raise
  `Ecto.CastError` → 500. A malformed id can't identify any row, so callers
  fold `nil` into their existing not_found/`nil` branch. Returns the CAST
  string on success (callers bind the returned value, not the original).
  """
  # @canonical capability:uuid-guarded-fetch aka:CastError,binary_id,uuid,Ecto.UUID.cast doc:docs/contracts/tenancy.md
  def uuid_or_nil(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  def uuid_or_nil(_), do: nil
end
