defmodule BarkparkCloud.RegistryAdminTokenWithheldTest do
  @moduledoc """
  task-0d75da311d16a94d: the admin bearer never goes to a url host another box
  owns.

  The prod shape (dr-w24-bl-gyldendal-live-cross-tenant-escalation): a ghost
  row's `url` is a host that a different team attached as its `custom_host`.
  The `hostname_claims` backfill gave the host to the custom_host claim, and
  skipped the ghost row's url claim. Every seam that talks to an instance as
  its admin decrypts through `Registry.reveal_admin_token/1` and posts to
  `bp.url`, so the ghost row's bearer went to the other team's server.
  """
  use BarkparkCloud.DataCase, async: true

  import ExUnit.CaptureLog

  alias BarkparkCloud.{Accounts, Registry, Usage}
  alias BarkparkCloud.Registry.Vault

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp barkpark_fixture(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    bp
  end

  defp host, do: "xt-#{System.unique_integer([:positive])}.barkpark.cloud"

  # A row that holds `url` and an admin token WITHOUT writing a url claim,
  # the way a pre-table ghost row does.
  defp row_with_url(url, token) do
    {:ok, bp} =
      team_fixture()
      |> barkpark_fixture()
      |> Ecto.Changeset.change(url: url, admin_token_encrypted: Vault.encrypt(token))
      |> Repo.update()

    bp
  end

  test "a ghost row whose url host another team claims gets no decrypted token" do
    h = host()

    # The customer attaches the host first; their claim holds it.
    customer = team_fixture() |> barkpark_fixture()
    assert {:ok, _} = Registry.set_custom_host(customer, h)

    ghost = row_with_url("https://" <> h, "ghost-admin-token")

    me = self()
    handler = "xt-withheld-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:barkpark_cloud, :registry, :admin_token_withheld],
      fn _e, _m, meta, _ -> send(me, {:withheld, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    log =
      capture_log(fn ->
        assert :error = Registry.reveal_admin_token(ghost)
        # The usage sampler's door answers fail-closed, so nothing is sent.
        assert {:error, :decrypt_failed} = Usage.instance_admin_token(ghost)
      end)

    assert log =~ "WITHHELD"
    assert log =~ customer.id
    assert_receive {:withheld, %{barkpark_id: ghost_id, claimed_by: claimed_by, host: ^h}}
    assert ghost_id == ghost.id
    assert claimed_by == customer.id
  end

  test "CONTROL: a row whose url host is unclaimed still decrypts" do
    bp = row_with_url("https://" <> host(), "plain-token")
    assert {:ok, "plain-token"} = Registry.reveal_admin_token(bp)
  end

  test "CONTROL: a row whose url host it claims itself still decrypts" do
    h = host()
    bp = row_with_url("https://" <> h, "own-token")

    # Attaching the host the row already serves as its url is the legitimate
    # self-claim.
    assert {:ok, bp} = Registry.set_custom_host(bp, h)
    assert {:ok, "own-token"} = Registry.reveal_admin_token(bp)
  end

  test "CONTROL: a row with no admin token is unchanged" do
    bp = team_fixture() |> barkpark_fixture()
    assert {:ok, nil} = Registry.reveal_admin_token(bp)
  end
end
