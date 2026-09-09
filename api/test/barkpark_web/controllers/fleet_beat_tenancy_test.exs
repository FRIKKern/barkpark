defmodule BarkparkWeb.FleetBeatTenancyTest do
  @moduledoc """
  `POST /v1/fleet/beat` resolves its listener row UNDER THE CALLER'S WORKSPACE
  — the regression test for task-8d083ef87c7d0022.

  ## The defect

  `Barkpark.Tasks.Fleet.canonical_row/2` resolved the row that decides
  register-vs-touch with `type == "listener" and dataset == ^dataset and
  doc_id in [logical_id, "drafts." <> logical_id]` and NO workspace clause.
  The logical id is derived from the caller-supplied `params["worker"]`
  (`"listener-" <> slug(worker)`) and the route is `auth: :token_root`, so a
  bearer in workspace A that beat as a worker name workspace B had already
  registered landed on B's row: `touch/3` CAS-merged A's `status`, `agent`,
  `scope`, `capacity` and `ttl_s` into it, and the 200 receipt handed A B's
  document back. `register/5` stamps the tenant scope on CREATE only, so the
  WRITE was scoped and the RESOLVE was not — the same read/write asymmetry
  `FleetRosterTenancyTest` pins for the roster, one function over.

  ## What this file proves

  Two REAL workspaces, two tokens bound to them, one shared worker NAME:

    * B's stored row is BYTE-unchanged after A's beat (content, rev and
      `updated_at` all compared) — A neither wrote to nor read out of it;
    * A's beat lands on A's OWN row (`registered: true`, A's own agent) or is
      an HONEST refusal — never a silent touch of B's;
    * each workspace's roster reports its OWN listener's declared state;
    * at the unit seam, `Fleet.beat/3` under a nil `:workspace_id` refuses
      outright (`:unscoped_beat`) rather than falling through to a create
      whose own prev-doc lookup reads nil as EVERY tenant.

  The non-vacuity guard throughout: B's own second beat MUST still touch B's
  row (`registered: false`). Without it, "A did not touch B" would also be
  true of a resolve that had fail-closed for everyone.
  """

  use BarkparkWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Auth, Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document
  alias Barkpark.Tasks.Fleet

  @dataset "production"

  setup do
    n = System.unique_integer([:positive])

    ws_a = TenancyFixtures.create_workspace!("fleet-beat-a-#{n}")
    ws_b = TenancyFixtures.create_workspace!("fleet-beat-b-#{n}")
    project_a = TenancyFixtures.create_project!(ws_a, "fleet-beat-a-p-#{n}")
    project_b = TenancyFixtures.create_project!(ws_b, "fleet-beat-b-p-#{n}")

    scope_a = [workspace_id: ws_a.id, project_id: project_a.id]
    scope_b = [workspace_id: ws_b.id, project_id: project_b.id]

    for scope <- [scope_a, scope_b], do: register_task_schemas!(scope)

    token_a = "fleet-beat-a-#{n}"
    token_b = "fleet-beat-b-#{n}"

    {:ok, _} = Auth.create_token(token_a, "fleet-beat-a-#{n}", @dataset, ~w(read write), ws_a.id)
    {:ok, _} = Auth.create_token(token_b, "fleet-beat-b-#{n}", @dataset, ~w(read write), ws_b.id)

    # ONE worker name, shared. The house convention (w1, lead-x, builder-1)
    # plus `slug/1`'s small alphabet makes this collision routine, not exotic.
    worker = "fleet-beat-shared-#{n}"

    %{
      ws_a: ws_a,
      ws_b: ws_b,
      scope_a: scope_a,
      scope_b: scope_b,
      token_a: token_a,
      token_b: token_b,
      worker: worker,
      n: n
    }
  end

  describe "POST /v1/fleet/beat — the cross-tenant write" do
    test "A's beat for a name B registered never reads, updates or returns B's row", ctx do
      # 1. B registers the name, with a state that is unmistakably B's.
      b_first =
        beat!(ctx.token_b, %{
          "worker" => ctx.worker,
          "agent" => "b-agent",
          "status" => "working",
          "scope" => "b-scope",
          "capacity" => "b-capacity",
          "ttl" => 300
        })

      assert b_first["registered"] == true
      before = row_in!(ctx.ws_b, ctx.worker)
      assert before.content["agent"] == "b-agent"

      # 2. A beats the SAME name with values that could not be mistaken for B's.
      a_conn =
        post_beat(ctx.token_a, %{
          "worker" => ctx.worker,
          "agent" => "a-agent",
          "status" => "blocked",
          "scope" => "a-scope",
          "capacity" => "a-capacity",
          "ttl" => 60
        })

      # 3. B's stored row is BYTE-unchanged: same content, same rev, same
      #    updated_at. This is the criterion, and it holds whichever of the
      #    two honest outcomes A's beat took.
      after_ = row_in!(ctx.ws_b, ctx.worker)

      assert Jason.encode!(after_.content) == Jason.encode!(before.content),
             """
             workspace A's beat rewrote workspace B's listener row.
             before: #{Jason.encode!(before.content)}
             after:  #{Jason.encode!(after_.content)}
             """

      assert after_.rev == before.rev, "A's beat advanced B's row rev — it CAS-wrote B's document"
      assert after_.updated_at == before.updated_at

      # 4. A's beat itself: its own row, or an honest named refusal. Never a
      #    200 carrying B's document.
      case a_conn.status do
        200 ->
          body = json_response(a_conn, 200)
          assert body["registered"] == true, "A's beat TOUCHED an existing row it does not own"
          assert body["doc"]["status"] == "blocked"

          # `agent` is NOT in the beat receipt's projection (`Fleet.receipt/2`
          # projects id/worker/status/last_seen/ttl_s only, pinned by
          # `FleetTest`), so the row read below is what proves whose state
          # landed — the receipt cannot.

          own = row_in!(ctx.ws_a, ctx.worker)
          assert own.content["agent"] == "a-agent"
          assert own.workspace_id == ctx.ws_a.id

        409 ->
          body = json_response(a_conn, 409)
          assert body["ok"] == false

          assert body["reason"] == "worker_name_taken",
                 "the refusal must NAME why: got #{inspect(body["reason"])}"

        other ->
          flunk("A's beat answered #{other}, neither its own row nor an honest refusal: " <>
                  a_conn.resp_body)
      end

      # 5. NON-VACUITY: B can still beat its OWN row. Without this, every
      #    assertion above would also pass on a resolve that fail-closed for
      #    everybody and turned every beat into a failed registration.
      b_second =
        beat!(ctx.token_b, %{"worker" => ctx.worker, "status" => "idle"})

      assert b_second["registered"] == false,
             "B's own second beat did not touch B's row — the resolve fail-closed for the OWNER too"

      assert b_second["doc"]["status"] == "idle"

      # And the stored row is still B's own, agent intact (the receipt does not
      # carry `agent` — see above).
      assert row_in!(ctx.ws_b, ctx.worker).content["agent"] == "b-agent"
    end

    test "each workspace's roster reports its OWN listener's declared state", ctx do
      _ = beat!(ctx.token_b, %{"worker" => ctx.worker, "agent" => "b-agent", "capacity" => "b-cap"})

      _ =
        post_beat(ctx.token_a, %{
          "worker" => ctx.worker,
          "agent" => "a-agent",
          "capacity" => "a-cap"
        })

      row_b = roster_row!(ctx.token_b, ctx.worker)

      assert row_b, "B's own listener vanished from B's roster — every assertion here is vacuous"

      assert row_b["agent"] == "b-agent",
             "workspace B's roster reports workspace A's declared agent — A's beat overwrote B"

      assert row_b["capacity"] == "b-cap"

      case roster_row!(ctx.token_a, ctx.worker) do
        nil ->
          # A was honestly refused the name; it must then own nothing.
          assert Repo.all(listener_query(ctx.worker))
                 |> Enum.filter(&(&1.workspace_id == ctx.ws_a.id)) == []

        row_a ->
          assert row_a["agent"] == "a-agent"
      end
    end
  end

  describe "Fleet.beat/3 at the unit seam" do
    test "a beat with no resolvable workspace cannot land on another tenant's row", ctx do
      {:ok, %{registered: true}} =
        Fleet.beat(%{"worker" => ctx.worker, "agent" => "b-agent"}, @dataset, ctx.scope_b)

      before = row_in!(ctx.ws_b, ctx.worker)

      # `workspace_id: nil` is the fail-closed arm (Content.Scope). Whatever it
      # does with A's beat, it must not be "merge into B's row" — and it must
      # not reach `Content.create_document/4` with those nil-scope opts either,
      # because that create's prev-doc lookup reads a nil workspace as EVERY
      # tenant and would update B's row from the write side instead.
      assert {:error, :unscoped_beat} =
               Fleet.beat(%{"worker" => ctx.worker, "agent" => "nil-scope"}, @dataset,
                 workspace_id: nil
               )

      after_ = row_in!(ctx.ws_b, ctx.worker)
      assert Jason.encode!(after_.content) == Jason.encode!(before.content)
      assert after_.rev == before.rev
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp authed(token) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
  end

  defp post_beat(token, params) do
    token |> authed() |> post("/v1/fleet/beat", Jason.encode!(params))
  end

  defp beat!(token, params) do
    conn = post_beat(token, params)
    assert conn.status == 200, "beat answered #{conn.status}: #{conn.resp_body}"
    json_response(conn, 200)
  end

  defp roster_row!(token, worker) do
    conn = token |> authed() |> get("/v1/fleet/roster")
    assert conn.status == 200, "roster answered #{conn.status}: #{conn.resp_body}"
    Enum.find(json_response(conn, 200)["documents"], &(&1["worker"] == worker))
  end

  defp listener_query(worker) do
    logical = "listener-" <> worker

    from(d in Document,
      where: d.type == "listener" and d.doc_id in ^[logical, "drafts." <> logical]
    )
  end

  # The stored row a workspace OWNS — read straight off the table, never
  # through the code under test.
  defp row_in!(workspace, worker) do
    worker
    |> listener_query()
    |> Repo.all()
    |> Enum.filter(&(&1.workspace_id == workspace.id))
    |> case do
      [row] ->
        row

      other ->
        flunk("expected exactly ONE listener row for #{worker} in #{workspace.id}, got #{length(other)}")
    end
  end

  defp register_task_schemas!(scope) do
    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end
  end
end
