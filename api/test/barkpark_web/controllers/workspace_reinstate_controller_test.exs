defmodule BarkparkWeb.WorkspaceReinstateControllerTest do
  @moduledoc """
  `task-7ab3d03b49606f83` — the operator verb that lifts a workspace suspension.

  THE DEFECT this suite pins: `Barkpark.Tenancy.Workers.PlaygroundReaper`
  suspends every expired `tier = "playground"` workspace once a minute, holds it
  write-blocked for a 24h grace window, then hard-DELETES it. Two places in the
  tree promised a rescue — `playground_reaper.ex` ("`bp go-live` can still
  `reinstate/1` it") and `Barkpark.Content.Errors` ("no writes are accepted until
  an operator reinstates it") — and `Quota.reinstate/1` had ZERO callers in
  `lib/`. The only exit from the state was `iex` or SQL.

  THE RULING (orchestrator, binding), verbatim:

  > OPTION (a) — instance-operator only. The reinstate route rides the admin
  > tier: `pipe_through([:api, :require_admin, :require_platform_operator])`,
  > exactly like the `/v1/status/incidents` and `/v1/admin/*` groups in
  > api/lib/barkpark_web/router.ex (~line 2077 and 2145 on origin/main). NO
  > workspace-owner self-reinstate path. Reasoning: the playground expired BY
  > POLICY, and a self-service loop around a TTL lets the subject of a limit
  > lift it, which is not a permit widening — it is removing the limit. The
  > smallest permit that fixes the actual defect (a suspended workspace being
  > unrescuable inside its own grace window).

  So the authorisation is pinned in BOTH directions, which is the difference
  between proving a rule and proving half of one:

    * POSITIVE — an operator (a bearer with the `admin` bit whose token id is on
      `BARKPARK_OPERATOR_TOKEN_IDS`, i.e. one that passes
      `BarkparkWeb.Plugs.RequirePlatformOperator`) reinstates: 200, the flag is
      false in the DB, and the mutate seam admits writes again.
    * NEGATIVE — the WORKSPACE'S OWN admin, seated in that workspace by
      `Auth.create_token/5` and carrying the same `admin` bit but NOT on the
      allowlist, is refused 403 `required: "platform_operator"` — and the
      workspace is STILL suspended afterwards, so the refusal is a real halt and
      not a 403 emitted after the write.

  Both arms run with the allowlist ARMED. The UNSET arm (legacy: the `admin` bit
  alone suffices) is asserted too, because a one-sided test cannot tell "the gate
  works" from "the route is broken".

  ## The re-suspend defect the route had to close as well

  `PlaygroundReaper.run_suspend_stage/1` selects on
  `tier = 'playground' AND expires_at < now() AND suspended = false`. A bare
  `Quota.reinstate/1` clears `suspended` and leaves `expires_at` in the past —
  so the reaper's next tick (once a minute) re-suspends the workspace and the
  rescue lasts under 60 seconds. That is a real defect, not a hypothetical: the
  "the reaper does not immediately re-suspend" test below RUNS
  `run_suspend_stage/1` against the reinstated row and is RED against a route
  that only calls `reinstate/1`. The route therefore also pushes an
  already-elapsed playground TTL forward by the 48h mint TTL.

  async: false — the operator allowlist is Application env, i.e. node-global.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Quota
  alias Barkpark.Tenancy.Workers.PlaygroundReaper
  alias Barkpark.Tenancy.Workspace
  alias BarkparkWeb.Plugs.RequireWithinQuota

  @dataset "production"

  # The reason PlaygroundReaper stamps (playground_reaper.ex, @suspend_reason).
  @reaper_reason "playground_expired"

  setup do
    # Slice 1-owned columns, provisioned idempotently exactly as
    # PlaygroundReaperTest does — a no-op wherever the migration has landed.
    Repo.query!("ALTER TABLE workspaces ADD COLUMN IF NOT EXISTS tier text")
    Repo.query!("ALTER TABLE workspaces ADD COLUMN IF NOT EXISTS expires_at timestamptz")

    # Deterministic baseline: pin BOTH allowlist keys to UNSET and restore, so a
    # box with BARKPARK_OPERATOR_EMAILS exported cannot invert an arm.
    put_allowlist([], [])

    ws = playground!(hours_ago(1))

    # THE OPERATOR: admin bit + token id on the allowlist when armed.
    raw_op = uniq("op")
    {:ok, tok_op} = admin_token(raw_op, uniq("lbl-op"), ws.id)

    # THE WORKSPACE'S OWN ADMIN: same admin bit, seated in THIS workspace by
    # Auth.create_token/5 (which writes the membership row), never on the
    # allowlist. The principal the ruling refuses.
    raw_owner = uniq("ws-admin")
    {:ok, _tok_owner} = admin_token(raw_owner, uniq("lbl-ws-admin"), ws.id)

    %{ws: ws, operator: raw_op, operator_token: tok_op, ws_admin: raw_owner}
  end

  # ── helpers ────────────────────────────────────────────────────────────

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp admin_token(raw, label, ws_id),
    do: Auth.create_token(raw, label, @dataset, ["read", "write", "admin"], ws_id)

  defp as(bearer) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{bearer}")
    |> put_req_header("content-type", "application/json")
  end

  defp put_allowlist(emails, ids) do
    prev_emails = Application.get_env(:barkpark, :operator_emails, [])
    prev_ids = Application.get_env(:barkpark, :operator_token_ids, [])

    Application.put_env(:barkpark, :operator_emails, emails)
    Application.put_env(:barkpark, :operator_token_ids, ids)

    on_exit(fn ->
      Application.put_env(:barkpark, :operator_emails, prev_emails)
      Application.put_env(:barkpark, :operator_token_ids, prev_ids)
    end)

    :ok
  end

  defp hours_ago(n), do: DateTime.add(DateTime.utc_now(), -n, :hour)

  defp playground!(expires_at) do
    slug = uniq("pg")

    {:ok, ws} =
      Tenancy.create_workspace(%{
        slug: slug,
        name: slug,
        tier: "playground",
        expires_at: expires_at
      })

    ws
  end

  # Suspend EXACTLY as PlaygroundReaper.run_suspend_stage/1 does, then age
  # `suspended_at` so the row sits INSIDE (not at the start of) the 24h grace.
  defp reaper_suspend!(%Workspace{} = ws, grace_hours_elapsed) do
    {:ok, suspended} = Quota.suspend(ws, @reaper_reason)

    Repo.query!("UPDATE workspaces SET suspended_at = $1 WHERE id = $2", [
      hours_ago(grace_hours_elapsed),
      Ecto.UUID.dump!(suspended.id)
    ])

    reload(ws)
  end

  defp reload(%Workspace{id: id}), do: Repo.get(Workspace, id)

  defp reinstate(bearer, slug),
    do: post(as(bearer), "/v1/admin/workspaces/#{slug}/reinstate", "{}")

  # The real mutate seam: RequireWithinQuota is the plug the two scoped mutate
  # pipelines run before RequireWritePermission. Halted => writes refused.
  defp seam(%Workspace{} = ws) do
    build_conn()
    |> Plug.Conn.assign(:current_workspace, ws)
    |> RequireWithinQuota.call(RequireWithinQuota.init([]))
  end

  # ── C1: the rescue itself ──────────────────────────────────────────────

  describe "POST /v1/admin/workspaces/:slug/reinstate — the rescue" do
    test "a reaper-suspended playground is reinstated and writes are admitted again", ctx do
      suspended = reaper_suspend!(ctx.ws, 1)

      # RED-before control: the seam refuses writes while suspended.
      assert seam(suspended).halted, "setup broken: a suspended workspace must refuse writes"
      assert suspended.suspended
      assert suspended.suspended_reason == @reaper_reason

      body = ctx.operator |> reinstate(ctx.ws.slug) |> json_response(200)

      assert body["slug"] == ctx.ws.slug
      refute body["suspended"]
      refute body["suspended_reason"]
      assert body["ttl_extended"], "an elapsed playground TTL must be re-armed"

      # Persisted, not just in-struct.
      back = reload(ctx.ws)
      refute back.suspended
      refute back.suspended_reason
      refute back.suspended_at

      # And the mutate seam admits again — the criterion's "writes succeed".
      refute seam(back).halted
    end

    test "an unknown slug is 404 not_found", ctx do
      body = ctx.operator |> reinstate("no-such-workspace-#{System.unique_integer([:positive])}")

      assert json_response(body, 404)["error"]["code"] == "not_found"
    end

    test "reinstating a workspace that was never suspended is a 200 no-op", ctx do
      body = ctx.operator |> reinstate(ctx.ws.slug) |> json_response(200)
      refute body["suspended"]
    end
  end

  # ── C2: inside the 24h grace window, and the reaper leaves it alone ────

  describe "the 24h grace window" do
    test "reinstatement works late in the grace window, BEFORE Stage 2 would delete", ctx do
      # 23h into the 24h grace: still rescuable, one hour from deletion.
      suspended = reaper_suspend!(ctx.ws, 23)
      assert suspended.suspended

      assert ctx.operator |> reinstate(ctx.ws.slug) |> json_response(200)

      back = reload(ctx.ws)
      refute back.suspended

      # Stage 2 selects on `suspended = true`, so the reinstated row is now out
      # of its reach even though its suspension WAS old enough.
      assert PlaygroundReaper.run_delete_stage(DateTime.utc_now()) >= 0
      assert reload(ctx.ws), "Stage 2 deleted a workspace the operator had just rescued"
    end

    test "the reaper does not immediately RE-SUSPEND a reinstated workspace", ctx do
      _suspended = reaper_suspend!(ctx.ws, 1)
      assert ctx.operator |> reinstate(ctx.ws.slug) |> json_response(200)

      # THE MUTATION TARGET. `run_suspend_stage/1` selects on
      # `tier = 'playground' AND expires_at < now() AND suspended = false`. If
      # reinstate only cleared `suspended`, this tick — the very next minute in
      # production — puts the workspace straight back where it was.
      _ = PlaygroundReaper.run_suspend_stage(DateTime.utc_now())

      back = reload(ctx.ws)

      refute back.suspended,
             "the reaper re-suspended a reinstated playground on its next tick: the rescue " <>
               "survives under 60s unless reinstate also moves the elapsed expires_at"

      assert DateTime.compare(back.expires_at, DateTime.utc_now()) == :gt,
             "the TTL was not re-armed, so the row is still stage-1 eligible"
    end

    test "a NON-playground suspension is lifted WITHOUT touching expires_at", _ctx do
      slug = uniq("cust")
      future = DateTime.add(DateTime.utc_now(), 72, :hour)
      {:ok, ws} = Tenancy.create_workspace(%{slug: slug, name: slug, expires_at: future})
      {:ok, _} = Quota.suspend(ws, "billing lapsed")

      raw = uniq("op2")
      {:ok, tok} = admin_token(raw, uniq("lbl-op2"), ws.id)
      put_allowlist([], [tok.id])

      body = raw |> reinstate(slug) |> json_response(200)

      refute body["suspended"]
      refute body["ttl_extended"], "a non-playground TTL must not be moved"

      back = reload(ws)
      assert DateTime.compare(back.expires_at, future) == :eq
    end
  end

  # ── C4: who is authorised, pinned in BOTH directions ───────────────────

  describe "authorisation — instance-operator only (THE RULING)" do
    test "ARMED: the instance operator reinstates (200)", ctx do
      put_allowlist([], [ctx.operator_token.id])
      _ = reaper_suspend!(ctx.ws, 1)

      assert ctx.operator |> reinstate(ctx.ws.slug) |> json_response(200)
      refute reload(ctx.ws).suspended
    end

    test "ARMED: the WORKSPACE'S OWN admin is refused 403 platform_operator", ctx do
      put_allowlist([], [ctx.operator_token.id])
      _ = reaper_suspend!(ctx.ws, 1)

      body = ctx.ws_admin |> reinstate(ctx.ws.slug) |> json_response(403)

      assert body["error"]["code"] == "forbidden"
      assert body["error"]["required"] == "platform_operator"

      # The halt is REAL — the write never happened.
      assert reload(ctx.ws).suspended,
             "a refused caller still lifted the suspension: the plug ran after the write"
    end

    test "an anonymous caller gets RequireToken's 401, never the operator 403", ctx do
      put_allowlist([], [ctx.operator_token.id])
      _ = reaper_suspend!(ctx.ws, 1)

      conn =
        scoped_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/v1/admin/workspaces/#{ctx.ws.slug}/reinstate", "{}")

      assert conn.status == 401
      assert reload(ctx.ws).suspended
    end

    test "UNSET (legacy): the admin bit alone still opens the route", ctx do
      # The non-vacuity control for the ARMED arms above: with the allowlist
      # unset the SAME workspace admin that was refused a moment ago passes,
      # which proves the 403 came from the allowlist and not from a broken route.
      _ = reaper_suspend!(ctx.ws, 1)

      assert ctx.ws_admin |> reinstate(ctx.ws.slug) |> json_response(200)
      refute reload(ctx.ws).suspended
    end
  end
end
