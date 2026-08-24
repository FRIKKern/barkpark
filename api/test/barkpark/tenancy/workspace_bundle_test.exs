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

  alias Barkpark.{Content, Tenancy}
  alias Barkpark.Plugins.Bootstrap
  alias Barkpark.Repo
  alias Barkpark.Tenancy.WorkspaceBundle
  alias Barkpark.Tenancy.WorkspaceBundle.{Archive, Catalog}
  alias Barkpark.Tenancy.WorkspaceBundle.Janitor

  # ── criterion 1: three enumerations derive LIVE from the catalog ─────────────

  describe "Catalog live enumerations (charter D4)" do
    test "E1 = the 41 workspace_id tables including correction and release authority" do
      e1 = Catalog.live_e1(Repo)
      assert length(e1) == 41
      assert "roles" in e1
      # The run-secrets store gained a nullable workspace_id FK (Connectors W21,
      # charter D191/D192): a workspace's scoped secret rides the generic E1
      # WHERE workspace_id=$ws export + FK cascade; a global secret (NULL) stays.
      assert "secrets" in e1
      assert "secrets_audit" in e1
      assert "registered_chat_hosts" in e1
      assert "chat_execution_leases" in e1
      assert "chat_execution_events" in e1
      # The 20260715 epic-cycle / cycle-fleet ledgers carry workspace_id and ride
      # the generic E1 path (exported + torn down via WHERE workspace_id=$ws).
      assert "cycle_waves" in e1
      assert "epic_assignments" in e1
      assert "epic_benchmark_experiments" in e1

      for table <-
            ~w(cycle_correction_admissions cycle_correction_promotion_events
               cycle_correction_quarantines cycle_correction_roots cycle_correction_targets
               cycle_release_gate_admissions cycle_release_gate_challenges) do
        assert table in e1, "#{table} must be exported by direct workspace ownership"
      end

      # search_surface_config gained a workspace_id column in Wave 5 Slice A
      # (charter D45/D49) to close a LIVE cross-tenant config bleed — re-pinned
      # out of the scope-column allowlist into E1.
      assert "search_surface_config" in e1
      # data_keys carries a workspace_id FK (bpb-datakeys-write-path-workspace-attribution,
      # charter D51-D54) so a shared-slug DEK travels via the E1 workspace_id path,
      # not a bare scope — also re-pinned out of the allowlist into E1.
      assert "data_keys" in e1
      # audit_events / audit_export_sinks carry workspace_id with ZERO FK to workspaces
      assert "audit_events" in e1
      assert "audit_export_sinks" in e1
      refute "audit_events" in Catalog.live_e2(Repo)
      # The full sync_* family gained a workspace_id attribution column (charter D55).
      for t <-
            ~w(sync_cursors sync_dead_letters sync_push_cursors sync_push_conflicts sync_push_doc_revs) do
        assert t in e1, "#{t} must be E1 after per-workspace attribution"
      end
    end

    test "E2 = the 16 FK-transitive children without a workspace_id column" do
      # The six 20260715 cycle-fleet children joined the original six; each reaches
      # the tenant grain through a single many-to-one FK to a workspace_id parent.
      assert Catalog.live_e2(Repo) ==
               ~w(chat_runtime_usage_receipts content_edges cycle_build_plans
                  cycle_release_gate_captures cycle_release_gate_consumptions
                  cycle_release_paper_candidates cycle_release_public_smokes datasets
                  epic_assignment_results epic_assignment_runtime_attempts epic_assignment_tasks
                  epic_benchmark_attempts plugin_doc_state role_permissions task_edges
                  webhook_deliveries)
    end

    test "E3 = the 4 dataset-column tables; the scope allowlist is EMPTY; data_keys, search_surface_config and the 5 sync_* tables all rode into E1" do
      e3 = Catalog.live_e3(Repo)
      assert length(e3) == 4
      assert "authoring_exemptions" in e3
      # The scope-column allowlist is now EMPTY — both former members gained a
      # real workspace_id column and moved to E1.
      assert Catalog.allowlist() == %{}
      # The 5 sync_* tables left E3 for E1 (they carry workspace_id now — D55).
      refute "sync_cursors" in e3
      refute "sync_push_doc_revs" in e3
      # data_keys is NEITHER dataset-scanned E3 NOR allowlist any more — once
      # workspace-attributed it moved to E1 (bpb-datakeys-write-path-workspace-attribution),
      # so a shared-slug DEK travels by workspace_id instead of a bare project-ambiguous scope.
      refute "data_keys" in e3
      refute Map.has_key?(Catalog.allowlist(), "data_keys")
      assert "data_keys" in Catalog.live_e1(Repo)
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

  # ── webhook_deliveries E2 INNER JOIN confinement (pds-bl-pin-webhook-deliveries-inner-join) ──

  describe "webhook_deliveries INNER JOIN keeps secret-bearing media snapshots out of every bundle" do
    test "the media secret is absent from EVERY member, an endpoint-backed delivery still exports, and a backfilled endpoint_id trips catalog validation" do
      ws_a = create_workspace!(unique("wsa"))
      tag = System.unique_integer([:positive])

      # A real workspace-owned endpoint + an endpoint-backed (audit-kind)
      # delivery — the POSITIVE fixture proving ordinary deliveries still ride
      # the E2 join into A's bundle.
      endpoint_id = Ecto.UUID.generate()

      Repo.query!(
        "INSERT INTO webhooks (id, name, url, workspace_id, inserted_at, updated_at) " <>
          "VALUES ($1::text::uuid, $2, 'https://example.test/hook', $3::text::uuid, now(), now())",
        [endpoint_id, "ep-#{tag}", ws_a.id]
      )

      {:ok, _ordinary} =
        %Barkpark.Webhooks.Delivery{}
        |> Barkpark.Webhooks.Delivery.changeset(%{
          endpoint_id: endpoint_id,
          source_kind: "audit",
          payload_snapshot: %{"body" => "ORDINARY-AUDIT-#{tag}"},
          status: "ok"
        })
        |> Repo.insert()

      # The secret-bearing row, written by the REAL media writer: media is the
      # only delivery kind embedding a plaintext secret in payload_snapshot,
      # and BY DESIGN it carries no endpoint_id (config-driven endpoints).
      secret = "MEDIA-SECRET-#{tag}"

      {:ok, media} =
        Barkpark.Webhooks.create_media_delivery(%{
          "url" => "https://example.test/media",
          "secret" => secret,
          "body" => ~s({"kind":"media.deleted"})
        })

      assert is_nil(media.endpoint_id)

      {:ok, bundle} = WorkspaceBundle.export(ws_a.id)
      {manifest, dumps} = Archive.unpack(bundle)

      member = Enum.find(manifest["tables"], &(&1["name"] == "webhook_deliveries"))
      assert member["partition"] == "E2"

      # Positive: the ordinary endpoint-backed delivery IS carried.
      assert dumps["webhook_deliveries"] =~ "ORDINARY-AUDIT-#{tag}"

      # Negative: the media signing secret appears in NO member of the bundle —
      # the INNER JOIN on endpoint_id is what keeps it out.
      for {name, dump} <- dumps do
        refute dump =~ secret, "secret-bearing media snapshot leaked into member #{name}"
      end

      # Catalog validation: green while confined…
      assert :ok = Catalog.assert_partition!(Repo)

      # …and it FIRES when endpoint reachability admits the media row (the
      # backfill breakage mode named at the @e2_joins invariant comment).
      Repo.query!(
        "UPDATE webhook_deliveries SET endpoint_id = $1::text::uuid WHERE id = $2",
        [endpoint_id, media.id]
      )

      assert_raise RuntimeError, ~r/secret-bearing/, fn ->
        Catalog.assert_partition!(Repo)
      end

      # The flagged hazard is REAL, not theoretical: the backfilled row now
      # rides the join into A's bundle carrying the plaintext secret.
      {:ok, bundle2} = WorkspaceBundle.export(ws_a.id)
      {_m2, dumps2} = Archive.unpack(bundle2)
      assert dumps2["webhook_deliveries"] =~ secret

      # Restore confinement → validation is green again.
      Repo.query!("UPDATE webhook_deliveries SET endpoint_id = NULL WHERE id = $1", [media.id])
      assert :ok = Catalog.assert_partition!(Repo)
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
      # (preview_token_jti is a remaining E3-dataset table; the sync_* family
      # moved to E1 in charter D55 and is proved separately below.)
      insert_preview_jti!("EXCL-A-JTI-#{tag}", excl)

      # B's rows under the SHARED slug, uniquely marked — MUST NOT leak into A.
      # (search_surface_config and the sync_* family are no longer bare-slug-keyed —
      # they moved to E1, so their cross-tenant isolation is proven by dedicated
      # per-workspace E1 attribution describe blocks; preview_token_jti remains an
      # E3-dataset table and stands in for the bare-slug leak here.)
      insert_preview_jti!("B-ONLY-JTI-#{tag}", shared)
      insert_data_key!("dataset:#{shared}", "B-ONLY-CIPHERTEXT-#{tag}")

      {:ok, bundle} = WorkspaceBundle.export(ws_a.id)
      {manifest, dumps} = Archive.unpack(bundle)

      # No over-narrow: A's exclusive-slug row IS carried.
      assert "excl-a-#{tag}" in manifest["dataset_slugs"]
      assert dumps["preview_token_jti"] =~ "EXCL-A-JTI-#{tag}"

      # No cross-tenant leak: the shared slug is excluded, so B's bare-keyed rows
      # are categorically absent from A's bundle. On origin/main the bare copy
      # pulls them in (and lists the shared slug) → these refutes FAIL → RED.
      refute "shared-prod-#{tag}" in manifest["dataset_slugs"]
      refute dumps["preview_token_jti"] =~ "B-ONLY-JTI-#{tag}"
      refute dumps["data_keys"] =~ "B-ONLY-CIPHERTEXT-#{tag}"
    end
  end

  # ── :full means full — bare-slug E3 fidelity under a shared slug (PDS-D45/D74)

  # THE PROPERTY BELOW STATES ITS OWN CARVE-OUTS. For every E3-dataset table, the
  # rows sitting under a slug this workspace's projects OWN fall in exactly three
  # buckets, and they must add up:
  #
  #   travelled  — the member's row_count
  #   declared   — the manifest's machine-readable `declared_loss` count
  #   foreign    — rows the table itself PROVES belong to another workspace
  #
  # `foreign` is the ONLY legitimate silent omission, and it is named per table
  # here, so a future weakening has to delete a named carve-out rather than
  # quietly widen an inequality. Everything else that fails to travel MUST be
  # counted out loud; a row in none of the three buckets vanished silently, and
  # that is the defect this block exists to convict.
  #
  # Carve-outs deliberately OUTSIDE the property (they are not loss):
  #   * generated columns (documents.search_vector) — Postgres re-derives them on
  #     import, so their absence from the column list is by construction;
  #   * the boundary tables no bundle carries (users, organizations,
  #     chat_sessions, …) — @pinned_non_tenant, outside the tenancy partition;
  #   * a sibling workspace's rows — excluded BY DESIGN (charter D21), which is
  #     exactly the `foreign` bucket wherever the table can prove it.
  @foreign_row_predicate %{
    # `shares` carries workspace_slug NOT NULL and workspaces.slug is uniquely
    # indexed, so a row naming a DIFFERENT workspace is provably not ours.
    "shares" => "t.workspace_slug <> $2",
    # `preview_token_jti` carries ONLY a bare `dataset` string — no workspace_id /
    # project_id / dataset_id column exists. NOTHING in the row proves ownership
    # either way, so it has no `foreign` bucket at all: every candidate must
    # either travel or be declared. `$2::text` is the workspace slug and is never
    # NULL, so this is a constant FALSE that still binds the parameter — the cast
    # is required (a bare `$2 IS NULL` is 42P18 indeterminate_datatype), and the
    # parameter must be referenced at all (Postgres rejects a bind supplying more
    # parameters than the statement uses).
    "preview_token_jti" => "$2::text IS NULL"
  }

  describe "a :full bundle is LOSS-EXPLICIT for the bare-slug E3 family (PDS-D45/D74)" do
    test "PROPERTY: every bare-slug E3 row under an owned slug travels, is declared, or is provably foreign" do
      f = seed_shared_slug_fixture!()

      {:ok, bundle} = WorkspaceBundle.export(f.ws_a.id)
      {manifest, _dumps} = Archive.unpack(bundle)

      owned = owned_slugs(f.ws_a.id)
      members = table_index(manifest)
      losses = declared_loss_index(manifest)

      # The fixture must actually exercise the shape, else the property is vacuous.
      assert f.shared in owned
      refute f.shared in manifest["dataset_slugs"]

      for table <- Catalog.e3_dataset_keyed() do
        foreign_pred = Map.fetch!(@foreign_row_predicate, table)

        candidates =
          scalar(
            "SELECT count(*) FROM #{quote_ident(table)} t " <>
              "WHERE t.dataset = ANY($1::text[]) AND NOT (#{foreign_pred})",
            [owned, f.ws_a.slug]
          )

        travelled = get_in(members, [table, "row_count"]) || 0
        declared = get_in(losses, [table, "row_count"]) || 0

        assert candidates == travelled + declared,
               "SILENT LOSS in #{table}: #{candidates} row(s) sit under a slug workspace " <>
                 "#{f.ws_a.slug} owns and are not provably foreign, but only #{travelled} " <>
                 "travelled and #{declared} were declared — " <>
                 "#{candidates - travelled - declared} vanished with no sentinel."
      end
    end

    test "shares: the workspace's OWN row under a SHARED slug travels; the sibling's does not" do
      f = seed_shared_slug_fixture!()

      {:ok, bundle} = WorkspaceBundle.export(f.ws_a.id)
      {manifest, dumps} = Archive.unpack(bundle)

      # On origin/main the shared slug is narrowed OUT of `dataset_slugs`, the
      # bare `dataset = ANY(slugs)` copy selects nothing under it, and this row is
      # silently absent — a :full backup missing a live share.
      assert dumps["shares"] =~ f.a_shared_share_id
      assert dumps["shares"] =~ f.a_excl_share_id

      # The exclusivity rule still holds where it matters: B's row under the very
      # same slug is categorically absent from A's bundle.
      refute dumps["shares"] =~ f.b_shared_share_id

      assert table_index(manifest)["shares"]["row_count"] == 2,
             "the member count must be the TRUE count, not the truncated one"
    end

    test "preview_token_jti: the unattributable rows are DECLARED with their slugs and count, and shares is not" do
      f = seed_shared_slug_fixture!()

      {:ok, bundle} = WorkspaceBundle.export(f.ws_a.id)
      {manifest, dumps} = Archive.unpack(bundle)

      losses = declared_loss_index(manifest)
      loss = Map.fetch!(losses, "preview_token_jti")

      assert loss["reason"] == "unattributable_shared_dataset_slug"
      assert loss["slugs"] == [f.shared]

      # BOTH rows under the shared slug are counted: the bundle cannot tell whose
      # they are, so it reports the honest upper bound rather than guessing.
      assert loss["row_count"] == 2
      assert is_binary(loss["message"]) and loss["message"] =~ "preview_token_jti"

      # The cross-tenant refutation is untouched: nothing under the shared slug
      # travels, it is merely no longer SILENT.
      refute dumps["preview_token_jti"] =~ f.a_shared_jti
      refute dumps["preview_token_jti"] =~ f.b_shared_jti
      assert dumps["preview_token_jti"] =~ f.a_excl_jti

      # shares is deliberately NOT in the loss list — it got the correct-export
      # answer, so declaring a loss for it would be a lie in the other direction.
      refute Map.has_key?(losses, "shares")
    end

    test "no shared slug in play → declared_loss is present and EMPTY (the key is not conditional)" do
      %{ws_a: ws_a} = seed_two_workspaces!()

      {:ok, bundle} = WorkspaceBundle.export(ws_a.id)
      {manifest, _dumps} = Archive.unpack(bundle)

      assert manifest["declared_loss"] == [],
             "the key must always be present — a consumer that only sees it on loss " <>
               "cannot tell 'no loss' from 'an engine too old to say'"
    end

    test "a dataset-scoped bundle does not WIDEN shares to the workspace's other datasets" do
      f = seed_shared_slug_fixture!()

      {:ok, bundle} = WorkspaceBundle.export(f.ws_a.id, dataset: f.excl)
      {manifest, dumps} = Archive.unpack(bundle)

      assert dumps["shares"] =~ f.a_excl_share_id

      refute dumps["shares"] =~ f.a_shared_share_id,
             "a dataset-scoped pull carried a share for a DIFFERENT dataset — the " <>
               "workspace_slug predicate widened the grain"

      refute dumps["shares"] =~ f.b_shared_share_id
      assert table_index(manifest)["shares"]["row_count"] == 1
    end

    test "export and teardown agree: delete_workspace sweeps every shares row A's bundle carried, and spares B's" do
      f = seed_shared_slug_fixture!()

      # The binding assertion: whatever the EXPORT claims as A's travels, the
      # TEARDOWN must remove — otherwise a workspace that was backed up and then
      # deleted leaves rows behind that its own bundle said it owned. Without the
      # teardown half of the split this fails while 98 other tests stay green.
      {:ok, bundle} = WorkspaceBundle.export(f.ws_a.id)
      {_manifest, dumps} = Archive.unpack(bundle)
      exported = share_ids_in(dumps["shares"])

      assert f.a_shared_share_id in exported,
             "fixture regression: the shared-slug row must be IN the bundle for this " <>
               "lockstep assertion to mean anything"

      assert {:ok, _} = Tenancy.delete_workspace(f.ws_a)

      survivors =
        scalar("SELECT count(*) FROM shares WHERE id::text = ANY($1::text[])", [exported])

      assert survivors == 0,
             "delete_workspace left #{survivors} shares row(s) the :full bundle exported as " <>
               "this workspace's — export and teardown disagree (tenancy.ex documents them " <>
               "as the EXACT same shapes)"

      # And the sweep is still fail-CLOSED across the tenant boundary.
      assert scalar("SELECT count(*) FROM shares WHERE id::text = $1", [f.b_shared_share_id]) == 1
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

  # ── shared-slug DEK travels by attribution (bpb-datakeys-write-path-workspace-attribution) ──

  describe "a shared-slug DEK attributed to a workspace is carried in its bundle" do
    test "A's shared-slug DEK is PRESENT via the E1 workspace_id path; a sibling/NULL one is not" do
      ws_a = create_workspace!(unique("wsa"))
      proj_a = create_project!(ws_a, unique("proja"))
      ws_b = create_workspace!(unique("wsb"))
      proj_b = create_project!(ws_b, unique("projb"))

      # `shared` collides across A and B (a slug is unique only per project_id —
      # charter D21), so `dataset_slugs_for(A)` project-qualifies it OUT. On
      # origin/main data_keys is a BARE scope-keyed allowlist table, so A's DEK
      # under `shared` is silently DROPPED from A's single-workspace bundle. Per-
      # workspace attribution (this slice) restores it via the E1 workspace_id
      # copy path.
      tag = System.unique_integer([:positive])
      shared = "shared-prod-#{tag}"

      seed_dataset!(proj_a.id, shared)
      seed_dataset!(proj_b.id, shared)

      # Three DEKs under the SAME shared scope, distinguished by workspace +
      # version (version keeps the (workspace_id, scope, version) index happy):
      insert_data_key!("dataset:#{shared}", "A-ATTRIBUTED-DEK-#{tag}", ws_a.id, 1)
      insert_data_key!("dataset:#{shared}", "B-ATTRIBUTED-DEK-#{tag}", ws_b.id, 2)
      insert_data_key!("dataset:#{shared}", "NULL-LEGACY-DEK-#{tag}", nil, 3)

      {:ok, bundle} = WorkspaceBundle.export(ws_a.id)
      {manifest, dumps} = Archive.unpack(bundle)

      # data_keys now rides the E1 partition (workspace_id copy), NOT the allowlist.
      dk = Enum.find(manifest["tables"], &(&1["name"] == "data_keys"))
      assert dk["partition"] == "E1"

      # A's attributed DEK travels — the D4 completeness the fix restores…
      assert dumps["data_keys"] =~ "A-ATTRIBUTED-DEK-#{tag}"
      # …B's does NOT (no cross-tenant leak into A's single-workspace bundle)…
      refute dumps["data_keys"] =~ "B-ATTRIBUTED-DEK-#{tag}"
      # …and the NULL-workspace legacy row is excluded (the D44 forward-guard).
      refute dumps["data_keys"] =~ "NULL-LEGACY-DEK-#{tag}"
    end
  end

  # ── sync_* family E1 attribution (charter D55) ────────────────────────────────

  describe "export attributes the sync_* family via workspace_id (E1), even on a SHARED slug" do
    test "a sync_cursors row under a slug SHARED with a sibling is carried by its OWNER's bundle only" do
      ws_a = create_workspace!(unique("wsa"))
      proj_a = create_project!(ws_a, unique("proja"))
      ws_b = create_workspace!(unique("wsb"))
      proj_b = create_project!(ws_b, unique("projb"))

      # Both workspaces own the SAME slug — the exact bare-slug collision D55 fixes.
      tag = System.unique_integer([:positive])
      shared = "shared-prod-#{tag}"
      seed_dataset!(proj_a.id, shared)
      seed_dataset!(proj_b.id, shared)

      # One sync cursor per workspace under the shared slug, distinguished ONLY by
      # workspace_id (the old bare {source, dataset} key could not tell them apart).
      insert_sync_cursor_ws!(ws_a.id, "A-SYNC-#{tag}", shared)
      insert_sync_cursor_ws!(ws_b.id, "B-SYNC-#{tag}", shared)

      {:ok, bundle} = WorkspaceBundle.export(ws_a.id)
      {_manifest, dumps} = Archive.unpack(bundle)

      # E1 keys on workspace_id, so A's row IS carried even though the slug is
      # shared (on origin/main the sync_cursors E3-dataset copy drops the shared
      # slug entirely → A's row is ABSENT → this assertion is RED before D55).
      assert dumps["sync_cursors"] =~ "A-SYNC-#{tag}"
      # …and B's row under the same slug never leaks into A's single-workspace bundle.
      refute dumps["sync_cursors"] =~ "B-SYNC-#{tag}"
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
      # Attribute the exclusive-slug DEK to A so it rides the E1 workspace_id copy
      # path (data_keys is E1 now — bpb-datakeys-write-path-workspace-attribution).
      insert_data_key!("dataset:solo-a", "solo-a-dek-ciphertext", ws_a.id)

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

    test "media_files.size survives the round-trip IDENTICALLY — the independent witness the blob proof compares against" do
      %{ws_a: ws_a, proj_a: proj_a} = seed_two_workspaces!()

      # The crown proof convicts a truncated blob by comparing the SERVED
      # content-length against the target's stored `media_files.size`. That
      # comparison only means anything because `size` is an independent witness:
      # it is stamped once at upload from `File.stat` and recomputed nowhere, and
      # the blob-push route never touches the DB. So the bundle must carry the
      # number itself, unchanged. Distinct, non-default sizes (the fixture default
      # is 1): a column that silently vanished and defaulted would still "match"
      # if every row shared one value.
      for bytes <- [4_097, 65_536, 1_048_577] do
        {:ok, _} =
          create_media_file_in!(
            ws_a,
            proj_a,
            %{size: bytes, path: "sized/#{unique("m")}-#{bytes}.bin"},
            "prod-a"
          )
      end

      source = media_path_sizes!(ws_a.id)
      assert length(source) == 4
      assert Enum.uniq(Enum.map(source, &elem(&1, 1))) |> length() == 4

      {:ok, bundle} = WorkspaceBundle.export(ws_a.id)
      {manifest, dumps} = Archive.unpack(bundle)

      entry = table_index(manifest)["media_files"]

      # (a) export side: `size` is in the carried column list at all…
      assert "size" in entry["columns"],
             "media_files exported without `size` — the blob-fidelity witness is gone"

      # …and (b) the BUNDLE BYTES carry every seeded value, not just the DB.
      assert media_pairs_from_copy(dumps["media_files"], entry["columns"]) == source

      # (c) import side: a clean target reconstructs the pairs IDENTICALLY.
      purge_workspace!(ws_a.id, manifest)
      assert media_path_sizes!(ws_a.id) == []

      {:ok, _stats} = WorkspaceBundle.import_bundle(bundle)

      assert media_path_sizes!(ws_a.id) == source,
             "media_files (path, size) drifted across the round-trip — a truncated-blob " <>
               "proof built on the imported size would silently pass"
    end

    test "media_files.size rides the DEV profile too — the profile the crown proof actually pulls with" do
      %{ws_a: ws_a, proj_a: proj_a} = seed_two_workspaces!()

      for bytes <- [4_097, 1_048_577] do
        {:ok, _} =
          create_media_file_in!(
            ws_a,
            proj_a,
            %{size: bytes, path: "sized-dev/#{unique("m")}-#{bytes}.bin"},
            "prod-a"
          )
      end

      source = media_path_sizes!(ws_a.id)

      # The test above pins the FULL profile. Step 5 of the crown proof runs off
      # a `--profile dev` pull, and the dev partition is a SECOND, orthogonal
      # classification: media_files is `:copy` with an empty scrub set today, so
      # `size` travels — but nothing pinned that, and a future entry in
      # @dev_scrub nulling it would break step 5's baseline with every other
      # gate green. This is the assertion that convicts that change.
      {:ok, bundle} = WorkspaceBundle.export(ws_a.id, profile: :dev)
      {manifest, dumps} = Archive.unpack(bundle)

      assert manifest["profile"] == "dev"

      entry = table_index(manifest)["media_files"]

      assert entry,
             "a dev-profile bundle carried NO media_files member — the crown proof's " <>
               "served-asset step has nothing to compare a content-length against"

      assert "size" in entry["columns"],
             "the dev profile dropped or scrubbed media_files.size — step 5 would then " <>
               "compare a served content-length against a default and pass on a truncated blob"

      assert media_pairs_from_copy(dumps["media_files"], entry["columns"]) == source
    end
  end

  # ── merge import mode (PDS-D8/D9) ─────────────────────────────────────────────

  describe "merge import mode (PDS-D8): ON CONFLICT (order_columns) DO UPDATE convergence" do
    test "merge over a POPULATED workspace converges — mutated rows restored, deleted rows resurrected, 2nd AND 3rd import md5-stable" do
      %{ws_a: ws_a, only_a_doc: only_a_doc} = seed_two_workspaces!()

      {:ok, bundle} = WorkspaceBundle.export(ws_a.id)
      {manifest_before, _} = Archive.unpack(bundle)
      md5s = fn m -> Map.new(m["tables"], &{&1["name"], &1["md5"]}) end

      # Drift the target four ways, one per convergence class:
      #   root non-key mutation (DO UPDATE on workspaces)…
      Repo.query!("UPDATE workspaces SET name = 'PDS-DRIFT-NAME' WHERE id = $1::text::uuid", [
        ws_a.id
      ])

      #   …E1 non-key mutation (DO UPDATE on documents)…
      Repo.query!(
        "UPDATE documents SET title = 'PDS-DRIFT-TITLE' " <>
          "WHERE workspace_id = $1::text::uuid AND doc_id = $2",
        [ws_a.id, only_a_doc]
      )

      #   …E2 row deletion (plain insert resurrects — no conflict)…
      Repo.query!(
        "DELETE FROM content_edges WHERE from_id IN " <>
          "(SELECT id FROM documents WHERE workspace_id = $1::text::uuid)",
        [ws_a.id]
      )

      #   …E3 row deletion (bare DO NOTHING re-inserts the missing row).
      Repo.query!("DELETE FROM authoring_exemptions WHERE doc_id = $1", [only_a_doc])

      # Second import (the first was the export's implicit source state): MERGE
      # over the still-populated workspace — on origin/main this PK-crashes.
      {:ok, stats} = WorkspaceBundle.import_bundle(bundle, mode: :merge)
      assert stats.total_rows > 0

      # Row-count receipts keep CARRIED-rows semantics in merge mode too.
      assert stats.tables["workspaces"] == 1

      # The mutations are converged back and the deletions resurrected —
      # re-export md5 parity across EVERY table is the strongest proof.
      assert scalar("SELECT name FROM workspaces WHERE id = $1::text::uuid", [ws_a.id]) ==
               ws_a.name

      {:ok, b2} = WorkspaceBundle.export(ws_a.id)
      {m2, _} = Archive.unpack(b2)
      assert md5s.(manifest_before) == md5s.(m2)

      # Third import over the converged state: still {:ok, _}, still identical.
      {:ok, _} = WorkspaceBundle.import_bundle(bundle, mode: :merge)
      {:ok, b3} = WorkspaceBundle.export(ws_a.id)
      {m3, _} = Archive.unpack(b3)
      assert md5s.(manifest_before) == md5s.(m3)
    end

    # ── media_files.size under mode: :merge ───────────────────────────────────
    #
    # WHY THESE TWO EXIST AT ALL. The md5-parity convergence test above drifts
    # workspaces / documents / content_edges / authoring_exemptions and never
    # touches media_files; the only other merge-mode assertion repo-wide
    # (workspace_bundle_dev_profile_test.exs) checks that `total_rows` is
    # positive and asserts no column value. PR #4589's two `size` tests both
    # import with NO `:mode` — i.e. `:clean`, over a purged target — and its
    # dev-profile one never imports at all. So the ONE path the crown proof
    # actually walks in step 1 (a dev-profile bundle merged over a populated
    # target) had no assertion that could convict a `size` regression. These
    # two do: excluding `size` from merge_upsert's DO UPDATE set reddens them
    # and nothing else in this file.

    test "merge over a POPULATED target converges media_files.size — the witness step 5 convicts a truncated blob with" do
      %{ws_a: ws_a, proj_a: proj_a} = seed_two_workspaces!()

      # DISTINCT, NON-DEFAULT sizes. `create_media_file_in!/4` defaults `size`
      # to 1, so on a table where every row shares one value a merge that
      # silently dropped `size` from its update set would still "converge".
      sized =
        for bytes <- [4_099, 65_538, 1_048_579] do
          {:ok, mf} =
            create_media_file_in!(
              ws_a,
              proj_a,
              %{size: bytes, path: "merge-sized/#{unique("m")}-#{bytes}.bin"},
              "prod-a"
            )

          mf
        end

      source = media_path_sizes!(ws_a.id)
      assert length(source) == 4
      assert length(Enum.uniq(Enum.map(source, &elem(&1, 1)))) == 4

      {:ok, bundle} = WorkspaceBundle.export(ws_a.id)

      # Drift the target two ways against media_files specifically:
      #   (1) a SURVIVING row's `size` is mutated — only an ON CONFLICT DO
      #       UPDATE set that CARRIES `size` restores it (a set built over
      #       `cols -- order_cols` does; one that skips `size` does not)…
      [to_drift, to_delete | _] = sized

      Repo.query!("UPDATE media_files SET size = 7 WHERE id = $1::text::uuid", [to_drift.id])

      #   …and (2) a row is DELETED — it comes back as a plain insert (no
      #       conflict), so a passing (1) and a passing (2) are different
      #       mechanisms and a single bug cannot fake both.
      Repo.query!("DELETE FROM media_files WHERE id = $1::text::uuid", [to_delete.id])

      # Sanity: the drift is REAL. Without this a no-op export/import would
      # satisfy the convergence assertion vacuously.
      drifted = media_path_sizes!(ws_a.id)
      refute drifted == source
      assert length(drifted) == 3
      assert {to_drift.path, 7} in drifted

      {:ok, stats} = WorkspaceBundle.import_bundle(bundle, mode: :merge)
      assert stats.total_rows > 0

      assert media_path_sizes!(ws_a.id) == source,
             "media_files (path, size) did not converge under mode: :merge — the crown " <>
               "proof's step-5 content-length comparison would run against a stale or " <>
               "defaulted size and pass on a truncated blob"
    end

    test "dev profile + mode: :merge converges media_files.size — step 1 of the crown proof, exactly" do
      %{ws_a: ws_a, proj_a: proj_a} = seed_two_workspaces!()

      sized =
        for bytes <- [8_193, 262_147] do
          {:ok, mf} =
            create_media_file_in!(
              ws_a,
              proj_a,
              %{size: bytes, path: "merge-dev/#{unique("m")}-#{bytes}.bin"},
              "prod-a"
            )

          mf
        end

      source = media_path_sizes!(ws_a.id)
      assert length(source) == 3

      # `--profile dev` + `--merge` is the literal pull the crown proof's step 1
      # runs. The dev partition is a SECOND, orthogonal classification from the
      # copy/merge strategy, so a green full-profile merge test does not imply
      # this one.
      {:ok, bundle} = WorkspaceBundle.export(ws_a.id, profile: :dev)
      {manifest, _dumps} = Archive.unpack(bundle)
      assert manifest["profile"] == "dev"

      [to_drift, to_delete | _] = sized
      Repo.query!("UPDATE media_files SET size = 9 WHERE id = $1::text::uuid", [to_drift.id])
      Repo.query!("DELETE FROM media_files WHERE id = $1::text::uuid", [to_delete.id])

      refute media_path_sizes!(ws_a.id) == source

      {:ok, stats} = WorkspaceBundle.import_bundle(bundle, mode: :merge)
      assert stats.total_rows > 0

      # KEEP BOTH THIS AND THE EXPORT-SIDE DEV TEST ABOVE (L558). This probe
      # alone could pass VACUOUSLY: if a future @dev_scrub / @dev_copy change
      # dropped the media_files member from the dev bundle entirely, the merge
      # becomes a no-op — and a no-op over a target this test already drifted
      # would fail here, but a no-op over an UNDRIFTED target would not. The
      # export-side test is what pins member PRESENCE and column carriage; this
      # one pins that the merge WRITE path actually lands the value.
      assert media_path_sizes!(ws_a.id) == source,
             "a dev-profile bundle merged over a populated target did not converge " <>
               "media_files.size — step 1 of the crown proof leaves the target wrong " <>
               "and step 5 measures against it"
    end

    test "clean re-import over a populated workspace still ABORTS (default mode untouched)" do
      %{ws_a: ws_a} = seed_two_workspaces!()
      {:ok, bundle} = WorkspaceBundle.export(ws_a.id)

      # The default :clean path assumes a clean target — a re-import over the
      # still-populated workspace PK-conflicts and the transaction rolls back.
      assert_raise Postgrex.Error, fn -> WorkspaceBundle.import_bundle(bundle) end

      # Nothing partial-imported: the workspace row is still the single original.
      assert scalar("SELECT count(*) FROM workspaces WHERE id = $1::text::uuid", [ws_a.id]) == 1
    end

    test "unknown mode raises ArgumentError before touching the database" do
      assert_raise ArgumentError, ~r/unknown import mode/, fn ->
        WorkspaceBundle.import_bundle(<<>>, mode: :sideways)
      end
    end
  end

  describe "root-slug pre-flight (PDS-D9): empty-shell adoption, fail-closed refusal" do
    test "same slug + different id + provably EMPTY shell → shell replaced in-transaction" do
      %{ws_a: ws_a} = seed_two_workspaces!()
      {:ok, bundle} = WorkspaceBundle.export(ws_a.id)
      {manifest, _} = Archive.unpack(bundle)

      # Simulate the fresh-target shape: A is gone, and a migrate-seeded shell
      # squats A's slug under a DIFFERENT id (with its own project + dataset —
      # the shell's FK children must vanish with it, not orphan).
      purge_workspace!(ws_a.id, manifest)
      shell = create_workspace!(ws_a.slug)
      shell_proj = create_project!(shell, unique("shellproj"))
      refute shell.id == ws_a.id

      {:ok, stats} = WorkspaceBundle.import_bundle(bundle, mode: :merge)
      assert stats.total_rows > 0

      # The bundle's workspace owns the slug again; the shell and its children
      # are gone (deleted in-transaction, FK cascade intact).
      assert scalar("SELECT id::text FROM workspaces WHERE slug = $1", [ws_a.slug]) == ws_a.id

      assert scalar("SELECT count(*) FROM workspaces WHERE id = $1::text::uuid", [shell.id]) == 0

      assert scalar("SELECT count(*) FROM projects WHERE id = $1::text::uuid", [shell_proj.id]) ==
               0

      # A's content really landed.
      assert scalar("SELECT count(*) FROM documents WHERE workspace_id = $1::text::uuid", [
               ws_a.id
             ]) > 0
    end

    test "same slug + different id + NON-empty workspace → refused with a NAMED error, never a raw 25P02; target untouched" do
      %{ws_a: ws_a} = seed_two_workspaces!()
      {:ok, bundle} = WorkspaceBundle.export(ws_a.id)
      {manifest, _} = Archive.unpack(bundle)

      purge_workspace!(ws_a.id, manifest)

      # A POPULATED squatter on A's slug — one document makes it not-a-shell.
      squatter = create_workspace!(ws_a.slug)
      squatter_proj = create_project!(squatter, unique("squatproj"))

      {:ok, _doc} =
        create_document_in!(squatter, squatter_proj, "post", %{"doc_id" => "squat-doc"}, "test")

      assert {:error, {:workspace_slug_conflict, info}} =
               WorkspaceBundle.import_bundle(bundle, mode: :merge)

      assert info.slug == ws_a.slug
      assert info.existing_id == squatter.id
      assert info.bundle_id == ws_a.id

      # Fail-closed: the squatter and its document are untouched, and A was NOT
      # partially imported (the whole transaction rolled back).
      assert scalar("SELECT count(*) FROM documents WHERE workspace_id = $1::text::uuid", [
               squatter.id
             ]) == 1

      assert scalar("SELECT count(*) FROM workspaces WHERE id = $1::text::uuid", [ws_a.id]) == 0
    end
  end

  # ── The support-box merge-import scenario (task-63a199c0a0ce2a06) ───────────
  #
  # The live provision_support chain fired THREE times with the same blind
  # signature (bp exit 8 = box-side 5xx) importing a template-launched parent's
  # dev/dataset bundle into a fresh box. This test reproduces the box's exact
  # documented state and the chain's exact sequence IN CI, so the engine half of
  # the diagnosis is pinned mechanically: if the merge engine can crash on this
  # state, the raise is named HERE, not on a torn-down Hetzner box.

  describe "support-box merge-import scenario (task-63a199c0a0ce2a06)" do
    test "dev/dataset bundle into Default ws + Bootstrap schemas + ensured same-slug shell imports clean; Default slot untouched" do
      # FRESH-BOX SHAPE: the migrate-seeded Default workspace holds the
      # boot-time plugin schemas (Bootstrap stamps them into the Default
      # production slot — same names, same `dataset` string as any parent's).
      {default_ws, default_proj} = ensure_default_scope!()
      {:ok, _prod} = Tenancy.get_or_create_dataset(default_proj.id, "production")
      assert {:ok, _n} = Bootstrap.register_all_schemas()

      default_schema_count =
        scalar(
          "SELECT count(*) FROM schema_definitions WHERE workspace_id = $1::text::uuid",
          [default_ws.id]
        )

      # A schema NAME the box's Default slot already owns (the cross-workspace
      # same-name case the live import always carries); "tplarticle" when the
      # plugin registry is empty under test.
      overlap =
        case Repo.query!(
               "SELECT name FROM schema_definitions WHERE workspace_id = $1::text::uuid " <>
                 "AND dataset = 'production' ORDER BY name LIMIT 1",
               [default_ws.id]
             ).rows do
          [[name]] -> name
          [] -> "tplarticle"
        end

      # PARENT: the template bootstrap's exact shape (internal/bootstrap) —
      # workspace + "default" project + "production" dataset, schemas and seed
      # docs written through the SCOPED write path. "production" is deliberately
      # SHARED with the Default workspace, exactly as on a live parent.
      parent = create_workspace!(unique("tpl-instance"))
      parent_proj = create_project!(parent, "default")
      {:ok, _ds} = Tenancy.get_or_create_dataset(parent_proj.id, "production")
      scope = [workspace_id: parent.id, project_id: parent_proj.id]

      for name <- Enum.uniq([overlap, "tplarticle"]) do
        assert {:ok, _} =
                 Content.upsert_schema(
                   %{"name" => name, "title" => name, "fields" => []},
                   "production",
                   scope
                 )
      end

      {:ok, _doc} =
        create_document_in!(
          parent,
          parent_proj,
          "tplarticle",
          %{"doc_id" => "tpl-doc-1"},
          "production"
        )

      # Export BOTH grains: the dev/dataset bundle is what the support chain
      # ships; the full bundle exists only to drive a complete purge below.
      {:ok, full_bundle} = WorkspaceBundle.export(parent.id)
      {full_manifest, _} = Archive.unpack(full_bundle)
      {:ok, dev_bundle} = WorkspaceBundle.export(parent.id, profile: :dev, dataset: "production")
      {dev_manifest, _} = Archive.unpack(dev_bundle)
      assert dev_manifest["profile"] == "dev"
      assert dev_manifest["dataset"] == "production"

      # THE BOX: the parent lives on another machine — remove every parent row,
      # then replay supportEnsureWorkspaceStep (POST /api/workspaces): a
      # same-slug EMPTY shell with its own Default project + production dataset.
      purge_workspace!(parent.id, full_manifest)
      shell = create_workspace!(parent.slug)
      shell_proj = create_project!(shell, "default")
      {:ok, _shell_ds} = Tenancy.get_or_create_dataset(shell_proj.id, "production")
      refute shell.id == parent.id

      # THE IMPORT the chain runs (bp cloud workspace import --merge).
      assert {:ok, stats} = WorkspaceBundle.import_bundle(dev_bundle, mode: :merge)
      assert stats.total_rows > 0

      # The shell was adopted: the bundle's workspace owns the slug again.
      assert scalar("SELECT id::text FROM workspaces WHERE slug = $1", [parent.slug]) ==
               parent.id

      assert scalar("SELECT count(*) FROM workspaces WHERE id = $1::text::uuid", [shell.id]) == 0

      # The parent's content really landed at the dev/dataset grain.
      assert scalar("SELECT count(*) FROM documents WHERE workspace_id = $1::text::uuid", [
               parent.id
             ]) > 0

      assert scalar(
               "SELECT count(*) FROM schema_definitions WHERE workspace_id = $1::text::uuid",
               [parent.id]
             ) == length(Enum.uniq([overlap, "tplarticle"]))

      # The resident Default slot is UNTOUCHED — same workspace, same schema
      # rows, none adopted/overwritten by the import.
      assert scalar("SELECT count(*) FROM workspaces WHERE id = $1::text::uuid", [default_ws.id]) ==
               1

      assert scalar(
               "SELECT count(*) FROM schema_definitions WHERE workspace_id = $1::text::uuid",
               [default_ws.id]
             ) == default_schema_count
    end
  end

  # ── COPY timeout (PDS-D42) ────────────────────────────────────────────────────

  describe "export COPY timeout (PDS-D42)" do
    # A happy-path export does NOT pay for this: it is just as green with no
    # `:timeout` at all — that is exactly how the 15s default hid until a live
    # export died at 27.0s. So look at what actually reaches the driver.
    #
    # RE-SITED onto `Repo.transaction/2` (PDS-D206). The producer is now
    # `Ecto.Adapters.SQL.stream` rather than `Repo.query!`, and the budget it
    # actually runs under is the TRANSACTION's: a 4-cell probe matrix proved
    # the stream-level `:timeout` is INERT (txn `:infinity` + stream 300 ms
    # survived 3002 ms) and that a stream cannot widen its transaction's budget
    # (txn 300 ms + stream `:infinity` died at 310 ms). So a build that moved
    # `:infinity` onto the `SQL.stream` call would be GREEN on a `query!`-shaped
    # assertion while silently running on Ecto's 15,000 ms default in prod —
    # precisely the live failure PDS-D42 exists to close. Delete
    # `timeout: copy_out_timeout()` from run_copy_out/2 and this fails on the
    # very next run.
    #
    # (Driving a real 0 ms budget is NOT usable here: under
    # `Ecto.Adapters.SQL.Sandbox` a pool timeout arrives as an ownership-
    # shutdown EXIT, not a rescuable raise, and it kills the test connection.)
    test "every COPY streams inside a Repo.transaction carrying timeout: :infinity — never Ecto's 15_000 ms default" do
      %{ws_a: ws_a} = seed_two_workspaces!()

      calls =
        trace_repo_transaction(fn -> assert {:ok, _} = WorkspaceBundle.export(ws_a.id) end)

      # One transaction per table in the COPY loop — the same population the
      # old `COPY `-prefixed query! filter counted.
      assert length(calls) > 10,
             "expected the COPY loop to open one transaction per table; saw #{length(calls)}"

      for opts <- calls do
        assert Keyword.get(opts, :timeout) == :infinity,
               "a COPY transaction opened with " <>
                 "#{inspect(Keyword.get(opts, :timeout, :NO_TIMEOUT))} — the stream would then " <>
                 "inherit that budget, not :infinity"
      end
    end
  end

  # ── transport: file-to-file packing (PDS-D204/D207) ──────────────────────────

  describe "transport parity (PDS-D204/D207)" do
    test "export_to_file/2 produces the same bundle export/2 does and leaves NO spill behind" do
      %{ws_a: ws_a} = seed_two_workspaces!()
      dir = Archive.spill_dir()
      before = spill_files(dir)

      {:ok, path} = WorkspaceBundle.export_to_file(ws_a.id)

      try do
        assert String.starts_with?(Path.basename(path), "bp-ws-bundle-"),
               "the janitor sweeps by prefix; got #{Path.basename(path)}"

        # Every per-table spill was deleted the MOMENT it was added to the tar.
        assert spill_files(dir) -- before == [],
               "streamed spills survived the export: #{inspect(spill_files(dir) -- before)}"

        {manifest, dumps} = Archive.unpack(File.read!(path))
        assert manifest["format"] == "bp-export-v1"

        # THE CHARLIST TRIPWIRE (PDS-D207d). The manifest md5 is folded
        # incrementally over the bytes the producer STREAMED; this compares it
        # against the bytes the tar actually CARRIES. `:erl_tar.add/4` treats a
        # binary as content and a charlist as a filename, so a string path would
        # silently archive the path TEXT as the member body — with no error, and
        # every one of these md5s would diverge.
        for %{"name" => table, "md5" => md5} <- manifest["tables"] do
          assert :crypto.hash(:md5, dumps[table]) |> Base.encode16(case: :lower) == md5,
                 "member #{table}: the archived body is not the bytes the producer hashed"
        end
      after
        File.rm(path)
      end
    end

    # The engine itself stamps the REAL export time, so it is deliberately NOT
    # self-reproducible: two identical-input exports a second apart differ in
    # their tar headers. An unpinned two-export `cmp` would therefore red
    # against the CURRENT engine and be misread as a regression. Pin the mtime
    # and the packing becomes deterministic — and the third pack proves this
    # assertion can still FAIL, i.e. that it is genuinely reading header bytes.
    test "the same members packed twice with the SAME pinned mtime are byte-identical" do
      dir = Archive.spill_dir()
      manifest = %{"format" => "bp-export-v1", "grain" => "workspace", "tables" => []}
      body = String.duplicate("42\tsome-copy-row-value\n", 500)

      pack_at = fn mtime ->
        # A fresh spill each time: pack/3 CONSUMES what it adds.
        spill = Archive.spill_path(dir, "documents")
        File.write!(spill, body)
        Archive.pack(manifest, %{"documents" => spill}, dir: dir, mtime: mtime)
      end

      a = pack_at.(1_700_000_000)
      b = pack_at.(1_700_000_000)
      c = pack_at.(1_700_000_001)

      try do
        assert File.read!(a) == File.read!(b)
        refute File.read!(a) == File.read!(c)
      after
        Enum.each([a, b, c], &File.rm/1)
      end
    end

    test "the spill dir assertion REFUSES a memory-backed filesystem" do
      mounts = [{"/", "ext4"}, {"/dev/shm", "tmpfs"}]

      assert :ok = Archive.assert_not_tmpfs!("/var/lib/barkpark/spill", mounts)

      # Longest matching mount point wins, so /dev/shm beats / …
      assert_raise ArgumentError, ~r/tmpfs/, fn ->
        Archive.assert_not_tmpfs!("/dev/shm/bp-spill", mounts)
      end

      # …and the boundary is a path SEGMENT: /dev/shmx is not under /dev/shm.
      assert :ok = Archive.assert_not_tmpfs!("/dev/shmx/bp-spill", mounts)

      # A host with no /proc/mounts (macOS) abstains rather than guessing.
      assert :ok = Archive.assert_not_tmpfs!("/anywhere", [])
    end
  end

  # ── bounded import: spill the body, extract to disk (pds-bl-bounded-import) ──

  describe "bounded import (PDS wave 23)" do
    test "unpack_to_dir/2 answers the SAME manifest and members as unpack/1, and every " <>
           "per-table md5 folds INCREMENTALLY off disk — and can still FAIL" do
      %{ws_a: ws_a} = seed_two_workspaces!()
      {:ok, bundle_path} = WorkspaceBundle.export_to_file(ws_a.id)
      dir = Path.join(Archive.spill_dir(), "unpack-to-dir-#{System.unique_integer([:positive])}")

      try do
        # The binary shape (the one the tenancy tripwires read) …
        {manifest_bin, dumps_bin} = Archive.unpack(File.read!(bundle_path))
        # … and the disk shape.
        {manifest_disk, paths} = Archive.unpack_to_dir(bundle_path, dir)

        assert manifest_disk == manifest_bin
        assert Map.keys(paths) |> Enum.sort() == Map.keys(dumps_bin) |> Enum.sort()

        # Same member NAMES, same member BYTES — proven by md5 folded over
        # File.stream!, never :crypto.hash(:md5, File.read!(path)), which would
        # pass while re-materialising the very 1.31 GB member this path exists
        # to keep out of the BEAM.
        for %{"name" => table, "md5" => md5} <- manifest_disk["tables"],
            path = paths[table],
            not is_nil(path) do
          assert md5_stream(path) == md5,
                 "member #{table}: on-disk bytes do not match the manifest md5"

          assert md5_stream(path) ==
                   :crypto.hash(:md5, dumps_bin[table]) |> Base.encode16(case: :lower)
        end

        # PROVE THE FOLD CAN FAIL. A tripwire that cannot red is decoration:
        # mutate one member ON DISK by a single byte and the same fold must
        # diverge from the manifest.
        [{table, path} | _] =
          paths
          |> Enum.filter(fn {_t, p} -> File.stat!(p).size > 0 end)
          |> Enum.sort()

        original = md5_stream(path)
        File.write!(path, "x", [:append])

        refute md5_stream(path) == original,
               "appending a byte to member #{table} did not change the streamed md5 — " <>
                 "the fold is not reading the file"

        refute md5_stream(path) ==
                 Enum.find_value(manifest_disk["tables"], fn
                   %{"name" => ^table, "md5" => md5} -> md5
                   _ -> nil
                 end)
      after
        File.rm_rf(dir)
        File.rm(bundle_path)
      end
    end

    test "unpack/1 KEEPS its binary contract, so the 25 cross-tenant refutes stay real" do
      %{ws_a: ws_a} = seed_two_workspaces!()
      {:ok, bundle} = WorkspaceBundle.export(ws_a.id)
      {_manifest, dumps} = Archive.unpack(bundle)

      # Every value is BYTES. If this ever became %{table => path}, every
      # `refute dumps[t] =~ "<marker>"` below would pass vacuously — the marker
      # is in the file, not in its name.
      for {table, value} <- dumps do
        assert is_binary(value), "dumps[#{inspect(table)}] must be COPY bytes, not a path"
      end

      # The vacuity itself, demonstrated rather than argued: A's own id is IN
      # A's documents bytes, and it is NOT in the path that would name them.
      assert dumps["documents"] =~ ws_a.id

      fake_path_shape = Map.new(dumps, fn {t, _} -> {t, "/tmp/tables/#{t}.copy"} end)
      refute fake_path_shape["documents"] =~ ws_a.id

      # THE COUNT, STATED. Twenty-five `refute dumps[…] =~ …` cross-tenant
      # isolation tripwires ride this contract across the two bundle suites. If a
      # future change flips `unpack/1` to paths, they all go quietly green — so
      # the count is pinned here, in the same file, next to the reason.
      #
      # 20 -> 25 (PDS-D74): the bare-slug E3 fidelity block added five, all under
      # a cross-tenant-SHARED dataset slug — one that the sibling's `shares` row
      # never travels, two that neither workspace's unattributable
      # `preview_token_jti` rows do, and two more proving a dataset-scoped pull
      # neither widens nor leaks. Raised deliberately, not to make a red go away.
      counted =
        for file <- [
              "test/barkpark/tenancy/workspace_bundle_test.exs",
              "test/barkpark/tenancy/workspace_bundle_dev_profile_test.exs"
            ],
            line <- File.stream!(file),
            not String.starts_with?(String.trim_leading(line), "#"),
            String.match?(line, ~r/refute\s+\w*dumps\[/),
            reduce: 0 do
          n -> n + 1
        end

      assert counted == 25,
             "expected 25 `refute …dumps[…]` cross-tenant tripwires riding unpack/1's " <>
               "binary contract; found #{counted}. If you added or removed one, update this " <>
               "count deliberately — do not delete the assertion."
    end

    test "import_bundle_file/2 restores the same rows import_bundle/2 does, streaming " <>
           "each member off disk, and leaves NO scratch behind" do
      %{ws_a: ws_a} = seed_two_workspaces!()

      {:ok, bundle} = WorkspaceBundle.export(ws_a.id)
      {manifest, _} = Archive.unpack(bundle)
      {:ok, bundle_path} = WorkspaceBundle.export_to_file(ws_a.id)

      docs_before =
        scalar("SELECT count(*) FROM documents WHERE workspace_id=$1::text::uuid", [ws_a.id])

      assert docs_before > 0

      purge_workspace!(ws_a.id, manifest)

      assert scalar("SELECT count(*) FROM documents WHERE workspace_id=$1::text::uuid", [ws_a.id]) ==
               0

      spill_dir = Archive.spill_dir()
      scratch_before = scratch_dirs(spill_dir)

      try do
        assert {:ok, stats} = WorkspaceBundle.import_bundle_file(bundle_path)
        assert stats.total_rows > 0
        assert stats.manifest["format"] == "bp-export-v1"

        assert scalar("SELECT count(*) FROM documents WHERE workspace_id=$1::text::uuid", [
                 ws_a.id
               ]) == docs_before

        assert_no_orphans!()

        # The extraction directory is gone — no member survives the import.
        assert scratch_dirs(spill_dir) == scratch_before

        assert Path.wildcard(Path.join(Path.dirname(bundle_path), "members-*")) == [],
               "an extraction directory survived import_bundle_file/2"
      after
        File.rm(bundle_path)
      end
    end

    test "a member name that escapes the extraction root is REFUSED BY NAME, and nothing " <>
           "is written outside the root" do
      root = Path.join(Archive.spill_dir(), "traversal-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      outside = Path.join(root, "outside")
      dir = Path.join(root, "extract")
      File.mkdir_p!(outside)

      try do
        for evil <- [~c"../../evil.copy", ~c"tables/../../evil.copy", ~c"/etc/evil.copy"] do
          path = hand_packed_tar(root, evil)

          e =
            assert_raise Barkpark.Tenancy.WorkspaceBundle.InvalidBundleError, fn ->
              Archive.unpack_to_dir(path, dir)
            end

          assert e.code == "invalid_bundle"

          assert e.message =~ "evil.copy",
                 "the refusal must NAME the offending member; got: #{e.message}"

          File.rm(path)
        end

        # A DIRECTORY member is refused on type, not name — a symlink/dir member
        # is the other way a tar escapes a cwd.
        dirmember = hand_packed_tar(root, {:dir, outside})

        assert_raise Barkpark.Tenancy.WorkspaceBundle.InvalidBundleError,
                     ~r/not a regular file/,
                     fn ->
                       Archive.unpack_to_dir(dirmember, dir)
                     end

        # Refused BEFORE extraction: not one byte landed.
        refute File.exists?(Path.join(root, "evil.copy"))
        assert File.ls!(outside) == []
        assert (File.exists?(dir) and File.ls!(dir) == []) or not File.exists?(dir)
      after
        File.rm_rf(root)
      end
    end

    test "the free-space precondition refuses BEFORE the spill, and says so when it cannot " <>
           "be performed" do
      dir = Archive.spill_dir()

      assert {:ok, free} = Archive.free_space(dir)
      assert free > 0

      # NEAR, not EQUAL. `free` was read by a previous syscall, and the disk under
      # a CI runner moves between two reads: this assertion was `^free` and failed
      # by 24_576 bytes on #8222, reddening a dependency bump that had nothing to
      # do with it. A test that can fail for a reason other than the one it
      # measures is worse than no test, because its red teaches people to re-run.
      #
      # The property is still asserted, and the tolerance is still tight enough to
      # catch every way this could go wrong: a hardcoded 0, a constant, the
      # REQUIRED bytes echoed back, or a reading of a different filesystem would
      # all be orders of magnitude outside 64 MiB on a volume with ~85 GiB free.
      drift = 64 * 1024 * 1024

      # Sufficient → verified, with a fresh reading of the same filesystem.
      assert {:ok, {:verified, verified}} = Archive.check_free_space(dir, 1)
      assert_in_delta verified, free, drift

      # Short → a NAMED refusal carrying both sides of the comparison.
      assert {:error, {:insufficient_disk_space, info}} =
               Archive.check_free_space(dir, free + 1_000_000)

      assert_in_delta info.free_bytes, free, drift
      assert info.required_bytes == free + 1_000_000
      assert info.dir == dir

      # Unperformable → says so, never a silent pass dressed as a check.
      assert {:ok, {:unverified, reason}} = Archive.check_free_space("/no/such/dir/at/all", 1)
      assert reason in [:df_failed, :df_unparsable, :df_unavailable]
    end

    test "the janitor collects an abandoned import scratch DIRECTORY" do
      dir = Path.join(Archive.spill_dir(), "janitor-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      try do
        scratch = Path.join(dir, "#{Archive.scratch_prefix()}999")
        File.mkdir_p!(Path.join(scratch, "members-1"))
        File.write!(Path.join(scratch, "body.tar"), "x")
        File.write!(Path.join([scratch, "members-1", "documents.copy"]), "y")

        old = System.os_time(:second) - 10_000
        File.touch!(scratch, old)

        assert {:ok, %{removed: removed}} =
                 Barkpark.Tenancy.WorkspaceBundle.Janitor.sweep(dir: dir, max_age_seconds: 60)

        assert scratch in removed,
               "the janitor did not collect the scratch DIRECTORY #{scratch}"

        refute File.exists?(scratch)
      after
        File.rm_rf(dir)
      end
    end

    @tag timeout: 300_000
    test "MEASURED: the disk path peaks at ~1x the largest member, not ~3x the archive" do
      dir = Path.join(Archive.spill_dir(), "measure-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      # One dominant member, so "1x the largest member" is a number this fixture
      # can actually show. 48 MiB — big enough that the binary path's ~3x is far
      # outside sampling noise, small enough to stay a unit test.
      member_bytes = 48 * 1024 * 1024
      spill = Archive.spill_path(dir, "documents")
      File.write!(spill, String.duplicate("0123456789abcdef", div(member_bytes, 16)))

      manifest = %{"format" => "bp-export-v1", "grain" => "workspace", "tables" => []}
      path = Archive.pack(manifest, %{"documents" => spill}, dir: dir)

      try do
        binary_peak = peak_bytes(fn -> Archive.unpack(File.read!(path)) end)

        disk_peak =
          peak_bytes(fn ->
            out = Path.join(dir, "out-#{System.unique_integer([:positive])}")
            Archive.unpack_to_dir(path, out)
            File.rm_rf(out)
          end)

        IO.puts(
          "\n[pds-bl-bounded-import-unpack] MEASURED, this run, on a #{member_bytes}-byte " <>
            "largest member (OTP #{System.otp_release()}): " <>
            "unpack/1 (binary, [:memory]) peak=#{binary_peak} B = " <>
            "#{Float.round(binary_peak / member_bytes, 2)}x the largest member · " <>
            "unpack_to_dir/2 peak=#{disk_peak} B = " <>
            "#{Float.round(disk_peak / member_bytes, 2)}x. " <>
            "THE CLAIM IS '1x THE LARGEST MEMBER', NEVER 'CONSTANT MEMORY'. Runs of this " <>
            "test have measured the disk path anywhere from 0.01x to 1.01x — the spread " <>
            "IS the point: :erl_tar exposes no chunked EXTRACT API, so whether a given " <>
            "member is held whole is an implementation detail, and 1x the largest member " <>
            "is the bound actually owed. On guerrilla that is ~1.31 GB (mutation_events) " <>
            "— RE-MEASURE rather than quoting: the database grew 63.6 MB in one day."
        )

        assert disk_peak < binary_peak,
               "unpack_to_dir/2 peaked at #{disk_peak} B, no better than unpack/1's " <>
                 "#{binary_peak} B"

        # The bound is 1x the largest member; the sampler is a 1 ms poll over a
        # shared VM, so the assertion carries one member of slack rather than
        # sitting exactly on the number it is measuring.
        assert disk_peak < 2 * member_bytes,
               "unpack_to_dir/2 peaked at #{disk_peak} B = " <>
                 "#{Float.round(disk_peak / member_bytes, 2)}x the largest member — past " <>
                 "the 1x bound this slice claims (plus slack)"

        assert binary_peak > div(3 * member_bytes, 2),
               "the binary path measured #{Float.round(binary_peak / member_bytes, 2)}x — " <>
                 "if it is no longer a multiple of the archive, re-derive the comparison " <>
                 "rather than keeping this number"
      after
        File.rm_rf(dir)
      end
    end
  end

  # ── catalog-membership guard on the import path (felix-w25-s3, D165) ─────────
  #
  # NAMED FAILURE MODE: a manifest-named table reaches the interpolated
  # COPY/INSERT path with no membership check — `qi/1` quotes the identifier
  # but never restricts WHICH table, and the import loop filters only by
  # `table_exists?/1`. The export enumerates members PURELY from
  # `[root] ++ live_e1/e2/e3 ++ allowlist keys`, so a manifest naming any
  # other EXISTING table is crafted/foreign by construction. With the guard
  # ABSENT these two tests red: the hostile one because the import proceeds
  # into the write path instead of refusing, and that asymmetry is the
  # RED-BEFORE proof this guard is graded against.

  describe "import refuses tables the export could never have written (felix-w25-s3)" do
    test "a crafted manifest naming users + schema_migrations is refused invalid_bundle BEFORE any COPY/INSERT" do
      %{ws_a: ws_a} = seed_two_workspaces!()

      {:ok, bundle} = WorkspaceBundle.export(ws_a.id)
      {manifest, dumps} = Archive.unpack(bundle)

      # Ground truth first: no export enumeration emits either hostile table —
      # neither carries workspace_id, a workspaces-FK chain, nor `dataset`.
      exported = Enum.map(manifest["tables"], & &1["name"])
      refute "users" in exported
      refute "schema_migrations" in exported

      # Both dumps are VALID COPY text for their live table, so absent the
      # guard neither would fail on shape — they would LAND.
      hostile_version = 99_999_999_999_999
      hostile_email = "hostile-#{System.unique_integer([:positive])}@example.com"

      hostile_members = [
        %{
          "name" => "schema_migrations",
          "partition" => "E1",
          "import_strategy" => "copy",
          "columns" => ["version", "inserted_at"],
          "order_columns" => ["version"],
          "row_count" => 1,
          "md5" => "unchecked-on-import"
        },
        %{
          "name" => "users",
          "partition" => "E1",
          "import_strategy" => "copy",
          "columns" => [
            "id",
            "email",
            "hashed_password",
            "totp_enabled",
            "recovery_codes_hashed",
            "inserted_at",
            "updated_at"
          ],
          "order_columns" => ["id"],
          "row_count" => 1,
          "md5" => "unchecked-on-import"
        }
      ]

      hostile_dumps = %{
        "schema_migrations" => "#{hostile_version}\t2026-01-01 00:00:00\n",
        "users" =>
          Enum.join(
            [
              Ecto.UUID.generate(),
              hostile_email,
              "$argon2id$fake",
              "f",
              "{}",
              "2026-01-01 00:00:00",
              "2026-01-01 00:00:00"
            ],
            "\t"
          ) <> "\n"
      }

      hostile_bundle =
        repack(
          Map.put(manifest, "tables", manifest["tables"] ++ hostile_members),
          Map.merge(dumps, hostile_dumps)
        )

      users_before = scalar("SELECT count(*) FROM users", [])

      err =
        assert_raise WorkspaceBundle.InvalidBundleError, fn ->
          WorkspaceBundle.import_bundle(hostile_bundle, mode: :merge)
        end

      # The refusal rides the existing 422 invalid_bundle oracle and NAMES the
      # foreign tables.
      assert err.code == "invalid_bundle"
      assert err.message =~ "schema_migrations"
      assert err.message =~ "users"

      # …and it fired BEFORE any write: neither hostile row exists.
      assert scalar("SELECT count(*) FROM schema_migrations WHERE version = $1", [
               hostile_version
             ]) == 0

      assert scalar("SELECT count(*) FROM users", []) == users_before
    end

    test "a member table ABSENT on the target keeps the cross-version 0-row skip — the guard gates membership, table_exists?/1 gates existence" do
      %{ws_a: ws_a} = seed_two_workspaces!()

      {:ok, bundle} = WorkspaceBundle.export(ws_a.id)
      {manifest, dumps} = Archive.unpack(bundle)

      # A future schema version's member: unknown to this target, 0 rows —
      # exactly the cross-version shape today's import skips silently.
      future_member = %{
        "name" => "bp_future_member_table",
        "partition" => "E1",
        "import_strategy" => "copy",
        "columns" => ["id"],
        "order_columns" => ["id"],
        "row_count" => 0,
        "md5" => "d41d8cd98f00b204e9800998ecf8427e"
      }

      cross_version =
        repack(Map.put(manifest, "tables", manifest["tables"] ++ [future_member]), dumps)

      assert {:ok, stats} = WorkspaceBundle.import_bundle(cross_version, mode: :merge)
      assert stats.tables["bp_future_member_table"] == 0
    end
  end

  # ── the membership guard is not schema-blind (felix-w27, pg_catalog) ─────────
  #
  # NAMED FAILURE MODE: schema-blind existence filter. The felix-w25-s3 guard
  # above rejects foreign PUBLIC tables, but `table_exists?/1` classified by
  # `nspname = 'public'` while the unqualified COPY in the import path resolves
  # via search_path (pg_catalog implicit-FIRST) — so a crafted manifest naming
  # a pg_catalog relation (pg_authid, the role/password table) was FILTERED OUT
  # of `assert_member_tables!/1`'s `foreign` set instead of refused.
  #
  # RED-BEFORE (recorded venue: this header comment; also the commit body):
  # against the unmodified nspname='public' table_exists?/1, the probe below
  # FAILS with "Expected exception Barkpark.Tenancy.WorkspaceBundle.
  # InvalidBundleError but nothing was raised" — the hostile member imports
  # (0-row silent skip). Green-after: the search-path-visibility rewrite keeps
  # pg_authid in `foreign` and refuses it before any COPY/INSERT/DDL.
  describe "import refuses pg_catalog relations — the membership guard is search-path-aware (felix-w27)" do
    test "a crafted manifest appending pg_authid is refused invalid_bundle naming pg_authid" do
      # Role-independent on purpose: row_count 0 means the refusal is asserted
      # without ever writing (or reading) pg_authid, so the probe passes under
      # non-superuser prod-host test roles.
      %{ws_a: ws_a} = seed_two_workspaces!()

      {:ok, bundle} = WorkspaceBundle.export(ws_a.id)
      {manifest, dumps} = Archive.unpack(bundle)

      # Ground truth first: no export enumeration ever emits a pg_catalog
      # relation — a manifest naming one is crafted/foreign by construction.
      refute "pg_authid" in Enum.map(manifest["tables"], & &1["name"])

      hostile_member = %{
        "name" => "pg_authid",
        "partition" => "E1",
        "import_strategy" => "copy",
        "columns" => ["rolname"],
        "order_columns" => ["rolname"],
        "row_count" => 0,
        "md5" => "d41d8cd98f00b204e9800998ecf8427e"
      }

      hostile_bundle =
        repack(Map.put(manifest, "tables", manifest["tables"] ++ [hostile_member]), dumps)

      err =
        assert_raise WorkspaceBundle.InvalidBundleError, fn ->
          WorkspaceBundle.import_bundle(hostile_bundle, mode: :merge)
        end

      # The refusal rides the existing 422 invalid_bundle oracle and NAMES the
      # pg_catalog relation.
      assert err.code == "invalid_bundle"
      assert err.message =~ "pg_authid"
    end
  end

  # Re-pack a (possibly tampered) manifest + in-memory dumps into a bundle
  # binary, through the SAME Archive.pack/3 the engine uses.
  defp repack(manifest, dumps) do
    dir = Archive.spill_dir()

    files =
      Map.new(dumps, fn {table, body} ->
        spill = Archive.spill_path(dir, table)
        File.write!(spill, body)
        {table, spill}
      end)

    path = Archive.pack(manifest, files, dir: dir)

    try do
      File.read!(path)
    after
      File.rm(path)
    end
  end

  # md5 folded over a stream, never over File.read!/1 — the whole point is that
  # no member is ever a binary in the BEAM.
  defp md5_stream(path) do
    path
    |> File.stream!(65_536)
    |> Enum.reduce(:crypto.hash_init(:md5), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp scratch_dirs(dir) do
    dir
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, Archive.scratch_prefix()))
    |> Enum.sort()
  end

  # A tar the ENGINE would never produce: a hostile member name (or a directory
  # member) beside a valid manifest.
  defp hand_packed_tar(dir, member) do
    path = Path.join(dir, "hostile-#{System.unique_integer([:positive])}.tar")
    {:ok, tar} = :erl_tar.open(String.to_charlist(path), [:write])

    try do
      :ok = :erl_tar.add(tar, Jason.encode!(%{"format" => "bp-export-v1"}), ~c"manifest.json", [])

      case member do
        {:dir, real} -> :ok = :erl_tar.add(tar, String.to_charlist(real), ~c"tables", [])
        name -> :ok = :erl_tar.add(tar, "row\n", name, [])
      end
    after
      :erl_tar.close(tar)
    end

    path
  end

  # Peak `:erlang.memory(:total)` above baseline while `fun` runs, sampled from a
  # separate process (the traced one is too busy to sample itself).
  defp peak_bytes(fun) do
    :erlang.garbage_collect()
    baseline = :erlang.memory(:total)
    me = self()
    sampler = spawn_link(fn -> sample(me, baseline, 0) end)

    try do
      fun.()
    after
      send(sampler, {:stop, self()})
    end

    receive do
      {:peak, peak} -> peak
    after
      5_000 -> flunk("the memory sampler never answered")
    end
  end

  defp sample(parent, baseline, peak) do
    receive do
      {:stop, pid} -> send(pid, {:peak, peak})
    after
      1 ->
        sample(parent, baseline, max(peak, :erlang.memory(:total) - baseline))
    end
  end

  defp spill_files(dir) do
    dir |> File.ls!() |> Enum.filter(&String.starts_with?(&1, "bp-ws-spill-")) |> Enum.sort()
  end

  # Call-trace `Barkpark.Repo.transaction/2` for the duration of `fun`,
  # returning each call's OPTS in call order. `:erlang.trace/3` is the only
  # seam that observes the options argument — Ecto's telemetry metadata carries
  # `:telemetry_options`, not the caller's `:timeout`. The tracer MUST be a
  # separate process: with the traced process as its own tracer, OTP accepts
  # the call and silently delivers nothing (measured).
  defp trace_repo_transaction(fun) do
    me = self()
    tracer = spawn_link(fn -> trace_collector([], me) end)

    :erlang.trace_pattern({Repo, :transaction, 2}, true, [:local])
    :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    try do
      fun.()
    after
      :erlang.trace(self(), false, [:call])
      :erlang.trace_pattern({Repo, :transaction, 2}, false, [:local])
    end

    send(tracer, {:dump, me})

    receive do
      {:traced, msgs} ->
        for {:trace, _pid, :call, {_m, :transaction, [fun_or_multi, opts]}} <- msgs,
            is_function(fun_or_multi),
            do: opts
    after
      5_000 -> flunk("the trace collector never answered")
    end
  end

  defp trace_collector(acc, parent) do
    receive do
      {:dump, pid} -> send(pid, {:traced, Enum.reverse(acc)})
      msg -> trace_collector([msg | acc], parent)
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

    # E1 (charter D55): A's sync cursor, attributed to A via workspace_id.
    Repo.query!(
      "INSERT INTO sync_cursors (workspace_id, source, dataset, inserted_at, updated_at) " <>
        "VALUES ($1::text::uuid, 'sync-a', 'prod-a', now(), now())",
      [ws_a.id]
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

  # ── engine ⇄ janitor handshake (pds-w11-janitor-engine-handshake) ────────────

  describe "the engine writes where the janitor sweeps, and marks liveness while it does" do
    test "a REAL export lands in Janitor.spill_dir/0 and is a live-owned sweep candidate" do
      %{ws_a: ws_a} = seed_two_workspaces!()

      # THE HANDSHAKE, end to end. Two modules built in parallel against a PROSE
      # contract: the janitor sweeps a configured directory, the engine writes to
      # one. Nothing proved they were the SAME directory — and a janitor pointed
      # one level off sweeps an empty dir and reports a clean green forever while
      # the spills pile up somewhere else.
      {:ok, path} = WorkspaceBundle.export_to_file(ws_a.id)

      try do
        assert Path.dirname(path) == Janitor.spill_dir(),
               "the engine wrote its bundle to #{Path.dirname(path)} but the janitor sweeps " <>
                 "#{Janitor.spill_dir()} — the sweep would be a permanent no-op"

        assert File.read!(path <> ".owner") == System.pid(),
               "the sidecar must carry THIS os process's pid, or the liveness check is guessing"

        # Age it past the threshold so the sweep genuinely WANTS it. Without
        # this the assertion below is vacuous: a freshly written file fails the
        # strictly-older-than cutoff and survives for a reason that has nothing
        # to do with ownership.
        File.touch!(path, System.os_time(:second) - 7200)

        assert {:ok, guarded} = Janitor.sweep(dir: Path.dirname(path), max_age_seconds: 3600)

        # THE LIVENESS GUARD on a real artifact. `own/1` had ZERO callers in
        # api/lib before this slice, so this could not have been asserted at all:
        # the sweep would have eaten a bundle this very process is still holding.
        assert File.exists?(path),
               "a live-owned bundle was reaped by the sweep — the export engine is not " <>
                 "writing the ownership sidecar"

        refute path in guarded.removed

        assert guarded.skipped_live >= 1,
               "the bundle survived, but not via the LIVENESS branch — skipped_live was 0, so " <>
                 "something else spared it and this proves nothing about ownership"

        # And the control that makes the line above mean something: drop the
        # sidecar and the SAME sweep takes it. If this collected nothing, the
        # survival above would prove only that the file was never a candidate.
        Janitor.disown(path)

        assert {:ok, unguarded} = Janitor.sweep(dir: Path.dirname(path), max_age_seconds: 3600)

        refute File.exists?(path),
               "an unowned, over-age bundle survived — then the sweep never had it in range " <>
                 "and the guarded assertion above was vacuous"

        assert path in unguarded.removed
      after
        File.rm(path)
        Janitor.disown(path)
      end
    end

    test "the caller that deletes the bundle is the one that disowns it — no sidecar is stranded" do
      %{ws_a: ws_a} = seed_two_workspaces!()

      {:ok, path} = WorkspaceBundle.export_to_file(ws_a.id)
      assert File.exists?(path <> ".owner")

      File.rm(path)
      Janitor.disown(path)

      # A sidecar outliving its subject is litter the sweep is STRUCTURALLY
      # unable to collect: `candidates/1` rejects `.owner` entries by design, so
      # they are only ever removed alongside the file they name.
      refute File.exists?(path <> ".owner"),
             "the ownership sidecar outlived its bundle — the janitor can never collect it alone"
    end

    test "export/2 leaves NO owner sidecar behind — it deletes the tar, so it disowns it" do
      %{ws_a: ws_a} = seed_two_workspaces!()

      # ORPHANS ONLY — a sidecar whose subject still exists belongs to a live
      # export, possibly another test's. Counting every `.owner` would make this
      # flake against concurrent work while proving nothing extra: the invariant
      # is "no sidecar outlives its file", not "no sidecar exists". Diffed
      # against a before-snapshot as well, so pre-existing debris cannot convict.
      orphans = fn ->
        Janitor.spill_dir()
        |> Path.join("*.owner")
        |> Path.wildcard()
        |> Enum.reject(&File.exists?(String.replace_suffix(&1, ".owner", "")))
        |> MapSet.new()
      end

      before = orphans.()

      {:ok, _bundle} = WorkspaceBundle.export(ws_a.id)

      leaked = MapSet.difference(orphans.(), before)

      assert MapSet.size(leaked) == 0,
             "export/2 deleted its tar but stranded #{MapSet.size(leaked)} ownership " <>
               "sidecar(s) the janitor can never collect alone: " <>
               "#{inspect(MapSet.to_list(leaked))}"
    end
  end

  # ── bare-slug E3 fidelity fixture (PDS-D45/D74) ──────────────────────────────

  # Two workspaces colliding on ONE dataset slug, with a bare-slug E3 row of each
  # kind on BOTH sides of the collision plus an exclusive-slug control. This is
  # the shape guerrilla is in today (`production` owned by both `default` and
  # `gyldendal`), reduced to a fixture.
  defp seed_shared_slug_fixture! do
    ws_a = create_workspace!(unique("wsa"))
    proj_a = create_project!(ws_a, unique("proja"))
    ws_b = create_workspace!(unique("wsb"))
    proj_b = create_project!(ws_b, unique("projb"))

    tag = System.unique_integer([:positive])
    shared = "shared-prod-#{tag}"
    excl = "excl-a-#{tag}"

    seed_dataset!(proj_a.id, excl)
    seed_dataset!(proj_a.id, shared)
    seed_dataset!(proj_b.id, shared)

    # `shares` — attributable: it carries workspace_slug + project_slug + dataset.
    a_shared = insert_share!(ws_a.slug, proj_a.slug, shared)
    a_excl = insert_share!(ws_a.slug, proj_a.slug, excl)
    b_shared = insert_share!(ws_b.slug, proj_b.slug, shared)

    # `preview_token_jti` — unattributable: a bare `dataset` string is all it has.
    a_shared_jti = "A-SHARED-JTI-#{tag}"
    b_shared_jti = "B-SHARED-JTI-#{tag}"
    a_excl_jti = "A-EXCL-JTI-#{tag}"
    insert_preview_jti!(a_shared_jti, shared)
    insert_preview_jti!(b_shared_jti, shared)
    insert_preview_jti!(a_excl_jti, excl)

    %{
      ws_a: ws_a,
      ws_b: ws_b,
      proj_a: proj_a,
      proj_b: proj_b,
      tag: tag,
      shared: shared,
      excl: excl,
      a_shared_share_id: a_shared,
      a_excl_share_id: a_excl,
      b_shared_share_id: b_shared,
      a_shared_jti: a_shared_jti,
      b_shared_jti: b_shared_jti,
      a_excl_jti: a_excl_jti
    }
  end

  defp insert_share!(workspace_slug, project_slug, dataset) do
    %{rows: [[id]]} =
      Repo.query!(
        "INSERT INTO shares (id, workspace_slug, project_slug, dataset, surfaces, access, " <>
          "inserted_at, updated_at) VALUES (gen_random_uuid(), $1, $2, $3, ARRAY['docs'], " <>
          "'read', now(), now()) RETURNING id::text",
        [workspace_slug, project_slug, dataset]
      )

    id
  end

  # Every dataset slug under the workspace's projects — the OWNED set, which is a
  # SUPERSET of `dataset_slugs_for/1`'s workspace-EXCLUSIVE set. The gap between
  # the two is exactly the population the fidelity block is about.
  defp owned_slugs(ws_id) do
    Repo.query!(
      "SELECT DISTINCT d.slug FROM datasets d JOIN projects p ON p.id = d.project_id " <>
        "WHERE p.workspace_id = $1::text::uuid",
      [ws_id]
    ).rows
    |> List.flatten()
  end

  defp declared_loss_index(manifest),
    do: Map.new(manifest["declared_loss"] || [], &{&1["table"], &1})

  # `id` is the first column of `shares` (Catalog.non_generated_columns returns
  # ordinal order), so the leading tab-separated field of each COPY line is it.
  defp share_ids_in(dump) do
    dump
    |> String.split("\n", trim: true)
    |> Enum.map(&(&1 |> String.split("\t") |> hd()))
  end

  defp seed_dataset!(project_id, slug) do
    Repo.query!(
      "INSERT INTO datasets (id, project_id, slug, name, inserted_at, updated_at) " <>
        "VALUES (gen_random_uuid(), $1::text::uuid, $2, $2, now(), now())",
      [project_id, slug]
    )
  end

  # E3-dataset / allowlist bare-slug raw seed helpers (bpb-e3-dataset-slug-collision).
  # preview_token_jti is the E3-dataset exemplar (the sync_* family moved to E1 — D55).
  defp insert_preview_jti!(jti, dataset) do
    Repo.query!(
      "INSERT INTO preview_token_jti (jti, dataset, issued_at, expires_at) " <>
        "VALUES ($1, $2, now(), now() + interval '1 hour')",
      [jti, dataset]
    )
  end

  # A workspace-attributed sync_cursors row (charter D55 — sync_* is E1 now).
  defp insert_sync_cursor_ws!(ws_id, source, dataset) do
    Repo.query!(
      "INSERT INTO sync_cursors (workspace_id, source, dataset, event_id, inserted_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2, $3, 0, now(), now())",
      [ws_id, source, dataset]
    )
  end

  # `workspace_id` attributes the DEK to a workspace (E1 path); `version` keeps
  # sibling rows under the SAME shared scope distinct for the
  # `(workspace_id, scope, version)` unique index. A `nil` workspace_id is a
  # legacy/dormant DEK, intentionally excluded from a per-workspace bundle.
  defp insert_data_key!(scope, ciphertext, workspace_id \\ nil, version \\ 1) do
    Repo.query!(
      "INSERT INTO data_keys (id, scope, version, wrapped_key, workspace_id, inserted_at, updated_at) " <>
        "VALUES (gen_random_uuid(), $1, $4, $2, $3::text::uuid, now(), now())",
      [scope, ciphertext, workspace_id, version]
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
    cond do
      t in Catalog.e3_doc_keyed() ->
        scalar(
          "SELECT count(*) FROM #{quote_ident(t)} x WHERE EXISTS (SELECT 1 FROM documents d " <>
            "WHERE d.workspace_id = $1::text::uuid AND d.doc_id = x.doc_id AND d.dataset = x.dataset)",
          [ws]
        )

      # PDS-D74: an E3-dataset table with its own workspace key is scoped by that
      # key, not by the exclusive slug set. Derived here from the WORKSPACE ROW
      # (id → slug), never from the exporter's literal, so this stays an
      # independent witness rather than a restatement of the implementation.
      col = Map.get(Catalog.e3_dataset_workspace_slug_column(), t) ->
        scalar(
          "SELECT count(*) FROM #{quote_ident(t)} x WHERE x.#{quote_ident(col)} = " <>
            "(SELECT w.slug FROM workspaces w WHERE w.id = $1::text::uuid)",
          [ws]
        )

      true ->
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

  # (path, size) straight from the database, sorted — the target-side reading the
  # blob-fidelity proof does.
  defp media_path_sizes!(ws_id) do
    Repo.query!("SELECT path, size FROM media_files WHERE workspace_id = $1::text::uuid", [ws_id]).rows
    |> Enum.map(fn [path, size] -> {path, size} end)
    |> Enum.sort()
  end

  # The same pairs read out of the bundle's own COPY-text payload (tab-separated,
  # `\N` for NULL), so an export-side drop is convicted in the BYTES.
  defp media_pairs_from_copy(dump, columns) do
    path_idx = Enum.find_index(columns, &(&1 == "path"))
    size_idx = Enum.find_index(columns, &(&1 == "size"))

    dump
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      fields = String.split(line, "\t")
      {Enum.at(fields, path_idx), Enum.at(fields, size_idx)}
    end)
    |> Enum.map(fn
      {path, "\\N"} -> {path, nil}
      {path, size} -> {path, String.to_integer(size)}
    end)
    |> Enum.sort()
  end

  defp scalar(sql, params), do: Repo.query!(sql, params).rows |> hd() |> hd()

  defp quote_ident(ident), do: ~s("#{String.replace(ident, "\"", "\"\"")}")

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
