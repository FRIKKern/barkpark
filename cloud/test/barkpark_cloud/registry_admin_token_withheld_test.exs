defmodule BarkparkCloud.RegistryAdminTokenWithheldTest do
  @moduledoc """
  Admin tokens are sent only to hosts the instance owns
  (task-0d75da311d16a94d, task-08fb01643e16ed4c).

  Every seam that talks to an instance as its admin decrypts through
  `Registry.reveal_admin_token/1` and sends the bearer to `bp.url`: the usage
  sampler, the instance-API proxy, update refresh, studio links, verify and the
  relays. So the token is decrypted only when a `hostname_claims` row for the
  url host is held by this barkpark. That is the managed hostname Cloud wrote
  at provisioning, or a custom host this row attached.
  """
  use BarkparkCloud.DataCase, async: true

  import ExUnit.CaptureLog

  alias BarkparkCloud.{Accounts, Registry, Usage}
  alias BarkparkCloud.Registry.{Barkpark, Vault}

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp barkpark_fixture(team, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, bp} =
      Registry.register_barkpark(team, Enum.into(attrs, %{name: "BP #{n}", slug: "bp-#{n}"}))

    bp
  end

  defp host, do: "xt-#{System.unique_integer([:positive])}.barkpark.cloud"

  defp with_token(bp, token) do
    bp
    |> Ecto.Changeset.change(admin_token_encrypted: Vault.encrypt(token))
    |> Repo.update!()
  end

  # A row that holds `url` and an admin token WITHOUT a url claim: a url host
  # nobody proved this row owns.
  defp row_with_unclaimed_url(url, token) do
    team_fixture()
    |> barkpark_fixture()
    |> Ecto.Changeset.change(url: url, admin_token_encrypted: Vault.encrypt(token))
    |> Repo.update!()
  end

  defp tap_withheld do
    me = self()
    handler = "xt-withheld-#{System.unique_integer([:positive])}"

    BarkparkCloud.TelemetryTap.attach(
      handler,
      [:barkpark_cloud, :registry, :admin_token_withheld],
      fn _e, _m, meta, _ -> send(me, {:withheld, meta}) end,
      nil
    )

    on_exit(fn -> BarkparkCloud.TelemetryTap.detach(handler) end)
  end

  test "a row whose url host another team claims gets no decrypted token" do
    h = host()

    customer = team_fixture() |> barkpark_fixture()
    assert {:ok, _} = Registry.set_custom_host(customer, h)

    ghost = row_with_unclaimed_url("https://" <> h, "ghost-admin-token")
    tap_withheld()

    log =
      capture_log(fn ->
        assert :error = Registry.reveal_admin_token(ghost)
        assert {:error, :decrypt_failed} = Usage.instance_admin_token(ghost)
      end)

    assert log =~ "WITHHELD"
    assert log =~ "reason=claimed_elsewhere"
    assert log =~ customer.id
    refute log =~ "ghost-admin-token"

    assert_receive {:withheld,
                    %{
                      barkpark_id: ghost_id,
                      claimed_by: claimed_by,
                      host: ^h,
                      reason: :claimed_elsewhere
                    }}

    assert ghost_id == ghost.id
    assert claimed_by == customer.id
  end

  test "a row whose url host nobody claims gets no decrypted token" do
    h = host()
    bp = row_with_unclaimed_url("https://" <> h, "unclaimed-token")
    tap_withheld()

    log =
      capture_log(fn ->
        assert :error = Registry.reveal_admin_token(bp)
        assert {:error, :decrypt_failed} = Usage.instance_admin_token(bp)
        refute Registry.owns_url_host?(bp)
      end)

    assert log =~ "WITHHELD"
    assert log =~ "reason=unclaimed"
    refute log =~ "unclaimed-token"
    assert_receive {:withheld, %{barkpark_id: id, host: ^h, reason: :unclaimed, claimed_by: nil}}
    assert id == bp.id
  end

  test "a row with no url gets no decrypted token" do
    bp = team_fixture() |> barkpark_fixture() |> with_token("no-url-token")

    log = capture_log(fn -> assert :error = Registry.reveal_admin_token(bp) end)
    assert log =~ "reason=no_url_host"
  end

  test "a struct that was never read from the database gets no decrypted token" do
    built = %Barkpark{
      id: Ecto.UUID.generate(),
      url: "https://" <> host(),
      admin_token_encrypted: Vault.encrypt("built-token")
    }

    log = capture_log(fn -> assert :error = Registry.reveal_admin_token(built) end)
    assert log =~ "reason=not_persisted"
  end

  test "its own managed hostname, claimed at provisioning, still decrypts" do
    h = host()

    bp =
      team_fixture()
      |> barkpark_fixture(%{url: "https://" <> h})
      |> with_token("own-token")

    assert Registry.owns_url_host?(bp)
    assert {:ok, "own-token"} = Registry.reveal_admin_token(bp)
    assert {:ok, "own-token"} = Usage.instance_admin_token(bp)
  end

  test "a custom host this row claimed still decrypts" do
    h = host()
    bp = row_with_unclaimed_url("https://" <> h, "custom-token")

    assert {:ok, bp} = Registry.set_custom_host(bp, h)
    assert {:ok, "custom-token"} = Registry.reveal_admin_token(bp)
  end

  test "a row with no admin token is unchanged" do
    bp = team_fixture() |> barkpark_fixture()
    assert {:ok, nil} = Registry.reveal_admin_token(bp)
  end

  test "the claim path refuses a host that is another row's url host, claimed or not" do
    h = host()
    # The other row holds a live credential for `h`, so its url is not abandoned.
    _other = row_with_unclaimed_url("https://" <> h, "other-token")

    taker = team_fixture() |> barkpark_fixture()

    capture_log(fn -> assert {:error, :taken} = Registry.set_custom_host(taker, h) end)
  end
end
