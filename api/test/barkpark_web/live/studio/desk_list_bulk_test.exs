defmodule BarkparkWeb.Studio.DeskListBulkTest do
  @moduledoc """
  B03 on the desk (`DeskLive`, /papers/desk-vertical-slice): tick several
  rows of a list pane, then publish or unpublish them in one go. Reference:
  the TanStack Studio's list pane (`Structure.tsx` ListPane, `BulkBar.tsx`)
  and e2e/journeys/bulk.spec.ts; Barkpark's own LiveView Studio has the
  same bar (`StudioComponents.bulk_action_bar/1`) and the write
  (`Shared.bulk_action/2`).

  The markup these tests read (builder and test agree on it):

    * a row's tick: `[data-desk-pick="<doc id>"]` in the list pane, with a
      `phx-click` (any event, any target: selecting writes nothing);
    * the bar: `[data-desk-bulk]` in the same pane, shown only while a row
      is ticked, saying "N selected";
    * its buttons: `button[phx-click="bulk-publish"]`,
      `button[phx-click="bulk-unpublish"]` (with a `data-confirm`) and
      `button[phx-click="bulk-clear"]`. These three are the Studio's own
      event names, sent WITHOUT `phx-target`: they are classified in
      `Caps` (`bulk-publish` / `bulk-unpublish` are admin-tier), so the
      page's capability gate sees the write. A component-targeted write
      would skip that gate.

  Every test reads the store after the click, not the page alone.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @type_name "desk_bulk_note"

  setup %{conn: conn} do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Desk bulk notes",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "summary", "title" => "Summary", "type" => "string"}
          ]
        },
        @dataset
      )

    n = System.unique_integer([:positive])

    # Three draft-only notes (publish subjects; the third stays unticked) and
    # two published ones with no draft (unpublish subjects; the second stays
    # unticked).
    ids = %{
      a: "dbn-a-#{n}",
      b: "dbn-b-#{n}",
      c: "dbn-c-#{n}",
      d: "dbn-d-#{n}",
      e: "dbn-e-#{n}"
    }

    titles = %{a: "Alpha", b: "Bravo", c: "Charlie", d: "Delta", e: "Echo"}

    for {key, id} <- ids do
      {:ok, _doc} =
        Content.create_document(
          @type_name,
          %{"doc_id" => id, "title" => titles[key] <> " bulk note", "content" => %{}},
          @dataset
        )
    end

    for key <- [:d, :e] do
      {:ok, _} = Content.publish_document(ids[key], @type_name, @dataset)
    end

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"

    {:ok, Map.merge(ids, %{conn: conn, base: base})}
  end

  defp admin(conn) do
    raw = "desk-bulk-token-" <> Ecto.UUID.generate()
    ws = Tenancy.get_default_workspace()
    {:ok, _} = Auth.create_token(raw, "desk-bulk", @dataset, ["read", "write", "admin"], ws.id)
    Plug.Test.init_test_session(conn, %{"api_token" => raw})
  end

  defp settle(view), do: render_async(view, 5_000)

  defp open_list(conn, base) do
    {:ok, view, _html} = live(admin(conn), "#{base}/#{@type_name}")
    settle(view)
    view
  end

  @list ~s([data-pane-index="1"][data-pane-kind="list"])
  @bar @list <> " [data-desk-bulk]"

  defp tick_sel(id), do: @list <> ~s( [data-desk-pick="#{id}"])

  # Tick a row: the tick must be there to click (a missing one fails here
  # with the selector, not later with a vaguer count).
  defp tick(view, id) do
    assert has_element?(view, tick_sel(id)),
           "no tick #{tick_sel(id)} in the list pane"

    view |> element(tick_sel(id)) |> render_click()
    settle(view)
  end

  defp bar_button(view, event) do
    sel = @bar <> ~s( button[phx-click="#{event}"])
    assert has_element?(view, sel), "no #{sel}"
    view |> element(sel) |> render_click()
    settle(view)
  end

  # {draft?, published?} as the store holds it.
  defp state(id) do
    {_doc, draft?, published?} = Content.fetch_doc_with_draft(@type_name, id, @dataset)
    {draft?, published?}
  end

  # Poll for a value rather than read it once (CAMPAIGN rule 6).
  defp eventually(fun) do
    Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)
  end

  test "every row of a list pane has a tick that names its document", %{
    conn: conn,
    base: base,
    a: a,
    d: d
  } do
    view = open_list(conn, base)

    assert has_element?(view, @list <> " a[data-desk-row]", "Alpha bulk note")

    for id <- [a, d] do
      assert has_element?(view, tick_sel(id)),
             "the row of #{id} has no tick #{tick_sel(id)}"
    end

    # The tick is named for the row, as the reference's "Select <title>".
    assert has_element?(view, tick_sel(a) <> ~s([aria-label="Select Alpha bulk note"]))
  end

  test "no bar until a row is ticked; ticking two says 2 selected; unticking one says 1", %{
    conn: conn,
    base: base,
    a: a,
    b: b
  } do
    view = open_list(conn, base)
    refute has_element?(view, @bar)

    tick(view, a)
    tick(view, b)
    assert has_element?(view, @bar, "2 selected")

    tick(view, b)
    assert has_element?(view, @bar, "1 selected")

    # Nothing was written by selecting.
    assert state(a) == {true, false}
    assert state(b) == {true, false}
  end

  test "Clear drops the selection and the bar, and writes nothing", %{
    conn: conn,
    base: base,
    a: a
  } do
    view = open_list(conn, base)
    tick(view, a)
    assert has_element?(view, @bar, "1 selected")

    bar_button(view, "bulk-clear")

    refute has_element?(view, @bar)
    assert state(a) == {true, false}
  end

  test "Publish selected publishes each ticked draft and leaves the unticked one a draft", %{
    conn: conn,
    base: base,
    a: a,
    b: b,
    c: c
  } do
    view = open_list(conn, base)
    tick(view, a)
    tick(view, b)
    bar_button(view, "bulk-publish")

    # STORE FIRST: published, no draft left, for each ticked doc.
    assert state(a) == {false, true}
    assert state(b) == {false, true}
    # The unticked control is untouched.
    assert state(c) == {true, false}

    # The bulk action ends selecting: the bar goes.
    refute has_element?(view, @bar)
  end

  test "Publish selected says what it did in one summary, counting a doc with nothing to publish",
       %{conn: conn, base: base, a: a, d: d} do
    view = open_list(conn, base)
    # `d` is published with no draft: nothing to publish, left alone.
    tick(view, a)
    tick(view, d)
    bar_button(view, "bulk-publish")

    assert state(a) == {false, true}
    assert state(d) == {false, true}

    assert eventually(fn -> render(view) =~ "Published 1 of 2" end),
           "no summary \"Published 1 of 2\" on the page"
  end

  test "the list's rows show the publish: a published row loses its draft mark", %{
    conn: conn,
    base: base,
    a: a
  } do
    view = open_list(conn, base)
    row = @list <> ~s( a[data-desk-row][href$=";#{a}"])
    assert has_element?(view, row <> " .dk-draft")

    tick(view, a)
    bar_button(view, "bulk-publish")
    assert state(a) == {false, true}

    # The page re-reads the list when the save is announced; poll for it.
    assert eventually(fn ->
             settle(view)
             has_element?(view, row) and not has_element?(view, row <> " .dk-draft")
           end),
           "the published row still shows its draft mark"
  end

  test "Unpublish selected asks first, naming how many", %{conn: conn, base: base, d: d, e: e} do
    view = open_list(conn, base)
    tick(view, d)
    tick(view, e)

    assert has_element?(
             view,
             @bar <>
               ~s( button[phx-click="bulk-unpublish"][data-confirm="Unpublish 2 documents?"])
           )
  end

  test "Unpublish selected unpublishes each ticked doc and leaves the unticked one published", %{
    conn: conn,
    base: base,
    d: d,
    e: e
  } do
    view = open_list(conn, base)
    tick(view, d)
    bar_button(view, "bulk-unpublish")

    {_draft?, published?} = state(d)
    refute published?, "the ticked doc is still published"
    # The unticked control is untouched.
    assert state(e) == {false, true}

    assert eventually(fn -> render(view) =~ "Unpublished 1 of 1" end),
           "no summary \"Unpublished 1 of 1\" on the page"

    refute has_element?(view, @bar)
  end
end
