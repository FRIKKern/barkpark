defmodule BarkparkWeb.Studio.StudioPaperTitleDisplayTest do
  # task-23bff317e617928e: an untitled paper's header used the raw
  # `drafts.<id>`, and a title typed on the canvas reached the header but not
  # the desk row until a reload. The header and the row now name the paper the
  # same way, and an op that changes the title patches the row.
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.PaperEditorTestHelpers, only: [pin_paper_canvas!: 1, seed_paper_schema!: 0]
  alias Barkpark.Content

  @dataset "production"

  setup do
    pin_paper_canvas!("1")
    seed_paper_schema!()
    :ok
  end

  defp open(conn, slug), do: live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{slug}"))

  defp header_title(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(
      ~s([data-test-id="studio-paper-editor"] h1, [data-test-id="studio-paper-editor"] .doc-header-title)
    )
    |> Enum.map(&LazyHTML.text/1)
    |> Enum.map(&String.trim/1)
  end

  defp row_titles(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(".pane-doc-title")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  test "an untitled paper's header uses the desk row spelling, not the draft id", %{conn: conn} do
    {:ok, _} =
      Content.create_document(
        "paper",
        %{"doc_id" => "paper-0123abcd", "content" => %{}},
        @dataset
      )

    {:ok, _view, html} = open(conn, "paper-0123abcd")

    assert "Untitled paper · 0123abcd" in row_titles(html)
    refute html =~ ">drafts.paper-0123abcd<"
    assert html =~ "Untitled paper · 0123abcd"
  end

  test "a canvas op that changes the title updates the desk row", %{conn: conn} do
    slug = "paper-title-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          dataset: @dataset,
          title: "Gammel",
          blocks: [
            %{
              "id" => "tpl-title",
              "type" => "heading",
              "level" => 1,
              "role" => "title",
              "locked" => true,
              "text" => "Gammel"
            },
            %{
              "id" => "p-1",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "Tekst"}]
            }
          ]
        })
      )

    {:ok, view, html} = open(conn, slug)
    assert "Gammel" in row_titles(html)

    request = Ecto.UUID.generate()

    render_hook(view, "paper-ops", %{
      "ops" => [
        %{"op" => "patch-block", "id" => "tpl-title", "patch" => %{"text" => "Ny tittel"}}
      ],
      "request_id" => request,
      "if_rev" => :sys.get_state(view.pid).socket.assigns.paper_rev
    })

    assert_reply(view, %{saved: true, request_id: ^request})
    # The row title follows the title block, and so does a stored
    # content["title"] (upsert_paper wrote "Gammel" there).
    assert %{title: "Ny tittel", content: %{"title" => "Ny tittel"}} =
             Content.get_paper(slug, @dataset)

    titles = row_titles(render(view))
    assert "Ny tittel" in titles
    refute "Gammel" in titles
  end
end
