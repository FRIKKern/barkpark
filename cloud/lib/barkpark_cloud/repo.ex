defmodule BarkparkCloud.Repo do
  use Ecto.Repo,
    otp_app: :barkpark_cloud,
    adapter: Ecto.Adapters.Postgres

  @doc """
  Cast `id` to a UUID string, or `nil` when it isn't a valid UUID.

  The class guard for :binary_id PK lookups: a malformed path param fed straight
  into `Repo.get`/`Repo.get_by`/a `where: x.id == ^id` query raises
  `Ecto.Query.CastError` → an HTTP 500. Routing a non-castable id to `nil` lets
  callers return the `{:error, :not_found}` (→ 404) the API documents for an
  absent/invalid id. A valid UUID passes through unchanged. This is the one home
  for the guard the codebase previously hand-rolled per call site.

  The 500 is cloud-specific and is NOT a typo for api/'s 400: `api/` carries
  `phoenix_ecto`, which maps both CastError structs to 400, while `cloud/` is
  Plug.Router + Bandit with no `phoenix_ecto` at all — the only `Plug.Exception`
  impl in cloud's deps is plug's `for: Any`, which answers 500. Pinned by a run
  in `BarkparkCloud.CastErrorStatusContractTest`, which also reds if api/'s
  answer is ever copied in here; do not "correct" the status above.
  """
  @spec uuid_or_nil(term()) :: binary() | nil
  def uuid_or_nil(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  def uuid_or_nil(_), do: nil

  @doc """
  Fetch `schema` by primary key, guarding the cast: a non-UUID `id` returns `nil`
  instead of raising `Ecto.Query.CastError`.
  """
  @spec get_by_uuid(module(), term()) :: Ecto.Schema.t() | nil
  def get_by_uuid(schema, id) do
    case uuid_or_nil(id) do
      nil -> nil
      uuid -> get(schema, uuid)
    end
  end
end
