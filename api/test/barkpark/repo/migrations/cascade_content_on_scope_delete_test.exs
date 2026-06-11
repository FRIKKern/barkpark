defmodule Barkpark.Repo.Migrations.CascadeContentOnScopeDeleteTest do
  @moduledoc """
  Correctness gate for migration 20260527160000 (4lsn).

  Before this migration the four content tables (documents / revisions /
  media_files / schema_definitions) carried their three scope FKs
  (workspace_id / project_id / dataset_id) as `:nilify_all` (SET NULL). So a
  workspace delete cascaded the projects + datasets but left every owned
  content row alive with all scope columns NULL while its `dataset` STRING
  survived — resurfacing under Default (the orphan leak).

  This suite runs against the FULLY-MIGRATED test DB (the migration is part of
  the chain via `mix ecto.reset`), so these assertions exercise the LIVE FK
  actions in the test database:

    * Deleting a WORKSPACE cascades to its project, dataset, AND every owned
      content row (document / revision / media_file / schema_definition) — zero
      rows survive with NULL scope, nothing resurfaces under Default.
    * Content in ANOTHER workspace is untouched.
    * Deleting a PROJECT cascades its content (project_id FK).
    * Deleting a DATASET cascades its content (dataset_id FK).
    * (down) rolling the migration back restores `:nilify_all`: a workspace
      delete then SET-NULLs the content scope columns instead of cascading.

  The down/0 check drives the migration body directly via `apply_down/0` /
  `apply_up/0` against the test's own sandbox connection (mirrors the
  20260527143000 rescope test), then restores up so it leaves the schema in the
  migrated state for sibling tests.

  ## How this relates to `Barkpark.Tenancy.delete_workspace/1` (obhg-P0 + 0f7g-P1)

  This test asserts the LOW-LEVEL SQL CASCADE contract — what happens when a
  bare `DELETE FROM workspaces WHERE id = …` runs. That cascade is now the
  belt-and-suspenders BACKSTOP under `Tenancy.delete_workspace/1`: the context
  function walks media_files via `Media.delete_file/2` first (so File.rm +
  Cdn.invalidate + plugin hooks fire), then `Repo.delete(workspace)` rides the
  same cascade chain this test pins. Both layers stay green — the SQL chain
  remains correct, the app-level pass adds the side-effect cleanup.
  `test/barkpark/tenancy_delete_workspace_test.exs` is the HIGH-LEVEL gate.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Repo
  alias Barkpark.Tenancy

  @migration_file Path.expand(
                    "../../../../priv/repo/migrations/20260527160000_cascade_content_on_scope_delete.exs",
                    __DIR__
                  )

  setup_all do
    Code.require_file(@migration_file)
    :ok
  end

  alias Barkpark.Repo.Migrations.CascadeContentOnScopeDelete

  # uuid params for raw Repo.query! must be 16-byte binaries; struct ids are
  # string UUIDs → dump on the way in.
  defp uuid_in(nil), do: nil
  defp uuid_in(id) when is_binary(id), do: Ecto.UUID.dump!(id)

  # ── content-row fixtures (raw SQL so we set the scope columns exactly) ──────

  defp insert_document!(slug, ws, project, dataset) do
    Repo.query!(
      """
      INSERT INTO documents
        (id, doc_id, type, dataset, title, status, rev, workspace_id, project_id,
         dataset_id, inserted_at, updated_at)
      VALUES
        (gen_random_uuid(), $1, 'post', $2, $3, 'draft', $4, $5, $6, $7, now(), now())
      """,
      [
        slug,
        dataset.slug,
        "Doc #{slug}",
        "rev-#{slug}-#{System.unique_integer([:positive])}",
        uuid_in(ws.id),
        uuid_in(project.id),
        uuid_in(dataset.id)
      ]
    )
  end

  defp insert_revision!(slug, ws, project, dataset) do
    Repo.query!(
      """
      INSERT INTO revisions
        (id, doc_id, type, action, dataset, workspace_id, project_id, dataset_id,
         inserted_at)
      VALUES
        (gen_random_uuid(), $1, 'post', 'create', $2, $3, $4, $5, now())
      """,
      [slug, dataset.slug, uuid_in(ws.id), uuid_in(project.id), uuid_in(dataset.id)]
    )
  end

  defp insert_media!(name, ws, project, dataset) do
    Repo.query!(
      """
      INSERT INTO media_files
        (id, filename, original_name, path, dataset, workspace_id, project_id,
         dataset_id, inserted_at, updated_at)
      VALUES
        (gen_random_uuid(), $1, $2, $3, $4, $5, $6, $7, now(), now())
      """,
      [
        "#{name}.png",
        "#{name}-orig.png",
        "/media/#{name}.png",
        dataset.slug,
        uuid_in(ws.id),
        uuid_in(project.id),
        uuid_in(dataset.id)
      ]
    )
  end

  defp insert_schema!(name, ws, project, dataset) do
    Repo.query!(
      """
      INSERT INTO schema_definitions
        (id, name, title, dataset, workspace_id, project_id, dataset_id,
         inserted_at, updated_at)
      VALUES
        (gen_random_uuid(), $1, $2, $3, $4, $5, $6, now(), now())
      """,
      [
        name,
        "Schema #{name}",
        dataset.slug,
        uuid_in(ws.id),
        uuid_in(project.id),
        uuid_in(dataset.id)
      ]
    )
  end

  # row counts for a given doc_id / filename / schema name.
  defp count(table, key_col, key) do
    %{rows: [[n]]} =
      Repo.query!("SELECT count(*) FROM #{table} WHERE #{key_col} = $1", [key])

    n
  end

  # rows with that key whose scope columns are ALL NULL (the orphan shape).
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

  defp delete_project!(p), do: Repo.query!("DELETE FROM projects WHERE id = $1", [uuid_in(p.id)])
  defp delete_dataset!(d), do: Repo.query!("DELETE FROM datasets WHERE id = $1", [uuid_in(d.id)])

  defp scope do
    ws = create_workspace!()
    project = create_project!(ws)
    {:ok, dataset} = Tenancy.get_or_create_dataset(project, "production")
    {ws, project, dataset}
  end

  describe "workspace delete cascades all owned content (up)" do
    test "document/revision/media/schema all cascade; no orphan; other workspace untouched" do
      {ws, project, dataset} = scope()
      {ws_other, project_other, dataset_other} = scope()

      insert_document!("doc-cascade", ws, project, dataset)
      insert_revision!("doc-cascade", ws, project, dataset)
      insert_media!("media-cascade", ws, project, dataset)
      insert_schema!("schema-cascade", ws, project, dataset)

      insert_document!("doc-other", ws_other, project_other, dataset_other)
      insert_media!("media-other", ws_other, project_other, dataset_other)

      # preconditions
      assert count("documents", "doc_id", "doc-cascade") == 1
      assert count("revisions", "doc_id", "doc-cascade") == 1
      assert count("media_files", "filename", "media-cascade.png") == 1
      assert count("schema_definitions", "name", "schema-cascade") == 1

      delete_workspace!(ws)

      # the workspace's projects + datasets cascade (existing FKs)…
      assert count("projects", "id", uuid_in(project.id)) == 0
      assert count("datasets", "id", uuid_in(dataset.id)) == 0

      # …AND all owned content rows are GONE (the fix). Not orphaned, deleted.
      assert count("documents", "doc_id", "doc-cascade") == 0
      assert count("revisions", "doc_id", "doc-cascade") == 0
      assert count("media_files", "filename", "media-cascade.png") == 0
      assert count("schema_definitions", "name", "schema-cascade") == 0

      # no row survives with NULL scope (the orphan-under-Default leak).
      assert count_orphaned("documents", "doc_id", "doc-cascade") == 0
      assert count_orphaned("revisions", "doc_id", "doc-cascade") == 0
      assert count_orphaned("media_files", "filename", "media-cascade.png") == 0
      assert count_orphaned("schema_definitions", "name", "schema-cascade") == 0

      # the OTHER workspace's content is untouched.
      assert count("documents", "doc_id", "doc-other") == 1
      assert count("media_files", "filename", "media-other.png") == 1
    end
  end

  describe "project / dataset delete also cascade content (up)" do
    test "deleting a project removes its content (project_id FK)" do
      {ws, project, dataset} = scope()
      insert_document!("doc-proj", ws, project, dataset)

      assert count("documents", "doc_id", "doc-proj") == 1
      delete_project!(project)
      assert count("documents", "doc_id", "doc-proj") == 0
      assert count_orphaned("documents", "doc_id", "doc-proj") == 0
    end

    test "deleting a dataset removes its content (dataset_id FK)" do
      {ws, project, dataset} = scope()
      insert_media!("media-ds", ws, project, dataset)

      assert count("media_files", "filename", "media-ds.png") == 1
      delete_dataset!(dataset)
      assert count("media_files", "filename", "media-ds.png") == 0
      assert count_orphaned("media_files", "filename", "media-ds.png") == 0
    end
  end

  describe "down/0 restores SET NULL semantics" do
    test "after rollback a workspace delete SET-NULLs the content scope instead of cascading" do
      CascadeContentOnScopeDelete.apply_down(Repo)

      try do
        {ws, project, dataset} = scope()
        insert_document!("doc-downrev", ws, project, dataset)

        delete_workspace!(ws)

        # The document SURVIVES — its scope columns went NULL (legacy behaviour).
        assert count("documents", "doc_id", "doc-downrev") == 1
        assert count_orphaned("documents", "doc_id", "doc-downrev") == 1
      after
        # Re-apply up so the schema is back in the migrated state for any other
        # test sharing this sandbox transaction's connection.
        CascadeContentOnScopeDelete.apply_up(Repo)
      end
    end
  end
end
