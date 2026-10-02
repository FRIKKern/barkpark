defmodule BarkparkWeb.TasksShowSealedChildCountTest do
  @moduledoc """
  task-e4f1d8e178509fc9 — THE SEAL-DROP PIN for `GET /v1/tasks/:doc_id`.

  `show/2` used to count children off the UNSEALED list
  (`child_count: length(children)`, and the same `length(children)` keyed into
  `doc.child_count`) while the `children:` array was rendered off
  `seal_docs(children, conn)`. Two parallel derivations from two different
  lists: they agree only because `seal_docs/2` happens to be a
  length-preserving `Enum.map` — an incidental property of an unrelated
  helper, not a stated invariant. The day a seal DROPS a doc, both counts
  would describe rows the caller never received (the shape PDS-D502 refuted).

  The fix seals ONCE (`sealed_children`) and derives the array and BOTH counts
  from that one list. This test is the mutation pin for it, and it reds in
  BOTH directions:

    * make `seal_docs/2` drop a doc on the PATCHED code → the array and both
      counts drop together to 1 and the absolute `== 2` assertion reds: a seal
      that swallows a child is no longer a silent wire fact.
    * REVERT the patch (count off `children`, render off `seal_docs(children)`)
      and drop a doc → the agreement assertions red: 2 reported, 1 delivered.

  Everything is asserted over the HTTP surface. Conns come from ConnCase (the
  controller-inline rate limiter keys per-test scope through it) — never a
  bare `build_conn/0`.
  """

  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content, Tasks, TenancyFixtures}

  @token "barkpark-test-sealed-child-count-token"
  @dataset "production"

  setup do
    {:ok, _} =
      Auth.create_token(@token, "test-sealed-child-count", "test", ["read", "write", "admin"])

    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]
    register_schemas!(scope)
    %{scope: scope}
  end

  defp register_schemas!(scope) do
    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end
  end

  defp mk_task!(doc_id, scope, content_extra \\ %{}) do
    content =
      Map.merge(
        %{
          "kind" => "task",
          "lifecycle_status" => "open",
          "acceptance_criteria" => [
            %{"criterion" => "the fixture is closeable", "met" => true}
          ]
        },
        content_extra
      )

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
  end

  test "show: every child_count is the length of the SEALED children the caller received",
       %{conn: conn, scope: scope} do
    root = mk_task!(uniq("seal-count-root"), scope)
    first = mk_task!(uniq("seal-count-child-1"), scope, %{"parent_id" => root.doc_id})
    second = mk_task!(uniq("seal-count-child-2"), scope, %{"parent_id" => root.doc_id})

    resp = conn |> authed() |> get("/v1/tasks/#{root.doc_id}")
    assert resp.status == 200

    payload = Jason.decode!(resp.resp_body)
    assert payload["ok"] == true

    delivered = payload["children"]
    delivered_ids = Enum.map(delivered, & &1["doc_id"])

    # The envelope's count describes the rows the caller actually received.
    assert payload["child_count"] == length(delivered),
           "top-level child_count (#{inspect(payload["child_count"])}) counts rows the " <>
             "caller never received: #{length(delivered)} children on the wire"

    # ...and so does the copy that rides INSIDE `doc`.
    assert payload["doc"]["child_count"] == length(delivered),
           "doc.child_count (#{inspect(payload["doc"]["child_count"])}) disagrees with the " <>
             "#{length(delivered)} children on the wire"

    # The absolute fact, asserted AFTER the agreements so each direction of the
    # bug prints its own FAIL line: BOTH children were created and BOTH must
    # arrive. This is the assertion that reds when `seal_docs/2` drops a doc.
    assert delivered_ids == [first.doc_id, second.doc_id],
           "the sealed rail lost a child: expected both children on the wire, got " <>
             inspect(delivered_ids)

    assert payload["child_count"] == 2
    assert payload["doc"]["child_count"] == 2
  end
end
