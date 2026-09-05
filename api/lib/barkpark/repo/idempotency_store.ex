defmodule Barkpark.Repo.IdempotencyStore do
  @moduledoc """
  Repository boundary for idempotency rows and transaction-bound exact claims.

  Exact claims never reclaim pending rows. Their caller must claim, mutate, and
  complete inside one database transaction so a rollback removes the entire
  operation.
  """

  import Ecto.Query

  alias Barkpark.Repo

  defmodule Key do
    use Ecto.Schema

    @primary_key {:key_hash, :string, autogenerate: false}

    schema "idempotency_keys" do
      field :scope, :string
      field :state, :string, default: "pending"
      field :status_code, :integer
      field :response_body, :string
      field :response_headers, :map, default: %{}
      field :inserted_at, :utc_datetime_usec
    end
  end

  @doc """
  Claim an idempotency row whose exact payload identity is carried by `scope`.

  This operation must run inside the transaction that performs the mutation.
  A matching completed row replays its receipt, while mismatched or pending
  rows fail closed.
  """
  def claim_exact(hash, scope) when is_binary(hash) and is_binary(scope) do
    if Repo.in_transaction?() do
      do_claim_exact(hash, scope)
    else
      {:error, :idempotency_transaction_required}
    end
  end

  defp do_claim_exact(hash, scope) do
    row = %{
      key_hash: hash,
      scope: scope,
      state: "pending",
      status_code: nil,
      response_body: nil,
      response_headers: %{},
      inserted_at: DateTime.utc_now()
    }

    case Repo.insert_all(Key, [row], on_conflict: :nothing, conflict_target: :key_hash) do
      {1, _} ->
        :claimed

      {0, _} ->
        case Repo.get(Key, hash) do
          %Key{scope: ^scope, state: "completed", response_body: body} ->
            decode_exact_receipt(body)

          %Key{scope: ^scope, state: "pending"} ->
            :in_progress

          %Key{} ->
            {:error, :idempotency_payload_mismatch}

          nil ->
            :in_progress
        end
    end
  end

  @doc """
  Complete one exact pending claim with a JSON receipt.

  The scope and pending-state predicates prevent overwriting a claim for a
  different payload or an already-completed replay.
  """
  def complete_exact(hash, scope, receipt)
      when is_binary(hash) and is_binary(scope) and is_map(receipt) do
    if Repo.in_transaction?() do
      do_complete_exact(hash, scope, receipt)
    else
      {:error, :idempotency_transaction_required}
    end
  end

  defp do_complete_exact(hash, scope, receipt) do
    with {:ok, body} <- Jason.encode(receipt) do
      query =
        from(k in Key,
          where: k.key_hash == ^hash and k.scope == ^scope and k.state == "pending"
        )

      case Repo.update_all(query,
             set: [
               state: "completed",
               status_code: 200,
               response_body: body,
               response_headers: %{},
               inserted_at: DateTime.utc_now()
             ]
           ) do
        {1, _} -> :ok
        {0, _} -> {:error, :idempotency_completion_failed}
      end
    end
  end

  defp decode_exact_receipt(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, receipt} when is_map(receipt) -> {:replay, receipt}
      _ -> {:error, :idempotency_receipt_invalid}
    end
  end

  defp decode_exact_receipt(_), do: {:error, :idempotency_receipt_invalid}
end
