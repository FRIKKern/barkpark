defmodule Barkpark.Tasks.EdgeTest do
  @moduledoc """
  Pure changeset / schema tests for `Barkpark.Tasks.Edge`.

  No database access — all assertions operate on `%Ecto.Changeset{}` values
  returned by `Edge.changeset/2` and on the `Edge.kinds/0` accessor.  Run
  with `async: true` (no shared state).
  """

  use ExUnit.Case, async: true

  alias Barkpark.Tasks.Edge

  # A stable UUID that can stand in as a foreign-key value in a cast;
  # FK constraints are only enforced on DB insert, not during changeset
  # validation, so any valid binary_id string is fine here.
  @uuid_a "00000000-0000-0000-0000-000000000001"
  @uuid_b "00000000-0000-0000-0000-000000000002"

  describe "kinds/0" do
    test "returns the two documented kinds and nothing else" do
      assert Edge.kinds() == ~w(blocks discovered-from)
    end
  end

  describe "changeset/2 — valid attrs" do
    test "a blocks edge with two distinct UUIDs is valid" do
      cs =
        Edge.changeset(%Edge{}, %{
          from_id: @uuid_a,
          to_id: @uuid_b,
          kind: "blocks"
        })

      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :kind) == "blocks"
      assert Ecto.Changeset.get_field(cs, :from_id) == @uuid_a
      assert Ecto.Changeset.get_field(cs, :to_id) == @uuid_b
    end

    test "a discovered-from edge is valid" do
      cs =
        Edge.changeset(%Edge{}, %{
          from_id: @uuid_a,
          to_id: @uuid_b,
          kind: "discovered-from"
        })

      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :kind) == "discovered-from"
    end
  end

  describe "changeset/2 — missing required fields" do
    test "missing kind produces an error on :kind" do
      cs = Edge.changeset(%Edge{}, %{from_id: @uuid_a, to_id: @uuid_b})
      refute cs.valid?
      assert cs.errors[:kind]
    end

    test "missing from_id produces an error on :from_id" do
      cs = Edge.changeset(%Edge{}, %{to_id: @uuid_b, kind: "blocks"})
      refute cs.valid?
      assert cs.errors[:from_id]
    end

    test "missing to_id produces an error on :to_id" do
      cs = Edge.changeset(%Edge{}, %{from_id: @uuid_a, kind: "blocks"})
      refute cs.valid?
      assert cs.errors[:to_id]
    end
  end

  describe "changeset/2 — unknown kind" do
    test "an unrecognised kind string produces an :inclusion error" do
      cs =
        Edge.changeset(%Edge{}, %{
          from_id: @uuid_a,
          to_id: @uuid_b,
          kind: "depends-on"
        })

      refute cs.valid?
      assert {msg, _} = cs.errors[:kind]
      assert msg =~ "must be one of"
    end
  end

  describe "changeset/2 — self-edge rejection" do
    test "from_id == to_id produces an error on :to_id" do
      cs =
        Edge.changeset(%Edge{}, %{
          from_id: @uuid_a,
          to_id: @uuid_a,
          kind: "blocks"
        })

      refute cs.valid?
      assert {msg, _} = cs.errors[:to_id]
      assert msg =~ "same document"
    end

    test "self-edge with discovered-from kind also rejected" do
      cs =
        Edge.changeset(%Edge{}, %{
          from_id: @uuid_b,
          to_id: @uuid_b,
          kind: "discovered-from"
        })

      refute cs.valid?
      assert cs.errors[:to_id]
    end
  end
end
