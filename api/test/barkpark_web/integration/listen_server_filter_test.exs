defmodule BarkparkWeb.Integration.ListenServerFilterTest do
  @moduledoc """
  task-684369333a0f0deb: `GET /w/:ws/p/:proj/v1/data/listen/:dataset` honours
  `?types=`, `?perspective=` and `filter[field]=value` on the server.

  On main the controller read none of them, so every subscriber got every
  mutation in scope. The SDK and `bp listen` send all three.

  The drive is the one `listen_grant_narrowing_test.exs` established. The real
  route runs inside a `Task`, and one `:sse_overloaded` is posted to the
  connection process. That is the controller's own slow-consumer signal: it
  sheds the loop and hands back the accumulated chunk body.

  Both stream legs are covered:

    * REPLAY: `?lastEventId=0` replays the workspace event log.
    * LIVE: the connection process is handed the genuine broadcast messages,
      captured in `setup`.

  The fixture is a mixed stream:

    * a `post` draft that is later published, with `stage: "live"`;
    * a `post` draft only, with `stage: "wip"`;
    * an `article` draft that is later published, with `stage: "live"`.
  """

  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Content}

  @ds "production"

  setup %{conn: conn} do
    ensure_default_scope!()
    ws = create_workspace!("listen-filter-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "listen-filter-p-#{System.unique_integer([:positive])}")
    opts = [workspace_id: ws.id, project_id: proj.id]

    Phoenix.PubSub.subscribe(Barkpark.PubSub, "documents:ws:#{ws.id}:#{@ds}")

    {:ok, _} = create_document_in!(ws, proj, "post", %{"_id" => "p-live", "stage" => "live"}, @ds)
    {:ok, _} = Content.publish_document("p-live", "post", @ds, opts)
    {:ok, _} = create_document_in!(ws, proj, "post", %{"_id" => "p-wip", "stage" => "wip"}, @ds)

    {:ok, _} =
      create_document_in!(ws, proj, "article", %{"_id" => "a-live", "stage" => "live"}, @ds)

    {:ok, _} = Content.publish_document("a-live", "article", @ds, opts)

    msgs = drain_broadcasts([])
    assert length(msgs) >= 5, "expected the fixture's writes to broadcast: #{inspect(msgs)}"

    raw = "listen-filter-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(raw, "listen-filter", @ds, ["read"], ws.id)
    conn = put_req_header(conn, "authorization", "Bearer " <> raw)

    {:ok, conn: conn, path: "/w/#{ws.slug}/p/#{proj.slug}/v1/data/listen/#{@ds}", msgs: msgs}
  end

  defp drain_broadcasts(acc) do
    receive do
      {:document_changed, %{event_id: _} = msg} -> drain_broadcasts([msg | acc])
    after
      300 -> Enum.reverse(acc)
    end
  end

  defp replay(conn, path, params) do
    task = Task.async(fn -> get(conn, path, Map.put(params, "lastEventId", "0")) end)
    send(task.pid, :sse_overloaded)
    Task.await(task, 20_000)
  end

  defp live(conn, path, params, msgs) do
    task = Task.async(fn -> get(conn, path, params) end)
    Enum.each(msgs, &send(task.pid, {:document_changed, &1}))
    send(task.pid, :sse_overloaded)
    Task.await(task, 20_000)
  end

  defp seen(%{status: 200, resp_body: body}) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn frame ->
      frame
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, "data: "))
      |> Enum.map(&(&1 |> String.replace_prefix("data: ", "") |> Jason.decode!()))
    end)
    |> Enum.filter(&Map.has_key?(&1, "documentId"))
    |> Enum.map(&{&1["type"], &1["documentId"]})
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp seen(conn), do: flunk("expected a 200 stream, got #{conn.status}: #{conn.resp_body}")

  @all [
    {"article", "a-live"},
    {"article", "drafts.a-live"},
    {"post", "drafts.p-live"},
    {"post", "drafts.p-wip"},
    {"post", "p-live"}
  ]

  for {leg, drive} <- [replay: :replay, live: :live] do
    describe "#{leg} leg" do
      setup ctx do
        drive = unquote(drive)

        run = fn params ->
          case drive do
            :replay -> replay(ctx.conn, ctx.path, params)
            :live -> live(ctx.conn, ctx.path, params, ctx.msgs)
          end
        end

        {:ok, run: run}
      end

      test "no params: every event, as before", %{run: run} do
        assert seen(run.(%{})) == @all
      end

      test "?types=post drops the article", %{run: run} do
        assert seen(run.(%{"types" => "post"})) ==
                 [{"post", "drafts.p-live"}, {"post", "drafts.p-wip"}, {"post", "p-live"}]
      end

      test "?types=post,article is a set", %{run: run} do
        assert seen(run.(%{"types" => "post, article"})) == @all
      end

      test "?perspective=published drops draft writes", %{run: run} do
        assert seen(run.(%{"perspective" => "published"})) ==
                 [{"article", "a-live"}, {"post", "p-live"}]
      end

      test "?perspective=drafts and raw keep both", %{run: run} do
        assert seen(run.(%{"perspective" => "drafts"})) == @all
        assert seen(run.(%{"perspective" => "raw"})) == @all
      end

      test "filter[stage]=wip keeps only the matching document", %{run: run} do
        assert seen(run.(%{"filter" => %{"stage" => "wip"}})) == [{"post", "drafts.p-wip"}]
      end

      test "a comma filter value is any-of, composed with types", %{run: run} do
        assert seen(run.(%{"types" => "post", "filter" => %{"stage" => "wip,live"}})) ==
                 [{"post", "drafts.p-live"}, {"post", "drafts.p-wip"}, {"post", "p-live"}]
      end
    end
  end

  describe "the filter reads the REDACTED document" do
    test "a filter on a private field never matches for a non-admin, so it cannot probe it",
         ctx do
      [ws_id] = ctx.msgs |> Enum.map(& &1.workspace_id) |> Enum.uniq()
      ws = Barkpark.Repo.get!(Barkpark.Tenancy.Workspace, ws_id)
      [proj] = Barkpark.Tenancy.list_projects(ws)
      opts = [workspace_id: ws.id, project_id: proj.id]

      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => "memo",
            "title" => "Memo",
            "visibility" => "public",
            "fields" => [
              %{"name" => "topic", "type" => "string"},
              %{"name" => "pin", "type" => "string", "private" => true}
            ]
          },
          @ds,
          opts
        )

      {:ok, _} =
        create_document_in!(
          ws,
          proj,
          "memo",
          %{"_id" => "m1", "topic" => "t", "pin" => "4242"},
          @ds
        )

      [msg] = drain_broadcasts([])

      # CONTROL: the memo streams, and a filter on its VISIBLE field matches.
      assert seen(live(ctx.conn, ctx.path, %{"filter" => %{"topic" => "t"}}, [msg])) ==
               [{"memo", "drafts.m1"}]

      # The private field's true value does not match: the caller cannot see it.
      assert seen(live(ctx.conn, ctx.path, %{"filter" => %{"pin" => "4242"}}, [msg])) == []
    end
  end

  describe "refused before the stream opens" do
    test "an unsupported perspective is a 400 naming the supported set", ctx do
      conn = live(ctx.conn, ctx.path, %{"perspective" => "drafst"}, [])
      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["details"]["supported"] == ["published", "drafts", "raw"]
      assert body["error"]["details"]["received"] == "drafst"
    end

    test "an operator filter is a 400, not a silent over-send", ctx do
      conn = live(ctx.conn, ctx.path, %{"filter" => %{"stage" => %{"neq" => "wip"}}}, [])
      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"]["message"] =~ "equality filters only"
    end
  end
end
