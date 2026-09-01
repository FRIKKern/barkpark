defmodule Barkpark.TenancyDeleteWorkspaceTest do
  @moduledoc """
  Correctness gate for `Barkpark.Tenancy.delete_workspace/1` — the
  redesign that closes obhg-P0 + 0f7g-P1.

  Pre-redesign:

    * 160000 flipped media_files SQL FKs to delete_all. A raw
      `Repo.delete(workspace)` would remove the row but the SQL CASCADE path
      bypasses `Media.delete_file/2`, leaking the disk blob, the CDN edge
      cache entry, and the `:after_media_delete` plugin notification.
    * 160000 covered four content tables only — webhooks /
      mutation_events / search_intel_events / search_intel_crystals /
      search_intel_merge_patterns / search_synonyms / paper_events still
      carried `nilify_all`, so workspace_id was SET NULL on delete and the
      rows resurfaced under Default.

  This suite proves:

    1. **Blob/CDN/plugin cleanup runs** when `Tenancy.delete_workspace/1`
       deletes a workspace owning a media_file — the file is gone from
       disk, the CDN invalidation HTTP endpoint receives a POST, the
       `:after_media_delete` plugin hook fired, the workspace row is gone.
    2. **Cascade extends to the seven extra tables** — a workspace owning
       a webhook, a search_synonym, a paper_event, and a mutation_event
       has all four rows GONE post-delete, and zero rows survive with
       workspace_id=NULL.
    3. **Atomicity** — a mid-delete failure rolls the whole sequence back;
       the workspace, its document, and its media_file all survive.
    4. **Other-workspace untouched** — a doc / media / webhook in
       workspace B is unaffected by deleting workspace A.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures
  import Ecto.Query

  alias Barkpark.{Content, Media, Repo, Tenancy}
  alias Barkpark.Content.{Document, MutationEvent}
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Plugins.Bulldocs.Event, as: PaperEvent
  alias Barkpark.Search.Synonym
  alias Barkpark.Tenancy.Workspace
  alias Barkpark.Webhooks.Webhook

  @dataset "test"

  # ── plugin / CDN / disk setup ─────────────────────────────────────────────

  defmodule MediaDeleteSpyPlugin do
    @moduledoc """
    Captures after_media_delete invocations. Also halts :before_delete on
    documents flagged with `doc_id == "halt-me"` so the atomicity test can
    force a mid-transaction failure cleanly.
    """

    def manifest do
      %{
        "plugin_name" => "media-delete-spy",
        "version" => "0.0.0"
      }
    end

    def after_media_delete(ctx) do
      case Process.whereis(:tenancy_delete_spy) do
        nil -> :ok
        pid -> send(pid, {:after_media_delete, ctx})
      end

      :ok
    end

    # Match BOTH variants — Content.create_document persists the row as
    # the draft variant (`drafts.<base>`) and Content.delete_document
    # resolves both the published and the draft form.
    def before_delete(%{doc: %{doc_id: doc_id}}) do
      if doc_id in ["halt-me", "drafts.halt-me"] do
        {:halt, "atomicity-test"}
      else
        :ok
      end
    end

    def before_delete(_payload), do: :ok

    # Hooks dispatcher (`Barkpark.Plugins.Hooks.fire/2`) iterates plugins
    # whose `lifecycle_hooks/0` map carries a callable for the event. The
    # `:after_media_delete` notification rides a different path
    # (`Registry.run_after_media_delete/1`, which uses `function_exported?/3`).
    def lifecycle_hooks do
      %{before_delete: [&__MODULE__.before_delete/1]}
    end
  end

  setup do
    # Capture CDN invalidation HTTP calls via Bypass.
    bypass = Bypass.open()
    cdn_url = "http://localhost:#{bypass.port}/purge"

    Application.put_env(:barkpark, :media_cdn,
      base_url: "http://cdn.test",
      invalidation: [adapter: :http, url: cdn_url, secret: "test"]
    )

    # Default: every POST /purge succeeds. Tests that want to ASSERT the
    # call fired use the `cdn_calls` counter and Bypass.expect.
    Bypass.stub(bypass, "POST", "/purge", fn conn ->
      Plug.Conn.resp(conn, 200, "{}")
    end)

    # Subscribe to plugin-hook fire-and-forget messages.
    Process.register(self(), :tenancy_delete_spy)

    :ok =
      Barkpark.Plugins.Registry.register(
        MediaDeleteSpyPlugin,
        MediaDeleteSpyPlugin.manifest()
      )

    on_exit(fn ->
      Application.delete_env(:barkpark, :media_cdn)
      # `Registry.reset/0` snaps back to the boot-time plugin baseline,
      # dropping the spy plugin we registered above. There is no
      # `unregister/1` — plugin topology is compile-time static.
      Barkpark.Plugins.Registry.reset()
    end)

    {:ok, bypass: bypass}
  end

  defp write_temp_upload!(name, body \\ "fake bytes") do
    path =
      Path.join(System.tmp_dir!(), "tenancy-del-#{System.unique_integer([:positive])}-#{name}")

    File.write!(path, body)
    path
  end

  # Upload via the real Media.upload path so the blob hits disk and the
  # row carries workspace scope. Returns {file, on_disk_path}.
  defp upload_media!(ws, project, filename) do
    temp = write_temp_upload!(filename)

    {:ok, file} =
      Media.upload(
        %Plug.Upload{path: temp, filename: filename, content_type: "image/png"},
        @dataset,
        workspace_id: ws.id,
        project_id: project.id
      )

    on_disk = Path.join(Media.upload_dir(), file.path)
    {file, on_disk}
  end

  defp insert_webhook!(ws, project) do
    suffix = System.unique_integer([:positive])

    {:ok, webhook} =
      %Webhook{}
      |> Webhook.changeset(%{
        "name" => "hook-#{suffix}",
        "url" => "https://example.test/#{suffix}",
        "dataset" => @dataset,
        "events" => ["create"],
        "types" => ["post"],
        "workspace_id" => ws.id,
        "project_id" => project.id
      })
      |> Repo.insert()

    webhook
  end

  defp insert_synonym!(ws, project) do
    suffix = System.unique_integer([:positive])

    {:ok, syn} =
      %Synonym{
        surface: "documents",
        scope: @dataset,
        from_query: "from-#{suffix}",
        to_query: "to-#{suffix}",
        workspace_id: ws.id,
        project_id: project.id
      }
      |> Repo.insert()

    syn
  end

  defp insert_paper_event!(ws, project) do
    suffix = System.unique_integer([:positive])

    {:ok, ev} =
      %PaperEvent{
        goal_id: "goal-#{suffix}",
        paper_slug: "paper-#{suffix}",
        event_type: "goal-opened",
        workspace_id: ws.id,
        project_id: project.id
      }
      |> Repo.insert()

    ev
  end

  defp insert_mutation_event!(ws, project) do
    suffix = System.unique_integer([:positive])

    {:ok, mev} =
      Repo.insert(%MutationEvent{
        dataset: @dataset,
        type: "post",
        doc_id: "mev-#{suffix}",
        mutation: "create",
        rev: "rev-#{suffix}",
        document: %{},
        workspace_id: ws.id,
        project_id: project.id,
        inserted_at: DateTime.utc_now()
      })

    mev
  end

  # ── 1. Blob / CDN / plugin cleanup gate (obhg-P0) ─────────────────────────

  describe "delete_workspace/1 fires blob + CDN + plugin cleanup" do
    test "removes the disk blob, hits the CDN purge URL, fires the plugin hook",
         %{bypass: bypass} do
      ws = create_workspace!()
      project = create_project!(ws)

      {file, on_disk} = upload_media!(ws, project, "purge-me.png")

      assert File.exists?(on_disk),
             "upload should have placed the blob on disk at #{on_disk}"

      # Override the default stub with a counting one so we can assert the
      # CDN purge endpoint was actually called from inside `Cdn.invalidate`.
      cdn_calls = :counters.new(1, [])

      Bypass.stub(bypass, "POST", "/purge", fn conn ->
        :counters.add(cdn_calls, 1, 1)
        Plug.Conn.resp(conn, 200, "{}")
      end)

      assert {:ok, %Workspace{}} = Tenancy.delete_workspace(ws)

      # The workspace + media_file are gone.
      refute Repo.get(Workspace, ws.id),
             "workspace row should be deleted"

      refute Repo.get(MediaFile, file.id),
             "media_file row should be deleted"

      # The disk blob is GONE — the test that distinguishes app-level
      # cleanup from a raw SQL cascade.
      refute File.exists?(on_disk),
             "disk blob at #{on_disk} should have been removed by File.rm"

      # CDN purge endpoint was hit (Cdn.invalidate fired).
      assert :counters.get(cdn_calls, 1) >= 1,
             "expected at least one POST to the CDN purge URL"

      # The :after_media_delete plugin hook fired with the doomed blob's id.
      assert_receive {:after_media_delete, %{media_file_id: media_file_id}}, 1_000
      assert media_file_id == file.id
    end

    test "control: raw Repo.delete(workspace) bypasses cleanup (proves the leak)" do
      # Pre-fix shape: a workspace delete that does NOT go through
      # Tenancy.delete_workspace/1 lets the SQL CASCADE remove the
      # media_files row without firing File.rm / Cdn.invalidate / hooks.
      ws = create_workspace!()
      project = create_project!(ws)

      {_file, on_disk} = upload_media!(ws, project, "leaked.png")

      assert File.exists?(on_disk)

      assert {:ok, %Workspace{}} = Repo.delete(ws)

      # The blob is STILL on disk — the orphan-blob leak. This is exactly
      # what `delete_workspace/1` prevents by walking media_files first.
      assert File.exists?(on_disk),
             "raw Repo.delete bypasses File.rm; the blob should still be on disk " <>
               "(this asserts the LEAK the fix closes)"

      # Clean up the artifact so the test partition's uploads dir doesn't grow.
      _ = File.rm(on_disk)
    end
  end

  # ── 2. Cascade to the seven extra tables (0f7g-P1) ────────────────────────

  describe "delete_workspace/1 cascades to the seven extended tables" do
    test "webhooks / synonyms / paper_events / mutation_events all gone, no NULL-scope orphans" do
      ws = create_workspace!()
      project = create_project!(ws)

      webhook = insert_webhook!(ws, project)
      synonym = insert_synonym!(ws, project)
      paper_event = insert_paper_event!(ws, project)
      mutation_event = insert_mutation_event!(ws, project)

      # preconditions
      assert Repo.get(Webhook, webhook.id)
      assert Repo.get(Synonym, synonym.id)
      assert Repo.get(PaperEvent, paper_event.id)
      assert Repo.get(MutationEvent, mutation_event.id)

      # (Global setup already stubs POST /purge → 200; no media in this
      # test, so it won't fire, but a stub is cheap insurance.)
      assert {:ok, %Workspace{}} = Tenancy.delete_workspace(ws)

      # All four rows are GONE (the cascade extension).
      refute Repo.get(Webhook, webhook.id)
      refute Repo.get(Synonym, synonym.id)
      refute Repo.get(PaperEvent, paper_event.id)
      refute Repo.get(MutationEvent, mutation_event.id)

      # And no orphan rows survive with workspace_id=NULL — the leak that
      # would have happened if any of those FKs were still `:nilify_all`.
      assert null_scope_count(Webhook, webhook.id) == 0
      assert null_scope_count(Synonym, synonym.id) == 0
      assert null_scope_count(PaperEvent, paper_event.id) == 0
      assert null_scope_count(MutationEvent, mutation_event.id) == 0
    end
  end

  # ── 3. Atomicity ──────────────────────────────────────────────────────────

  describe "delete_workspace/1 atomicity" do
    test "a mid-delete failure rolls everything back; nothing partial-deletes" do
      ws = create_workspace!()
      project = create_project!(ws)

      # `MediaDeleteSpyPlugin.before_delete/1` halts when it sees a doc with
      # `doc_id == "halt-me"` — Content.delete_document returns
      # `{:error, {:halted, _}}` and `do_delete_workspace`'s `with`
      # propagates that, triggering `Repo.rollback`.
      {:ok, doc_keep} =
        Content.create_document(
          "post",
          %{"doc_id" => "atom-keep", "title" => "Keep", "content" => %{}},
          @dataset,
          workspace_id: ws.id,
          project_id: project.id
        )

      {:ok, doc_halt} =
        Content.create_document(
          "post",
          %{"doc_id" => "halt-me", "title" => "Halt", "content" => %{}},
          @dataset,
          workspace_id: ws.id,
          project_id: project.id
        )

      {file, on_disk} = upload_media!(ws, project, "atom.png")

      assert File.exists?(on_disk),
             "upload should have placed the blob on disk at #{on_disk}"

      # Sanity: prove the halt hook IS wired in for this test before we
      # blame Tenancy.delete_workspace for not propagating it.
      halt_result =
        Content.delete_document(
          "halt-me",
          "post",
          @dataset,
          workspace_id: ws.id
        )

      assert halt_result == {:error, {:halted, "atomicity-test"}},
             "before_delete halt hook must be wired in for this test to be meaningful, got #{inspect(halt_result)}"

      # Re-fetch the doc — Content.delete_document calls get_document
      # which scopes by workspace_id; the row should still be there after
      # the halt.
      assert Repo.get(Document, doc_halt.id)

      assert {:error, _} = Tenancy.delete_workspace(ws)

      # Every DB row survives the rolled-back delete.
      assert Repo.get(Workspace, ws.id),
             "workspace must survive a rolled-back delete"

      assert Repo.get(Document, doc_keep.id),
             "first document must survive a rolled-back delete"

      assert Repo.get(Document, doc_halt.id),
             "halt-me document must survive a rolled-back delete"

      assert Repo.get(MediaFile, file.id),
             "media_file row must survive a rolled-back delete"

      # PHANTOM-MEDIA GATE (felix-phantom-media-atomicity): the media_file ROW
      # survives (asserted above) AND its on-disk blob survives WITH it. Before
      # the deferred-effects fix, `delete_workspace_media` ran `File.rm` eagerly
      # inside the transaction, so a later rollback (the halted document delete)
      # left the row alive but the blob GONE — a phantom. The blob's four
      # irreversible non-DB effects (File.rm / CDN purge / media.deleted webhook /
      # rendition removal) are now DEFERRED until commit and DROPPED on rollback,
      # so row and blob stay consistent. This assertion goes RED on the unfixed
      # tree (blob already removed) and GREEN once the effects are deferred.
      assert File.exists?(on_disk),
             "on rollback the media blob at #{on_disk} must survive alongside its " <>
               "surviving row — a live row with a deleted blob is the phantom this fix closes"
    end
  end

  # ── 3b. Malformed / absent id guard ───────────────────────────────────────

  describe "delete_workspace/1 guards the :binary_id cast" do
    # delete_workspace/1 resolves the id via get_workspace_by_id/1, which now
    # cast-guards the :binary_id PK. A non-UUID id must map to :not_found, not
    # an Ecto.CastError → 500.
    test "a non-UUID id returns {:error, :not_found}, not a raise" do
      assert Tenancy.delete_workspace("not-a-uuid") == {:error, :not_found}
    end

    test "a well-formed but absent UUID returns {:error, :not_found}" do
      assert Tenancy.delete_workspace(Ecto.UUID.generate()) == {:error, :not_found}
    end
  end

  # ── 4. Other workspace untouched ──────────────────────────────────────────

  describe "delete_workspace/1 isolation" do
    test "deleting workspace A leaves workspace B's content/media/webhook intact" do
      ws_a = create_workspace!()
      project_a = create_project!(ws_a)
      ws_b = create_workspace!()
      project_b = create_project!(ws_b)

      {:ok, doc_a} =
        Content.create_document(
          "post",
          %{"doc_id" => "doc-in-a", "title" => "A", "content" => %{}},
          @dataset,
          workspace_id: ws_a.id,
          project_id: project_a.id
        )

      {:ok, doc_b} =
        Content.create_document(
          "post",
          %{"doc_id" => "doc-in-b", "title" => "B", "content" => %{}},
          @dataset,
          workspace_id: ws_b.id,
          project_id: project_b.id
        )

      {file_a, _on_disk_a} = upload_media!(ws_a, project_a, "a.png")
      {file_b, on_disk_b} = upload_media!(ws_b, project_b, "b.png")

      webhook_a = insert_webhook!(ws_a, project_a)
      webhook_b = insert_webhook!(ws_b, project_b)

      assert {:ok, %Workspace{}} = Tenancy.delete_workspace(ws_a)

      # A's stuff is gone.
      refute Repo.get(Workspace, ws_a.id)
      refute Repo.get(Document, doc_a.id)
      refute Repo.get(MediaFile, file_a.id)
      refute Repo.get(Webhook, webhook_a.id)

      # B's stuff is intact.
      assert Repo.get(Workspace, ws_b.id)
      assert Repo.get(Document, doc_b.id)
      assert Repo.get(MediaFile, file_b.id)
      assert Repo.get(Webhook, webhook_b.id)
      assert File.exists?(on_disk_b)
    end
  end

  # ── 5. E3 string-keyed sweep (bpb-delete-e3-string-keyed-sweep) ────────────

  describe "delete_workspace/1 sweeps the FK-less E3 string-keyed tables" do
    test "an authoring_exemptions row keyed by (doc_id, dataset) is GONE post-delete" do
      ws = create_workspace!()
      project = create_project!(ws)

      # A real document establishes the (doc_id, dataset) leaf the E3 doc-keyed
      # semi-join keys on. authoring_exemptions carries NO workspace_id and NO
      # FK to workspaces — the SQL cascade on Repo.delete(workspace) never
      # reaches it, so ONLY the new string-keyed sweep can remove this row.
      {:ok, doc} =
        create_document_in!(ws, project, "post", %{"doc_id" => "sweep-me"})

      insert_exemption!(doc.doc_id, doc.dataset, doc.type)

      assert exemption_count(doc.doc_id, doc.dataset) == 1,
             "precondition: the exemption row must exist before delete"

      assert {:ok, %Workspace{}} = Tenancy.delete_workspace(ws)

      # The proof is the ROW BEING GONE (count == 0), never "no crash". On the
      # unfixed tree (no string-keyed sweep) this row survives → count == 1 → RED.
      assert exemption_count(doc.doc_id, doc.dataset) == 0,
             "the workspace's authoring_exemptions row must be swept on teardown"
    end

    test "a (doc_id, dataset) exemption ALSO owned by a sibling workspace SURVIVES" do
      ws_a = create_workspace!()
      proj_a = create_project!(ws_a)
      ws_b = create_workspace!()
      proj_b = create_project!(ws_b)

      # The SAME (doc_id, dataset) leaf in TWO workspaces — legal because
      # documents' unique key is (doc_id, type, dataset_id) and each workspace
      # has its OWN dataset_id for the shared "test" slug (charter D6/D7). One
      # exemption row therefore maps to both workspaces.
      {:ok, doc_a} =
        create_document_in!(ws_a, proj_a, "post", %{"doc_id" => "shared-exemption"})

      {:ok, doc_b} =
        create_document_in!(ws_b, proj_b, "post", %{"doc_id" => "shared-exemption"})

      assert doc_a.doc_id == doc_b.doc_id and doc_a.dataset == doc_b.dataset,
             "the two workspaces must share the exact (doc_id, dataset) leaf"

      insert_exemption!(doc_a.doc_id, doc_a.dataset, doc_a.type)

      assert {:ok, %Workspace{}} = Tenancy.delete_workspace(ws_a)

      # The sibling-guard (AND NOT EXISTS another workspace's document) keeps the
      # shared row alive — deleting workspace A must NOT clobber a row workspace
      # B still references. Without the guard this would be 0 → RED.
      assert exemption_count(doc_a.doc_id, doc_a.dataset) == 1,
             "a shared exemption still referenced by workspace B must survive A's teardown"
    end
  end

  # ── 6. E3-dataset / allowlist bare-slug collision (bpb-e3-dataset-slug-collision) ──

  describe "delete_workspace/1 project-qualifies the E3-dataset/allowlist bare-slug sweep" do
    test "a dataset slug SHARED with a sibling workspace is NOT swept from the bare-keyed tables; an exclusive slug IS" do
      ws_a = create_workspace!()
      proj_a = create_project!(ws_a)
      ws_b = create_workspace!()
      proj_b = create_project!(ws_b)

      # A dataset slug is unique only per (project_id, slug) — so "shared-prod"
      # legitimately names a DISTINCT dataset in EACH workspace (charter D21).
      # The E3-dataset tables (preview_token_jti, shares) carry ONLY that bare
      # slug with no project/dataset column, so a bare `dataset = ANY(slugs)`
      # sweep of A would strip B's rows under the SAME slug too — a cross-tenant
      # delete. The project-qualified slug set is what prevents that.
      #
      # The former scope-column allowlist is now EMPTY — both members moved to E1
      # and are swept by the teardown FK cascade (workspace_id = A), NOT by slug:
      #   * search_surface_config — Wave 5 Slice A; see the dedicated E1-cascade
      #     test in the describe below.
      #   * data_keys — bpb-datakeys-write-path-workspace-attribution; its
      #     non-over-deletion is proven by cascade scoping (workspace_id = A)
      #     rather than slug narrowing: A's own shared-slug DEK is cascade-swept
      #     while B's survives.
      #
      # (The sync_* family also moved to E1/FK-cascade in charter D55 and is
      # proved separately in the sync_* describe below.)
      tag = System.unique_integer([:positive])
      shared = "shared-prod-#{tag}"
      excl = "excl-a-#{tag}"

      seed_dataset!(proj_a.id, excl)
      seed_dataset!(proj_a.id, shared)
      seed_dataset!(proj_b.id, shared)

      # A's OWN row under its exclusive slug — MUST still be swept (no over-narrow).
      insert_preview_jti!("jti-a-#{tag}", excl)

      # Rows under the slug A SHARES with B — MUST survive A's teardown.
      insert_preview_jti!("jti-b-#{tag}", shared)

      # A's own shared-slug DEK (attributed to A) + B's under the SAME shared
      # scope (attributed to B, distinct version for the (workspace_id, scope,
      # version) index). A's is cascade-swept on teardown; B's survives.
      insert_data_key!("dataset:#{shared}", ws_a.id, 1)
      insert_data_key!("dataset:#{shared}", ws_b.id, 2)

      assert {:ok, %Workspace{}} = Tenancy.delete_workspace(ws_a)

      # No over-narrow: A's exclusive-slug bare-keyed row is gone.
      assert preview_jti_count!("jti-a-#{tag}", excl) == 0,
             "A's exclusive-slug preview jti must still be swept on teardown"

      # No cross-tenant over-deletion: on origin/main the bare
      # `dataset = ANY([excl, shared])` sweep also deletes the shared-slug rows
      # → these counts are 0 → RED. The project-qualified fix excludes `shared`
      # (owned by B too) so B's rows SURVIVE.
      assert preview_jti_count!("jti-b-#{tag}", shared) == 1,
             "a preview jti under a slug SHARED with workspace B must survive A's teardown"

      # data_keys: A's own DEK is cascade-swept (workspace_id = A) and B's DEK
      # under the SAME shared scope SURVIVES — non-over-deletion now enforced by
      # the FK cascade's workspace_id scoping, not slug narrowing.
      assert data_key_count("dataset:#{shared}") == 1,
             "only sibling workspace B's per-dataset DEK survives A's teardown; A's own is cascade-swept"
    end
  end

  # ── 7. search_surface_config per-workspace E1 attribution (Wave 5 Slice A) ──

  describe "delete_workspace/1 tears down only the deleted workspace's surface config" do
    test "B's config on the SAME 'production' scope SURVIVES A's teardown (charter D45/D49)" do
      ws_a = create_workspace!()
      ws_b = create_workspace!()

      # Both own a config on the universally-shared "production" scope. They are
      # DISTINCT workspace_id-keyed rows now, so A's cascade delete removes only
      # A's; B's SURVIVES (and a NULL-workspace global default, if any, too).
      insert_surface_config_ws!(ws_a.id, "documents", "production")
      insert_surface_config_ws!(ws_b.id, "documents", "production")

      assert {:ok, %Workspace{}} = Tenancy.delete_workspace(ws_a)

      assert surface_config_count_ws(ws_a.id, "documents", "production") == 0,
             "A's workspace-keyed surface config must be cascade-deleted on teardown"

      assert surface_config_count_ws(ws_b.id, "documents", "production") == 1,
             "B's surface config on the same scope must survive A's teardown"
    end
  end

  # ── 7. sync_* family E1 attribution — FK cascade, per-workspace (charter D55) ──

  describe "delete_workspace/1 cascades the sync_* family by workspace_id" do
    test "a sync_cursors row is GONE post-delete; a sibling workspace's under the SAME slug SURVIVES" do
      ws_a = create_workspace!()
      proj_a = create_project!(ws_a)
      ws_b = create_workspace!()
      proj_b = create_project!(ws_b)

      # Both workspaces own the SAME slug (bare-slug collision D55 fixes). The
      # sync cursors are told apart ONLY by workspace_id (the old bare
      # {source, dataset} key could not represent both at once).
      tag = System.unique_integer([:positive])
      shared = "shared-prod-#{tag}"
      seed_dataset!(proj_a.id, shared)
      seed_dataset!(proj_b.id, shared)

      insert_sync_cursor_ws!(ws_a.id, "sync-a-#{tag}", shared)
      insert_sync_cursor_ws!(ws_b.id, "sync-b-#{tag}", shared)

      assert {:ok, %Workspace{}} = Tenancy.delete_workspace(ws_a)

      # A's cursor is swept by the workspace_id FK cascade…
      assert sync_cursor_count("sync-a-#{tag}", shared) == 0,
             "workspace A's sync cursor must be cascade-deleted on teardown"

      # …and B's cursor under the SAME shared slug is UNTOUCHED (per-workspace
      # attribution — the pre-D55 bare-slug delete could not distinguish them).
      assert sync_cursor_count("sync-b-#{tag}", shared) == 1,
             "workspace B's sync cursor under the shared slug must survive A's teardown"
    end

    test "a workspace-agnostic (NULL workspace_id) sync_push_cursors row survives any workspace delete" do
      ws = create_workspace!()
      tag = System.unique_integer([:positive])

      # The GitHub outbound mirror stamps NULL workspace_id (per-dataset, not
      # per-workspace) — a workspace teardown must NOT sweep it (no matching FK).
      Repo.query!(
        "INSERT INTO sync_push_cursors (workspace_id, source, dataset, event_id, inserted_at, updated_at) " <>
          "VALUES (NULL, 'github:outbound', 'ds-#{tag}', 0, now(), now())",
        []
      )

      assert {:ok, %Workspace{}} = Tenancy.delete_workspace(ws)

      assert scalar(
               "SELECT count(*) FROM sync_push_cursors WHERE source = 'github:outbound' AND dataset = $1",
               ["ds-#{tag}"]
             ) == 1,
             "a NULL-workspace (workspace-agnostic) push cursor must survive a workspace delete"
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  # Insert a raw authoring_exemptions row (no Ecto schema — a FK-less E3
  # doc-keyed table). PK is (doc_id, dataset).
  defp insert_exemption!(doc_id, dataset, type) do
    Repo.query!(
      "INSERT INTO authoring_exemptions (doc_id, dataset, type, exempted_at) " <>
        "VALUES ($1, $2, $3, now()) ON CONFLICT (doc_id, dataset) DO NOTHING",
      [doc_id, dataset, type]
    )
  end

  # Count authoring_exemptions rows for a (doc_id, dataset) leaf — the GONE /
  # SURVIVES proof (never "no crash").
  defp exemption_count(doc_id, dataset) do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM authoring_exemptions WHERE doc_id = $1 AND dataset = $2",
        [doc_id, dataset]
      )

    n
  end

  # Count rows for `schema` matching `id` with workspace_id IS NULL — the
  # orphan shape we MUST NOT produce on a workspace delete.
  defp null_scope_count(schema, id) do
    Repo.aggregate(
      from(r in schema, where: r.id == ^id and is_nil(r.workspace_id)),
      :count
    )
  end

  # ── E3-dataset / allowlist bare-slug raw seed + count helpers ───────────────
  # These tables carry ONLY a bare dataset/scope string (no Ecto tenancy scope),
  # so they are seeded and counted with raw SQL.

  defp seed_dataset!(project_id, slug) do
    Repo.query!(
      "INSERT INTO datasets (id, project_id, slug, name, inserted_at, updated_at) " <>
        "VALUES (gen_random_uuid(), $1::text::uuid, $2, $2, now(), now())",
      [project_id, slug]
    )
  end

  # preview_token_jti is the E3-dataset exemplar (sync_* moved to E1/FK-cascade — D55).
  defp insert_preview_jti!(jti, dataset) do
    Repo.query!(
      "INSERT INTO preview_token_jti (jti, dataset, issued_at, expires_at) " <>
        "VALUES ($1, $2, now(), now() + interval '1 hour')",
      [jti, dataset]
    )
  end

  defp preview_jti_count!(jti, dataset) do
    scalar("SELECT count(*) FROM preview_token_jti WHERE jti = $1 AND dataset = $2", [
      jti,
      dataset
    ])
  end

  # A workspace-attributed sync_cursors row (charter D55 — sync_* is E1 now).
  defp insert_sync_cursor_ws!(ws_id, source, dataset) do
    Repo.query!(
      "INSERT INTO sync_cursors (workspace_id, source, dataset, event_id, inserted_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2, $3, 0, now(), now())",
      [ws_id, source, dataset]
    )
  end

  defp sync_cursor_count(source, dataset) do
    scalar("SELECT count(*) FROM sync_cursors WHERE source = $1 AND dataset = $2", [
      source,
      dataset
    ])
  end

  # `workspace_id` attributes the DEK (E1 path, swept by the teardown FK
  # cascade); `version` keeps sibling rows under the SAME shared scope distinct
  # for the `(workspace_id, scope, version)` unique index.
  defp insert_data_key!(scope, workspace_id, version) do
    Repo.query!(
      "INSERT INTO data_keys (id, scope, version, wrapped_key, workspace_id, inserted_at, updated_at) " <>
        "VALUES (gen_random_uuid(), $1, $3, 'ciphertext', $2::text::uuid, now(), now())",
      [scope, workspace_id, version]
    )
  end

  defp data_key_count(scope) do
    scalar("SELECT count(*) FROM data_keys WHERE scope = $1", [scope])
  end

  # Workspace-keyed surface config (Wave 5 Slice A E1 attribution).
  defp insert_surface_config_ws!(workspace_id, surface, scope) do
    Repo.query!(
      "INSERT INTO search_surface_config (id, workspace_id, surface, scope, inserted_at, updated_at) " <>
        "VALUES (gen_random_uuid(), $1::text::uuid, $2, $3, now(), now())",
      [workspace_id, surface, scope]
    )
  end

  defp surface_config_count_ws(workspace_id, surface, scope) do
    scalar(
      "SELECT count(*) FROM search_surface_config WHERE workspace_id = $1::text::uuid AND surface = $2 AND scope = $3",
      [workspace_id, surface, scope]
    )
  end

  defp scalar(sql, params) do
    %{rows: [[n]]} = Repo.query!(sql, params)
    n
  end
end
