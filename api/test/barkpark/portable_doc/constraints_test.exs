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

  # A block carrying only a "type" (no role) — so `Tiers.tier_of/1` resolves its
  # composition tier. Used to exercise tier-atom declarations.
  defp typed(type, extra \\ %{}), do: Map.merge(%{"type" => type}, extra)

  # Replicated inline from Barkpark.Content.Papers.Template.paper_declarations/0
  # (all string kinds, no tier atom, no {:not_index, ·}) — the LIVE paper set,
  # used by the backward-compat describe to prove byte-identity.
  defp paper_decls do
    [
      %{
        kind: "title",
        presence: :required,
        count: {:exactly, 1},
        position: [{:index, 0}],
        locked: true
      },
      %{
        kind: "ingress",
        presence: :optional,
        count: {:max, 1},
        position: [{:after, "title"}, {:before, "featured"}],
        locked: false
      },
      %{
        kind: "featured",
        presence: :optional,
        count: {:max, 1},
        position: [{:after, "title"}],
        locked: true
      }
    ]
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
      decls = [
        %{kind: "title", presence: :required, count: {:min, 0}, position: [:free], locked: true}
      ]

      assert [msg] = Constraints.validate([block("body")], decls)
      assert msg =~ "required" and msg =~ "title" and msg =~ "missing"
    end

    test "an optional kind that is absent is fine" do
      decls = [
        %{
          kind: "featured",
          presence: :optional,
          count: {:max, 1},
          position: [:free],
          locked: true
        }
      ]

      assert Constraints.validate([block("body")], decls) == []
    end
  end

  # ── cardinality ───────────────────────────────────────────────────────────────

  describe "cardinality" do
    test "{:exactly, 1} — one is fine, two is an error, zero is silent (presence owns missing)" do
      decl = %{
        kind: "title",
        presence: :required,
        count: {:exactly, 1},
        position: [:free],
        locked: true
      }

      assert Constraints.validate([block("title")], [decl]) == []
      assert Constraints.validate([block("title"), block("title")], [decl]) != []
      # zero occurrences → cardinality is silent (a required-missing is presence's error)
      assert Constraints.validate([block("body")], [decl]) ==
               ["the required \"title\" block is missing"]
    end

    test "{:max, 1} — zero or one pass, two fails" do
      decl = %{
        kind: "featured",
        presence: :optional,
        count: {:max, 1},
        position: [:free],
        locked: true
      }

      assert Constraints.validate([], [decl]) == []
      assert Constraints.validate([block("featured")], [decl]) == []
      assert [msg] = Constraints.validate([block("featured"), block("featured")], [decl])
      assert msg =~ "at most 1" and msg =~ "featured" and msg =~ "found 2"
    end

    test "{:min, 2} — proves min-N: one fails, two passes" do
      decl = %{
        kind: "bullet",
        presence: :optional,
        count: {:min, 2},
        position: [:free],
        locked: false
      }

      assert [msg] = Constraints.validate([block("bullet")], [decl])
      assert msg =~ "at least 2" and msg =~ "found 1"
      assert Constraints.validate([block("bullet"), block("bullet")], [decl]) == []
    end
  end

  # ── position: pinned index ─────────────────────────────────────────────────

  describe "position — pinned index" do
    test "the block must sit at the declared index" do
      decl = %{
        kind: "title",
        presence: :required,
        count: {:exactly, 1},
        position: [{:index, 0}],
        locked: true
      }

      assert Constraints.validate([block("title"), block("body")], [decl]) == []

      assert [msg] = Constraints.validate([block("body"), block("title")], [decl])
      assert msg =~ "block 0" and msg =~ "found at 1"
    end

    test "with several occurrences the OFFENDING index is reported, not a compliant one" do
      decl = %{
        kind: "title",
        presence: :required,
        count: {:max, 2},
        position: [{:index, 0}],
        locked: true
      }

      assert [msg] = Constraints.validate([block("title"), block("body"), block("title")], [decl])
      assert msg =~ "found at 2"
    end
  end

  # ── position: relative order ────────────────────────────────────────────────

  describe "position — relative order (before/after)" do
    test "{:after, anchor} holds only when the block sits after the anchor" do
      decl = %{
        kind: "featured",
        presence: :optional,
        count: {:max, 1},
        position: [{:after, "title"}],
        locked: true
      }

      assert Constraints.validate([block("title"), block("featured")], [decl]) == []

      assert [msg] = Constraints.validate([block("featured"), block("title")], [decl])
      assert msg =~ "featured" and msg =~ "after" and msg =~ "title"
    end

    test "an ABSENT anchor never fails a present block" do
      decl = %{
        kind: "featured",
        presence: :optional,
        count: {:max, 1},
        position: [{:after, "title"}],
        locked: true
      }

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
      decl = %{
        kind: "pin",
        presence: :optional,
        count: {:min, 0},
        position: [:top_group],
        locked: false
      }

      assert Constraints.validate([block("pin"), block("pin"), block("body")], [decl]) == []
      assert Constraints.validate([block("body"), block("pin")], [decl]) != []
    end

    test ":bottom_group requires a contiguous run at the bottom" do
      decl = %{
        kind: "foot",
        presence: :optional,
        count: {:min, 0},
        position: [:bottom_group],
        locked: false
      }

      assert Constraints.validate([block("body"), block("foot"), block("foot")], [decl]) == []
      assert Constraints.validate([block("foot"), block("body")], [decl]) != []
    end

    test ":free imposes no position constraint" do
      decl = %{
        kind: "note",
        presence: :optional,
        count: {:min, 0},
        position: [:free],
        locked: false
      }

      assert Constraints.validate([block("body"), block("note"), block("body")], [decl]) == []
    end
  end

  # ── position: mixed constraint lists compose ─────────────────────────────────

  describe "position — mixed constraint lists" do
    test "a pinned index AND a relation in one list both enforce (no silent no-op)" do
      decl = %{
        kind: "title",
        presence: :required,
        count: {:exactly, 1},
        position: [{:index, 0}, {:before, "featured"}],
        locked: true
      }

      # both hold
      assert Constraints.validate([block("title"), block("featured")], [decl]) == []

      # index holds but the relation is broken → the relation still fires
      assert [msg] =
               Constraints.validate([block("featured"), block("body"), block("title")], [decl])
               |> Enum.filter(&(&1 =~ "before"))

      assert msg =~ "title" and msg =~ "featured"

      # relation holds but the pin is broken → the pin still fires
      msgs = Constraints.validate([block("body"), block("title"), block("featured")], [decl])
      assert Enum.any?(msgs, &(&1 =~ "block 0"))
    end
  end

  # ── all three axes at once + satisfied?/2 ────────────────────────────────────

  describe "the whole vocabulary" do
    test "presence + cardinality + position compose; satisfied?/2 mirrors validate/2" do
      decls = [
        %{
          kind: "title",
          presence: :required,
          count: {:exactly, 1},
          position: [{:index, 0}],
          locked: true
        },
        %{
          kind: "featured",
          presence: :optional,
          count: {:max, 1},
          position: [{:after, "title"}],
          locked: true
        }
      ]

      good = [block("title"), block("featured"), block("body")]
      assert Constraints.validate(good, decls) == []
      assert Constraints.satisfied?(good, decls)

      bad = [block("featured"), block("body")]
      refute Constraints.satisfied?(bad, decls)
    end

    test "non-list inputs never raise" do
      assert Constraints.validate(nil, [
               %{
                 kind: "x",
                 presence: :optional,
                 count: {:max, 1},
                 position: [:free],
                 locked: false
               }
             ]) == []

      assert Constraints.validate([block("x")], nil) == []
    end
  end

  # ── tier-aware declarations (composition doctrine, step 5) ───────────────────

  describe "tier-aware declarations (composition doctrine, step 5)" do
    test "THE HEADLINE EXAMPLE — require a :section, forbid a :widget at index 0" do
      decls = [
        %{
          kind: :section,
          presence: :required,
          count: {:min, 0},
          position: [:free],
          locked: false
        },
        %{
          kind: :widget,
          presence: :optional,
          count: {:min, 0},
          position: [{:not_index, 0}],
          locked: false
        }
      ]

      # callout (tier :widget) at index 0, paragraph (tier :element) — no section.
      bad = [typed("callout"), typed("paragraph")]
      msgs = Constraints.validate(bad, decls)
      assert Enum.any?(msgs, &(&1 =~ "section" and &1 =~ "missing"))
      assert Enum.any?(msgs, &(&1 =~ "widget" and &1 =~ "block 0"))

      # section present; callout (widget) now sits at index 2, not 0 → clean.
      good = [typed("section"), typed("paragraph"), typed("callout")]
      assert Constraints.validate(good, decls) == []
    end

    test "forbid a tier entirely — count {:max, 0} on :widget" do
      decl = %{
        kind: :widget,
        count: {:max, 0},
        presence: :optional,
        position: [:free],
        locked: false
      }

      assert [msg] = Constraints.validate([typed("callout")], [decl])
      assert msg =~ "at most 0" and msg =~ "widget" and msg =~ "found 1"

      # a paragraph is tier :element, not :widget → passes.
      assert Constraints.validate([typed("paragraph")], [decl]) == []
    end

    test "cardinality math runs over tier-classified counts — {:min, 2} on :element" do
      decl = %{
        kind: :element,
        presence: :optional,
        count: {:min, 2},
        position: [:free],
        locked: false
      }

      assert [msg] = Constraints.validate([typed("paragraph")], [decl])
      assert msg =~ "at least 2" and msg =~ "found 1"

      # two element blocks (paragraph + heading are both tier :element) → passes.
      assert Constraints.validate([typed("paragraph"), typed("heading")], [decl]) == []
    end
  end

  # ── DISTRUST-VACUOUS-GREEN: tier matching is REAL, not string equality ───────

  describe "tier matching routes through Tiers.tier_of (not string equality)" do
    test "a :section tier decl COUNTS a columns block; a \"section\" STRING decl does NOT" do
      columns = [typed("columns")]

      tier_decl = %{
        kind: :section,
        presence: :required,
        count: {:min, 1},
        position: [:free],
        locked: false
      }

      string_decl = %{
        kind: "section",
        presence: :required,
        count: {:min, 1},
        position: [:free],
        locked: false
      }

      # columns is tier :section (type "columns" != "section") → the tier decl is
      # satisfied, proving the match went through Tiers.tier_of, not kind_of.
      assert Constraints.validate(columns, [tier_decl]) == []

      # the STRING decl keys on "section"; a columns block's kind_of is "columns",
      # so it is NOT counted → the required-section error fires. A mistyped tier
      # atom (matching nothing) therefore cannot silently no-op.
      refute Constraints.satisfied?(columns, [string_decl])
    end

    test "validate/2 is deterministic — the dual index appends in block order" do
      decls = [
        %{
          kind: :section,
          presence: :optional,
          count: {:min, 0},
          position: [:free],
          locked: false
        },
        %{
          kind: :widget,
          presence: :optional,
          count: {:min, 0},
          position: [{:not_index, 0}],
          locked: false
        }
      ]

      blocks = [typed("callout"), typed("columns"), typed("paragraph")]
      assert Constraints.validate(blocks, decls) == Constraints.validate(blocks, decls)
    end

    test "a relation can anchor on a whole tier — {:after, :element}" do
      decl = %{
        kind: :widget,
        presence: :optional,
        count: {:min, 0},
        position: [{:after, :element}],
        locked: false
      }

      # paragraph (element) then callout (widget) → widget is after the element.
      assert Constraints.validate([typed("paragraph"), typed("callout")], [decl]) == []

      # callout (widget) before the paragraph (element) → the tier relation fires.
      assert [msg] = Constraints.validate([typed("callout"), typed("paragraph")], [decl])
      assert msg =~ "widget" and msg =~ "after" and msg =~ "element"
    end
  end

  # ── position: forbidden index ({:not_index, n}) — isolated from tiers ─────────

  describe "position — forbidden index ({:not_index, n})" do
    test "a plain role kind may not sit at the forbidden index" do
      decl = %{
        kind: "banner",
        presence: :optional,
        count: {:min, 0},
        position: [{:not_index, 0}],
        locked: false
      }

      # banner at index 0 → error naming block 0.
      assert [msg] = Constraints.validate([block("banner"), block("body")], [decl])
      assert msg =~ "banner" and msg =~ "block 0"

      # banner anywhere else → clean.
      assert Constraints.validate([block("body"), block("banner")], [decl]) == []

      # banner absent → position never fires on an empty occurrence set.
      assert Constraints.validate([block("body")], [decl]) == []
    end
  end

  # ── backward-compat: the live string-kind set is byte-identical ──────────────

  describe "backward-compat — old shape still works" do
    test "a conforming title/ingress/featured doc validates clean" do
      doc = [block("title"), block("ingress"), block("featured")]
      assert Constraints.validate(doc, paper_decls()) == []
    end

    test "a legacy title + body doc (zero sections/widgets) validates clean" do
      # no tier decl in the set ⇒ the added atom keys are never consulted, so the
      # result is byte-identical to the pre-dual-index checker.
      assert Constraints.validate([block("title"), block("paragraph")], paper_decls()) == []
    end

    test "tier-classifiable blocks in a string-decl doc change nothing" do
      # a callout (tier :widget) carries no role → its kind_of is "callout", which
      # no string decl looks up; its :widget atom key is never consulted either.
      doc = [block("title"), typed("callout")]
      assert Constraints.validate(doc, paper_decls()) == []
    end
  end

  describe "live-data task-list query gate (additive, legacy-safe)" do
    # Validate against `[]` decls to ISOLATE the additive query gate from
    # presence/cardinality (a bare doc has no title, which paper_decls would flag).
    test "a legacy snapshot-only task-list validates clean (no new error)" do
      doc = [typed("task-list", %{"snapshot" => [%{"title" => "Pinned", "status" => "open"}]})]
      assert Constraints.validate(doc, []) == []
    end

    test "a legacy snapshot-only task-list PAPER (conforming title) validates clean" do
      # Wired into a real paper (title at index 0) it still adds NO error — the gate is
      # legacy-safe end-to-end, not just against an empty decl set.
      doc = [block("title"), typed("task-list", %{"snapshot" => []})]
      assert Constraints.validate(doc, paper_decls()) == []
    end

    test "a well-formed LIVE task-list (query map) validates clean" do
      doc = [typed("task-list", %{"query" => %{"label" => "proj:x"}, "title" => "Plan"})]
      assert Constraints.validate(doc, []) == []
    end

    test "a task-list with a present-but-non-map query surfaces ONE calm error" do
      doc = [typed("task-list", %{"query" => "proj:x"})]
      errors = Constraints.validate(doc, [])
      assert length(errors) == 1
      assert hd(errors) =~ "task-list"
      assert hd(errors) =~ "must be a map"
    end

    test "the query gate never fires on non-task-list blocks (mixed legacy doc stays clean)" do
      doc = [block("title"), typed("callout"), typed("tasks", %{"snapshot" => []})]
      assert Constraints.validate(doc, paper_decls()) == []
    end
  end
end
