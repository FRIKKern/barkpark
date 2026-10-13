defmodule BarkparkWeb.Integration.ListenProjectNarrowingTest do
  @moduledoc """
  Owner ruling #50 (task-d60479a7749b0ca5): a listen stream opened on a
  `/w/:ws/p/:proj/...` URL carries only that project; a flat `/v1/...` stream
  stays workspace-wide.

  Every project's dataset is usually named `production`, and the stream is
  keyed by workspace + dataset name, so a per-project consumer also received
  sibling projects' changes. For an ADMIN caller the live leg forwarded them
  unredacted (the admin fast path skips the per-project re-render).
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Tenancy}
  alias Barkpark.Content.EventLog
  alias BarkparkWeb.ListenFilter

  @ds "production"

  setup %{conn: conn} do
    ensure_default_scope!()
    ws = create_workspace!("listen-narrow-#{System.unique_integer([:positive])}")
    p1 = create_project!(ws, "narrow-one")
    p2 = create_project!(ws, "narrow-two")
    for p <- [p1, p2], do: {:ok, _} = Tenancy.get_or_create_dataset(p, @ds)

    Phoenix.PubSub.subscribe(Barkpark.PubSub, "documents:ws:#{ws.id}:#{@ds}")

    {:ok, d1} = create_document_in!(ws, p1, "post", %{"_id" => "n-one", "title" => "one"}, @ds)
    {:ok, d2} = create_document_in!(ws, p2, "post", %{"_id" => "n-two", "title" => "two"}, @ds)

    msgs = drain([])

    raw = "listen-narrow-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(raw, "listen-narrow", @ds, ["read", "write", "admin"], ws.id)
    conn = put_req_header(conn, "authorization", "Bearer " <> raw)

    {:ok, conn: conn, ws: ws, p1: p1, p2: p2, d1: d1, d2: d2, msgs: msgs}
  end

  defp drain(acc) do
    receive do
      {:document_changed, %{event_id: _} = msg} -> drain([msg | acc])
    after
      300 -> Enum.reverse(acc)
    end
  end

  defp live(conn, path, msgs) do
    task = Task.async(fn -> get(conn, path) end)
    Enum.each(msgs, &send(task.pid, {:document_changed, &1}))
    send(task.pid, :sse_overloaded)
    Task.await(task, 20_000)
  end

  defp replay(conn, path) do
    task = Task.async(fn -> get(conn, path, %{"lastEventId" => "0"}) end)
    send(task.pid, :sse_overloaded)
    Task.await(task, 20_000)
  end

  defp project_path(ctx, proj), do: "/w/#{ctx.ws.slug}/p/#{proj.slug}/v1/data/listen/#{@ds}"

  test "the live leg on a project URL carries only that project, admin included", ctx do
    assert length(ctx.msgs) >= 2

    body = live(ctx.conn, project_path(ctx, ctx.p1), ctx.msgs).resp_body
    assert body =~ "drafts.n-one"
    refute body =~ "drafts.n-two", "a P1 project stream forwarded P2's live event"
  end

  test "the replay leg on a project URL carries only that project", ctx do
    body = replay(ctx.conn, project_path(ctx, ctx.p2)).resp_body
    assert body =~ "drafts.n-two"
    refute body =~ "drafts.n-one"
  end

  test "EventLog.replay_since narrows by project_id when asked, workspace-wide otherwise", ctx do
    ids = fn opts ->
      @ds |> EventLog.replay_since(0, ctx.ws.id, opts) |> Enum.map(& &1.doc_id) |> Enum.sort()
    end

    assert ids.(project_id: ctx.p1.id) == ["drafts.n-one"]
    assert ids.([]) == ["drafts.n-one", "drafts.n-two"]
  end

  test "pass_meta? keeps a flat (un-narrowed) stream workspace-wide" do
    {:ok, lf} = ListenFilter.parse(%{})
    ev = %{type: "post", doc_id: "x", project_id: "p-a"}

    assert ListenFilter.pass_meta?(lf, ev)
    narrowed = ListenFilter.narrow_to_project(lf, "p-b")
    refute ListenFilter.pass_meta?(narrowed, ev)
    refute ListenFilter.pass_meta?(narrowed, %{ev | project_id: nil})
    assert ListenFilter.pass_meta?(narrowed, %{ev | project_id: "p-b"})
  end

  test "only a URL that names a project narrows" do
    scope = [project_id: "proj-1"]
    project_conn = %Plug.Conn{path_info: ["w", "acme", "p", "site", "v1", "data", "listen", "x"]}
    flat_conn = %Plug.Conn{path_info: ["v1", "data", "listen", "x"]}

    assert BarkparkWeb.ListenController.project_path_project_id(project_conn, scope) == "proj-1"
    assert BarkparkWeb.ListenController.project_path_project_id(flat_conn, scope) == nil
  end
end
