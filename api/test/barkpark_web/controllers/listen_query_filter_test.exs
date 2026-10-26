defmodule BarkparkWeb.ListenQueryFilterTest do
  @moduledoc """
  task-72331698ada8a2f6: `@sanity/client`'s `listen(query, params, {includeResult})`.
  Only a mutation whose document matches `*[<filter>]` before or after is sent, with
  Sanity's `transition`; `includeResult=false` leaves `result` out. The filter only
  narrows: it runs on the document as the subscriber may see it.

  The stream runs in a Task; the test writes, then sends `:retire` (the drain signal),
  which ends the stream, and reads every frame it wrote.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Tenancy}

  @dataset "listen_q_ds"

  setup do
    {:ok, ws} = Tenancy.create_workspace(%{slug: "listen-q", name: "Listen query"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "site", name: "Site"})
    scope = [workspace_id: ws.id, project_id: proj.id]

    for {type, fields} <- [
          {"post",
           [
             %{"name" => "title", "type" => "string"},
             %{"name" => "featured", "type" => "boolean"},
             %{"name" => "secret", "type" => "string", "private" => true}
           ]},
          {"author", [%{"name" => "name", "type" => "string"}]}
        ] do
      {:ok, _} =
        Content.upsert_schema(
          %{"name" => type, "title" => type, "visibility" => "public", "fields" => fields},
          @dataset,
          scope
        )
    end

    put!(scope, "post", "p1", %{"title" => "One", "featured" => true, "secret" => "s"})
    put!(scope, "post", "p2", %{"title" => "Two", "featured" => false})
    put!(scope, "author", "a1", %{"name" => "Ada"})

    token = "listen-q-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(token, "listen q", @dataset, ["read", "write"], ws.id)
    %{token: token, scope: scope}
  end

  defp put!(scope, type, id, fields) do
    {:ok, _} = Content.upsert_document(type, Map.merge(%{"_id" => id}, fields), @dataset, scope)
  end

  defp stream(token, query, during) do
    task =
      Task.async(fn ->
        scoped_conn()
        |> put_req_header("authorization", "Bearer " <> token)
        |> put_req_header("accept", "text/event-stream")
        |> get("/w/listen-q/p/site/v2025-02-19/data/listen/#{@dataset}", query)
      end)

    Process.sleep(300)
    during.()
    Process.sleep(300)
    send(task.pid, :retire)
    conn = Task.await(task, 5_000)

    conn.resp_body
    |> String.split("\n\n", trim: true)
    |> Enum.filter(&String.contains?(&1, "event: mutation"))
    |> Enum.map(fn block ->
      [_, data] = Regex.run(~r/^data: (.*)$/m, block)
      Jason.decode!(data)
    end)
  end

  test "only documents matching the query, before or after, with their transition", %{
    token: t,
    scope: scope
  } do
    events =
      stream(t, %{"query" => ~s|*[_type == "post" && featured == $f]|, "$f" => "true"}, fn ->
        put!(scope, "post", "p1", %{"title" => "One, edited", "featured" => true})
        put!(scope, "post", "p1", %{"title" => "One", "featured" => false})
        put!(scope, "post", "p2", %{"title" => "Two", "featured" => true})
        put!(scope, "author", "a1", %{"name" => "Ada L"})
      end)

    assert Enum.map(events, &{&1["documentId"], &1["transition"]}) == [
             {"drafts.p1", "update"},
             {"drafts.p1", "disappear"},
             {"drafts.p2", "appear"}
           ]

    assert Enum.all?(events, &is_map(&1["result"]))
  end

  test "an author-only listener hears nothing when a post changes; includeResult=false leaves result out",
       %{token: t, scope: scope} do
    assert [] ==
             stream(t, %{"query" => ~s|*[_type == "author"]|}, fn ->
               put!(scope, "post", "p1", %{"title" => "x", "featured" => true})
             end)

    [event] =
      stream(t, %{"query" => ~s|*[_type == "author"]|, "includeResult" => "false"}, fn ->
        put!(scope, "author", "a1", %{"name" => "Ada B"})
      end)

    assert event["transition"] == "update"
    refute Map.has_key?(event, "result")
  end

  test "a filter on a field the subscriber cannot read never matches", %{scope: scope} do
    reader = "listen-q-read-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(reader, "reader", @dataset, ["read"], scope[:workspace_id])

    assert [] ==
             stream(reader, %{"query" => ~s|*[_type == "post" && secret == "s"]|}, fn ->
               put!(scope, "post", "p1", %{"title" => "z", "featured" => true, "secret" => "s"})
             end)

    # The control: the same reader hears the post through a filter it can read.
    assert [%{"transition" => "update"}] =
             stream(reader, %{"query" => ~s|*[_type == "post" && featured == true]|}, fn ->
               put!(scope, "post", "p1", %{"title" => "zz", "featured" => true, "secret" => "s"})
             end)
  end

  test "without a query the stream is as before: every event, no transition", %{
    token: t,
    scope: scope
  } do
    events = stream(t, %{}, fn -> put!(scope, "author", "a1", %{"name" => "Ada C"}) end)
    assert [%{"documentId" => "drafts.a1"} = e] = events
    refute Map.has_key?(e, "transition")
    assert is_map(e["result"])
  end

  # As on Sanity (read-only probe of ecu57yeh, 26 Oct): a projection or order after
  # the filter is ignored, any other query opens the stream unnarrowed, and only a
  # query that does not parse is refused.
  test "the filter under a projection still narrows; another shape narrows nothing", %{
    token: t,
    scope: scope
  } do
    assert [] ==
             stream(t, %{"query" => ~s/*[_type == "author"]{name} | order(name)/}, fn ->
               put!(scope, "post", "p1", %{"title" => "q", "featured" => true})
             end)

    assert [%{"documentId" => "drafts.p1"} = e] =
             stream(t, %{"query" => ~s|count(*[_type == "author"])|}, fn ->
               put!(scope, "post", "p1", %{"title" => "r", "featured" => true})
             end)

    refute Map.has_key?(e, "transition")
  end

  test "a query that does not parse is refused before the stream opens", %{token: t} do
    conn =
      scoped_conn()
      |> put_req_header("authorization", "Bearer " <> t)
      |> get("/w/listen-q/p/site/v2025-02-19/data/listen/#{@dataset}", %{"query" => "*["})

    assert conn.status == 400
  end
end
