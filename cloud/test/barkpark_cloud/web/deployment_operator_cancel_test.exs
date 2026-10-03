defmodule BarkparkCloud.Web.DeploymentOperatorCancelTest do
  @moduledoc """
  The OPERATOR cancel (task-4187bcf6d0424cfc):
  `POST /v1/sites/:id/deployments/:dep_id/cancel`, driven through the real
  router, writers and builder routes. One test per arm of
  `Registry.operator_cancel_deployment/3`:

    * queued → 200 `cancelled`, `failure_reason: "operator_cancelled"`, the
      slot is free (the same commit redeploys as a NEW row), and an audit row
      `deployment.cancelled` names the acting user;
    * a CONTAINER row still `building` → 200, and the builder holding the
      claim is refused afterwards (409 illegal_transition);
    * `pushing`, or a static row `building` → 409 `in_flight`, row untouched;
    * `live` / `failed` → 409 `illegal_transition`, row untouched;
    * already `cancelled` → 200 `already_cancelled`, no write and no second
      audit row;
    * a wrong-team site, another site's deployment, or a non-UUID → 404 (no
      existence leak).
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Accounts.AuditEvent
  alias BarkparkCloud.Registry.Deployment
  alias BarkparkCloud.Web.Router

  @opts Router.init([])

  defp world(site_attrs \\ %{}) do
    {:ok, user} =
      Accounts.register_user(%{
        email: "oc-#{System.unique_integer([:positive])}@example.com",
        password: "correct-horse-battery"
      })

    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "OC #{n}", slug: "oc-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "ocbp-#{n}"})

    {:ok, site} =
      Registry.create_site(bp, Map.merge(%{name: "S #{n}", slug: "ocs-#{n}"}, site_attrs))

    {:ok, site} = Registry.set_site_github(site, "owner/repo", "main", "the-secret")
    {:ok, session} = Accounts.create_user_session_token(user)
    {:ok, agent, _} = Registry.mint_agent_token(bp.id, "report")

    %{site: site, session: session, agent: agent, team: team, user: user}
  end

  defp sha(n), do: String.duplicate(Integer.to_string(n, 16) |> String.downcase(), 40)

  defp call(method, path, body, token) do
    conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp redeploy(w, sha),
    do: call(:post, "/v1/sites/#{w.site.id}/deploy", %{git_ref: sha}, w.session)

  defp queued!(w, n) do
    conn = redeploy(w, sha(n))
    assert conn.status == 201, conn.resp_body
    json(conn)["deployment"]["id"]
  end

  defp cancel(w, dep_id, token \\ nil),
    do:
      call(:post, "/v1/sites/#{w.site.id}/deployments/#{dep_id}/cancel", %{}, token || w.session)

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

  defp active_rows(site) do
    Deployment
    |> where([d], d.site_id == ^site.id and d.status in ~w(queued building pushing))
    |> Repo.all()
  end

  defp cancel_audits(team) do
    AuditEvent
    |> where([e], e.team_id == ^team.id and e.action == "deployment.cancelled")
    |> Repo.all()
  end

  # A row walked straight to `status` through the unfenced writer, for the arms
  # whose precondition is a state no route reaches cheaply.
  defp row_in!(w, n, status) do
    id = queued!(w, n)
    dep = Registry.get_deployment(id)

    path =
      case status do
        "building" -> ["building"]
        "pushing" -> ["building", "pushing"]
        "live" -> ["building", "pushing", "live"]
        "failed" -> ["failed"]
      end

    Enum.reduce(path, dep, fn s, d ->
      {:ok, d} = Registry.transition_deployment(d, %{status: s})
      d
    end)
  end

  describe "200: the cancel lands and frees the slot" do
    test "a QUEUED row is cancelled, attributed, audited, and the same commit redeploys" do
      w = world()
      id = queued!(w, 1)

      conn = cancel(w, id)
      assert conn.status == 200, conn.resp_body
      body = json(conn)
      assert body["ok"] == true
      assert body["status"] == "cancelled"
      assert body["slot_free"] == true
      assert body["next"] =~ "redeploy"
      assert body["deployment"]["status"] == "cancelled"

      row = Registry.get_deployment(id)
      assert row.status == "cancelled"
      assert row.failure_reason == Registry.operator_cancel_reason()
      assert row.failure_reason == "operator_cancelled"
      assert active_rows(w.site) == []

      assert [audit] = cancel_audits(w.team)
      assert audit.actor_user_id == w.user.id
      assert audit.target_id == id

      # cancel FREES: the same commit is a NEW queued row, not a 409.
      again = redeploy(w, sha(1))
      assert again.status == 201, again.resp_body
      refute json(again)["deployment"]["id"] == id
    end

    test "a CONTAINER row still BUILDING is cancelled, and the claim holder is refused after" do
      w = world()
      id = queued!(w, 2)
      {^id, epoch} = claim(w, "wA")
      assert Registry.get_deployment(id).status == "building"

      conn = cancel(w, id)
      assert conn.status == 200, conn.resp_body
      assert json(conn)["status"] == "cancelled"

      for next <- ~w(pushing live failed) do
        late = transition(w, id, "wA", epoch, %{status: next})
        assert late.status == 409, "#{next}: #{late.resp_body}"
        assert json(late)["error"] == "illegal_transition"
      end

      assert Registry.get_deployment(id).status == "cancelled"
      assert active_rows(w.site) == []
    end

    test "an ALREADY-cancelled row answers 200 already_cancelled: no write, no second audit" do
      w = world()
      id = queued!(w, 3)
      assert cancel(w, id).status == 200
      row = Registry.get_deployment(id)

      again = cancel(w, id)
      assert again.status == 200, again.resp_body
      assert json(again)["status"] == "already_cancelled"
      assert json(again)["slot_free"] == true

      after_row = Registry.get_deployment(id)
      assert after_row.updated_at == row.updated_at
      assert after_row.console == row.console
      assert length(cancel_audits(w.team)) == 1
    end
  end

  describe "409: what a cancel must refuse" do
    test "live and failed are terminal: illegal_transition, row untouched" do
      w = world()

      for {status, n} <- [{"live", 4}, {"failed", 5}] do
        dep = row_in!(w, n, status)
        conn = cancel(w, dep.id)
        assert conn.status == 409, "#{status}: #{conn.resp_body}"
        assert json(conn)["error"] == "illegal_transition"
        assert json(conn)["status"] == status
        assert Registry.get_deployment(dep.id).status == status
      end

      assert cancel_audits(w.team) == []
    end

    test "PUSHING is in flight on the box: in_flight, row untouched" do
      w = world()
      dep = row_in!(w, 6, "pushing")

      conn = cancel(w, dep.id)
      assert conn.status == 409, conn.resp_body
      assert json(conn)["error"] == "in_flight"
      assert json(conn)["detail"] =~ "settle"
      assert Registry.get_deployment(dep.id).status == "pushing"
    end

    test "a STATIC site's BUILDING row is driven by the box: in_flight, row untouched" do
      w = world(%{kind: "static", framework: "static"})
      {:ok, dep} = Registry.create_deployment(w.site, %{git_ref: sha(7)})
      {:ok, dep} = Registry.transition_deployment(dep, %{status: "building"})

      conn = cancel(w, dep.id)
      assert conn.status == 409, conn.resp_body
      assert json(conn)["error"] == "in_flight"
      assert Registry.get_deployment(dep.id).status == "building"
    end
  end

  describe "404: no existence leak" do
    test "another team's site, another site's deployment and a non-UUID all answer 404" do
      w = world()
      other = world()
      id = queued!(w, 8)
      other_id = queued!(other, 9)

      # Another team's session against w's site and row.
      assert cancel(w, id, other.session).status == 404
      # w's site, but a deployment that belongs to another site.
      assert cancel(w, other_id).status == 404
      # Not a UUID.
      assert cancel(w, "not-a-uuid").status == 404

      assert Registry.get_deployment(id).status == "queued"
      assert Registry.get_deployment(other_id).status == "queued"
    end
  end
end
