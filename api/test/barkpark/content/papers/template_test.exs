defmodule Barkpark.Content.Papers.TemplateTest do
  @moduledoc """
  Locks the content-first doctrine's enforcement core (pdd-t1/t3/t4):
  seed on new-blank, derive doc.title from the locked title block, gate the
  template shape, and the op backstops (no remove/move/unlock of a locked
  block by any client).
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.Papers.Template
  alias Barkpark.PortableDoc.Patch

  # ── pure template unit truths ────────────────────────────────────────────

  test "seed: a NEW paper with an explicit empty block list is born as a document" do
    blocks = Template.maybe_seed([], nil, %{"title" => "My paper"})
    assert [%{"role" => "title", "locked" => true, "text" => "My paper"}, featured, _p] = blocks
    assert featured["role"] == "featured" and featured["locked"] == true
  end

  test "seed: existing docs, nil blocks (HTML-only path) and explicit blocks untouched" do
    assert Template.maybe_seed(nil, nil, %{}) == nil
    assert Template.maybe_seed([%{"type" => "paragraph"}], nil, %{}) == [%{"type" => "paragraph"}]
    assert Template.maybe_seed([], %{id: "existing"}, %{}) == []
  end

  test "seed: template opt-in prepends onto provided blocks once" do
    blocks =
      Template.maybe_seed([%{"type" => "paragraph"}], nil, %{"template" => true, "title" => "T"})

    assert [%{"role" => "title"}, %{"role" => "featured"}, %{"type" => "paragraph"}] = blocks
    # idempotent: a title-carrying list is not re-seeded
    assert Template.maybe_seed(blocks, nil, %{"template" => true}) == blocks
  end

  test "derive_title: the locked title block IS the row title; legacy passes through" do
    attrs = Template.derive_title(%{"title" => "old"}, Template.template_blocks("The real title"))
    assert attrs["title"] == "The real title"

    assert Template.derive_title(%{"title" => "old"}, [%{"type" => "paragraph"}])["title"] ==
             "old"
  end

  test "validate: legacy (no locked blocks) passes; template shape is enforced when locked" do
    assert Template.validate([%{"type" => "paragraph"}]) == []
    assert Template.validate(Template.template_blocks("t")) == []

    # title not at 0 (and featured displaced too — both reported)
    [title, featured] = Template.template_blocks("t")
    msgs = Template.validate([featured, title])
    assert Enum.any?(msgs, &(&1 =~ "title block must be block 0"))

    # locked doc missing its title block entirely
    assert [msg2] = Template.validate([%{"type" => "paragraph", "locked" => true}])
    assert msg2 =~ "missing"
  end

  # ── op backstops (Patch) ─────────────────────────────────────────────────

  test "ops: remove/move of a locked block is rejected; patch cannot unlock or re-role" do
    blocks = Template.template_blocks("t") ++ [%{"id" => "p1", "type" => "paragraph"}]

    assert {:error, {:locked_block, "tpl-title", "remove-block"}} =
             Patch.apply_patches(blocks, [%{"op" => "remove-block", "id" => "tpl-title"}])

    assert {:error, {:locked_block, "tpl-title", "move-block"}} =
             Patch.apply_patches(blocks, [
               %{"op" => "move-block", "id" => "tpl-title", "after" => "p1"}
             ])

    {:ok, patched} =
      Patch.apply_patches(blocks, [
        %{
          "op" => "patch-block",
          "id" => "tpl-title",
          "patch" => %{"text" => "new", "locked" => false, "role" => "hax"}
        }
      ])

    title = Enum.find(patched, &(&1["id"] == "tpl-title"))
    assert title["text"] == "new"
    assert title["locked"] == true
    assert title["role"] == "title"

    # unlocked blocks keep full mobility
    assert {:ok, _} = Patch.apply_patches(blocks, [%{"op" => "remove-block", "id" => "p1"}])
  end

  test "ops: no op may DISPLACE a locked block — inserts into the prefix, moves to head, replace-away" do
    blocks = Template.template_blocks("t") ++ [%{"id" => "p1", "type" => "paragraph"}]
    new_block = %{"id" => "n1", "type" => "paragraph"}

    # insert-after the locked title lands BETWEEN title and featured — it would
    # push the locked featured from index 1 to 2 (the exact op a canvas Enter at
    # the end of the title run emits). Rejected as a locked-block violation.
    assert {:error, {:locked_block, "tpl-featured", "insert-after"}} =
             Patch.apply_patches(blocks, [
               %{"op" => "insert-after", "afterId" => "tpl-title", "block" => new_block}
             ])

    # moving an UNLOCKED block to the head displaces the whole locked prefix.
    assert {:error, {:locked_block, _id, "move-block"}} =
             Patch.apply_patches(blocks, [%{"op" => "move-block", "id" => "p1", "after" => nil}])

    # replace-block may not swap a locked block for an unlocked one — wholesale
    # replace would otherwise be a delete (and an unlock) in disguise.
    assert {:error, {:locked_block, "tpl-title", "replace-block"}} =
             Patch.apply_patches(blocks, [
               %{
                 "op" => "replace-block",
                 "id" => "tpl-title",
                 "block" => %{"id" => "tpl-title", "type" => "heading", "text" => "x"}
               }
             ])

    # BELOW the locked prefix the doc stays fully mutable: insert directly after
    # the featured block, and append at the end.
    assert {:ok, inserted} =
             Patch.apply_patches(blocks, [
               %{"op" => "insert-after", "afterId" => "tpl-featured", "block" => new_block}
             ])

    assert Enum.map(inserted, & &1["id"]) == ["tpl-title", "tpl-featured", "n1", "p1"]

    assert {:ok, _} =
             Patch.apply_patches(blocks, [%{"op" => "append-block", "block" => new_block}])

    # D3 additive: a lock-free doc keeps head-moves exactly as before.
    free = [%{"id" => "a", "type" => "paragraph"}, %{"id" => "b", "type" => "paragraph"}]

    assert {:ok, moved} =
             Patch.apply_patches(free, [%{"op" => "move-block", "id" => "b", "after" => nil}])

    assert Enum.map(moved, & &1["id"]) == ["b", "a"]
  end

  # ── end-to-end through upsert_paper + the before_save gate ──────────────

  test "upsert_paper: blank new paper is seeded; title derives; gate blocks a violated save" do
    slug = "tpl-#{System.unique_integer([:positive])}"

    {:ok, doc} = Content.upsert_paper(%{slug: slug, blocks: [], title: "Born as a document"})
    blocks = doc.content["blocks"]
    assert [%{"role" => "title", "text" => "Born as a document"} | _] = blocks
    assert doc.title == "Born as a document"

    # editing the title block re-derives the row title (one truth)
    edited = List.update_at(blocks, 0, &Map.put(&1, "text", "Renamed in the body"))
    {:ok, doc2} = Content.upsert_paper(%{slug: slug, blocks: edited})
    assert doc2.title == "Renamed in the body"

    # a save that demotes the title block off position 0 is halted by the gate
    [title | rest] = doc2.content["blocks"]

    assert {:error, {:halted, reason}} =
             Content.upsert_paper(%{slug: slug, blocks: rest ++ [title]})

    assert reason =~ "template"
  end

  test "upsert_paper: legacy papers (no locked blocks) save exactly as before" do
    slug = "legacy-#{System.unique_integer([:positive])}"

    {:ok, doc} =
      Content.upsert_paper(%{slug: slug, blocks: [%{"type" => "paragraph", "content" => []}]})

    assert [%{"type" => "paragraph"}] = doc.content["blocks"]
    refute Enum.any?(doc.content["blocks"], &Template.locked?/1)
  end
end

defmodule Barkpark.Content.Papers.TemplateStyleTest do
  @moduledoc """
  Live-polish fixes (pdd-t15 + the scoped-op finding, 2026-07-06):
  template papers are ARTICLE papers (the reader's h1 must match the canvas'
  h1 — rule 3), and block ops resolve the paper in the CALLER'S workspace.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.Papers.Template
  alias Barkpark.TenancyFixtures

  test "stamp_article_style: template papers become article; explicit + legacy untouched" do
    tpl = Template.template_blocks("t")
    assert Template.stamp_article_style(%{}, tpl)["style"] == "article"
    assert Template.stamp_article_style(%{"style" => "plain"}, tpl)["style"] == "plain"
    refute Map.has_key?(Template.stamp_article_style(%{}, [%{"type" => "paragraph"}]), "style")
  end

  test "upsert_paper: a template-born paper renders its title as a real <h1> (rule 3)" do
    slug = "art-#{System.unique_integer([:positive])}"
    {:ok, doc} = Content.upsert_paper(%{slug: slug, blocks: [], title: "Article born"})
    assert doc.content["style"] == "article"
    assert doc.content["body_html"] =~ "<h1"
    refute doc.content["body_html"] =~ ~s(font-weight:bold">Article born)
  end

  test "block ops honor the caller's workspace scope (the scoped-Studio fix)" do
    ws = TenancyFixtures.create_workspace!()
    slug = "scoped-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.upsert_paper(%{
        slug: slug,
        blocks: [%{"id" => "p1", "type" => "paragraph", "content" => []}],
        workspace_id: ws.id
      })

    op = %{"op" => "patch-block", "id" => "p1", "patch" => %{"content" => ["edited"]}}

    # WITH the caller's scope the op lands (what the LiveView now threads).
    assert {:ok, _} =
             Content.apply_paper_block_ops(slug, [op], "production", workspace_id: ws.id)

    # WITHOUT scope it resolves the seeded Default workspace and must NOT
    # silently mutate the other tenant's paper.
    assert {:error, _} = Content.apply_paper_block_ops(slug, [op], "production")
  end
end

defmodule Barkpark.Content.Papers.WriterSeamTest do
  @moduledoc "pdd-t16: the Writer/mutate path gives papers the same birth guarantee as upsert_paper."
  use Barkpark.DataCase, async: false
  alias Barkpark.Content

  test "create_document type paper with explicit [] blocks is born templated + article + derived title" do
    {:ok, doc} =
      Content.create_document(
        "paper",
        %{
          "doc_id" => "ws-#{System.unique_integer([:positive])}",
          "title" => "Born via Writer",
          "content" => %{"blocks" => []}
        },
        "production",
        []
      )

    assert [%{"role" => "title", "text" => "Born via Writer"}, %{"role" => "featured"} | _] =
             doc.content["blocks"]

    assert doc.content["style"] == "article"
    assert doc.title == "Born via Writer"
  end

  test "non-paper types and block-less papers are untouched" do
    {:ok, doc} =
      Content.create_document(
        "paper",
        %{
          "doc_id" => "nb-#{System.unique_integer([:positive])}",
          "title" => "HTML only",
          "content" => %{"body_html" => "<p>x</p>"}
        },
        "production",
        []
      )

    refute Map.has_key?(doc.content, "blocks")
    refute doc.content["style"] == "article"
  end
end
