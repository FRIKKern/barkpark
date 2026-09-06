defmodule Barkpark.Plugins.TasksZeroCriteriaAdvisoryTest do
  @moduledoc """
  THE ZERO-CRITERIA BIRTH ADVISORY MUST REACH THE AUTHOR, NOT ONLY THE JOURNAL
  (task-62d245a1ee5247f6).

  `warn_if_create_zero/1` (plugins/tasks.ex) fired a `Logger.warning` and
  nothing else. Its only reader was the server journal, which no task author
  ever sees — so in one week on this lane 163 of 975 new rows (16.7%) were born
  with an empty `acceptance_criteria` list, 63 of which CLOSED as done. An
  empty list reads to every completeness audit as fully proven, because 0-of-0
  is vacuously complete.

  The sibling six clauses below, `warn_unflagged_merge_gates/1`, already
  learned this and rides `Content.Warnings.put/3` — the advisory channel that
  lands in the mutate SUCCESS envelope's `warnings` array, which the bp CLI
  prints to stderr (`emitWarnings`, pinned by
  `internal/cli/cli_test.go:TestRenderSuccessWarnings`) and Studio folds into
  its save flash.

  THIS FILE MEASURES THE WIRE, not the private function. A hook-level drain
  would stay green if the controller ever stopped draining the accumulator into
  the body — and the accumulator, not the gate, is where the fix lives. So the
  create goes through the real `POST /v1/data/mutate` door and the assertion
  reads the decoded response body.

  Three directions, all required. It FIRES on a birth with no criteria; it is
  SILENT on a birth that carries one (an advisory that never shuts up is the
  same defect as one that never fires); it is SILENT on an UPDATE of a row that
  already has none, preserving `warn_if_create_zero(_prev) -> :ok`. And it is
  never a gate: the save lands.
  """
  use BarkparkWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Repo

  @dataset "test"
  @code "zero_acceptance_criteria"

  setup do
    Barkpark.Auth.create_token("barkpark-dev-token", "dev", @dataset, ["read", "write", "admin"])
    register_task_schemas!()
    :ok
  end

  describe "the birth advisory rides the mutate SUCCESS envelope" do
    test "a create with ZERO acceptance_criteria puts the advisory ON THE RESPONSE", %{conn: conn} do
      resp = mutate(conn, [task_create("zc-advisory-empty", [])])

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)

      # A plain filter rather than a pattern-match assert: other emitters may
      # queue their own advisories on the same create, and this row owns
      # exactly one code.
      assert [warning] = Enum.filter(body["warnings"] || [], &(&1["code"] == @code)),
             "the zero-criteria create carried no #{@code} advisory: #{inspect(body["warnings"])}"

      assert warning["severity"] == "warning"
      assert warning["message"] =~ "zero acceptance_criteria"
      assert warning["message"] =~ "save proceeds"
    end

    test "a create with the acceptance_criteria KEY ABSENT is advised too", %{conn: conn} do
      resp = mutate(conn, [task_create("zc-advisory-absent", :absent)])

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)

      assert [_] = Enum.filter(body["warnings"] || [], &(&1["code"] == @code))
    end

    # THE DISCRIMINATION HALF. Without this the advisory could be unconditional
    # and every assertion above would still pass.
    test "a create WITH one criterion draws no advisory", %{conn: conn} do
      resp =
        mutate(conn, [
          task_create("zc-advisory-present", [
            %{"criterion" => "the suite is green", "met" => false}
          ])
        ])

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)

      assert Enum.filter(body["warnings"] || [], &(&1["code"] == @code)) == []
    end
  end

  describe "it is a BIRTH advisory — an update of an already-empty row is silent" do
    test "the second write of the same zero-criteria row carries no advisory", %{conn: conn} do
      first = mutate(conn, [task_create("zc-advisory-update", [])])
      assert first.status == 200

      # Precondition, asserted rather than assumed: the row this update is
      # about IS on disk, so `prev_doc` is non-nil on the second write. Without
      # it the silence below would pass vacuously for a second BIRTH.
      assert draft_row("drafts.zc-advisory-update"),
             "the fixture row must exist before the update, or this proves nothing"

      second =
        mutate(conn, [
          %{
            "createOrReplace" => %{
              "_id" => "zc-advisory-update",
              "_type" => "task",
              "title" => "Zero-criteria advisory fixture zc-advisory-update (edited)",
              "content" => task_content([])
            }
          }
        ])

      assert second.status == 200
      body = Jason.decode!(second.resp_body)

      assert Enum.filter(body["warnings"] || [], &(&1["code"] == @code)) == [],
             "the advisory fired on an UPDATE — warn_if_create_zero(_prev) must stay :ok"
    end
  end

  describe "it is ADVISORY, never a gate — this row changes the CHANNEL only" do
    test "the zero-criteria create still returns 2xx and the document exists", %{conn: conn} do
      resp = mutate(conn, [task_create("zc-advisory-proceeds", [])])

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert [%{"id" => "drafts.zc-advisory-proceeds"}] = body["results"]

      # Read from the table, not from the response's own echo: the point is
      # that the write LANDED, which only the row can answer.
      assert draft_row("drafts.zc-advisory-proceeds")
    end
  end

  defp mutate(conn, mutations) do
    conn
    |> put_req_header("authorization", "Bearer barkpark-dev-token")
    |> put_req_header("content-type", "application/json")
    |> post("/v1/data/mutate/#{@dataset}", Jason.encode!(%{"mutations" => mutations}))
  end

  defp task_create(id, criteria) do
    %{
      "create" => %{
        "_id" => id,
        "_type" => "task",
        "title" => "Zero-criteria advisory fixture #{id}",
        "content" => task_content(criteria)
      }
    }
  end

  defp task_content(criteria) do
    base = %{"kind" => "task", "lifecycle_status" => "open", "priority" => 2}

    case criteria do
      :absent -> base
      list -> Map.put(base, "acceptance_criteria", list)
    end
  end

  defp draft_row(doc_id) do
    Repo.one(
      from(d in Document,
        where: d.doc_id == ^doc_id and d.type == "task" and d.dataset == ^@dataset,
        select: d.doc_id
      )
    )
  end

  defp register_task_schemas! do
    for schema_def <- Barkpark.Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset)
    end

    :ok
  end
end
