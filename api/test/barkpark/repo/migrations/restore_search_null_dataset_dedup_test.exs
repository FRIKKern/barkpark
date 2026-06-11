defmodule Barkpark.Repo.Migrations.RestoreSearchNullDatasetDedupTest do
  @moduledoc """
  barkpark-vwu5 — regression test for the NULL-`dataset_id` dedup restore.

  The 134000 flip dropped the `scope`-STRING unique index on search tables and
  replaced it with `(surface, dataset_id, …)`. The 132000 backfill only stamps
  `dataset_id` for scopes that are DOCUMENT datasets, so search rows whose
  `scope` isn't a doc dataset kept `dataset_id = NULL`. Postgres treats NULLs as
  DISTINCT, so the flipped index does NOT dedupe those rows — the old scope
  uniqueness was lost for them.

  This locks the Option-A restore (20260527150000): seed a `datasets` row per
  distinct search `scope` + stamp `dataset_id` on the legacy NULL rows (after
  collapsing true byte-duplicates), converging them onto the flipped index so
  dedup is enforced again.
  """

  # See the migration-test note in codelist_issue_version_test.exs: the
  # Ecto.Migrator / repo.query! path races on sandbox connection checkout, so
  # these are tagged :flaky and excluded from the default run. Drive with:
  #
  #     mix test test/barkpark/repo/migrations --include flaky
  use Barkpark.DataCase, async: false

  alias Barkpark.Repo

  @migration_file Path.expand(
                    "../../../../priv/repo/migrations/20260527150000_restore_search_null_dataset_dedup.exs",
                    __DIR__
                  )

  setup_all do
    Code.require_file(@migration_file)
    :ok
  end

  alias Barkpark.Repo.Migrations.RestoreSearchNullDatasetDedup

  # Drive the migration body via apply_up/1 / apply_down/1 on the sandbox
  # connection — NOT Ecto.Migrator, which spawns its own (un-allowed) task and
  # races on sandbox checkout (see the :flaky note in codelist_issue_version_test).
  defp migrate_up, do: RestoreSearchNullDatasetDedup.apply_up(Repo)
  defp migrate_down, do: RestoreSearchNullDatasetDedup.apply_down(Repo)

  # A NON-doc scope: not present as a `dataset` string on documents /
  # schema_definitions / media_files, so 132000 left it NULL. Made unique per
  # run so a re-used sandbox can't leak rows between tests.
  defp nondoc_scope, do: "surface-scope-#{System.unique_integer([:positive])}"

  # Raw insert of a search_synonyms row with an EXPLICIT dataset_id (nil = the
  # legacy NULL arm). Bypasses the changeset/dual-write so we can manufacture
  # the exact byte-duplicate NULL rows the bug allowed.
  defp insert_synonym_raw(surface, scope, from_q, to_q, kind, dataset_id) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO search_synonyms
          (id, surface, scope, from_query, to_query, kind, source, enabled,
           dataset_id, inserted_at, updated_at)
        VALUES
          (gen_random_uuid(), $1, $2, $3, $4, $5, 'manual', true,
           $6, now(), now())
        RETURNING id
        """,
        [surface, scope, from_q, to_q, kind, dataset_id]
      )

    id
  end

  defp count_synonyms(surface, scope, from_q, to_q, kind) do
    %{rows: [[n]]} =
      Repo.query!(
        """
        SELECT count(*) FROM search_synonyms
        WHERE surface = $1 AND scope = $2 AND from_query = $3
          AND to_query = $4 AND kind = $5
        """,
        [surface, scope, from_q, to_q, kind]
      )

    n
  end

  defp dataset_ids(surface, scope, from_q, to_q, kind) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT dataset_id FROM search_synonyms
        WHERE surface = $1 AND scope = $2 AND from_query = $3
          AND to_query = $4 AND kind = $5
        """,
        [surface, scope, from_q, to_q, kind]
      )

    Enum.map(rows, fn [d] -> d end)
  end

  describe "Option-A restore on search_synonyms" do
    @tag :flaky
    test "collapses byte-duplicate NULL rows, stamps dataset_id, and re-enforces dedup" do
      scope = nondoc_scope()

      # Two BYTE-DUPLICATE rows on a non-doc scope, both dataset_id = NULL —
      # exactly what the flip allowed (the new index can't see them as equal).
      insert_synonym_raw("documents", scope, "kolor", "color", "alt_correction", nil)
      insert_synonym_raw("documents", scope, "kolor", "color", "alt_correction", nil)

      # A legitimately-DISTINCT row (different from_query) — must be untouched.
      insert_synonym_raw("documents", scope, "lite", "light", "alt_correction", nil)

      # Pre-state: the duplicate pair coexists (bug reproduced).
      assert count_synonyms("documents", scope, "kolor", "color", "alt_correction") == 2

      assert Enum.all?(
               dataset_ids("documents", scope, "kolor", "color", "alt_correction"),
               &is_nil/1
             )

      # --- run the migration ---
      assert :ok = migrate_up()

      # Dedup restored: the byte-duplicate pair collapsed to ONE row…
      assert count_synonyms("documents", scope, "kolor", "color", "alt_correction") == 1

      # …and the survivor is now STAMPED with a non-NULL dataset_id.
      [survivor_ds] = dataset_ids("documents", scope, "kolor", "color", "alt_correction")
      refute is_nil(survivor_ds)

      # The distinct row is unaffected — still present, also stamped (same
      # scope → same dataset), and NOT collapsed into the other tuple.
      assert count_synonyms("documents", scope, "lite", "light", "alt_correction") == 1
      [distinct_ds] = dataset_ids("documents", scope, "lite", "light", "alt_correction")
      assert distinct_ds == survivor_ds

      # The flipped (surface, dataset_id, from_query, to_query, kind) unique
      # index now REJECTS a re-insert of the same tuple with the same
      # dataset_id (uniqueness genuinely restored, not just collapsed).
      assert_raise Postgrex.Error, fn ->
        insert_synonym_raw("documents", scope, "kolor", "color", "alt_correction", survivor_ds)
      end

      # IDEMPOTENT: re-running up/0 (down then up, since the migrator won't
      # re-run an applied version) is a clean no-op — no rows added/removed and
      # the survivor keeps its stamp.
      assert :ok = migrate_down()
      assert :ok = migrate_up()
      assert count_synonyms("documents", scope, "kolor", "color", "alt_correction") == 1
      assert count_synonyms("documents", scope, "lite", "light", "alt_correction") == 1
    end

    @tag :flaky
    test "down/0 reverts the search-only stamp + seeded dataset (reversible)" do
      scope = nondoc_scope()
      insert_synonym_raw("documents", scope, "fcolor", "color", "one_way", nil)

      assert :ok = migrate_up()
      [ds] = dataset_ids("documents", scope, "fcolor", "color", "one_way")
      refute is_nil(ds)

      assert :ok = migrate_down()

      # The stamp is reverted to NULL (legacy arm) and the search-only dataset
      # row is dropped — back to the pre-restore state, ready to re-run.
      [ds_after] = dataset_ids("documents", scope, "fcolor", "color", "one_way")
      assert is_nil(ds_after)

      %{rows: [[seeded]]} =
        Repo.query!("SELECT count(*) FROM datasets WHERE slug = $1", [scope])

      assert seeded == 0
    end
  end
end
