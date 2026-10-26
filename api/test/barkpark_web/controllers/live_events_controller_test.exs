defmodule BarkparkWeb.LiveEventsControllerTest do
  @moduledoc """
  task-d6566cbed9b7c33c: Sanity's Live Content API stream,
  `GET …/v{apiVersion}/data/live/events/:dataset`.

  The stream runs in a Task: a test publishes, sends the stream `:flush` (its
  one-second batch timer, early) and then `:retire` (the drain signal), which
  ends it, and reads every frame it wrote.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Tenancy}
  alias Barkpark.Groq.SyncTag

  @dataset "live_events_ds"

  setup do
    {:ok, ws} = Tenancy.create_workspace(%{slug: "live-events", name: "Live events"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "site", name: "Site"})
    {:ok, other} = Tenancy.create_project(ws, %{slug: "other", name: "Other"})
    scope = [workspace_id: ws.id, project_id: proj.id]

    for s <- [scope, [workspace_id: ws.id, project_id: other.id]] do
      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => "page",
            "title" => "Page",
            "visibility" => "public",
            "fields" => [%{"name" => "slug", "type" => "string"}]
          },
          @dataset,
          s
        )
    end

    token = "live-events-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(token, "live", @dataset, ["read", "write"], ws.id)

    {:ok,
     token: token,
     scope: scope,
     project_id: proj.id,
     other: [workspace_id: ws.id, project_id: other.id]}
  end

  defp path(query \\ ""),
    do: "/w/live-events/p/site/v2025-02-19/data/live/events/#{@dataset}#{query}"

  # Opens the stream in a Task; `during` runs while it is subscribed.
  defp stream(token, query \\ "", during) do
    task =
      Task.async(fn ->
        scoped_conn()
        |> put_req_header("authorization", "Bearer " <> token)
        |> put_req_header("accept", "text/event-stream")
        |> get(path(query))
      end)

    Process.sleep(200)
    during.()
    Process.sleep(100)
    send(task.pid, :flush)
    Process.sleep(100)
    send(task.pid, :retire)
    conn = Task.await(task, 5_000)
    frames(conn.resp_body)
  end

  defp frames(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, ":"))
    |> Enum.map(fn block ->
      fields =
        for line <- String.split(block, "\n"),
            [k, v] <- [String.split(line, ": ", parts: 2)],
            into: %{},
            do: {k, v}

      %{
        event: fields["event"],
        id: fields["id"],
        data: fields["data"] && Jason.decode!(fields["data"])
      }
    end)
  end

  defp publish!(scope, id, fields \\ %{}) do
    {:ok, _} =
      Content.create_document(
        "page",
        Map.merge(%{"_id" => id, "title" => id}, fields),
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document(id, "page", @dataset, scope)
  end

  defp twin(project_id, tag), do: SyncTag.opaque(project_id, tag)

  test "below API 2021-03-25 the stream is refused 400", %{conn: conn, token: t} do
    for v <- ["1", "2020-01-01"] do
      conn
      |> put_req_header("authorization", "Bearer " <> t)
      |> get("/w/live-events/p/site/v#{v}/data/live/events/#{@dataset}")
      |> json_response(400)
    end
  end

  test "welcome, then one message of opaque tags for a published change", %{
    token: t,
    scope: scope,
    project_id: pid
  } do
    [welcome | rest] = stream(t, fn -> publish!(scope, "p1") end)
    assert welcome.event == "welcome" and welcome.data == %{}

    [message] = Enum.filter(rest, &(&1.event == "message"))
    tags = message.data["tags"]

    assert twin(pid, "bp:ds:#{@dataset}:doc:p1") in tags
    assert twin(pid, "bp:ds:#{@dataset}:type:page") in tags
    assert twin(pid, "bp:ds:#{@dataset}:_all") in tags
    refute Enum.any?(tags, &String.contains?(&1, "bp:ds"))
    assert is_binary(message.id)
  end

  test "the page-created case: a GROQ lookup's _all twin is in the message for the new page", %{
    conn: conn,
    token: t,
    scope: scope
  } do
    fetched =
      conn
      |> put_req_header("authorization", "Bearer " <> t)
      |> get("/w/live-events/p/site/v2025-02-19/data/query/#{@dataset}", %{
        "query" => ~s|*[slug == "new-page"][0]|
      })
      |> json_response(200)
      |> Map.fetch!("syncTags")

    frames = stream(t, fn -> publish!(scope, "np", %{"slug" => "new-page"}) end)
    [message] = Enum.filter(frames, &(&1.event == "message"))
    refute MapSet.disjoint?(MapSet.new(fetched), MapSet.new(message.data["tags"]))
  end

  test "a draft change is sent only with includeDrafts=true", %{token: t, scope: scope} do
    draft = fn id ->
      fn ->
        {:ok, _} = Content.create_document("page", %{"_id" => id, "title" => id}, @dataset, scope)
      end
    end

    assert Enum.filter(stream(t, draft.("d1")), &(&1.event == "message")) == []

    assert [_] =
             Enum.filter(stream(t, "?includeDrafts=true", draft.("d2")), &(&1.event == "message"))
  end

  test "another project's change is not sent", %{token: t, other: other} do
    assert Enum.filter(stream(t, fn -> publish!(other, "o1") end), &(&1.event == "message")) == []
  end

  test "resume: changes since the id come as one message; a bad id gets restart", %{
    token: t,
    scope: scope,
    project_id: pid
  } do
    [welcome | _] = stream(t, fn -> :ok end)
    publish!(scope, "r1")

    [w2, missed | _] = stream(t, "?lastEventId=#{welcome.id || 0}", fn -> :ok end)
    assert w2.event == "welcome"
    assert missed.event == "message"
    assert twin(pid, "bp:ds:#{@dataset}:doc:r1") in missed.data["tags"]

    for bad <- ["nope", "999999999999"] do
      assert [%{event: "restart"} | _] = stream(t, "?lastEventId=#{bad}", fn -> :ok end)
    end
  end

  describe "the per-credential cap" do
    setup do
      previous = Application.get_env(:barkpark, :live_events_max_streams)
      Application.put_env(:barkpark, :live_events_max_streams, 2)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:barkpark, :live_events_max_streams, previous),
          else: Application.delete_env(:barkpark, :live_events_max_streams)
      end)
    end

    defp open_stream(token) do
      Task.async(fn ->
        scoped_conn()
        |> put_req_header("authorization", "Bearer " <> token)
        |> put_req_header("accept", "text/event-stream")
        |> get(path())
      end)
    end

    defp close_stream(task) do
      send(task.pid, :retire)
      frames(Task.await(task, 5_000).resp_body)
    end

    test "at the cap a stream opens; over it the answer is goaway; a closed stream frees its slot",
         %{token: t} do
      [a, b] = for _ <- 1..2, do: open_stream(t)
      Process.sleep(200)

      # The third is over the cap: goaway, and the response ends at once.
      over = open_stream(t) |> Task.await(5_000)
      assert [%{event: "goaway", data: %{"reason" => reason}}] = frames(over.resp_body)
      assert reason =~ "2"

      # Closing one frees its slot for the next.
      assert [%{event: "welcome"} | _] = close_stream(a)
      Process.sleep(100)
      c = open_stream(t)
      Process.sleep(200)

      for task <- [b, c], do: assert([%{event: "welcome"} | _] = close_stream(task))
    end
  end

  test "no anonymous stream", %{conn: conn} do
    status = conn |> get(path()) |> Map.fetch!(:status)
    assert status in [401, 403]
  end
end
