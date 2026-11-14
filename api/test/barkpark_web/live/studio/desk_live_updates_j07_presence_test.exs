defmodule BarkparkWeb.Studio.DeskLiveUpdatesJ07PresenceTest do
  @moduledoc """
  J07 (barkpark-studio JOURNEYS.md): presence everywhere — avatars on the
  document, on the field, on list rows, on array items and blocks; the
  navbar's "who's online" jumps to them.

  Driven in a browser first (live lane triage, 2026-11-10). The document's
  header dots and the navbar's "who's online" worked when a document was
  open, because the hosted editor joined the presence room when it loaded
  one. A desk showing lists only was in nobody's room (it saw no one and no
  one saw it), and closing the document pane left you shown on that
  document. The page now joins the room itself (`Desk.LiveRefresh`).

  The list-row mark (`LiveRefresh.row_mark/1`) is drawn by the list pane,
  which is not this file's to change; its test waits on that call site.
  Field, array-item and block avatars exist in neither Studio (presence
  carries no field).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @type_name "desk_live_j07"

  setup %{conn: conn} do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Desk J07 notes",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    n = System.unique_integer([:positive])

    for {id, title} <- [{"dj07-a-#{n}", "Alpha seven"}, {"dj07-b-#{n}", "Beta seven"}] do
      {:ok, _doc} =
        Content.create_document(@type_name, %{"doc_id" => id, "title" => title}, @dataset)
    end

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk/#{@type_name}"

    {:ok, conn: conn, base: base, a: "dj07-a-#{n}", b: "dj07-b-#{n}"}
  end

  defp person(conn, name) do
    raw = "desk-j07-token-" <> Ecto.UUID.generate()
    ws = Tenancy.get_default_workspace()
    {:ok, _} = Auth.create_token(raw, "desk-j07", @dataset, ["read", "write", "admin"], ws.id)

    conn
    |> Plug.Test.init_test_session(%{"api_token" => raw})
    |> put_connect_params(%{"user_id" => "j07-#{name}-#{System.unique_integer([:positive])}"})
  end

  defp open(conn, url) do
    {:ok, view, _html} = live(conn, url)
    render_async(view, 5_000)
    view
  end

  defp second(), do: person(BarkparkWeb.ConnCase.scoped_conn(), "b")

  # The document header's avatars (TanStack's AvatarStack, `Desk.DocStatus`):
  # one per OTHER person on the document, none for a person alone. The
  # Studio's toolbar row that drew dots before is hidden in the desk.
  defp header_dots(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-pane-editing] > .pane-header .p-avatars .p-avatar:not(.more)")
    |> Enum.count()
  end

  # The navbar's "who's online": one entry per OTHER person.
  defp online_others(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(".presence-nav .presence-user-wrap")
    |> Enum.count()
  end

  # Presence travels by broadcast: poll for the value itself.
  defp eventually(fun),
    do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  test "two people on one document each see the other on it", %{conn: conn, base: base, a: a} do
    va = open(person(conn, "a"), "#{base};#{a}")
    vb = open(second(), "#{base};#{a}")

    assert eventually(fn -> header_dots(va) == 1 and header_dots(vb) == 1 end),
           "header avatars: A #{header_dots(va)}, B #{header_dots(vb)} (want 1 each: the other)"

    assert eventually(fn -> online_others(va) == 1 and online_others(vb) == 1 end),
           "who's online: A #{online_others(va)}, B #{online_others(vb)} (want 1 each)"
  end

  test "a desk showing lists only still shows who is online", %{conn: conn, base: base, a: a} do
    vb = open(second(), "#{base};#{a}")
    va = open(person(conn, "a"), base)
    refute has_element?(va, "[data-pane-editing]")

    assert eventually(fn -> online_others(va) == 1 end),
           "a desk with no document open shows nobody online (B has Alpha open)"

    assert eventually(fn -> online_others(vb) == 1 end),
           "B on Alpha does not see A, whose desk shows lists only"
  end

  test "closing the document pane takes you off that document", %{conn: conn, base: base, a: a} do
    va = open(person(conn, "a"), "#{base};#{a}")
    vb = open(second(), "#{base};#{a}")
    assert eventually(fn -> header_dots(va) == 1 end), "A never saw B arrive on Alpha"

    # B closes the document's pane: the desk patches to the list.
    render_patch(vb, base)
    render_async(vb, 5_000)
    refute has_element?(vb, "[data-pane-editing]")

    # Alone again: no avatar, as in the TanStack Studio (`Desk.DocStatus`).
    assert eventually(fn -> header_dots(va) == 0 end),
           "B closed Alpha's pane, yet A still shows #{header_dots(va)} people on Alpha"

    assert online_others(va) == 1,
           "B closed a pane, not the desk: A shows #{online_others(va)} others online (want 1)"
  end

  # What a list row will mark, read from the room's presences: the people on
  # each document of this dataset, the page's own session left out.
  test "a row's people: others on that document in this dataset, never yourself" do
    presences = [
      %{doc_id: "alpha", dataset: @dataset, session_id: "me", name: "Me", color: "#111111"},
      %{doc_id: "alpha", dataset: @dataset, session_id: "b", name: "Bea", color: "#222222"},
      %{doc_id: "alpha", dataset: "other", session_id: "c", name: "Cy", color: "#333333"},
      %{doc_id: nil, dataset: @dataset, session_id: "d", name: "Dee", color: "#444444"}
    ]

    rows = BarkparkWeb.Studio.Desk.LiveRefresh.on_rows(presences, @dataset, "me")
    names = rows |> Map.get("alpha", []) |> Enum.map(& &1.name)

    assert names == ["Bea"],
           "Alpha's row should mark Bea alone (not me, not another dataset): #{inspect(names)}"

    assert Map.keys(rows) == ["alpha"],
           "someone browsing (on no document) was put on a row: #{inspect(Map.keys(rows))}"

    html =
      render_component(&BarkparkWeb.Studio.Desk.LiveRefresh.row_mark/1, people: rows["alpha"])

    assert html =~ "background: #222222", "the row mark drew no dot in Bea's colour"

    assert render_component(&BarkparkWeb.Studio.Desk.LiveRefresh.row_mark/1, people: [])
           |> String.trim() == "",
           "a row nobody has open drew a mark"
  end
end
