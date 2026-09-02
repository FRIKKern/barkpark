defmodule Barkpark.Content.Papers.TemplateTest do
  @moduledoc """
  Locks the content-first doctrine's enforcement core (pdd-t1/t3/t4):
  seed on new-blank, derive doc.title from the locked title block, gate the
  template shape, and the op backstops (no remove/move/unlock of a locked
  block by any client).
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Papers.Template
  alias Barkpark.PortableDoc.Patch

  # ── pure template unit truths ────────────────────────────────────────────

  test "seed: a NEW paper with an explicit empty block list is born as a document" do
    blocks = Template.maybe_seed([], nil, %{"title" => "My paper"})
    # Only the required minimum is seeded (D11): the locked title + an empty body
    # paragraph. The optional featured slot is a ghost affordance, NOT a birth block.
    assert [%{"role" => "title", "locked" => true, "text" => "My paper"}, body] = blocks
    assert body["id"] == "tpl-body" and body["type"] == "paragraph"
    refute Enum.any?(blocks, &(&1["role"] == "featured"))
  end

  # task-a945b98cfd8d941f — the title argument is CONTENT. A title-less birth
  # must seed an EMPTY heading, because whatever lands in "text" is text the
  # author has to delete before typing (the Studio seeded the literal
  # "Untitled" here, so the first keystroke appended to it). The second half
  # pins that a REAL title still round-trips verbatim — the fix must not gut
  # the API caller who genuinely supplies one.
  test "seed: a title-less paper is born with an EMPTY title block, not a literal" do
    assert [%{"id" => "tpl-title", "text" => ""}] = Template.template_blocks(nil)
    assert [%{"id" => "tpl-title", "text" => ""}] = Template.template_blocks("")

    # and an empty title block derives NO row title — the display fallbacks own
    # the word "Untitled", the stored document does not.
    refute Map.has_key?(Template.derive_title(%{}, Template.template_blocks(nil)), "title")

    # a caller-supplied title is still copied verbatim (unchanged behaviour)
    assert [%{"text" => "A real title"}] = Template.template_blocks("A real title")

    # the birth path agrees: no title in attrs ⇒ an empty locked heading
    assert [%{"role" => "title", "text" => ""}, %{"id" => "tpl-body"}] =
             Template.maybe_seed([], nil, %{})
  end

  test "seed: existing docs, nil blocks (HTML-only path) and explicit blocks untouched" do
    assert Template.maybe_seed(nil, nil, %{}) == nil
    assert Template.maybe_seed([%{"type" => "paragraph"}], nil, %{}) == [%{"type" => "paragraph"}]
    assert Template.maybe_seed([], %{id: "existing"}, %{}) == []
  end

  test "seed: template opt-in prepends onto provided blocks once" do
    blocks =
      Template.maybe_seed([%{"type" => "paragraph"}], nil, %{"template" => true, "title" => "T"})

    # Optional slots are not injected — only the locked title is prepended.
    assert [%{"role" => "title"}, %{"type" => "paragraph"}] = blocks
    refute Enum.any?(blocks, &(&1["role"] == "featured"))
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

    # a locked featured before the locked title: the title is off block 0 → a
    # calm, specific order violation.
    [title] = Template.template_blocks("t")
    featured = %{"id" => "f", "type" => "image", "role" => "featured", "locked" => true}
    msgs = Template.validate([featured, title])
    assert Enum.any?(msgs, &(&1 =~ "block 0"))

    # locked doc missing its title block entirely
    assert [msg2] = Template.validate([%{"type" => "paragraph", "locked" => true}])
    assert msg2 =~ "missing"
  end

  # ── the constraint-vocabulary byte-compat matrix (pdd-t20) ────────────────

  # A locked featured block for the fixtures that need the OLD seeded shape.
  defp locked_featured(id \\ "tpl-featured") do
    %{"id" => id, "type" => "image", "role" => "featured", "locked" => true}
  end

  defp locked_ingress(id \\ "ing") do
    %{"id" => id, "type" => "paragraph", "role" => "ingress", "locked" => true}
  end

  describe "validate/1 — the paper declarations, byte-compatibly" do
    test "legacy no-locked papers are untouched (D3)" do
      assert Template.validate([%{"type" => "paragraph"}, %{"type" => "image"}]) == []
    end

    test "the OLD seeded shape (title@0 + featured@1) still validates clean" do
      [title] = Template.template_blocks("t")
      assert Template.validate([title, locked_featured()]) == []
    end

    test "a title-only paper validates clean (the new birth shape)" do
      assert Template.validate(Template.template_blocks("t")) == []
    end

    test "featured before title is a calm order error" do
      [title] = Template.template_blocks("t")
      msgs = Template.validate([locked_featured(), title])
      assert msgs != []
    end

    test "two featured blocks trip the max-1 cardinality error" do
      [title] = Template.template_blocks("t")
      msgs = Template.validate([title, locked_featured("f1"), locked_featured("f2")])
      assert Enum.any?(msgs, &(&1 =~ "at most 1" and &1 =~ "featured"))
    end

    test "an ingress between the title and featured validates clean" do
      [title] = Template.template_blocks("t")
      assert Template.validate([title, locked_ingress(), locked_featured()]) == []
    end

    test "an ingress AFTER the featured is a relative-order error" do
      [title] = Template.template_blocks("t")
      msgs = Template.validate([title, locked_featured(), locked_ingress()])
      assert Enum.any?(msgs, &(&1 =~ "ingress" and &1 =~ "before" and &1 =~ "featured"))
    end

    test "a paper that carries a locked block but no title is missing-required" do
      msgs = Template.validate([%{"type" => "paragraph", "locked" => true}])
      assert Enum.any?(msgs, &(&1 =~ "required" and &1 =~ "title" and &1 =~ "missing"))
    end

    test "a role:title block that is NOT a heading is rejected (byte-compat with the old gate)" do
      # The generic vocabulary has no type axis; the paper rule "the title IS a
      # heading" (derive_title reads its text; the reader renders the <h1>) must
      # survive the re-expression — a raw API replace could otherwise swap it.
      impostor = %{
        "id" => "t",
        "type" => "paragraph",
        "role" => "title",
        "locked" => true,
        "text" => "x"
      }

      msgs = Template.validate([impostor])
      assert Enum.any?(msgs, &(&1 =~ "title" and &1 =~ "heading"))
    end
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
    # The locked prefix is title + featured; featured is now constructed here (no
    # longer seeded) so the displacement backstops keep their coverage.
    featured = %{
      "id" => "tpl-featured",
      "type" => "image",
      "role" => "featured",
      "locked" => true
    }

    blocks = Template.template_blocks("t") ++ [featured, %{"id" => "p1", "type" => "paragraph"}]
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

  test "upsert_paper: new paper is seeded; title derives; gate blocks a violated save" do
    slug = "tpl-#{System.unique_integer([:positive])}"

    # blocks: [] (a bare hollow stub) is refused by the hollow-body quality
    # gate (p-quality-gate — see hollow_test.exs), so the template birth is
    # exercised via the explicit opt-in with a real body block.
    {:ok, doc} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          template: true,
          blocks: [
            %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "Body."}]}
          ],
          title: "Born as a document"
        })
      )

    blocks = doc.content["blocks"]
    assert [%{"role" => "title", "text" => "Born as a document"} | _] = blocks
    assert doc.title == "Born as a document"

    # editing the title block re-derives the row title (one truth)
    edited = List.update_at(blocks, 0, &Map.put(&1, "text", "Renamed in the body"))

    {:ok, doc2} =
      Content.upsert_paper(Barkpark.LabelFixtures.paper_attrs(%{slug: slug, blocks: edited}))

    assert doc2.title == "Renamed in the body"

    # a save that demotes the title block off position 0 is halted by the gate
    [title | rest] = doc2.content["blocks"]

    assert {:error, {:halted, reason}} =
             Content.upsert_paper(
               Barkpark.LabelFixtures.paper_attrs(%{slug: slug, blocks: rest ++ [title]})
             )

    assert reason =~ "template"
  end

  test "upsert_paper: legacy papers (no locked blocks) save exactly as before" do
    slug = "legacy-#{System.unique_integer([:positive])}"

    {:ok, doc} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          blocks: [
            %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "legacy body"}]}
          ]
        })
      )

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
  use Barkpark.DataCase, async: true

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

    # template: true + a real body block — a bare blocks: [] stub is refused
    # by the hollow-body quality gate (p-quality-gate).
    {:ok, doc} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          template: true,
          blocks: [
            %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "Body."}]}
          ],
          title: "Article born"
        })
      )

    assert doc.content["style"] == "article"
    assert doc.content["body_html"] =~ "<h1"
    refute doc.content["body_html"] =~ ~s(font-weight:bold">Article born)
  end

  test "block ops honor the caller's workspace scope (the scoped-Studio fix)" do
    ws = TenancyFixtures.create_workspace!()
    slug = "scoped-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          blocks: [
            %{
              "id" => "p1",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "seed body"}]
            }
          ],
          workspace_id: ws.id
        })
      )

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
  use Barkpark.DataCase, async: true
  alias Barkpark.Content
  alias Barkpark.Content.Papers.Template

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

    # Only the locked title is seeded now (D11) — the featured slot is a ghost
    # affordance, not a birth block.
    assert [%{"role" => "title", "text" => "Born via Writer"} | _] = doc.content["blocks"]
    refute Enum.any?(doc.content["blocks"], &(&1["role"] == "featured"))

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

  # ── pdd-t20c: the constraint vocabulary (client_declarations/0 — the JSON wire form) ─────────────

  describe "client_declarations/0 — the wire form the editor consumes" do
    test "declares title required exactly-1 @top locked" do
      title = Enum.find(Template.client_declarations(), &(&1["kind"] == "title"))

      assert title["role"] == "title"
      assert title["presence"] == "required"
      assert title["count"] == %{"exactly" => 1}
      assert title["position"] == "top"
      assert title["locked"] == true
    end

    test "declares featured optional max-1 after(title) locked" do
      featured = Enum.find(Template.client_declarations(), &(&1["kind"] == "featured"))

      assert featured["presence"] == "optional"
      assert featured["count"] == %{"max" => 1}
      assert featured["position"] == %{"after" => "title"}
      assert featured["locked"] == true
    end

    test "declares ingress optional max-1 after(title) before(featured) unlocked" do
      ingress = Enum.find(Template.client_declarations(), &(&1["kind"] == "ingress"))

      assert ingress["presence"] == "optional"
      assert ingress["count"] == %{"max" => 1}
      assert ingress["position"] == %{"after" => "title", "before" => "featured"}
      assert ingress["locked"] == false
    end

    test "the declared order is title, ingress, featured (the enforced document order)" do
      assert Enum.map(Template.client_declarations(), & &1["kind"]) ==
               ["title", "ingress", "featured"]
    end

    test "JSON-encodes cleanly for the data-constraints stamp" do
      json = Jason.encode!(Template.client_declarations())
      assert {:ok, decoded} = Jason.decode(json)
      assert length(decoded) == 3
    end
  end
end
