defmodule Barkpark.Idempotency do
  @moduledoc """
  Idempotency-Key dedup store. Backs P1-k (mutation dedup) and P1-d
  (webhook delivery dedup). Postgres-only; rows expire after `ttl_seconds`
  and are removed by `sweep/1`.
  """

  import Ecto.Query
  alias Barkpark.Repo

  @default_ttl_seconds 86_400

  defmodule Key do
    use Ecto.Schema

    @primary_key {:key_hash, :string, autogenerate: false}

    schema "idempotency_keys" do
      field :scope, :string
      field :status_code, :integer
      field :response_body, :string
      field :response_headers, :map, default: %{}
      field :inserted_at, :utc_datetime_usec
    end
  end

  def hash_key(raw_key, token_id, method, path) do
    material = "#{raw_key}|#{token_id}|#{method}|#{path}"
    :crypto.hash(:sha256, material) |> Base.encode16(case: :lower)
  end

  def lookup(hash) when is_binary(hash) do
    case Repo.get(Key, hash) do
      nil ->
        :miss

      %Key{} = row ->
        {:ok,
         %{
           status: row.status_code,
           body: row.response_body,
           headers: row.response_headers || %{}
         }}
    end
  end

  def store(hash, scope, status, body, headers)
      when is_binary(hash) and is_binary(scope) and is_integer(status) and is_binary(body) do
    %Key{}
    |> Ecto.Changeset.change(%{
      key_hash: hash,
      scope: scope,
      status_code: status,
      response_body: body,
      response_headers: headers_to_map(headers),
      inserted_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  def sweep(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -ttl_seconds(), :second)

    {n, _} =
      from(k in Key, where: k.inserted_at < ^cutoff)
      |> Repo.delete_all()

    n
  end

  defp ttl_seconds do
    Application.get_env(:barkpark, :idempotency, [])
    |> Keyword.get(:ttl_seconds, @default_ttl_seconds)
  end

  defp headers_to_map(list) when is_list(list), do: Map.new(list)
  defp headers_to_map(%{} = m), do: m
  defp headers_to_map(_), do: %{}
end
