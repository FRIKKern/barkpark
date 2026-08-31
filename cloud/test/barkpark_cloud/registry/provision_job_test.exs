defmodule BarkparkCloud.Registry.ProvisionJobTest do
  @moduledoc """
  azh-w6 (S14c) — the provision-job SCHEMA shape gates, focused on the new
  `resurrect` kind + its required `bundle_ref` (charter D40: no new step kind —
  resurrect rides the same 7 canonical steps).
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.Registry.ProvisionJob

  @bp_id "11111111-1111-1111-1111-111111111111"

  defp changeset(attrs) do
    ProvisionJob.changeset(%ProvisionJob{}, attrs)
  end

  describe "kinds" do
    test "the exact kind list — provision_support the 5th (PDF-D83), push_agent_key the 6th (PDF-D94), enable_apply the 7th (isu-w5)" do
      assert ProvisionJob.kinds() ==
               ~w(provision deprovision attach_domain resurrect provision_support push_agent_key enable_apply)
    end

    test "an enable_apply job changeset is valid (needs no bundle_ref)" do
      cs = changeset(%{barkpark_id: @bp_id, kind: "enable_apply", status: "pending"})
      assert cs.valid?
    end

    test "a push_agent_key job changeset is valid (needs no bundle_ref — and has no key field to hold)" do
      cs = changeset(%{barkpark_id: @bp_id, kind: "push_agent_key", status: "pending"})
      assert cs.valid?
    end

    test "a provision_support job changeset is valid (needs no bundle_ref)" do
      cs = changeset(%{barkpark_id: @bp_id, kind: "provision_support", status: "pending"})
      assert cs.valid?
    end
  end

  describe "step vocabulary (D40/D84 — no new step kind for resurrect OR support)" do
    test "the canonical 7 steps are unchanged" do
      assert ProvisionJob.step_names() ==
               ~w(create freshen secure configure content verify ready)
    end
  end

  describe "bundle_ref requirement" do
    test "a resurrect job WITHOUT bundle_ref is invalid" do
      cs = changeset(%{barkpark_id: @bp_id, kind: "resurrect", status: "pending"})
      refute cs.valid?
      assert %{bundle_ref: ["can't be blank"]} = errors_on(cs)
    end

    test "a resurrect job WITH bundle_ref is valid" do
      cs =
        changeset(%{
          barkpark_id: @bp_id,
          kind: "resurrect",
          status: "pending",
          bundle_ref: "s3://archives/shop-2026.tar.zst"
        })

      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :bundle_ref) == "s3://archives/shop-2026.tar.zst"
    end

    test "a PROVISION job needs no bundle_ref (nil is fine for every other kind)" do
      for kind <- ~w(provision deprovision attach_domain) do
        cs = changeset(%{barkpark_id: @bp_id, kind: kind, status: "pending"})
        assert cs.valid?, "#{kind} should not require bundle_ref"
      end
    end

    test "an unknown kind is still rejected" do
      cs = changeset(%{barkpark_id: @bp_id, kind: "teleport", status: "pending"})
      refute cs.valid?
      assert %{kind: [_ | _]} = errors_on(cs)
    end
  end

  # Local mini errors_on (DataCase's helper without the DB dependency).
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
