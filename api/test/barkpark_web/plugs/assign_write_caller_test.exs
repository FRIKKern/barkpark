defmodule BarkparkWeb.Plugs.AssignWriteCallerTest do
  @moduledoc """
  The `:ingest` pipeline's `WriteCaller` and the Bulldocs write rule that
  judges it (`WriteGate.may_write?/2`):

    * `may_write_in` answers what `Tenancy.Auth.authorize(token, ws, :write)`
      answers, for a seat with write, a read-only seat, no seat, a token
      without write permission, and a user-owned token whose owner may not
      write;
    * one row per caller the `:ingest` routes carry: a pinned token, a
      workspace-less token, a user-owned one, a saved row with no workspace;
    * home alone is not permission: a pinned token without write permission
      may not write in its home;
    * anything but a `WriteCaller` is refused: a bare map with its fields, the
      token itself, a `%Document{}` or `%Membership{}` carrying a workspace id.
  """
  use Barkpark.DataCase, async: false

  import Plug.Test, only: [conn: 2]

  alias Barkpark.{AccountsFixtures, Auth, Repo, Tenancy, TenancyFixtures}
  alias Barkpark.Content.Document
  alias Barkpark.Plugins.Bulldocs.Web.WriteGate
  alias Barkpark.Tenancy.{Membership, Role, RolePermission, WriteCaller}
  alias BarkparkWeb.Plugs.AssignWriteCaller

  @ds "production"

  defp ws!, do: TenancyFixtures.create_workspace!().id

  defp token!(ws_id, perms \\ ["admin"]) do
    raw = "write-caller-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "write caller", @ds, perms, ws_id)
    token
  end

  defp seat!(ws_id, principal_id, role, kind \\ "api_token") do
    {:ok, _} = Tenancy.Auth.create_membership(ws_id, principal_id, role, kind)
    :ok
  end

  defp read_role!(ws_id) do
    {:ok, role} = Repo.insert(Role.changeset(%Role{}, %{name: "reader", workspace_id: ws_id}))
    perm = RolePermission.changeset(%RolePermission{}, %{role_id: role.id, action: "read"})
    {:ok, _} = Repo.insert(perm)
    "reader"
  end

  defp owned!(token, ws_id, owner_role) do
    user = AccountsFixtures.register_user("wc-#{System.unique_integer([:positive])}@example.com")
    seat!(ws_id, user.id, owner_role, "user")
    token |> Ecto.Changeset.change(owner_user_id: user.id) |> Repo.update!()
  end

  defp arm(ids) do
    prev = Application.get_env(:barkpark, :operator_token_ids, [])
    Application.put_env(:barkpark, :operator_token_ids, ids)
    on_exit(fn -> Application.put_env(:barkpark, :operator_token_ids, prev) end)
  end

  defp caller(token), do: AssignWriteCaller.build(token)
  defp writes?(token, ws_id), do: Tenancy.Auth.authorize(token, ws_id, :write) == :ok

  test "may_write_in answers what authorize answers for write, in five cases" do
    ws = ws!()
    seated = token!(nil)
    seat!(ws, seated.id, "member")
    read_only = token!(nil)
    seat!(ws, read_only.id, read_role!(ws))
    no_seat = token!(nil)
    read_perm = token!(nil, ["read"])
    seat!(ws, read_perm.id, "member")
    owner_reads = token!(nil)
    seat!(ws, owner_reads.id, "member")
    owner_reads = owned!(owner_reads, ws, "reader")

    cases = [
      {"a seat with write", seated, true},
      {"a read-only seat", read_only, false},
      {"no seat", no_seat, false},
      {"a token without write permission", read_perm, false},
      {"a user-owned token whose owner may not write", owner_reads, false}
    ]

    assert for({name, token, want} <- cases, writes?(token, ws) != want, do: name) == []

    assert for(
             {name, token, _want} <- cases,
             caller(token).may_write_in.(ws) != writes?(token, ws),
             do: name
           ) == []
  end

  test "a pinned token writes in its home, elsewhere only by a seat or an armed allowlist" do
    home = ws!()
    other = ws!()
    token = token!(home)

    assert WriteGate.may_write?(caller(token), home)
    refute WriteGate.may_write?(caller(token), other)

    seat!(other, token.id, "member")
    assert WriteGate.may_write?(caller(token), other)

    third = ws!()
    arm([token.id])
    assert WriteGate.may_write?(caller(token), third)
  end

  test "a pinned token without write permission may not write in its home" do
    home = ws!()
    token = token!(home, ["read"])
    assert caller(token).home == home
    refute caller(token).may_write?
    refute WriteGate.may_write?(caller(token), home)
  end

  test "a workspace-less token writes only where a seat allows it" do
    a = ws!()
    b = ws!()
    token = token!(nil)
    seat!(a, token.id, "member")

    assert caller(token).home == nil
    assert WriteGate.may_write?(caller(token), a)
    refute WriteGate.may_write?(caller(token), b)
  end

  test "a user-owned workspace-less token writes only where its owner may write too" do
    ws = ws!()
    writer = token!(nil)
    seat!(ws, writer.id, "member")
    writer = owned!(writer, ws, "member")
    assert WriteGate.may_write?(caller(writer), ws)

    reader = token!(nil)
    seat!(ws, reader.id, "member")
    reader = owned!(reader, ws, read_role!(ws))
    refute WriteGate.may_write?(caller(reader), ws)
  end

  test "no caller writes in a row with no workspace" do
    token = token!(ws!())
    arm([token.id])
    refute WriteGate.may_write?(caller(token), nil)
  end

  test "anything but a WriteCaller is refused, a look-alike map included" do
    ws = ws!()
    token = token!(ws)
    arm([token.id])
    look_alike = Map.from_struct(caller(token))

    for value <- [
          look_alike,
          Map.put(look_alike, :workspace_id, ws),
          token,
          %Document{workspace_id: ws},
          %Membership{workspace_id: ws},
          %{workspace_id: ws}
        ] do
      refute WriteGate.may_write?(value, ws), inspect(value)
      refute WriteGate.write_check(%{write_caller: value}).(ws)
    end

    assert WriteGate.may_write?(caller(token), ws)
  end

  test "the write check: the caller's rule, a refusal with no caller, nil without a token" do
    ws = ws!()
    token = token!(ws)
    assert WriteGate.write_check(%{write_caller: caller(token), api_token: token}).(ws)
    refute WriteGate.write_check(%{api_token: token}).(ws)
    assert WriteGate.write_check(%{}) == nil
  end

  test "the plug assigns a WriteCaller for a token and nothing without one" do
    token = token!(ws!())

    assigned =
      conn(:post, "/")
      |> Plug.Conn.assign(:api_token, token)
      |> AssignWriteCaller.call([])

    assert %WriteCaller{home: home, may_write?: true, operator?: false} =
             assigned.assigns.write_caller

    assert home == token.workspace_id
    refute Map.has_key?(AssignWriteCaller.call(conn(:post, "/"), []).assigns, :write_caller)
  end
end
