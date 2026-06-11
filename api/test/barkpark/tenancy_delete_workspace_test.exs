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
  alias Barkpark.Media.MediaFile
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

      {file, _on_disk} = upload_media!(ws, project, "atom.png")

      # Sanity: prove the halt hook IS wired in for this test before we
      # blame Tenancy.delete_workspace for not propagating it.
      assert {:error, {:halted, "atomicity-test"}} =
               Content.delete_document(
                 "halt-me",
                 "post",
                 @dataset,
                 workspace_id: ws.id
               ),
             "before_delete halt hook must be wired in for this test to be meaningful"

      # Re-fetch the doc — Content.delete_document calls get_document
      # which scopes by workspace_id; the row should still be there after
      # the halt.
      assert Repo.get(Document, doc_halt.id)

      assert {:error, _} = Tenancy.delete_workspace(ws)

      # Every DB row survives the rolled-back delete. (Side-effects outside
      # the transaction — File.rm, the CDN HTTP purge — cannot be un-done;
      # see the moduledoc on `delete_workspace/1`. The contract this test
      # pins is the DATABASE state.)
      assert Repo.get(Workspace, ws.id),
             "workspace must survive a rolled-back delete"

      assert Repo.get(Document, doc_keep.id),
             "first document must survive a rolled-back delete"

      assert Repo.get(Document, doc_halt.id),
             "halt-me document must survive a rolled-back delete"

      assert Repo.get(MediaFile, file.id),
             "media_file row must survive a rolled-back delete"
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

  # ── helpers ───────────────────────────────────────────────────────────────

  # Count rows for `schema` matching `id` with workspace_id IS NULL — the
  # orphan shape we MUST NOT produce on a workspace delete.
  defp null_scope_count(schema, id) do
    Repo.aggregate(
      from(r in schema, where: r.id == ^id and is_nil(r.workspace_id)),
      :count
    )
  end
end
