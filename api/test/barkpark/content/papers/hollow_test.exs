defmodule Barkpark.Content.Papers.HollowTest do
  @moduledoc """
  The paper hollow-body quality gate (epic p-quality-gate, charter D2/D3):
  ONE predicate (`Barkpark.Content.Papers.Hollow`), enforced at the paper
  write seams.

    * `hollow?/1` — the D3 predicate: skeleton = locked ∪ role title/featured
      ∪ block[0]-when-heading; content = non-blank flattened text OR a
      non-text block with real payload; divider/blank text never count;
      docs without a blocks list are exempt.
    * `upsert_paper` — a hollow RESULT is refused, always (papers publish in
      place through this path), with the ratified hard-stop copy; real papers
      and HTML-only (pre-doctrine) writes save.
    * `apply_paper_block_op` / `apply_paper_block_ops` — the RATCHET: an edit
      may not hollow OUT a non-hollow paper; a still-hollow paper stays
      freely editable (fresh papers are hollow by construction).
  """

  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Content.Papers.{Hollow, Template}
  alias Barkpark.Repo

  @dataset "production"

  # ── fixtures ────────────────────────────────────────────────────────────

  defp locked_title(text \\ "The title") do
    %{
      "id" => "tpl-title",
      "type" => "heading",
      "level" => 1,
      "role" => "title",
      "locked" => true,
      "text" => text
    }
  end

  defp para(text, id \\ "p1") do
    %{"id" => id, "type" => "paragraph", "content" => [%{"type" => "text", "value" => text}]}
  end

  defp fresh_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # ── hollow?/1 — the D3 predicate ────────────────────────────────────────

  describe "hollow?/1" do
    test "the seeded fresh paper (locked title + empty tpl-body paragraph) IS hollow" do
      seeded = Template.maybe_seed([], nil, %{"title" => "Born hollow"})

      assert [%{"role" => "title"}, %{"id" => "tpl-body", "type" => "paragraph"}] = seeded
      assert Hollow.hollow?(seeded)
    end

    test "a whitespace-only paragraph does not count as content" do
      assert Hollow.hollow?([locked_title(), para("   \n\t ")])
    end

    test "punctuation-only prose is hollow while language, numbers, and symbols count" do
      assert Hollow.hollow?([locked_title(), para(" / — ")])
      refute Hollow.hollow?([locked_title(), para("I")])
      refute Hollow.hollow?([locked_title(), para("2")])
      refute Hollow.hollow?([locked_title(), para("∑")])
    end

    test "an image-only paper is NOT hollow (real payload, no text needed)" do
      refute Hollow.hollow?([%{"id" => "i1", "type" => "image", "src" => "/hero.jpg"}])
    end

    test "an image ghost with a blank src is NOT content" do
      assert Hollow.hollow?([locked_title(), %{"id" => "i1", "type" => "image", "src" => ""}])

      assert Hollow.hollow?([
               locked_title(),
               %{"id" => "i2", "type" => "image", "width" => 640, "height" => 480}
             ])
    end

    test "docs without a blocks list (body_html-only, pre-doctrine) are exempt" do
      refute Hollow.hollow?(nil)
      refute Hollow.hollow?("not-blocks")
    end

    test "a leading heading counts as skeleton for role-less legacy papers" do
      # The de-facto title of the un-migrated corpus: its text is NOT content.
      assert Hollow.hollow?([%{"id" => "h", "type" => "heading", "text" => "Legacy title"}])

      # …but real body text after it is.
      refute Hollow.hollow?([
               %{"id" => "h", "type" => "heading", "text" => "Legacy title"},
               para("Real body.")
             ])

      # A non-leading heading with text is ordinary content.
      refute Hollow.hollow?([
               para("  ", "blank"),
               %{"id" => "h2", "type" => "heading", "text" => "Section"}
             ])
    end

    test "role title/featured blocks are skeleton even when unlocked or filled" do
      assert Hollow.hollow?([
               %{"id" => "t", "type" => "heading", "role" => "title", "text" => "T"},
               %{"id" => "f", "type" => "image", "role" => "featured", "src" => "/hero.jpg"}
             ])
    end

    test "divider never counts" do
      assert Hollow.hollow?([locked_title(), %{"id" => "d", "type" => "divider"}])
    end

    test "non-text blocks with real payload count: table/code/diagram/sheet/task-list" do
      for block <- [
            %{"id" => "b", "type" => "table", "rows" => [["a", "b"]]},
            %{"id" => "b", "type" => "code", "lang" => "elixir", "code" => "IO.puts(:hi)"},
            %{"id" => "b", "type" => "diagram", "source" => "flowchart LR; a-->b"},
            %{"id" => "b", "type" => "sheet", "ref" => "budget-2026", "tab" => 0},
            %{"id" => "b", "type" => "task-list", "query" => %{"label" => "wave-1"}}
          ] do
        refute Hollow.hollow?([locked_title(), block]),
               "expected #{block["type"]} with payload to count as content"
      end
    end

    test "an empty code block (structure only) does not count" do
      assert Hollow.hollow?([
               locked_title(),
               %{"id" => "c", "type" => "code", "lang" => "elixir", "code" => "  "}
             ])
    end

    test "legacy flat-string list items flatten as text" do
      refute Hollow.hollow?([locked_title(), %{"id" => "l", "type" => "list", "items" => ["hi"]}])
      assert Hollow.hollow?([locked_title(), %{"id" => "l", "type" => "list", "items" => [" "]}])
    end

    test "a section counts through its children" do
      texty = %{"id" => "s", "type" => "section", "blocks" => [para("Nested body.")]}
      blank = %{"id" => "s", "type" => "section", "blocks" => [para("  ")]}

      refute Hollow.hollow?([locked_title(), texty])
      assert Hollow.hollow?([locked_title(), blank])
    end

    test "the ratified copy is stable" do
      assert Hollow.message() ==
               "This paper has a title but no content yet — add at least one body block."

      assert Hollow.ratchet_message() ==
               "This edit would remove the last content block — a published paper cannot be hollowed out to title-only."
    end
  end

  # ── upsert_paper — hard stop on a hollow result ─────────────────────────

  describe "upsert_paper hollow gate" do
    test "a hollow result is rejected with the ratified copy, and nothing persists" do
      slug = fresh_slug("hollow-upsert")

      # blocks: [] seeds the template (locked title + empty tpl-body) — the
      # canonical hollow stub a machine writer would POST.
      assert {:error, {:halted, msg}} =
               Content.upsert_paper(
                 Barkpark.LabelFixtures.paper_attrs(%{slug: slug, blocks: [], title: "Stub"})
               )

      assert msg == Hollow.message()
      assert Content.get_paper(slug, @dataset) == nil
    end

    test "an explicit title-only block list is rejected too" do
      slug = fresh_slug("hollow-explicit")

      assert {:error, {:halted, msg}} =
               Content.upsert_paper(
                 Barkpark.LabelFixtures.paper_attrs(%{slug: slug, blocks: [locked_title()]})
               )

      assert msg == Hollow.message()
    end

    test "positive control: a real paper (title + one body block) saves" do
      slug = fresh_slug("real-upsert")

      assert {:ok, doc} =
               Content.upsert_paper(
                 Barkpark.LabelFixtures.paper_attrs(%{
                   slug: slug,
                   blocks: [locked_title("Real paper"), para("A real body block.")]
                 })
               )

      assert doc.title == "Real paper"
      assert doc.status == "published"
    end

    test "HTML-only (pre-doctrine) writes stay exempt" do
      slug = fresh_slug("html-only")

      assert {:ok, doc} =
               Content.upsert_paper(
                 Barkpark.LabelFixtures.paper_attrs(%{slug: slug, body_html: "<p>legacy</p>"})
               )

      refute Map.has_key?(doc.content, "blocks")
    end
  end

  # ── the op-path RATCHET — both single-op and batch ──────────────────────

  # A real (non-hollow) published paper, via the front door.
  defp seed_real_paper! do
    slug = fresh_slug("ratchet")

    {:ok, doc} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          blocks: [locked_title("Ratchet paper"), para("The only content block.")]
        })
      )

    {slug, doc}
  end

  # A stored hollow paper (the legacy/pre-gate corpus shape): seed a real one
  # through the front door (so tenancy scope is stamped exactly like every
  # other paper), then hollow the ROW directly — the gate must not brick it.
  defp seed_stored_hollow_paper! do
    {slug, doc} = seed_real_paper!()

    {:ok, _} =
      doc
      |> Document.changeset(%{
        "content" => Map.put(doc.content, "blocks", [locked_title("Ratchet paper")])
      })
      |> Repo.update()

    slug
  end

  describe "apply_paper_block_op ratchet" do
    test "hollowing out a non-hollow paper halts, paper unchanged" do
      {slug, _doc} = seed_real_paper!()
      op = %{"op" => "remove-block", "id" => "p1"}

      assert {:error, {:halted, msg}} = Content.apply_paper_block_op(slug, op, @dataset)
      assert msg == Hollow.ratchet_message()

      # The paper still carries its content block — nothing was persisted.
      doc = Content.get_paper(slug, @dataset)
      assert Enum.any?(doc.content["blocks"], &(&1["id"] == "p1"))
    end

    test "blanking the only content block halts too (text edit, not removal)" do
      {slug, _doc} = seed_real_paper!()

      op = %{
        "op" => "patch-block",
        "id" => "p1",
        "patch" => %{"content" => [%{"type" => "text", "value" => "   "}]}
      }

      assert {:error, {:halted, msg}} = Content.apply_paper_block_op(slug, op, @dataset)
      assert msg == Hollow.ratchet_message()
    end

    test "ops on a still-hollow paper are allowed (fresh papers stay editable)" do
      slug = seed_stored_hollow_paper!()

      # A hollow-preserving edit (retitling) is free…
      retitle = %{
        "op" => "patch-block",
        "id" => "tpl-title",
        "patch" => %{"text" => "Renamed while hollow"}
      }

      assert {:ok, _} = Content.apply_paper_block_op(slug, retitle, @dataset)

      # …and so is the edit that ADDS the first content block.
      append = %{"op" => "append-block", "block" => para("First real content.", "new-p")}
      assert {:ok, _} = Content.apply_paper_block_op(slug, append, @dataset)

      doc = Content.get_paper(slug, @dataset)
      refute Hollow.hollow?(doc.content["blocks"])
    end
  end

  describe "apply_paper_block_ops ratchet (atomic batch)" do
    test "a batch that hollows out a non-hollow paper halts, paper unchanged" do
      {slug, _doc} = seed_real_paper!()

      assert {:error, {:halted, msg}} =
               Content.apply_paper_block_ops(
                 slug,
                 [%{"op" => "remove-block", "id" => "p1"}],
                 @dataset
               )

      assert msg == Hollow.ratchet_message()

      doc = Content.get_paper(slug, @dataset)
      assert Enum.any?(doc.content["blocks"], &(&1["id"] == "p1"))
    end

    test "the batch RESULT is judged, not the steps: remove + append lands" do
      {slug, _doc} = seed_real_paper!()

      ops = [
        %{"op" => "remove-block", "id" => "p1"},
        %{"op" => "append-block", "block" => para("Replacement content.", "p2")}
      ]

      assert {:ok, %{op_count: 2}} = Content.apply_paper_block_ops(slug, ops, @dataset)

      doc = Content.get_paper(slug, @dataset)
      refute Enum.any?(doc.content["blocks"], &(&1["id"] == "p1"))
      assert Enum.any?(doc.content["blocks"], &(&1["id"] == "p2"))
    end

    test "a batch on a still-hollow paper is allowed" do
      slug = seed_stored_hollow_paper!()

      ops = [%{"op" => "append-block", "block" => para("Batch-added content.", "b1")}]
      assert {:ok, %{op_count: 1}} = Content.apply_paper_block_ops(slug, ops, @dataset)
    end
  end
end
