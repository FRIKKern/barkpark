defmodule Barkpark.PortableDoc.BpmlUnprintableTest do
  @moduledoc """
  The printer is TOTAL: every shape outside the BPML kernel vocabulary raises
  the ONE typed refusal, `Bpml.UnprintableError`, tagged with the position that
  could not be spelled (`:block` | `:inline` | `:mark` | `:head_cell`).

  Wave-3 inline-vocabulary update: the four shapes #11758 refused as a honest
  stopgap are now SPELLED, not refused — node-spelled `code`/`strong`/`em`
  inline marks, raw-string inline runs, non-list inline content, and bare-string
  head cells all print (their positive round-trips live in `BpmlTest`). What
  STAYS refused is the honest-refusal core: `valueref` (12 papers — resolves
  against live data the printer cannot reach) and a `paragraph` inline node
  (20 papers — a BLOCK, unspellable inline) both raise kind `:inline`; a
  head-cell map without a binary `"text"` still raises kind `:head_cell` rather
  than dropping the cell with a 200; and every genuinely-unknown block/mark/
  inline type still raises rather than crashing to a 500.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Bpml
  alias Barkpark.PortableDoc.Bpml.UnprintableError

  defp refusal(blocks) do
    assert_raise UnprintableError, fn -> Bpml.print_blocks(blocks) end
  end

  defp p(content), do: %{"id" => "p1", "type" => "paragraph", "content" => content}

  describe "kind: :block" do
    test "a block type outside the kernel names the type" do
      e = refusal([%{"id" => "i1", "type" => "image"}])

      assert e.kind == :block
      assert e.type == "image"
      assert Exception.message(e) =~ ~s(block type "image")
      assert Exception.message(e) =~ "kind: block"
    end

    test "a block map with NO type refuses instead of crashing on a missing clause" do
      e = refusal([%{"id" => "x1", "text" => "orphaned"}])

      assert e.kind == :block
      assert e.type == nil
      assert Exception.message(e) =~ ~s(carries no "type")
    end
  end

  describe "kind: :inline (the honest-refusal core that STAYS refused)" do
    test "a valueref inline node stays refused — it resolves against live data" do
      e = refusal([p([%{"type" => "valueref", "ref" => "stats.total"}])])

      assert e.kind == :inline
      assert e.type == "valueref"
      assert Exception.message(e) =~ ~s(inline node type "valueref")
    end

    test "a paragraph inline node stays refused — a block is unspellable inline" do
      e = refusal([p([%{"type" => "paragraph", "content" => []}])])

      assert e.kind == :inline
      assert e.type == "paragraph"
      assert Exception.message(e) =~ ~s(inline node type "paragraph")
    end

    test "a code node smuggling children refuses — printing the value alone would drop them" do
      e = refusal([p([%{"type" => "code", "children" => [%{"type" => "text", "value" => "x"}]}])])

      assert e.kind == :inline
      assert e.type == "code"
    end

    test "a strong/em node smuggling its text in value refuses — <b></b> would drop it" do
      for type <- ["strong", "em"] do
        e = refusal([p([%{"type" => type, "value" => "smuggled"}])])
        assert e.kind == :inline
        assert e.type == type
      end
    end

    test "genuinely untyped inline content (a number cell) still refuses" do
      e =
        refusal([
          %{
            "id" => "t1",
            "type" => "table",
            "rows" => [[42]]
          }
        ])

      assert e.kind == :inline
      assert e.type == nil
    end
  end

  describe "kind: :mark" do
    test "a mark outside strong|em|code|underline|strike names the mark" do
      e = refusal([p([%{"type" => "text", "value" => "x", "marks" => ["highlight"]}])])

      assert e.kind == :mark
      assert e.type == "highlight"
      assert Exception.message(e) =~ ~s(inline mark type "highlight")
    end
  end

  describe "kind: :head_cell (the silent-loss path)" do
    # SUPERSEDED shape: a `%{"content" => inline_nodes}` head cell used to refuse
    # here, because the alternative at the time was printing an EMPTY cell. It
    # is spellable — the nodes are an ordinary inline list — so it now PRINTS.
    # Refusing a body the kernel can spell is not honesty, it is just a
    # narrower loss: the author cannot pull the paper at all.
    test "a %{\"content\" => inline_nodes} head cell PRINTS (it is spellable)" do
      blocks = [
        %{
          "id" => "t1",
          "type" => "table",
          "head" => [%{"content" => [%{"type" => "text", "value" => "Claim"}]}],
          "rows" => [[[%{"type" => "text", "value" => "a"}]]]
        }
      ]

      assert Bpml.print_blocks(blocks) =~ "<th>Claim</th>"
    end

    # The refusal core survives: a head cell carrying NO readable body at all
    # still raises kind :head_cell rather than printing an empty <th>.
    test "a head-cell map with no readable body still refuses" do
      blocks = [
        %{
          "id" => "t1",
          "type" => "table",
          "head" => [%{"tone" => "warn"}],
          "rows" => [[[%{"type" => "text", "value" => "a"}]]]
        }
      ]

      e = refusal(blocks)

      assert e.kind == :head_cell
    end

    test "the LEGACY %{\"text\" => binary} head cell still prints — no regression" do
      blocks = [
        %{
          "id" => "t1",
          "type" => "table",
          "head" => [%{"text" => "Claim"}],
          "rows" => [[[%{"type" => "text", "value" => "a"}]]]
        }
      ]

      assert Bpml.print_blocks(blocks) =~ "<th>Claim</th>"
    end
  end

  describe "the refusal is a 422, never a 500" do
    test "Plug.Exception status is 422 as an unrescued backstop" do
      assert Plug.Exception.status(UnprintableError.new(:block, "image")) == 422
    end

    test "every kind is one of the four declared positions" do
      assert UnprintableError.kinds() == [:block, :inline, :mark, :head_cell]
    end
  end
end
