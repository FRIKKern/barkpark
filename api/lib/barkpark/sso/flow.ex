defmodule Barkpark.Sso.Flow do
  @moduledoc """
  A started OIDC or social sign-in, kept on the server and keyed by its
  `state`. The callback takes it once with `take/2`. A flow expires after 10
  minutes. Each start has its own row, so a second start in the same browser,
  such as a second tab or a retry, does not break the first.

  The PKCE `code_verifier` is encrypted at rest. The state is stored as a hash.
  """
  use Ecto.Schema
  import Ecto.Query

  alias Barkpark.Repo

  @primary_key {:id, :binary_id, autogenerate: true}
  @ttl_seconds 600

  @type t :: %__MODULE__{}

  schema "sso_flows" do
    field :state_hash, :binary
    field :provider, :string
    field :nonce, :string
    field :code_verifier, Barkpark.EncryptedBinary, redact: true
    field :studio, :map
    field :expires_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "Store a started flow for `provider` under `state`. Drops expired flows."
  @spec put(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def put(provider, state, attrs \\ %{}) when is_binary(provider) and is_binary(state) do
    now = DateTime.utc_now()
    Repo.delete_all(from f in __MODULE__, where: f.expires_at < ^now)

    %__MODULE__{
      state_hash: hash(state),
      provider: provider,
      nonce: attrs[:nonce],
      code_verifier: attrs[:code_verifier],
      studio: attrs[:studio],
      expires_at: DateTime.add(now, @ttl_seconds)
    }
    |> Repo.insert()
    |> case do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Take the flow for `provider` and `state`, once. A second take of the same
  state finds nothing. Returns `{:error, :unknown_state}` for a used or unknown
  state and `{:error, :state_expired}` for an expired one.
  """
  @spec take(String.t(), String.t()) :: {:ok, t()} | {:error, :unknown_state | :state_expired}
  def take(provider, state) when is_binary(provider) and is_binary(state) do
    h = hash(state)

    case Repo.delete_all(
           from(f in __MODULE__,
             where: f.state_hash == ^h and f.provider == ^provider,
             select: f
           )
         ) do
      {1, [flow]} ->
        if DateTime.compare(flow.expires_at, DateTime.utc_now()) == :gt,
          do: {:ok, flow},
          else: {:error, :state_expired}

      _ ->
        {:error, :unknown_state}
    end
  end

  def take(_provider, _state), do: {:error, :unknown_state}

  @sweep_batch_limit 5_000

  @doc """
  Delete at most `limit` expired flows, oldest first. Returns the number
  deleted. `Barkpark.Sso.FlowSweeper` calls this on a schedule, so a flow
  started and never finished does not stay in the table after it expires.
  """
  @spec sweep_expired_batch(DateTime.t(), pos_integer()) :: non_neg_integer()
  def sweep_expired_batch(now \\ DateTime.utc_now(), limit \\ @sweep_batch_limit) do
    victims =
      from(f in __MODULE__,
        where: f.expires_at <= ^now,
        order_by: [asc: f.expires_at],
        limit: ^limit,
        select: f.id
      )

    {n, _} = Repo.delete_all(from(f in __MODULE__, where: f.id in subquery(victims)))
    n
  end

  defp hash(state), do: :crypto.hash(:sha256, state)
end
