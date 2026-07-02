defmodule Barkpark.Content.LifecycleTest do
  @moduledoc """
  Behaviour tests for `Barkpark.Content.Lifecycle` — the core CMS verbs
  (publish / unpublish / discard-draft / delete).

  The load-bearing guarantees under test:

  - Happy path moves the row exactly (published row appears, draft row gone,
    and vice-versa) and returns `{:ok, doc}`.
  - A row that has already been consumed by another writer surfaces as
    `{:error, :not_found}` — NEVER an uncaught `Ecto.StaleEntryError` (a 500)
    and never a phantom/partial state.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Repo

  @dataset "lifecycle_unit_test"
  @type_name "lpost"

  setup do
    Content.upsert_schema(
      %{"name" => @type_name, "title" => "LPost", "visibility" => "public", "fields" => []},
      @dataset
    )

    :ok
  end

  defp draft!(id, title \\ "Title") do
    {:ok, _} =
      Content.create_document(@type_name, %{"_id" => id, "title" => title}, @dataset)

    {:ok, draft} = Content.get_document("drafts." <> id, @type_name, @dataset)
    draft
  end

  # ── publish ─────────────────────────────────────────────────────────────────

  test "publish moves draft→published: published row exists, draft row gone" do
    draft!("pub-happy", "Hello")

    assert {:ok, published} = Content.publish_document("pub-happy", @type_name, @dataset)
    assert published.doc_id == "pub-happy"
    assert published.status == "published"

    assert {:ok, _} = Content.get_document("pub-happy", @type_name, @dataset)
    assert {:error, :not_found} = Content.get_document("drafts.pub-happy", @type_name, @dataset)
  end

  test "publish on a draft already deleted by a concurrent writer → :not_found, no raise" do
    draft = draft!("pub-stale")
    # Simulate the race winner having already consumed the draft row.
    {:ok, _} = Repo.delete(draft)

    assert {:error, :not_found} = Content.publish_document("pub-stale", @type_name, @dataset)
    # And no phantom published row was left behind.
    assert {:error, :not_found} = Content.get_document("pub-stale", @type_name, @dataset)
  end

  # ── unpublish ───────────────────────────────────────────────────────────────

  test "unpublish moves published→draft: draft row exists, published row gone" do
    draft!("unpub-happy")
    {:ok, _} = Content.publish_document("unpub-happy", @type_name, @dataset)

    assert {:ok, draft} = Content.unpublish_document("unpub-happy", @type_name, @dataset)
    assert draft.status == "draft"

    assert {:ok, _} = Content.get_document("drafts.unpub-happy", @type_name, @dataset)
    assert {:error, :not_found} = Content.get_document("unpub-happy", @type_name, @dataset)
  end

  test "unpublish on a published row already deleted → :not_found, no raise" do
    draft!("unpub-stale")
    {:ok, published} = Content.publish_document("unpub-stale", @type_name, @dataset)
    {:ok, _} = Repo.delete(published)

    assert {:error, :not_found} = Content.unpublish_document("unpub-stale", @type_name, @dataset)
  end

  # ── discard draft ───────────────────────────────────────────────────────────

  test "discard_draft removes the draft and returns {:ok, _}" do
    draft!("disc-happy")

    assert {:ok, _} = Content.discard_draft("disc-happy", @type_name, @dataset)
    assert {:error, :not_found} = Content.get_document("drafts.disc-happy", @type_name, @dataset)
  end

  test "discard_draft on an already-deleted draft → :not_found, no raise" do
    draft = draft!("disc-stale")
    {:ok, _} = Repo.delete(draft)

    assert {:error, :not_found} = Content.discard_draft("disc-stale", @type_name, @dataset)
  end

  # ── delete ──────────────────────────────────────────────────────────────────

  test "delete on a doc with BOTH variants: both rows gone, returns {:ok, _}" do
    # Publish once (creates published, removes draft), then re-create the draft
    # so the doc carries both a published row and a pending-changes draft.
    draft!("del-both")
    {:ok, _} = Content.publish_document("del-both", @type_name, @dataset)
    draft!("del-both", "Edited")

    assert {:ok, _} = Content.delete_document("del-both", @type_name, @dataset)
    assert {:error, :not_found} = Content.get_document("del-both", @type_name, @dataset)
    assert {:error, :not_found} = Content.get_document("drafts.del-both", @type_name, @dataset)
  end

  test "delete on a draft-only doc removes the draft" do
    draft!("del-draft")

    assert {:ok, _} = Content.delete_document("del-draft", @type_name, @dataset)
    assert {:error, :not_found} = Content.get_document("drafts.del-draft", @type_name, @dataset)
  end

  test "delete when every variant is already gone → :not_found, no raise" do
    draft = draft!("del-stale")
    {:ok, _} = Repo.delete(draft)

    assert {:error, :not_found} = Content.delete_document("del-stale", @type_name, @dataset)
  end
end
