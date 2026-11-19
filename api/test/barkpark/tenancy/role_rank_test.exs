defmodule Barkpark.Tenancy.RoleRankTest do
  @moduledoc """
  `Tenancy.Auth.role_rank/2` (task-018e79d8734a1b08): the seat ladder access
  requests compare on. Built-ins rank with no DB read, custom roles by their
  actions in THIS workspace, and every malformed input ranks `0`.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Tenancy.{Role, RolePermission}
  alias Barkpark.Tenancy.Auth

  defp custom_role!(ws_id, name, actions) do
    {:ok, role} = Repo.insert(Role.changeset(%Role{}, %{name: name, workspace_id: ws_id}))

    for action <- actions,
        do:
          {:ok, _} =
            Repo.insert(
              RolePermission.changeset(%RolePermission{}, %{role_id: role.id, action: action})
            )
  end

  setup do
    ws = create_workspace!("rank-#{System.unique_integer([:positive])}")
    other = create_workspace!("rank-o-#{System.unique_integer([:positive])}")
    custom_role!(ws.id, "viewer", ~w(read))
    custom_role!(ws.id, "editor", ~w(read write))
    custom_role!(ws.id, "steward", ~w(read write admin))
    %{ws: ws.id, other: other.id}
  end

  test "built-ins: owner > admin > member > contributor", %{ws: ws} do
    assert Enum.map(~w(owner admin member contributor), &Auth.role_rank(&1, ws)) == [5, 4, 3, 2]
  end

  test "custom roles rank by their actions in this workspace", %{ws: ws} do
    assert Auth.role_rank("viewer", ws) == 1
    assert Auth.role_rank("editor", ws) == 3
    assert Auth.role_rank("steward", ws) == 4
  end

  test "another workspace's custom role ranks nothing here", %{other: other} do
    for name <- ~w(viewer editor steward), do: assert(Auth.role_rank(name, other) == 0)
  end

  test "unknown and malformed input ranks 0 and never raises", %{ws: ws} do
    assert Auth.role_rank("no-such-role", ws) == 0
    assert Auth.role_rank(nil, ws) == 0
    assert Auth.role_rank("admin", nil) == 0
    assert Auth.role_rank(:admin, ws) == 0
    # A custom name with a malformed workspace id resolves no row; a built-in
    # keeps its workspace-independent rung, like `role_permits?/3`.
    assert Auth.role_rank("editor", "zzz") == 0
    assert Auth.role_rank("member", "zzz") == 3
  end
end
