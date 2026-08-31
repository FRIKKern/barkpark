defmodule Barkpark.Content.WriterFenceTest do
  @moduledoc """
  Protective tests for two content-write-path correctness fixes in the WRITE
  concern (`Barkpark.Content.Writer`), the update-side siblings of
  `Barkpark.Content.LifecycleFenceTest` (the delete-side fence).

  ## [ifmatch-unfenced-update]

  `patch` / `replace` validate `ifMatch`/`ifRevisionID` against the row they READ,
  then call `upsert_document`/`create_document` whose UPDATE branch USED to issue a
  plain `UPDATE … WHERE id = pk` — last write wins. A concurrent write committing
  between the guard read and the write was silently clobbered despite the
  precondition. The fix threads the asserted rev into the writer and fences the
  UPDATE `WHERE rev = expected`, returning the SAME `{:rev_mismatch, _}` (→ 412)
  the delete fence uses when 0 rows match.

  We drive that race with a `before_save` hook that bumps the just-read row's rev
  BEFORE the fenced UPDATE runs (the same seam `LifecycleFenceTest` uses). With an
  `ifMatch`, the fence rejects and the stale write never lands; WITHOUT one, the
  original last-write-wins behavior is preserved unchanged.

  ## [doc-id-collision-overwrite]

  `generate_id/1` now appends strong entropy, so an id-less create can no longer
  draw a colliding number and land as an UPDATE that overwrites an unrelated doc.

  `async: false` because the hook seam mutates the global `:barkpark, :plugins` env.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.Writer

  @dataset "writer_fence_test"
  @type_name "wpost"

  # A before_save hook that simulates a concurrent writer landing between the
  # mutation spine's guard read and the writer's fenced UPDATE: it rewrites the
  # just-read row's `rev` in place (via `prev_doc`, the struct the writer read),
  # then returns `:ok` so the write proceeds against a now-stale precondition.
  # Only fires when there IS a prev_doc (an UPDATE), never on a fresh insert.
  defmodule BumpHook do
    @moduledoc false
    import Ecto.Query
    alias Barkpark.Content.Document

    def lifecycle_hooks, do: %{before_save: [&__MODULE__.bump/1]}

    def bump(%{prev_doc: %Document{} = prev}) do
      {1, _} =
        Barkpark.Repo.update_all(
          from(d in Document, where: d.id == ^prev.id),
          set: [rev: "concurrent-" <> Integer.to_string(System.unique_integer([:positive]))]
        )

      :ok
    end

    def bump(_), do: :ok
  end

  setup do
    Content.upsert_schema(
      %{
        "name" => @type_name,
        "title" => "WPost",
        "visibility" => "public",
        "fields" => [%{"name" => "body", "type" => "string"}]
      },
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

  defp draft!(id, body) do
    {:ok, _} =
      Content.create_document(
        @type_name,
        %{"_id" => id, "title" => "T", "content" => %{"body" => body}},
        @dataset
      )

    {:ok, draft} = Content.get_document("drafts." <> id, @type_name, @dataset)
    draft
  end

  defp patch(id, body, extra) do
    op = %{
      "patch" => Map.merge(%{"id" => id, "type" => @type_name, "set" => %{"body" => body}}, extra)
    }

    Content.apply_mutations([op], @dataset)
  end

  # ── [ifmatch-unfenced-update] the lost-update race ────────────────────────

  test "fenced patch that loses a concurrent-rev race → rev_mismatch, stale write never lands",
       ctx do
    draft = draft!("race-patch", "original")
    :ok = with_plugins([BumpHook], ctx)

    # ifMatch asserts the rev we read; the hook bumps it before the fenced UPDATE.
    assert {:error, {:rev_mismatch, %{expected: expected, actual: actual}}} =
             patch("race-patch", "CLOBBER", %{"ifMatch" => draft.rev})

    assert expected == draft.rev
    assert actual != draft.rev

    # The whole batch rolled back: the stale "CLOBBER" write never persisted —
    # the row still holds its ORIGINAL content (pre-fix it would have been
    # overwritten despite the precondition).
    {:ok, after_doc} = Content.get_document("drafts.race-patch", @type_name, @dataset)
    assert after_doc.content["body"] == "original"
  end

  test "fenced replace that loses a concurrent-rev race → rev_mismatch", ctx do
    draft = draft!("race-replace", "original")
    :ok = with_plugins([BumpHook], ctx)

    op = %{
      "replace" => %{
        "_id" => "race-replace",
        "_type" => @type_name,
        "title" => "T",
        "content" => %{"body" => "CLOBBER"},
        "ifMatch" => draft.rev
      }
    }

    assert {:error, {:rev_mismatch, %{expected: expected}}} =
             Content.apply_mutations([op], @dataset)

    assert expected == draft.rev

    {:ok, after_doc} = Content.get_document("drafts.race-replace", @type_name, @dataset)
    assert after_doc.content["body"] == "original"
  end

  # ── non-ifMatch path is UNCHANGED (last-write-wins) ───────────────────────

  test "patch WITHOUT ifMatch during a concurrent bump still lands (last-write-wins)", ctx do
    draft!("no-ifmatch", "original")
    :ok = with_plugins([BumpHook], ctx)

    # No ifMatch supplied → no fence → the bump is clobbered, the write commits.
    assert {:ok, {_tx, [%{operation: "update"}]}} = patch("no-ifmatch", "WINS", %{})

    {:ok, after_doc} = Content.get_document("drafts.no-ifmatch", @type_name, @dataset)
    assert after_doc.content["body"] == "WINS"
  end

  # ── [doc-id-collision-overwrite] id entropy ───────────────────────────────

  test "generate_id/1 has a readable shape and negligible collision odds" do
    assert Regex.match?(~r/^post-[0-9a-f]{16}$/, Writer.generate_id("post"))

    ids = for _ <- 1..2000, do: Writer.generate_id("post")
    assert length(Enum.uniq(ids)) == 2000
  end

  test "an id-less create inserts a fresh row and never overwrites an existing doc" do
    keep = draft!("keep-me", "precious")

    # A create with NO _id: the writer generates one. Pre-fix a colliding random
    # number could have landed this as an UPDATE of an unrelated same-type doc.
    assert {:ok, {_tx, [%{id: new_id, operation: "create"}]}} =
             Content.apply_mutations(
               [
                 %{
                   "create" => %{
                     "_type" => @type_name,
                     "title" => "New",
                     "content" => %{"body" => "fresh"}
                   }
                 }
               ],
               @dataset
             )

    refute new_id == keep.doc_id

    # Both rows coexist; the original is byte-identical (not overwritten).
    {:ok, still} = Content.get_document("drafts.keep-me", @type_name, @dataset)
    assert still.content["body"] == "precious"
    assert {:ok, _} = Content.get_document(new_id, @type_name, @dataset)
  end
end
