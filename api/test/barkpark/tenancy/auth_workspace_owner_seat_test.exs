defmodule Barkpark.Tenancy.AuthWorkspaceOwnerSeatTest do
  @moduledoc """
  `Barkpark.Tenancy.Auth.workspace_owner?/2` — the OWNER-ONLY SEAT.

  It exists because chat-host enrollment spelled its rule as a literal
  `membership_role(principal, ws) == "owner"` in TWO mirrored places (the
  Studio `ChatHostsLive` `:enroll` arm and
  `ChatHostController.create_enrollment/2`) with nothing tying them together —
  `arpss-w10-bl-chat-hosts-owner-literal-seat-fork`. Those sites now call this
  predicate; this file pins what the predicate MEANS, so a future loosening has
  to be made HERE, once, in the open — which is the whole point of moving it to
  the chokepoint.

  The load-bearing claim is the NARROWNESS: `workspace_owner?/2` must stay
  strictly narrower than `workspace_admin?/2`. It can only ever DENY where the
  admin gate admits; it must never become a way to ADMIT someone the admin gate
  refuses. The `admin` row below is the cell that proves the two predicates
  have not been quietly unified.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth

  defp workspace!(slug) do
    {:ok, ws} = Tenancy.create_workspace(%{slug: slug, name: slug})
    ws
  end

  # Every token here carries GLOBAL admin permissions. The seat must come from
  # the membership ROLE and nothing else, so holding "admin" globally is the
  # control that proves permissions[] is not leaking into the answer.
  defp token! do
    {:ok, token} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token("t-" <> Ecto.UUID.generate()),
        label: "l",
        dataset: "test",
        permissions: ["read", "write", "admin"]
      })
      |> Repo.insert()

    token
  end

  defp seated!(ws, role) do
    token = token!()
    {:ok, _} = Auth.create_membership(ws.id, token.id, role)
    token
  end

  describe "workspace_owner?/2" do
    test "true for owner, false for admin and member — strictly narrower than workspace_admin?/2" do
      ws = workspace!("owner-seat-#{System.unique_integer([:positive])}")

      owner = seated!(ws, "owner")
      admin = seated!(ws, "admin")
      member = seated!(ws, "member")

      assert Auth.workspace_owner?(owner, ws.id)
      refute Auth.workspace_owner?(admin, ws.id)
      refute Auth.workspace_owner?(member, ws.id)

      # The narrowness, stated as a relation and not as three separate facts:
      # every principal the owner seat admits is also a workspace admin, and the
      # `admin` row is admitted by one and refused by the other.
      assert Auth.workspace_admin?(owner, ws.id)
      assert Auth.workspace_admin?(admin, ws.id)
      refute Auth.workspace_admin?(member, ws.id)
    end

    test "a NON-MEMBER is never an owner, even holding global admin permissions" do
      ws = workspace!("owner-seat-nonmember-#{System.unique_integer([:positive])}")
      outsider = token!()

      refute Auth.workspace_owner?(outsider, ws.id)
      refute Auth.workspace_admin?(outsider, ws.id)
    end

    test "an owner of ANOTHER workspace is not an owner here — the seat is per-workspace" do
      a = workspace!("owner-seat-a-#{System.unique_integer([:positive])}")
      b = workspace!("owner-seat-b-#{System.unique_integer([:positive])}")
      owner_of_a = seated!(a, "owner")

      assert Auth.workspace_owner?(owner_of_a, a.id)
      refute Auth.workspace_owner?(owner_of_a, b.id)
    end

    test "DENIES on malformed or absent input rather than raising — the #12616 posture, inherited" do
      ws = workspace!("owner-seat-total-#{System.unique_integer([:positive])}")

      refute Auth.workspace_owner?(nil, ws.id)
      refute Auth.workspace_owner?(token!(), nil)
      refute Auth.workspace_owner?("not-a-uuid", ws.id)
      refute Auth.workspace_owner?(seated!(ws, "owner"), "")
      refute Auth.workspace_owner?(%{}, ws.id)
    end
  end
end
