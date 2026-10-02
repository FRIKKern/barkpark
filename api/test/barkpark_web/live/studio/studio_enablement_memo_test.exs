defmodule BarkparkWeb.Studio.StudioEnablementMemoTest do
  @moduledoc """
  A connected Studio socket reads its workspace's plugin enablement ONCE, not
  once per render (task-c8a87043cb286a2f) — and a workspace write still takes
  effect on the socket's next render.

  Measured before the memo, with the lineage-scoped `Barkpark.QueryCounter`:
  six sequential desk mounts cost 59, 60, 61, 62, 63, 64 statements. Each one
  paid a `workspaces` read for every OTHER live Studio session, because
  `presence_diff` re-renders every open socket and every render resolved
  `Plugins.Enablement.effective/1` from the row (`studio_live_shell` doc actions
  and the top-menu tabs). After: 56, 56, 56, 56, 56, 56.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.Plugins.Enablement
  alias Barkpark.QueryCounter
  alias Barkpark.Tenancy

  @dataset "production"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "memoish",
          "title" => "Memoish",
          "icon" => "file-text",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    :ok
  end

  defp path, do: scoped_studio("/d/#{@dataset}/studio/content-types/memoish")

  defp mount_counted(conn) do
    QueryCounter.census(fn ->
      {:ok, view, _html} = live(conn, path())
      QueryCounter.own(view.pid)
      _ = render(view)
      view
    end)
  end

  # A re-render nothing in the socket's own state asked for — the shape a
  # presence join on the workspace produces on every open socket.
  # A presence JOIN on the socket's workspace: another session tracks itself on
  # the topic (synchronous), and the socket gets the `presence_diff` that a join
  # delivers — handed over directly, so the re-render is not left to the
  # tracker's broadcast timing. The socket re-lists presences, which CHANGED, so
  # it really re-renders (asserted below, or the zero would be vacuous).
  defp rerender_counted(view) do
    topic = :sys.get_state(view.pid).socket.assigns.presence_topic
    key = "joiner-#{System.unique_integer([:positive])}"
    joiner = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(joiner, :kill) end)

    {:ok, _} =
      BarkparkWeb.Presence.track(joiner, topic, key, %{
        doc_id: nil,
        type: nil,
        dataset: @dataset,
        project_id: nil,
        name: key,
        color: "#888888",
        joined_at: System.system_time(:second)
      })

    {html, census} =
      QueryCounter.census(fn ->
        send(view.pid, %Phoenix.Socket.Broadcast{
          event: "presence_diff",
          topic: topic,
          payload: %{}
        })

        QueryCounter.own(view.pid)
        render(view)
      end)

    assert Enum.any?(:sys.get_state(view.pid).socket.assigns.presences, &(&1[:user_id] == key)),
           "the join never reached the socket's presences — no re-render was measured"

    {html, census}
  end

  test "a desk mount costs the same statements however many Studio sessions are open", %{
    conn: conn
  } do
    {first, {n_first, _}} = mount_counted(conn)
    assert n_first > 0, "the counter saw nothing — the measurement is vacuous"

    # four more live sessions on the same workspace, all kept open
    others = for _ <- 1..4, do: elem(mount_counted(conn), 0)

    {_last, {n_last, per_last}} = mount_counted(conn)

    assert n_last == n_first,
           "the 6th mount cost #{n_last} statements against #{n_first} for the 1st, with 5 " <>
             "sessions open — an open session is being paid for by every new one " <>
             "(#{inspect(per_last)})"

    assert Process.alive?(first.pid) and Enum.all?(others, &Process.alive?(&1.pid))
  end

  test "re-renders of a connected socket read the workspace row zero times", %{conn: conn} do
    {view, _} = mount_counted(conn)

    for _ <- 1..3 do
      {_html, {_n, per}} = rerender_counted(view)

      assert Map.get(per, "workspaces", 0) == 0,
             "a re-render read the workspace row #{per["workspaces"]}x: #{inspect(per)}"
    end
  end

  test "a workspace write is still seen: the next render reads the row again", %{conn: conn} do
    {view, _} = mount_counted(conn)
    {_html, {_n, before}} = rerender_counted(view)
    assert Map.get(before, "workspaces", 0) == 0

    ws = Tenancy.get_default_workspace()
    {:ok, _} = Tenancy.set_workspace_plugin_settings(ws, %{"media" => %{"placement" => "main"}})

    # the broadcast is delivered to the socket before this render request,
    # which travels the same mailbox after it
    {_html, {_n, after_write}} = rerender_counted(view)

    assert Map.get(after_write, "workspaces", 0) >= 1,
           "the socket kept serving its memo after a plugin-settings write: #{inspect(after_write)}"

    # …and memoizes again: the render after that reads nothing
    {_html, {_n, settled}} = rerender_counted(view)
    assert Map.get(settled, "workspaces", 0) == 0
  end

  test "ANY workspace write through Tenancy drops the memo, not only a plugin toggle", %{
    conn: conn
  } do
    {view, _} = mount_counted(conn)
    ws = Tenancy.get_default_workspace()
    # a theme change writes the same `settings` bag the plugin overrides live in
    {:ok, _} = Tenancy.set_workspace_theme(ws, Tenancy.workspace_theme(ws))
    {_html, {_n, per}} = rerender_counted(view)

    assert Map.get(per, "workspaces", 0) >= 1,
           "a settings write did not drop the memo: #{inspect(per)}"
  end

  test "the memo holds the SAME answer an unmemoized read gives — before and after a toggle and an archive" do
    {:ok, ws} =
      Tenancy.create_workspace(%{
        slug: "memo-ws-#{System.unique_integer([:positive])}",
        name: "Memo"
      })

    fresh = fn -> Task.async(fn -> Enablement.effective(ws.id) end) |> Task.await() end

    :ok = Enablement.memoize!(ws.id)
    assert Enablement.effective(ws.id) == fresh.()

    {:ok, _} = Tenancy.set_workspace_plugin_settings(ws.id, %{"media" => %{"enabled" => false}})
    assert_receive {:plugin_enablement_changed, id} when id == ws.id
    Enablement.forget(ws.id)
    assert Enablement.effective(ws.id) == fresh.()
    assert Enablement.effective(ws.id)["media"].enabled == false

    # archive is not an enablement input (the row and its settings stay) — the
    # memoized answer and a fresh read still agree
    {:ok, _} = Tenancy.archive_workspace(Tenancy.get_workspace_by_id(ws.id))
    assert Enablement.effective(ws.id) == fresh.()
  end
end
