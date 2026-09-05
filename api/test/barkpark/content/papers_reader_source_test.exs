defmodule Barkpark.Content.PapersReaderSourceTest do
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Content.Document

  test "anonymous reader schema is selected from the Paper tenant and redacted caches stay closed" do
    dataset = "reader-scope-#{System.unique_integer([:positive])}"
    {default_ws, default_project} = ensure_default_scope!()
    other_ws = create_workspace!("reader-schema-other")
    other_project = create_project!(other_ws, "reader-schema-other-project")

    public_blocks = %{
      "name" => "paper",
      "title" => "Paper",
      "fields" => [%{"name" => "blocks", "type" => "array"}]
    }

    private_blocks = put_in(public_blocks, ["fields", Access.at(0), "private"], true)

    {:ok, _} =
      Content.upsert_schema(public_blocks, dataset,
        workspace_id: other_ws.id,
        project_id: other_project.id
      )

    {:ok, _} =
      Content.upsert_schema(private_blocks, dataset,
        workspace_id: default_ws.id,
        project_id: default_project.id
      )

    {:ok, seed} =
      Content.create_document(
        "post",
        %{"doc_id" => "reader-schema-seed", "title" => "Seed"},
        dataset,
        workspace_id: default_ws.id,
        project_id: default_project.id
      )

    blocks = [%{"id" => "secret", "type" => "paragraph", "text" => "Tenant secret"}]

    body_html =
      Barkpark.PortableDoc.Render.render_blocks(
        blocks,
        Barkpark.Content.Labels.paper_render_opts(dataset, nil,
          workspace_id: default_ws.id,
          project_id: default_project.id
        )
      )

    paper = %{
      seed
      | type: "paper",
        content: %{
          "body" => %{"blocks" => blocks},
          "body_html" => body_html
        }
    }

    # The foreign public schema must not override the Paper tenant's private
    # schema, and the derived HTML cache must not reopen the redacted prose.
    assert {:error, :redacted_source} = Content.Papers.reader_source(paper, dataset, [])

    {:ok, _} =
      Content.upsert_schema(public_blocks, dataset,
        workspace_id: default_ws.id,
        project_id: default_project.id
      )

    assert {:blocks, ^blocks} = Content.Papers.reader_source(paper, dataset, [])
  end

  test "semantic source authority rejects empty, malformed, and unknown-unlabeled blocks" do
    for blocks <- [[], [%{"text" => "missing type"}], [%{"type" => "future-widget"}]] do
      paper = %Document{
        doc_id: "invalid",
        dataset: "test",
        type: "paper",
        title: "Invalid",
        content: %{"blocks" => blocks}
      }

      assert {:error, _reason} = Content.Papers.reader_source(paper, "test", [])
    end

    labeled = [%{"type" => "future-widget", "aria-label" => "Accessible future content"}]

    paper = %Document{
      doc_id: "future",
      dataset: "test",
      type: "paper",
      title: "Future",
      content: %{"blocks" => labeled}
    }

    assert {:blocks, ^labeled} = Content.Papers.reader_source(paper, "test", [])
  end

  test "HTML-only source is sanitized without changing safe bytes and unstamped mixed provenance serves blocks" do
    html = "<h1>Exact &amp; authored</h1>\n<p>two spaces  stay</p>"

    legacy = %Document{
      doc_id: "legacy",
      dataset: "test",
      type: "paper",
      title: "Legacy",
      content: %{"body_html" => html}
    }

    assert {:html, ^html} = Content.Papers.reader_source(legacy, "test", [])

    poisoned = %Document{
      legacy
      | doc_id: "poisoned-legacy",
        content: %{
          "body_html" =>
            ~s|<form action="https://evil.example"><input name="token"></form><script>alert(1)</script><p>Readable</p>|
        }
    }

    assert {:html, "<p>Readable</p>"} =
             Content.Papers.reader_source(poisoned, "test", [])

    script_only = %Document{
      legacy
      | doc_id: "script-only-legacy",
        content: %{"body_html" => "<script>steal()</script>"}
    }

    assert {:error, :semantic_empty} =
             Content.Papers.reader_source(script_only, "test", [])

    blocks = [
      %{
        "id" => "body",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "Blocks"}]
      }
    ]

    mixed = %Document{
      doc_id: "mixed",
      dataset: "test",
      type: "paper",
      title: "Mixed",
      content: %{"blocks" => blocks, "body_html" => "<p>Different richer HTML</p>"}
    }

    # An unstamped mixed row claims nothing about the current renderer, so since
    # pe-w2-reader-stamp-guard it is LAGGING, not divergent: blocks are
    # canonical, the derived HTML cache is rewritten. Only a row stamped with the
    # current digest can still fail closed — pinned in
    # test/barkpark/content/papers/reader_lagging_stamp_test.exs.
    assert {:blocks, ^blocks} = Content.Papers.reader_source(mixed, "test", [])
  end

  test "reader source rejects punctuation-only block and HTML bodies" do
    punctuation_blocks = [
      %{
        "id" => "body",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => " / — "}]
      }
    ]

    block_paper = %Document{
      doc_id: "punctuation-blocks",
      dataset: "test",
      type: "paper",
      title: "Punctuation blocks",
      content: %{"blocks" => punctuation_blocks}
    }

    html_paper = %Document{
      doc_id: "punctuation-html",
      dataset: "test",
      type: "paper",
      title: "Punctuation HTML",
      content: %{"body_html" => ~s(<p> / &mdash; </p><img alt="/">)}
    }

    assert {:error, :semantic_empty} = Content.Papers.reader_source(block_paper, "test", [])
    assert {:error, :semantic_empty} = Content.Papers.reader_source(html_paper, "test", [])

    for body <- [
          ~s(<p hidden>Invisible prose</p>),
          ~s(<p aria-hidden="true">Invisible prose</p>),
          ~s(<div hidden><div>nested</div><p>still hidden</p></div>),
          ~s(<span aria-label="Metadata only"></span>),
          ~s(<span title="Metadata only"></span>),
          ~s(<img hidden alt="Invisible diagram">),
          ~s(<img aria-hidden="true" alt="Invisible diagram">),
          ~s(<p>&mdash;</p>)
        ] do
      hidden = %Document{html_paper | doc_id: "hidden", content: %{"body_html" => body}}
      assert {:error, :semantic_empty} = Content.Papers.reader_source(hidden, "test", [])
    end

    for body <- [~s(<p>&#x49;</p>), ~s(<p>&copy;</p>), ~s(<img alt="Diagram">)] do
      visible = %Document{html_paper | doc_id: "visible", content: %{"body_html" => body}}
      assert {:html, ^body} = Content.Papers.reader_source(visible, "test", [])
    end
  end

  test "first BlockOp against HTML-only source fails closed without changing bytes or revision" do
    slug = "html-blockop-fence-#{System.unique_integer([:positive])}"
    html = "<h1>Immutable</h1>\n<p>Authored &amp; byte-significant.</p>"

    {:ok, _written} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{slug: slug, dataset: "test", body_html: html})
      )

    # Re-read the baseline from the DB rather than trusting the struct the write
    # RETURNED. A paper upsert now records a revision ([paper-upsert-unlogged-clobber]),
    # and the `bind_document_revision` trigger advances `documents.current_revision_id`
    # AFTER the returning struct was built — so the in-memory struct is stale in
    # exactly that one column. Comparing two fresh reads keeps this assertion's
    # meaning intact (the halted op changed nothing) without asserting against a
    # value the write path never populated in memory.

    before = Content.get_paper(slug, "test")

    op = %{
      "op" => "append-block",
      "block" => %{"id" => "new", "type" => "paragraph", "text" => "destructive"}
    }

    assert {:error, {:halted, message}} = Content.apply_paper_block_op(slug, op, "test")
    assert message =~ "HTML-only papers are read-only"
    assert Content.get_paper(slug, "test") == before

    assert {:error, {:halted, _}} = Content.apply_paper_block_ops(slug, [op], "test")
    assert Content.get_paper(slug, "test") == before

    assert {:error, {:halted, _}} =
             Content.apply_paper_block_ops(slug, [op], "test", if_rev: 1)

    assert Content.get_paper(slug, "test") == before
  end

  test "revision-fenced batch promotes legacy body.blocks without treating it as HTML-only" do
    slug = "legacy-body-blocks-fence-#{System.unique_integer([:positive])}"
    html = "<p>Legacy authored body</p>"

    {:ok, seeded} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{slug: slug, dataset: "test", body_html: html})
      )

    legacy_blocks = [
      %{
        "id" => "legacy-body",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "Legacy authored body"}]
      }
    ]

    legacy_content =
      seeded.content
      |> Map.delete("blocks")
      |> Map.put("body", %{"blocks" => legacy_blocks})
      |> Map.put("body_html", html)
      |> Map.put("rev", 7)

    {:ok, _written_legacy} =
      seeded
      |> Document.changeset(%{"content" => legacy_content})
      |> Barkpark.Repo.update()

    # Re-read the baseline from the DB rather than trusting the struct the write
    # RETURNED. A paper upsert now records a revision ([paper-upsert-unlogged-clobber]),
    # and the `bind_document_revision` trigger advances `documents.current_revision_id`
    # AFTER the returning struct was built — so the in-memory struct is stale in
    # exactly that one column. Comparing two fresh reads keeps this assertion's
    # meaning intact (the halted op changed nothing) without asserting against a
    # value the write path never populated in memory.

    legacy = Content.get_paper(slug, "test")

    op = %{
      "op" => "append-block",
      "block" => %{
        "id" => "new-body",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "Safely promoted"}]
      }
    }

    assert {:error, {:halted, message}} =
             Content.apply_paper_block_ops(slug, [op], "test")

    assert message =~ "require an explicit revision-fenced batch conversion"
    assert Content.get_paper(slug, "test") == legacy

    assert {:error, :precondition_failed} =
             Content.apply_paper_block_ops(slug, [op], "test", if_rev: 6)

    assert Content.get_paper(slug, "test") == legacy

    assert {:ok, %{op_count: 1, rev: 8}} =
             Content.apply_paper_block_ops(slug, [op], "test", if_rev: 7)

    promoted = Content.get_paper(slug, "test")
    assert Enum.map(promoted.content["blocks"], & &1["id"]) == ["legacy-body", "new-body"]
    assert get_in(promoted.content, ["body", "blocks"]) == promoted.content["blocks"]
    assert promoted.content["body_html"] =~ "Legacy authored body"
    assert promoted.content["body_html"] =~ "Safely promoted"
  end
end
