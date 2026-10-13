defmodule Barkpark.Groq.ParserTest do
  @moduledoc "Parser behaviour the conformance suite does not pin, plus SQL pushdown."
  use ExUnit.Case, async: true

  alias Barkpark.Groq.{Evaluator, MemorySource, Parser, Pushdown}

  defp eval!(query, docs \\ [], params \\ %{}) do
    {:ok, tree} = Parser.parse(query, params)
    {:ok, value} = Evaluator.evaluate(tree, source: MemorySource.new(docs))
    value
  end

  test "a parameter the request lacks is a parse error naming it, even inside a filter" do
    assert {:error, %{description: description}} = Parser.parse("*[_id == $id]")
    assert description =~ "$id"
  end

  test "slices take parameters" do
    docs = for i <- 1..5, do: %{"_id" => "d#{i}", "_type" => "t"}

    assert eval!("*[_type == 't'][$start...$end]._id", docs, %{"start" => 1, "end" => 3}) == [
             "d2",
             "d3"
           ]
  end

  test "comments and Unicode escapes" do
    assert eval!("// a comment\n\"\\u00e6\\u{1F600}\"") == "æ😀"
  end

  test "a closed subquery inside a filter is wrapped for memoization" do
    {:ok, tree} = Parser.parse(~s|*[_type == "a" && _id in *[_type == "b"].ref]|)
    assert inspect(tree) =~ "{:memo,"
  end

  test "a subquery that reads ^ is not memoized" do
    {:ok, tree} = Parser.parse(~s|*[_type == "a"]{"n": count(*[_type == "b" && ref == ^._id])}|)
    assert inspect(tree) =~ ~s|{:func, "global", "count", [{:filter, {:everything}|
  end

  describe "pushdown" do
    defp constraints(query, params \\ %{}) do
      {:ok, tree} = Parser.parse(query, params)
      find_filter(tree)
    end

    defp find_filter({:filter, {:everything}, expr}), do: Pushdown.constraints(expr)

    defp find_filter(node) when is_tuple(node) do
      node |> Tuple.to_list() |> Enum.find_value(&find_filter/1)
    end

    defp find_filter(list) when is_list(list), do: Enum.find_value(list, &find_filter/1)
    defp find_filter(_), do: nil

    test "type, id and content equality become constraints" do
      c =
        constraints(
          ~s|*[_type == "book" && _id == $id && slug.current == $slug && year > 2000][0]|,
          %{"id" => "b1", "slug" => "s"}
        )

      assert c.types == ["book"]
      assert c.ids == ["b1"]
      assert c.eq == [{["slug", "current"], "s"}]
    end

    test "in with constant lists" do
      c = constraints(~s|*[_type in ["a", "b"] && isbn in $isbns]|, %{"isbns" => ["1", "2"]})
      assert c.types == ["a", "b"]
      assert c.any == [{["isbn"], ["1", "2"]}]
    end

    test "or, functions and ^ stay in memory" do
      c = constraints(~s'*[_type == "a" || _type == "b"]')
      assert c.types == nil
      c = constraints(~s|*[_type == "a"]{"x": *[_type == "b" && ref == ^._id]}|)
      assert c.types == ["a"]
    end
  end
end
