defmodule Barkpark.ContextualHistoryLookupTest do
  use Barkpark.DataCase, async: true

  alias Barkpark.Idempotency
  alias Barkpark.Repo
  alias Barkpark.Repo.IdempotencyStore

  @prefixes ["paper_ops:v1:", "block_form:v1:", "document_op:v1:"]
  @max_age_seconds 3_600
  @now ~U[2026-09-08 12:00:00.000000Z]

  test "returns an exact completed receipt only inside a transaction" do
    hash = insert_row!(scope: "paper_ops:v1:fingerprint", inserted_at: @now)

    assert {:error, :idempotency_transaction_required} =
             Idempotency.lookup_completed_exact(hash, @prefixes, @max_age_seconds, @now)

    assert {:ok, {:ok, %{"rev" => 7, "slug" => "paper"}}} =
             Repo.transaction(fn ->
               Idempotency.lookup_completed_exact(hash, @prefixes, @max_age_seconds, @now)
             end)
  end

  test "uses an inclusive unswept receipt age boundary and rejects older rows" do
    boundary = DateTime.add(@now, -@max_age_seconds, :second)
    boundary_hash = insert_row!(scope: "block_form:v1:fingerprint", inserted_at: boundary)

    expired_hash =
      insert_row!(
        scope: "document_op:v1:fingerprint",
        inserted_at: DateTime.add(boundary, -1, :microsecond)
      )

    assert {:ok, {:ok, %{"rev" => 7, "slug" => "paper"}}} =
             transaction_lookup(boundary_hash)

    assert {:ok, {:error, :idempotency_receipt_expired}} = transaction_lookup(expired_hash)
  end

  test "rejects future timestamps as malformed" do
    hash = insert_row!(inserted_at: DateTime.add(@now, 1, :microsecond))
    assert {:ok, {:error, :idempotency_receipt_malformed}} = transaction_lookup(hash)
  end

  test "distinguishes missing, pending, and disallowed scope rows" do
    pending = insert_row!(state: "pending", status_code: nil, response_body: nil)
    wrong_scope = insert_row!(scope: "unrelated:v1:fingerprint")

    assert {:ok, {:error, :idempotency_receipt_missing}} =
             transaction_lookup(unique_hash())

    assert {:ok, {:error, :idempotency_receipt_pending}} = transaction_lookup(pending)

    assert {:ok, {:error, :idempotency_receipt_wrong_scope}} =
             transaction_lookup(wrong_scope)
  end

  test "fails closed for malformed completed rows and receipt bodies" do
    wrong_status = insert_row!(status_code: 201)
    invalid_json = insert_row!(response_body: "not-json")
    scalar_json = insert_row!(response_body: Jason.encode!(["not", "a", "map"]))

    for hash <- [wrong_status, invalid_json, scalar_json] do
      assert {:ok, {:error, :idempotency_receipt_malformed}} = transaction_lookup(hash)
    end
  end

  test "validates every lookup argument before reading the store" do
    invalid_arguments = [
      {"", @prefixes, @max_age_seconds, @now},
      {unique_hash(), [], @max_age_seconds, @now},
      {unique_hash(), ["paper_ops:v1:", ""], @max_age_seconds, @now},
      {unique_hash(), "paper_ops:v1:", @max_age_seconds, @now},
      {unique_hash(), @prefixes, -1, @now},
      {unique_hash(), @prefixes, 1.5, @now},
      {unique_hash(), @prefixes, @max_age_seconds, :not_a_datetime}
    ]

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               for {hash, prefixes, max_age, now} <- invalid_arguments do
                 assert {:error, :idempotency_lookup_invalid_args} =
                          Idempotency.lookup_completed_exact(hash, prefixes, max_age, now)
               end

               :ok
             end)
  end

  defp transaction_lookup(hash) do
    Repo.transaction(fn ->
      Idempotency.lookup_completed_exact(hash, @prefixes, @max_age_seconds, @now)
    end)
  end

  defp insert_row!(overrides \\ []) do
    hash = unique_hash()

    attrs =
      %{
        key_hash: hash,
        scope: "paper_ops:v1:fingerprint",
        state: "completed",
        status_code: 200,
        response_body: Jason.encode!(%{"slug" => "paper", "rev" => 7}),
        response_headers: %{},
        inserted_at: @now
      }
      |> Map.merge(Map.new(overrides))

    Repo.insert!(struct!(IdempotencyStore.Key, attrs))
    hash
  end

  defp unique_hash do
    :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
  end
end
