defmodule Barkpark.Auth.PublicRead do
  @moduledoc """
  Helpers for the weekly `public-read` API token rotation.

  Raw tokens are 32 random bytes, URL-safe base64 encoded with no padding.
  Only the SHA256 hash is persisted (via `Barkpark.Auth.create_token/4`);
  the plaintext is returned once from `create_public_read_token/2` so the
  caller can hand it to the deploy pipeline.
  """

  import Ecto.Query
  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo

  @label_prefix "public-read-"

  @doc """
  Create a new public-read token row.

  Returns `{:ok, raw_token, row}` on success. `raw_token` is the only
  place the plaintext will ever be exposed.
  """
  def create_public_read_token(label, dataset \\ "production") when is_binary(label) do
    raw = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    case Auth.create_token(raw, label, dataset, ["public-read"]) do
      {:ok, row} -> {:ok, raw, row}
      error -> error
    end
  end

  @doc """
  Delete public-read token rows older than `cutoff` (a `DateTime`).
  Returns `{:ok, count_deleted}`.

  Only rows whose label starts with `"public-read-"` are considered, so
  manually-labelled tokens are never touched.
  """
  def purge_public_read_older_than(%DateTime{} = cutoff) do
    pattern = @label_prefix <> "%"

    {n, _} =
      ApiToken
      |> where([t], like(t.label, ^pattern))
      |> where([t], t.inserted_at < ^cutoff)
      |> Repo.delete_all()

    {:ok, n}
  end
end
