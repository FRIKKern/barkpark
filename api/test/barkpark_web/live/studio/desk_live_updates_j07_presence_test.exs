defmodule BarkparkWeb.Studio.DeskLiveUpdatesJ07PresenceTest do
  @moduledoc """
  J07 (barkpark-studio JOURNEYS.md): presence everywhere — avatars on the
  document, on the field, on list rows, on array items and blocks; the
  navbar's "who's online" jumps to them.

  Driven in a browser first (live lane triage, 2026-11-10). In the desk
  today: the document's header dots and the navbar's "who's online" work
  when a document is open, and its jump opens their document in the desk.
  Missing: a mark on list rows (the old Studio draws `presence-dot-sm`, the
  desk's read-only list panes draw nothing); a desk showing lists only is in
  nobody's room (it sees no one and no one sees it); closing the document
  pane leaves you shown on that document. Field, array-item and block
  avatars exist in neither Studio (presence carries no field).
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

  # The editor header's co-presence dots: one per session on the document,
  # this one included.
  defp header_dots(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-pane-editing] .presence-dots .presence-dot")
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

    assert eventually(fn -> header_dots(va) == 2 and header_dots(vb) == 2 end),
           "header dots: A #{header_dots(va)}, B #{header_dots(vb)} (want 2 each)"

    assert eventually(fn -> online_others(va) == 1 and online_others(vb) == 1 end),
           "who's online: A #{online_others(va)}, B #{online_others(vb)} (want 1 each)"
  end

  test "a list row shows that someone has its document open", %{
    conn: conn,
    base: base,
    a: a,
    b: b
  } do
    # A edits Beta with the list beside it; B has Alpha open.
    va = open(person(conn, "a"), "#{base};#{b}")
    _vb = open(second(), "#{base};#{a}")

    alpha_row = ~s([data-pane-index="1"] a[data-desk-row][href$=";#{a}"])
    assert has_element?(va, alpha_row), "the list has no row for Alpha"
    # Precondition: A's page knows B is on Alpha (its navbar says so).
    assert eventually(fn -> online_others(va) == 1 end), "A never heard B arrive"

    assert eventually(fn -> has_element?(va, alpha_row <> ~s( [class*="presence"])) end),
           "Alpha's list row draws no presence mark though B has Alpha open"
  end

  test "a desk showing lists only still shows who is online", %{conn: conn, base: base, a: a} do
    _vb = open(second(), "#{base};#{a}")
    va = open(person(conn, "a"), base)
    refute has_element?(va, "[data-pane-editing]")

    assert eventually(fn -> online_others(va) == 1 end),
           "a desk with no document open shows nobody online (B has Alpha open)"
  end

  test "closing the document pane takes you off that document", %{conn: conn, base: base, a: a} do
    va = open(person(conn, "a"), "#{base};#{a}")
    vb = open(second(), "#{base};#{a}")
    assert eventually(fn -> header_dots(va) == 2 end), "A never saw B arrive on Alpha"

    # B closes the document's pane: the desk patches to the list.
    render_patch(vb, base)
    render_async(vb, 5_000)
    refute has_element?(vb, "[data-pane-editing]")

    assert eventually(fn -> header_dots(va) == 1 end),
           "B closed Alpha's pane, yet A still shows #{header_dots(va)} people on Alpha"
  end
end
