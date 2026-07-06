defmodule Barkpark.PortableDoc.ConstraintsTest do
  @moduledoc """
  The generic constraint vocabulary (pdd-t20): presence + cardinality + position
  (pinned index, relative before/after, top/bottom group, free) over plain block
  maps, with no Content/DB dependency. `Barkpark.Content.Papers.Template` layers
  the paper's declaration set on top; these lock the enforcement math directly.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Constraints

  defp block(kind, extra \\ %{}) do
    # A block's kind is its "role", falling back to "type" — model both here by
    # stamping the kind under "role" (the common case) unless caller overrides.
    Map.merge(%{"role" => kind}, extra)
  end

  # ── kind_of ────────────────────────────────────────────────────────────────

  describe "kind_of/1" do
    test "role wins, then type, else nil" do
      assert Constraints.kind_of(%{"role" => "title", "type" => "heading"}) == "title"
      assert Constraints.kind_of(%{"type" => "paragraph"}) == "paragraph"
      assert Constraints.kind_of(%{"role" => "", "type" => "image"}) == "image"
      assert Constraints.kind_of(%{"text" => "x"}) == nil
    end
  end

  # ── presence ─────────────────────────────────────────────────────────────────

  describe "presence" do
    test "a required kind that is absent is an error" do
      decls = [%{kind: "title", presence: :required, count: {:min, 0}, position: [:free], locked: true}]
      assert [msg] = Constraints.validate([block("body")], decls)
      assert msg =~ "required" and msg =~ "title" and msg =~ "missing"
    end

    test "an optional kind that is absent is fine" do
      decls = [%{kind: "featured", presence: :optional, count: {:max, 1}, position: [:free], locked: true}]
      assert Constraints.validate([block("body")], decls) == []
    end
  end

  # ── cardinality ───────────────────────────────────────────────────────────────

  describe "cardinality" do
    test "{:exactly, 1} — one is fine, two is an error, zero is silent (presence owns missing)" do
      decl = %{kind: "title", presence: :required, count: {:exactly, 1}, position: [:free], locked: true}

      assert Constraints.validate([block("title")], [decl]) == []
      assert Constraints.validate([block("title"), block("title")], [decl]) != []
      # zero occurrences → cardinality is silent (a required-missing is presence's error)
      assert Constraints.validate([block("body")], [decl]) ==
               ["the required \"title\" block is missing"]
    end

    test "{:max, 1} — zero or one pass, two fails" do
      decl = %{kind: "featured", presence: :optional, count: {:max, 1}, position: [:free], locked: true}

      assert Constraints.validate([], [decl]) == []
      assert Constraints.validate([block("featured")], [decl]) == []
      assert [msg] = Constraints.validate([block("featured"), block("featured")], [decl])
      assert msg =~ "at most 1" and msg =~ "featured" and msg =~ "found 2"
    end

    test "{:min, 2} — proves min-N: one fails, two passes" do
      decl = %{kind: "bullet", presence: :optional, count: {:min, 2}, position: [:free], locked: false}

      assert [msg] = Constraints.validate([block("bullet")], [decl])
      assert msg =~ "at least 2" and msg =~ "found 1"
      assert Constraints.validate([block("bullet"), block("bullet")], [decl]) == []
    end
  end

  # ── position: pinned index ─────────────────────────────────────────────────

  describe "position — pinned index" do
    test "the block must sit at the declared index" do
      decl = %{kind: "title", presence: :required, count: {:exactly, 1}, position: [{:index, 0}], locked: true}

      assert Constraints.validate([block("title"), block("body")], [decl]) == []

      assert [msg] = Constraints.validate([block("body"), block("title")], [decl])
      assert msg =~ "block 0" and msg =~ "found at 1"
    end
  end

  # ── position: relative order ────────────────────────────────────────────────

  describe "position — relative order (before/after)" do
    test "{:after, anchor} holds only when the block sits after the anchor" do
      decl = %{kind: "featured", presence: :optional, count: {:max, 1}, position: [{:after, "title"}], locked: true}

      assert Constraints.validate([block("title"), block("featured")], [decl]) == []

      assert [msg] = Constraints.validate([block("featured"), block("title")], [decl])
      assert msg =~ "featured" and msg =~ "after" and msg =~ "title"
    end

    test "an ABSENT anchor never fails a present block" do
      decl = %{kind: "featured", presence: :optional, count: {:max, 1}, position: [{:after, "title"}], locked: true}

      # no title at all → the after-relation is vacuously satisfied
      assert Constraints.validate([block("featured")], [decl]) == []
    end

    test "chained relations — after one anchor AND before another" do
      decl = %{
        kind: "ingress",
        presence: :optional,
        count: {:max, 1},
        position: [{:after, "title"}, {:before, "featured"}],
        locked: false
      }

      # title, ingress, featured → both relations hold
      ok = [block("title"), block("ingress"), block("featured")]
      assert Constraints.validate(ok, [decl]) == []

      # title, featured, ingress → ingress is after featured (before-relation broken)
      bad = [block("title"), block("featured"), block("ingress")]
      assert [msg] = Constraints.validate(bad, [decl])
      assert msg =~ "before" and msg =~ "featured"

      # featured absent → the before-relation is skipped; after-title still holds
      only_after = [block("title"), block("ingress")]
      assert Constraints.validate(only_after, [decl]) == []
    end
  end

  # ── position: top/bottom group + free ───────────────────────────────────────

  describe "position — top/bottom group and free" do
    test ":top_group requires a contiguous run at the top" do
      decl = %{kind: "pin", presence: :optional, count: {:min, 0}, position: [:top_group], locked: false}

      assert Constraints.validate([block("pin"), block("pin"), block("body")], [decl]) == []
      assert Constraints.validate([block("body"), block("pin")], [decl]) != []
    end

    test ":bottom_group requires a contiguous run at the bottom" do
      decl = %{kind: "foot", presence: :optional, count: {:min, 0}, position: [:bottom_group], locked: false}

      assert Constraints.validate([block("body"), block("foot"), block("foot")], [decl]) == []
      assert Constraints.validate([block("foot"), block("body")], [decl]) != []
    end

    test ":free imposes no position constraint" do
      decl = %{kind: "note", presence: :optional, count: {:min, 0}, position: [:free], locked: false}

      assert Constraints.validate([block("body"), block("note"), block("body")], [decl]) == []
    end
  end

  # ── all three axes at once + satisfied?/2 ────────────────────────────────────

  describe "the whole vocabulary" do
    test "presence + cardinality + position compose; satisfied?/2 mirrors validate/2" do
      decls = [
        %{kind: "title", presence: :required, count: {:exactly, 1}, position: [{:index, 0}], locked: true},
        %{kind: "featured", presence: :optional, count: {:max, 1}, position: [{:after, "title"}], locked: true}
      ]

      good = [block("title"), block("featured"), block("body")]
      assert Constraints.validate(good, decls) == []
      assert Constraints.satisfied?(good, decls)

      bad = [block("featured"), block("body")]
      refute Constraints.satisfied?(bad, decls)
    end

    test "non-list inputs never raise" do
      assert Constraints.validate(nil, [%{kind: "x", presence: :optional, count: {:max, 1}, position: [:free], locked: false}]) == []
      assert Constraints.validate([block("x")], nil) == []
    end
  end
end
