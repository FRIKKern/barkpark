defmodule BarkparkCloud.SelfUpdateEgressTest do
  @moduledoc """
  task-b4b2bb60b63e28ea — every self-update trigger carries the control plane's
  egress address(es) as `cloud_egress_ips`, so a SELF-updating box backfills
  BARKPARK_TRUSTED_PROXIES the way a CD deploy does. Only a list of bare IPs is
  ever sent; anything else leaves the body `{}` (the pre-change shape).

  async: false — it mutates `:cloud_egress_ips` application env.
  """
  use BarkparkCloud.DataCase, async: false

  alias BarkparkCloud.{Accounts, Registry, Repo, StudioLinkFakeHttpClient}
  alias BarkparkCloud.Registry.Vault

  defp live_box do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
    |> Ecto.Changeset.change(
      host: "203.0.113.#{rem(n, 250) + 1}",
      url: "https://bp-#{n}.barkpark.cloud",
      admin_token_encrypted: Vault.encrypt("instance-admin-token")
    )
    |> Repo.update!()
  end

  defp with_egress(value) do
    prior = Application.get_env(:barkpark_cloud, :cloud_egress_ips)

    if value,
      do: Application.put_env(:barkpark_cloud, :cloud_egress_ips, value),
      else: Application.delete_env(:barkpark_cloud, :cloud_egress_ips)

    on_exit(fn ->
      if prior,
        do: Application.put_env(:barkpark_cloud, :cloud_egress_ips, prior),
        else: Application.delete_env(:barkpark_cloud, :cloud_egress_ips)
    end)
  end

  defp trigger_body(value) do
    with_egress(value)
    bp = live_box()
    StudioLinkFakeHttpClient.program([{:ok, %{status: 202, body: ~s({"ok":true})}}])

    assert {:ok, 202, _} = Registry.trigger_self_update(bp)
    [req] = StudioLinkFakeHttpClient.requests()
    assert req.url =~ "/v1/admin/self-update"
    Jason.decode!(req.body)
  end

  test "a configured list of bare IPs rides the trigger body, normalised" do
    assert trigger_body(" 178.105.92.191 , 2a01:4f9::1 ") ==
             %{"cloud_egress_ips" => "178.105.92.191,2a01:4f9::1"}
  end

  test "unset: the body is the pre-change {}" do
    assert trigger_body(nil) == %{}
  end

  test "a CIDR, a hostname or a blank list sends nothing — never a value the box would refuse" do
    for bad <- ["10.0.0.0/8", "178.105.92.191,barkpark.cloud", " , ", "not-an-ip"] do
      with_egress(bad)
      assert Registry.self_update_body() == %{}, "sent #{inspect(bad)}"
    end
  end
end
