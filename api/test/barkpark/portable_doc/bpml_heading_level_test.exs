defmodule Barkpark.PortableDoc.BpmlHeadingLevelTest do
  @moduledoc """
  `heading` is INSIDE the BPML kernel and the printer spells it — yet 26
  published papers answered 422 on `bp paper pull` with
  `block type "heading" is outside the BPML kernel vocabulary`. The guard read
  `when l in 1..3`, an INTEGER range, while the corpus stores 225 of its
  heading levels as numeric STRINGS. The whole paper became unpullable over the
  SPELLING of one scalar.

  This suite pins the coercion AND its two edges, because the edges are the
  whole risk: a level is the document OUTLINE, and a printer's output is what
  `bp paper push` writes back. Widening this into "guess a level" would rewrite
  papers nobody edited.

    * `"1"` / `"2"` / `"3"` print EXACTLY as `1` / `2` / `3`. The render side
      already collapses both spellings (`heading_level("2") -> 2`,
      `Barkpark.PortableDoc.Render.Compose`), so this spells what readers see.
    * A JUNK level (`"h2"`, `"w14-h2"`, `"state"`, `"4"`, `"01"`, `" 2"`) keeps
      raising the typed `UnprintableError` (charter D3 — fail honest, never a
      broadened rescue).
    * A NIL or ABSENT level keeps raising too. THE DECISION IS DELIBERATE and
      is recorded here as a test so it cannot drift: the renderer defaults a
      level-less heading to 2 (`heading_level(_) -> 2`), but that default is a
      DISPLAY choice the stored block survives. Printing it would persist the
      guess through push and restructure the outline of a paper the author
      never edited. 4 papers stay at 422 until someone states the level.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Bpml
  alias Barkpark.PortableDoc.Bpml.UnprintableError

  defp heading(level, extra \\ %{}) do
    Map.merge(%{"id" => "h", "type" => "heading", "level" => level, "text" => "Criteria"}, extra)
  end

  describe "numeric-string levels print as the integer they spell" do
    for {str, int} <- [{"1", 1}, {"2", 2}, {"3", 3}] do
      test "level #{inspect(str)} prints the same BPML as #{int}" do
        assert Bpml.print_blocks([heading(unquote(str))]) ==
                 Bpml.print_blocks([heading(unquote(int))])

        assert Bpml.print_blocks([heading(unquote(str))]) ==
                 ~s(<h#{unquote(int)} id="h">Criteria</h#{unquote(int)}>\n)
      end
    end

    test "the coercion reaches the alias-keyed (content) heading body too" do
      block =
        heading("2", %{"text" => nil, "content" => [%{"type" => "text", "value" => "Body"}]})

      assert Bpml.print_blocks([block]) == ~s(<h2 id="h">Body</h2>\n)
    end

    test "a string-level heading round-trips to the canonical INTEGER level" do
      first = Bpml.print_blocks([heading("3")])

      assert {:ok, [parsed]} = Bpml.parse_blocks(first)
      assert parsed["level"] == 3
      assert Bpml.print_blocks([parsed]) == first
    end

    test "a whole paper of string-level headings prints instead of refusing" do
      blocks = [
        heading("1", %{"id" => "a"}),
        heading("2", %{"id" => "b"}),
        heading("3", %{"id" => "c"})
      ]

      bpml = Bpml.print_blocks(blocks)

      assert bpml =~ ~s(<h1 id="a">)
      assert bpml =~ ~s(<h2 id="b">)
      assert bpml =~ ~s(<h3 id="c">)
    end
  end

  describe "the coercion does not widen into guessing an outline level" do
    # The junk spellings the census actually found, plus the near-misses that
    # would fall out of a lazier coercion (`String.to_integer/1` on anything
    # numeric-ish, a trimmed parse, an out-of-range level).
    for junk <- [
          "h2",
          "w14-h2",
          "h3",
          "state",
          "live",
          "w14-h-ledger",
          "4",
          "0",
          "01",
          " 2",
          "2 ",
          "two",
          ""
        ] do
      test "junk level #{inspect(junk)} still raises the typed refusal" do
        e = assert_raise UnprintableError, fn -> Bpml.print_blocks([heading(unquote(junk))]) end

        assert e.kind == :block
        assert e.type == "heading"
        assert Exception.message(e) =~ ~s(block type "heading")
      end
    end

    test "an out-of-range INTEGER level is unchanged — it still refuses" do
      e = assert_raise UnprintableError, fn -> Bpml.print_blocks([heading(4)]) end
      assert e.kind == :block
    end
  end

  describe "a level-less heading keeps refusing (the recorded decision)" do
    test "an explicit nil level refuses rather than defaulting to the renderer's 2" do
      e = assert_raise UnprintableError, fn -> Bpml.print_blocks([heading(nil)]) end

      assert e.kind == :block
      assert e.type == "heading"
    end

    test "an ABSENT level key refuses too" do
      block = %{"id" => "h", "type" => "heading", "text" => "Criteria"}

      e = assert_raise UnprintableError, fn -> Bpml.print_blocks([block]) end

      assert e.kind == :block
      assert e.type == "heading"
    end

    test "the renderer's own default is 2 — the divergence is the point, not an oversight" do
      # Cited, not asserted from memory: the render side DOES default a
      # level-less (and a junk-level) heading to 2, and this printer
      # deliberately declines to borrow that default because its output is
      # persisted by `bp paper push`, not merely displayed.
      compose = &Barkpark.PortableDoc.Render.Compose.compose_block(&1, :article)

      assert %{"kind" => "PdHeading", "level" => 2} =
               compose.(%{"id" => "h", "type" => "heading", "text" => "Criteria"})

      assert %{"kind" => "PdHeading", "level" => 2} =
               compose.(%{"id" => "h", "type" => "heading", "level" => "w14-h2", "text" => "C"})

      # …and it collapses the numeric-string spelling exactly as the printer
      # now does, which is why THAT coercion invents nothing.
      assert %{"kind" => "PdHeading", "level" => 3} =
               compose.(%{"id" => "h", "type" => "heading", "level" => "3", "text" => "C"})
    end
  end
end
