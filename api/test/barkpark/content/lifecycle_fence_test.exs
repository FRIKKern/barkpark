defmodule Barkpark.Content.LifecycleFenceTest do
  @moduledoc """
  Rev-fence tests for `Barkpark.Content.Lifecycle` — the data-loss class fix.

  The four lifecycle verbs (publish / unpublish / discard-draft / delete) read a
  row, then delete it. A bare `Repo.delete(struct, stale_error_field: :doc_id)`
  fires only when the row is GONE, so a concurrent write that bumps the row's
  `rev` between the read and the delete would still succeed — publishing a stale
  snapshot while silently destroying the newer edit.

  These tests drive that exact race using a `:before_*` lifecycle hook (the same
  registration seam `Barkpark.Plugins.HooksTest` uses) that bumps the row's rev
  AFTER the verb has read it but BEFORE the fenced delete runs. Pre-fix, publish
  succeeds and the edit vanishes; post-fix the fence turns it into
  `{:error, {:rev_mismatch, _}}` (mapped to a 412) and nothing is lost.

  `async: false` because the hook seam mutates the global
  `Application.get_env(:barkpark, :plugins, …)`.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Repo

  @dataset "lifecycle_fence_test"
  @type_name "fpost"

  # ── concurrent-write hook ─────────────────────────────────────────────────
  #
  # A bare module with `lifecycle_hooks/0` — the dispatcher only needs that
  # export (see HooksTest). `bump/1` simulates a concurrent writer (Studio
  # canvas per-op write, autosave, a `mutate` patch) landing between the verb's
  # read and its fenced delete: it rewrites the just-read row's `rev` in place,
  # then returns `:ok` so the verb proceeds against a now-stale snapshot.
  defmodule BumpHook do
    @moduledoc false
    import Ecto.Query

    def lifecycle_hooks do
      %{
        before_publish: [&__MODULE__.bump/1],
        before_unpublish: [&__MODULE__.bump/1],
        before_delete: [&__MODULE__.bump/1]
      }
    end

    def bump(%{doc: doc}) do
      {1, _} =
        Barkpark.Repo.update_all(
          from(d in Barkpark.Content.Document, where: d.id == ^doc.id),
          set: [rev: "concurrent-" <> Integer.to_string(System.unique_integer([:positive]))]
        )

      :ok
    end
  end

  setup do
    Content.upsert_schema(
      %{"name" => @type_name, "title" => "FPost", "visibility" => "public", "fields" => []},
      @dataset
    )

    :ok
  end

  # Delegated to `Barkpark.PluginEnv` so the restore uses the `:unset`
  # sentinel — a `[]` snapshot default would restore an EXPLICIT `[]` on the
  # unset boot baseline, arming BootCollectors' discovery kill switch for
  # later tests.
  defp with_plugins(modules, ctx) do
    Barkpark.PluginEnv.with_plugins(modules, ctx)
  end

  defp draft!(id, title \\ "Title") do
    {:ok, _} = Content.create_document(@type_name, %{"_id" => id, "title" => title}, @dataset)
    {:ok, draft} = Content.get_document("drafts." <> id, @type_name, @dataset)
    draft
  end

  defp rev_of(id, type \\ @type_name) do
    {:ok, doc} = Content.get_document(id, type, @dataset)
    doc.rev
  end

  # ── the data-loss race: publish-during-edit ───────────────────────────────

  test "publish while the draft is concurrently edited → rev_mismatch, edit preserved", ctx do
    draft = draft!("pub-race", "Original")
    :ok = with_plugins([BumpHook], ctx)

    assert {:error, {:rev_mismatch, %{expected: expected, actual: actual}}} =
             Content.publish_document("pub-race", @type_name, @dataset)

    # The fence compared the snapshot's rev against the concurrently-bumped row.
    assert expected == draft.rev
    assert actual != draft.rev

    # No stale published row was created, and the (bumped) draft SURVIVES —
    # pre-fix it would have been deleted and its content lost.
    assert {:error, :not_found} = Content.get_document("pub-race", @type_name, @dataset)
    assert {:ok, still_there} = Content.get_document("drafts.pub-race", @type_name, @dataset)
    assert still_there.rev == actual
  end

  test "unpublish while the published row is concurrently edited → rev_mismatch, row preserved",
       ctx do
    draft!("unpub-race")
    {:ok, _} = Content.publish_document("unpub-race", @type_name, @dataset)
    pub_rev = rev_of("unpub-race")

    :ok = with_plugins([BumpHook], ctx)

    assert {:error, {:rev_mismatch, %{expected: expected}}} =
             Content.unpublish_document("unpub-race", @type_name, @dataset)

    assert expected == pub_rev

    # The published row survives (unpublish rolled back) and NO draft was created.
    assert {:ok, _} = Content.get_document("unpub-race", @type_name, @dataset)
    assert {:error, :not_found} = Content.get_document("drafts.unpub-race", @type_name, @dataset)
  end

  test "delete while a variant is concurrently edited → rev_mismatch, both rows preserved", ctx do
    draft!("del-race")
    {:ok, _} = Content.publish_document("del-race", @type_name, @dataset)
    draft!("del-race", "Edited")

    :ok = with_plugins([BumpHook], ctx)

    assert {:error, {:rev_mismatch, _}} =
             Content.delete_document("del-race", @type_name, @dataset)

    # The whole delete rolled back: both variants still exist.
    assert {:ok, _} = Content.get_document("del-race", @type_name, @dataset)
    assert {:ok, _} = Content.get_document("drafts.del-race", @type_name, @dataset)
  end

  # ── happy paths (no concurrent writer) prove unchanged semantics ───────────

  test "publish happy path is unchanged" do
    draft!("pub-ok", "Hello")

    assert {:ok, published} = Content.publish_document("pub-ok", @type_name, @dataset)
    assert published.status == "published"
    assert {:ok, _} = Content.get_document("pub-ok", @type_name, @dataset)
    assert {:error, :not_found} = Content.get_document("drafts.pub-ok", @type_name, @dataset)
  end

  test "unpublish happy path is unchanged" do
    draft!("unpub-ok")
    {:ok, _} = Content.publish_document("unpub-ok", @type_name, @dataset)

    assert {:ok, draft} = Content.unpublish_document("unpub-ok", @type_name, @dataset)
    assert draft.status == "draft"
    assert {:ok, _} = Content.get_document("drafts.unpub-ok", @type_name, @dataset)
    assert {:error, :not_found} = Content.get_document("unpub-ok", @type_name, @dataset)
  end

  test "discard_draft happy path is unchanged" do
    draft!("disc-ok")

    assert {:ok, _} = Content.discard_draft("disc-ok", @type_name, @dataset)
    assert {:error, :not_found} = Content.get_document("drafts.disc-ok", @type_name, @dataset)
  end

  test "delete happy path is unchanged" do
    draft!("del-ok")
    {:ok, _} = Content.publish_document("del-ok", @type_name, @dataset)
    draft!("del-ok", "Edited")

    assert {:ok, _} = Content.delete_document("del-ok", @type_name, @dataset)
    assert {:error, :not_found} = Content.get_document("del-ok", @type_name, @dataset)
    assert {:error, :not_found} = Content.get_document("drafts.del-ok", @type_name, @dataset)
  end

  # ── loser semantics preserved: a vanished row is still :not_found ──────────

  test "publish on a draft a concurrent writer already deleted → :not_found (not rev_mismatch)" do
    draft = draft!("pub-gone")
    {:ok, _} = Repo.delete(draft)

    assert {:error, :not_found} = Content.publish_document("pub-gone", @type_name, @dataset)
    assert {:error, :not_found} = Content.get_document("pub-gone", @type_name, @dataset)
  end
end
