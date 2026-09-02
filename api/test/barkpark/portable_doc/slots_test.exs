defmodule Barkpark.PortableDoc.SlotsTest do
  @moduledoc """
  STEP 3 (loop-epic/widget-slots) — the callout SLOT-MODEL proof.

  The load-bearing claim is byte-identity: the additive `body`-slot encoding and the
  legacy inline `content` encoding of the SAME body compose to a byte-identical Pd
  tree, so reader / TUI / email bytes never move. These tests prove that at the
  compose layer (the reference implementation), plus the D1 slot-type gate and the
  idempotent content⇄slots normalizer.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.{Constraints, Slots}
  alias Barkpark.PortableDoc.Render
  alias Barkpark.PortableDoc.Render.Compose

  # A shared body with a bold run, to prove the mark survives the slot indirection.
  @body [
    %{"type" => "text", "value" => "Be "},
    %{"type" => "strong", "children" => [%{"type" => "text", "value" => "careful"}]}
  ]

  defp legacy(extra \\ %{}) do
    Map.merge(
      %{"id" => "c-1", "type" => "callout", "tone" => "warning", "content" => @body},
      extra
    )
  end

  defp slotted(extra \\ %{}) do
    Map.merge(
      %{
        "id" => "c-1",
        "type" => "callout",
        "tone" => "warning",
        "slots" => %{"body" => [%{"type" => "paragraph", "content" => @body}]}
      },
      extra
    )
  end

  describe "slot_elements/2 + callout_body_inline/1 (the compat reader)" do
    test "legacy callout synthesizes a one-paragraph body slot from `content`" do
      assert Slots.slot_elements(legacy(), "body") == [
               %{"type" => "paragraph", "content" => @body}
             ]
    end

    test "materialized slot form returns its body list verbatim" do
      assert Slots.slot_elements(slotted(), "body") == [
               %{"type" => "paragraph", "content" => @body}
             ]
    end

    test "callout_body_inline/1 yields the SAME inline array for both encodings" do
      assert Slots.callout_body_inline(legacy()) == @body
      assert Slots.callout_body_inline(slotted()) == @body
      assert Slots.callout_body_inline(legacy()) == Slots.callout_body_inline(slotted())
    end

    test "nil / absent content is nil-safe (empty inline array)" do
      assert Slots.callout_body_inline(%{"type" => "callout"}) == []
      assert Slots.callout_body_inline(%{"type" => "callout", "content" => nil}) == []
    end

    test "legacy prose stranded under text remains visible" do
      assert Slots.callout_body_inline(%{"type" => "callout", "text" => "Visible"}) ==
               [%{"type" => "text", "value" => "Visible"}]
    end

    test "unknown slot / non-callout block synthesizes []" do
      assert Slots.slot_elements(legacy(), "media") == []
      assert Slots.slot_elements(%{"type" => "paragraph"}, "body") == []
    end
  end

  describe "byte-identity via compose (the proof)" do
    # DISTRUST-VACUOUS-GREEN: assert the inputs GENUINELY differ, then assert the
    # composed Pd trees are EQUAL — a test that passed on identical inputs proves
    # nothing.
    test "legacy and slot encodings compose to byte-identical Pd trees (article + email)" do
      refute legacy() == slotted(), "the two source encodings must genuinely differ"

      for style <- [:article, :email] do
        assert Compose.compose_block(legacy(), style) == Compose.compose_block(slotted(), style),
               "callout compose diverged between legacy and slot form for #{inspect(style)}"
      end
    end

    test "the composed callout body is ONE flattened PdText (never a block PdParagraph)" do
      # The single most important implementation constraint: the widget FLATTENS its
      # single-paragraph body slot to inline. A PdParagraph would add a <p> wrapper +
      # 12pt margin and break parity.
      composed = Compose.compose_block(slotted(), :article)
      assert %{"kind" => "PdCallout", "children" => [body]} = composed
      assert %{"kind" => "PdText"} = body
      refute match?(%{"kind" => "PdParagraph"}, body)
    end

    test "legacy callout renders byte-identical article HTML (standing golden shape)" do
      # Mirrors render_test.exs "non-collapsible callout is byte-identical".
      html =
        Render.render_blocks([legacy(%{"tone" => "info", "content" => plain()})], %{
          style: :article
        })

      assert html =~ ~s(<div class="bp-callout bp-callout--info">)
      refute html =~ "<details"
      refute html =~ "border-left:4px solid"

      # And the slot form renders the SAME article HTML.
      slot_html =
        Render.render_blocks(
          [
            slotted(%{
              "tone" => "info",
              "slots" => %{"body" => [%{"type" => "paragraph", "content" => plain()}]}
            })
          ],
          %{style: :article}
        )

      assert slot_html == html
    end

    test "chrome (title/collapsible/collapsed) stays a widget attr, threaded identically" do
      lc = legacy(%{"title" => "Heads up", "collapsible" => true, "collapsed" => true})
      sc = slotted(%{"title" => "Heads up", "collapsible" => true, "collapsed" => true})

      article = Compose.compose_block(lc, :article)
      assert article["title"] == "Heads up"
      assert article["collapsible"] == true
      assert article["collapsed"] == true
      assert Compose.compose_block(lc, :article) == Compose.compose_block(sc, :article)
    end
  end

  describe "empty-body fidelity" do
    test "content:[] composes to the same empty PdText as a slot with an empty paragraph" do
      le = legacy(%{"content" => []})
      se = slotted(%{"slots" => %{"body" => [%{"type" => "paragraph", "content" => []}]}})

      for style <- [:article, :email] do
        assert Compose.compose_block(le, style) == Compose.compose_block(se, style)
      end

      assert Slots.callout_body_inline(le) == []
    end
  end

  describe "normalize_widget/1 (idempotent, lossless content⇄slots)" do
    test "is idempotent (normalize∘normalize == normalize)" do
      for input <- [legacy(), slotted(), legacy(%{"content" => []})] do
        once = Slots.normalize_widget(input)
        assert Slots.normalize_widget(once) == once
      end
    end

    test "content-form and slot-form of the same body normalize to the IDENTICAL map" do
      assert Slots.normalize_widget(legacy()) == Slots.normalize_widget(slotted())
    end

    test "normal form dual-writes content AND slots.body[0].content in sync" do
      normalized = Slots.normalize_widget(legacy())
      assert normalized["content"] == @body
      assert normalized["slots"]["body"] == [%{"type" => "paragraph", "content" => @body}]
    end

    test "empty body omits BOTH keys (the callout precedent)" do
      normalized = Slots.normalize_widget(legacy(%{"content" => []}))
      refute Map.has_key?(normalized, "content")
      refute Map.has_key?(normalized, "slots")
    end

    test "a non-widget block passes through untouched" do
      p = %{"type" => "paragraph", "content" => @body}
      assert Slots.normalize_widget(p) == p
    end
  end

  describe "D1 gate — slot children must be element tier" do
    test "an element body yields NO slot errors (legacy + slot form)" do
      assert Slots.slot_type_errors(legacy()) == []
      assert Slots.slot_type_errors(slotted()) == []
    end

    test "a body slot holding a WIDGET (nested callout) yields the specific error" do
      nested = %{
        "type" => "callout",
        "tone" => "info",
        "slots" => %{"body" => [%{"type" => "callout", "tone" => "danger", "content" => plain()}]}
      }

      errors = Slots.slot_type_errors(nested)
      refute errors == []
      # Assert the SPECIFIC string, not merely non-empty (a bare refute would be vacuous).
      assert Enum.any?(errors, &(&1 =~ ~s(the "body" slot accepts only element blocks)))
      assert Enum.any?(errors, &(&1 =~ "widget"))
    end

    test "a body slot holding a SECTION yields an error" do
      nested = %{
        "type" => "callout",
        "slots" => %{"body" => [%{"type" => "section", "children" => []}]}
      }

      assert Enum.any?(Slots.slot_type_errors(nested), &(&1 =~ "section"))
    end

    test "Constraints.validate/2 folds in the slot gate (legacy zero-new-error, nested widget errors)" do
      # A legacy callout produces ZERO new errors under an empty declaration set.
      assert Constraints.validate([legacy()], []) == []

      nested = %{
        "type" => "callout",
        "slots" => %{"body" => [%{"type" => "callout", "content" => plain()}]}
      }

      errors = Constraints.validate([nested], [])
      refute errors == []
      assert Enum.any?(errors, &(&1 =~ ~s(the "body" slot accepts only element blocks)))
    end
  end

  describe "card widget slots (STEP 4)" do
    test "declares four element slots (title/body/media/action), each arity {:max,1}" do
      decls = Slots.slot_decls(%{"type" => "card"})
      assert Enum.map(decls, & &1.name) == ["title", "body", "media", "action"]
      assert Enum.all?(decls, &(&1.tier == :element))
      assert Enum.all?(decls, &(&1.count == {:max, 1}))
    end

    test "element slots (incl. present media/action) yield NO D1 errors" do
      assert Slots.slot_type_errors(card()) == []

      full =
        card(%{
          "slots" => %{
            "title" => [%{"type" => "heading", "text" => "T"}],
            "body" => [%{"type" => "paragraph", "content" => plain()}],
            "media" => [%{"type" => "image", "src" => "/x.png", "alt" => "x"}],
            "action" => [%{"type" => "action", "href" => "/go", "label" => "Go"}]
          }
        })

      assert Slots.slot_type_errors(full) == []
    end

    test "a body slot holding a nested WIDGET (callout) yields the specific D1 error" do
      nested = card(%{"slots" => %{"body" => [%{"type" => "callout", "content" => plain()}]}})
      errors = Slots.slot_type_errors(nested)
      refute errors == []
      assert Enum.any?(errors, &(&1 =~ ~s(the "body" slot accepts only element blocks)))
      assert Enum.any?(errors, &(&1 =~ "widget"))
    end

    test "a title slot holding a SECTION yields an error" do
      nested =
        card(%{
          "slots" => %{
            "title" => [%{"type" => "section", "children" => []}],
            "body" => [%{"type" => "paragraph", "content" => plain()}]
          }
        })

      assert Enum.any?(Slots.slot_type_errors(nested), &(&1 =~ "section"))
    end

    test "Constraints.validate/2 folds in the card D1 gate (clean card zero-error)" do
      assert Constraints.validate([card()], []) == []
      nested = card(%{"slots" => %{"body" => [%{"type" => "section", "children" => []}]}})
      refute Constraints.validate([nested], []) == []
    end
  end

  describe "stage widget slots (the pipeline-node twin)" do
    test "declares three element slots — kind {:max,1}, title {:exactly,1}, detail {:max,1}" do
      decls = Slots.slot_decls(%{"type" => "stage"})
      assert Enum.map(decls, & &1.name) == ["kind", "title", "detail"]
      assert Enum.all?(decls, &(&1.tier == :element))
      assert Enum.find(decls, &(&1.name == "title")).count == {:exactly, 1}
      assert Enum.find(decls, &(&1.name == "kind")).count == {:max, 1}
      assert Enum.find(decls, &(&1.name == "detail")).count == {:max, 1}
    end

    test "stage_field_text/2 yields the SAME plain string for the scalar AND slot encodings" do
      assert Slots.stage_field_text(stage_scalar(), "kind") == "source"
      assert Slots.stage_field_text(stage_scalar(), "title") == "emit"
      assert Slots.stage_field_text(stage_slotted(), "kind") == "source"
      assert Slots.stage_field_text(stage_slotted(), "title") == "emit"

      for name <- ["kind", "title", "detail"] do
        assert Slots.stage_field_text(stage_scalar(), name) ==
                 Slots.stage_field_text(stage_slotted(), name),
               ~s(scalar and slot "#{name}" diverged)
      end
    end

    test "stage_field_text/2 DROPS marks (plain text — a pasted <strong> must not survive)" do
      marked =
        stage_scalar(%{
          "slots" => %{
            "detail" => [
              %{
                "type" => "paragraph",
                "content" => [
                  %{"type" => "strong", "children" => [%{"type" => "text", "value" => "bold "}]},
                  %{"type" => "text", "value" => "tail"}
                ]
              }
            ]
          }
        })

      assert Slots.stage_field_text(marked, "detail") == "bold tail"
    end

    test "an absent field is nil-safe (empty string)" do
      assert Slots.stage_field_text(%{"type" => "stage"}, "kind") == ""
      assert Slots.stage_field_text(%{"type" => "stage"}, "detail") == ""
    end

    test "scalar and slot encodings compose to byte-identical HTML (the reader proof)" do
      assert Render.render_block(stage_scalar(), %{style: :article}) ==
               Render.render_block(stage_slotted(), %{style: :article})
    end

    test "a stage renders the IDENTICAL pnode cell one legacy pipeline node emits (drift tripwire)" do
      # A single-node pipeline wraps its ONE cell in bp-pipe-scroll/bp-pipe; a stage IS
      # that inner cell. So stage_html == the pipeline's cell, byte for byte.
      node = %{
        "kind" => "source",
        "title" => "emit",
        "detail" => "reads the queue",
        "source" => true
      }

      pipeline = %{"type" => "pipeline", "nodes" => [node]}
      stage = Map.merge(%{"type" => "stage"}, node)

      cell = Compose.compose_block(stage, :article)["html"]

      wrapped =
        ~s(<div class="bp-pipe-scroll"><div class="bp-pipe">) <>
          cell <> ~s(</div></div>)

      assert Compose.compose_block(pipeline, :article)["html"] == wrapped,
             "a stage cell no longer byte-matches one legacy pipeline node — reader drift"
    end

    test "element slots yield NO D1 errors; a nested widget/section yields the specific error" do
      assert Slots.slot_type_errors(stage_scalar()) == []
      assert Slots.slot_type_errors(stage_slotted()) == []

      nested =
        stage_scalar(%{"slots" => %{"detail" => [%{"type" => "callout", "content" => plain()}]}})

      errors = Slots.slot_type_errors(nested)
      assert Enum.any?(errors, &(&1 =~ ~s(the "detail" slot accepts only element blocks)))
      assert Enum.any?(errors, &(&1 =~ "widget"))
    end

    test "normalize_widget/1 is idempotent + dual-writes scalars AND slots" do
      once = Slots.normalize_widget(stage_scalar())
      assert Slots.normalize_widget(once) == once
      # Scalar-form and slot-form of the same stage normalize to the IDENTICAL map.
      assert Slots.normalize_widget(stage_scalar()) == Slots.normalize_widget(stage_slotted())
      # Dual-write: the scalar AND the slot entry are both present + in sync.
      assert once["kind"] == "source"

      assert once["slots"]["kind"] == [
               %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "source"}]}
             ]
    end

    test "normalize_widget/1 omits an EMPTY field from BOTH scalar and slots; keeps files/source chrome" do
      normalized =
        Slots.normalize_widget(%{
          "type" => "stage",
          "title" => "t",
          "detail" => "",
          "files" => "a.ex",
          "source" => true
        })

      assert normalized["title"] == "t"
      refute Map.has_key?(normalized, "detail")
      refute Map.has_key?(normalized["slots"], "detail")
      # files/source are chrome, NOT slots — pass through untouched.
      assert normalized["files"] == "a.ex"
      assert normalized["source"] == true
    end
  end

  describe "tier/1 classifier (delegates FULLY to Tiers)" do
    test "callout is a widget, section is a section, paragraph is an element" do
      assert Slots.tier(%{"type" => "callout"}) == :widget
      assert Slots.tier(%{"type" => "card"}) == :widget
      assert Slots.tier(%{"type" => "section"}) == :section
      assert Slots.tier(%{"type" => "paragraph"}) == :element
      assert Slots.tier(%{"type" => "image"}) == :element
      # Non-map / type-less defaults to element (legacy-safe).
      assert Slots.tier(%{}) == :element
      assert Slots.tier("nope") == :element
    end

    test "tier(card) resolves via the Tiers delegation (special-case removed)" do
      # The old Slots.tier/1 "card" special case is GONE — `card` is now a real
      # @widget type in Tiers, so tier/1 MUST agree with Tiers.tier_of/1 (proving the
      # single-classifier delegation, not a lingering hard-coded branch).
      assert Slots.tier(%{"type" => "card"}) == Barkpark.PortableDoc.Tiers.tier_of("card")
    end
  end

  describe "live-data task-list: query_decl/1 + normalize_widget/1 + query_type_errors/1" do
    defp live_tl(extra \\ %{}) do
      Map.merge(
        %{
          "id" => "t-1",
          "type" => "task-list",
          "query" => %{"label" => "proj:x"},
          "title" => "Plan"
        },
        extra
      )
    end

    defp snap_tl(extra \\ %{}) do
      Map.merge(
        %{
          "id" => "t-2",
          "type" => "task-list",
          "snapshot" => [%{"title" => "Pinned", "status" => "open"}]
        },
        extra
      )
    end

    test "query_decl/1 declares query(:when_live) + optional title/config for a task-list" do
      assert Slots.query_decl(%{"type" => "task-list"}) == [
               %{name: "query", kind: :query, required: :when_live},
               %{name: "title", kind: :string, required: false},
               %{name: "config", kind: :config, required: false}
             ]
    end

    test "query_decl/1 is [] for every non-task-list block" do
      assert Slots.query_decl(%{"type" => "callout"}) == []
      assert Slots.query_decl(%{"type" => "paragraph"}) == []
      assert Slots.query_decl(%{}) == []
    end

    test "normalize_widget/1 on a live task-list is idempotent AND lossless (query preserved exactly)" do
      block = live_tl(%{"config" => %{"limit" => 10, "fields" => ["title", "status"]}})
      once = Slots.normalize_widget(block)
      # lossless: same map back
      assert once == block
      # idempotent
      assert Slots.normalize_widget(once) == once
      # the query map survives byte-for-byte
      assert once["query"] == %{"label" => "proj:x"}
    end

    test "normalize_widget/1 passes a snapshot-only task-list through UNTOUCHED" do
      block = snap_tl()
      assert Slots.normalize_widget(block) == block
      # never gains a query key
      refute Map.has_key?(Slots.normalize_widget(block), "query")
    end

    test "query_type_errors/1 is [] for a snapshot-only (author-pinned) task-list" do
      assert Slots.query_type_errors(snap_tl()) == []
    end

    test "query_type_errors/1 is [] for a well-formed live query map" do
      assert Slots.query_type_errors(live_tl()) == []
      # an empty map is still a map → legal (the fetcher's tenant scoping owns row selection)
      assert Slots.query_type_errors(live_tl(%{"query" => %{}})) == []
    end

    test "query_type_errors/1 returns ONE calm error for a present-but-non-map query" do
      errors = Slots.query_type_errors(live_tl(%{"query" => "proj:x"}))
      assert length(errors) == 1
      assert hd(errors) =~ "task-list"
      assert hd(errors) =~ "must be a map"
    end

    test "query_type_errors/1 NEVER requires a query (no unconditional error) + is [] for non-task-list" do
      # a task-list with neither query nor snapshot still yields [] (never forced)
      assert Slots.query_type_errors(%{"id" => "t", "type" => "task-list"}) == []
      assert Slots.query_type_errors(%{"type" => "callout"}) == []
      assert Slots.query_type_errors(%{"type" => "paragraph"}) == []
    end
  end

  # A materialized-slot card fixture (STEP 4): a slots-native block, title + body
  # (extra merges over the top, e.g. to swap the `slots` map for a D1-violation case).
  defp card(extra \\ %{}) do
    Map.merge(
      %{
        "id" => "cw-1",
        "type" => "card",
        "tone" => "info",
        "slots" => %{
          "title" => [%{"type" => "heading", "text" => "Card"}],
          "body" => [%{"type" => "paragraph", "content" => plain()}]
        }
      },
      extra
    )
  end

  defp plain, do: [%{"type" => "text", "value" => "plain"}]

  describe "note widget — slot round-trip + compat-read + byte-identity accessors" do
    # A note in the FLAT wire form (label + lead + body `text`).
    defp note_flat(extra \\ %{}) do
      Map.merge(
        %{
          "id" => "nw-1",
          "type" => "note",
          "label" => "alive",
          "lead" => "Kept",
          "text" => "the body"
        },
        extra
      )
    end

    # The MATERIALIZED twin — the additive slots encoding of the SAME three strings.
    defp note_slotted(extra \\ %{}) do
      Map.merge(
        %{
          "id" => "nw-1",
          "type" => "note",
          "slots" => %{
            "label" => [
              %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "alive"}]}
            ],
            "lead" => [
              %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "Kept"}]}
            ],
            "body" => [
              %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "the body"}]}
            ]
          }
        },
        extra
      )
    end

    test "note_{label,lead,body}_text/1 yield the SAME three strings for BOTH encodings" do
      for enc <- [note_flat(), note_slotted()] do
        assert Slots.note_label_text(enc) == "alive"
        assert Slots.note_lead_text(enc) == "Kept"
        assert Slots.note_body_text(enc) == "the body"
      end
    end

    test "compat-read: a flat note with NO slots key synthesizes the 3 implicit paragraphs" do
      assert Slots.slot_elements(note_flat(), "label") ==
               [%{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "alive"}]}]

      assert Slots.slot_elements(note_flat(), "body") ==
               [
                 %{
                   "type" => "paragraph",
                   "content" => [%{"type" => "text", "value" => "the body"}]
                 }
               ]

      assert Slots.slot_elements(note_flat(), "lead") ==
               [%{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "Kept"}]}]
    end

    test "a bare legacy `notes` ITEM (no type key) reads through the flat fallback" do
      item = %{"label" => "x", "lead" => "L", "text" => "y"}
      assert Slots.note_label_text(item) == "x"
      assert Slots.note_lead_text(item) == "L"
      assert Slots.note_body_text(item) == "y"
    end

    test "an EMPTY lead synthesizes [] (arity {:max,1}) and reads back \"\"" do
      n = note_flat(%{"lead" => ""})
      assert Slots.slot_elements(n, "lead") == []
      assert Slots.note_lead_text(n) == ""
      # An absent lead key is likewise "" (nil-safe).
      assert Slots.note_lead_text(%{"type" => "note", "label" => "a", "text" => "b"}) == ""
    end

    test "the body slot FLATTENS inline marks to plain text (the lossy legacy contract)" do
      marked = [
        %{"type" => "text", "value" => "Be "},
        %{"type" => "strong", "children" => [%{"type" => "text", "value" => "bold"}]}
      ]

      n = %{
        "type" => "note",
        "slots" => %{"body" => [%{"type" => "paragraph", "content" => marked}]}
      }

      assert Slots.note_body_text(n) == "Be bold"
    end

    # ── top-level content[] (task-993d136b0fbf2fd1) ──────────────────────────
    #
    # A note persisted the WIDGET way — `{"type":"note","content":[…]}`, no flat
    # `text` — read "" through every path: the legacy synthesis wraps the ABSENT
    # `text` as an empty paragraph, which flattens to "". The reader served a
    # blank note (1 live block on guerrilla, full-corpus census 2026-07-25)
    # while `@barkpark/react` rendered it. `note_body_text/1` now falls back to
    # the block's top-level `content`, the `callout_body_inline/1` law.
    test "note_body_text/1 falls back to the block's top-level content[]" do
      n = %{
        "type" => "note",
        "label" => "Ops",
        "content" => [%{"type" => "text", "value" => "the widget body"}]
      }

      assert Slots.note_body_text(n) == "the widget body"
      # …and the label/lead are NOT polluted by the body's inline array.
      assert Slots.note_label_text(n) == "Ops"
      assert Slots.note_lead_text(n) == ""
    end

    test "the top-level content[] fallback flattens marks like the slot path" do
      n = %{
        "type" => "note",
        "content" => [
          %{"type" => "text", "value" => "Be "},
          %{"type" => "strong", "children" => [%{"type" => "text", "value" => "bold"}]}
        ]
      }

      assert Slots.note_body_text(n) == "Be bold"
    end

    test "a NON-EMPTY flat text or body slot still WINS over top-level content[]" do
      flat = %{
        "type" => "note",
        "text" => "the flat body",
        "content" => [%{"type" => "text", "value" => "ignored"}]
      }

      assert Slots.note_body_text(flat) == "the flat body"

      slotted = %{
        "type" => "note",
        "slots" => %{
          "body" => [
            %{
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "the slot body"}]
            }
          ]
        },
        "content" => [%{"type" => "text", "value" => "ignored"}]
      }

      assert Slots.note_body_text(slotted) == "the slot body"
    end

    test "a note with NEITHER text nor content[] still reads \"\" (nil-safe)" do
      assert Slots.note_body_text(%{"type" => "note", "label" => "L"}) == ""
      assert Slots.note_body_text(%{"type" => "note", "content" => %{}}) == ""
      assert Slots.note_body_text("not a map") == ""
    end

    # THE BOUNDARY the fallback must not cross. The silent-content-loss write
    # gate (`Barkpark.Content.Papers.NoteCardFieldLossTest`) REFUSES a note whose
    # prose was stranded under a SCALAR `content`, and it asks this very accessor
    # whether the reader shows anything. Consuming a bare string here would
    # silently disarm that ratchet, so the fallback takes a non-empty INLINE
    # ARRAY only — the same guard `callout_body_inline/1` holds.
    test "a SCALAR content stays unread, so the field-loss ratchet stays armed" do
      stranded = %{"id" => "n1", "type" => "note", "content" => "Stranded note prose"}
      assert Slots.note_body_text(stranded) == ""
      assert Slots.lossy_shape?(stranded)

      # …while the widget's INLINE-ARRAY content is real, rendered prose.
      widget = %{
        "id" => "n1",
        "type" => "note",
        "content" => [%{"type" => "text", "value" => "the widget body"}]
      }

      assert Slots.note_body_text(widget) == "the widget body"
      refute Slots.lossy_shape?(widget)
    end

    test "a content-only note is no longer BLANK to the reader (end-to-end HTML)" do
      html =
        Barkpark.PortableDoc.Render.render_blocks(
          [
            %{
              "id" => "n-1",
              "type" => "note",
              "label" => "Ops",
              "content" => [%{"type" => "text", "value" => "the widget body"}]
            }
          ],
          %{style: :article}
        )

      assert html =~ "the widget body"
    end

    test "normalize_widget dual-writes flat ⇄ slots and is IDEMPOTENT" do
      n = Slots.normalize_widget(note_flat())
      assert n["label"] == "alive"
      assert n["text"] == "the body"
      assert n["lead"] == "Kept"

      assert n["slots"]["label"] == [
               %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "alive"}]}
             ]

      assert n["slots"]["body"] == [
               %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "the body"}]}
             ]

      assert n["slots"]["lead"] == [
               %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "Kept"}]}
             ]

      # Idempotent, and a flat-form and slot-form note normalize to the SAME map.
      assert Slots.normalize_widget(n) == n
      assert Slots.normalize_widget(note_slotted()) == n
    end

    test "normalize_widget OMITS an empty/absent lead entirely (flat key AND slot), never \"\"" do
      n = Slots.normalize_widget(note_flat(%{"lead" => ""}))
      refute Map.has_key?(n, "lead")
      refute Map.has_key?(n["slots"], "lead")
      # Idempotent on the lead-less shape.
      assert Slots.normalize_widget(n) == n

      absent = Slots.normalize_widget(%{"type" => "note", "label" => "a", "text" => "b"})
      refute Map.has_key?(absent, "lead")
      refute Map.has_key?(absent["slots"], "lead")
    end

    test "slot_decls/1: 3 element slots — label exactly-1, lead max-1, body exactly-1" do
      assert Slots.slot_decls(%{"type" => "note"}) == [
               %{name: "label", tier: :element, count: {:exactly, 1}},
               %{name: "lead", tier: :element, count: {:max, 1}},
               %{name: "body", tier: :element, count: {:exactly, 1}}
             ]
    end

    test "D1 gate: a clean note is error-free; a nested widget in a slot reds" do
      assert Slots.slot_type_errors(note_flat()) == []
      assert Slots.slot_type_errors(note_slotted()) == []

      nested = %{
        "type" => "note",
        "slots" => %{
          "label" => [%{"type" => "callout", "content" => plain()}],
          "body" => [%{"type" => "paragraph", "content" => plain()}]
        }
      }

      errors = Slots.slot_type_errors(nested)
      refute errors == []
      assert Enum.any?(errors, &(&1 =~ ~s(the "label" slot accepts only element blocks)))
      assert Enum.any?(errors, &(&1 =~ "widget"))
    end

    test "Constraints.validate/2 folds in the note D1 gate (clean note zero-error)" do
      assert Constraints.validate([note_flat()], []) == []

      nested = %{
        "type" => "note",
        "slots" => %{"body" => [%{"type" => "section", "children" => []}]}
      }

      refute Constraints.validate([nested], []) == []
    end
  end

  # A WIRE-canonical (scalar) stage fixture: three text fields + source chrome.
  defp stage_scalar(extra \\ %{}) do
    Map.merge(
      %{
        "id" => "st-1",
        "type" => "stage",
        "kind" => "source",
        "title" => "emit",
        "detail" => "reads the queue",
        "source" => true
      },
      extra
    )
  end

  # The additive SLOTS encoding of the SAME stage (plain text runs, no marks).
  defp stage_slotted(extra \\ %{}) do
    Map.merge(
      %{
        "id" => "st-1",
        "type" => "stage",
        "source" => true,
        "slots" => %{
          "kind" => [
            %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "source"}]}
          ],
          "title" => [
            %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "emit"}]}
          ],
          "detail" => [
            %{
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "reads the queue"}]
            }
          ]
        }
      },
      extra
    )
  end
end
