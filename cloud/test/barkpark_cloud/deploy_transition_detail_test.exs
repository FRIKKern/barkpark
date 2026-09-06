defmodule BarkparkCloud.DeployTransitionDetailTest do
  @moduledoc """
  THE SIXTH TERMINAL DETAIL PRODUCER — the two HTTP transition ROUTES
  (task-9e17071084bc5466, under the deploy-reliability epic).

  `deployments.detail` is the LATEST-WINS caption the site page renders under
  the status pill. Every writer that files a row TERMINAL owes it a rewrite, or
  the row keeps whatever the UI was saying when the deploy died. PR #14571
  fixed five such writers (the reaper's four `Repo.update_all` passes and
  `Registry.create_failed_deployment/3`); `Sites.Deploy.fail/3` was already
  correct. The SIXTH lives in the router and was left open by that branch:

      POST /v1/builder/deployments/:id/transition   (the off-box builder)
      POST /v1/agent/deployments/:id/transition     (the on-box agent)

  Both built their attrs with `:status` and `:failure_reason` and NO `:detail`.

  DRIVEN AT THE ROUTE, DELIBERATELY. A unit test on the Registry function
  would be VACUOUS here: the Registry layer is not where the omission lives —
  the route simply never asked it to write the column. The sequence these tests
  reproduce is the one the fleet actually ran: the builder POSTs a caption to
  `/detail`, the build dies, the builder POSTs a terminal transition, and the
  row is filed as a failure whose only human-readable text is "Fetching your
  source…".

  MEASURED, not assumed (2026-09-06, whole population — 37,719 deployment rows
  across all 14 sites, walked by cursor, not a capped sample): 23 failed rows
  carry a progress caption and 7 carry NULL. All 23 captions carry a
  BUILDER-stage reason ("The build source couldn't be fetched.", "nixpacks
  build: exit status 1") and reached the ledger through these routes; all 7
  NULLs are `GITHUB_PUSH_UNBUILDABLE` tombstones from
  `create_failed_deployment/3`, which PR #14571 already fixed. So this route
  pair is the sole producer of the caption class.

  AND THE CLASS IS DORMANT, NOT CURED: every one of those 30 rows belongs to
  ONE site, `jarl-website`, whose last deployment of any kind was
  2026-08-03T12:50:36Z. Nothing has exercised the builder path in the 33 days
  since, and all 89 failures recorded after 2026-08-20 carry a `detail` that
  mirrors `failure_reason`. This is therefore a TRIPWIRE fix on a live, reachable
  code path — not the repair of an active bleed — and these tests are what stop
  it returning the day someone connects a GitHub repo again.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @caption "Fetching your source…"

  ## ── Fixtures ───────────────────────────────────────────────────────────────

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "T #{n}", slug: "t-#{n}"})
    team
  end

  defp barkpark_fixture(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    bp
  end

  defp site_fixture(bp) do
    n = System.unique_integer([:positive])
    {:ok, site} = Registry.create_site(bp, %{name: "S #{n}", slug: "s-#{n}"})
    site
  end

  # Returns {token, barkpark, site}. One real AgentToken per box, so the
  # `require_agent` plug runs its real path. Minted ONCE per box: a second mint
  # supersedes the first and would 401 a token an earlier line still holds.
  defp box do
    team = team_fixture()
    bp = barkpark_fixture(team)
    site = site_fixture(bp)
    {:ok, token, _} = Registry.mint_agent_token(bp, "report")
    {token, bp, site}
  end

  defp call(method, path, body, token) do
    conn =
      case body do
        nil ->
          conn(method, path)

        b ->
          conn(method, path, Jason.encode!(b))
          |> put_req_header("content-type", "application/json")
      end

    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  # Put the row in the exact state the fleet was in: a caption showing, written
  # through the builder's own `/detail` route (the thing that produces captions).
  defp caption!(token, deployment_id) do
    conn =
      call(:post, "/v1/builder/deployments/#{deployment_id}/detail", %{detail: @caption}, token)

    assert conn.status == 200
    assert Registry.get_deployment(deployment_id).detail == @caption
  end

  # Claim through the BUILDER route → {deployment_id, observed_epoch}.
  defp builder_claim(site, token) do
    ref = "ref-#{System.unique_integer([:positive])}"
    {:ok, _d} = Registry.create_deployment(site, %{git_ref: ref})
    claim = call(:post, "/v1/builder/claim", %{worker_id: "wA"}, token)
    assert claim.status == 200
    {json_body(claim)["deployment"]["id"], json_body(claim)["observed_epoch"]}
  end

  # Claim through the AGENT route → {deployment_id, observed_epoch}. The agent
  # picks up at `pushing`, which is where the builder hands off.
  defp agent_claim(site, token) do
    ref = "ref-#{System.unique_integer([:positive])}"
    {:ok, d} = Registry.create_deployment(site, %{git_ref: ref})
    {:ok, _d} = Registry.transition_deployment(d, %{status: "pushing", image_tag: "img-1"})
    claim = call(:post, "/v1/agent/deployments/claim", %{worker_id: "agent-A"}, token)
    assert claim.status == 200
    {json_body(claim)["deployment"]["id"], json_body(claim)["observed_epoch"]}
  end

  ## ── The class ──────────────────────────────────────────────────────────────

  describe "a terminal failure filed through a transition route" do
    test "BUILDER route: the caption is replaced by the cause, not left standing" do
      {token, _bp, site} = box()
      {did, epoch} = builder_claim(site, token)
      caption!(token, did)

      reason = "BUILD failed (exit 12): nixpacks build: exit status 1"

      conn =
        call(
          :post,
          "/v1/builder/deployments/#{did}/transition",
          %{worker_id: "wA", observed_epoch: epoch, status: "failed", failure_reason: reason},
          token
        )

      assert conn.status == 200

      row = Registry.get_deployment(did)
      assert row.status == "failed"
      assert row.failure_reason == reason
      refute row.detail == @caption
      assert row.detail == reason
    end

    test "AGENT route: the caption is replaced by the cause, not left standing" do
      {token, _bp, site} = box()
      {did, epoch} = agent_claim(site, token)
      caption!(token, did)

      reason = "HEALTH gate failed — not switched (exit 14): bp-doc-id marker is empty"

      conn =
        call(
          :post,
          "/v1/agent/deployments/#{did}/transition",
          %{
            worker_id: "agent-A",
            observed_epoch: epoch,
            status: "failed",
            failure_reason: reason
          },
          token
        )

      assert conn.status == 200

      row = Registry.get_deployment(did)
      assert row.status == "failed"
      assert row.failure_reason == reason
      refute row.detail == @caption
      assert row.detail == reason
    end

    test "a failure that names NO reason gets a NAMED UNKNOWN — never the caption, never blank" do
      {token, _bp, site} = box()
      {did, epoch} = builder_claim(site, token)
      caption!(token, did)

      conn =
        call(
          :post,
          "/v1/builder/deployments/#{did}/transition",
          %{worker_id: "wA", observed_epoch: epoch, status: "failed"},
          token
        )

      assert conn.status == 200

      row = Registry.get_deployment(did)
      assert row.status == "failed"
      refute row.detail == @caption
      assert is_binary(row.detail)
      assert String.trim(row.detail) != ""
      # The parent epic's rule, in force: a cause OR a named unknown. The
      # sentence must SAY that nothing was reported, not merely be non-empty.
      assert row.detail =~ ~r/no reason|did not say|unknown/i
    end

    test "an over-long reason is clamped to the caption's 255, through the SHARED clamp" do
      {token, _bp, site} = box()
      {did, epoch} = builder_claim(site, token)
      caption!(token, did)

      reason = String.duplicate("x", 400)

      conn =
        call(
          :post,
          "/v1/builder/deployments/#{did}/transition",
          %{worker_id: "wA", observed_epoch: epoch, status: "failed", failure_reason: reason},
          token
        )

      assert conn.status == 200

      row = Registry.get_deployment(did)
      # `failure_reason` is :text and keeps the WHOLE story untruncated.
      assert row.failure_reason == reason
      # `detail` is the one-line caption and is clamped exactly as
      # Sites.Deploy.short_detail/1 and Registry.failure_detail/1 clamp.
      assert String.length(row.detail) == 255
      assert String.ends_with?(row.detail, "…")
    end

    test "a NON-terminal transition leaves the caption alone — it is legitimate mid-flight" do
      {token, _bp, site} = box()
      {did, epoch} = builder_claim(site, token)
      caption!(token, did)

      conn =
        call(
          :post,
          "/v1/builder/deployments/#{did}/transition",
          %{worker_id: "wA", observed_epoch: epoch, status: "pushing", image_tag: "sha256:abc"},
          token
        )

      assert conn.status == 200

      row = Registry.get_deployment(did)
      assert row.status == "pushing"
      # Still the caption: the deploy is alive and the caption is the truth.
      assert row.detail == @caption
    end
  end

  ## ── The clamp has ONE owner ────────────────────────────────────────────────

  describe "the 255 clamp" do
    test "FailureCopy.caption/1 is the single implementation the three call sites share" do
      short = "a cause"
      assert BarkparkCloud.FailureCopy.caption(short) == short
      assert BarkparkCloud.FailureCopy.caption(nil) == nil

      long = String.duplicate("y", 400)
      clamped = BarkparkCloud.FailureCopy.caption(long)
      assert String.length(clamped) == 255
      assert String.ends_with?(clamped, "…")
      assert String.starts_with?(clamped, String.duplicate("y", 254))
    end
  end
end
