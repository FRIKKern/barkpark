defmodule Barkpark.PortableDoc.BpmlSectionVariantTest do
  @moduledoc """
  BPML leg of the framed-finale section variant (charter D19) — the
  THREE-POINT grammar change: parser attr allowlist (`section` now admits
  `variant`), `put_attr("variant", …)` in BOTH `build_block` section branches
  (self-closed and children-bearing), and the printer's
  `attr_str(b, ["id","title","variant"])`.

  The parser HARD-ERRORS unknown attrs (the silent-drop premise was refuted in
  the wave-3 spike), so without the allowlist entry a printed framed section
  could never re-parse — the round-trip below is the whole proof.

  SCALAR GUARD: `attr_str`'s `to_string/1` raises `Protocol.UndefinedError` on
  a map, so a map-valued `variant` is DROPPED by the printer (fail-soft),
  never crashed.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Bpml
  alias Barkpark.PortableDoc.Bpml.UnprintableError

  @framed %{
    "id" => "s1",
    "type" => "section",
    "title" => "Finale",
    "variant" => "framed",
    "blocks" => [
      %{
        "id" => "p1",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "closing"}]
      }
    ]
  }

  describe "round-trip" do
    test "a framed section round-trips parse(print(blocks)) == blocks" do
      bpml = Bpml.print_blocks([@framed])
      assert bpml =~ ~s(<section id="s1" title="Finale" variant="framed">)
      assert {:ok, [parsed]} = Bpml.parse_blocks(bpml)
      assert parsed == @framed
    end

    test "a SELF-CLOSED framed section keeps the variant (second build_block branch)" do
      assert {:ok, [block]} = Bpml.parse_blocks(~s(<section id="s2" variant="framed"/>))
      assert block["variant"] == "framed"
      assert block["blocks"] == []

      # And it round-trips back through the printer.
      assert {:ok, [^block]} = Bpml.parse_blocks(Bpml.print_blocks([block]))
    end

    test "a variant-less section prints WITHOUT the attr (byte-identity with the pre-hook printer)" do
      plain = Map.delete(@framed, "variant")
      bpml = Bpml.print_blocks([plain])
      refute bpml =~ "variant"
      assert {:ok, [parsed]} = Bpml.parse_blocks(bpml)
      assert parsed == plain
    end

    test "an arbitrary scalar variant value rides the round-trip (data, not a whitelist)" do
      odd = Map.put(@framed, "variant", "future-variant")
      assert {:ok, [parsed]} = Bpml.parse_blocks(Bpml.print_blocks([odd]))
      assert parsed == odd
    end
  end

  describe "scalar guard" do
    # The text cannot carry a non-scalar variant, so the print is refused
    # (kind :round_trip) naming it, never printed without it and never crashed.
    test "a map-valued variant is refused by the printer, naming it, never crashed" do
      poisoned = Map.put(@framed, "variant", %{"deep" => "map"})
      e = assert_raise UnprintableError, fn -> Bpml.print_blocks([poisoned]) end
      assert e.kind == :round_trip
      assert e.type == "blocks[0].variant"
    end

    test "a list-valued variant is likewise refused" do
      poisoned = Map.put(@framed, "variant", ["framed"])
      e = assert_raise UnprintableError, fn -> Bpml.print_blocks([poisoned]) end
      assert e.type == "blocks[0].variant"
    end
  end
end
