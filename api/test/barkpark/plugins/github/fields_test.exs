defmodule Barkpark.Plugins.Github.FieldsTest do
  @moduledoc """
  Property-style enumeration of the field-ownership matrix (charter D5). Every
  assertion holds FOR EVERY field, so the matrix stays directionally pure as it
  grows: no field is bidirectional, every ledger-owned outbound field has one
  unambiguous issue attr, and the ledger-only primitives never touch GitHub.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.Github.Fields

  @valid_directions [:outbound_only, :inbound_intake_only, :never]
  @valid_owners [:barkpark, :github, :derived]
  @valid_issue_attrs [:title, :body, :labels, :state, :sub_issue]

  describe "(a) no field has two directions" do
    test "every field declares exactly ONE direction from the valid set" do
      for {field, entry} <- Fields.all() do
        assert entry.direction in @valid_directions,
               "#{field} has invalid direction #{inspect(entry.direction)}"

        # A single atom, never a list — bidirectionality can't even be expressed.
        refute is_list(entry.direction), "#{field} direction must be a single atom"
      end
    end

    test "the three direction buckets partition the matrix (disjoint + total)" do
      out = Fields.outbound_fields() |> Map.keys() |> MapSet.new()
      intake = Fields.intake_fields() |> Map.keys() |> MapSet.new()
      never = Fields.never_fields() |> Map.keys() |> MapSet.new()

      # Disjoint: no field appears in two buckets (structurally impossible to be
      # both outbound and inbound).
      assert MapSet.disjoint?(out, intake)
      assert MapSet.disjoint?(out, never)
      assert MapSet.disjoint?(intake, never)

      # Total: every field lands in exactly one bucket.
      all = Fields.all() |> Map.keys() |> MapSet.new()
      assert MapSet.union(out, MapSet.union(intake, never)) == all
    end

    test "every entry has valid owner + issue_attr shape" do
      for {field, entry} <- Fields.all() do
        assert entry.owner in @valid_owners, "#{field} bad owner"
        assert entry.issue_attr == nil or entry.issue_attr in @valid_issue_attrs
      end
    end
  end

  describe "(b) every ledger-owned outbound field maps to exactly one issue attr" do
    test "each outbound field has a single non-nil issue_attr" do
      outbound = Fields.outbound_fields()
      refute Enum.empty?(outbound)

      for {field, entry} <- outbound do
        # Ledger-authored (barkpark) or ledger-derived — both project onto one
        # issue attribute. GitHub never owns an outbound field.
        assert entry.owner in [:barkpark, :derived],
               "#{field} is outbound but not ledger-owned"

        assert entry.issue_attr in @valid_issue_attrs,
               "#{field} outbound but issue_attr #{inspect(entry.issue_attr)} not a single valid attr"
      end
    end

    test "the outbound set is exactly the charter's Barkpark-owned list" do
      assert Fields.outbound_fields() |> Map.keys() |> Enum.sort() ==
               Enum.sort([
                 :title,
                 :description,
                 :lifecycle_status,
                 :priority,
                 :worker,
                 :status,
                 :parent_id,
                 :blocks,
                 :acceptance_criteria
               ])
    end

    test "intake fields are inbound_intake_only and github-origin, never outbound" do
      intake = Fields.intake_fields()

      assert intake |> Map.keys() |> Enum.sort() ==
               Enum.sort([:src_labels, :outsider_title, :outsider_body, :outsider_author])

      for {field, entry} <- intake do
        assert entry.direction == :inbound_intake_only
        assert entry.owner == :github, "#{field} intake must be github-origin"
        # Intake fields are read once at birth — they never project TO an issue.
        assert entry.issue_attr == nil, "#{field} intake must not map to an issue attr"
      end
    end
  end

  describe "(c) claim/epoch/fence/rail_rev are :never" do
    test "the ledger-only primitives never touch GitHub" do
      never = Fields.never_fields()

      for primitive <- [:claim, :epoch, :fence, :rail_rev] do
        entry = Map.fetch!(never, primitive)
        assert entry.direction == :never, "#{primitive} must be :never"
        assert entry.issue_attr == nil, "#{primitive} must not map to any issue attr"
        assert entry.projects_field == nil, "#{primitive} must not feed Projects"
      end
    end

    test "no other field is :never (the never-set is exactly the four primitives)" do
      assert Fields.never_fields() |> Map.keys() |> Enum.sort() ==
               Enum.sort([:claim, :epoch, :fence, :rail_rev])
    end
  end

  describe "directional purity — no reverse writer exists" do
    test "the Fields module exposes ONLY matrix readers, no github→task writer" do
      names = Fields.__info__(:functions) |> Enum.map(&elem(&1, 0)) |> Enum.map(&to_string/1)

      for name <- names do
        refute name =~ ~r/(write|apply|inbound|from_issue|from_github|set_)/,
               "Fields.#{name} looks like a reverse writer — bidirectionality is forbidden"
      end
    end
  end
end
