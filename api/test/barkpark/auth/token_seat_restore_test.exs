defmodule Barkpark.Auth.TokenSeatRestoreTest do
  @moduledoc """
  `Barkpark.Auth.TokenSeatRestore` (task-c6185553d0bd7869): a token gets back
  only the seats a revoked predecessor held, read from the box's own
  `token_minted` audit rows.
  """
  use Barkpark.DataCase, async: true

  import Ecto.Query
  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Repo}
  alias Barkpark.Audit.Event
  alias Barkpark.Auth.TokenSeatRestore
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.Tenancy.Membership

  @admin ["read", "write", "admin"]

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  setup do
    home = create_workspace!(uniq("rs-home"))
    a = create_workspace!(uniq("rs-a"))
    b = create_workspace!(uniq("rs-b"))
    other = create_workspace!(uniq("rs-other"))

    # The predecessor: admin in home and a, member in b, nothing in other.
    {:ok, old} =
      Auth.create_token(uniq("old"), "barkpark cloud admin", "production", @admin, home.id)

    {:ok, _} = TenancyAuth.create_membership(a.id, old.id, "admin", "api_token")
    {:ok, _} = TenancyAuth.create_membership(b.id, old.id, "member", "api_token")

    %{home: home, a: a, b: b, other: other, old: old}
  end

  # The pre-#24619 rotation: the old token mints a successor in home only and
  # then revokes itself.
  defp rotate(old, home) do
    {:ok, {_raw, new}} =
      Auth.mint_delegated_token(old, home.id, label: "barkpark cloud admin", permissions: @admin)

    {:ok, _} = Auth.revoke_token(old, old)
    new
  end

  defp seats(token_id) do
    Repo.all(
      from m in Membership,
        join: w in assoc(m, :workspace),
        where: m.principal_type == "api_token" and m.principal_id == ^token_id,
        select: {w.slug, m.role}
    )
    |> Enum.sort()
  end

  test "a dry run plans the predecessor's seats and writes nothing", ctx do
    new = rotate(ctx.old, ctx.home)
    before = seats(new.id)

    assert {:ok, plan} = TokenSeatRestore.restore(new.id, [ctx.a.slug, ctx.b.slug, ctx.home.slug])
    assert plan.predecessors == [ctx.old.id]
    refute plan.applied

    assert Enum.map(plan.restore, &{&1.workspace, &1.role, &1.from_token}) == [
             {ctx.a.slug, "admin", ctx.old.id},
             {ctx.b.slug, "member", ctx.old.id}
           ]

    assert plan.already == [ctx.home.slug]
    assert plan.refused == []
    assert seats(new.id) == before
  end

  test "no workspaces named plans every seat a predecessor held", ctx do
    new = rotate(ctx.old, ctx.home)
    assert {:ok, plan} = TokenSeatRestore.restore(new.id, [])

    assert Enum.sort(Enum.map(plan.restore, & &1.workspace)) ==
             Enum.sort([ctx.a.slug, ctx.b.slug])

    assert plan.already == [ctx.home.slug]
  end

  test "apply seats the token, caps the role at the predecessor's, and audits each seat",
       ctx do
    new = rotate(ctx.old, ctx.home)

    assert {:ok, plan} =
             TokenSeatRestore.restore(new.id, [ctx.a.slug, ctx.b.slug], apply: true, actor: new)

    assert plan.applied

    assert seats(new.id) ==
             Enum.sort([{ctx.home.slug, "admin"}, {ctx.a.slug, "admin"}, {ctx.b.slug, "member"}])

    events =
      Repo.all(from e in Event, where: e.action == "token_seated" and e.subject == ^new.id)

    assert length(events) == 2
    assert Enum.all?(events, &(&1.actor_type == "api_token" and &1.actor_id == new.id))
    assert Enum.all?(events, &(&1.metadata["restored_from"] == ctx.old.id))

    # A second apply changes nothing.
    assert {:ok, again} = TokenSeatRestore.restore(new.id, [ctx.a.slug], apply: true)
    assert again.restore == []
    assert again.already == [ctx.a.slug]
  end

  test "a workspace no predecessor held is refused, and an apply then writes nothing", ctx do
    new = rotate(ctx.old, ctx.home)

    assert {:ok, plan} = TokenSeatRestore.restore(new.id, [ctx.a.slug, ctx.other.slug])
    assert plan.refused == [%{workspace: ctx.other.slug, reason: "not_held_before"}]

    assert {:error, {:refused, _}} =
             TokenSeatRestore.restore(new.id, [ctx.a.slug, ctx.other.slug], apply: true)

    assert seats(new.id) == [{ctx.home.slug, "admin"}]
  end

  test "an unknown workspace is refused by name", ctx do
    new = rotate(ctx.old, ctx.home)
    assert {:ok, plan} = TokenSeatRestore.restore(new.id, ["no-such-ws"])
    assert plan.refused == [%{workspace: "no-such-ws", reason: "unknown_workspace"}]
  end

  test "a child of a live parent gets none of the parent's seats", ctx do
    {:ok, {_raw, child}} =
      Auth.mint_delegated_token(ctx.old, ctx.home.id, label: "child", permissions: @admin)

    assert {:ok, plan} = TokenSeatRestore.restore(child.id, [ctx.a.slug])
    assert plan.predecessors == []
    assert plan.refused == [%{workspace: ctx.a.slug, reason: "not_held_before"}]
    assert {:error, {:refused, _}} = TokenSeatRestore.restore(child.id, [ctx.a.slug], apply: true)
  end

  test "a token with no mint row has no predecessor", ctx do
    {:ok, plain} = Auth.create_token(uniq("plain"), "plain", "production", @admin, ctx.home.id)

    assert {:ok, %{predecessors: [], refused: [_]}} =
             TokenSeatRestore.restore(plain.id, [ctx.a.slug])
  end

  test "the walk crosses two rotations", ctx do
    middle = rotate(ctx.old, ctx.home)
    newest = rotate(middle, ctx.home)

    assert {:ok, plan} = TokenSeatRestore.restore(newest.id, [ctx.a.slug])
    assert plan.predecessors == [middle.id, ctx.old.id]
    assert [%{workspace: slug, from_token: from}] = plan.restore
    assert slug == ctx.a.slug
    assert from == ctx.old.id
  end

  test "a write token gets member seats only", ctx do
    {:ok, {_raw, writer}} =
      Auth.mint_delegated_token(ctx.old, ctx.home.id, label: "w", permissions: ["read", "write"])

    {:ok, _} = Auth.revoke_token(ctx.old, ctx.old)

    assert {:ok, plan} = TokenSeatRestore.restore(writer.id, [ctx.a.slug])
    assert [%{role: "member"}] = plan.restore
  end

  test "a revoked or unknown target is refused", ctx do
    new = rotate(ctx.old, ctx.home)
    assert {:error, :token_not_live} = TokenSeatRestore.restore(ctx.old.id, [ctx.a.slug])
    assert {:error, :token_not_found} = TokenSeatRestore.restore(Ecto.UUID.generate(), [])
    assert {:error, :token_not_found} = TokenSeatRestore.restore("nope", [])
    assert {:ok, _} = TokenSeatRestore.restore(new.id, [])
  end
end
