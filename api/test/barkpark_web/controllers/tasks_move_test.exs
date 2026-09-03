defmodule BarkparkWeb.TasksMoveTest do
  @moduledoc """
  rail-l3 — HTTP envelope contract for `POST /v1/tasks/:doc_id/move`.

    * a move carries `rail_rev` (destination) + `from_rail_rev` (source), and
      BOTH differ from the pre-move digests (the membership flipped);
    * a move to root omits `rail_rev`; a move OFF root omits `from_rail_rev`;
    * `new_parent_id` that resolves to no task → 409 invalid_parent;
    * a self / descendant move → 409 cycle;
    * a no-op move (already that parent) → 200 with the doc unchanged;
    * bare-id resolution (subject + new parent) works.
  """

  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content, Tasks, TenancyFixtures}

  @token "barkpark-test-move-token"
  @dataset "production"

  setup do
    {:ok, _} = Auth.create_token(@token, "test-move", "test", ["read", "write", "admin"])
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    %{scope: scope}
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp mk_task!(doc_id, scope, content_extra \\ %{}) do
    content = Map.merge(%{"kind" => "task", "lifecycle_status" => "open"}, content_extra)

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
  end

  defp move(conn, doc_id, body) do
    conn
    |> authed()
    |> post("/v1/tasks/#{doc_id}/move", Jason.encode!(body))
    |> json_response(200)
  end

  describe "move envelope: rail_rev + from_rail_rev" do
    test "carries both digests, and both differ from the pre-move digests",
         %{conn: conn, scope: scope} do
      src = uniq("srcEpic")
      dst = uniq("dstEpic")
      _dstp = mk_task!(dst, scope)
      task = mk_task!(uniq("mv"), scope, %{"parent_id" => src})

      pre_src = Tasks.rail_rev(src, scope)
      pre_dst = Tasks.rail_rev(dst, scope)

      payload = move(conn, task.doc_id, %{new_parent_id: dst})

      assert payload["ok"] == true
      assert payload["doc"]["parent_id"] == dst
      # destination rail = new parent; source rail = old parent.
      assert is_binary(payload["rail_rev"])
      assert is_binary(payload["from_rail_rev"])
      # Membership flipped on BOTH rails → both digests moved.
      assert payload["rail_rev"] != pre_dst
      assert payload["from_rail_rev"] != pre_src
    end

    test "move to root omits rail_rev; keeps from_rail_rev", %{conn: conn, scope: scope} do
      src = uniq("srcEpic")
      task = mk_task!(uniq("mvroot"), scope, %{"parent_id" => src})

      payload = move(conn, task.doc_id, %{new_parent_id: nil})

      assert payload["ok"] == true
      refute Map.has_key?(payload, "rail_rev")
      assert is_binary(payload["from_rail_rev"])
    end

    test "move OFF root omits from_rail_rev; keeps rail_rev", %{conn: conn, scope: scope} do
      dst = uniq("dstEpic")
      _dstp = mk_task!(dst, scope)
      task = mk_task!(uniq("mvfromroot"), scope, %{})

      payload = move(conn, task.doc_id, %{new_parent_id: dst})

      assert payload["ok"] == true
      assert is_binary(payload["rail_rev"])
      refute Map.has_key?(payload, "from_rail_rev")
    end
  end

  describe "move guards" do
    test "new_parent_id that resolves to no task → 409 invalid_parent", %{
      conn: conn,
      scope: scope
    } do
      task = mk_task!(uniq("mvbad"), scope, %{})

      resp =
        conn
        |> authed()
        |> post(
          "/v1/tasks/#{task.doc_id}/move",
          Jason.encode!(%{new_parent_id: "no-such-parent"})
        )

      assert resp.status == 409
      assert Jason.decode!(resp.resp_body)["reason"] == "invalid_parent"
    end

    test "moving a task under its own descendant → 409 cycle", %{conn: conn, scope: scope} do
      root = mk_task!(uniq("root"), scope, %{})
      child = mk_task!(uniq("child"), scope, %{"parent_id" => root.doc_id})

      resp =
        conn
        |> authed()
        |> post("/v1/tasks/#{root.doc_id}/move", Jason.encode!(%{new_parent_id: child.doc_id}))

      assert resp.status == 409
      assert Jason.decode!(resp.resp_body)["reason"] == "cycle"
    end

    test "no-op move (already that parent) → 200 unchanged", %{conn: conn, scope: scope} do
      parent = uniq("epic")
      _pp = mk_task!(parent, scope)
      task = mk_task!(uniq("noop"), scope, %{"parent_id" => parent})

      payload = move(conn, task.doc_id, %{new_parent_id: parent})
      assert payload["ok"] == true
      assert payload["doc"]["parent_id"] == parent
      assert payload["doc"]["rev"] == task.rev
    end

    test "bare-id resolution: subject + new parent resolve without drafts. prefix",
         %{conn: conn, scope: scope} do
      dst = uniq("dstEpic")
      _dstp = mk_task!(dst, scope)
      task = mk_task!(uniq("mvbare"), scope, %{})

      payload = move(conn, task.doc_id, %{new_parent_id: dst})
      assert payload["ok"] == true
      assert payload["doc"]["parent_id"] == dst
    end
  end
end
