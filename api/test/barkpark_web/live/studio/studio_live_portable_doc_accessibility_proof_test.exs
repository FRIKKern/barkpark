defmodule BarkparkWeb.Studio.StudioLivePortableDocAccessibilityProofTest do
  @moduledoc """
  Deterministic Studio/LiveView proof for a candidate PortableDoc.

  This harness has two explicit rails:

    * the server-rendered Studio View rail proves the candidate's heading
      hierarchy, semantic lists, link, and byte reuse of the canonical
      `Render.render_block/2` producer;
    * the default always-editable canvas rail proves LiveView hands the exact
      candidate blocks to the client canvas while preserving named landmarks,
      keyboard-native controls, and live status regions.

  No browser geometry or JavaScript execution is claimed here. The assertions
  stop at the deterministic HTML/LiveView boundary they can actually observe.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.PortableDoc.Render

  @dataset "production"
  @slug "portable-doc-accessibility-candidate"
  @title "PortableDoc accessibility candidate"

  @candidate_blocks [
    %{
      "id" => "candidate-title",
      "type" => "heading",
      "level" => 1,
      "text" => @title
    },
    %{
      "id" => "candidate-evidence",
      "type" => "heading",
      "level" => 2,
      "text" => "Evidence"
    },
    %{
      "id" => "candidate-link",
      "type" => "paragraph",
      "content" => [
        %{
          "type" => "link",
          "href" => "https://example.com/evidence",
          "children" => [%{"type" => "text", "value" => "Read the evidence"}]
        }
      ]
    },
    %{
      "id" => "candidate-bullets",
      "type" => "list",
      "ordered" => false,
      "items" => [
        [%{"type" => "text", "value" => "Heading hierarchy"}],
        [%{"type" => "text", "value" => "Semantic list structure"}]
      ]
    },
    %{
      "id" => "candidate-steps-heading",
      "type" => "heading",
      "level" => 3,
      "text" => "Verification steps"
    },
    %{
      "id" => "candidate-steps",
      "type" => "list",
      "ordered" => true,
      "items" => [
        [%{"type" => "text", "value" => "Open Studio"}],
        [%{"type" => "text", "value" => "Inspect the candidate"}]
      ]
    }
  ]

  setup do
    previous_canvas = System.get_env("BARKPARK_PAPER_CANVAS")
    System.put_env("BARKPARK_PAPER_CANVAS", "0")

    on_exit(fn ->
      case previous_canvas do
        nil -> System.delete_env("BARKPARK_PAPER_CANVAS")
        value -> System.put_env("BARKPARK_PAPER_CANVAS", value)
      end
    end)

    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => "paper",
          "title" => "Papers",
          "icon" => "file-text",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: @slug,
          title: @title,
          dataset: @dataset,
          blocks: @candidate_blocks
        })
      )

    :ok
  end

  test "Studio View preserves heading order, semantic lists, links, and canonical render bytes",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))

    editor_html =
      view
      |> element(~s([data-test-id="studio-paper-editor"]))
      |> render()

    editor = LazyHTML.from_fragment(editor_html)

    assert editor |> LazyHTML.query("article h1, article h2, article h3") |> LazyHTML.tag() ==
             ["h1", "h2", "h3"]

    assert one_text(editor, "article h1") == @title
    assert one_text(editor, "article h2") == "Evidence"
    assert one_text(editor, "article h3") == "Verification steps"

    assert editor |> LazyHTML.query("article ul") |> Enum.count() == 1
    assert editor |> LazyHTML.query("article ul > li") |> Enum.count() == 2
    assert editor |> LazyHTML.query("article ol") |> Enum.count() == 1
    assert editor |> LazyHTML.query("article ol > li") |> Enum.count() == 2

    evidence_link =
      editor
      |> LazyHTML.query(~s(article a[href="https://example.com/evidence"]))

    assert Enum.count(evidence_link) == 1
    assert evidence_link |> LazyHTML.text() |> String.trim() == "Read the evidence"

    for block <- @candidate_blocks do
      block_html =
        view
        |> element(~s([data-block-id="#{block["id"]}"]))
        |> render()

      expected = Render.render_block(block, %{style: :article})

      assert block_html =~ expected,
             "Studio forked the canonical article render for block #{block["id"]}"
    end
  end

  test "Studio exposes keyboard-native controls, named structure, and programmatic status cues",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))

    editor_html =
      view
      |> element(~s([data-test-id="studio-paper-editor"]))
      |> render()

    editor = LazyHTML.from_fragment(editor_html)

    assert editor |> LazyHTML.query(~s(main[data-test-id="studio-paper-shell"])) |> Enum.count() ==
             1

    standalone =
      editor
      |> LazyHTML.query(~s(a[data-test-id="paper-open-standalone"]))

    # spd-w19 — an EXPECTATION CHANGE, not a regression. This link fell to the
    # paper pane's missing `scope_prefix` thread and emitted the FLAT
    # `/papers/:slug`, while the viewer sits on a scoped Studio mount; the pane
    # now carries the viewer's own scope, and
    # `/w/:ws/p/:proj/papers/:slug` is a real route (the gated scoped paper
    # reader, `:scoped_paper_reader`). The scoped spelling is asserted through the
    # same helper that built the mount, so the two can never drift apart.
    assert LazyHTML.attribute(standalone, "href") == [scoped_studio("") <> "/papers/#{@slug}"]
    assert LazyHTML.attribute(standalone, "target") == ["_blank"]
    assert LazyHTML.attribute(standalone, "rel") == ["noopener"]

    inspector = editor |> LazyHTML.query(~s(aside[aria-label="Document metadata"]))
    assert Enum.count(inspector) == 1

    toggle = editor |> LazyHTML.query("#bp-doc-sidebar-toggle")
    assert LazyHTML.tag(toggle) == ["button"]
    assert LazyHTML.attribute(toggle, "aria-controls") == ["bp-doc-sidebar-body"]
    assert LazyHTML.attribute(toggle, "aria-expanded") == ["true"]

    assert one_text(editor, ~s([data-test-id="sidebar-status"])) == "published"

    slug_feedback =
      editor
      |> LazyHTML.query(~s([data-test-id="sidebar-slug-feedback"][role="status"]))

    assert Enum.count(slug_feedback) == 1
  end

  test "default canvas receives the exact candidate and keeps an accessible editing/status contract",
       %{conn: conn} do
    System.put_env("BARKPARK_PAPER_CANVAS", "1")

    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))

    editor_html =
      view
      |> element(~s([data-test-id="studio-paper-editor"]))
      |> render()

    editor = LazyHTML.from_fragment(editor_html)

    shell =
      editor
      |> LazyHTML.query(~s(main[data-test-id="studio-paper-shell"]))

    assert LazyHTML.attribute(shell, "aria-label") == ["Editing #{@title}"]
    assert editor |> LazyHTML.query("bp-paper-canvas") |> Enum.count() == 1

    [encoded_blocks] =
      editor
      |> LazyHTML.query(~s([data-test-id="paper-canvas-run"]))
      |> LazyHTML.attribute("data-canvas-blocks")

    assert Jason.decode!(encoded_blocks) == @candidate_blocks

    save_status =
      editor
      |> LazyHTML.query(~s([data-test-id="bp-paper-footer-save"]))

    assert LazyHTML.attribute(save_status, "role") == ["status"]
    assert LazyHTML.attribute(save_status, "aria-live") == ["polite"]

    refute editor_html =~ ~s(data-test-id="paper-edit-toggle")
  end

  defp one_text(document, selector) do
    nodes = LazyHTML.query(document, selector)
    assert Enum.count(nodes) == 1
    nodes |> LazyHTML.text() |> String.trim()
  end
end
