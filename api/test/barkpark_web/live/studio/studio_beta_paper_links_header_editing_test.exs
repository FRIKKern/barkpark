defmodule BarkparkWeb.Studio.StudioBetaPaperLinksHeaderEditingTest do
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Auth, Content}

  @dataset "production"
  @doc_type "beta_paper_links_header_editing"

  setup %{conn: conn} do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => @doc_type,
          "title" => "Beta Paper links header editing",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "body", "title" => "Body", "type" => "richText"}
          ]
        },
        @dataset
      )

    raw = "beta-paper-links-writer-#{System.unique_integer([:positive])}"

    {:ok, _token} =
      Auth.create_token(
        raw,
        "Beta Paper links editing",
        @dataset,
        ["read", "write"],
        Barkpark.TenancyFixtures.default_workspace_id!()
      )

    %{conn: Plug.Test.init_test_session(conn, %{"api_token" => raw})}
  end

  test "Studio scalar header forms preserve whitespace and reference metadata", %{conn: conn} do
    refs = [%{"slug" => "linked-paper", "vendor" => %{"keep" => true}}, "legacy-paper"]

    block = %{
      "id" => "related",
      "type" => "paper-links",
      "title" => "Before",
      "description" => "Before description",
      "refs" => refs,
      "unknown" => [1, 2]
    }

    doc = create_document!([block])
    path = studio_path(doc.doc_id)
    {:ok, view, _html} = live(conn, path)
    view |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()

    assert has_element?(
             view,
             ~s([data-test-id="paper-links-title-editor"] textarea[name="title"])
           )

    render_hook(view, "paper-block-autosave", %{
      "block_id" => "related",
      "title" => "  Studio heading  ",
      "if_rev" => socket_of(view).assigns.editor_doc.rev,
      "request_id" => Ecto.UUID.generate()
    })

    render_hook(view, "paper-block-autosave", %{
      "block_id" => "related",
      "description" => "  Studio description  ",
      "if_rev" => socket_of(view).assigns.editor_doc.rev,
      "request_id" => Ecto.UUID.generate()
    })

    assert [persisted] = stored_blocks(doc.doc_id)
    assert persisted["title"] == "  Studio heading  "
    assert persisted["description"] == "  Studio description  "
    assert persisted["refs"] == refs
    assert persisted["unknown"] == [1, 2]

    {:ok, reloaded, _html} = live(conn, path)
    reloaded |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()

    assert reloaded
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.query(~s([data-test-id="paper-links-title-editor"] textarea[name="title"]))
           |> LazyHTML.text() == "  Studio heading  "
  end

  # The reader paints the heading as <h2 style={title_style}> under the paper
  # surface's h2 rule (weight 400 and h2 tracking in the article palette). The
  # editable heading must carry that rule, not a hard-coded bold: the August
  # Chronicle's related-paper headings painted 700 in Edit, 400 in View.
  test "the editable heading carries the reader's h2 typography, never a forced bold",
       %{conn: conn} do
    for layout <- [nil, "chapters"] do
      block =
        %{
          "id" => "related",
          "type" => "paper-links",
          "title" => "Worth opening next",
          "refs" => ["legacy-paper"]
        }
        |> then(&if(layout, do: Map.put(&1, "layout", layout), else: &1))

      doc = create_document!([block])
      {:ok, view, _html} = live(conn, studio_path(doc.doc_id))
      view |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()

      [style] =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(".bp-paper-links-title-owner")
        |> LazyHTML.attribute("style")

      refute style =~ "font-weight:bold", "layout #{inspect(layout)}: #{style}"
      assert style =~ "font-weight:var(--bp-h2-weight)"
      assert style =~ "letter-spacing:var(--bp-h2-tracking)"
      assert style =~ "font-family:var(--paper-font-serif)"
      # the layout's own declarations come AFTER the h2 rule, so they still win
      [h2_rule, layout_rule] = String.split(style, "text-wrap:balance;", parts: 2)
      assert h2_rule =~ "font-weight"
      assert layout_rule =~ "font-size"
    end
  end

  defp create_document!(blocks) do
    id = "beta-paper-links-#{System.unique_integer([:positive])}"

    {:ok, doc} =
      Content.create_document(
        @doc_type,
        %{"doc_id" => id, "title" => "Paper links", "content" => %{"blocks" => blocks}},
        @dataset
      )

    doc
  end

  defp stored_blocks(doc_id) do
    {:ok, doc} = Content.get_document(doc_id, @doc_type, @dataset)
    doc.content["blocks"]
  end

  defp studio_path(doc_id) do
    scoped_studio("/d/#{@dataset}/studio/#{@doc_type}/#{Content.published_id(doc_id)}")
  end

  defp socket_of(view), do: :sys.get_state(view.pid).socket
end
