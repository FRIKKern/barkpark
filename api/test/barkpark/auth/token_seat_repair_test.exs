defmodule Barkpark.Auth.TokenSeatRepairTest do
  @moduledoc """
  `mix barkpark.token_seat`: the server-side repair that seats an existing
  API token in more workspaces (`Barkpark.Auth.TokenSeatRepair`,
  task-86e3a3a0c885097a).
  """
  use Barkpark.DataCase, async: true

  import Ecto.Query
  import ExUnit.CaptureIO
  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Repo}
  alias Barkpark.Audit.Event
  alias Barkpark.Auth.TokenSeatRepair
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.Tenancy.Membership

  setup do
    home = create_workspace!("seat-home-#{System.unique_integer([:positive])}")
    a = create_workspace!("seat-a-#{System.unique_integer([:positive])}")
    b = create_workspace!("seat-b-#{System.unique_integer([:positive])}")

    raw = "seat-#{System.unique_integer([:positive])}"

    {:ok, token} =
      Auth.create_token(
        raw,
        "barkpark cloud admin",
        "production",
        ["read", "write", "admin"],
        home.id
      )

    %{home: home, a: a, b: b, token: token}
  end

  defp seats(token_id) do
    Repo.all(
      from m in Membership,
        where: m.principal_type == "api_token" and m.principal_id == ^token_id,
        select: {m.workspace_id, m.role}
    )
    |> Enum.sort()
  end

  test "a dry run writes nothing", ctx do
    assert {:ok, plan} = TokenSeatRepair.seat(ctx.token.id, [ctx.a.slug, ctx.home.slug])
    assert plan.seat == [ctx.a.slug]
    assert plan.already == [ctx.home.slug]
    assert plan.role == "admin"
    assert seats(ctx.token.id) == [{ctx.home.id, "admin"}]
  end

  test "--apply seats the token with the role its permissions give, and audits each seat",
       ctx do
    assert {:ok, _} = TokenSeatRepair.seat(ctx.token.id, [ctx.a.slug, ctx.b.slug], apply: true)

    assert seats(ctx.token.id) ==
             Enum.sort([{ctx.home.id, "admin"}, {ctx.a.id, "admin"}, {ctx.b.id, "admin"}])

    assert TenancyAuth.workspace_admin?(ctx.token.id, ctx.a.id)

    events =
      Repo.all(from e in Event, where: e.action == "token_seated" and e.subject == ^ctx.token.id)

    assert Enum.sort(Enum.map(events, & &1.workspace_id)) == Enum.sort([ctx.a.id, ctx.b.id])
    assert Enum.all?(events, &(&1.metadata["role"] == "admin"))
  end

  test "a second run changes nothing", ctx do
    assert {:ok, _} = TokenSeatRepair.seat(ctx.token.id, [ctx.a.slug], apply: true)
    assert {:ok, plan} = TokenSeatRepair.seat(ctx.token.id, [ctx.a.slug], apply: true)
    assert plan.seat == []
    assert plan.already == [ctx.a.slug]
  end

  test "an unknown workspace refuses the whole run", ctx do
    assert {:error, {:unknown_workspace, "nope"}} =
             TokenSeatRepair.seat(ctx.token.id, [ctx.a.slug, "nope"], apply: true)

    assert seats(ctx.token.id) == [{ctx.home.id, "admin"}]
  end

  test "a revoked token is refused", ctx do
    {:ok, _} = Auth.revoke_token(ctx.token)

    assert {:error, :token_not_live} =
             TokenSeatRepair.seat(ctx.token.id, [ctx.a.slug], apply: true)
  end

  test "an unknown token id is refused", ctx do
    assert {:error, :token_not_found} =
             TokenSeatRepair.seat(Ecto.UUID.generate(), [ctx.a.slug], apply: true)
  end

  test "the cli prints ids, slugs and the role, and exits 0", ctx do
    out =
      capture_io(fn ->
        assert TokenSeatRepair.cli([
                 "--token",
                 ctx.token.id,
                 "--workspace",
                 ctx.a.slug,
                 "--workspace",
                 ctx.b.slug,
                 "--apply"
               ]) == 0
      end)

    assert out =~ ctx.token.id
    assert out =~ "Seated: #{ctx.a.slug}, #{ctx.b.slug}"
  end

  test "the cli without --token is a usage error" do
    capture_io(:stderr, fn -> assert TokenSeatRepair.cli(["--workspace", "x"]) == 2 end)
  end
end
