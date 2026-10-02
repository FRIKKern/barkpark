defmodule Barkpark.Repo.Migrations.ExtendWorkspaceDeleteCascadeTest do
  @moduledoc """
  Correctness gate for migration 20260527170000 (obhg-P0 + 0f7g-P1).

  Before this migration the seven peripheral scope-bearing tables —
  webhooks / mutation_events / search_intel_events / search_intel_crystals /
  search_intel_merge_patterns / search_synonyms / paper_events — carried
  their three scope FKs as `:nilify_all`. So a `DELETE FROM workspaces`
  cascaded the four content tables (per 20260527160000) but left every
  row in these seven tables alive with `workspace_id = NULL` (and
  project_id / dataset_id NULL) while their `dataset` STRING survived —
  the SAME orphan-resurfaces-under-Default leak 160000 closed for the
  content tables, just on the OTHER half of the schema.

  This suite runs against the fully-migrated test DB and exercises the
  LIVE FK actions:

    * Deleting a WORKSPACE cascades to a webhook / mutation_event /
      search_intel_event / search_intel_crystal / search_intel_merge_pattern /
      search_synonym / paper_event scoped to it — zero NULL-scope orphans.
    * A row in another workspace is untouched.
    * (down) rolling the migration back restores `:nilify_all`: a workspace
      delete then SET-NULLs the scope columns on each of the seven tables
      instead of cascading.

  See also `tenancy_delete_workspace_test.exs` — the high-level gate that
  asserts `Tenancy.delete_workspace/1` chains app-level side-effect
  cleanup (File.rm / Cdn.invalidate / plugin hooks) BEFORE this SQL
  cascade fires.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Repo
  alias Barkpark.Tenancy

  @migration_file Path.expand(
                    "../../../../priv/repo/migrations/20260527170000_extend_workspace_delete_cascade.exs",
                    __DIR__
                  )

  setup_all do
    Code.require_file(@migration_file)
    :ok
  end

  alias Barkpark.Repo.Migrations.ExtendWorkspaceDeleteCascade

  defp uuid_in(nil), do: nil
  defp uuid_in(id) when is_binary(id), do: Ecto.UUID.dump!(id)

  defp scope do
    ws = create_workspace!()
    project = create_project!(ws)
    {:ok, dataset} = Tenancy.get_or_create_dataset(project, "production")
    {ws, project, dataset}
  end

  # ── inserters for the seven peripheral tables ─────────────────────────────

  defp insert_webhook!(key, ws, project, dataset) do
    Repo.query!(
      """
      INSERT INTO webhooks
        (id, name, url, dataset, events, types, active, workspace_id,
         project_id, dataset_id, inserted_at, updated_at)
      VALUES
        (gen_random_uuid(), $1, $2, $3, '{}', '{}', true, $4, $5, $6, now(), now())
      """,
      [
        key,
        "https://hook/#{key}",
        dataset.slug,
        uuid_in(ws.id),
        uuid_in(project.id),
        uuid_in(dataset.id)
      ]
    )
  end

  defp insert_mutation_event!(key, ws, project, dataset) do
    Repo.query!(
      """
      INSERT INTO mutation_events
        (dataset, type, doc_id, mutation, rev, document, workspace_id,
         project_id, dataset_id, inserted_at)
      VALUES
        ($1, 'post', $2, 'create', $3, '{}'::jsonb, $4, $5, $6, now())
      """,
      [
        dataset.slug,
        key,
        "rev-#{key}-#{System.unique_integer([:positive])}",
        uuid_in(ws.id),
        uuid_in(project.id),
        uuid_in(dataset.id)
      ]
    )
  end

  defp insert_search_event!(key, ws, project, dataset) do
    Repo.query!(
      """
      INSERT INTO search_intel_events
        (id, surface, scope, event_type, query, query_normalized, filters,
         result_count, zero_hits, actor_key, source, workspace_id,
         project_id, dataset_id, inserted_at)
      VALUES
        (gen_random_uuid(), 'documents', $1, 'search', $2, $2, '{}'::jsonb,
         0, false, 'anon', 'api', $3, $4, $5, now())
      """,
      [dataset.slug, key, uuid_in(ws.id), uuid_in(project.id), uuid_in(dataset.id)]
    )
  end

  defp insert_search_crystal!(key, ws, project, dataset) do
    Repo.query!(
      """
      INSERT INTO search_intel_crystals
        (id, surface, scope, period, period_start, query_normalized,
         filter_fingerprint, search_count, workspace_id, project_id,
         dataset_id, inserted_at)
      VALUES
        (gen_random_uuid(), 'documents', $1, 'day', current_date, $2,
         '', 1, $3, $4, $5, now())
      """,
      [dataset.slug, key, uuid_in(ws.id), uuid_in(project.id), uuid_in(dataset.id)]
    )
  end

  defp insert_search_merge_pattern!(key, ws, project, dataset) do
    Repo.query!(
      """
      INSERT INTO search_intel_merge_patterns
        (id, surface, scope, period, period_start, from_fingerprint,
         to_fingerprint, pattern_type, transition_count, success_count,
         workspace_id, project_id, dataset_id, inserted_at)
      VALUES
        (gen_random_uuid(), 'documents', $1, 'day', current_date, $2,
         $2 || '-to', 'refine', 1, 0, $3, $4, $5, now())
      """,
      [dataset.slug, key, uuid_in(ws.id), uuid_in(project.id), uuid_in(dataset.id)]
    )
  end

  defp insert_search_synonym!(key, ws, project, dataset) do
    Repo.query!(
      """
      INSERT INTO search_synonyms
        (id, surface, scope, from_query, to_query, kind, source, enabled,
         workspace_id, project_id, dataset_id, inserted_at, updated_at)
      VALUES
        (gen_random_uuid(), 'documents', $1, $2, $2 || '-to', 'one_way',
         'manual', true, $3, $4, $5, now(), now())
      """,
      [dataset.slug, key, uuid_in(ws.id), uuid_in(project.id), uuid_in(dataset.id)]
    )
  end

  defp insert_paper_event!(key, ws, project, dataset) do
    Repo.query!(
      """
      INSERT INTO paper_events
        (id, goal_id, paper_slug, event_type, branch, workspace_id,
         project_id, dataset_id, inserted_at, updated_at)
      VALUES
        (gen_random_uuid(), $1, $2, 'goal-opened', 'main', $3, $4, $5, now(), now())
      """,
      [key, key, uuid_in(ws.id), uuid_in(project.id), uuid_in(dataset.id)]
    )
  end

  defp count(table, key_col, key) do
    %{rows: [[n]]} =
      Repo.query!("SELECT count(*) FROM #{table} WHERE #{key_col} = $1", [key])

    n
  end

  defp count_orphaned(table, key_col, key) do
    %{rows: [[n]]} =
      Repo.query!(
        """
        SELECT count(*) FROM #{table}
        WHERE #{key_col} = $1
          AND workspace_id IS NULL
          AND project_id IS NULL
          AND dataset_id IS NULL
        """,
        [key]
      )

    n
  end

  defp delete_workspace!(ws),
    do: Repo.query!("DELETE FROM workspaces WHERE id = $1", [uuid_in(ws.id)])

  describe "workspace delete cascades the seven peripheral tables (up)" do
    test "every owned row in the seven tables is GONE; no NULL-scope orphan" do
      {ws, project, dataset} = scope()
      {ws_other, project_other, dataset_other} = scope()

      insert_webhook!("hook-cas", ws, project, dataset)
      insert_mutation_event!("mev-cas", ws, project, dataset)
      insert_search_event!("sev-cas", ws, project, dataset)
      insert_search_crystal!("sc-cas", ws, project, dataset)
      insert_search_merge_pattern!("mp-cas", ws, project, dataset)
      insert_search_synonym!("syn-cas", ws, project, dataset)
      insert_paper_event!("pe-cas", ws, project, dataset)

      insert_webhook!("hook-other", ws_other, project_other, dataset_other)
      insert_search_synonym!("syn-other", ws_other, project_other, dataset_other)

      # preconditions
      assert count("webhooks", "name", "hook-cas") == 1
      assert count("mutation_events", "doc_id", "mev-cas") == 1
      assert count("search_intel_events", "query", "sev-cas") == 1
      assert count("search_intel_crystals", "query_normalized", "sc-cas") == 1
      assert count("search_intel_merge_patterns", "from_fingerprint", "mp-cas") == 1
      assert count("search_synonyms", "from_query", "syn-cas") == 1
      assert count("paper_events", "goal_id", "pe-cas") == 1

      delete_workspace!(ws)

      # All seven peripheral rows are GONE (the cascade extension).
      assert count("webhooks", "name", "hook-cas") == 0
      assert count("mutation_events", "doc_id", "mev-cas") == 0
      assert count("search_intel_events", "query", "sev-cas") == 0
      assert count("search_intel_crystals", "query_normalized", "sc-cas") == 0
      assert count("search_intel_merge_patterns", "from_fingerprint", "mp-cas") == 0
      assert count("search_synonyms", "from_query", "syn-cas") == 0
      assert count("paper_events", "goal_id", "pe-cas") == 0

      # No NULL-scope orphans on any of the seven tables.
      assert count_orphaned("webhooks", "name", "hook-cas") == 0
      assert count_orphaned("mutation_events", "doc_id", "mev-cas") == 0
      assert count_orphaned("search_intel_events", "query", "sev-cas") == 0
      assert count_orphaned("search_intel_crystals", "query_normalized", "sc-cas") == 0
      assert count_orphaned("search_intel_merge_patterns", "from_fingerprint", "mp-cas") == 0
      assert count_orphaned("search_synonyms", "from_query", "syn-cas") == 0
      assert count_orphaned("paper_events", "goal_id", "pe-cas") == 0

      # Other workspace's rows untouched.
      assert count("webhooks", "name", "hook-other") == 1
      assert count("search_synonyms", "from_query", "syn-other") == 1
    end
  end

  # ── down/0 ────────────────────────────────────────────────────────────────
  #
  # ONE PARENT PER ROW (task-962637a90e406961). This used to delete a
  # workspace under a webhook carrying ALL THREE scope keys, and it raised
  # 23503 (webhooks_project_id_fkey) at random in the weekly plugins-off run
  # 36645209662. With every scope FK SET NULL, that delete reaches the row
  # three ways — SET NULL on workspace_id, the projects cascade (project_id),
  # the datasets cascade (dataset_id) — and each is an UPDATE that re-checks
  # the row's OTHER foreign keys (a row version this transaction wrote is
  # always re-checked, key changed or not). Whether a re-check finds a scope
  # parent the cascade already deleted depends on which RI action trigger
  # fires first, and Postgres fires them in trigger-NAME order,
  # `RI_ConstraintTrigger_a_<oid>`, compared as TEXT. `apply_down/1`
  # re-creates the scope FKs with fresh OIDs while the parent cascades keep
  # their migration-time ones, so a suite that pushes the OID counter across a
  # digit boundary (99999 -> 100000) flips the order and the delete raises.
  # Forcing the flipped order (re-creating projects_workspace_id_fkey and
  # datasets_project_id_fkey after the swap) reproduces it every time, with
  # committed fixtures too: it is a property of the down STATE, not of the
  # sandbox. That is the legacy schema's own behaviour, which this migration
  # removed; it is not something a test of the down arm should gamble on.
  #
  # So the down arm is pinned in two deterministic halves: the catalog (all 21
  # FKs are SET NULL after apply_down, CASCADE after apply_up), and the
  # behaviour, one parent per row, where each delete reaches the row by exactly
  # one path.
  @down_tables ~w(webhooks mutation_events search_intel_events search_intel_crystals
                  search_intel_merge_patterns search_synonyms paper_events)

  defp delete_actions do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT conrelid::regclass::text, conname, confdeltype
        FROM pg_constraint
        WHERE contype = 'f'
          AND conrelid::regclass::text = ANY($1)
          AND conname ~ '_(workspace|project|dataset)_id_fkey$'
        """,
        [@down_tables]
      )

    Map.new(rows, fn [_table, name, action] -> {name, action} end)
  end

  defp absent, do: %{id: nil}

  describe "down/0 restores SET NULL semantics" do
    test "after rollback all 21 scope FKs are SET NULL, and CASCADE again after apply_up" do
      before = delete_actions()
      assert map_size(before) == 21
      assert before |> Map.values() |> Enum.uniq() == ["c"]

      ExtendWorkspaceDeleteCascade.apply_down(Repo)

      try do
        after_down = delete_actions()
        assert Map.keys(after_down) == Map.keys(before)
        assert after_down |> Map.values() |> Enum.uniq() == ["n"]
      after
        ExtendWorkspaceDeleteCascade.apply_up(Repo)
      end

      assert delete_actions() == before
    end

    test "after rollback deleting each scope parent SET-NULLs a webhook + synonym it alone scopes" do
      ExtendWorkspaceDeleteCascade.apply_down(Repo)

      try do
        {ws, project, dataset} = scope()
        slug_only = %{id: nil, slug: dataset.slug}

        insert_webhook!("hook-down-ws", ws, absent(), slug_only)
        insert_search_synonym!("syn-down-ws", ws, absent(), slug_only)
        insert_webhook!("hook-down-proj", absent(), project, slug_only)
        insert_search_synonym!("syn-down-proj", absent(), project, slug_only)
        insert_webhook!("hook-down-ds", absent(), absent(), dataset)
        insert_search_synonym!("syn-down-ds", absent(), absent(), dataset)

        # Leaf first, so each delete reaches its rows by exactly one path.
        Repo.query!("DELETE FROM datasets WHERE id = $1", [uuid_in(dataset.id)])
        Repo.query!("DELETE FROM projects WHERE id = $1", [uuid_in(project.id)])
        delete_workspace!(ws)

        # Rows SURVIVE — scope went NULL (legacy behaviour the fix closes).
        for key <- ~w(ws proj ds) do
          assert count("webhooks", "name", "hook-down-#{key}") == 1
          assert count("search_synonyms", "from_query", "syn-down-#{key}") == 1
          assert count_orphaned("webhooks", "name", "hook-down-#{key}") == 1
          assert count_orphaned("search_synonyms", "from_query", "syn-down-#{key}") == 1
        end
      after
        ExtendWorkspaceDeleteCascade.apply_up(Repo)
      end
    end
  end
end
