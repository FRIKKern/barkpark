defmodule BarkparkWeb.TasksControllerLandedFilesTest do
  @moduledoc """
  task-726717ba693eb424, AT THE DOOR — `POST /v1/tasks/:doc_id/landed`.

  The unit arms live in `Barkpark.Tasks.LandedFilesTest`; these are the three
  things only the HTTP surface can say:

    1. a `files` list POSTed on the wire is STORED and comes back on the row a
       subsequent `GET /v1/tasks/:doc_id` serves — the round trip the defect
       report is written against, not the internal write;
    2. a `files` value that is not a list of strings is a 4xx NAMING THE FIELD,
       which is the whole complaint: the old door returned 2xx and dropped it;
    3. a `--criterion` flip SAYS what the overlap guard did — `overlap.checked`
       true with both sides, or false with the reason. A guard that silently
       does nothing on a fileless landing is indistinguishable from one that
       ran and passed, and the response is the only place that distinction can
       reach the caller.

  Mutation proof for the door: neuter `Landed.check_files/1`'s error clause to
  `{:ok, nil}` and arm 2 reds while arms 1 and 3 stay green; neuter
  `Landed.files_overlap/3` to `:ok` and the 409 test reds while the
  fileless-flip control stays green.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Tasks, TenancyFixtures}

  @token "barkpark-test-landed-files"
  @dataset "production"

  setup do
    {:ok, _} = Auth.create_token(@token, "test-landed-files", "test", ["read", "write"])
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

  defp task!(scope) do
    doc_id = uniq("landed-http")

    {:ok, doc} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => "landed drops files — api/lib/barkpark/tasks/landed.ex",
          "content" => %{
            "kind" => "task",
            "description" => "the write path is api/lib/barkpark/tasks/landed.ex",
            "acceptance_criteria" => [
              %{
                "criterion" => "MERGE-GATED: the PR merged to main",
                "merge_gate" => true,
                "met" => false,
                "evidence" => ""
              }
            ],
            "lifecycle_status" => "open"
          }
        },
        @dataset,
        scope
      )

    doc.doc_id
  end

  defp auth(conn), do: put_req_header(conn, "authorization", "Bearer " <> @token)

  defp post_landed(conn, doc_id, body),
    do: conn |> auth() |> post("/v1/tasks/#{doc_id}/landed", body)

  test "a files list POSTed on the wire is stored and READ BACK VERBATIM by GET",
       %{conn: conn, scope: scope} do
    doc_id = task!(scope)
    files = ["api/lib/barkpark/tasks/landed.ex", "api/test/barkpark/tasks/landed_test.exs"]

    body =
      conn
      |> post_landed(doc_id, %{"pr" => "17454", "commit" => "b2e2b80", "files" => files})
      |> json_response(200)

    assert body["ok"] == true

    read = conn |> auth() |> get("/v1/tasks/#{doc_id}") |> json_response(200)
    assert read["doc"]["content"]["landed"]["files"] == files
  end

  test "a files value that is not a list of strings is a 4xx NAMING THE FIELD",
       %{conn: conn, scope: scope} do
    doc_id = task!(scope)

    body =
      conn
      |> post_landed(doc_id, %{"pr" => "1", "note" => "merged", "files" => "api/lib/x.ex"})
      |> json_response(400)

    assert body["ok"] == false
    assert body["reason"] == "bad_request"
    assert body["message"] =~ "files"
    assert body["message"] =~ "LIST OF STRINGS"

    # AND NOTHING LANDED — the point of refusing is that the caller is not told
    # the paths were recorded when they were not.
    read = conn |> auth() |> get("/v1/tasks/#{doc_id}") |> json_response(200)
    assert is_nil(read["doc"]["content"]["landed"])
  end

  test "a flip with overlapping files succeeds and the response reports BOTH SIDES",
       %{conn: conn, scope: scope} do
    doc_id = task!(scope)

    body =
      conn
      |> post_landed(doc_id, %{
        "pr" => "17345",
        "note" => "merged to main as b2e2b80",
        "criterion" => 0,
        "files" => ["api/lib/barkpark/tasks/landed.ex"]
      })
      |> json_response(200)

    assert body["overlap"]["checked"] == true
    assert body["overlap"]["files"] == ["api/lib/barkpark/tasks/landed.ex"]
    assert "api/lib/barkpark/tasks/landed.ex" in body["overlap"]["row_paths"]

    read = conn |> auth() |> get("/v1/tasks/#{doc_id}") |> json_response(200)
    assert [%{"met" => true}] = read["doc"]["content"]["acceptance_criteria"]
  end

  test "a flip whose files overlap nothing the row names is 409 landing_files_outside_row",
       %{conn: conn, scope: scope} do
    doc_id = task!(scope)

    body =
      conn
      |> post_landed(doc_id, %{
        "pr" => "17345",
        "note" => "merged to main",
        "criterion" => 0,
        "files" => ["cloud/lib/barkpark_cloud/oauth.ex"]
      })
      |> json_response(409)

    assert body["reason"] == "landing_files_outside_row"
    assert body["message"] =~ doc_id
    assert body["message"] =~ "17345"
    assert body["message"] =~ "cloud/lib/barkpark_cloud/oauth.ex"
    assert body["message"] =~ "api/lib/barkpark/tasks/landed.ex"

    read = conn |> auth() |> get("/v1/tasks/#{doc_id}") |> json_response(200)
    assert [%{"met" => false}] = read["doc"]["content"]["acceptance_criteria"]
    assert is_nil(read["doc"]["content"]["landed"])
  end

  test "POSITIVE CONTROL — a fileless flip still works, and the response SAYS no check ran",
       %{conn: conn, scope: scope} do
    doc_id = task!(scope)

    body =
      conn
      |> post_landed(doc_id, %{"pr" => "17345", "note" => "merged to main", "criterion" => 0})
      |> json_response(200)

    assert body["overlap"]["checked"] == false
    assert body["overlap"]["reason"] =~ "no files"

    read = conn |> auth() |> get("/v1/tasks/#{doc_id}") |> json_response(200)
    assert [%{"met" => true}] = read["doc"]["content"]["acceptance_criteria"]
  end

  test "no criterion → no overlap block at all; a landing sentence is not a flip",
       %{conn: conn, scope: scope} do
    doc_id = task!(scope)

    body =
      conn
      |> post_landed(doc_id, %{"pr" => "1", "files" => ["cloud/lib/x.ex"]})
      |> json_response(200)

    refute Map.has_key?(body, "overlap")
  end
end
