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

  OPERATOR-ONLY, INSTANCE-WIDE. This is a `delete_all` with no workspace
  predicate — by design: the `public-read` tier is a singleton instance-level
  credential, not a per-tenant one, and `create_public_read_token/2` binds its
  row to whatever `Auth.create_token/5` defaults to (the seeded Default
  workspace), so scoping the sweep to a tenant would simply break it. The only
  caller is `mix barkpark.rotate_public_read`, driven by the
  `barkpark-rotate-public-token.timer` systemd unit; nothing on the request path
  reaches this function, so it is not an HTTP-reachable mass-delete.

  What it IS reachable for is COLLATERAL: the row filter is a caller-chosen
  `label`, and callers choose labels through request paths. Two fences narrow
  it to rows this module actually mints:

    * the KIND fence (`kind == "api"`) — ticket keys mirror their
      operator-chosen name into `label`, so a key named "public-read-…" would
      otherwise be swept, silently destroying an outsider's identity.
    * the TIER fence (`"public-read" in permissions`) — `TokenController` lets
      a tenant label its own api-kind token freely, in ANY workspace. Before
      this predicate, a token labelled "public-read-my-blog-feed" was deleted
      by the weekly timer on a label-prefix match alone. The predicate is the
      same tier test `BarkparkWeb.Plugs.PublicRead.public_read_token?/1` uses,
      and `create_public_read_token/2` always stamps `["public-read"]`, so no
      real rotation token escapes.
  """
  def purge_public_read_older_than(%DateTime{} = cutoff) do
    pattern = @label_prefix <> "%"

    {n, _} =
      ApiToken
      |> where([t], like(t.label, ^pattern))
      |> where([t], t.kind == "api")
      |> where([t], ^"public-read" in t.permissions)
      |> where([t], t.inserted_at < ^cutoff)
      |> Repo.delete_all()

    {:ok, n}
  end
end
