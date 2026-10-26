defmodule Barkpark.Groq.DiffTest do
  @moduledoc """
  task-13790b478beeee4d: `diff::changedAny(lhs, rhs, selector)` and
  `diff::changedOnly(lhs, rhs, selector)`. Every expected value is Sanity's,
  read from its API (ecu57yeh/e2e-local, 26 Oct). Barkpark adds a cap on a
  selector's size.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Groq.{Evaluator, MemorySource, Parser}

  defp eval!(query) do
    {:ok, tree} = Parser.parse(query, %{"p" => true})
    {:ok, value} = Evaluator.evaluate(tree, source: MemorySource.new([]))
    value
  end

  defp error(query) do
    assert {:error, %{description: description}} = Parser.parse(query)
    description
  end

  test "changedAny follows the selected keys" do
    for {q, want} <- [
          {~s|diff::changedAny({"a":1}, {"a":2}, (a))|, true},
          {~s|diff::changedAny({"a":1}, {"a":1}, (a))|, false},
          {~s|diff::changedAny({"a":1}, {"a":2}, a)|, true},
          {~s|diff::changedAny({"a":1,"b":1}, {"a":1,"b":2}, (a))|, false},
          {~s|diff::changedAny({"a":1,"b":1}, {"a":1,"b":2}, (a, b))|, true},
          {~s|diff::changedAny({"a":{"b":{"c":1}}}, {"a":{"b":{"c":2}}}, (a.b.c))|, true},
          {~s|diff::changedAny({"a":{"b":1}}, {"a":{"b":2}}, a.(b))|, true},
          {~s|diff::changedAny({"x":{"b":1},"y":{"b":1}}, {"x":{"b":1},"y":{"b":2}}, (x, y).b)|,
           true},
          {~s|diff::changedAny({"a":1}, {}, (a))|, true},
          {~s|diff::changedAny({"a":null}, {}, (a))|, false},
          {~s|diff::changedAny({"a":1}, {"a":1.0}, (a))|, false},
          {~s|diff::changedAny({"a":[1,2]}, {"a":[2,1]}, (a))|, true},
          {~s|diff::changedAny({"a":{"x":1,"y":2}}, {"a":{"y":2,"x":1}}, (a))|, false},
          {~s|diff::changedAny(null, {"a":1}, (a))|, false},
          {~s|diff::changedAny(1, 2, (a))|, false},
          {~s|diff::changedAny({"a":1}, {"a":{"b":1}}, (a.b))|, false}
        ] do
      assert eval!(q) == want, q
    end
  end

  test "an array step compares by position, and a change of length is a change" do
    for {q, want} <- [
          {~s|diff::changedAny({"a":[1,2]}, {"a":[1,3]}, (a[]))|, true},
          {~s|diff::changedAny({"a":[1,2]}, {"a":[1,2]}, (a[]))|, false},
          {~s|diff::changedAny({"a":[1]}, {"a":[1,2]}, (a[]))|, true},
          {~s|diff::changedAny({"a":[{"x":1},{"x":1}]}, {"a":[{"x":1}]}, (a[].x))|, true},
          {~s|diff::changedAny({"a":[{"x":1}]}, {"a":{"x":1}}, (a[].x))|, true},
          {~s|diff::changedAny({"a":{"n":1}}, {"a":{"n":2}}, (a[]))|, false},
          {~s|diff::changedAny({"a":1}, {"a":2}, (a[]))|, false},
          {~s|diff::changedAny({"a":[{"n":"A"},{"n":"B"}]}, {"a":[{"n":"A"},{"n":"B"},{"n":"C"}]}, a[n == "A"].n)|,
           true},
          {~s|diff::changedAny({"a":[{"n":"A","x":1},{"n":"B","x":1}]}, {"a":[{"n":"A2","x":1},{"n":"B","x":1}]}, a[n == "B"].n)|,
           false},
          {~s|diff::changedAny({"a":[{"n":"A","x":1},{"n":"B","x":1}]}, {"a":[{"n":"B","x":1},{"n":"A","x":1}]}, (a[n == "A"].x))|,
           false}
        ] do
      assert eval!(q) == want, q
    end
  end

  test "anywhere() selects every node whose condition is true" do
    l = ~s|{"a":[{"t":"foo","v":1},{"t":"bar","v":1}]}|

    for {q, want} <- [
          {~s|diff::changedAny(#{l}, {"a":[{"t":"foo","v":2},{"t":"bar","v":1}]}, anywhere(t == "foo"))|,
           true},
          {~s|diff::changedAny(#{l}, {"a":[{"t":"foo","v":1},{"t":"bar","v":2}]}, anywhere(t == "foo"))|,
           false},
          {~s|diff::changedAny(#{l}, {"a":[{"t":"foo","v":2},{"t":"bar","v":1}]}, anywhere(t == "foo").v)|,
           true},
          {~s|diff::changedAny({"a":{"t":"foo"}}, {"b":{"t":"foo"}}, anywhere(t == "foo"))|,
           true},
          {~s|diff::changedAny({"t":"foo","v":1}, {"t":"foo","v":2}, anywhere(t == "foo"))|,
           true},
          {~s|diff::changedAny({"a":1}, {"a":2}, anywhere(true))|, true},
          {~s|diff::changedAny({"a":1}, {"a":2}, anywhere(1))|, false},
          {~s|diff::changedAny({"a":1}, {"a":2}, a[$p])|, false}
        ] do
      assert eval!(q) == want, q
    end
  end

  test "changedOnly is true when nothing outside the selection changed" do
    for {q, want} <- [
          {~s|diff::changedOnly({"a":1,"b":1}, {"a":2,"b":1}, (a))|, true},
          {~s|diff::changedOnly({"a":1,"b":1}, {"a":2,"b":2}, (a))|, false},
          {~s|diff::changedOnly({"a":1,"b":1}, {"a":1,"b":1}, (a))|, true},
          {~s|diff::changedOnly({"a":1}, {"a":1}, (b))|, true},
          {~s|diff::changedOnly(null, {"a":1}, (a))|, false},
          {~s|diff::changedOnly({"a":[1,2],"b":1}, {"a":[1,2,3],"b":1}, (a[]))|, false},
          {~s|diff::changedOnly({"a":[{"x":1,"y":1}],"b":1}, {"a":[{"x":2,"y":1}],"b":1}, (a[].x))|,
           true},
          {~s|diff::changedOnly({"a":[{"x":1,"y":1}],"b":1}, {"a":[{"x":2,"y":2}],"b":1}, (a[].x))|,
           false},
          {~s|diff::changedOnly({"a":[{"n":"A","x":1},{"n":"B","x":1}]}, {"a":[{"n":"A","x":2},{"n":"B","x":1}]}, (a[n == "A"].x))|,
           true},
          {~s|diff::changedOnly({"a":[{"n":"A","x":1},{"n":"B","x":1}]}, {"a":[{"n":"A","x":1},{"n":"B","x":2}]}, (a[n == "A"].x))|,
           false},
          {~s|diff::changedOnly({"a":[{"t":"foo","v":1},{"t":"bar","v":1}]}, {"a":[{"t":"foo","v":2},{"t":"bar","v":1}]}, anywhere(t == "foo"))|,
           true}
        ] do
      assert eval!(q) == want, q
    end
  end

  test "a selector Sanity refuses is refused with its words" do
    for sel <- [
          ~s|foo + 1|,
          ~s|foo{bar}|,
          ~s|(foo + 1)|,
          ~s|foo[0]|,
          ~s|"foo"|,
          ~s|123|,
          ~s|@|,
          ~s|$p|
        ] do
      assert error(~s|diff::changedAny({}, {}, #{sel})|) == "invalid selector", sel
    end

    assert error(~s|diff::changedAny({"a":1}, {"a":2})|) == "three arguments expected"
    assert error(~s|diff::changedAny({"a":1}, {"a":2}, (a), (b))|) == "three arguments expected"
  end

  test "a selector past the size cap is refused fast" do
    sel = "(" <> Enum.map_join(1..5_000, ", ", &"k#{&1}") <> ")"
    {micros, result} = :timer.tc(fn -> Parser.parse(~s|diff::changedAny({}, {}, #{sel})|) end)
    assert {:error, %{description: description}} = result
    assert description =~ "selector is too large"
    assert micros < 100_000, "took #{div(micros, 1000)} ms"
  end
end
