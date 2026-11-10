defmodule BarkparkWeb.Studio.DeskLiveUpdatesBackendDownTest do
  @moduledoc """
  J50 (JOURNEYS.md): the backend goes away. A pane that cannot read says so
  in itself with a Retry, retries by itself a bounded number of times, and
  fills once the backend is back; the rest of the desk stays up.

  The fault here is the exception a real outage raises in a pane's read: a
  pool checkout that times out (`DBConnection.ConnectionError`), which makes
  the pane's `start_async` exit. It goes in through the reader seam
  (`config :barkpark, PaneComponent, reader: fun`). In a real browser the same
  card is reached by holding a lock on `documents` until the read times out:
  `$ORCH/tmp/live-w2/backend-down.mjs`.

  Not pinned here (browser only): what the page shows while the SOCKET is down
  (root.html.heex has only `.phx-disconnected { opacity: 0.7 }`).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias BarkparkWeb.Studio.Desk.PaneComponent

  @dataset "production"
  @type_name "desk_down_note"

  setup %{conn: conn} do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Desk down notes",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "summary", "title" => "Summary", "type" => "string"}
          ]
        },
        @dataset
      )

    n = System.unique_integer([:positive])

    for {id, title} <- [{"ddn-a-#{n}", "Alpha down"}, {"ddn-b-#{n}", "Beta down"}] do
      {:ok, _doc} =
        Content.create_document(
          @type_name,
          %{"doc_id" => id, "title" => title, "content" => %{"summary" => "About " <> title}},
          @dataset
        )
    end

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"

    raw = "desk-down-token-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(raw, "desk-down", @dataset, ~w(read write admin), ws.id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    # Alpha is a read-only pane (index 2); Beta, the last document, is the editor's.
    chain = "#{@type_name};ddn-a-#{n};ddn-b-#{n},type=#{@type_name},parentRefPath=more"
    {:ok, conn: conn, url: "#{base}/#{chain}", list_url: "#{base}/#{@type_name}", a: "ddn-a-#{n}"}
  end

  defp settle(view), do: render_async(view, 5_000)

  defp poll(fun, tries \\ 300) do
    Enum.any?(1..tries, fn _ -> fun.() or (Process.sleep(20) && false) end)
  end

  # Document reads fail while `down` holds true; every document read is counted.
  defp outage do
    down = :counters.new(1, [])
    reads = :counters.new(1, [])
    :counters.put(down, 1, 1)

    Application.put_env(:barkpark, PaneComponent,
      reader: fn
        %{kind: :doc} = pane, node, dataset, scope, title ->
          :counters.add(reads, 1, 1)

          if :counters.get(down, 1) == 1,
            do: raise(DBConnection.ConnectionError, "connection not available and request was dropped from queue after 2000ms"),
            else: PaneComponent.read(pane, node, dataset, scope, title)

        pane, node, dataset, scope, title ->
          PaneComponent.read(pane, node, dataset, scope, title)
      end
    )

    on_exit(fn -> Application.delete_env(:barkpark, PaneComponent) end)
    %{up: fn -> :counters.put(down, 1, 0) end, reads: fn -> :counters.get(reads, 1) end}
  end

  @card ~s([data-pane-index="2"] [role="alert"] button[phx-click="retry"])

  test "a read that meets an outage shows its own card and Retry; the other panes stay up", %{
    conn: conn,
    url: url
  } do
    fault = outage()
    {:ok, view, _html} = live(conn, url)

    assert poll(fn -> settle(view) && has_element?(view, @card) end),
           "the failed pane never showed its Retry card"

    assert has_element?(view, ~s([data-pane-index="1"] a[data-desk-row]), "Alpha down")
    assert has_element?(view, ~s([data-pane-index="3"][data-pane-editing] #editor-form))

    # Retry while still down: one read per press, the card again.
    before = fault.reads.()
    view |> element(@card) |> render_click()
    assert poll(fn -> settle(view) && fault.reads.() == before + 1 && has_element?(view, @card) end)

    # Back up: Retry fills the pane.
    fault.up.()
    view |> element(@card) |> render_click()

    assert poll(fn -> settle(view) && has_element?(view, ~s([data-pane-index="2"] dd), "About Alpha down") end),
           "Retry after the outage did not fill the pane"

    refute has_element?(view, @card)
  end

  test "a lasting outage is not retried without end", %{conn: conn, url: url} do
    fault = outage()
    {:ok, view, _html} = live(conn, url)
    assert poll(fn -> settle(view) && has_element?(view, @card) end)

    # Six seconds of a backend that stays down: a bounded number of reads.
    Process.sleep(6_000)
    settle(view)
    reads = fault.reads.()
    assert reads <= 5, "the pane read #{reads} times in 6 s against a backend that stays down"
    assert has_element?(view, @card)
  end

  test "a document the editor cannot load is that pane's to show; the page stays up", %{
    conn: conn,
    list_url: list_url,
    a: a
  } do
    # The editor pane loads in the page's own process (DeskLive.edit/2 ->
    # StudioLive.handle_params), not in a pane task. The outage is real: the
    # documents table is gone (inside this test's sandbox transaction, so it
    # rolls back), and the next read raises Postgrex.Error.
    Process.flag(:trap_exit, true)
    {:ok, view, _html} = live(conn, list_url)
    assert poll(fn -> settle(view) && has_element?(view, ~s([data-pane-index="1"] a[data-desk-row]), "Alpha down") end)

    Barkpark.Repo.query!("ALTER TABLE documents RENAME TO documents_gone")

    row = ~s([data-pane-index="1"] a[data-desk-row][href$="#{a}"])

    try do
      view |> element(row) |> render_click()
    catch
      :exit, _ -> :the_page_died
    end

    died? = poll(fn -> not Process.alive?(view.pid) end, 150)

    refute died?,
           "the whole desk LiveView died on the editor's failed load; the browser shows a busy " <>
             "skeleton, then reloads the page (no card, no Retry)"

    assert poll(fn -> has_element?(view, ~s([data-pane-index="2"] [role="alert"])) end)
    assert has_element?(view, ~s([data-pane-index="1"] a[data-desk-row]), "Alpha down")
  end

  test "a short outage heals by itself, with no click", %{conn: conn, url: url} do
    fault = outage()
    {:ok, view, _html} = live(conn, url)
    assert poll(fn -> settle(view) && has_element?(view, @card) end)

    # The backend comes back; nobody presses Retry.
    fault.up.()

    healed? =
      poll(
        fn -> settle(view) && has_element?(view, ~s([data-pane-index="2"] dd), "About Alpha down") end,
        500
      )

    assert healed?,
           "the pane stayed on its error card after the backend came back (no automatic retry); " <>
             "it read #{fault.reads.()} time(s)"
  end
end
