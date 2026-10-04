defmodule BarkparkCloud.Web.RouterOperatorEnableApplyTest do
  @moduledoc """
  task-90f256a8c5e27cd2: `POST /v1/operator/barkparks/:id/enable-apply` re-runs
  the enable-apply SSH job on one ARMED box — the control plane's own way (the
  LATEST worker code) to clear the box-side go.mod/go.sum churn that jammed
  every self-update in the 0.2.27 rollout. The automatic paths only enqueue for
  an UNARMED box, which these are not.

  Operator-only; consent-gated exactly like the automatic path.

  `async: false` — the operator allowlist is process-global Application config.
  """
  use BarkparkCloud.DataCase, async: false
  import Plug.Test
  import Plug.Conn
  import Ecto.Query

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Registry.ProvisionJob
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  setup do
    prior = Application.get_env(:barkpark_cloud, :platform_admin_emails, [])
    on_exit(fn -> Application.put_env(:barkpark_cloud, :platform_admin_emails, prior) end)
    :ok
  end

  defp user_and_team(role) do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, role)
    {:ok, token} = Accounts.create_user_session_token(user)
    {user, team, token}
  end

  defp operator_token do
    {user, _team, token} = user_and_team("owner")
    Application.put_env(:barkpark_cloud, :platform_admin_emails, [user.email])
    token
  end

  defp armed_box(team, attrs \\ %{}) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
    |> Ecto.Changeset.change(
      Map.merge(
        %{host: "203.0.113.#{rem(n, 200) + 10}", autoupdate_enabled: true, apply_arming: "armed"},
        attrs
      )
    )
    |> Repo.update!()
  end

  defp call(path, token) do
    conn(:post, path, "{}")
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  defp jobs(bp),
    do:
      Repo.all(
        from j in ProvisionJob, where: j.barkpark_id == ^bp.id and j.kind == "enable_apply"
      )

  test "an operator queues one enable-apply job on an ARMED box (202); a second ask dedups (200)" do
    {_u, team, _t} = user_and_team("owner")
    bp = armed_box(team)
    op = operator_token()

    first = call("/v1/operator/barkparks/#{bp.id}/enable-apply", op)
    assert first.status == 202
    assert %{"status" => "queued", "job_id" => job_id} = Jason.decode!(first.resp_body)
    assert [%{id: ^job_id, status: "pending"}] = jobs(bp)

    second = call("/v1/operator/barkparks/#{bp.id}/enable-apply", op)
    assert second.status == 200
    assert Jason.decode!(second.resp_body) == %{"status" => "already_arming"}
    assert length(jobs(bp)) == 1
  end

  test "a team owner who is not an operator is refused, and nothing is queued" do
    {_u, team, token} = user_and_team("owner")
    bp = armed_box(team)

    assert call("/v1/operator/barkparks/#{bp.id}/enable-apply", token).status == 403
    assert jobs(bp) == []
  end

  test "the consent gate holds: autoupdate off → 409 not_live; suspended → 409; unknown → 404" do
    {_u, team, _t} = user_and_team("owner")
    op = operator_token()

    off = armed_box(team, %{autoupdate_enabled: false})
    assert call("/v1/operator/barkparks/#{off.id}/enable-apply", op).status == 409
    assert jobs(off) == []

    susp = armed_box(team, %{suspended: true})
    resp = call("/v1/operator/barkparks/#{susp.id}/enable-apply", op)
    assert resp.status == 409
    assert Jason.decode!(resp.resp_body)["error"] == "suspended"
    assert jobs(susp) == []

    assert call("/v1/operator/barkparks/#{Ecto.UUID.generate()}/enable-apply", op).status == 404
  end
end
