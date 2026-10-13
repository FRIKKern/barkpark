defmodule BarkparkWeb.Integration.PreviewListenDocScopeTest do
  @moduledoc """
  task-78dc25a4f117fa07 — `GET /v1/preview/listen/:dataset`, the PreviewToken
  JWT's own listen route, mounted onto `ListenController.listen/2` (the same
  action `/v1/data/listen/:dataset` uses) with ZERO new controller logic
  beyond `ListenFilter`'s new `only_doc_ids` fence.

  A doc-scoped `Barkpark.PreviewToken` (owner ruling #17) must never forward
  a SIBLING document's mutation on either stream leg — the same fence its
  `GET .../doc/:dataset/:type/:doc_id` read already has
  (`preview_token_doc_scope_test.exs`), extended here to the push surface.
  Drive pattern borrowed from `listen_server_filter_test.exs`: the route runs
  inside a `Task`, fed either real captured broadcasts (live leg) or driven
  via `?lastEventId=0` (replay leg), then shed with `:sse_overloaded`.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Content, PreviewToken}

  @ds "production"
  @secret "test-preview-secret-listen-scope-1234567890"

  setup %{conn: conn} do
    prior = Application.get_env(:barkpark, :preview)

    Application.put_env(:barkpark, :preview,
      secret: @secret,
      ttl_seconds: 600,
      issuer: "barkpark"
    )

    on_exit(fn -> Application.put_env(:barkpark, :preview, prior || []) end)

    {ws, proj} = ensure_default_scope!()

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        @ds
      )

    Phoenix.PubSub.subscribe(Barkpark.PubSub, "documents:ws:#{ws.id}:#{@ds}")

    {:ok, _} = create_document_in!(ws, proj, "post", %{"_id" => "mine", "title" => "MINE"}, @ds)
    {:ok, _} = create_document_in!(ws, proj, "post", %{"_id" => "sib", "title" => "SIBLING"}, @ds)

    msgs = drain_broadcasts([])
    assert length(msgs) >= 2, "expected the fixture's writes to broadcast: #{inspect(msgs)}"

    {:ok, conn: conn, path: "/v1/preview/listen/#{@ds}", msgs: msgs}
  end

  defp drain_broadcasts(acc) do
    receive do
      {:document_changed, %{event_id: _} = msg} -> drain_broadcasts([msg | acc])
    after
      300 -> Enum.reverse(acc)
    end
  end

  defp jwt(claims), do: elem(PreviewToken.sign(Map.merge(%{dataset: @ds}, claims), @secret), 0)

  defp preview(conn, token), do: put_req_header(conn, "authorization", "Preview " <> token)

  defp live(conn, path, params, msgs) do
    task = Task.async(fn -> get(conn, path, params) end)
    Enum.each(msgs, &send(task.pid, {:document_changed, &1}))
    send(task.pid, :sse_overloaded)
    Task.await(task, 20_000)
  end

  defp replay(conn, path, params) do
    task = Task.async(fn -> get(conn, path, Map.put(params, "lastEventId", "0")) end)
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
    |> Enum.map(& &1["documentId"])
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp seen(conn), do: flunk("expected a 200 stream, got #{conn.status}: #{conn.resp_body}")

  test "a doc-scoped token's LIVE stream sees only its own document, never a sibling's", %{
    conn: conn,
    path: path,
    msgs: msgs
  } do
    out = live(conn |> preview(jwt(%{doc_ids: ["mine"]})), path, %{}, msgs)
    assert seen(out) == ["drafts.mine"]
  end

  test "a doc-scoped token's REPLAY leg ALSO fences to its own document", %{
    conn: conn,
    path: path
  } do
    out = replay(conn |> preview(jwt(%{doc_ids: ["mine"]})), path, %{})
    assert seen(out) == ["drafts.mine"]
  end

  test "a dataset-wide (empty doc_ids) token keeps seeing every document, unchanged", %{
    conn: conn,
    path: path,
    msgs: msgs
  } do
    out = live(conn |> preview(jwt(%{doc_ids: []})), path, %{}, msgs)
    assert seen(out) == ["drafts.mine", "drafts.sib"]
  end

  test "a `drafts.`-prefixed doc_ids claim matches the same document", %{
    conn: conn,
    path: path,
    msgs: msgs
  } do
    out = live(conn |> preview(jwt(%{doc_ids: ["drafts.mine"]})), path, %{}, msgs)
    assert seen(out) == ["drafts.mine"]
  end

  test "a bearer token (no PreviewToken) is refused on this route", %{conn: conn, path: path} do
    resp =
      conn
      |> put_req_header("authorization", "Bearer not-a-preview-token")
      |> get(path, %{"lastEventId" => "0"})

    assert resp.status == 401
  end

  test "no token at all is refused", %{conn: conn, path: path} do
    resp = get(conn, path, %{"lastEventId" => "0"})
    assert resp.status == 401
  end
end
