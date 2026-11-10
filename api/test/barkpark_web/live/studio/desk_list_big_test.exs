defmodule BarkparkWeb.Studio.DeskListBigTest do
  @moduledoc """
  J41 (barkpark-studio JOURNEYS.md): a big list opens with its first page,
  loads more near the bottom without a button, stops at 2,000 rows and says
  so ("Displaying a maximum of 2000 documents"), and its search finds a
  document the loaded rows do not hold. The reference is the TanStack
  Studio's ListPane (`LIST_PAGE` 100, `LIST_MAX` 2000 in `app/src/lib/data.ts`)
  and its spec `e2e/journeys/big-list.spec.ts`.

  Frame times (F11: 60 fps while scrolling 2,000 rows, no long frame while
  growing) are a browser's to measure, in the rig's big-list spec; these
  tests pin what the server must hand the browser for that.

  Names these tests agree on with the builder:
    * `[data-desk-more]` — the element near the bottom of a list that holds
      more; reaching it sends the pane's "more" event (a `phx-viewport-bottom`
      or a hook's push). Gone once everything (or 2,000) is loaded.
    * `form.dk-list-search input[name="q"]` — the list's search box.

  Kept cheap: 130 documents prove "beyond the first page"; only the cap test
  holds 2,001, written in one insert.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  @dataset "production"
  @type_name "desk_lbig_item"

  @list ~s([data-pane-kind="list"])
  @rows @list <> " a[data-desk-row]"
  @more @list <> " [data-desk-more]"
  @search @list <> " form.dk-list-search"

  setup %{conn: conn} do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Big items",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"
    {:ok, conn: conn, base: base, ws: ws, proj: proj}
  end

  # `count` items through the real write path. Inside the test's transaction
  # they share one timestamp, so which 100 the first page holds is not known
  # ahead: a test reads it off the page.
  defp create_items(count) do
    for i <- 1..count do
      num = String.pad_leading(Integer.to_string(i), 4, "0")

      {:ok, _doc} =
        Content.create_document(
          @type_name,
          %{"doc_id" => "lbig-#{num}", "title" => "Big item #{num}"},
          @dataset
        )
    end
  end

  defp admin(conn) do
    raw = "desk-list-big-" <> Ecto.UUID.generate()
    ws = Tenancy.get_default_workspace()
    {:ok, _} = Auth.create_token(raw, "desk-list-big", @dataset, ~w(read write admin), ws.id)
    Plug.Test.init_test_session(conn, %{"api_token" => raw})
  end

  defp open(conn, base) do
    {:ok, view, _html} = live(admin(conn), "#{base}/#{@type_name}")
    render_async(view, 5_000)
    view
  end

  defp row_count(view),
    do: view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(@rows) |> Enum.count()

  # The titles of items 1..count the pane does not draw.
  defp not_shown(view, count) do
    html = render(view)

    shown =
      ~r/Big item (\d{4})/ |> Regex.scan(html) |> Enum.map(fn [t, _] -> t end) |> MapSet.new()

    for i <- 1..count,
        t = "Big item " <> String.pad_leading(Integer.to_string(i), 4, "0"),
        not MapSet.member?(shown, t),
        do: t
  end

  # Wait for the row count itself to reach `n` (a read runs in the pane's task).
  defp rows_reach(view, n) do
    Enum.any?(1..250, fn _ ->
      render_async(view, 5_000)
      row_count(view) >= n or (Process.sleep(20) && false)
    end)

    row_count(view)
  end

  # Reach the bottom of the list once: the near-the-bottom element when there
  # is one, else today's "Show more" button. Returns false when neither is there.
  defp reach_bottom(view) do
    cond do
      has_element?(view, @more) ->
        view |> element(@more) |> render_hook("more", %{})
        true

      has_element?(view, @list <> " button.dk-more") ->
        view |> element(@list <> " button.dk-more") |> render_click()
        true

      true ->
        false
    end
  end

  test "a big list opens with its first 100 rows", %{conn: conn, base: base} do
    create_items(130)
    view = open(conn, base)

    assert row_count(view) == 100
    assert length(not_shown(view, 130)) == 30
  end

  test "more rows load near the bottom, with no button to press", %{conn: conn, base: base} do
    create_items(130)
    view = open(conn, base)
    assert row_count(view) == 100

    assert has_element?(view, @more),
           "J41: a list that holds more has an element near its bottom that loads the rest " <>
             "(#{@more}); today there is only a Show more button"

    view |> element(@more) |> render_hook("more", %{})
    assert rows_reach(view, 130) == 130
    assert not_shown(view, 130) == []

    refute has_element?(view, @more), "a list with everything loaded asks for no more"
  end

  test "a list grows to 2,000 rows, stops there and says so", %{
    conn: conn,
    base: base,
    ws: ws,
    proj: proj
  } do
    # 2,001 rows in one insert: the real write path would take about 20 s.
    # Distinct updated_at, newest = the highest number, as the real path gives.
    t0 = DateTime.utc_now()

    rows =
      for i <- 1..2001 do
        num = String.pad_leading(Integer.to_string(i), 4, "0")
        at = DateTime.add(t0, i - 3000, :second)

        %{
          doc_id: "lbig-#{num}",
          type: @type_name,
          dataset: @dataset,
          workspace_id: ws.id,
          project_id: proj.id,
          title: "Big item #{num}",
          status: "published",
          content: %{},
          rev: "rev-lbig-#{num}",
          inserted_at: at,
          updated_at: at
        }
      end

    {2001, _} = Repo.insert_all(Document, rows)

    view = open(conn, base)
    assert row_count(view) == 100

    # Reach the bottom until nothing more comes (at most 25 times).
    Enum.reduce_while(1..25, row_count(view), fn _, before ->
      if reach_bottom(view) do
        Enum.any?(1..100, fn _ ->
          render_async(view, 10_000)
          row_count(view) > before or (Process.sleep(20) && false)
        end)

        now = row_count(view)
        if now > before, do: {:cont, now}, else: {:halt, now}
      else
        {:halt, before}
      end
    end)

    assert row_count(view) == 2000,
           "J41: the list grows to 2,000 rows (Sanity's maximum); it stopped at #{row_count(view)}"

    assert has_element?(view, @list, "Displaying a maximum of 2000 documents"),
           "J41: at 2,000 rows the list says it shows no more"

    refute has_element?(view, @more)
    refute has_element?(view, @list <> " button.dk-more")
  end

  test "list search finds a document beyond the first page", %{conn: conn, base: base} do
    create_items(130)
    view = open(conn, base)
    # Precondition: the document is not among the rows the list loaded.
    assert row_count(view) == 100
    [target | _] = not_shown(view, 130)
    refute has_element?(view, @rows, target)

    assert has_element?(view, @search <> ~s( input[name="q"])),
           "the list pane has no search box (#{@search} input[name=q])"

    view |> element(@search) |> render_change(%{"q" => target})

    found? =
      Enum.any?(1..250, fn _ ->
        render_async(view, 5_000)
        has_element?(view, @rows, target) or (Process.sleep(20) && false)
      end)

    assert found?, "J41: list search reaches a document the loaded rows do not hold"
  end
end
