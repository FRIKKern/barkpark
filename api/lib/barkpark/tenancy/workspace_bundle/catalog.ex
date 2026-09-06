defmodule Barkpark.Tenancy.WorkspaceBundle.Catalog do
  @moduledoc """
  The tenant-table catalog for the workspace bundle: the THREE live-derived
  enumerations (E1/E2/E3), the reviewed extraction specs, the non-generated
  column derivation, and the pinned partition sentinel.

  ## Why live-derived, never hardcoded (charter D4)

  Which tables belong to a workspace is derived from the LIVE catalog on every
  export, so a new tenant table is picked up automatically instead of being
  silently dropped:

    * **E1** — every table carrying a `workspace_id` column (42 today; the three
      epic-cycle ledgers `cycle_waves` / `epic_assignments` /
      `epic_benchmark_experiments` (the 20260715 cycle-fleet schema) ride the
      generic `WHERE workspace_id = $ws` path, the three
      registered Chat host / execution tables are workspace-owned, the two
      zero-FK audit tables `audit_events` / `audit_export_sinks` carry the
      column with no FK to `workspaces`, and so does `paper_access_log` (the
      paper view/edit trail, edit-on-the-link slice 4 — same zero-FK,
      append-only, workspace-attributed shape as `audit_events`), `roles` is
      one, both
      `search_surface_config` (Wave 5 Slice A, charter D45/D49) and `data_keys`
      (the per-dataset DEK store, bpb-datakeys-write-path-workspace-attribution)
      were re-pinned from the allowlist, and the five `sync_*` bare-slug tables
      (`sync_cursors` / `sync_dead_letters` / `sync_push_cursors` /
      `sync_push_doc_revs` / `sync_push_conflicts`) gained a nullable
      `workspace_id` attribution column (Wave 5 Slice B, charter D55) — so a
      shared-slug row travels via the `workspace_id` path instead of a bare,
      project-ambiguous `scope`/`dataset`), and the run-secrets store
      `secrets` / `secrets_audit` gained a nullable `workspace_id` FK (Connectors
      W21, charter D191/D192): a workspace's scoped secret rides the generic
      `WHERE workspace_id = $ws` export + FK cascade, while an
      instance-global secret (`workspace_id IS NULL`, e.g. `ingest_token`) is
      never matched by any workspace scan — the two-tier tenant wall.
    * **E2** — the recursive `pg_constraint` FK descendants of `workspaces`
      that do NOT themselves carry `workspace_id` (16: `content_edges`,
      `datasets`, `plugin_doc_state`, `role_permissions`, `task_edges`,
      `webhook_deliveries`, plus the six 20260715 cycle-fleet children
      `chat_runtime_usage_receipts`, `cycle_build_plans`,
      `epic_assignment_results`, `epic_assignment_runtime_attempts`,
      `epic_assignment_tasks`, `epic_benchmark_attempts`, plus the four release
      evidence tables `cycle_release_gate_captures`,
      `cycle_release_gate_consumptions`, `cycle_release_paper_candidates`, and
      `cycle_release_public_smokes`). Reached via a real FK,
      extracted through a parent-join to the nearest `workspace_id`-bearing
      ancestor.
    * **E3** — the `dataset`-column tables minus E1 (4), keyed by a `dataset`
      slug (and, for two of them, a `doc_id`). The `scope`-column allowlist is
      now EMPTY: both former members (`search_surface_config`, `data_keys`)
      gained a `workspace_id` column and moved to E1, and the five `sync_*`
      bare-slug tables moved to E1 too (charter D55), so a shared-slug row —
      including a per-dataset DEK or a workspace's sync cursors / dead-letters /
      push-ledger — is exported and torn down via `WHERE workspace_id = $ws` and
      is never silently dropped.

  ## The reviewed extraction specs

  Membership is live; HOW to extract each E2/E3 table is a reviewed decision
  (the join path / semi-join shape). The pinned partition sentinel
  (`assert_partition!/1`) asserts live-membership == the reviewed classification,
  so a NEW E2/E3 table that appears without an extraction spec RAISES loudly
  instead of exporting empty — the human tripwire that caught `data_keys`.

  ## E3 never fans out (charter D6)

  `documents`' unique key is `(doc_id, type, dataset_id)`, so a workspace can
  hold two docs sharing `(doc_id, dataset)`. A doc-keyed E3 table is therefore
  filtered with a `WHERE EXISTS` semi-join — never a plain JOIN, which would
  double-count. The count-parity gate uses the identical semi-join.
  """

  # ── Pinned partition (the reviewed baseline the sentinel diffs against) ──────
  #
  # These lists are the reviewed classification of every base table as of this
  # schema version. They are NOT what the exporter reads (it derives live) —
  # they are the tripwire: `assert_partition!/1` diffs the LIVE catalog against
  # them and RAISES on any drift, forcing a human to classify a new table.

  @root_table "workspaces"

  # The five `sync_*` tables carry `workspace_id` (charter D55): they were
  # bare-slug E3 tables (project-ambiguous `dataset` grain) until per-workspace
  # attribution promoted `workspace_id` into their primary keys, moving the whole
  # dormant family from E3 → E1 (export keys `WHERE workspace_id=$ws`, delete
  # rides the FK cascade — the same clean path every other E1 table uses).
  # cycle_waves / epic_assignments / epic_benchmark_experiments carry a
  # workspace_id column (the 20260715 epic-cycle / cycle-fleet ledgers). They
  # ride the generic E1 path like every other workspace_id table — exported via
  # `WHERE workspace_id = $ws`, torn down the same way — so a workspace's own
  # cycle/assignment/benchmark rows travel in its bundle and never orphan on
  # teardown. Pinned here to clear the partition sentinel (they were
  # live-detected but unpinned, which is exactly what the sentinel raises on).
  @pinned_e1 ~w(
    access_grants api_tokens audit_events audit_export_sinks chat_execution_events
    chat_execution_leases cycle_correction_admissions
    cycle_correction_promotion_events cycle_correction_quarantines
    cycle_correction_roots cycle_correction_targets
    cycle_release_gate_admissions cycle_release_gate_challenges cycle_waves
    data_keys documents epic_assignments
    epic_benchmark_experiments media_files mutation_events paper_access_log
    paper_events
    projects registered_chat_hosts revisions roles
    schema_definitions search_intel_crystals search_intel_events
    search_intel_merge_patterns search_surface_config search_synonyms
    secrets secrets_audit share_links sync_cursors sync_dead_letters
    sync_push_conflicts sync_push_cursors sync_push_doc_revs webhooks
    workspace_memberships
  )

  # The six 20260715 cycle-fleet children are FK-transitive descendants of
  # `workspaces` that carry NO `workspace_id` of their own — each reaches the
  # tenant grain through a single many-to-one FK to a workspace_id-bearing parent
  # (see @e2_joins). They are pinned E2 so the sentinel is satisfied and their
  # rows travel in the owning workspace's bundle instead of exporting empty:
  #   * chat_runtime_usage_receipts       → documents (task_id)
  #   * cycle_build_plans                 → cycle_waves (wave_id)
  #   * epic_assignment_results           → epic_assignments (assignment_id)
  #   * epic_assignment_runtime_attempts  → epic_assignments (assignment_id)
  #   * epic_assignment_tasks             → epic_assignments (assignment_id)
  #   * epic_benchmark_attempts           → epic_benchmark_experiments (experiment_id)
  @pinned_e2 ~w(
    chat_runtime_usage_receipts content_edges cycle_build_plans
    cycle_release_gate_captures cycle_release_gate_consumptions
    cycle_release_paper_candidates cycle_release_public_smokes datasets
    epic_assignment_results epic_assignment_runtime_attempts epic_assignment_tasks
    epic_benchmark_attempts plugin_doc_state role_permissions task_edges
    webhook_deliveries
  )

  # E3 tables that carry a `doc_id` → filtered by a (doc_id, dataset) semi-join.
  # (`sync_push_conflicts` / `sync_push_doc_revs` moved to E1 — charter D55.)
  @e3_doc_keyed ~w(authoring_exemptions github_sync_conflicts)

  # E3 tables with no `doc_id` → filtered by dataset-slug membership.
  # (`sync_cursors` / `sync_dead_letters` / `sync_push_cursors` moved to E1 — D55.)
  @e3_dataset_keyed ~w(preview_token_jti shares)

  # ── E3-dataset attribution: which of them can name their own tenant (PDS-D74)
  #
  # The bare `dataset` slug is unique only per `(project_id, slug)`, so a slug two
  # workspaces both own attributes to NEITHER — `dataset_slugs_for/1` drops it and
  # the bare `dataset = ANY(slugs)` copy then selects nothing under it. That is
  # correct as a REFUSAL and wrong as a silent one; the two E3-dataset tables are
  # not symmetric about it, so they get different answers:
  #
  #   * a table listed here carries its OWN workspace key, so it is exported and
  #     swept by that column and a shared slug costs it nothing — `workspaces.slug`
  #     is uniquely indexed (20260527110000), which is what makes a slug column a
  #     safe tenant key where the `dataset` slug is not;
  #   * a table NOT listed here has no tenant column at all, so its rows under a
  #     shared slug are genuinely unattributable. They still do not travel — but
  #     the bundle DECLARES them, with the slugs and the row count, instead of
  #     dropping them silently (`WorkspaceBundle`'s `declared_loss` manifest key).
  #
  # Absence is the fail-LOUD default: a new E3-dataset table starts unattributable
  # and shows up in `declared_loss` until someone gives it a real key, rather than
  # inheriting a predicate that would resolve by slug string across tenants.
  @e3_dataset_workspace_slug_column %{"shares" => "workspace_slug"}

  # The `scope`-column allowlist (charter D4/D5): tables whose tenant key is a
  # bare `scope` string, not a `dataset` column, so the mechanical dataset scan
  # cannot see them.
  #
  # EMPTY as of Wave 5 — both former members gained a real `workspace_id` column
  # and moved to E1 (`@pinned_e1`), exported and torn down via
  # `WHERE workspace_id = $ws` instead of a bare, project-ambiguous `scope`:
  #   * `search_surface_config` — Wave 5 Slice A (charter D45/D49), closed a LIVE
  #     cross-tenant config-overwrite bleed.
  #   * `data_keys` — bpb-datakeys-write-path-workspace-attribution (D51-D54),
  #     so a shared-slug DEK is attributed to one workspace, not silently dropped.
  @allowlist %{}

  # Every base table that rolls ABOVE or OUTSIDE the workspace grain (charter
  # D5): global codelists, admin/host state, the org tier, job queue, metrics,
  # user/auth tier, and the residual *_backup tables. A base table that is
  # neither live-tenant nor in this list makes the sentinel RAISE.
  # chat_runtime_telemetry_events (20260715 cycle-fleet) FK-references
  # chat_sessions only — it is NOT reachable from `workspaces` by any FK path, so
  # the live E1/E2/E3 scans never surface it. Like chat_sessions / chat_messages
  # it is host/admin-scoped runtime telemetry that rolls OUTSIDE the workspace
  # grain; pinned non-tenant so the "unaccounted base table" sentinel is clear.
  @pinned_non_tenant ~w(
    chat_messages chat_runtime_telemetry_events chat_sessions
    codelist_value_translations codelist_values
    codelists collapsed_schema_definitions_backup
    cycle_release_gate_migration_state_20260719020100 idempotency_keys login_tickets
    oban_jobs oban_peers oidc_connections org_domains organizations
    paper_events_dataset_rescope_backup plugin_settings plugin_settings_audit
    pulse_counters pulse_events pulse_meters saml_connections schema_migrations
    scim_groups scim_tokens social_identities
    social_providers status_incidents user_email_tokens user_sessions users
    webauthn_credentials
  )

  # E2 extraction specs: a parent-join from the child (`t`) to the nearest
  # ancestor that carries `workspace_id`. FK is many-to-one so a plain JOIN
  # never fans out (unlike E3).
  @e2_joins %{
    "datasets" => {"JOIN projects p ON p.id = t.project_id", "p.workspace_id"},
    "role_permissions" => {"JOIN roles r ON r.id = t.role_id", "r.workspace_id"},
    # SECURITY INVARIANT (pds-bl-pin-webhook-deliveries-inner-join): this INNER
    # JOIN is the ONLY thing keeping media signing secrets out of every bundle.
    # Media deliveries are the one delivery kind whose `payload_snapshot` embeds
    # a plaintext secret (`%{url, secret, body}` — media/delivery/events.ex),
    # and BY DESIGN they carry no `endpoint_id` (media endpoints are
    # config-driven, not `webhooks` rows), so the inner join makes them match no
    # workspace and enter no bundle in any profile. Two changes silently open a
    # credential-export leak:
    #   1. relaxing this to a LEFT JOIN (step one of "orphan rows belong to
    #      everyone" — `assert_partition!/1` raises on a non-inner join here);
    #   2. backfilling `endpoint_id` onto media rows, which makes the secret
    #      workspace-reachable through this join (`assert_partition!/1` raises
    #      on any reachable secret-bearing snapshot).
    "webhook_deliveries" => {"JOIN webhooks w ON w.id = t.endpoint_id", "w.workspace_id"},
    "content_edges" => {"JOIN documents d ON d.id = t.from_id", "d.workspace_id"},
    "task_edges" => {"JOIN documents d ON d.id = t.from_id", "d.workspace_id"},
    "plugin_doc_state" => {"JOIN documents d ON d.id = t.doc_id", "d.workspace_id"},
    # 20260715 cycle-fleet children. Each FK column is NOT NULL, so the plain
    # (many-to-one) parent-join neither fans out nor drops a row — the same
    # shape as every other E2 spec above.
    "chat_runtime_usage_receipts" => {"JOIN documents d ON d.id = t.task_id", "d.workspace_id"},
    "cycle_build_plans" => {"JOIN cycle_waves cw ON cw.id = t.wave_id", "cw.workspace_id"},
    "cycle_release_gate_captures" =>
      {"JOIN cycle_release_gate_challenges challenge ON challenge.id = t.challenge_id",
       "challenge.workspace_id"},
    "cycle_release_gate_consumptions" =>
      {"JOIN cycle_release_gate_admissions admission ON admission.id = t.admission_id",
       "admission.workspace_id"},
    "cycle_release_paper_candidates" =>
      {"JOIN cycle_waves wave ON wave.id = t.target_wave_id", "wave.workspace_id"},
    "cycle_release_public_smokes" =>
      {"JOIN cycle_correction_promotion_events event ON event.id = t.promotion_event_id",
       "event.workspace_id"},
    "epic_assignment_results" =>
      {"JOIN epic_assignments ea ON ea.id = t.assignment_id", "ea.workspace_id"},
    "epic_assignment_runtime_attempts" =>
      {"JOIN epic_assignments ea ON ea.id = t.assignment_id", "ea.workspace_id"},
    "epic_assignment_tasks" =>
      {"JOIN epic_assignments ea ON ea.id = t.assignment_id", "ea.workspace_id"},
    "epic_benchmark_attempts" =>
      {"JOIN epic_benchmark_experiments ee ON ee.id = t.experiment_id", "ee.workspace_id"}
  }

  def root_table, do: @root_table
  def e2_joins, do: @e2_joins
  def e3_doc_keyed, do: @e3_doc_keyed
  def e3_dataset_keyed, do: @e3_dataset_keyed
  def allowlist, do: @allowlist

  @doc """
  The E3-dataset tables that carry their OWN workspace key, mapped to the column
  (PDS-D74). ONE source of truth for both halves of the lockstep: the exporter's
  `copy_where/4` and `Tenancy.delete_workspace/1`'s sweep read the same map, so a
  table can never be exported by one shape and torn down by another.
  """
  @spec e3_dataset_workspace_slug_column() :: %{String.t() => String.t()}
  def e3_dataset_workspace_slug_column, do: @e3_dataset_workspace_slug_column

  @doc """
  The E3-dataset tables with NO workspace key of their own — the population whose
  rows under a cross-tenant-shared dataset slug are genuinely unattributable and
  must therefore be DECLARED in the bundle rather than silently omitted.
  """
  @spec e3_dataset_unattributable() :: [String.t()]
  def e3_dataset_unattributable,
    do: @e3_dataset_keyed -- Map.keys(@e3_dataset_workspace_slug_column)

  # ── Live enumerations (what the exporter actually reads) ─────────────────────

  @doc "E1: every table with a `workspace_id` column (live)."
  def live_e1(repo) do
    query_col(repo, """
    SELECT table_name FROM information_schema.columns
    WHERE table_schema = 'public' AND column_name = 'workspace_id'
    ORDER BY table_name
    """)
  end

  @doc "E2: recursive FK descendants of `workspaces` without a `workspace_id` column (live)."
  def live_e2(repo) do
    query_col(repo, """
    WITH RECURSIVE fk(child) AS (
      SELECT cl.relname
      FROM pg_constraint c
      JOIN pg_class cl ON cl.oid = c.conrelid
      JOIN pg_class pl ON pl.oid = c.confrelid
      WHERE c.contype = 'f' AND pl.relname = 'workspaces'
      UNION
      SELECT cl.relname
      FROM pg_constraint c
      JOIN pg_class cl ON cl.oid = c.conrelid
      JOIN pg_class pl ON pl.oid = c.confrelid
      JOIN fk ON pl.relname = fk.child
      WHERE c.contype = 'f'
    )
    SELECT DISTINCT child FROM fk
    WHERE child NOT IN (
      SELECT table_name FROM information_schema.columns
      WHERE table_schema = 'public' AND column_name = 'workspace_id'
    )
    ORDER BY child
    """)
  end

  @doc "E3: `dataset`-column tables minus E1 (live)."
  def live_e3(repo) do
    query_col(repo, """
    SELECT table_name FROM information_schema.columns
    WHERE table_schema = 'public' AND column_name = 'dataset'
      AND table_name NOT IN (
        SELECT table_name FROM information_schema.columns
        WHERE table_schema = 'public' AND column_name = 'workspace_id'
      )
    ORDER BY table_name
    """)
  end

  @doc """
  Group-A (live): every table carrying the CANONICAL `dataset_id` column
  (migration 20260527131000's dual dataset-column family).

  A dataset-scoped export narrows these on `dataset_id` and NEVER on the
  `dataset` string mirror — the mirror is a denormalized convenience that can
  name a slug another project also owns, so keying on it would pull a
  sibling dataset's rows into a dataset-grained bundle (PDS-D7). Derived live
  for the same reason E1/E2/E3 are: a new dataset_id table inherits the
  narrowing instead of silently exporting workspace-whole.
  """
  def live_dataset_id_tables(repo) do
    query_col(repo, """
    SELECT table_name FROM information_schema.columns
    WHERE table_schema = 'public' AND column_name = 'dataset_id'
    ORDER BY table_name
    """)
  end

  @doc """
  The columns of `table` that FK-reference `documents.id` (live) — the seam the
  dev-profile document type-deny CASCADES through (PDS-D27).

  A denied document type (today `ticket`) is filtered out of the `documents`
  member, but every child keyed to it — `content_edges` (BOTH endpoints),
  `task_edges`, `plugin_doc_state` — is reached through a type-BLIND join, so
  without this cascade those rows travel as orphans that violate the FK on
  import. Live-derived so a new child table inherits the cascade automatically.

  The REFERENCED side is pinned to `documents.id`: the cascade predicate the
  caller emits is `dtd.id = t.<col>`, so a hypothetical FK pointing at some
  other `documents` key (or one leg of a composite FK) must NOT be returned —
  it would either compare mismatched types (a loud SQL error) or, worse, join
  the wrong row. What this returns is exactly what that predicate is valid for.
  """
  def document_fk_columns(repo, table) do
    query_col(repo, """
    SELECT a.attname
    FROM pg_constraint c
    JOIN pg_class cl ON cl.oid = c.conrelid
    JOIN pg_class pl ON pl.oid = c.confrelid
    JOIN unnest(c.conkey) WITH ORDINALITY k(attnum, ord) ON true
    JOIN unnest(c.confkey) WITH ORDINALITY r(attnum, ord) ON r.ord = k.ord
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
    JOIN pg_attribute ra ON ra.attrelid = c.confrelid AND ra.attnum = r.attnum
    WHERE c.contype = 'f' AND cl.relname = '#{sql_ident(table)}'
      AND pl.relname = 'documents' AND ra.attname = 'id'
    ORDER BY a.attname
    """)
  end

  @doc "Every base table in the public schema (live)."
  def live_base_tables(repo) do
    query_col(repo, """
    SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
    ORDER BY table_name
    """)
  end

  @doc """
  The non-generated columns of a table, in ordinal order (charter D3).

  Excludes `GENERATED ALWAYS` columns (today only `documents.search_vector`),
  which Postgres re-generates on import. A `COPY (SELECT *)` would emit the
  generated column and the re-import would fail "extra data after last expected
  column"; a column-list COPY lets Postgres regenerate it.
  """
  def non_generated_columns(repo, table) do
    query_col(repo, """
    SELECT column_name FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = '#{sql_ident(table)}'
      AND is_generated <> 'ALWAYS'
    ORDER BY ordinal_position
    """)
  end

  @doc """
  The deterministic ORDER BY column list for a table — its primary key columns
  (so a re-exported dump is byte-identical, which the md5 parity check needs).
  Falls back to every non-generated column when a table has no primary key.
  """
  def order_columns(repo, table) do
    case query_col(repo, """
         SELECT a.attname
         FROM pg_constraint c
         JOIN pg_class cl ON cl.oid = c.conrelid
         JOIN unnest(c.conkey) WITH ORDINALITY k(attnum, ord) ON true
         JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
         WHERE c.contype = 'p' AND cl.relname = '#{sql_ident(table)}'
         ORDER BY k.ord
         """) do
      [] -> non_generated_columns(repo, table)
      pks -> pks
    end
  end

  # ── The pinned partition sentinel (charter D10 acceptance-gate part a) ───────

  @doc """
  Assert the LIVE catalog matches the reviewed partition, RAISING on any drift.

  This is the "not grep" completeness proof: every base table is accounted for
  in EXACTLY ONE bucket (E1/E2/E3/allowlist/root/non-tenant), the live E1/E2/E3
  derivations equal the reviewed classification, and no base table falls
  through unaccounted. Inject a new `workspace_id` table and E1 drift + the
  unaccounted-table check both fire — the tripwire that forces a human to
  classify (and, for E2/E3, spec the extraction of) a new tenant table.
  """
  def assert_partition!(repo) do
    live_e1 = live_e1(repo)
    live_e2 = live_e2(repo)
    live_e3 = live_e3(repo)
    live_base = live_base_tables(repo)

    diff_or_raise!("E1", live_e1, Enum.sort(@pinned_e1))
    diff_or_raise!("E2", live_e2, Enum.sort(@pinned_e2))
    diff_or_raise!("E3", live_e3, Enum.sort(@e3_doc_keyed ++ @e3_dataset_keyed))

    # Every E2 table must have a reviewed join spec; every E3 table a keyed shape.
    for t <- live_e2, not Map.has_key?(@e2_joins, t) do
      raise "WorkspaceBundle.Catalog: E2 table #{inspect(t)} has no extraction join spec"
    end

    # PDS-D74: an E3-dataset table claimed as workspace-attributable must BE an
    # E3-dataset table and must really have that column live. Getting either
    # wrong would render a WHERE over a column that does not exist (a hard COPY
    # failure) or, worse, quietly exempt a table from the declared-loss sweep.
    for {t, col} <- @e3_dataset_workspace_slug_column do
      unless t in @e3_dataset_keyed do
        raise "WorkspaceBundle.Catalog: #{inspect(t)} claims a workspace slug column " <>
                "but is not an E3-dataset table"
      end

      unless col in non_generated_columns(repo, t) do
        raise "WorkspaceBundle.Catalog: #{inspect(t)} has no live #{inspect(col)} column — " <>
                "its workspace-attributed export/teardown predicate would be invalid SQL"
      end
    end

    partition =
      [@root_table] ++
        @pinned_e1 ++
        @pinned_e2 ++
        @e3_doc_keyed ++
        @e3_dataset_keyed ++
        Map.keys(@allowlist) ++
        @pinned_non_tenant

    dupes = partition -- Enum.uniq(partition)

    if dupes != [] do
      raise "WorkspaceBundle.Catalog: partition overlap #{inspect(Enum.uniq(dupes))}"
    end

    # THE SENTINEL: a live base table that no bucket claims is unreviewed drift.
    unaccounted = live_base -- partition

    if unaccounted != [] do
      raise "WorkspaceBundle.Catalog: #{length(unaccounted)} unaccounted base table(s) " <>
              "#{inspect(unaccounted)} — classify each as tenant (E1/E2/E3/allowlist) or " <>
              "non-tenant before it can silently drop from a workspace bundle"
    end

    phantom = partition -- live_base

    if phantom != [] do
      raise "WorkspaceBundle.Catalog: pinned table(s) #{inspect(phantom)} absent from the live schema"
    end

    assert_webhook_delivery_confinement!(repo)

    :ok
  end

  # The webhook_deliveries E2 spec is a SECURITY boundary, not just an
  # extraction shape (see the invariant comment at its `@e2_joins` entry).
  # Both breakage modes are validated here:
  #   * the join must stay INNER — a LEFT JOIN is the first half of the
  #     "orphan rows export everywhere" regression;
  #   * no secret-bearing `payload_snapshot` may be workspace-reachable through
  #     the endpoint join — backfilling `endpoint_id` onto media rows would put
  #     a plaintext signing secret into the next full-fidelity bundle.
  defp assert_webhook_delivery_confinement!(repo) do
    {join, pred} = Map.fetch!(@e2_joins, "webhook_deliveries")

    unless String.starts_with?(join, "JOIN ") and pred == "w.workspace_id" do
      raise "WorkspaceBundle.Catalog: webhook_deliveries must export via the reviewed " <>
              "INNER `JOIN webhooks` on endpoint_id — got #{inspect({join, pred})}. " <>
              "Relaxing this join is a credential-export hazard: media deliveries embed " <>
              "a plaintext signing secret in payload_snapshot and are kept out of every " <>
              "bundle ONLY by failing this join (nil endpoint_id)."
    end

    %{rows: [[reachable]]} =
      repo.query!("""
      SELECT COUNT(*) FROM webhook_deliveries t
      JOIN webhooks w ON w.id = t.endpoint_id
      WHERE t.payload_snapshot ? 'secret'
      """)

    if reachable > 0 do
      raise "WorkspaceBundle.Catalog: #{reachable} secret-bearing webhook_deliveries " <>
              "row(s) are workspace-reachable through the E2 endpoint join — a plaintext " <>
              "signing secret would export in that workspace's bundle. Media deliveries " <>
              "must keep endpoint_id NULL (config-driven endpoints); never backfill it."
    end

    :ok
  end

  defp diff_or_raise!(label, live, pinned) do
    if live != pinned do
      raise "WorkspaceBundle.Catalog: #{label} drift — live=#{inspect(live)} pinned=#{inspect(pinned)}"
    end
  end

  # ── Dev-profile partition (PDS charter D4/D5 — classification data only) ─────
  #
  # A SECOND partition, orthogonal to the pinned E1/E2/E3 buckets above: every
  # bundle-reachable table (root + E1 + E2 + E3 + allowlist) classified for the
  # `--profile dev` pull as
  #
  #   * `:copy`                     — travels verbatim in a dev bundle
  #   * `:deny`                     — never enters a dev bundle (secret /
  #                                   credential / fleet / size classes)
  #   * `{:scrub_fields, [field]}`  — travels with the named fields nulled at
  #                                   export (empty in W1; the shape exists so a
  #                                   future field-scrub needs no model change)
  #
  # `documents` alone carries an extra axis: `{:copy, deny_types: [type]}` —
  # rows whose `type` is listed never travel (PDS-D5: tickets are customer PII
  # conversations, full-denied per-type; the snapshot back door through
  # `revisions` / `mutation_events` is closed by their table-level deny).
  #
  # This section is CLASSIFICATION DATA + SENTINEL only — the exporter does not
  # read it yet (the dev export slice consumes it). The full-fidelity backup
  # partition above and `assert_partition!/1` are untouched by design: the
  # md5-parity suite in workspace_bundle_test.exs is the regression tripwire.
  #
  # Deny census (PDS-D4, verified live 2026-07-19):
  #   * credential/secret stores: api_tokens, secrets, secrets_audit, data_keys,
  #     access_grants, webhooks (live rows carry PLAINTEXT signing secrets),
  #     webhook_deliveries (payload + signature trail of a denied parent),
  #     audit_export_sinks (plaintext `secret` sink column), share_links,
  #     shares (access-granting registry — copying would silently re-open
  #     public surfaces on the target), registered_chat_hosts,
  #     preview_token_jti.
  #   * PII / conversation / audit trails: audit_events, paper_access_log
  #     (who read which paper and when, identified where the reader could
  #     identify them — the same trail shape as audit_events and denied for the
  #     same reason: a dev target must not inherit a production readership),
  #     workspace_memberships,
  #     chat_execution_leases, chat_execution_events, search_intel_events
  #     (raw user-typed `query` text + `actor_key`/`session_key` identity —
  #     per-user behavioral telemetry; the DERIVED aggregates
  #     search_intel_crystals / search_intel_merge_patterns carry only
  #     normalized-query counts with no actor identity and stay copy).
  #   * sync family: sync_* (all five), github_sync_conflicts (conflict
  #     payloads snapshot foreign state that cannot converge on a dev target).
  #   * cycle/epic fleet ledgers incl. FK children: cycle_*, epic_*,
  #     chat_runtime_usage_receipts (fleet usage telemetry).
  #   * SIZE denies: mutation_events (241MB live), revisions (192MB live) —
  #     keeps a dev bundle ~42MB instead of ~475MB and closes the
  #     ticket-snapshot cascade in the same stroke.
  #   * UNREVIEWED-PAYLOAD deny (RULED 2026-09-02): plugin_doc_state. Unlike
  #     every other copy table it is not a reviewed typed schema — it is a
  #     (plugin_name, doc_id, key) -> value:map scratch bag whose `value` is
  #     opaque to this catalog, and a repo-wide search found ZERO readers or
  #     writers in api/lib. Its old :copy safety rested on "nothing writes
  #     here", not on a reviewed column shape, and with @dev_scrub empty there
  #     is no field-level backstop: the first plugin to stash a token or a PII
  #     blob in `value` would travel through a dev export unguarded. THE
  #     COMPATIBILITY CONSEQUENCE, stated rather than hidden: a dev bundle
  #     carries no plugin scratch state at all, so a plugin that later depends
  #     on it must re-derive or re-seed it on the dev target. Re-classify to
  #     :copy only together with a declared safe-key contract over `value`
  #     (or a @dev_scrub entry) and a test that fails on an undeclared key.

  @dev_doc_type_deny ~w(ticket)

  @dev_copy ~w(
    authoring_exemptions content_edges datasets media_files paper_events
    projects role_permissions roles schema_definitions
    search_intel_crystals search_intel_merge_patterns
    search_surface_config search_synonyms task_edges workspaces
  )

  @dev_deny ~w(
    access_grants api_tokens audit_events audit_export_sinks
    chat_execution_events chat_execution_leases chat_runtime_usage_receipts
    cycle_build_plans cycle_correction_admissions
    cycle_correction_promotion_events cycle_correction_quarantines
    cycle_correction_roots cycle_correction_targets
    cycle_release_gate_admissions cycle_release_gate_captures
    cycle_release_gate_challenges cycle_release_gate_consumptions
    cycle_release_paper_candidates cycle_release_public_smokes cycle_waves
    data_keys epic_assignment_results epic_assignment_runtime_attempts
    epic_assignment_tasks epic_assignments epic_benchmark_attempts
    epic_benchmark_experiments github_sync_conflicts mutation_events
    paper_access_log plugin_doc_state preview_token_jti registered_chat_hosts
    revisions search_intel_events
    secrets secrets_audit
    share_links shares sync_cursors sync_dead_letters sync_push_conflicts
    sync_push_cursors sync_push_doc_revs webhook_deliveries webhooks
    workspace_memberships
  )

  # W1 ships an empty scrub set; the key shape is `table => [field]`.
  @dev_scrub %{}

  # Traveling tables with a REVIEWED composite primary key. Live census
  # (2026-07-19): 94/94 base tables carry a PK, but only 86/94 are
  # single-column — `plugin_doc_state` (3-col) and `authoring_exemptions`
  # (2-col) are the composites. Since the 2026-09-02 ruling denied
  # `plugin_doc_state` from the dev profile it no longer TRAVELS, so it comes
  # off this list too: the list is "traveling composites", and a denied table
  # left here would be padding the no-rot test asserts against. The
  # merge-import arbiter is the manifest's `order_columns` — the FULL pk
  # column list — so a composite arbiter is valid (`ON CONFLICT (a, b) DO
  # UPDATE`). What fails closed: a traveling table with NO pk, or a NEW
  # composite nobody reviewed.
  @dev_composite_pk_ok ~w(authoring_exemptions)

  # Compile-time tripwire: a table listed in two source lists would silently
  # last-write-win in the merged map — refuse to compile instead.
  dev_sources = @dev_copy ++ ["documents"] ++ @dev_deny ++ Map.keys(@dev_scrub)

  if dev_sources != Enum.uniq(dev_sources) do
    raise "WorkspaceBundle.Catalog: dev partition source lists overlap — " <>
            inspect(dev_sources -- Enum.uniq(dev_sources))
  end

  @dev_partition Map.new(@dev_copy, &{&1, :copy})
                 |> Map.merge(Map.new(@dev_deny, &{&1, :deny}))
                 |> Map.merge(
                   Map.new(@dev_scrub, fn {table, fields} -> {table, {:scrub_fields, fields}} end)
                 )
                 |> Map.put("documents", {:copy, deny_types: @dev_doc_type_deny})

  @doc "The dev-profile classification map: table => :copy | :deny | {:scrub_fields, fields} (PDS-D4)."
  def dev_partition, do: @dev_partition

  @doc "Document `type`s that never travel in a dev-profile bundle (PDS-D5)."
  def dev_doc_type_deny do
    {:copy, deny_types: types} = Map.fetch!(@dev_partition, "documents")
    types
  end

  @doc """
  The normalized dev-profile action for a table: `:copy`, `:deny`, or
  `{:scrub_fields, fields}`. FAIL-CLOSED: an unclassified table is `:deny` —
  the export path can never copy a table the partition has not reviewed
  (the sentinel additionally RAISES on any unclassified reachable table, so
  this branch is defense-in-depth, not the primary guard).
  """
  def dev_action(table) do
    case Map.fetch(@dev_partition, table) do
      {:ok, :copy} -> :copy
      {:ok, {:copy, _axis}} -> :copy
      {:ok, {:scrub_fields, fields}} -> {:scrub_fields, fields}
      _deny_or_unclassified -> :deny
    end
  end

  @doc "Tables that travel in a dev-profile bundle (`:copy` + `{:scrub_fields, _}`), sorted."
  def dev_copy_tables do
    for({table, classification} <- @dev_partition, classification != :deny, do: table)
    |> Enum.sort()
  end

  @doc "Tables a dev-profile bundle never carries, sorted."
  def dev_deny_tables do
    for({table, :deny} <- @dev_partition, do: table) |> Enum.sort()
  end

  @doc "Traveling tables whose composite primary key is reviewed as a valid merge arbiter."
  def dev_composite_pk_ok, do: @dev_composite_pk_ok

  # ── The dev-profile sentinel (PDS-D4: deny-by-default, fail-closed) ──────────

  @doc """
  Assert the dev-profile partition covers the LIVE bundle-reachable catalog,
  RAISING on any gap — the fail-closed mirror of `assert_partition!/1`.

  Four checks, all fail-closed:

    1. every classification value is well-formed (`:copy` / `:deny` /
       `{:scrub_fields, [field]}` / documents' `{:copy, deny_types: [type]}`);
    2. every bundle-reachable table (root + live E1/E2/E3 + allowlist) is
       classified — an UNCLASSIFIED new table RAISES, so nothing ever travels
       (or is silently dropped) unreviewed;
    3. no phantom entries — a classified table that is no longer reachable
       RAISES, keeping the map honest;
    4. every traveling table (copy + scrub) has a primary key the merge-import
       `ON CONFLICT (pk) DO UPDATE` arbiter (PDS-D8) can use — single-column,
       unless the composite is on the reviewed `dev_composite_pk_ok/0` list
       (live census: 94/94 base tables carry a PK; 86/94 single-column).

  The second argument exists for protective tests (injecting a classification
  the real map would never carry); production callers use the default.
  """
  def assert_dev_partition!(repo, partition \\ @dev_partition) do
    malformed = for {table, c} <- partition, not valid_dev_classification?(c), do: table

    if malformed != [] do
      raise "WorkspaceBundle.Catalog: dev partition entry for #{inspect(Enum.sort(malformed))} " <>
              "is malformed — a classification is :copy | :deny | {:scrub_fields, [field]} " <>
              "(documents alone may carry {:copy, deny_types: [type]})"
    end

    reachable =
      ([@root_table] ++
         live_e1(repo) ++ live_e2(repo) ++ live_e3(repo) ++ Map.keys(@allowlist))
      |> Enum.uniq()
      |> Enum.sort()

    classified = partition |> Map.keys() |> Enum.sort()

    unclassified = reachable -- classified

    if unclassified != [] do
      raise "WorkspaceBundle.Catalog: #{length(unclassified)} unclassified bundle-reachable " <>
              "table(s) #{inspect(unclassified)} — the dev profile is deny-by-default and " <>
              "FAILS CLOSED: classify each as copy | deny | scrub_fields before a dev " <>
              "export can run"
    end

    phantom = classified -- reachable

    if phantom != [] do
      raise "WorkspaceBundle.Catalog: dev-classified table(s) #{inspect(phantom)} are not " <>
              "bundle-reachable — remove the stale entry or fix the reachability drift"
    end

    traveling = for {table, c} <- partition, c != :deny, do: table
    bad_pk = pk_arbiter_violations(repo, traveling)

    if bad_pk != [] do
      raise "WorkspaceBundle.Catalog: copy-classified table(s) #{inspect(Enum.sort(bad_pk))} " <>
              "lack a single-column primary key and are not on the reviewed composite-PK " <>
              "list — the merge-import ON CONFLICT (pk) DO UPDATE arbiter (PDS-D8) needs " <>
              "a reviewed pk"
    end

    :ok
  end

  defp valid_dev_classification?(:copy), do: true
  defp valid_dev_classification?(:deny), do: true

  defp valid_dev_classification?({:copy, deny_types: types}) when is_list(types),
    do: types != [] and Enum.all?(types, &is_binary/1)

  defp valid_dev_classification?({:scrub_fields, fields}) when is_list(fields),
    do: fields != [] and Enum.all?(fields, &is_binary/1)

  defp valid_dev_classification?(_), do: false

  defp pk_arbiter_violations(repo, tables) do
    Enum.filter(tables, fn table ->
      case query_col(repo, """
           SELECT array_length(c.conkey, 1)
           FROM pg_constraint c
           JOIN pg_class cl ON cl.oid = c.conrelid
           WHERE c.contype = 'p' AND cl.relname = '#{sql_ident(table)}'
           """) do
        [1] -> false
        [n] when is_integer(n) and n > 1 -> table not in @dev_composite_pk_ok
        # No primary key at all: never a valid merge arbiter.
        _none -> true
      end
    end)
  end

  # ── SQL literal helpers (COPY subqueries take no bind params) ────────────────

  @doc """
  A validated `workspace_id` as a Postgres UUID literal, or raise. COPY
  subqueries cannot carry bind params, so the id is inlined — validated as a
  UUID first so nothing else can ever reach the SQL string.
  """
  def uuid_literal!(workspace_id) do
    case Ecto.UUID.cast(workspace_id) do
      {:ok, uuid} -> "'#{uuid}'::uuid"
      :error -> raise ArgumentError, "workspace_id is not a UUID: #{inspect(workspace_id)}"
    end
  end

  @doc "A Postgres `text[]` array literal from a list of strings (single-quote-escaped)."
  def text_array_literal(list) do
    inner = list |> Enum.map(&"'#{escape_sql_string(&1)}'") |> Enum.join(",")
    "ARRAY[#{inner}]::text[]"
  end

  @doc "A single-quoted, escaped Postgres text literal."
  def text_literal(value), do: "'#{escape_sql_string(value)}'"

  # SAFETY ASSUMPTION: single-quote doubling is a COMPLETE escape ONLY when
  # `standard_conforming_strings = on` (the Postgres default since 9.1, and never
  # flipped in Barkpark). With it off, a backslash would begin a C-style escape
  # sequence and `''` would no longer be the sole quote path — the doubling below
  # would be defeated. This is the last line of defense for the COPY-FROM-STDIN
  # import path, which bypasses the Ecto changeset guards entirely (unlike the
  # POST /v1/data/mutate write path, where Dataset.changeset now validates slug
  # format). Do not weaken this to a bare interpolation, and do not disable
  # standard_conforming_strings.
  defp escape_sql_string(value) when is_binary(value), do: String.replace(value, "'", "''")

  # A bare SQL identifier from a catalog-derived table/column name. Every name
  # this module inlines comes from information_schema / pg_constraint (never user
  # input); this strips anything but the safe identifier charset as belt-and-suspenders.
  defp sql_ident(name), do: String.replace(name, ~r/[^a-zA-Z0-9_]/, "")

  defp query_col(repo, sql) do
    repo.query!(sql, []).rows |> List.flatten()
  end
end
