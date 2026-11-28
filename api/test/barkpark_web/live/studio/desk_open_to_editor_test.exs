defmodule BarkparkWeb.Studio.DeskOpenToEditorTest do
  @moduledoc """
  A click on a document row draws its editor in the patch that answers it
  (task-32a5956065c81200). The patch used to draw the document pane first and
  the editor one message later: a read-only copy of the form when the row had
  been hovered (its read kept), else an empty frame. In a browser that was a
  different pane for a moment, then the editor.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content

  @dataset "production"
  @type_name "desk_open_note"

  setup %{conn: conn} do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Desk open notes",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "summary", "title" => "Summary", "type" => "string"}
          ]
        },
        @dataset
      )

    n = System.unique_integer([:positive])

    for {id, title} <- [{"don-a-#{n}", "Alpha note"}, {"don-b-#{n}", "Beta note"}] do
      {:ok, _doc} =
        Content.create_document(
          @type_name,
          %{"doc_id" => id, "title" => title, "content" => %{"summary" => "About " <> title}},
          @dataset
        )
    end

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"

    raw = "desk-open-token-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(raw, "desk-open", @dataset, ["read", "write", "admin"], ws.id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok, conn: conn, base: base, a: "don-a-#{n}", b: "don-b-#{n}"}
  end

  # The HTML the click's own patch drew, before any later message.
  defp click_row(view, href),
    do:
      view
      |> element(~s([data-pane-index="1"] a[data-desk-row][href="#{href}"]))
      |> render_click()

  defp doc_pane(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s(#desk-panes > [data-pane-index="2"]))
  end

  test "a hovered row opens its editor, not a read-only copy of the form first", c do
    {:ok, view, _html} = live(c.conn, "#{c.base}/#{@type_name};#{c.a}")
    render_async(view, 5_000)

    beta = "#{c.base}/#{@type_name};#{c.b}"
    view |> element("#desk-panes") |> render_hook("warm", %{"href" => beta})
    render_async(view, 5_000)

    pane = doc_pane(click_row(view, beta))

    assert LazyHTML.query(pane, "[data-desk-read-only]") |> Enum.empty?(),
           "no read-only copy of the form"

    assert LazyHTML.attribute(pane, "data-pane-editing") == [""], "the patch draws the editor"
    assert LazyHTML.query(pane, ".dk-skeleton") |> Enum.empty?()
  end

  test "a row not hovered opens its editor, not an empty frame first", c do
    {:ok, view, _html} = live(c.conn, "#{c.base}/#{@type_name};#{c.a}")
    render_async(view, 5_000)

    pane = doc_pane(click_row(view, "#{c.base}/#{@type_name};#{c.b}"))

    assert LazyHTML.query(pane, ".dk-skeleton") |> Enum.empty?(), "no empty frame"
    assert LazyHTML.attribute(pane, "data-pane-editing") == [""], "the patch draws the editor"
    assert LazyHTML.text(LazyHTML.query(pane, ".pane-header-title")) =~ "Beta note"
  end
end
