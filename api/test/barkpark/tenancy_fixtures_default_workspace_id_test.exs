defmodule Barkpark.TenancyFixturesDefaultWorkspaceIdTest do
  @moduledoc """
  `TenancyFixtures.default_workspace_id!/0` — the suite's explicit name for the
  instance-default scope that a bare 4-arity `Auth.create_token/4` has been
  getting implicitly.

  Both arms matter equally. The happy arm proves it returns the SEATED default
  and not merely "some workspace"; the refuse arm proves that on a vacant seat
  it raises instead of handing back `nil`, because a `nil` workspace_id is not
  an error at the mint — it is a workspace-less token whose 403 surfaces a test
  file away from the fixture that caused it.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Tenancy

  describe "default_workspace_id!/0" do
    test "returns the id of the workspace holding the instance-default seat" do
      {ws, _project} = ensure_default_scope!()

      id = default_workspace_id!()

      assert is_binary(id)
      assert id == ws.id
      # Not merely "a workspace": the one the seat actually points at.
      assert id == Tenancy.get_default_workspace().id
    end

    test "raises, rather than returning nil, when no workspace holds the seat" do
      ensure_default_scope!()
      # Precondition, asserted rather than assumed: the seat is taken BEFORE we
      # vacate it, so a passing refuse arm cannot be a vacuously empty database.
      assert Tenancy.get_default_workspace() != nil

      vacate_default_seat!()
      assert Tenancy.get_default_workspace() == nil

      assert_raise RuntimeError, ~r/instance-default seat/, fn ->
        default_workspace_id!()
      end
    end

    test "the raise names what it looked for" do
      ensure_default_scope!()
      vacate_default_seat!()

      error = assert_raise(RuntimeError, fn -> default_workspace_id!() end)
      message = error.message

      assert message =~ "default_workspace_id!/0"
      assert message =~ "workspaces.is_default == true"
      assert message =~ "Barkpark.Tenancy.get_default_workspace/0"
    end
  end
end
