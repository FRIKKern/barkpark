defmodule Barkpark.Content.PortableTextAdoptKeysTest do
  @moduledoc """
  task-dc8eaead5484fd12 (#28360 review): an edited block took the `_key` and
  fields of the stored block at its index. A paragraph added above an edited
  one in one post took the edited one's key and its `anchor`, and the edited
  one got a new key; TanStack matches blocks by `_key`. It now takes them
  from the stored block it replaces (`PortableTextPairing`).
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.PortableText

  defp span(k, t), do: %{"_type" => "span", "_key" => k, "text" => t, "marks" => []}

  defp block(k, text, extra \\ %{}) do
    Map.merge(
      %{
        "_type" => "block",
        "_key" => k,
        "style" => "normal",
        "markDefs" => [],
        "children" => [span(k <> "s", text)]
      },
      extra
    )
  end

  # What the editor posts after `edit`, read against `stored`.
  defp save(stored, edit), do: PortableText.from_html(PortableText.to_html(edit), stored)

  defp keyed(out, text), do: Enum.find(out, &(words(&1) == text))

  defp words(b), do: Enum.map_join(b["children"], "", & &1["text"])

  defp new(text), do: block("new", text)

  setup do
    p1 = block("k1", "The quick brown fox jumps over the lazy dog", %{"anchor" => "intro"})
    p2 = block("k2", "A second paragraph that stays as it was", %{"anchor" => "second"})
    {:ok, p1: p1, p2: p2}
  end

  test "a block inserted above an edited block takes neither its key nor its fields",
       %{p1: p1, p2: p2} do
    edited = block("k1", "The quick brown fox leaps over the lazy dog")
    out = save([p1, p2], [new("A brand new opening line"), edited, p2])

    assert keyed(out, "The quick brown fox leaps over the lazy dog")["_key"] == "k1"
    assert keyed(out, "The quick brown fox leaps over the lazy dog")["anchor"] == "intro"
    assert keyed(out, "A brand new opening line")["_key"] not in ["k1", "k2"]
    refute Map.has_key?(keyed(out, "A brand new opening line"), "anchor")
    assert keyed(out, "A second paragraph that stays as it was") == p2
  end

  test "the same with nothing after the edited block", %{p1: p1} do
    edited = block("k1", "The quick brown fox leaps over the lazy dog")
    out = save([p1], [new("A brand new opening line"), edited])

    assert keyed(out, "The quick brown fox leaps over the lazy dog")["_key"] == "k1"
    assert keyed(out, "The quick brown fox leaps over the lazy dog")["anchor"] == "intro"
    refute Map.has_key?(keyed(out, "A brand new opening line"), "anchor")
  end

  test "a block inserted between two edited blocks: each keeps its own", %{p1: p1, p2: p2} do
    e1 = block("k1", "The quick brown fox leaps over the lazy dog")
    e2 = block("k2", "A second paragraph that changed from what it was")
    out = save([p1, p2], [e1, new("Something in the middle"), e2])

    assert keyed(out, words(e1))["_key"] == "k1"
    assert keyed(out, words(e2))["_key"] == "k2"
    assert keyed(out, words(e2))["anchor"] == "second"
    refute Map.has_key?(keyed(out, "Something in the middle"), "anchor")
  end

  test "an edited block whose neighbour was deleted keeps its key", %{p1: p1, p2: p2} do
    e2 = block("k2", "A second paragraph that changed from what it was")
    out = save([p1, p2], [e2])

    assert [%{"_key" => "k2", "anchor" => "second"}] = out
  end

  test "a block rewritten in place, one for one, keeps its key", %{p1: p1, p2: p2} do
    out = save([p1, p2], [block("k1", "Nothing in common at all"), p2])

    assert keyed(out, "Nothing in common at all")["_key"] == "k1"
    assert keyed(out, "Nothing in common at all")["anchor"] == "intro"
  end

  # Beside an insert, a rewrite with no words in common cannot be told from
  # a new block: neither takes the stored block's key.
  test "an insert beside a rewrite with no words in common moves no key", %{p1: p1, p2: p2} do
    out = save([p1, p2], [new("A brand new opening line"), block("k1", "Nothing in common"), p2])

    refute Enum.any?(out, &(&1["_key"] == "k1"))
    refute Enum.any?(out, &(&1["anchor"] == "intro"))
  end
end
