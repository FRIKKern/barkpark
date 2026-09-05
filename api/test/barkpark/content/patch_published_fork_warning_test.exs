defmodule Barkpark.Content.PatchPublishedForkWarningTest do
  @moduledoc """
  A mutate PATCH naming a BARE published id returns 200 with
  `results[].id = "drafts.<id>"` and a fresh `_rev` that NO canonical reader
  will ever serve — `Writer.upsert_document` always draft-prefixes the write
  target while `/v1/data/doc`, `/v1/tasks/:id`, the board and the queue are all
  published-first. Measured live as PDS-D453 and re-measured a day later
  (pds-w33-bl-wrong-row-mutate-forks-published-tasks): 22 task rows carried a
  draft twin, 12 diverging from their published row on `lifecycle_status`, and
  the success envelope said `warnings: null` on every one of them.

  These tests pin the advisory that ends the silence. Semantics are unchanged —
  the patch still lands on the draft, exactly as before; only the receipt now
  says so. Two codes, because the two shapes carry different risk:

    * `patch.forked_published` — no draft existed; this patch mints the twin.
    * `patch.stale_draft_base` — a draft ALREADY existed, so the merge base was
      that draft rather than the published row the caller read. This is the
      half that lets a stale `lifecycle_status` ride forward into a later
      publish.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Warnings

  @dataset "patch_fork_test"
  @fork "patch.forked_published"
  @stale "patch.stale_draft_base"

  setup do
    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      @dataset
    )

    :ok
  end

  # A PUBLISHED row at the bare id, with no draft twin left behind.
  defp seed_published(id) do
    {:ok, {_tx, [_created]}} =
      Content.apply_mutations(
        [
          %{
            "create" => %{
              "_id" => id,
              "_type" => "post",
              "title" => "T",
              "content" => %{"blocks" => [], "lifecycle_status" => "done"}
            }
          }
        ],
        @dataset,
        []
      )

    {:ok, _doc} = Content.publish_document(id, "post", @dataset, [])
    :ok
  end

  # Mirror the controller: open the queue (reset), apply, drain the advisories.
  defp patch_warnings(id, set_fields) do
    Warnings.reset()

    {:ok, {_tx, _results}} =
      Content.apply_mutations(
        [%{"patch" => %{"id" => id, "type" => "post", "set" => set_fields}}],
        @dataset,
        []
      )

    Warnings.drain()
  end

  test "a patch on a bare PUBLISHED id warns that it wrote a draft twin no reader serves" do
    id = "pf-fresh"
    seed_published(id)

    warnings = patch_warnings(id, %{"lifecycle_status" => "open"})

    entry = Enum.find(warnings, &(&1.code == @fork))
    assert entry, "expected a #{@fork} advisory, got: #{inspect(warnings)}"
    assert entry.severity == "warning"
    assert entry.message =~ "drafts.#{id}"
    assert entry.message =~ "published-first"
    assert entry.message =~ "minted a NEW draft twin"
  end

  test "a SECOND patch, whose base is the existing stale draft, warns with the stale-base code" do
    id = "pf-stale"
    seed_published(id)

    # First patch forks the twin …
    _ = patch_warnings(id, %{"lifecycle_status" => "open"})

    # … the second one merges onto THAT draft, not the published row.
    warnings = patch_warnings(id, %{"note" => "second edit"})

    entry = Enum.find(warnings, &(&1.code == @stale))
    assert entry, "expected a #{@stale} advisory, got: #{inspect(warnings)}"
    assert entry.severity == "warning"
    assert entry.message =~ "the merge base was that EXISTING draft"
    assert entry.message =~ "lifecycle_status"

    refute Enum.any?(warnings, &(&1.code == @fork)),
           "the twin already existed — this patch minted nothing, got: #{inspect(warnings)}"
  end

  test "the published row keeps serving the OLD content — the advisory is telling the truth" do
    id = "pf-truth"
    seed_published(id)

    _ = patch_warnings(id, %{"lifecycle_status" => "open"})

    {:ok, published} = Content.get_document(id, "post", @dataset, [])

    assert published.content["lifecycle_status"] == "done",
           "the patch reported success but the published reader must still serve the old row"
  end

  test "a patch naming an ALREADY-draft id warns nothing — the caller asked for the draft" do
    id = "pf-explicit"
    seed_published(id)
    _ = patch_warnings(id, %{"lifecycle_status" => "open"})

    warnings = patch_warnings("drafts." <> id, %{"note" => "explicit draft edit"})

    refute Enum.any?(warnings, &(&1.code in [@fork, @stale])),
           "a caller who names drafts.<id> is not being surprised, got: #{inspect(warnings)}"
  end
end
