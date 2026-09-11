defmodule Barkpark.Content.PatchBoundFieldWritethroughTest do
  @moduledoc """
  task-d8785cff163c8013 — `doc patch --set` must PERSIST on a blocks-bearing
  document.

  `Writer.maybe_project_document_content/2` re-derives every projected
  `content[fieldName]` from `content["blocks"]` on any whole-document write
  carrying a block list. `Content.Mutations`' patch clauses merged the `set` map
  into `content` and handed it to `upsert_document/4` WITHOUT touching the bound
  block — so the projector overwrote the new value straight back to the
  create-time block value. The mutation answered 200 with a freshly bumped
  `_rev` and echoed the OLD value; only a read of the stored row showed the
  write was lost.

  EVERY assertion here reads the STORED ROW through `Repo`, never the mutation's
  response envelope — asserting on the envelope is precisely the mistake that
  made this defect invisible for as long as it lived.

  The `author` arm is the row's own NEGATIVE CONTROL: presence of a persisted
  `content["blocks"]` is the discriminator, `author` has none, and the patch
  landed correctly there all along. It must keep landing, and the document must
  keep having no block list — a "fix" that gave every type blocks would turn
  this test green while changing the storage shape of the whole CMS.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.{LabelFixtures, Repo, TenancyFixtures}

  @dataset "patch_bound_field_writethrough_test"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]
    LabelFixtures.register_tags!(@dataset)

    # `post` is Expectation-bearing: an EXPLICIT stored layout is what routes
    # create through `Writer.scaffold_expectation/3`, which persists one BOUND
    # block per layout field under content["blocks"] and projects. That is the
    # shape the defect needs.
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "slug", "type" => "slug"}
          ],
          "layout" => [
            %{"kind" => "field", "name" => "title"},
            %{"kind" => "field", "name" => "slug"},
            %{"kind" => "region", "name" => "body"}
          ]
        },
        @dataset,
        scope
      )

    # `author` carries NO layout, so it keeps the flat v1 initial-values path
    # and never gets a block list. The negative control.
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "author",
          "title" => "Author",
          "visibility" => "public",
          "fields" => [
            %{"name" => "name", "type" => "string"},
            %{"name" => "slug", "type" => "slug"}
          ]
        },
        @dataset,
        scope
      )

    %{scope: scope}
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp create!(type, id, title, content, scope) do
    {:ok, _} =
      Content.create_document(
        type,
        %{"doc_id" => id, "title" => title, "content" => content},
        @dataset,
        scope
      )

    id
  end

  defp patch(type, id, set_fields, scope) do
    Content.apply_mutations(
      [%{"patch" => %{"id" => id, "type" => type, "set" => set_fields}}],
      @dataset,
      [source: :api] ++ scope
    )
  end

  # THE STORED ROW. Not `Content.get_document/4` (which runs read-time
  # transforms) and emphatically not the mutation receipt.
  defp stored!(type, id) do
    Repo.get_by!(Document, doc_id: "drafts." <> id, type: type, dataset: @dataset)
  end

  defp bound_value(%Document{content: content}, field) do
    content
    |> Map.get("blocks", [])
    |> Enum.find(fn b ->
      is_map(b) and Map.get(b, "fieldName") == field
    end)
    |> case do
      nil -> :no_bound_block
      block -> Map.get(block, "value")
    end
  end

  describe "a blocks-bearing type (post) — the defect" do
    test "--set slug=X PERSISTS, in the stored content AND in the block it projects from",
         %{scope: scope} do
      id = uniq("wt-slug")
      create!("post", id, "T0", %{"slug" => "s0"}, scope)

      before = stored!("post", id)
      assert is_list(before.content["blocks"]), "the fixture must carry a block list"
      assert bound_value(before, "slug") == "s0"

      assert {:ok, {_tx, [_result]}} = patch("post", id, %{"slug" => "s-CHANGED"}, scope)

      row = stored!("post", id)

      # THE CRITERION. Before the fix this read "s0": a 200 and a new _rev over a
      # discarded value.
      assert row.content["slug"] == "s-CHANGED"

      # And the block projection re-derives the key FROM moved with it —
      # otherwise the very next whole-doc write would revert the field again.
      assert bound_value(row, "slug") == "s-CHANGED"
    end

    test "--set title=X leaves the column, content.title, the bound block and preview.title equal",
         %{scope: scope} do
      id = uniq("wt-title")
      create!("post", id, "T0", %{"slug" => "s0"}, scope)

      assert {:ok, {_tx, [_result]}} = patch("post", id, %{"title" => "T9"}, scope)

      row = stored!("post", id)

      assert row.title == "T9", "the row title COLUMN"
      assert row.content["title"] == "T9", "the projected content title"
      assert bound_value(row, "title") == "T9", "the bound title block"
      assert get_in(row.content, ["preview", "title"]) == "T9", "the preview card title"

      # All four in one breath, so a partial repair cannot pass.
      assert [row.title, row.content["title"], bound_value(row, "title")] ==
               ["T9", "T9", "T9"]
    end

    test "a patch never touches a bound block for a field it did not set", %{scope: scope} do
      id = uniq("wt-untouched")
      create!("post", id, "T0", %{"slug" => "s0"}, scope)

      assert {:ok, {_tx, [_result]}} = patch("post", id, %{"slug" => "s1"}, scope)

      row = stored!("post", id)
      assert bound_value(row, "title") == "T0"
      assert row.content["title"] == "T0"
    end

    test "the COMPOUND clause (set + unset) writes through too — it is a second door",
         %{scope: scope} do
      # `Mutations` has TWO patch heads: this one matches whenever any of
      # setIfMissing/unset/inc/dec/append/prepend rides along. Without its own
      # arm the compound door would keep discarding while the plain one healed.
      id = uniq("wt-ops")
      create!("post", id, "T0", %{"slug" => "s0", "scratch" => "x"}, scope)

      assert {:ok, {_tx, [_result]}} =
               Content.apply_mutations(
                 [
                   %{
                     "patch" => %{
                       "id" => id,
                       "type" => "post",
                       "set" => %{"slug" => "s-ops"},
                       "unset" => ["scratch"]
                     }
                   }
                 ],
                 @dataset,
                 [source: :api] ++ scope
               )

      row = stored!("post", id)
      assert row.content["slug"] == "s-ops"
      assert bound_value(row, "slug") == "s-ops"
      refute Map.has_key?(row.content, "scratch")
    end

    test "the block-edit direction still wins: a patch that sets ONLY blocks projects from them",
         %{scope: scope} do
      id = uniq("wt-blockdir")
      create!("post", id, "T0", %{"slug" => "s0"}, scope)

      blocks =
        stored!("post", id).content["blocks"]
        |> Enum.map(fn b ->
          if Map.get(b, "fieldName") == "slug", do: Map.put(b, "value", "s-from-block"), else: b
        end)

      assert {:ok, {_tx, [_result]}} = patch("post", id, %{"blocks" => blocks}, scope)

      row = stored!("post", id)

      assert row.content["slug"] == "s-from-block",
             "projection remains the sole writer of content[fieldName] on a blocks write"

      assert bound_value(row, "slug") == "s-from-block"
    end
  end

  describe "a non-blocks type (author) — the negative control" do
    test "--set slug=X still lands, and the document still has NO block list", %{scope: scope} do
      id = uniq("wt-author")
      create!("author", id, "N0", %{"name" => "N0"}, scope)

      before = stored!("author", id)

      refute Map.has_key?(before.content, "blocks"),
             "author is the discriminator's other side — it must never gain a block list"

      assert {:ok, {_tx, [_result]}} = patch("author", id, %{"slug" => "a-NEW"}, scope)

      row = stored!("author", id)
      assert row.content["slug"] == "a-NEW"
      assert row.content["name"] == "N0"

      refute Map.has_key?(row.content, "blocks"),
             "the write-through must be inert on a blocks-less document"
    end
  end
end
