defmodule BarkparkWeb.TasksControllerCloseLandedShapeTest do
  @moduledoc """
  task-4ab4a5b58bce97a6, criterion 1 — AT THE CLOSE DOOR.

  `POST /v1/tasks/:doc_id/close` used to pipe `params["landed"]` into the close
  opts RAW (`Params.put_opt(:landed, params["landed"])`), the ONE opt on that
  pipeline with no `Params.parse_*`. `Tasks.Internal.merge_landed/2` then
  normalised the keys it recognised and dropped everything else — so a caller
  posting `{"files": "api/lib/x.ex"}` (a string, not a list) or `{"pr": 17070}`
  (the singular of a key the union has never merged) got a 200 asserting a
  landing the ledger does not hold. The `/landed` route has refused exactly
  those shapes since task-726717ba693eb424; close did not.

  The three things only the HTTP surface can say:

    1. a malformed digest is a NAMED 4xx — 422 `invalid_landed_digest` with
       `field: "landed"` — and NOTHING is written: the row is still claimable
       and still not done;
    2. an UNKNOWN key is named in the refusal, because "silently dropped" is
       how a `"pr"`-for-`"prs"` typo became a 2xx that recorded nothing;
    3. the CONTROL — a well-formed digest still closes 200 and is read back
       verbatim by a subsequent GET. Without this arm a refuse-everything
       parser would pass arms 1 and 2.

  MUTATION PROOF: neuter `Tasks.Landed.check_digest/1`'s error paths to
  `{:ok, nil}` and arms 1 and 2 red while arm 3 stays green.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document

  @token "barkpark-test-close-landed-shape"
  @dataset "production"

  setup do
    {:ok, _} = Auth.create_token(@token, "test-close-landed-shape", "test", ["read", "write"])
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

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
  end

  # A claimed row: close needs a holder and an epoch, and the ONE met criterion
  # keeps the PDS-D291 close-artifact gate out of the measurement.
  defp claimed!(scope) do
    doc_id = uniq("close-landed")
    phase = uniq("phase-close-landed")

    {:ok, _doc} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => doc_id,
          "content" => %{
            "kind" => "task",
            "lifecycle_status" => "open",
            "parent_id" => phase,
            "acceptance_criteria" => [
              %{"criterion" => "built", "met" => true, "evidence" => "PR #17070"}
            ]
          }
        },
        @dataset,
        scope
      )

    %{doc_id: doc_id, phase: phase}
  end

  defp claim!(conn, %{phase: phase}) do
    payload =
      conn
      |> authed()
      |> post("/v1/tasks/claim", Jason.encode!(%{worker_id: "api-w13", phase_id: phase}))
      |> json_response(200)

    {payload["doc"]["doc_id"], payload["doc"]["claim"]["epoch"]}
  end

  defp close(conn, doc_id, body),
    do: conn |> authed() |> post("/v1/tasks/#{doc_id}/close", Jason.encode!(body))

  test "a `files` value that is not a list of strings is a 422 NAMING THE FIELD, and nothing closes",
       %{conn: conn, scope: scope} do
    task = claimed!(scope)
    {doc_id, epoch} = claim!(conn, task)

    body =
      conn
      |> close(doc_id, %{
        worker_id: "api-w13",
        observed_epoch: epoch,
        landed: %{"files" => "api/lib/barkpark/tasks/landed.ex"}
      })
      |> json_response(422)

    assert body["ok"] == false
    assert body["reason"] == "invalid_landed_digest"
    assert body["field"] == "landed"
    assert body["message"] =~ "files must be a LIST OF STRINGS"

    # The refusal is a refusal: the row did not close and holds no digest.
    row = Repo.get_by!(Document, doc_id: doc_id)
    assert row.content["lifecycle_status"] == "in_progress"
    refute Map.has_key?(row.content, "landed")
  end

  test "an UNKNOWN digest key is NAMED rather than silently dropped",
       %{conn: conn, scope: scope} do
    task = claimed!(scope)
    {doc_id, epoch} = claim!(conn, task)

    body =
      conn
      |> close(doc_id, %{
        worker_id: "api-w13",
        observed_epoch: epoch,
        # The measured typo: the singular of `prs`. `merge_landed/2` has never
        # merged this key, so the old door returned 200 and stored nothing.
        landed: %{"pr" => "17070"}
      })
      |> json_response(422)

    assert body["reason"] == "invalid_landed_digest"
    assert body["message"] =~ "SILENTLY DROPPED"
    assert body["message"] =~ ~s|"pr"|

    row = Repo.get_by!(Document, doc_id: doc_id)
    assert row.content["lifecycle_status"] == "in_progress"
  end

  test "CONTROL: a well-formed digest still closes 200 and is read back verbatim",
       %{conn: conn, scope: scope} do
    task = claimed!(scope)
    {doc_id, epoch} = claim!(conn, task)

    files = ["api/lib/barkpark/tasks/landed.ex", "api/lib/barkpark/tasks/close.ex"]

    body =
      conn
      |> close(doc_id, %{
        worker_id: "api-w13",
        observed_epoch: epoch,
        landed: %{"prs" => ["17070"], "commit" => "f7610ed6a", "files" => files}
      })
      |> json_response(200)

    assert body["ok"] == true
    assert body["doc"]["lifecycle_status"] == "done"

    read = conn |> authed() |> get("/v1/tasks/#{doc_id}") |> json_response(200)
    assert read["doc"]["content"]["landed"]["prs"] == ["17070"]
    assert read["doc"]["content"]["landed"]["files"] == files
  end

  test "CONTROL: a close with NO `landed` at all is untouched by the new parser",
       %{conn: conn, scope: scope} do
    task = claimed!(scope)
    {doc_id, epoch} = claim!(conn, task)

    body =
      conn
      |> close(doc_id, %{worker_id: "api-w13", observed_epoch: epoch})
      |> json_response(200)

    assert body["ok"] == true
    refute Map.has_key?(body["doc"]["content"] || %{}, "landed")
  end
end
