defmodule Barkpark.PortableDoc.BpmlCanonicalTest do
  @moduledoc """
  `Bpml.Canonical.normalize/1`, the thirteen rewrites the print check allows,
  and nothing more. Over every stored document the suite carries, and in each
  rule's own case, nothing is lost: no character, no mark on a character, no
  link, no checked state, no block, no item child, no slot. Each alias the
  printer reads moves its body whole; and a block whose two names hold
  different bodies is not normalised away, so the print of it is refused.
  """
  use ExUnit.Case, async: true

  alias Barkpark.BpmlStoredDocuments
  alias Barkpark.PortableDoc.Bpml
  alias Barkpark.PortableDoc.Bpml.{Canonical, UnprintableError}
  alias Barkpark.PortableDoc.Bpml.Canonical.AliasKey
  alias Barkpark.PortableDoc.Render

  @printer Path.expand("../../../lib/barkpark/portable_doc/bpml/printer.ex", __DIR__)

  defp t(v), do: %{"type" => "text", "value" => v}

  defp carried!(blocks) do
    printed = Bpml.print_blocks(blocks)
    assert {:ok, parsed} = Bpml.parse_blocks(printed)
    assert parsed == Canonical.normalize(blocks)
    parsed
  end

  defp refused!(blocks) do
    e = assert_raise UnprintableError, fn -> Bpml.print_blocks(blocks) end
    assert e.kind == :round_trip
    e
  end

  test "the definition is closed: thirteen rewrites" do
    assert length(Canonical.rules()) == 13
  end

  # ── rule 6: the copied list and the printer's own reads ──────────────────────

  # Every `alias_get(x, [...])`, `plain_alias(x, [...])` and `plain_body(x, [...])`
  # key list in printer.ex with more than one key.
  defp printer_reads(source \\ File.read!(@printer)) do
    ~r/(?:alias_get|plain_alias|plain_body)\(\s*\w+,\s*(\[[^\]]*\])\s*\)/s
    |> Regex.scan(source, capture: :all_but_first)
    |> Enum.map(fn [list] -> Regex.scan(~r/"([^"]+)"/, list, capture: :all_but_first) end)
    |> Enum.map(&List.flatten/1)
    |> Enum.filter(&(length(&1) > 1))
    |> Enum.uniq()
  end

  defp ends_with?(order, tail), do: Enum.take(order, -length(tail)) == tail

  test "the scan reads a call split over lines" do
    source = """
    alias_get(
      b,
      ["one", "two"]
    )
    """

    assert printer_reads(source) == [["one", "two"]]
  end

  test "every alias the printer reads is in the copied list, and every copied read is one the printer makes" do
    reads = Enum.map(AliasKey.reads(), &elem(&1, 3))
    assert printer_reads() != []

    for tail <- printer_reads() do
      assert Enum.any?(reads, &ends_with?(&1, tail)),
             "printer.ex reads #{inspect(tail)}; Canonical.AliasKey.reads/0 lacks it"
    end

    for order <- reads do
      assert Enum.any?(printer_reads(), &ends_with?(order, &1)),
             "Canonical.AliasKey reads #{inspect(order)}, which printer.ex does not"
    end
  end

  # One case per aliased key: a golden block with its body moved from the key
  # the parser writes to the alias prints, round-trips, and normalizes to the
  # golden itself.
  @golden_for %{"quote" => "blockquote"}

  # Goldens that do not print at all (a heading with no level in the section
  # golden, a link annotation mark in the paragraph golden): a plain sample.
  @plain_para %{
    "type" => "paragraph",
    "content" => [%{"type" => "text", "value" => "Plain words."}]
  }
  @samples %{
    "section" => %{"type" => "section", "blocks" => [@plain_para]},
    "paragraph" => @plain_para
  }

  for {type, scope, key, order, _shape} <- AliasKey.reads(), ak <- order, ak != key do
    test "#{type}: a body under #{inspect(ak)} moves whole to #{inspect(key)}" do
      type = unquote(type)

      golden =
        Map.get_lazy(@samples, type, fn ->
          BpmlStoredDocuments.golden(Map.get(@golden_for, type, type)) |> Map.put("type", type)
        end)

      aliased = move_key(golden, unquote(Macro.escape(scope)), unquote(key), unquote(ak))

      refute aliased == golden
      carried!([aliased])
      assert Canonical.normalize([aliased]) == Canonical.normalize([golden])
    end
  end

  defp move_key(m, :block, from, to), do: rename(m, from, to)

  defp move_key(m, {:each, list_key}, from, to),
    do: Map.update!(m, list_key, &Enum.map(&1, fn item -> rename(item, from, to) end))

  defp rename(m, from, to) when is_map_key(m, from) do
    {v, rest} = Map.pop!(m, from)
    Map.put(rest, to, v)
  end

  defp rename(m, _from, _to), do: m

  test "a block whose two names hold different bodies is not normalised away, and is refused" do
    both = %{"type" => "paragraph", "content" => [t("shown")], "text" => "dropped by the print"}
    assert Canonical.normalize([both]) == [both]
    assert refused!([both]).type =~ "blocks[0]"

    heading = %{"type" => "heading", "level" => 2, "text" => "shown", "content" => [t("hidden")]}
    refused!([heading])
  end

  test "the same body under both names is one body" do
    same = %{"type" => "paragraph", "content" => [t("one body")], "text" => "one body"}
    carried!([same])
  end

  # ── rules 7 and 8 ───────────────────────────────────────────────────────────

  test "rule 7: an empty text node with decorator marks only is dropped; one with an annotation is not" do
    decorated = %{
      "type" => "paragraph",
      "content" => [t("a"), %{"type" => "text", "value" => "", "marks" => ["strong"]}, t("b")]
    }

    assert [%{"content" => [%{"value" => "ab"}]}] = carried!([decorated])

    annotated = %{
      "type" => "paragraph",
      "content" => [t("a"), %{"type" => "text", "value" => "", "marks" => ["k1"]}]
    }

    assert Canonical.normalize([annotated]) |> hd() |> Map.get("content") |> length() == 2
  end

  test "rule 8: a step with no body has an empty one; no other absent list is filled" do
    steps = %{"type" => "steps", "steps" => [%{"title" => "No body"}]}
    assert [%{"steps" => [%{"blocks" => []}]}] = Canonical.normalize([steps])
    carried!([steps])

    list = %{"type" => "list"}
    assert Canonical.normalize([list]) == [list]
  end

  # ── rules 9 to 13 ───────────────────────────────────────────────────────────

  test "rule 9: an empty marks list is dropped" do
    para = %{
      "type" => "paragraph",
      "content" => [t("a"), %{"type" => "text", "value" => "b", "marks" => []}]
    }

    lossless!(para)
    assert [%{"content" => [%{"type" => "text", "value" => "ab"}]}] = carried!([para])
  end

  test "rule 10: a bare string beside inline nodes, and a single inline node, are inline lists" do
    mixed = %{"type" => "paragraph", "content" => ["hi < there ", t("friend")]}
    lossless!(mixed)
    assert [%{"content" => [%{"value" => "hi < there friend"}]}] = carried!([mixed])

    single = %{"type" => "paragraph", "content" => t("solo")}
    lossless!(single)
    assert [%{"content" => [%{"value" => "solo"}]}] = carried!([single])

    # A list of strings alone is not inline content (a byline's items).
    byline = %{"type" => "byline", "items" => ["a", "b"]}
    assert Canonical.normalize([byline], [:inline_shape]) == [byline]
  end

  test "rule 11: a byline value-map item is its string" do
    byline = %{"type" => "byline", "items" => [%{"value" => "Epic · wave 6"}, "plain"]}
    lossless!(byline)
    assert [%{"items" => ["Epic · wave 6", "plain"]}] = carried!([byline])

    other = %{"type" => "byline", "items" => [%{"value" => "v", "note" => "kept"}]}
    assert Canonical.normalize([other]) == [other]
  end

  test "rule 12: a bare-string note is a note with that text" do
    notes = %{"type" => "notes", "items" => ["A remedy < & >"]}
    lossless!(notes)
    assert [%{"items" => [%{"text" => "A remedy < & >"}]}] = carried!([notes])
  end

  test "rule 13: a step's nil or false children is dropped" do
    body = [%{"type" => "paragraph", "content" => [t("Visible legacy body")]}]

    for absent <- [nil, false] do
      steps = %{"type" => "steps", "steps" => [%{"children" => absent, "blocks" => body}]}
      lossless!(steps)
      assert [%{"steps" => [%{"blocks" => ^body} = step]}] = carried!([steps])
      refute is_map_key(step, "children")
    end
  end

  # Rule 1 rewrites only a mark node that is exactly its type and children; any
  # other key on the node is something the print drops, so normalize leaves it
  # and the wall refuses it.
  @strong_children [%{"type" => "text", "value" => "seen"}]
  @mark_node_extras [
    {"a strong node also holding a value", %{"value" => "HIDDEN"}},
    {"a strong node carrying its own em mark", %{"marks" => ["em"]}},
    {"a strong node carrying a link", %{"href" => "/x"}}
  ]

  for {name, extra} <- @mark_node_extras do
    test "rule 1 loses nothing: #{name} is not rewritten" do
      node =
        Map.merge(
          %{"type" => "strong", "children" => @strong_children},
          unquote(Macro.escape(extra))
        )

      block = %{"type" => "paragraph", "content" => [node]}
      lossless!(block)
      assert Canonical.normalize([block]) == [block]
    end
  end

  test "rule 1 loses nothing: an em node carrying an annotation mark is not rewritten" do
    node = %{"type" => "em", "children" => @strong_children, "marks" => ["k1"]}
    block = %{"type" => "paragraph", "content" => [node]}
    lossless!(block)
    assert Canonical.normalize([block]) == [block]
  end

  # ── the reader sees the same thing before and after ─────────────────────────

  test "rule 1: a code node and a code mark render the same" do
    node = %{
      "type" => "paragraph",
      "content" => [t("run "), %{"type" => "code", "value" => "mix test"}]
    }

    assert Render.render_blocks([node]) == Render.render_blocks(Canonical.normalize([node]))
  end

  test "rule 2: an expandable's children and blocks render the same" do
    golden = BpmlStoredDocuments.golden("expandable")
    children = rename(golden, "blocks", "children")

    assert Render.render_blocks([children]) ==
             Render.render_blocks(Canonical.normalize([children]))
  end

  # ── the property, over every stored document ────────────────────────────────

  test "no character, no mark on a character, no link, no checked state, no block, no item child, no slot" do
    for {file, blocks} <- BpmlStoredDocuments.all(), {block, i} <- Enum.with_index(blocks) do
      lossless!(block, "#{file} blocks[#{i}]")
    end
  end

  defp lossless!(block, where \\ "the case") do
    after_ = Canonical.normalize([block])

    assert letters([block]) == letters(after_), "#{where}: a character changed"
    assert sub_multiset?(marks([block]), marks(after_)), "#{where}: a mark was lost"

    assert tally(collect([block], "href")) == tally(collect(after_, "href")),
           "#{where}: a link moved"

    assert count_checked([block]) == count_checked(after_), "#{where}: a checked state was lost"

    assert tally(block_types([block])) == tally(block_types(after_)),
           "#{where}: a block was lost"

    assert item_children([block]) == item_children(after_), "#{where}: an item child was lost"
    assert tally(slot_names([block])) == tally(slot_names(after_)), "#{where}: a slot was lost"
  end

  # Item children, counted wherever a list item holds them.
  defp item_children(%{"items" => items} = m) when is_list(items) do
    own = for %{"children" => c} <- items, is_list(c), reduce: 0, do: (n -> n + length(c))
    own + (m |> Map.values() |> Enum.map(&item_children/1) |> Enum.sum())
  end

  defp item_children(m) when is_map(m),
    do: m |> Map.values() |> Enum.map(&item_children/1) |> Enum.sum()

  defp item_children(l) when is_list(l), do: l |> Enum.map(&item_children/1) |> Enum.sum()
  defp item_children(_), do: 0

  defp slot_names(%{"slots" => %{} = slots} = m),
    do: Map.keys(slots) ++ (m |> Map.values() |> Enum.flat_map(&slot_names/1))

  defp slot_names(m) when is_map(m), do: m |> Map.values() |> Enum.flat_map(&slot_names/1)
  defp slot_names(l) when is_list(l), do: Enum.flat_map(l, &slot_names/1)
  defp slot_names(_), do: []

  # Every non-space character of every string, except keys that hold names
  # (`type`, `marks`) or numbers written as strings (`level`).
  defp letters(term),
    do:
      term
      |> strings()
      |> Enum.flat_map(&String.graphemes/1)
      |> Enum.reject(&(&1 =~ ~r/\s/))
      |> tally()

  defp strings(m) when is_map(m),
    do:
      m
      |> Enum.reject(fn {k, _} -> k in ["type", "marks", "level"] end)
      |> Enum.flat_map(fn {_, v} -> strings(v) end)

  defp strings(l) when is_list(l), do: Enum.flat_map(l, &strings/1)
  defp strings(s) when is_binary(s), do: [s]
  defp strings(_), do: []

  @mark_nodes ~w(strong em code underline strike)

  # The marks on visible text, one entry per mark per text run: a text node's
  # own marks, plus every mark of the mark nodes it sits in (a mark node's type
  # and its own `marks`), so a mark lost off a node shows as a missing entry.
  defp marks(term), do: marks(term, [])

  defp marks(%{"type" => "text", "value" => v} = n, held) when is_binary(v) and v != "",
    do: held ++ own_marks(n)

  defp marks(%{"type" => t, "value" => v} = n, held)
       when t in @mark_nodes and is_binary(v) and v != "",
       do: held ++ [t | own_marks(n)] ++ marks(Map.drop(n, ["type", "value", "marks"]), held)

  defp marks(%{"type" => t, "children" => cs} = n, held) when t in @mark_nodes,
    do:
      marks(cs, held ++ [t | own_marks(n)]) ++
        marks(Map.drop(n, ["type", "children", "marks"]), held)

  defp marks(m, held) when is_map(m), do: m |> Map.values() |> Enum.flat_map(&marks(&1, held))
  defp marks(l, held) when is_list(l), do: Enum.flat_map(l, &marks(&1, held))
  defp marks(_, _held), do: []

  defp own_marks(n), do: n |> Map.get("marks") |> List.wrap() |> Enum.filter(&is_binary/1)

  defp sub_multiset?(a, b) do
    tb = tally(b)
    Enum.all?(tally(a), fn {k, n} -> Map.get(tb, k, 0) >= n end)
  end

  defp collect(m, key) when is_map(m),
    do: List.wrap(Map.get(m, key)) ++ (m |> Map.values() |> Enum.flat_map(&collect(&1, key)))

  defp collect(l, key) when is_list(l), do: Enum.flat_map(l, &collect(&1, key))
  defp collect(_, _), do: []

  defp count_checked(term), do: term |> collect("checked") |> Enum.count(&(&1 == true))

  # Block types at block positions only: the top level, the keys that hold
  # blocks, slots, a step's body (any of its three keys) and list item children.
  # Inline content is never walked, so inline nodes are never counted.
  @block_keys ~w(blocks children child columns)

  defp block_types(l) when is_list(l), do: Enum.flat_map(l, &block_types/1)
  defp block_types(%{"type" => t} = b) when is_binary(t), do: [t | nested_blocks(b)]
  defp block_types(%{} = m), do: nested_blocks(m)
  defp block_types(_), do: []

  defp nested_blocks(m) do
    from_keys =
      for k <- @block_keys, v = Map.get(m, k), is_list(v) or is_map(v), do: block_types(v)

    slots = for {_n, v} <- Map.get(m, "slots") || %{}, do: block_types(v)

    steps =
      for s <- List.wrap(Map.get(m, "steps")),
          is_map(s),
          k <- ["blocks", "children", "content"],
          is_list(s[k]),
          do: block_types(s[k])

    items =
      for it <- List.wrap(Map.get(m, "items")),
          is_map(it),
          do: block_types(Map.get(it, "children") || [])

    List.flatten([from_keys, slots, steps, items])
  end

  defp tally(list), do: Enum.frequencies(list)
end
