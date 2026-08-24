defmodule Barkpark.PortableDoc.BpmlRoundtripPropertyTest do
  @moduledoc """
  The working-copy round-trip property: `bp paper pull` → edit → `bp paper push`
  must never destroy what it did not show the author.

  The Go CLI is a byte pipe (`internal/apiclient/paper.go` — it never parses
  BPML), so the ONLY place the loop can lose content is this printer and the
  controller that feeds it. Every loss below was measured against the published
  corpus (1015 papers): the printer reads ONE key per block type while the
  corpus also stores the same body under an ALIAS key, so the element prints
  EMPTY, the pull answers 200, and the next push writes the emptiness back.

  ## The property

  For a block whose body is non-empty under EITHER the canonical key or a known
  alias, the printed BPML must contain that body. Anything the kernel vocabulary
  genuinely cannot spell must raise `UnprintableError` (an honest 422) — never a
  lossy `""`.

  ## Named carve-outs

  These are NOT losses, and the suite states them so it cannot be quietly
  weakened into proving nothing:

    * **Alias keys are CANONICALIZED, not preserved.** A `text`-keyed paragraph
      returns as `content`-keyed; a `children`-keyed section returns as
      `blocks`-keyed. The BODY is the invariant, not the spelling. This is the
      same read-tolerance/canonical-write rule `head_cell/2` already documents.
      The proof that canonicalization is not loss is IDEMPOTENCE (below).
    * **Server-assigned fields never enter the paper map** and so cannot round
      trip: `_rev`/`rev`, `doc_id`, `inserted_at`/`updated_at`, `status`,
      `comment_count`, and the transport's `kind`. `print_paper/1` is handed
      `slug`/`title`/`description`/`tags`/`blocks` and nothing else.
    * **A non-scalar `variant` is dropped** — the pre-existing, documented
      fail-soft in `drop_nonscalar_variant/1`. A hand-authored map there is
      noise, not a paper body.
    * **A MARKED-UP `heading`/`eyebrow` body refuses rather than flattening.**
      `<h2>` and `<eyebrow>` hold plain escaped text — they cannot spell marks.
      Flattening would silently drop the bold/link, so the honest answer is the
      typed refusal. Only an UNMARKED content array flattens (lossless).
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Bpml
  alias Barkpark.PortableDoc.Bpml.UnprintableError

  # The inline text node is spelled LITERALLY below: the case tables are module
  # attributes, evaluated at compile time, so they cannot call a helper defined
  # in this same module (neither a `defp` nor a `defmacrop`).

  defp print(block), do: Bpml.print_blocks([block])

  # ── the measured loss set ───────────────────────────────────────────────────
  #
  # {label, block, sentinel} — the sentinel is the body the corpus stores and
  # the printer currently drops. Each is its own test so a run enumerates the
  # WHOLE loss set instead of stopping at the first failure.

  @alias_cases [
    {"heading text<-content (2711 blocks / 135 papers — the dominant leg)",
     %{
       "id" => "b1",
       "type" => "heading",
       "level" => 2,
       "content" => [%{"type" => "text", "value" => "HEADING_BODY"}]
     }, "HEADING_BODY"},
    {"paragraph content<-text (238 / 32)",
     %{"id" => "b2", "type" => "paragraph", "text" => "PARAGRAPH_BODY"}, "PARAGRAPH_BODY"},
    {"table head<-header (154 / 32)",
     %{
       "id" => "b3",
       "type" => "table",
       "header" => ["HEAD_HEADER"],
       "rows" => [[[%{"type" => "text", "value" => "r"}]]]
     }, "HEAD_HEADER"},
    {"table head<-columns (105 / 11)",
     %{
       "id" => "b4",
       "type" => "table",
       "columns" => ["HEAD_COLUMNS"],
       "rows" => [[[%{"type" => "text", "value" => "r"}]]]
     }, "HEAD_COLUMNS"},
    {"table head<-headers (46 / 6)",
     %{
       "id" => "b5",
       "type" => "table",
       "headers" => ["HEAD_HEADERS"],
       "rows" => [[[%{"type" => "text", "value" => "r"}]]]
     }, "HEAD_HEADERS"},
    {"expandable summary<-title (50 / 14)",
     %{"id" => "b6", "type" => "expandable", "title" => "EXPANDABLE_SUMMARY", "blocks" => []},
     "EXPANDABLE_SUMMARY"},
    {"code value<-code (38 / 18)", %{"id" => "b7", "type" => "code", "code" => "CODE_CODE"},
     "CODE_CODE"},
    {"code value<-content (9 / 6)",
     %{"id" => "b8", "type" => "code", "content" => "CODE_CONTENT"}, "CODE_CONTENT"},
    {"code value<-text (6 / 4)", %{"id" => "b9", "type" => "code", "text" => "CODE_TEXT"},
     "CODE_TEXT"},
    {"ingress content<-text (32 / 32)",
     %{"id" => "b10", "type" => "ingress", "text" => "INGRESS_BODY"}, "INGRESS_BODY"},
    {"section blocks<-children (7 / 2 — the WHOLE nested subtree vanishes)",
     %{
       "id" => "b11",
       "type" => "section",
       "children" => [
         %{
           "id" => "n1",
           "type" => "paragraph",
           "content" => [%{"type" => "text", "value" => "SECTION_CHILD"}]
         }
       ]
     }, "SECTION_CHILD"},
    {"eyebrow text<-content (4 / 4)",
     %{
       "id" => "b12",
       "type" => "eyebrow",
       "content" => [%{"type" => "text", "value" => "EYEBROW_BODY"}]
     }, "EYEBROW_BODY"},
    {"pullquote content<-text (4 / 4)",
     %{"id" => "b13", "type" => "pullquote", "text" => "PULLQUOTE_BODY"}, "PULLQUOTE_BODY"},
    {"byline items<-content (2 / 2)",
     %{"id" => "b14", "type" => "byline", "content" => ["BYLINE_ITEM"]}, "BYLINE_ITEM"},
    {"steps steps<-items (1 / 1)",
     %{
       "id" => "b15",
       "type" => "steps",
       "items" => [%{"title" => "STEP_TITLE", "blocks" => []}]
     }, "STEP_TITLE"}
  ]

  describe "no silent body loss — a non-empty alias body must reach the BPML" do
    for {label, block, sentinel} <- @alias_cases do
      @block block
      @sentinel sentinel
      test label do
        bpml = print(@block)

        assert String.contains?(bpml, @sentinel),
               """
               SILENT LOSS: the block carries a non-empty body under an alias key,
               but the printed BPML does not contain it. `bp paper push` writes this
               emptiness back over the stored paper.

               block: #{inspect(@block)}
               bpml:  #{inspect(bpml)}
               """
      end
    end
  end

  describe "canonical keys keep working (control — these must never regress)" do
    test "a content-keyed paragraph prints its body" do
      assert print(%{
               "id" => "c1",
               "type" => "paragraph",
               "content" => [%{"type" => "text", "value" => "CANON_P"}]
             }) =~
               "CANON_P"
    end

    test "a text-keyed heading prints its body" do
      assert print(%{"id" => "c2", "type" => "heading", "level" => 2, "text" => "CANON_H"}) =~
               "CANON_H"
    end

    test "a head-keyed table prints its head" do
      assert print(%{"id" => "c3", "type" => "table", "head" => ["CANON_TH"], "rows" => []}) =~
               "CANON_TH"
    end

    test "a blocks-keyed section prints its children" do
      block = %{
        "id" => "c4",
        "type" => "section",
        "blocks" => [
          %{
            "id" => "c4a",
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "CANON_SEC"}]
          }
        ]
      }

      assert print(block) =~ "CANON_SEC"
    end
  end

  describe "canonicalization is not loss — the second print is byte-stable" do
    for {label, block, _sentinel} <- @alias_cases do
      @block block
      test "idempotent: #{label}" do
        once = print(@block)
        assert {:ok, parsed} = Bpml.parse_blocks(once)
        twice = Bpml.print_blocks(parsed)

        assert twice == once,
               """
               An alias body is allowed to be REKEYED to its canonical spelling,
               but printing the parse must then be a fixed point. It is not, so the
               round trip is still moving content.

               once:  #{inspect(once)}
               twice: #{inspect(twice)}
               """
      end
    end
  end

  describe "paper metadata survives the round trip" do
    @paper %{
      "slug" => "roundtrip-fixture",
      "title" => "Round-trip fixture",
      "description" => "A paper carrying description and weighted tags through BPML.",
      "tags" => [
        %{"tag" => "bulldocs", "strength" => 95, "rationale" => "The authoring surface."},
        %{"tag" => "portabledoc", "strength" => 80, "rationale" => "The serializer."}
      ],
      "blocks" => [
        %{
          "id" => "p1",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "body"}]
        }
      ]
    }

    test "description and weighted tags print and re-parse" do
      bpml = Bpml.print_paper(@paper)
      assert {:ok, parsed} = Bpml.parse_paper(bpml)

      assert parsed["slug"] == @paper["slug"]
      assert parsed["title"] == @paper["title"]
      assert parsed["description"] == @paper["description"]
      assert parsed["tags"] == @paper["tags"]
      assert parsed["blocks"] == @paper["blocks"]
    end
  end

  describe "carve-out: an unspellable body refuses instead of printing empty" do
    test "a MARKED-UP heading content raises rather than flattening away the mark" do
      block = %{
        "id" => "m1",
        "type" => "heading",
        "level" => 2,
        "content" => [
          %{"type" => "text", "value" => "plain "},
          %{"type" => "text", "value" => "bold", "marks" => ["strong"]}
        ]
      }

      assert_raise UnprintableError, fn -> print(block) end
    end

    test "a MARKED-UP eyebrow content raises rather than flattening away the mark" do
      block = %{
        "id" => "m2",
        "type" => "eyebrow",
        "content" => [%{"type" => "text", "value" => "bold", "marks" => ["strong"]}]
      }

      assert_raise UnprintableError, fn -> print(block) end
    end

    test "an UNMARKED heading content flattens losslessly (the allowed case)" do
      block = %{
        "id" => "m3",
        "type" => "heading",
        "level" => 2,
        "content" => [
          %{"type" => "text", "value" => "plain "},
          %{"type" => "text", "value" => "and more"}
        ]
      }

      assert print(block) =~ "plain and more"
    end
  end
end
