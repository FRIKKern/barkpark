defmodule BarkparkWeb.Studio.DeskLiveUpdatesRetryTest do
  @moduledoc """
  J50 (barkpark-studio JOURNEYS.md): the backend goes away. A pane whose
  read failed reads again by itself a bounded number of times, with growing
  waits, and fills once the backend is back, with no click
  (`BarkparkWeb.Studio.Desk.LiveRefresh`).

  The fault is the exception a real outage raises in a pane's read, through
  the reader seam (`config :barkpark, PaneComponent, reader: fun`). The page
  learns of a failed read from the pane's `{:desk_pane_failed, id}`. Until
  `PaneComponent.handle_async(:load, {:exit, _}, _)` sends it, the failing
  reader here sends it for the pane, from the read's own task, just before
  the read raises: the same message, in the same order, the pane will send.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias BarkparkWeb.Studio.Desk.LiveRefresh
  alias BarkparkWeb.Studio.Desk.PaneComponent
  alias BarkparkWeb.Studio.Desk.Panes

  @dataset "production"
  @type_name "desk_retry_note"
  @waits [100, 300, 900]

  setup %{conn: conn} do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Desk retry notes",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "summary", "title" => "Summary", "type" => "string"}
          ]
        },
        @dataset
      )

    n = System.unique_integer([:positive])
    a = "drn-a-#{n}"
    b = "drn-b-#{n}"

    for {id, title} <- [{a, "Alpha retry"}, {b, "Beta retry"}] do
      {:ok, _doc} =
        Content.create_document(
          @type_name,
          %{"doc_id" => id, "title" => title, "content" => %{"summary" => "About " <> title}},
          @dataset
        )
    end

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-retry-token-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(raw, "desk-retry", @dataset, ~w(read write admin), ws.id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    Application.put_env(:barkpark, LiveRefresh, retry_waits_ms: @waits)

    on_exit(fn ->
      Application.delete_env(:barkpark, LiveRefresh)
      Application.delete_env(:barkpark, PaneComponent)
    end)

    # a is a read-only pane (index 2); b, the last document, is the editor's.
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"
    url = "#{base}/#{@type_name};#{a};#{b},type=#{@type_name},parentRefPath=more"
    {:ok, conn: conn, url: url, a: a}
  end

  defp settle(view), do: render_async(view, 5_000)

  defp poll(fun, tries \\ 300),
    do: Enum.any?(1..tries, fn _ -> fun.() or (Process.sleep(20) && false) end)

  # Reads of document `a` fail while the backend is down; each one is stamped.
  defp outage(a) do
    down = :counters.new(1, [])
    :counters.put(down, 1, 1)
    {:ok, stamps} = Agent.start_link(fn -> [] end)

    Application.put_env(:barkpark, PaneComponent,
      reader: fn
        %{kind: :doc, id: ^a} = pane, node, dataset, scope, title ->
          now = System.monotonic_time(:millisecond)
          Agent.update(stamps, &[now | &1])

          if :counters.get(down, 1) == 1 do
            # The pane's own message (see the moduledoc), then the outage.
            [page | _] = Process.get(:"$callers")
            send(page, {:desk_pane_failed, "desk-pane-2-" <> Panes.pane_key(pane)})

            raise DBConnection.ConnectionError,
                  "connection not available and request was dropped from queue after 2000ms"
          else
            PaneComponent.read(pane, node, dataset, scope, title)
          end

        pane, node, dataset, scope, title ->
          PaneComponent.read(pane, node, dataset, scope, title)
      end
    )

    %{
      up: fn -> :counters.put(down, 1, 0) end,
      stamps: fn -> stamps |> Agent.get(& &1) |> Enum.reverse() end
    }
  end

  @card ~s([data-pane-index="2"] [role="alert"] button[phx-click="retry"])
  @filled ~s([data-pane-index="2"] dd)

  defp card?(view), do: settle(view) && has_element?(view, @card)

  test "a failed pane reads again by itself and fills once the backend is back, no click", %{
    conn: conn,
    url: url,
    a: a
  } do
    fault = outage(a)
    {:ok, view, _html} = live(conn, url)

    assert poll(fn -> card?(view) end), "the failed pane never showed its Retry card"

    ids = Enum.map(:sys.get_state(view.pid).socket.assigns.desk_panes, & &1.id)

    assert "desk-pane-2-doc:#{a}" in ids,
           "precondition: the fault names pane id desk-pane-2-doc:#{a}, the page has #{inspect(ids)}"

    # The backend comes back; nobody presses Retry.
    fault.up.()

    healed? = poll(fn -> settle(view) && has_element?(view, @filled, "About Alpha retry") end)

    assert healed?,
           "the pane stayed on its error card after the backend came back " <>
             "(it read #{length(fault.stamps.())} time(s))"

    assert has_element?(view, @card) == false, "the card stayed beside the filled pane"
  end

  test "a lasting outage is read again a bounded number of times, each wait longer", %{
    conn: conn,
    url: url,
    a: a
  } do
    fault = outage(a)
    {:ok, view, _html} = live(conn, url)
    assert poll(fn -> card?(view) end), "the failed pane never showed its Retry card"

    # 100 + 300 + 900 ms of waits; then twice that again of a backend still down.
    budget = Enum.sum(@waits)
    poll(fn -> length(fault.stamps.()) == 1 + length(@waits) end, div(budget * 2, 20))
    Process.sleep(budget)
    settle(view)

    stamps = fault.stamps.()

    assert length(stamps) == 1 + length(@waits),
           "expected the first read and #{length(@waits)} automatic ones, got #{length(stamps)} " <>
             "reads against a backend that stays down"

    gaps = stamps |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [x, y] -> y - x end)

    for {gap, wait} <- Enum.zip(gaps, @waits) do
      assert gap >= wait,
             "an automatic read came #{gap} ms after the last one, before its #{wait} ms wait " <>
               "(gaps #{inspect(gaps)})"
    end

    assert card?(view), "after the bound the pane no longer offers its Retry"
  end

  test "the default schedule is bounded and each wait is at least the one before" do
    Application.delete_env(:barkpark, LiveRefresh)
    waits = LiveRefresh.retry_waits_ms()

    assert length(waits) in 1..10, "the default retries #{length(waits)} times"

    assert waits == Enum.sort(waits),
           "the default waits do not grow: #{inspect(waits)}"

    assert List.last(waits) > hd(waits), "the default waits never grow: #{inspect(waits)}"
  end
end
