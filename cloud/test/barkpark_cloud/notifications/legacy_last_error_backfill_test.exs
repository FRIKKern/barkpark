# The migration is not part of the compiled app (migrations live outside the lib
# path), so it is loaded HERE — before this file compiles — rather than in a
# setup block: the test calls the migration's own predicate builder, and a
# runtime-only load would leave those calls compiling against an unknown module.
unless Code.ensure_loaded?(BarkparkCloud.Repo.Migrations.BackfillLegacyLastError) do
  Code.require_file(
    Path.expand(
      "../../../priv/repo/migrations/20260805210000_backfill_legacy_last_error.exs",
      __DIR__
    )
  )
end

defmodule BarkparkCloud.Notifications.LegacyLastErrorBackfillTest do
  @moduledoc """
  Wave 32 S5 — the guard on `20260805210000_backfill_legacy_last_error.exs`.

  The backfill rewrites every `notification_deliveries.last_error` OUTSIDE
  `DeliveryReason`'s closed vocabulary to `label(:unknown)`, because four
  production rows publish the team's Vault-sealed SMTP relay IP to its admins.
  A backfill that over-reaches is a SECOND, quieter data loss: it would flatten
  correctly-classified rows into "The delivery failed" and destroy the only
  failure detail the console legitimately shows. So this test seeds BOTH kinds
  and asserts the classified rows come out BYTE-IDENTICAL.

  It runs the migration's OWN `backfill_statement/0` — not a paraphrase — so a
  predicate change in the migration is a predicate change here.

  MUTATION-PROVED: widening the predicate to catch everything (dropping the
  `NOT IN`/`NOT LIKE` legs from `backfill_statement/0`) reds
  `"leaves every correctly-classified row byte-identical"` with the classified
  sentence rewritten to the unknown one; the legacy assertions stay green, which
  is exactly why the byte-identity half of this test exists.
  """
  use BarkparkCloud.DataCase, async: false

  alias BarkparkCloud.Notifications.DeliveryReason
  alias BarkparkCloud.Repo

  @migration BarkparkCloud.Repo.Migrations.BackfillLegacyLastError

  # The exact production shape, measured read-only on 2026-08-05: all four rows
  # carry the gen_smtp term with the relay host embedded. The host here is a
  # sentinel, not the real one.
  @legacy_smtp ~s({:retries_exceeded, {:network_failure, ~c"203.0.113.77", {:error, :econnrefused}}})

  # A DIFFERENTLY-SHAPED legacy term: no `{:` prefix at all. A denylist of raw
  # term prefixes would miss this; the allowlist must not.
  @legacy_other "gen_smtp: relay 203.0.113.77 refused the connection after 3 tries"

  @unknown_label DeliveryReason.label(:unknown)

  describe "the legacy last_error backfill" do
    test "rewrites a raw legacy transport term to the closed-vocabulary sentence" do
      legacy_id = insert_delivery(@legacy_smtp)

      assert {:ok, 1} = run_backfill()
      assert last_error(legacy_id) == @unknown_label
    end

    test "catches a legacy term that does not share the production shape" do
      other_id = insert_delivery(@legacy_other)

      assert {:ok, 1} = run_backfill()
      assert last_error(other_id) == @unknown_label
      refute last_error(other_id) =~ "203.0.113.77"
    end

    test "leaves every correctly-classified row byte-identical" do
      legacy_id = insert_delivery(@legacy_smtp)

      classified =
        for label <- @migration.constant_labels() ++ ["The channel rejected the message (HTTP 429)."] do
          {insert_delivery(label), label}
        end

      assert {:ok, rewritten} = run_backfill()
      assert last_error(legacy_id) == @unknown_label

      # BYTE IDENTITY, asserted per row and BEFORE the count, so a widened
      # predicate reds on the value that was destroyed rather than on a number.
      for {id, label} <- classified do
        assert last_error(id) == label,
               "classified row was rewritten: #{inspect(label)} became #{inspect(last_error(id))}"
      end

      # And only the one legacy row was touched at all.
      assert rewritten == 1
    end

    test "leaves a null last_error null" do
      id = insert_delivery(nil)

      assert {:ok, 0} = run_backfill()
      assert last_error(id) == nil
    end

    test "is idempotent — a second run rewrites nothing" do
      insert_delivery(@legacy_smtp)

      assert {:ok, 1} = run_backfill()
      assert {:ok, 0} = run_backfill()
    end

    test "derives its vocabulary from DeliveryReason rather than a typed copy" do
      constants = @migration.constant_labels()

      assert length(constants) == length(DeliveryReason.classes())
      assert @unknown_label in constants

      # The one non-constant label is matched by a derived LIKE pattern.
      assert @migration.http_status_like_pattern() =~ "%"

      assert {:ok, %{rows: [[true]]}} =
               Repo.query("SELECT $1::text LIKE $2 ESCAPE '\\'", [
                 DeliveryReason.label({:http_status, 503}),
                 @migration.http_status_like_pattern()
               ])
    end
  end

  ## ── helpers ──────────────────────────────────────────────────────────────

  defp run_backfill do
    {sql, params} = @migration.backfill_statement()

    case Repo.query(sql, params) do
      {:ok, %{num_rows: n}} -> {:ok, n}
      other -> other
    end
  end

  defp insert_delivery(last_error) do
    id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    Repo.query!(
      """
      INSERT INTO notification_deliveries
        (id, team_id, recipient, event, channel, kind, status, attempts, last_error,
         inserted_at, updated_at)
      VALUES ($1, NULL, $2, $3, 'email', 'alert', 'failed', 1, $4, $5, $5)
      """,
      [Ecto.UUID.dump!(id), "member@example.test", "provision_failed", last_error, now]
    )

    id
  end

  defp last_error(id) do
    %{rows: [[value]]} =
      Repo.query!("SELECT last_error FROM notification_deliveries WHERE id = $1", [
        Ecto.UUID.dump!(id)
      ])

    value
  end
end
