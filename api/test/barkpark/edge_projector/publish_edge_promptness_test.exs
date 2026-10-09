defmodule Barkpark.EdgeProjector.PublishEdgePromptnessTest do
  @moduledoc """
  task-3fd3c0c53d08a6bd — "Backlinks: a removed reference edge lingers 2-5s
  after publish while a new edge appears at once."

  ## What the row's own hypothesis got wrong

  The row suspected `createOrReplace` mints a new row id and the next
  publish's edge-removal diff keys on the CURRENT row id, stranding the OLD
  row's edges. Verified directly (`Barkpark.EdgeProjector.Projector.upsert_record/2`
  called synchronously against both a `create_document`-born row and a
  `create_document`-REPLACED row): the published row's PK is stable across
  republish either way, and `upsert_record/2`'s add+prune diff is correct for
  both. That hypothesis is false.

  ## What was actually wrong

  `:after_publish` shared the SAME 5-second-debounced `ProjectorWorker` job as
  `:after_save` (`Barkpark.EdgeProjector.Lifecycle`, pre-fix). `publish_document/4`
  — and the broadcast it fires — returned the instant a job was *enqueued*,
  never waiting for it to *run*. Whether a later read saw the update "at once"
  or "2-5s late" depended entirely on how much of an EARLIER debounce window
  (from a prior write to the same doc) happened to already be spent by the
  time of the read — not on which mutation verb built the row. Oban is still
  in `testing: :manual` for the whole suite (`config/test.exs`), so a test
  calling the old code and expecting the background job to have run would not
  even compile a meaningful assertion; this test instead asserts the thing the
  acceptance criterion actually demands: `content_edges` is already correct
  the instant `publish_document/4` returns, with NO job execution at all.

  The fix: `:after_publish` now runs `Projector.upsert_record/2` for the one
  published doc INLINE, before the hook returns.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.Edge

  @dataset "publish_edge_promptness_test"

  setup do
    Content.upsert_schema(
      %{"name" => "author", "title" => "Author", "visibility" => "public", "fields" => []},
      @dataset
    )

    Content.upsert_schema(
      %{
        "name" => "post",
        "title" => "Post",
        "visibility" => "public",
        "fields" => [
          %{"name" => "author", "type" => "reference", "refType" => "author"}
        ]
      },
      @dataset
    )

    :ok
  end

  defp publish!(type, id, attrs \\ %{}) do
    {:ok, _} =
      Content.create_document(type, Map.merge(%{"_id" => id, "title" => id}, attrs), @dataset)

    {:ok, doc} = Content.publish_document(id, type, @dataset)
    doc
  end

  defp outbound_targets(from_pk) do
    from_pk |> Content.list_outbound_edges() |> Enum.map(& &1.to_id)
  end

  describe "publishing a reference change — no debounce, no job execution" do
    test "the OLD target's edge is gone and the NEW target's edge exists the instant publish returns" do
      publish!("author", "author-alan")
      publish!("author", "author-grace")
      publish!("post", "post-07", %{"author" => "author-alan"})

      alan_pk = doc_pk("author-alan")
      grace_pk = doc_pk("author-grace")
      post_pk = doc_pk("post-07")

      # Established by the FIRST publish — this is the edge the second
      # publish must prune.
      assert alan_pk in outbound_targets(post_pk)

      {:ok, _} =
        Content.upsert_document(
          "post",
          %{"doc_id" => "post-07", "author" => "author-grace"},
          @dataset
        )

      # The assertion is the whole point: NOTHING ran the debounced
      # ProjectorWorker job (testing: :manual, no perform_job call anywhere in
      # this test) — only `publish_document/4` itself.
      {:ok, _published} = Content.publish_document("post-07", "post", @dataset)

      targets = outbound_targets(post_pk)
      refute alan_pk in targets, "stale edge to the OLD target must be gone when publish returns"
      assert grace_pk in targets, "the NEW target's edge must exist when publish returns"
    end

    test "holds for a doc whose CURRENT row came from createOrReplace, not just a fresh create" do
      publish!("author", "author-alan")
      publish!("author", "author-grace")
      doc1 = publish!("post", "post-replaced", %{"author" => "author-alan"})

      # `createOrReplace` on an EXISTING doc_id resolves to the exact same
      # `Content.create_document/4` call as a fresh birth (confirmed against
      # `Barkpark.Content.Mutations`'s `createOrReplace` clause, which always
      # calls `create_document/4` regardless of whether the id already
      # exists) — this is the row's own "current row came from createOrReplace"
      # scenario, replayed with the production function it actually calls.
      {:ok, _} =
        Content.create_document(
          "post",
          %{"_id" => "post-replaced", "title" => "post-replaced", "author" => "author-alan"},
          @dataset
        )

      {:ok, doc2} = Content.publish_document("post-replaced", "post", @dataset)
      assert doc1.id == doc2.id, "the published row's PK must stay stable across the replace"

      post_pk = doc2.id
      alan_pk = doc_pk("author-alan")
      grace_pk = doc_pk("author-grace")

      assert alan_pk in outbound_targets(post_pk)

      {:ok, _} =
        Content.upsert_document(
          "post",
          %{"doc_id" => "post-replaced", "author" => "author-grace"},
          @dataset
        )

      {:ok, _} = Content.publish_document("post-replaced", "post", @dataset)

      targets = outbound_targets(post_pk)
      refute alan_pk in targets, "stale edge to the OLD target must be gone when publish returns"
      assert grace_pk in targets, "the NEW target's edge must exist when publish returns"
    end

    test "a fresh first publish projects its own edge with no job execution" do
      publish!("author", "author-alan")
      doc = publish!("post", "post-fresh", %{"author" => "author-alan"})

      assert doc_pk("author-alan") in outbound_targets(doc.id)
    end
  end

  describe "fallback — a doc with no resolvable _id never crashes the hook" do
    test "enqueue_rebuild/1 on an :after_publish payload with no usable doc id is a no-op, not a raise" do
      payload = %{event: :after_publish, doc: %{}, dataset: @dataset, ctx: %{}}

      assert :ok = Barkpark.EdgeProjector.Lifecycle.enqueue_rebuild(payload)
    end
  end

  defp doc_pk(doc_id) do
    pub = Content.published_id(doc_id)

    Barkpark.Repo.get_by!(Barkpark.Content.Document, doc_id: pub, dataset: @dataset).id
  end

  # Mutation-proof seam: a test that only ever reads `Content.list_outbound_edges/1`
  # cannot tell "no edges were ever written" from "edges were written and then
  # removed" — assert the table is non-empty for the SURVIVING target directly
  # via the raw schema too, not just via the list helper.
  test "the surviving edge is a real content_edges row, not an artifact of the list helper" do
    publish!("author", "author-alan")
    doc = publish!("post", "post-raw-check", %{"author" => "author-alan"})

    assert Barkpark.Repo.get_by(Edge,
             from_id: doc.id,
             to_id: doc_pk("author-alan"),
             kind: "author"
           )
  end
end
