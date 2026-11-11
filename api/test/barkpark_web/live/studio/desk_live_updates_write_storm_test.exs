defmodule BarkparkWeb.Studio.DeskLiveUpdatesWriteStormTest do
  @moduledoc """
  The desk under a write storm (`BarkparkWeb.Studio.Desk.LiveRefresh`).

  Every `:desk_refresh` the page receives asks each stale pane to read again,
  and a pane that reads again drops the read it had in flight. So the number
  of `:desk_refresh` messages during a burst of document changes is the
  number of times a list read was restarted: this file counts them.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @type_name "desk_storm_note"

  setup %{conn: conn} do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Desk storm notes",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    id = "storm-#{System.unique_integer([:positive])}"

    {:ok, _doc} =
      Content.create_document(@type_name, %{"doc_id" => id, "title" => "Storm note"}, @dataset)

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-storm-token-" <> Ecto.UUID.generate()

    {:ok, _} =
      Auth.create_token(
        raw,
        "desk-storm",
        @dataset,
        ["read", "write", "admin"],
        Tenancy.get_default_workspace().id
      )

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    url = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk/content-types;#{@type_name}"

    {:ok, view, _html} = live(conn, url)
    render_async(view, 5_000)
    assert has_element?(view, "a", "Storm note"), "the list pane never showed its row"

    :erlang.trace(view.pid, true, [:receive])
    on_exit(fn -> Process.alive?(view.pid) && :erlang.trace(view.pid, false, [:receive]) end)

    {:ok, view: view, id: id}
  end

  defp change(view, id),
    do: send(view.pid, {:document_changed, %{type: @type_name, doc_id: id}})

  # How many :desk_refresh messages the page has received since the last count.
  defp refreshes(view, count \\ 0) do
    pid = view.pid

    receive do
      {:trace, ^pid, :receive, :desk_refresh} -> refreshes(view, count + 1)
      {:trace, ^pid, :receive, _other} -> refreshes(view, count)
    after
      0 -> count
    end
  end

  defp await_refresh(view, within_ms) do
    pid = view.pid

    receive do
      {:trace, ^pid, :receive, :desk_refresh} -> true
    after
      within_ms -> false
    end
  end

  test "one change is one read, a moment later", %{view: view, id: id} do
    change(view, id)

    assert await_refresh(view, 1_000),
           "a single document change asked for no read within a second"

    # The page has handled everything sent so far.
    _ = :sys.get_state(view.pid)
    assert refreshes(view) == 0, "a single document change asked for more than one read"
  end

  test "a burst of changes restarts the list read a few times, not every 120 ms",
       %{view: view, id: id} do
    # 480 changes, one every 5 ms: about 2.4 s of an import writing documents.
    for _ <- 1..480 do
      change(view, id)
      Process.sleep(5)
    end

    # Every change is handled; whatever read the last one asked for is still due.
    _ = :sys.get_state(view.pid)
    during = refreshes(view)

    assert await_refresh(view, 4_000),
           "no read followed the last change of the burst: the list would stay stale"

    Process.sleep(300)
    total = during + 1 + refreshes(view)

    assert total <= 8,
           "the list read was restarted #{total} times in a 2.4 s burst " <>
             "(one every 120 ms is about 20: a read slower than that never lands)"

    # The stream paused: the next change gets the short wait again.
    Process.sleep(400)
    change(view, id)

    assert await_refresh(view, 600),
           "after the burst a single change waited longer than 600 ms for its read"
  end
end
