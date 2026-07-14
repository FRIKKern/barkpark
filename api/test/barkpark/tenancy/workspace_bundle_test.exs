defmodule Barkpark.Tenancy.WorkspaceBundleTest do
  @moduledoc """
  The completeness-diff acceptance gate for the per-workspace bundle (charter
  D10). Every proof is MECHANICAL — an information_schema + pg_constraint
  partition diff, per-table count-parity, and md5(non-generated-cols) parity on
  a real seeded round-trip — never a grep. Row counts are re-measured live, never
  hardcoded.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Repo
  alias Barkpark.Tenancy.WorkspaceBundle
  alias Barkpark.Tenancy.WorkspaceBundle.{Archive, Catalog}

  # ── criterion 1: three enumerations derive LIVE from the catalog ─────────────

  describe "Catalog live enumerations (charter D4)" do
    test "E1 = the 20 workspace_id tables incl roles + search_surface_config + the two zero-FK audit tables" do
      e1 = Catalog.live_e1(Repo)
      assert length(e1) == 20
      assert "roles" in e1
      # search_surface_config gained a workspace_id column in Wave 5 Slice A
      # (charter D45/D49) to close a LIVE cross-tenant config bleed — it is the
      # 20th E1 table, re-pinned out of the scope-column allowlist.
      assert "search_surface_config" in e1
      # audit_events / audit_export_sinks carry workspace_id with ZERO FK to workspaces
      assert "audit_events" in e1
      assert "audit_export_sinks" in e1
      refute "audit_events" in Catalog.live_e2(Repo)
    end

    test "E2 = the 6 FK-transitive children without a workspace_id column" do
      assert Catalog.live_e2(Repo) ==
               ~w(content_edges datasets plugin_doc_state role_permissions task_edges webhook_deliveries)
    end

    test "E3 = the 9 dataset-column tables; data_keys is the scope allowlist; search_surface_config is now E1" do
      e3 = Catalog.live_e3(Repo)
      assert length(e3) == 9
      assert "authoring_exemptions" in e3
      # data_keys is invisible to the dataset scan and MUST be carried by the
      # explicit allowlist (dropping it = undecryptable ciphertext).
      refute "data_keys" in e3
      assert Map.has_key?(Catalog.allowlist(), "data_keys")
      # search_surface_config has neither a `dataset` column (never in E3) nor the
      # allowlist any more — Wave 5 Slice A moved it to E1 via a real workspace_id
      # column (charter D45/D49).
      refute "search_surface_config" in e3
      refute Map.has_key?(Catalog.allowlist(), "search_surface_config")
      assert "search_surface_config" in Catalog.live_e1(Repo)
    end
  end

  # ── criterion 4a: partition sentinel RAISES on an injected tenant table ───────

  describe "partition sentinel (charter D10a)" do
    test "clean schema partitions exactly; an injected tenant table flips N->N+1 and RAISES" do
      assert :ok = Catalog.assert_partition!(Repo)

      before_n = length(Catalog.live_base_tables(Repo))

      Repo.query!("CREATE TABLE zzz_injected_tenant (id uuid PRIMARY KEY, workspace_id uuid)", [])

      after_n = length(Catalog.live_base_tables(Repo))
      assert after_n == before_n + 1
      assert "zzz_injected_tenant" in Catalog.live_e1(Repo)

      assert_raise RuntimeError, ~r/drift|unaccounted/, fn ->
        Catalog.assert_partition!(Repo)
      end

      # Clean up so we never leak an injected table into the shared test DB
      # (a prior verify run left `verify_probe_rows` behind — do not repeat it).
      Repo.query!("DROP TABLE zzz_injected_tenant", [])
      assert :ok = Catalog.assert_partition!(Repo)
    end
  end

  # ── criterion 2: fail-closed scope + leak-negative + raw byte carrier ─────────

  describe "export guards (charter D8/D9)" do
    test "fail-CLOSED: a nil / non-UUID workspace_id never triggers an all-tenant read" do
      assert {:error, :workspace_id_required} = WorkspaceBundle.export(nil)
      assert {:error, :workspace_id_required} = WorkspaceBundle.export("not-a-uuid")
      assert {:error, :workspace_id_required} = WorkspaceBundle.export(123)
    end

    test "unknown workspace → :workspace_not_found" do
      assert {:error, :workspace_not_found} = WorkspaceBundle.export(Ecto.UUID.generate())
    end

    test "leak-negative: workspace B's rows never appear in workspace A's bundle" do
      %{ws_a: ws_a, ws_b: ws_b} = seed_two_workspaces!()

      {:ok, bundle} = WorkspaceBundle.export(ws_a.id)
      {manifest, dumps} = Archive.unpack(bundle)

      assert manifest["workspace_id"] == ws_a.id
      docs = dumps["documents"]

      # A's own rows are present…
      assert docs =~ ws_a.id
      assert docs =~ "only-a"
      # …and B's rows are categorically absent.
      refute docs =~ ws_b.id
      refute docs =~ "only-b"

      # authoring_exemptions: A's semi-join carries (shared-1) + (only-a) but
      # NEVER B's (only-b, prod-b).
      assert dumps["authoring_exemptions"] =~ "only-a"
      refute dumps["authoring_exemptions"] =~ "only-b"
    end

    test "documents member is RAW rows, not Envelope.render output (charter D9)" do
      %{ws_a: ws_a} = seed_two_workspaces!()
      {:ok, bundle} = WorkspaceBundle.export(ws_a.id)
      {manifest, dumps} = Archive.unpack(bundle)

      # Raw carrier keeps the tenancy column + the persisted status; render would
      # drop workspace_id/status and synthesize _draft/_publishedId instead.
      assert dumps["documents"] =~ ws_a.id
      doc_member = Enum.find(manifest["tables"], &(&1["name"] == "documents"))
      assert "workspace_id" in doc_member["columns"]
      assert "status" in doc_member["columns"]
      # search_vector is GENERATED ALWAYS → excluded from the column list (D3).
      refute "search_vector" in doc_member["columns"]
    end
  end

  # ── E3-dataset / allowlist bare-slug collision (bpb-e3-dataset-slug-collision) ──

  describe "export project-qualifies the E3-dataset/allowlist bare-slug copy" do
    test "a slug SHARED with a sibling workspace does NOT leak its bare-keyed rows into the bundle; an exclusive slug does" do
      ws_a = create_workspace!(unique("wsa"))
      proj_a = create_project!(ws_a, unique("proja"))
      ws_b = create_workspace!(unique("wsb"))
      proj_b = create_project!(ws_b, unique("projb"))

      # A owns an EXCLUSIVE slug + a slug that COLLIDES with B (unique only per
      # project_id — charter D21). The E3-dataset/allowlist tables carry the bare
      # slug/scope with no project column, so a bare `dataset = ANY(slugs)` copy
      # of A would pull B's shared-slug rows into A's single-workspace bundle.
      tag = System.unique_integer([:positive])
      shared = "shared-prod-#{tag}"
      excl = "excl-a-#{tag}"

      seed_dataset!(proj_a.id, excl)
      seed_dataset!(proj_a.id, shared)
      seed_dataset!(proj_b.id, shared)

      # A's own exclusive-slug row — MUST be carried in A's bundle.
      insert_sync_cursor!("EXCL-A-CURSOR-#{tag}", excl)

      # B's rows under the SHARED slug, uniquely marked — MUST NOT leak into A.
      # (search_surface_config is no longer bare-slug-keyed — it moved to E1 in
      # Wave 5 Slice A, so its cross-tenant isolation is proven by the dedicated
      # "search_surface_config per-workspace E1 attribution" describe below.)
      insert_sync_cursor!("B-ONLY-CURSOR-#{tag}", shared)
      insert_data_key!("dataset:#{shared}", "B-ONLY-CIPHERTEXT-#{tag}")

      {:ok, bundle} = WorkspaceBundle.export(ws_a.id)
      {manifest, dumps} = Archive.unpack(bundle)

      # No over-narrow: A's exclusive-slug row IS carried.
      assert "excl-a-#{tag}" in manifest["dataset_slugs"]
      assert dumps["sync_cursors"] =~ "EXCL-A-CURSOR-#{tag}"

      # No cross-tenant leak: the shared slug is excluded, so B's bare-keyed rows
      # are categorically absent from A's bundle. On origin/main the bare copy
      # pulls them in (and lists the shared slug) → these refutes FAIL → RED.
      refute "shared-prod-#{tag}" in manifest["dataset_slugs"]
      refute dumps["sync_cursors"] =~ "B-ONLY-CURSOR-#{tag}"
      refute dumps["data_keys"] =~ "B-ONLY-CIPHERTEXT-#{tag}"
    end
  end

  # ── search_surface_config per-workspace E1 attribution (Wave 5 Slice A) ───────

  describe "search_surface_config is exported per-workspace (charter D45/D49)" do
    test "A's workspace-keyed surface config IS carried; B's row on the SAME scope is NOT" do
      ws_a = create_workspace!(unique("wsa"))
      proj_a = create_project!(ws_a, unique("proja"))
      ws_b = create_workspace!(unique("wsb"))
      _proj_b = create_project!(ws_b, unique("projb"))

      # Both workspaces own a config on the universally-shared "production" scope
      # — the exact bleed shape. They are now DISTINCT physical rows keyed by
      # workspace_id, so A's bundle carries A's row and never B's.
      seed_dataset!(proj_a.id, "production")
      insert_surface_config_ws!(ws_a.id, "documents", "production", "A-ONLY-FIELD")
      insert_surface_config_ws!(ws_b.id, "documents", "production", "B-ONLY-FIELD")

      {:ok, bundle} = WorkspaceBundle.export(ws_a.id)
      {manifest, dumps} = Archive.unpack(bundle)

      member = Enum.find(manifest["tables"], &(&1["name"] == "search_surface_config"))
      assert member["partition"] == "E1"

      assert dumps["search_surface_config"] =~ "A-ONLY-FIELD"
      refute dumps["search_surface_config"] =~ "B-ONLY-FIELD"
    end
  end

  # ── criterion 4b/4c: count-parity + md5 parity across EVERY table ─────────────

  describe "completeness diff — count + md5 parity (charter D10b/D10c)" do
    test "every manifest table's row_count matches an independent scoped count, live" do
      %{ws_a: ws_a} = seed_two_workspaces!()
      {:ok, bundle} = WorkspaceBundle.export(ws_a.id)
      {manifest, _dumps} = Archive.unpack(bundle)

      dataset_slugs = manifest["dataset_slugs"]

      for member <- manifest["tables"] do
        independent = independent_count(member, ws_a.id, dataset_slugs)

        assert member["row_count"] == independent,
               "count-parity FAILED for #{member["name"]} (#{member["partition"]}): " <>
                 "bundle=#{member["row_count"]} independent=#{independent}"
      end
    end

    test "md5(non-generated-cols) is stable across a re-export (deterministic byte carrier)" do
      %{ws_a: ws_a} = seed_two_workspaces!()
      {:ok, b1} = WorkspaceBundle.export(ws_a.id)
      {:ok, b2} = WorkspaceBundle.export(ws_a.id)
      {m1, _} = Archive.unpack(b1)
      {m2, _} = Archive.unpack(b2)

      md5s = fn m -> Map.new(m["tables"], &{&1["name"], &1["md5"]}) end
      assert md5s.(m1) == md5s.(m2)
    end
  end

  # ── criterion 5 + D6: E3 semi-join never fans out ─────────────────────────────

  describe "E3 (doc_id, dataset) semi-join never fans out (charter D6)" do
    test "a plain JOIN over-counts authoring_exemptions; the bundle uses the DISTINCT truth" do
      %{ws_a: ws_a} = seed_two_workspaces!()

      # A holds two docs sharing (doc_id='shared-1', dataset='prod-a') — the
      # exact fan-out shape (documents unique key is doc_id,type,dataset_id).
      naive_join =
        scalar(
          """
          SELECT count(*) FROM authoring_exemptions ae
          JOIN documents d ON d.doc_id = ae.doc_id AND d.dataset = ae.dataset
          WHERE d.workspace_id = $1::text::uuid
          """,
          [ws_a.id]
        )

      semi_join =
        scalar(
          """
          SELECT count(*) FROM authoring_exemptions ae
          WHERE EXISTS (
            SELECT 1 FROM documents d
            WHERE d.workspace_id = $1::text::uuid AND d.doc_id = ae.doc_id AND d.dataset = ae.dataset
          )
          """,
          [ws_a.id]
        )

      assert naive_join > semi_join, "expected the plain JOIN to fan out"

      {:ok, bundle} = WorkspaceBundle.export(ws_a.id)
      {manifest, _} = Archive.unpack(bundle)
      member = Enum.find(manifest["tables"], &(&1["name"] == "authoring_exemptions"))

      # The bundle carries the DISTINCT semi-join count (re-measured live), never
      # the fanned-out JOIN count.
      assert member["row_count"] == semi_join
    end
  end

  # ── criterion 3 + 5: seeded round-trip — clean reimport, byte-identical, 0 orphans

  describe "round-trip: export → clean reimport → completeness diff (charter D2/D7)" do
    test "byte-identical round-trip with 0 FK orphans and idempotent E3 upsert" do
      %{ws_a: ws_a, ws_b: ws_b, proj_a: proj_a, shared_doc: shared_doc, only_a_doc: only_a_doc} =
        seed_two_workspaces!()

      # `prod-a` is SHARED: B created a `prod-a` document, which get_or_creates a
      # (proj_b, "prod-a") dataset, so both workspaces own the slug. A slug is
      # unique only per (project_id, slug), and the E3-dataset/allowlist tables
      # carry the bare slug/scope with no project column — so a `prod-a` DEK is
      # genuinely shared/global and MUST be excluded from A's single-workspace
      # bundle (charter D21; `dataset_slugs_for/1` is project-qualified). Give A
      # its OWN exclusive slug — the realistic keystone case where the D4
      # DEK-decryptability guarantee holds — and prove THAT DEK round-trips.
      seed_dataset!(proj_a.id, "solo-a")
      insert_data_key!("dataset:solo-a", "solo-a-dek-ciphertext")

      {:ok, bundle} = WorkspaceBundle.export(ws_a.id)
      {manifest_before, _} = Archive.unpack(bundle)

      # D21: the SHARED slug is project-qualified OUT of A's bundle; its DEK is
      # not A's to carry. The EXCLUSIVE slug IS carried.
      refute "prod-a" in manifest_before["dataset_slugs"]
      assert "solo-a" in manifest_before["dataset_slugs"]

      # The shared authoring_exemptions row belongs to BOTH A and B (each has a
      # matching document) — it survives the purge.
      assert scalar(
               "SELECT count(*) FROM authoring_exemptions WHERE doc_id=$1 AND dataset='prod-a'",
               [shared_doc]
             ) == 1

      # Simulate a CLEAN target: purge A's copy-strategy rows entirely, plus a
      # couple of A-exclusive string-keyed rows (proving they are RESTORED, not
      # silently lost — data_keys is the worst case: its DEKs). The DEK proof
      # uses the EXCLUSIVE slug `solo-a`, which A's bundle actually carries.
      purge_workspace!(ws_a.id, manifest_before)

      Repo.query!("DELETE FROM authoring_exemptions WHERE doc_id=$1 AND dataset='prod-a'", [
        only_a_doc
      ])

      Repo.query!("DELETE FROM data_keys WHERE scope='dataset:solo-a'", [])

      # A is gone; B untouched.
      assert scalar("SELECT count(*) FROM documents WHERE workspace_id=$1::text::uuid", [ws_a.id]) ==
               0

      assert scalar("SELECT count(*) FROM documents WHERE workspace_id=$1::text::uuid", [ws_b.id]) >
               0

      assert scalar("SELECT count(*) FROM data_keys WHERE scope='dataset:solo-a'", []) == 0

      # Re-import.
      {:ok, stats} = WorkspaceBundle.import_bundle(bundle)
      assert stats.total_rows > 0

      # 0 FK orphans post-replica-load (stronger than VALIDATE CONSTRAINT, which
      # no-ops on already-valid FKs): every restored child still resolves its parent.
      assert_no_orphans!()

      # generated search_vector was re-generated on import (D3): non-null for A's docs.
      assert scalar(
               "SELECT count(*) FROM documents WHERE workspace_id=$1::text::uuid AND search_vector IS NULL",
               [ws_a.id]
             ) == 0

      # The A-exclusive rows were restored…
      assert scalar("SELECT count(*) FROM data_keys WHERE scope='dataset:solo-a'", []) == 1

      assert scalar(
               "SELECT count(*) FROM authoring_exemptions WHERE doc_id=$1 AND dataset='prod-a'",
               [only_a_doc]
             ) == 1

      # …and the shared row is still a single row (ON CONFLICT DO NOTHING no-op,
      # not a crash and not a duplicate) — the authoring_exemptions byte-identical
      # silent-loss proof.
      assert scalar(
               "SELECT count(*) FROM authoring_exemptions WHERE doc_id=$1 AND dataset='prod-a'",
               [shared_doc]
             ) == 1

      # Completeness diff: re-export A and assert per-table row_count + md5 parity
      # against the pre-purge bundle → byte-identical round-trip, ZERO silent loss.
      {:ok, bundle2} = WorkspaceBundle.export(ws_a.id)
      {manifest_after, _} = Archive.unpack(bundle2)

      before = table_index(manifest_before)
      later = table_index(manifest_after)

      assert Map.keys(before) == Map.keys(later)

      for {name, m0} <- before do
        m1 = later[name]

        assert m0["row_count"] == m1["row_count"],
               "row_count drift after round-trip for #{name}: #{m0["row_count"]} -> #{m1["row_count"]}"

        assert m0["md5"] == m1["md5"],
               "md5(non-gen-cols) drift after round-trip for #{name} (silent loss!): " <>
                 "#{m0["md5"]} -> #{m1["md5"]}"
      end
    end
  end

  # ── seed + helpers ────────────────────────────────────────────────────────────

  # Workspace A: full spread across every extraction path. Workspace B: the leak
  # foil + the shared authoring_exemptions row. Row counts are never asserted as
  # magic numbers — the gate re-measures them live.
  defp seed_two_workspaces! do
    ws_a = create_workspace!(unique("wsa"))
    proj_a = create_project!(ws_a, unique("proja"))
    ws_b = create_workspace!(unique("wsb"))
    proj_b = create_project!(ws_b, unique("projb"))

    seed_dataset!(proj_a.id, "prod-a")
    seed_dataset!(proj_b.id, "prod-b")

    # A: two docs sharing (doc_id, dataset) but different type → fan-out shape.
    {:ok, a1} =
      create_document_in!(
        ws_a,
        proj_a,
        "post",
        %{"doc_id" => "shared-1", "title" => "A post"},
        "prod-a"
      )

    {:ok, _a2} =
      create_document_in!(
        ws_a,
        proj_a,
        "note",
        %{"doc_id" => "shared-1", "title" => "A note"},
        "prod-a"
      )

    {:ok, a3} =
      create_document_in!(
        ws_a,
        proj_a,
        "post",
        %{"doc_id" => "only-a", "title" => "only A"},
        "prod-a"
      )

    {:ok, _} = create_media_file_in!(ws_a, proj_a, %{}, "prod-a")

    # B: shares the (doc_id, dataset='prod-a') tuple of A's shared doc → the
    # shared authoring_exemptions row belongs to B too. Plus a B-only doc.
    # (create_document stamps a `drafts.` prefix, so `a1.doc_id` is the real
    # stored key the (doc_id, dataset) semi-join must match.)
    {:ok, _b1} =
      create_document_in!(
        ws_b,
        proj_b,
        "post",
        %{"doc_id" => "shared-1", "title" => "B post"},
        "prod-a"
      )

    {:ok, b2} =
      create_document_in!(
        ws_b,
        proj_b,
        "post",
        %{"doc_id" => "only-b", "title" => "only B"},
        "prod-b"
      )

    # E2 doc-anchored: a content edge between two of A's documents.
    Repo.query!(
      "INSERT INTO content_edges (id, from_id, to_id, kind, inserted_at, updated_at) " <>
        "VALUES (gen_random_uuid(), $1::text::uuid, $2::text::uuid, 'ref', now(), now())",
      [a1.id, a3.id]
    )

    # E3 doc-keyed: shared (belongs to A and B) + A-exclusive + B-exclusive.
    seed_exemption!(a1.doc_id, "prod-a", "post")
    seed_exemption!(a3.doc_id, "prod-a", "post")
    seed_exemption!(b2.doc_id, "prod-b", "post")

    # E3 dataset-keyed: A's sync cursor.
    Repo.query!(
      "INSERT INTO sync_cursors (source, dataset, inserted_at, updated_at) VALUES ('sync-a', 'prod-a', now(), now())",
      []
    )

    # allowlist: A's per-dataset DEK (scope-keyed, invisible to the dataset scan).
    Repo.query!(
      "INSERT INTO data_keys (id, scope, wrapped_key, inserted_at, updated_at) " <>
        "VALUES (gen_random_uuid(), 'dataset:prod-a', 'ciphertext-xyz', now(), now())",
      []
    )

    # E1: A's search surface config — now workspace_id-keyed (Wave 5 Slice A,
    # charter D45/D49). A NULL workspace_id here would be invisible to A's E1
    # bundle (WHERE workspace_id = $ws), so it MUST carry ws_a.id.
    Repo.query!(
      "INSERT INTO search_surface_config (id, workspace_id, surface, scope, inserted_at, updated_at) " <>
        "VALUES (gen_random_uuid(), $1::text::uuid, 'documents', 'prod-a', now(), now())",
      [ws_a.id]
    )

    %{
      ws_a: ws_a,
      ws_b: ws_b,
      proj_a: proj_a,
      proj_b: proj_b,
      shared_doc: a1.doc_id,
      only_a_doc: a3.doc_id
    }
  end

  defp seed_dataset!(project_id, slug) do
    Repo.query!(
      "INSERT INTO datasets (id, project_id, slug, name, inserted_at, updated_at) " <>
        "VALUES (gen_random_uuid(), $1::text::uuid, $2, $2, now(), now())",
      [project_id, slug]
    )
  end

  # E3-dataset / allowlist bare-slug raw seed helpers (bpb-e3-dataset-slug-collision).
  defp insert_sync_cursor!(source, dataset) do
    Repo.query!(
      "INSERT INTO sync_cursors (source, dataset, event_id, inserted_at, updated_at) " <>
        "VALUES ($1, $2, 0, now(), now())",
      [source, dataset]
    )
  end

  defp insert_data_key!(scope, ciphertext) do
    Repo.query!(
      "INSERT INTO data_keys (id, scope, wrapped_key, inserted_at, updated_at) " <>
        "VALUES (gen_random_uuid(), $1, $2, now(), now())",
      [scope, ciphertext]
    )
  end

  # Workspace-keyed surface config (Wave 5 Slice A E1 attribution). The distinctive
  # `marker` lands in the zero_hit_strategy text column so it appears in the COPY
  # text dump (searchable_fields is a jsonb[] — awkward to grep).
  defp insert_surface_config_ws!(workspace_id, surface, scope, marker) do
    Repo.query!(
      "INSERT INTO search_surface_config " <>
        "(id, workspace_id, surface, scope, zero_hit_strategy, inserted_at, updated_at) " <>
        "VALUES (gen_random_uuid(), $1::text::uuid, $2, $3, $4, now(), now())",
      [workspace_id, surface, scope, marker]
    )
  end

  defp seed_exemption!(doc_id, dataset, type) do
    Repo.query!(
      "INSERT INTO authoring_exemptions (doc_id, dataset, type, exempted_at) VALUES ($1, $2, $3, now()) " <>
        "ON CONFLICT (doc_id, dataset) DO NOTHING",
      [doc_id, dataset, type]
    )
  end

  # Purge every copy-strategy row for a workspace under replica role (a clean
  # target), deriving the per-partition delete from the manifest. E2 children
  # first (they JOIN parents), then E1, then the workspace row.
  defp purge_workspace!(ws_id, manifest) do
    members = manifest["tables"]
    e2 = Enum.filter(members, &(&1["partition"] == "E2"))
    e1 = Enum.filter(members, &(&1["partition"] == "E1"))

    Repo.query!("SET session_replication_role = replica", [])

    try do
      for m <- e2, do: delete_e2!(m["name"], ws_id)

      for m <- e1,
          do:
            Repo.query!(
              "DELETE FROM #{quote_ident(m["name"])} WHERE workspace_id = $1::text::uuid",
              [ws_id]
            )

      Repo.query!("DELETE FROM workspaces WHERE id = $1::text::uuid", [ws_id])
    after
      Repo.query!("SET session_replication_role = DEFAULT", [])
    end
  end

  # DELETE FROM <child> t USING <parent> WHERE <join-cond> AND <pred> = $ws,
  # reconstructed from the reviewed E2 join spec (the single source of truth).
  defp delete_e2!(table, ws_id) do
    {join, pred} = Map.fetch!(Catalog.e2_joins(), table)
    "JOIN " <> rest = join
    [using, on_cond] = String.split(rest, " ON ", parts: 2)

    Repo.query!(
      "DELETE FROM #{quote_ident(table)} t USING #{using} WHERE #{on_cond} AND #{pred} = $1::text::uuid",
      [ws_id]
    )
  end

  # Independent scoped count per partition (the count-parity foil — deliberately
  # NOT the exporter's SQL assembly, so a divergence surfaces).
  defp independent_count(%{"name" => "workspaces"}, _ws, _slugs), do: 1

  defp independent_count(%{"partition" => "E1", "name" => t}, ws, _slugs),
    do: scalar("SELECT count(*) FROM #{quote_ident(t)} WHERE workspace_id = $1::text::uuid", [ws])

  defp independent_count(%{"partition" => "E2", "name" => t}, ws, _slugs) do
    {join, pred} = Map.fetch!(Catalog.e2_joins(), t)

    scalar("SELECT count(*) FROM #{quote_ident(t)} t #{join} WHERE #{pred} = $1::text::uuid", [ws])
  end

  defp independent_count(%{"partition" => "E3", "name" => t}, ws, slugs) do
    if t in Catalog.e3_doc_keyed() do
      scalar(
        "SELECT count(*) FROM #{quote_ident(t)} x WHERE EXISTS (SELECT 1 FROM documents d " <>
          "WHERE d.workspace_id = $1::text::uuid AND d.doc_id = x.doc_id AND d.dataset = x.dataset)",
        [ws]
      )
    else
      scalar("SELECT count(*) FROM #{quote_ident(t)} WHERE dataset = ANY($1::text[])", [slugs])
    end
  end

  defp independent_count(%{"partition" => "allowlist", "name" => t}, _ws, slugs) do
    prefix = Map.fetch!(Catalog.allowlist(), t)
    scopes = Enum.map(slugs, &(prefix <> &1))
    scalar("SELECT count(*) FROM #{quote_ident(t)} WHERE scope = ANY($1::text[])", [scopes])
  end

  defp assert_no_orphans! do
    checks = [
      {"documents→workspaces",
       "SELECT count(*) FROM documents d WHERE d.workspace_id IS NOT NULL AND NOT EXISTS " <>
         "(SELECT 1 FROM workspaces w WHERE w.id = d.workspace_id)"},
      {"projects→workspaces",
       "SELECT count(*) FROM projects p WHERE NOT EXISTS (SELECT 1 FROM workspaces w WHERE w.id = p.workspace_id)"},
      {"datasets→projects",
       "SELECT count(*) FROM datasets ds WHERE NOT EXISTS (SELECT 1 FROM projects p WHERE p.id = ds.project_id)"},
      {"content_edges→documents",
       "SELECT count(*) FROM content_edges ce WHERE NOT EXISTS (SELECT 1 FROM documents d WHERE d.id = ce.from_id)"}
    ]

    for {label, sql} <- checks do
      assert scalar(sql, []) == 0, "FK orphans detected: #{label}"
    end
  end

  defp table_index(manifest), do: Map.new(manifest["tables"], &{&1["name"], &1})

  defp scalar(sql, params), do: Repo.query!(sql, params).rows |> hd() |> hd()

  defp quote_ident(ident), do: ~s("#{String.replace(ident, "\"", "\"\"")}")

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
