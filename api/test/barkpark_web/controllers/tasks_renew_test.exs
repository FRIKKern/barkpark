defmodule BarkparkWeb.TasksRenewTest do
  @moduledoc """
  task-16e56d05b809dd39 — HTTP contract tests for `POST /v1/tasks/:doc_id/renew`,
  the NON-HOLDER lease extension a CI job calls so a claim does not lapse
  underneath its own open pull request.

  **These tests exist to pin a FROZEN WIRE CONTRACT.** The CI half
  (`gates/lease-renew-workflow`) is being written against the exact shape
  `Barkpark.Tasks.Renew`'s moduledoc states, and a contract two lanes code
  against must be enforced by something other than a comment. Every arm below
  is one line of that contract:

    * body `{"pr": n, "state": "open"|"closed"|"merged", "reason": "..."}`
    * `pr` REQUIRED (400), `state` defaults to `"open"`, bad `state` is a 400
    * the clear is the SAME POST with `state` closed/merged, PR-MATCHED
    * 409 wire tokens: `not_claimed`, `extension_cap_reached`, `stale_claim`

  The receipt arm reads the STORED row back with `Repo.get!` and checks the
  wire `ok: true` only insofar as the store agrees with it — the census's
  `end_to_end` basis is earned here, not asserted (a receipt that agrees only
  with itself is the defect the PDS epic keeps filing).
  """

  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Auth, Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document

  @token "barkpark-test-tasks-renew-token"
  @dataset "production"

  setup do
    {:ok, _} = Auth.create_token(@token, "test-tasks-renew", "test", ["read", "write", "admin"])

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

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
  end

  # A row claimed through the real engine, so the renew meets a LIVE lease —
  # the one precondition the verb does not relax.
  defp claimed!(scope) do
    phase_id = uniq("phase-renew")
    doc_id = uniq("renew")

    {:ok, _} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => doc_id,
          "content" => %{
            "kind" => "task",
            "lifecycle_status" => "open",
            "parent_id" => phase_id
          }
        },
        @dataset,
        scope
      )

    {:ok, claimed} = Tasks.claim("worker-A", scope ++ [phase_id: phase_id, dataset: @dataset])
    claimed
  end

  defp renew(conn, doc_id, body) do
    conn |> authed() |> post("/v1/tasks/#{doc_id}/renew", Jason.encode!(body))
  end

  defp bare(doc_id), do: String.replace_prefix(doc_id, "drafts.", "")

  describe "the receipt agrees with the store (census basis: end_to_end)" do
    test "200 ok:true, and the STORED row carries the window the receipt reports",
         %{conn: conn, scope: scope} do
      task = claimed!(scope)
      claim_before = task.content["claim"]

      resp = renew(conn, bare(task.doc_id), %{pr: 15_234})
      assert resp.status == 200

      payload = Jason.decode!(resp.resp_body)
      assert payload["ok"] == true

      wire = payload["doc"]["claim"]["lease_extension"]
      assert wire["pr"] == 15_234
      assert wire["reason"] == "open_pr"
      assert wire["renewals"] == 1

      # THE RECEIPT IS THE STORED ROW, not a reconstruction of intent: read the
      # row back and require the wire to match it field for field. A receipt
      # that agrees only with itself proves nothing.
      stored = Repo.get!(Document, task.id).content["claim"]
      assert stored["lease_extension"]["until"] == wire["until"]
      assert stored["lease_extension"]["pr"] == 15_234
      assert stored["lease_extension"]["renewals"] == 1

      # And the CAS surface a lead depends on is untouched, in the store too.
      assert stored["epoch"] == claim_before["epoch"]
      assert stored["worker"] == claim_before["worker"]
      assert stored["ts_iso"] == claim_before["ts_iso"]
    end
  end

  describe "the frozen body contract" do
    test "pr is REQUIRED — a renew with no pr is a 400, and writes nothing",
         %{conn: conn, scope: scope} do
      task = claimed!(scope)

      resp = renew(conn, bare(task.doc_id), %{state: "open"})
      assert resp.status == 400

      assert is_nil(Repo.get!(Document, task.id).content["claim"]["lease_extension"])
    end

    test "a non-positive pr is a 400, not a silent default", %{conn: conn, scope: scope} do
      task = claimed!(scope)
      assert renew(conn, bare(task.doc_id), %{pr: 0}).status == 400
      assert renew(conn, bare(task.doc_id), %{pr: -3}).status == 400
      assert is_nil(Repo.get!(Document, task.id).content["claim"]["lease_extension"])
    end

    test "state DEFAULTS to open — omitting it renews", %{conn: conn, scope: scope} do
      task = claimed!(scope)

      resp = renew(conn, bare(task.doc_id), %{pr: 15_234})
      assert resp.status == 200

      stored = Repo.get!(Document, task.id).content["claim"]["lease_extension"]
      refute is_nil(stored["until"])
    end

    test "an unknown state is a 400 — the vocabulary is closed", %{conn: conn, scope: scope} do
      task = claimed!(scope)
      assert renew(conn, bare(task.doc_id), %{pr: 15_234, state: "draft"}).status == 400
      assert is_nil(Repo.get!(Document, task.id).content["claim"]["lease_extension"])
    end

    test "reason rides through and defaults to open_pr", %{conn: conn, scope: scope} do
      task = claimed!(scope)

      resp = renew(conn, bare(task.doc_id), %{pr: 15_234, reason: "queued behind elixir.yml"})
      assert resp.status == 200

      stored = Repo.get!(Document, task.id).content["claim"]["lease_extension"]
      assert stored["reason"] == "queued behind elixir.yml"
    end

    test "an unknown task is a 404, never a 409", %{conn: conn} do
      assert renew(conn, "no-such-task-#{System.unique_integer([:positive])}", %{pr: 1}).status ==
               404
    end
  end

  describe "the clear is the SAME POST, and it is pr-matched" do
    test "state=merged clears the extension this pr bought", %{conn: conn, scope: scope} do
      task = claimed!(scope)
      assert renew(conn, bare(task.doc_id), %{pr: 15_234}).status == 200

      resp = renew(conn, bare(task.doc_id), %{pr: 15_234, state: "merged"})
      assert resp.status == 200
      assert Jason.decode!(resp.resp_body)["ok"] == true

      assert is_nil(Repo.get!(Document, task.id).content["claim"]["lease_extension"])
    end

    test "state=closed by a DIFFERENT pr leaves the grace standing",
         %{conn: conn, scope: scope} do
      task = claimed!(scope)
      assert renew(conn, bare(task.doc_id), %{pr: 15_234}).status == 200

      resp = renew(conn, bare(task.doc_id), %{pr: 999, state: "closed"})
      assert resp.status == 200

      stored = Repo.get!(Document, task.id).content["claim"]["lease_extension"]
      assert stored["pr"] == 15_234
    end
  end

  describe "the 409 wire tokens" do
    test "not_claimed — a row with no live claim is refused by name",
         %{conn: conn, scope: scope} do
      # Never claimed: lifecycle_status is "open" with no claim.worker.
      doc_id = uniq("renew-unclaimed")

      {:ok, task} =
        Content.create_document(
          "task",
          %{
            "doc_id" => doc_id,
            "title" => doc_id,
            "content" => %{"kind" => "task", "lifecycle_status" => "open"}
          },
          @dataset,
          scope
        )

      resp = renew(conn, bare(task.doc_id), %{pr: 15_234})
      assert resp.status == 409

      payload = Jason.decode!(resp.resp_body)
      assert payload["ok"] == false
      assert payload["reason"] == "not_claimed"

      assert is_nil(Repo.get!(Document, task.id).content["claim"])
    end

    test "extension_cap_reached — past the cap the verb refuses by name",
         %{conn: conn, scope: scope} do
      task = claimed!(scope)
      assert renew(conn, bare(task.doc_id), %{pr: 15_234}).status == 200

      # Backdate the anchor past the cap — the row an abandoned PR would leave
      # after a day of dutiful renewals.
      fresh = Repo.get!(Document, task.id)
      claim = fresh.content["claim"]
      old = DateTime.utc_now() |> DateTime.add(-(Tasks.Renew.max_seconds() + 60), :second)

      aged =
        claim["lease_extension"]
        |> Map.put("first_granted_at", DateTime.to_iso8601(old))
        |> Map.put("until", DateTime.to_iso8601(DateTime.add(old, 60, :second)))

      {1, _} =
        from(d in Document, where: d.id == ^task.id)
        |> Repo.update_all(
          set: [
            content: Map.put(fresh.content, "claim", Map.put(claim, "lease_extension", aged))
          ]
        )

      resp = renew(conn, bare(task.doc_id), %{pr: 15_234})
      assert resp.status == 409
      assert Jason.decode!(resp.resp_body)["reason"] == "extension_cap_reached"

      # The refusal wrote nothing: the spent window is still the stored one.
      stored = Repo.get!(Document, task.id).content["claim"]["lease_extension"]
      assert stored["first_granted_at"] == DateTime.to_iso8601(old)
    end
  end
end
