defmodule Barkpark.Content.PortableTextEditedFieldsTest do
  @moduledoc """
  task-9e958e1739c7ce9b: an edited block is read against the stored block it
  replaces (`adopt/2`). It kept the stored `_key` and span keys and dropped
  everything else the editor does not draw: a field beside the text, and a
  custom `listItem` the editor draws as a bullet. TanStack's `mergeText`
  (pt-value.ts) takes only the MANAGED fields from the editor and keeps the
  rest, and keeps a stored value the editor reads the same.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.PortableText

  defp span(k, t), do: %{"_type" => "span", "_key" => k, "text" => t, "marks" => []}

  defp block(k, text, extra) do
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

  defp item(k, text, kind, extra \\ %{}),
    do: block(k, text, Map.merge(%{"listItem" => kind, "level" => 1}, extra))

  # What the editor posts after `edit`, read against `stored`.
  defp save(stored, edit), do: PortableText.from_html(PortableText.to_html(edit), stored)

  defp at(blocks, key), do: Enum.find(blocks, &(&1["_key"] == key))

  defp retext(b, text), do: %{b | "children" => [span(b["_key"] <> "s", text)]}

  setup do
    p = block("kp", "para", %{"extra" => %{"y" => 2}})
    a = item("ka", "one", "bullet")
    b = item("kb", "two", "bullet", %{"extra" => %{"x" => 1}})
    c = item("kc", "three", "check")
    {:ok, p: p, a: a, b: b, c: c, stored: [p, a, b, c]}
  end

  test "a word edit of a paragraph keeps its field", %{p: p, a: a, b: b, c: c, stored: stored} do
    out = save(stored, [retext(p, "para more"), a, b, c])

    assert at(out, "kp")["extra"] == %{"y" => 2}
    assert words(at(out, "kp")) == "para more"
  end

  test "a word edit of a list item keeps its field", %{p: p, a: a, b: b, c: c, stored: stored} do
    out = save(stored, [p, a, retext(b, "two more"), c])

    assert at(out, "kb")["extra"] == %{"x" => 1}
    assert words(at(out, "kb")) == "two more"
  end

  test "an indented item keeps its field", %{p: p, a: a, b: b, c: c, stored: stored} do
    out = save(stored, [p, a, Map.put(b, "level", 2), c])

    assert %{"_key" => "kb", "level" => 2, "listItem" => "bullet", "extra" => %{"x" => 1}} =
             at(out, "kb")
  end

  test "an indented custom item keeps its listItem", %{p: p, a: a, b: b, c: c, stored: stored} do
    out = save(stored, [p, a, b, Map.put(c, "level", 2)])

    assert %{"_key" => "kc", "level" => 2, "listItem" => "check"} = at(out, "kc")
  end

  test "a word edit of a custom item keeps its listItem", %{
    p: p,
    a: a,
    b: b,
    c: c,
    stored: stored
  } do
    out = save(stored, [p, a, b, retext(c, "three more")])

    assert %{"_key" => "kc", "listItem" => "check", "level" => 1} = at(out, "kc")
  end

  test "a custom item made numbered takes the number", %{p: p, a: a, b: b, c: c, stored: stored} do
    out = save(stored, [p, a, b, Map.put(c, "listItem", "number")])

    assert %{"_key" => "kc", "listItem" => "number"} = at(out, "kc")
  end

  test "an item with no stored level, edited, stays without one", %{p: p, a: a, stored: _} do
    d = item("kd", "four", "bullet") |> Map.delete("level")
    out = save([p, a, d], [p, a, retext(d, "four more")])

    refute Map.has_key?(at(out, "kd"), "level")
    assert at(out, "kd")["listItem"] == "bullet"
  end

  test "an item made a paragraph loses the list, keeps its field", %{
    p: p,
    a: a,
    b: b,
    c: c,
    stored: stored
  } do
    para = b |> Map.drop(["listItem", "level"])
    out = save(stored, [p, a, para, c])

    kb = at(out, "kb")
    refute Map.has_key?(kb, "listItem")
    refute Map.has_key?(kb, "level")
    assert kb["extra"] == %{"x" => 1}
  end

  test "an untouched block stays byte-identical", %{p: p, a: a, b: b, c: c, stored: stored} do
    out = save(stored, [p, a, retext(b, "two more"), c])

    for k <- ~w(kp ka kc), do: assert(at(out, k) == at(stored, k))
  end

  defp words(b), do: Enum.map_join(b["children"], & &1["text"])
end
