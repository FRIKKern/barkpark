defmodule Barkpark.Content.PaperRevisionRevLookupTest do
  @moduledoc """
  [rev-hash-has-no-read] A `_rev` hash could not be resolved to its content.

  The envelope publishes `"_rev" => doc.rev` (envelope.ex) on every document
  read, and acceptance criteria cite that hash to name the exact revision they
  sealed. But the `revisions` table carried NO `rev` column, and the only
  surfaced revision read — `Content.get_revision/3`, behind
  `GET /v1/data/revision/:dataset/:id` — keys on the revision row's own UUID.
  There was therefore no path, surfaced or un-surfaced, from a `_rev` hash to
  the content it names: `get_revision/3` rejected a non-UUID outright.

  Concretely: criteria 3, 6 and 7 on `important-paper-quality-wave-2-2026-07-31`
  cite `_rev` `207f04e54be05ee78b9f901a3a1b4c02`, which is neither the live rev
  of the document nor retrievable from history.

  The fix stamps `rev` onto each saved revision and resolves it through the
  EXISTING route: `GET /v1/data/revision/:dataset/:id` now accepts either a
  revision UUID or a `_rev` hash, so no new route and no new CLI verb is needed.

  LIMIT, stated honestly: only revisions written after this migration carry a
  `rev`. Pre-existing history rows have a NULL `rev` and stay unresolvable —
  the hash was never recorded, so it cannot be recovered.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content

  defp dataset, do: Content.paper_default_dataset()

  defp upsert(slug, text) do
    {:ok, doc} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          blocks: [%{"type" => "paragraph", "text" => text, "id" => "b1"}],
          style: "article"
        })
      )

    doc
  end

  describe "get_revision_by_rev/3" do
    test "a _rev hash resolves to the content that rev named" do
      slug = "rev-lookup-#{System.unique_integer([:positive])}"

      sealed = upsert(slug, "the sealed text")
      sealed_rev = sealed.rev
      assert is_binary(sealed_rev) and sealed_rev != ""

      # Now clobber it, exactly as the 2026-08-17 sweep did.
      upsert(slug, "the replacement text")

      opts = [workspace_id: sealed.workspace_id, project_id: sealed.project_id]

      # NOT `assert {:ok, rev} = ...,  "msg"`: a pattern match on the right of
      # `assert/2` raises MatchError BEFORE assert/2 ever runs, so the message
      # would be dead code. Match on a bound result instead.
      result = Content.get_revision_by_rev(sealed_rev, dataset(), opts)

      assert match?({:ok, _}, result),
             "the _rev a seal cited could not be resolved to any content — got #{inspect(result)}"

      {:ok, rev} = result

      assert rev.rev == sealed_rev

      text = rev.content |> Map.get("blocks") |> hd() |> Map.get("text")

      assert text == "the sealed text",
             "the resolved revision did not carry the sealed content — got #{inspect(text)}"
    end

    test "an unknown _rev hash is not_found, not a crash" do
      assert {:error, :not_found} =
               Content.get_revision_by_rev("207f04e54be05ee78b9f901a3a1b4c02", dataset(), [])
    end

    test "the surfaced single-revision read accepts a _rev hash as well as a UUID" do
      slug = "rev-lookup-surfaced-#{System.unique_integer([:positive])}"

      sealed = upsert(slug, "sealed")
      upsert(slug, "replaced")

      opts = [workspace_id: sealed.workspace_id, project_id: sealed.project_id]

      # The UUID form keeps working…
      {:ok, by_rev} = Content.get_revision_by_rev(sealed.rev, dataset(), opts)
      assert {:ok, by_uuid} = Content.get_revision(by_rev.id, dataset(), opts)
      assert by_uuid.id == by_rev.id

      # …and both name the same snapshot.
      assert by_uuid.content == by_rev.content
    end
  end
end
