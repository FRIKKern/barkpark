defmodule Barkpark.PortableDoc.BpmlUnprintableTest do
  @moduledoc """
  The printer is TOTAL: every shape outside the BPML kernel vocabulary raises
  the ONE typed refusal, `Bpml.UnprintableError`, tagged with the position that
  could not be spelled (`:block` | `:inline` | `:mark` | `:head_cell`).

  These are the verify-round probes made permanent. Before them the printer had
  exactly one honest refusal (unknown block type → `ArgumentError`) and three
  crash shapes that escaped every caller's rescue as a raw HTTP 500 — 141 of 776
  published papers on the 2026-08-17 full-corpus census
  (`tooling/grip/ledger/bpml-full-corpus-census-2026-08-17.md`: 113 unknown
  inline node type, 18 raw-string inline child, 16 `inline/1` on a non-list,
  6 bare-string head cell) — plus one SILENT LOSS: a head-cell map without a
  binary `"text"` printed `""`, dropping the cell with a 200.
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
      e = refusal([%{"id" => "d1", "type" => "divider"}])

      assert e.kind == :block
      assert e.type == "divider"
      assert Exception.message(e) =~ ~s(block type "divider")
      assert Exception.message(e) =~ "kind: block"
    end

    test "a block map with NO type refuses instead of crashing on a missing clause" do
      e = refusal([%{"id" => "x1", "text" => "orphaned"}])

      assert e.kind == :block
      assert e.type == nil
      assert Exception.message(e) =~ ~s(carries no "type")
    end
  end

  describe "kind: :inline" do
    test "an inline node type with no clause names the type — the whole 500 class" do
      e = refusal([p([%{"type" => "code", "value" => "mix test"}])])

      assert e.kind == :inline
      assert e.type == "code"
      assert Exception.message(e) =~ ~s(inline node type "code")
    end

    test "a raw string where an inline NODE belongs refuses" do
      e = refusal([p(["just a string"])])

      assert e.kind == :inline
      assert e.type == nil
    end

    test "inline content that is not a list at all (a string table cell) refuses" do
      e =
        refusal([
          %{
            "id" => "t1",
            "type" => "table",
            "rows" => [["a string cell"]]
          }
        ])

      assert e.kind == :inline
      assert e.type == nil
      assert Exception.message(e) =~ "not a typed inline node"
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
    test "a head-cell map without a binary \"text\" refuses instead of printing an empty cell" do
      blocks = [
        %{
          "id" => "t1",
          "type" => "table",
          "head" => [%{"content" => [%{"type" => "text", "value" => "Claim"}]}],
          "rows" => [[[%{"type" => "text", "value" => "a"}]]]
        }
      ]

      e = refusal(blocks)

      assert e.kind == :head_cell
      assert Exception.message(e) =~ "inline-node list"
    end

    test "a bare-string head cell refuses (census: 6 papers, formerly a 500)" do
      blocks = [
        %{
          "id" => "t1",
          "type" => "table",
          "head" => ["Claim"],
          "rows" => [[[%{"type" => "text", "value" => "a"}]]]
        }
      ]

      assert refusal(blocks).kind == :head_cell
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
      assert Plug.Exception.status(UnprintableError.new(:block, "divider")) == 422
    end

    test "every kind is one of the four declared positions" do
      assert UnprintableError.kinds() == [:block, :inline, :mark, :head_cell]
    end
  end
end
