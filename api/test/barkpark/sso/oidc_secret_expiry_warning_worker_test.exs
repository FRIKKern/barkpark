defmodule Barkpark.Sso.OidcSecretExpiryWarningWorkerTest do
  # async: false: the operator list is Application env.
  use Barkpark.DataCase, async: false

  import Barkpark.AccountsFixtures

  alias Barkpark.Sso.{Oidc, OidcConnection}
  alias Barkpark.Sso.OidcSecretExpiryWarningWorker, as: Worker
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @day 86_400
  @now ~U[2026-11-01 08:00:00Z]

  setup do
    prev = Application.fetch_env(:barkpark, :operator_emails)
    Application.put_env(:barkpark, :operator_emails, [" Operator@Example.com "])

    on_exit(fn ->
      case prev do
        {:ok, v} -> Application.put_env(:barkpark, :operator_emails, v)
        :error -> Application.delete_env(:barkpark, :operator_emails)
      end
    end)

    n = System.unique_integer([:positive])
    {:ok, org} = Tenancy.create_organization(%{slug: "osx-#{n}", name: "Secret Org"})
    {:ok, ws} = Tenancy.create_workspace(%{slug: "osx-ws-#{n}", name: "Secret WS"})
    {:ok, _} = Tenancy.assign_workspace_to_organization(ws, org.id)

    owner = register_user("owner-#{n}@example.com")
    member = register_user("member-#{n}@example.com")
    {:ok, _} = TenancyAuth.create_membership(ws.id, owner.id, "owner", "user")
    {:ok, _} = TenancyAuth.create_membership(ws.id, member.id, "member", "user")

    %{org: org, owner: owner}
  end

  defp connection(org, expires_at) do
    {:ok, c} =
      Oidc.create_connection(%{
        organization_id: org.id,
        issuer: "https://login.example.com/t/v2.0",
        client_id: "client-1",
        client_secret: "s3cret",
        client_secret_expires_at: expires_at
      })

    c
  end

  defp mails do
    receive do
      {:email, email} -> [email | mails()]
    after
      0 -> []
    end
  end

  test "warns once at 30, 14 and 7 days, to the operators and the org's workspace owners", %{
    org: org,
    owner: owner
  } do
    c = connection(org, DateTime.add(@now, 30 * @day, :second))

    sent =
      for day <- 0..29 do
        Worker.run(DateTime.add(@now, day * @day, :second))
        {day, mails()}
      end

    warned = for {day, [_ | _] = ms} <- sent, do: {day, length(ms), hd(ms).subject}

    assert warned == [
             {0, 2,
              ~s(Barkpark sign-in for "#{org.slug}": the OIDC client secret expires in 30 days)},
             {16, 2,
              ~s(Barkpark sign-in for "#{org.slug}": the OIDC client secret expires in 14 days)},
             {23, 2,
              ~s(Barkpark sign-in for "#{org.slug}": the OIDC client secret expires in 7 days)}
           ]

    to = for {_day, ms} <- sent, m <- ms, {_, addr} <- m.to, uniq: true, do: addr
    assert Enum.sort(to) == Enum.sort(["operator@example.com", String.downcase(owner.email)])

    [body | _] = for {_d, ms} <- sent, m <- ms, do: m.text_body
    assert body =~ "bp org oidc-rotate-secret #{org.slug}"
    refute body =~ "s3cret"

    assert Repo.get!(OidcConnection, c.id).client_secret_expiry_warned_days == 7
  end

  test "a date recorded 10 days out gets the 14-day warning once, then the 7-day one", %{org: org} do
    connection(org, DateTime.add(@now, 10 * @day, :second))

    assert Worker.run(@now) == %{warned: 1, failed: 0}
    assert [_, _] = mails()
    assert Worker.run(DateTime.add(@now, @day, :second)) == %{warned: 0, failed: 0}
    assert mails() == []
    assert Worker.run(DateTime.add(@now, 3 * @day, :second)) == %{warned: 1, failed: 0}
  end

  test "a new date starts the steps again", %{org: org} do
    c = connection(org, DateTime.add(@now, 5 * @day, :second))
    assert Worker.run(@now) == %{warned: 1, failed: 0}
    mails()

    {:ok, _} =
      Oidc.update_connection(c, %{
        client_secret: "new",
        client_secret_expires_at: DateTime.add(@now, 365 * @day, :second)
      })

    assert Repo.get!(OidcConnection, c.id).client_secret_expiry_warned_days == nil
    assert Worker.run(@now) == %{warned: 0, failed: 0}
    assert Worker.run(DateTime.add(@now, 336 * @day, :second)) == %{warned: 1, failed: 0}
  end

  test "no date, a date past the horizon, a passed date or an inactive connection sends nothing",
       %{org: org} do
    c = connection(org, nil)
    assert Worker.run(@now) == %{warned: 0, failed: 0}

    for at <- [DateTime.add(@now, 31 * @day, :second), DateTime.add(@now, -@day, :second)] do
      {:ok, _} = Oidc.update_connection(c, %{client_secret_expires_at: at})
      assert Worker.run(@now) == %{warned: 0, failed: 0}
    end

    {:ok, _} =
      Oidc.update_connection(Repo.get!(OidcConnection, c.id), %{
        client_secret_expires_at: DateTime.add(@now, 3 * @day, :second),
        active: false
      })

    assert Worker.run(@now) == %{warned: 0, failed: 0}
    assert mails() == []
  end

  test "perform/1 is a no-op while the token expiry warnings switch is off", %{org: org} do
    connection(org, DateTime.add(DateTime.utc_now(), 3 * @day, :second))
    prev = Application.get_env(:barkpark, :token_expiry_warnings)
    Application.put_env(:barkpark, :token_expiry_warnings, enabled: false)
    on_exit(fn -> Application.put_env(:barkpark, :token_expiry_warnings, prev) end)

    assert Worker.perform(%Oban.Job{}) == {:ok, %{skipped: :disabled}}
    assert mails() == []

    Application.put_env(:barkpark, :token_expiry_warnings, enabled: true)
    assert Worker.perform(%Oban.Job{}) == {:ok, %{warned: 1, failed: 0}}
  end
end
