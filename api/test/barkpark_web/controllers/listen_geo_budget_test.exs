defmodule BarkparkWeb.ListenGeoBudgetTest do
  @moduledoc """
  task-04f37760a2598bbf: a listen filter's geo::contains / geo::intersects
  calls get a budget per event (position pairs, as on the query endpoint). A
  filter that could pass it on any event is refused when the stream opens; a
  filter that passes it on one event ends the stream with `channelError`, never
  a silent false. A plain point-in-polygon listener is untouched.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Tenancy}

  @dataset "listen_geo_ds"
  @path "/w/listen-geo/p/site/v2025-02-19/data/listen/#{@dataset}"

  setup do
    {:ok, ws} = Tenancy.create_workspace(%{slug: "listen-geo", name: "Listen geo"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "site", name: "Site"})
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "place", "title" => "place", "visibility" => "public", "fields" => []},
        @dataset,
        scope
      )

    token = "listen-geo-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(token, "listen geo", @dataset, ["read", "write"], ws.id)
    %{token: token, scope: scope}
  end

  defp put!(scope, id, fields) do
    {:ok, _} =
      Content.upsert_document("place", Map.merge(%{"_id" => id}, fields), @dataset, scope)
  end

  defp open(token, params) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("accept", "text/event-stream")
    |> get(@path, params)
  end

  # Runs the stream in a task. With `retire: false` the stream must end by
  # itself: the await fails if it is still open.
  defp stream(token, params, during, retire \\ true) do
    task = Task.async(fn -> open(token, params) end)
    Process.sleep(300)
    during.()
    Process.sleep(300)
    if retire, do: send(task.pid, :retire)
    Task.await(task, 5_000).resp_body
  end

  defp frames(body, event) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.filter(&String.contains?(&1, "event: #{event}"))
    |> Enum.map(fn block ->
      [_, data] = Regex.run(~r/^data: (.*)$/m, block)
      Jason.decode!(data)
    end)
  end

  defp square(x0, y0, x1, y1),
    do: %{
      "type" => "Polygon",
      "coordinates" => [[[x0, y0], [x1, y0], [x1, y1], [x0, y1], [x0, y0]]]
    }

  # A 999-gon: a shape at the 1000-position cap.
  defp circle(cx, cy) do
    pts =
      for i <- 0..998,
          do: [cx + :math.cos(i / 999 * 2 * :math.pi()), cy + :math.sin(i / 999 * 2 * :math.pi())]

    %{"type" => "Polygon", "coordinates" => [pts ++ [hd(pts)]]}
  end

  test "a filter whose geo calls could pass the budget on any event is refused at open", %{
    token: t
  } do
    # 800 calls of a small polygon against a document field: a field may hold a
    # shape at the cap, so each call may cost 5 × 1000 pairs.
    query = "*[" <> Enum.map_join(1..800, " || ", fn _ -> "geo::intersects($b, area)" end) <> "]"
    conn = open(t, %{"query" => query, "$b" => Jason.encode!(square(0, 0, 1, 1))})

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["message"] =~ "position pairs"
  end

  test "a filter past the budget on one event ends the stream with channelError", %{
    token: t,
    scope: scope
  } do
    # One call site, within the budget on its own; a document with three
    # shapes at the cap runs it three times.
    params = %{
      "query" => ~s|*[_type == "place" && count(areas[geo::intersects($b, @)]) > 0]|,
      "$b" => Jason.encode!(circle(0, 0))
    }

    {micros, body} =
      :timer.tc(fn ->
        stream(
          t,
          params,
          fn -> put!(scope, "big", %{"areas" => List.duplicate(circle(1.9, 1.9), 3)}) end,
          false
        )
      end)

    assert [%{"message" => message}] = frames(body, "channelError")
    assert message =~ "position pairs"
    assert frames(body, "mutation") == []
    assert micros < 3_000_000, "took #{div(micros, 1000)} ms"
  end

  test "a point-in-polygon listener keeps matching across many events", %{
    token: t,
    scope: scope
  } do
    params = %{
      "query" => ~s|*[_type == "place" && geo::contains($region, location)]|,
      "$region" => Jason.encode!(square(10, 59, 11, 60))
    }

    body =
      stream(t, params, fn ->
        for i <- 1..10 do
          lng = if rem(i, 2) == 1, do: 10.5, else: 12.5

          put!(scope, "oslo", %{
            "location" => %{"_type" => "geopoint", "lat" => 59.9, "lng" => lng}
          })
        end
      end)

    assert frames(body, "channelError") == []

    assert Enum.map(frames(body, "mutation"), & &1["transition"]) ==
             List.duplicate(["appear", "disappear"], 5) |> List.flatten()
  end
end
