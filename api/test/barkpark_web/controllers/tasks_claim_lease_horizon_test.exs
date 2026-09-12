defmodule BarkparkWeb.TasksClaimLeaseHorizonTest do
  @moduledoc """
  task-f30dab8c54c605e6 — the claim lease HORIZON rides the READ payload.

  THE HOLE THIS CLOSES. `Params.claim_lease/1` has always told a caller how
  long its lease runs, but only on the claim/pulse RECEIPT. Every READ of a
  task carried `claim` with no horizon at all, so a consumer that wanted to
  grade a live claim had to invent a number. `internal/taskboard/theme.go`
  invented FIVE MINUTES and painted a claim RED there — while this server keeps
  the lease for `:task_lease_ttl_seconds`, default 2700, for another forty
  minutes. The client could not have read the truth off this envelope, so the
  fix has a server half: `claim.lease_seconds` (+ `claim.lease_expires_at`
  when `claim.ts_iso` parses), minted from the SAME single reader the sweeper's
  reap boundary comes from, `Barkpark.Tasks.QueueGate.lease_ttl_seconds/0`.

  Every arm below is one line of that contract, asserted through a REAL
  controller request against a REALLY claimed row — never against a
  hand-built map.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Tasks, TenancyFixtures}
  alias Barkpark.Tasks.QueueGate

  @token "barkpark-test-claim-lease-horizon-token"
  @dataset "production"

  setup do
    {:ok, _} =
      Auth.create_token(@token, "test-claim-lease-horizon", "test", ["read", "write", "admin"])

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

  # A row claimed through the real engine, so the horizon describes a LIVE lease.
  defp claimed!(scope) do
    phase_id = uniq("phase-lease-horizon")
    doc_id = uniq("lease-horizon")

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

    {:ok, claimed} = Tasks.claim("worker-lease-horizon", scope ++ [phase_id: phase_id, dataset: @dataset])
    claimed
  end

  defp bare(doc_id), do: String.replace_prefix(doc_id, "drafts.", "")

  defp show(conn, doc_id) do
    resp = conn |> authed() |> get("/v1/tasks/#{doc_id}")
    assert resp.status == 200
    Jason.decode!(resp.resp_body)
  end

  describe "GET /v1/tasks/:id — the claim carries its horizon" do
    test "claim.lease_seconds IS the server's configured TTL, not a client guess",
         %{conn: conn, scope: scope} do
      task = claimed!(scope)
      claim = show(conn, bare(task.doc_id))["doc"]["claim"]

      # The NUMBER is read from the one canonical reader, not retyped here: a
      # literal 2700 would pass on a box whose config says something else, which
      # is the whole class of bug this row is about.
      assert claim["lease_seconds"] == QueueGate.lease_ttl_seconds()

      # ...and it is the 45-minute-scale number, not the 5-minute one the Go
      # board had hardcoded. This arm is what reds if someone "simplifies" the
      # helper back onto a wrong constant.
      assert claim["lease_seconds"] > 300,
             "lease_seconds #{claim["lease_seconds"]} is at or under the false 5-minute horizon " <>
               "task-f30dab8c54c605e6 was filed for"
    end

    test "claim.lease_expires_at is ts_iso + the TTL, derived not guessed",
         %{conn: conn, scope: scope} do
      task = claimed!(scope)
      claim = show(conn, bare(task.doc_id))["doc"]["claim"]

      {:ok, granted, _} = DateTime.from_iso8601(claim["ts_iso"])
      {:ok, expires, _} = DateTime.from_iso8601(claim["lease_expires_at"])

      assert DateTime.diff(expires, granted, :second) == QueueGate.lease_ttl_seconds()

      # It agrees, to the second, with the RECEIPT surface that already existed
      # (Params.claim_lease/1) — one lease, one horizon, two places to read it.
      receipt = BarkparkWeb.TasksController.Params.claim_lease(Barkpark.Repo.get!(Barkpark.Content.Document, task.id))
      assert receipt.expires_at == claim["lease_expires_at"]
      assert receipt.seconds == claim["lease_seconds"]
    end

    test "the addition is ADDITIVE — every pre-existing claim key survives",
         %{conn: conn, scope: scope} do
      task = claimed!(scope)
      stored = task.content["claim"]
      claim = show(conn, bare(task.doc_id))["doc"]["claim"]

      for {k, v} <- stored do
        assert claim[k] == v, "the read payload changed claim.#{k}: #{inspect(claim[k])} != #{inspect(v)}"
      end

      assert MapSet.new(Map.keys(claim)) |> MapSet.difference(MapSet.new(Map.keys(stored))) ==
               MapSet.new(["lease_seconds", "lease_expires_at"])
    end
  end

  describe "GET /v1/tasks — the LIST the board actually consumes" do
    test "the index's claim map carries the same horizon as show",
         %{conn: conn, scope: scope} do
      task = claimed!(scope)
      id = bare(task.doc_id)

      resp = conn |> authed() |> get("/v1/tasks?limit=1000")
      assert resp.status == 200

      doc =
        Jason.decode!(resp.resp_body)["docs"]
        |> Enum.find(&(String.replace_prefix(&1["doc_id"], "drafts.", "") == id))

      refute is_nil(doc), "the claimed row is absent from GET /v1/tasks"
      assert doc["claim"]["lease_seconds"] == QueueGate.lease_ttl_seconds()
      assert doc["claim"]["lease_expires_at"] == show(conn, id)["doc"]["claim"]["lease_expires_at"]
    end

    test "a SWEPT claim gets NO horizon — a reaped residue has no lease left",
         %{conn: conn, scope: scope} do
      task = claimed!(scope)
      %{swept: swept} = Barkpark.Tasks.TtlSweeper.sweep(0)
      assert swept >= 1, "the sweep reaped nothing; this arm has no swept residue to read"

      claim = show(conn, bare(task.doc_id))["doc"]["claim"]

      refute is_nil(claim), "the sweep removed the claim map entirely; this arm assumes a residue"
      assert is_nil(claim["worker"]), "the sweep did not null the worker; the precondition is wrong"
      refute Map.has_key?(claim, "lease_seconds"),
             "a swept residue advertised lease_seconds — the opposite lie from the one this row fixes"
      refute Map.has_key?(claim, "lease_expires_at")
    end

    test "an UNCLAIMED row still carries claim: null — no horizon is invented",
         %{conn: conn, scope: scope} do
      doc_id = uniq("unclaimed-lease-horizon")

      {:ok, _} =
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

      assert is_nil(show(conn, doc_id)["doc"]["claim"])
    end
  end
end
