defmodule BarkparkWeb.Studio.DeskDocTitleHintTest do
  @moduledoc """
  A document pane drawn before its read or the editor lands (the frame a
  click, Back or Forward patches in) is named by the title the desk already
  read for it, not by its id. Feel walk 2026-11-13 on guerrilla: a click on
  "Fixture post 01" painted that title, the server's frame then said
  "post-01" for 50-80 ms, then the editor came; Back did the same.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @type_name "desk_hint_note"

  setup %{conn: conn} do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Hint notes",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    n = System.unique_integer([:positive])
    a = "dth-a-#{n}"
    b = "dth-b-#{n}"

    for {id, title} <- [{a, "Alpha hint"}, {b, "Beta hint"}] do
      {:ok, _} =
        Content.create_document(@type_name, %{"doc_id" => id, "title" => title}, @dataset)
    end

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-hint-" <> Ecto.UUID.generate()

    {:ok, _} =
      Auth.create_token(
        raw,
        "desk-hint",
        @dataset,
        ~w(read write admin),
        Tenancy.get_default_workspace().id
      )

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     base: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk",
     a: a,
     b: b}
  end

  # The document pane's name in the page the patch answered with: the frame,
  # before the editor's own message has run.
  defp frame_title(html) do
    [section] =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query(~s(#desk-panes > [data-pane-index="2"]))
      |> Enum.to_list()

    section |> LazyHTML.attribute("aria-label") |> List.first()
  end

  test "a click's frame and a Back's frame are named by the document's title, not its id",
       %{conn: conn, base: base, a: a, b: b} do
    {:ok, view, _html} = live(conn, "#{base}/#{@type_name}")
    render_async(view, 5_000)

    # A click: the list read the title.
    assert frame_title(render_patch(view, "#{base}/#{@type_name};#{a}")) == "Alpha hint"
    render_async(view, 5_000)

    assert frame_title(render_patch(view, "#{base}/#{@type_name};#{b}")) == "Beta hint"
    render_async(view, 5_000)

    # Back to the first.
    assert frame_title(render_patch(view, "#{base}/#{@type_name};#{a}")) == "Alpha hint"
  end

  test "a document no read has named yet keeps its id until its read lands",
       %{conn: conn, base: base, a: a} do
    {:ok, view, _html} = live(conn, "#{base}/#{@type_name};#{a}")
    render_async(view, 5_000)

    assert has_element?(
             view,
             ~s(#desk-panes > [data-pane-index="2"] .pane-header-title),
             "Alpha hint"
           )
  end
end
