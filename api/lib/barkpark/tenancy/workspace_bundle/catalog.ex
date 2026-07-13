defmodule Barkpark.Tenancy.WorkspaceBundle.Catalog do
  @moduledoc """
  The tenant-table catalog for the workspace bundle: the THREE live-derived
  enumerations (E1/E2/E3), the reviewed extraction specs, the non-generated
  column derivation, and the pinned partition sentinel.

  ## Why live-derived, never hardcoded (charter D4)

  Which tables belong to a workspace is derived from the LIVE catalog on every
  export, so a new tenant table is picked up automatically instead of being
  silently dropped:

    * **E1** — every table carrying a `workspace_id` column (19 today; the two
      zero-FK audit tables `audit_events` / `audit_export_sinks` carry the
      column with no FK to `workspaces`, and `roles` is the 19th).
    * **E2** — the recursive `pg_constraint` FK descendants of `workspaces`
      that do NOT themselves carry `workspace_id` (6: `content_edges`,
      `datasets`, `plugin_doc_state`, `role_permissions`, `task_edges`,
      `webhook_deliveries`). Reached via a real FK, extracted through a
      parent-join to the nearest `workspace_id`-bearing ancestor.
    * **E3** — the `dataset`-column tables minus E1 (9), keyed by a `dataset`
      slug (and, for four of them, a `doc_id`). PLUS an explicit two-table
      allowlist (`data_keys`, `search_surface_config`) whose tenant key is a
      `scope` column, not `dataset` — the mechanical `dataset` scan cannot see
      them, and dropping `data_keys` would render every exported ciphertext
      permanently undecryptable (it holds the per-dataset DEKs).

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

  @pinned_e1 ~w(
    access_grants api_tokens audit_events audit_export_sinks documents
    media_files mutation_events paper_events projects revisions roles
    schema_definitions search_intel_crystals search_intel_events
    search_intel_merge_patterns search_synonyms share_links webhooks
    workspace_memberships
  )

  @pinned_e2 ~w(content_edges datasets plugin_doc_state role_permissions task_edges webhook_deliveries)

  # E3 tables that carry a `doc_id` → filtered by a (doc_id, dataset) semi-join.
  @e3_doc_keyed ~w(authoring_exemptions github_sync_conflicts sync_push_conflicts sync_push_doc_revs)

  # E3 tables with no `doc_id` → filtered by dataset-slug membership.
  @e3_dataset_keyed ~w(preview_token_jti shares sync_cursors sync_dead_letters sync_push_cursors)

  # The `scope`-column allowlist (charter D4/D5). Cannot be dataset-scanned.
  #   data_keys.scope             = "dataset:" <> slug   (per-dataset DEKs)
  #   search_surface_config.scope = slug
  @allowlist %{
    "data_keys" => "dataset:",
    "search_surface_config" => ""
  }

  # Every base table that rolls ABOVE or OUTSIDE the workspace grain (charter
  # D5): global codelists, admin/host state, the org tier, job queue, metrics,
  # user/auth tier, and the residual *_backup tables. A base table that is
  # neither live-tenant nor in this list makes the sentinel RAISE.
  @pinned_non_tenant ~w(
    chat_messages chat_sessions codelist_value_translations codelist_values
    codelists collapsed_schema_definitions_backup idempotency_keys login_tickets
    oban_jobs oban_peers oidc_connections org_domains organizations
    paper_events_dataset_rescope_backup plugin_settings plugin_settings_audit
    pulse_counters pulse_events pulse_meters saml_connections schema_migrations
    scim_groups scim_tokens secrets secrets_audit social_identities
    social_providers status_incidents user_email_tokens user_sessions users
    webauthn_credentials
  )

  # E2 extraction specs: a parent-join from the child (`t`) to the nearest
  # ancestor that carries `workspace_id`. FK is many-to-one so a plain JOIN
  # never fans out (unlike E3).
  @e2_joins %{
    "datasets" => {"JOIN projects p ON p.id = t.project_id", "p.workspace_id"},
    "role_permissions" => {"JOIN roles r ON r.id = t.role_id", "r.workspace_id"},
    "webhook_deliveries" => {"JOIN webhooks w ON w.id = t.endpoint_id", "w.workspace_id"},
    "content_edges" => {"JOIN documents d ON d.id = t.from_id", "d.workspace_id"},
    "task_edges" => {"JOIN documents d ON d.id = t.from_id", "d.workspace_id"},
    "plugin_doc_state" => {"JOIN documents d ON d.id = t.doc_id", "d.workspace_id"}
  }

  def root_table, do: @root_table
  def e2_joins, do: @e2_joins
  def e3_doc_keyed, do: @e3_doc_keyed
  def e3_dataset_keyed, do: @e3_dataset_keyed
  def allowlist, do: @allowlist

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

    :ok
  end

  defp diff_or_raise!(label, live, pinned) do
    if live != pinned do
      raise "WorkspaceBundle.Catalog: #{label} drift — live=#{inspect(live)} pinned=#{inspect(pinned)}"
    end
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

  defp escape_sql_string(value) when is_binary(value), do: String.replace(value, "'", "''")

  # A bare SQL identifier from a catalog-derived table/column name. Every name
  # this module inlines comes from information_schema / pg_constraint (never user
  # input); this strips anything but the safe identifier charset as belt-and-suspenders.
  defp sql_ident(name), do: String.replace(name, ~r/[^a-zA-Z0-9_]/, "")

  defp query_col(repo, sql) do
    repo.query!(sql, []).rows |> List.flatten()
  end
end
