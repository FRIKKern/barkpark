defmodule Barkpark.Auth.TokenExpiryWarningWorkerTest do
  use Barkpark.DataCase, async: true

  import Barkpark.AccountsFixtures

  alias Barkpark.Auth.ApiToken
  alias Barkpark.Auth.TokenExpiryWarningWorker, as: Worker
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @day 86_400

  setup do
    {:ok, ws} =
      Tenancy.create_workspace(%{slug: "tew-" <> Ecto.UUID.generate(), name: "Expiry WS"})

    owner = register_user("owner-#{System.unique_integer([:positive])}@example.com")
    member = register_user("member-#{System.unique_integer([:positive])}@example.com")
    {:ok, _} = TenancyAuth.create_membership(ws.id, owner.id, "owner", "user")
    {:ok, _} = TenancyAuth.create_membership(ws.id, member.id, "member", "user")

    %{ws: ws, owner: owner, member: member}
  end

  defp token(ws, expires_at, attrs \\ %{}) do
    %ApiToken{}
    |> ApiToken.changeset(
      Map.merge(
        %{
          token_hash: ApiToken.hash_token(Ecto.UUID.generate()),
          label: "catalogue publisher",
          permissions: ["read"],
          workspace_id: ws.id,
          expires_at: DateTime.truncate(expires_at, :second)
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp mails do
    receive do
      {:email, email} -> [email | mails()]
    after
      0 -> []
    end
  end

  test "warns once at 14, 7 and 1 days, to the workspace owner only", %{ws: ws, owner: owner} do
    now = ~U[2026-11-01 08:00:00Z]
    t = token(ws, DateTime.add(now, 14 * @day, :second))

    # Day by day until expiry: exactly three warnings, one per step.
    sent =
      for day <- 0..13 do
        Worker.run(DateTime.add(now, day * @day, :second))
        {day, mails()}
      end

    warned = for {day, [_ | _] = ms} <- sent, do: {day, Enum.map(ms, & &1.subject)}

    assert warned == [
             {0, [~s(Barkpark API token "catalogue publisher" expires in 14 days)]},
             {7, [~s(Barkpark API token "catalogue publisher" expires in 7 days)]},
             {13, [~s(Barkpark API token "catalogue publisher" expires in 1 day)]}
           ]

    for {_day, ms} <- sent, m <- ms, do: assert(m.to == [{"", owner.email}])
    assert Repo.get!(ApiToken, t.id).expiry_warned_days == 1
  end

  test "a token minted 5 days before expiry gets the 7-day warning once", %{ws: ws} do
    now = ~U[2026-11-01 08:00:00Z]
    token(ws, DateTime.add(now, 5 * @day, :second))

    assert Worker.run(now) == %{warned: 1, failed: 0}
    assert [%{subject: subject}] = mails()
    assert subject =~ "expires in 7 days"

    assert Worker.run(DateTime.add(now, @day, :second)) == %{warned: 0, failed: 0}
    assert mails() == []
  end

  test "the token's owner user is warned with the admins", %{ws: ws, owner: owner} do
    now = ~U[2026-11-01 08:00:00Z]
    holder = register_user("holder-#{System.unique_integer([:positive])}@example.com")
    token(ws, DateTime.add(now, @day, :second), %{owner_user_id: holder.id})

    Worker.run(now)
    to = mails() |> Enum.flat_map(& &1.to) |> Enum.map(&elem(&1, 1)) |> Enum.sort()
    assert to == Enum.sort([owner.email, holder.email])
  end

  test "revoked, unexpiring and far-off tokens are not warned", %{ws: ws} do
    now = ~U[2026-11-01 08:00:00Z]
    token(ws, DateTime.add(now, @day, :second), %{revoked_at: DateTime.truncate(now, :second)})
    token(ws, DateTime.add(now, 15 * @day, :second))

    %ApiToken{}
    |> ApiToken.changeset(%{token_hash: ApiToken.hash_token("never"), workspace_id: ws.id})
    |> Repo.insert!()

    assert Worker.run(now) == %{warned: 0, failed: 0}
    assert mails() == []
  end

  test "perform/1 sends nothing while the switch is off", %{ws: ws} do
    token(ws, DateTime.add(DateTime.utc_now(), @day, :second))

    refute Worker.enabled?()
    assert Worker.perform(%Oban.Job{}) == {:ok, %{skipped: :disabled}}
    assert mails() == []
  end
end
