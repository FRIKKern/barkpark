defmodule BarkparkCloud.Web.RouterAttachPlatformLabelGuardTest do
  @moduledoc """
  task-6f85554a4e0cbc4c: a team admin must not be able to repoint a name in the
  platform zone that is not theirs.

  The platform-zone attach path used to persist straight away ("we own that
  DNS"), and the attach job's `UpsertRecord` is create-OR-REPLACE
  (internal/hetzner/dns.go). So attaching `api.barkpark.cloud`, or any label
  already holding somebody's record, replaced that record with the team's box
  IP, and the name-only TLS ask-gate would then certify it.

  Two fences, both before anything is written or enqueued:

    * a reserved system label (`Barkpark.reserved?/1`) fails validation → 422
      `invalid_domain`;
    * a platform name that already resolves anywhere but this box, or cannot be
      read, is refused → 409 `taken`.

  async: false — the `:platform_label_dns` seam is injected via application env.
  """
  use BarkparkCloud.DataCase, async: false
  import Plug.Test
  import Plug.Conn
  import Ecto.Query, only: [from: 2]

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Registry.ProvisionJob
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"
  @box_ip "203.0.113.10"
  @box_ip_tuple {203, 0, 113, 10}
  @cp_ip_tuple {178, 105, 92, 191}

  defp user_with_team do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  defp live_barkpark(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    {:ok, _} = Registry.upsert_health(bp, %{host: @box_ip})
    Registry.get_barkpark(bp.id)
  end

  defp attach(user, bp, domain) do
    {:ok, token} = Accounts.create_user_session_token(user)

    conn(:post, "/v1/barkparks/#{bp.id}/domain", Jason.encode!(%{domain: domain}))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  defp attach_jobs(bp) do
    from(j in ProvisionJob, where: j.barkpark_id == ^bp.id and j.kind == "attach_domain")
    |> Repo.aggregate(:count, :id)
  end

  defp with_platform_dns(fun) do
    prev = Application.fetch_env(:barkpark_cloud, :platform_label_dns)
    Application.put_env(:barkpark_cloud, :platform_label_dns, fun)

    on_exit(fn ->
      case prev do
        {:ok, v} -> Application.put_env(:barkpark_cloud, :platform_label_dns, v)
        :error -> Application.delete_env(:barkpark_cloud, :platform_label_dns)
      end
    end)
  end

  defp resolves_to(addrs) do
    fn
      _host, :inet -> {:ok, addrs}
      _host, :inet6 -> {:error, :nxdomain}
    end
  end

  defp label, do: "r2c-#{System.unique_integer([:positive])}"

  test "a reserved system label (api) is refused at validation, nothing written" do
    {user, team} = user_with_team()
    bp = live_barkpark(team)

    for reserved <- ~w(api www mail status) do
      conn = attach(user, bp, "#{reserved}.barkpark.cloud")
      assert conn.status == 422, "#{reserved} must be refused"
      assert Jason.decode!(conn.resp_body)["error"] == "invalid_domain"
    end

    assert Registry.get_barkpark(bp.id).custom_host == nil
    assert attach_jobs(bp) == 0
  end

  test "a platform name that already resolves elsewhere is refused as taken, nothing written" do
    with_platform_dns(resolves_to([@cp_ip_tuple]))
    {user, team} = user_with_team()
    bp = live_barkpark(team)

    conn = attach(user, bp, "#{label()}.barkpark.cloud")
    assert conn.status == 409
    assert Jason.decode!(conn.resp_body) == %{"error" => "taken"}
    assert Registry.get_barkpark(bp.id).custom_host == nil
    assert attach_jobs(bp) == 0
  end

  test "a platform name the resolver cannot read is refused (fail closed)" do
    with_platform_dns(fn _host, _family -> {:error, :timeout} end)
    {user, team} = user_with_team()
    bp = live_barkpark(team)

    assert attach(user, bp, "#{label()}.barkpark.cloud").status == 409
    assert attach_jobs(bp) == 0
  end

  test "CONTROL: a free platform name (NXDOMAIN) still attaches" do
    {user, team} = user_with_team()
    bp = live_barkpark(team)
    host = "#{label()}.barkpark.cloud"

    assert attach(user, bp, host).status == 202
    assert Registry.get_barkpark(bp.id).custom_host == host
    assert attach_jobs(bp) == 1
  end

  test "CONTROL: a name already pointing at THIS box (re-attach) still attaches" do
    with_platform_dns(resolves_to([@box_ip_tuple]))
    {user, team} = user_with_team()
    bp = live_barkpark(team)

    assert attach(user, bp, "#{label()}.barkpark.cloud").status == 202
  end
end
