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
