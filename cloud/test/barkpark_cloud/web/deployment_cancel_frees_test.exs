defmodule BarkparkCloud.Web.DeploymentCancelFreesTest do
  @moduledoc """
  dwb-cancel-blocking-semantics — the CANCEL-FREES contract, driven through the
  real writers and the real routes (ruling 2026-09-25, option A):

    * cancel is terminal FOR THAT ROW (`Deployment.legal_transition?/2`: no edge
      out of `cancelled`), so a builder still holding the claim cannot walk it
      back to pushing/live;
    * cancel FREES the active slot at once: `deployments_active_site_env_index`
      is partial on `status IN ('queued','building','pushing')`, so a cancelled
      row stops counting, and the same commit rebuilds from a manual redeploy
      (`POST /v1/sites/:id/deploy`) or a NEW GitHub delivery;
    * a redelivery of the SAME `X-GitHub-Delivery` stays deduped
      (`deployments_delivery_id_index` has no status filter, and the webhook asks
      `find_deployment_by_delivery_id/1` first), so GitHub retrying an event
      does not undo a cancel the fleet filed.

  There is no operator cancel ROUTE on the control plane (registry.ex says so:
  "There is no human cancel path"). The writers that land `cancelled` are the
  builder/agent fenced transition routes, the unfenced
  `Registry.transition_deployment/2` (AutoDeployWorker's refusal), and the
  preview teardown/supersede/evict path — every one a machine, none a person
  (charter D614(c)). The tests drive the first two.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Registry.Deployment
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  ## Fixtures

  # A container site on its own box, with a linked GitHub repo (so a push and a
  # manual deploy both mint a buildable queued row) and a webhook secret.
  defp world do
    {:ok, user} =
      Accounts.register_user(%{
        email: "u-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "T #{n}", slug: "t-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    {:ok, site} = Registry.create_site(bp, %{name: "S #{n}", slug: "s-#{n}"})
    {:ok, site} = Registry.set_site_github(site, "owner/repo", "main", "the-secret")
    {:ok, session} = Accounts.create_user_session_token(user)
    {:ok, agent, _} = Registry.mint_agent_token(bp.id, "report")

    %{site: site, secret: "the-secret", session: session, agent: agent}
  end

  defp sha(n), do: String.duplicate(Integer.to_string(n, 16) |> String.downcase(), 40)

  defp delivery, do: "delivery-#{System.unique_integer([:positive])}"

  ## Request helpers

  defp call(method, path, body, token) do
    conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  defp gh_push(w, sha, delivery_id) do
    raw = Jason.encode!(%{"ref" => "refs/heads/main", "after" => sha})
    sig = "sha256=" <> (:crypto.mac(:hmac, :sha256, w.secret, raw) |> Base.encode16(case: :lower))

    conn(:post, "/v1/webhooks/github/#{w.site.id}", raw)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-github-event", "push")
    |> put_req_header("x-hub-signature-256", sig)
    |> put_req_header("x-github-delivery", delivery_id)
    |> Router.call(@opts)
  end

  defp redeploy(w, sha),
    do: call(:post, "/v1/sites/#{w.site.id}/deploy", %{git_ref: sha}, w.session)

  defp claim(w, worker) do
    conn = call(:post, "/v1/builder/claim", %{worker_id: worker}, w.agent)
    assert conn.status == 200, conn.resp_body
    body = json(conn)
    {body["deployment"]["id"], body["observed_epoch"]}
  end

  defp transition(w, id, worker, epoch, attrs) do
    call(
      :post,
      "/v1/builder/deployments/#{id}/transition",
      Map.merge(%{worker_id: worker, observed_epoch: epoch}, attrs),
      w.agent
    )
  end

  defp cancel(w, id, worker, epoch),
    do:
      transition(w, id, worker, epoch, %{
        status: "cancelled",
        failure_reason: "cancelled by the build box"
      })

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp active_rows(site) do
    Deployment
    |> where([d], d.site_id == ^site.id and d.status in ~w(queued building pushing))
    |> Repo.all()
  end

  defp concurrently(n, fun) do
    parent = self()

    1..n
    |> Enum.map(fn i ->
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.allow(BarkparkCloud.Repo, parent, self())
        fun.(i)
      end)
    end)
    |> Task.await_many(10_000)
  end

  # A queued production build at `sha`, minted by a real GitHub push.
  defp pushed(w, sha) do
    d = delivery()
    conn = gh_push(w, sha, d)
    assert conn.status == 201, conn.resp_body
    {json(conn)["deployment_id"], d}
  end

  ## Cancel before build

  describe "cancel before build (queued, unclaimed)" do
    test "the row is never built and the slot is free for the same commit" do
      w = world()
      {id, _d} = pushed(w, sha(1))

      # The unfenced writer AutoDeployWorker uses — the only writer that can
      # cancel a row nobody has claimed.
      {:ok, cancelled} =
        Registry.transition_deployment(Registry.get_deployment(id), %{status: "cancelled"})

      assert cancelled.status == "cancelled"
      assert active_rows(w.site) == []

      # Never built: the builder's claim does not see it.
      refute_claimable(w)

      # Slot free: the same commit mints a FRESH row, not a coalesce onto the
      # cancelled one.
      again = redeploy(w, sha(1))
      assert again.status == 201, again.resp_body
      assert json(again)["deployment"]["id"] != id
      assert json(again)["deployment"]["status"] == "queued"
    end

    test "CONCURRENT cancel vs builder claim: the row ends cancelled either way and the slot is free" do
      w = world()
      {id, _d} = pushed(w, sha(2))
      queued = Registry.get_deployment(id)

      [claim_conn, cancel_result] =
        concurrently(2, fn
          1 -> call(:post, "/v1/builder/claim", %{worker_id: "racer"}, w.agent)
          2 -> Registry.transition_deployment(queued, %{status: "cancelled"})
        end)

      assert claim_conn.status in [200, 404]
      assert {:ok, _} = cancel_result
      assert Registry.get_deployment(id).status == "cancelled"
      assert active_rows(w.site) == []

      again = redeploy(w, sha(2))
      assert again.status == 201
    end
  end

  ## Cancel mid-build

  describe "cancel mid-build" do
    test "building → cancelled: terminal for the row, the holder cannot resume it, the slot is free" do
      w = world()
      {id, _d} = pushed(w, sha(3))
      {^id, epoch} = claim(w, "wA")

      conn = cancel(w, id, "wA", epoch)
      assert conn.status == 200, conn.resp_body
      assert json(conn)["deployment"]["status"] == "cancelled"

      # The builder that still holds the claim cannot walk it back.
      for next <- ~w(building pushing live failed) do
        late = transition(w, id, "wA", epoch, %{status: next})
        assert late.status == 409, "#{next}: #{late.resp_body}"
        assert json(late)["error"] == "illegal_transition"
      end

      assert Registry.get_deployment(id).status == "cancelled"
      assert active_rows(w.site) == []
      assert redeploy(w, sha(3)).status == 201
    end

    test "pushing → cancelled: terminal for the row, never goes live, the slot is free" do
      w = world()
      {id, _d} = pushed(w, sha(4))
      {^id, epoch} = claim(w, "wA")
      assert transition(w, id, "wA", epoch, %{status: "pushing"}).status == 200

      conn = cancel(w, id, "wA", epoch)
      assert conn.status == 200, conn.resp_body
      assert json(conn)["deployment"]["status"] == "cancelled"

      late = transition(w, id, "wA", epoch, %{status: "live"})
      assert late.status == 409
      assert json(late)["error"] == "illegal_transition"

      assert active_rows(w.site) == []
      assert redeploy(w, sha(4)).status == 201
    end
  end

  ## Duplicate cancel

  describe "duplicate cancel" do
    test "a repeated cancel is idempotent: same 200 body, row untouched" do
      w = world()
      {id, _d} = pushed(w, sha(5))
      {^id, epoch} = claim(w, "wA")

      first = cancel(w, id, "wA", epoch)
      assert first.status == 200
      row = Registry.get_deployment(id)

      second = cancel(w, id, "wA", epoch)
      assert second.status == 200
      assert json(second) == json(first)

      # Nothing was written the second time: no console line, no timestamp bump,
      # no second terminal edge (the notification dispatch is edge-triggered on
      # the PRIOR status, and cancelled → cancelled is not an edge).
      after_row = Registry.get_deployment(id)
      assert after_row.updated_at == row.updated_at
      assert after_row.console == row.console
      assert after_row.status == "cancelled"
    end

    test "CONCURRENT duplicate cancels both answer 200 with one outcome" do
      w = world()
      {id, _d} = pushed(w, sha(6))
      {^id, epoch} = claim(w, "wA")

      results = concurrently(3, fn _ -> cancel(w, id, "wA", epoch) end)

      assert Enum.all?(results, &(&1.status == 200))
      assert results |> Enum.map(&json/1) |> Enum.uniq() |> length() == 1
      assert Registry.get_deployment(id).status == "cancelled"
    end
  end

  ## Retry after cancel

  describe "retry after cancel starts a fresh deployment for the same site + git_ref" do
    test "a NEW GitHub delivery of the same commit mints a fresh queued row" do
      w = world()
      {id, _d} = pushed(w, sha(7))
      {^id, epoch} = claim(w, "wA")
      assert cancel(w, id, "wA", epoch).status == 200

      conn = gh_push(w, sha(7), delivery())
      assert conn.status == 201, conn.resp_body
      fresh = json(conn)["deployment_id"]
      assert fresh != id
      assert Registry.get_deployment(fresh).status == "queued"
      assert Registry.get_deployment(fresh).git_ref == sha(7)
    end

    test "CONCURRENT manual redeploys after a cancel mint exactly ONE fresh row" do
      w = world()
      {id, _d} = pushed(w, sha(8))
      {^id, epoch} = claim(w, "wA")
      assert cancel(w, id, "wA", epoch).status == 200

      results = concurrently(3, fn _ -> redeploy(w, sha(8)) end)

      assert Enum.count(results, &(&1.status == 201)) == 1
      assert Enum.count(results, &(&1.status == 200)) == 2
      ids = results |> Enum.map(&json(&1)["deployment"]["id"]) |> Enum.uniq()
      assert [fresh] = ids
      assert fresh != id
      assert [%{id: ^fresh}] = active_rows(w.site)
    end
  end

  ## Redelivery after cancel

  describe "redelivery of the SAME delivery_id after cancel" do
    test "stays deduped onto the cancelled row — GitHub retrying does not undo a cancel" do
      w = world()
      {id, d} = pushed(w, sha(9))
      {^id, epoch} = claim(w, "wA")
      assert cancel(w, id, "wA", epoch).status == 200

      conn = gh_push(w, sha(9), d)
      assert conn.status == 200, conn.resp_body
      assert json(conn)["reason"] == "duplicate_delivery"
      assert json(conn)["deployment_id"] == id

      assert active_rows(w.site) == []
      assert length(Registry.list_deployments(w.site)) == 1
    end

    test "CONCURRENT redeliveries of a cancelled delivery all dedupe, none rebuilds" do
      w = world()
      {id, d} = pushed(w, sha(10))

      {:ok, _} =
        Registry.transition_deployment(Registry.get_deployment(id), %{status: "cancelled"})

      results = concurrently(3, fn _ -> gh_push(w, sha(10), d) end)

      assert Enum.all?(results, &(&1.status == 200))
      assert Enum.all?(results, &(json(&1)["deployment_id"] == id))
      assert active_rows(w.site) == []
      assert length(Registry.list_deployments(w.site)) == 1
    end
  end

  ## The whole scenario

  test "SCENARIO: deploy → cancel mid-build → redeploy same commit → live, no wedge" do
    w = world()
    commit = sha(11)

    # 1. A push deploys the commit; the builder claims it.
    {first, d} = pushed(w, commit)
    {^first, e1} = claim(w, "wA")
    assert transition(w, first, "wA", e1, %{status: "pushing"}).status == 200

    # 2. Cancelled mid-build.
    assert cancel(w, first, "wA", e1).status == 200

    # 3. GitHub retrying the original event does not resurrect it.
    retry = gh_push(w, commit, d)
    assert json(retry)["reason"] == "duplicate_delivery"

    # 4. A manual redeploy of the SAME commit mints a fresh row.
    again = redeploy(w, commit)
    assert again.status == 201
    second = json(again)["deployment"]["id"]
    assert second != first

    # 5. The builder claims the fresh row and takes it all the way live.
    {^second, e2} = claim(w, "wB")
    assert transition(w, second, "wB", e2, %{status: "pushing"}).status == 200

    live =
      transition(w, second, "wB", e2, %{
        status: "live",
        became_live_at: DateTime.to_iso8601(DateTime.utc_now())
      })

    assert live.status == 200, live.resp_body
    assert json(live)["deployment"]["status"] == "live"

    # No wedge: both rows are terminal, nothing is left holding the slot, and a
    # further deploy of the commit is accepted.
    assert Registry.get_deployment(first).status == "cancelled"
    assert Registry.get_deployment(second).status == "live"
    assert active_rows(w.site) == []
    assert redeploy(w, commit).status == 201
  end

  defp refute_claimable(w) do
    conn = call(:post, "/v1/builder/claim", %{worker_id: "late"}, w.agent)
    assert conn.status == 404
    assert json(conn)["error"] == "no_queued"
  end
end
