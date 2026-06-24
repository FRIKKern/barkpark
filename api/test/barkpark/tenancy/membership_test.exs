defmodule Barkpark.Tenancy.MembershipTest do
  use Barkpark.DataCase, async: true

  alias Barkpark.Tenancy.Membership

  # ---------------------------------------------------------------------------
  # roles/0
  # ---------------------------------------------------------------------------

  describe "roles/0" do
    test "returns the three expected role strings" do
      assert Membership.roles() == ~w(owner admin member)
    end

    test "returns a list of strings" do
      roles = Membership.roles()
      assert is_list(roles)
      assert Enum.all?(roles, &is_binary/1)
    end
  end

  # ---------------------------------------------------------------------------
  # changeset/2 — valid attrs
  # ---------------------------------------------------------------------------

  describe "changeset/2 — valid attrs" do
    test "accepts all required fields with a valid role" do
      workspace_id = Ecto.UUID.generate()
      principal_id = Ecto.UUID.generate()

      cs =
        Membership.changeset(%Membership{}, %{
          workspace_id: workspace_id,
          principal_id: principal_id,
          role: "owner"
        })

      # assoc_constraint fires at DB level; pure cast+validate passes
      assert cs.valid?
    end

    test "accepts all three valid roles" do
      workspace_id = Ecto.UUID.generate()
      principal_id = Ecto.UUID.generate()

      for role <- ~w(owner admin member) do
        cs =
          Membership.changeset(%Membership{}, %{
            workspace_id: workspace_id,
            principal_id: principal_id,
            role: role
          })

        assert cs.valid?, "expected role #{inspect(role)} to be valid"
      end
    end

    test "defaults principal_type to api_token when omitted" do
      cs =
        Membership.changeset(%Membership{}, %{
          workspace_id: Ecto.UUID.generate(),
          principal_id: Ecto.UUID.generate(),
          role: "member"
        })

      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :principal_type) == "api_token"
    end

    test "accepts explicit api_token principal_type" do
      cs =
        Membership.changeset(%Membership{}, %{
          workspace_id: Ecto.UUID.generate(),
          principal_id: Ecto.UUID.generate(),
          principal_type: "api_token",
          role: "admin"
        })

      assert cs.valid?
    end
  end

  # ---------------------------------------------------------------------------
  # changeset/2 — required field guards
  # ---------------------------------------------------------------------------

  describe "changeset/2 — required fields" do
    test "requires workspace_id" do
      cs =
        Membership.changeset(%Membership{}, %{
          principal_id: Ecto.UUID.generate(),
          role: "member"
        })

      refute cs.valid?
      assert "can't be blank" in errors_on(cs).workspace_id
    end

    test "requires principal_id" do
      cs =
        Membership.changeset(%Membership{}, %{
          workspace_id: Ecto.UUID.generate(),
          role: "member"
        })

      refute cs.valid?
      assert "can't be blank" in errors_on(cs).principal_id
    end

    test "requires role" do
      cs =
        Membership.changeset(%Membership{}, %{
          workspace_id: Ecto.UUID.generate(),
          principal_id: Ecto.UUID.generate()
        })

      refute cs.valid?
      assert "can't be blank" in errors_on(cs).role
    end
  end

  # ---------------------------------------------------------------------------
  # changeset/2 — inclusion validation
  # ---------------------------------------------------------------------------

  describe "changeset/2 — role inclusion" do
    test "rejects an unknown role" do
      cs =
        Membership.changeset(%Membership{}, %{
          workspace_id: Ecto.UUID.generate(),
          principal_id: Ecto.UUID.generate(),
          role: "superuser"
        })

      refute cs.valid?
      assert errors_on(cs).role != []
    end

    test "rejects an unknown principal_type" do
      cs =
        Membership.changeset(%Membership{}, %{
          workspace_id: Ecto.UUID.generate(),
          principal_id: Ecto.UUID.generate(),
          principal_type: "oauth_user",
          role: "member"
        })

      refute cs.valid?
      assert errors_on(cs).principal_type != []
    end
  end
end
