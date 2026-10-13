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
      assert c.any == [[%{"isbn" => "1"}, %{"isbn" => "2"}]]
    end

    test "an || of field equalities becomes one any-of constraint" do
      c = constraints(~s'*[_type == "p" && (isbn == $i || onix.isbn == $i)]', %{"i" => "9"})
      assert c.any == [[%{"isbn" => "9"}, %{"onix" => %{"isbn" => "9"}}]]
    end

    # Constraints for the first `*[...]` filter, with `^` bound to `parent`.
    defp constraints_under(query, parent, params \\ %{}) do
      {:ok, tree} = Parser.parse(query, params)
      expr = filter_expr(tree)
      ctx = %Evaluator{source: MemorySource.new([])}
      scope = %{value: nil, parent: %{value: parent, parent: nil, hidden: false}, hidden: false}
      Pushdown.constraints(expr, &Evaluator.eval(&1, scope, ctx))
    end

    defp filter_expr({:filter, {:everything}, expr}), do: expr

    defp filter_expr(node) when is_tuple(node),
      do: node |> Tuple.to_list() |> Enum.find_value(&filter_expr/1)

    defp filter_expr(list) when is_list(list), do: Enum.find_value(list, &filter_expr/1)
    defp filter_expr(_), do: nil

    test "references() with a parameter or ^ becomes a refs probe" do
      c = constraints(~s|*[_type == "p" && references($s)]|, %{"s" => "series-1"})
      assert c.any == [[{:refs, ["series-1"]}]]

      c = constraints_under(~s|*[_type == "p" && references(^._id, "x")]|, %{"_id" => "p4"})
      assert c.any == [[{:refs, ["p4", "x"]}]]
    end

    test "references() with no string matches nothing" do
      c = constraints_under(~s|*[_type == "p" && references(^.missing)]|, %{"_id" => "p4"})
      assert c.any == [[]]
    end

    test "membership in an array path becomes containment with the array in the probe" do
      c =
        constraints_under(~s|*[$paths[0] in slugHistory[].value]|, %{}, %{"paths" => ["/a", "/b"]})

      assert c.eq == [] and c.any == [[%{"slugHistory" => [%{"value" => "/a"}]}]]

      c =
        constraints_under(
          ~s'*[$p[0] in slugHistory[].value || $p[1] in slugHistory[].value]',
          %{},
          %{"p" => ["/a", "/b"]}
        )

      assert c.any == [
               [
                 %{"slugHistory" => [%{"value" => "/a"}]},
                 %{"slugHistory" => [%{"value" => "/b"}]}
               ]
             ]
    end

    test "membership of null stays in memory, since null matches a missing value" do
      c = constraints_under(~s|*[$x in slugHistory[].value]|, %{}, %{"x" => nil})
      assert c.any == []
    end

    test "each disjunct gives its most selective condition and a false one drops" do
      filter = """
      *[_type == "product" && _id != ^._id && (defined(isbn) || defined(onix.isbn)) && (
        (references(^._id) && (mainProduct._ref == ^._id || ^._id in variants[]._ref)) ||
        _id == ^.mainProduct._ref ||
        (defined(^.mainProduct._ref) && references(^.mainProduct._ref) && mainProduct._ref == ^.mainProduct._ref) ||
        _id in ^.variants[]._ref ||
        (defined(^.onix.publicationId) && onix.publicationId == ^.onix.publicationId)
      )]
      """

      root = %{"_id" => "p4", "onix" => %{"publicationId" => "pub-1"}}
      assert constraints_under(filter, root).types == ["product"]

      assert constraints_under(filter, root).any == [
               [{:refs, ["p4"]}, %{"onix" => %{"publicationId" => "pub-1"}}]
             ]

      child = %{
        "_id" => "p5",
        "mainProduct" => %{"_ref" => "p4"},
        "variants" => [%{"_ref" => "p9"}]
      }

      assert constraints_under(filter, child).any == [
               [{:refs, ["p5"]}, {:ids, ["p4"]}, {:refs, ["p4"]}, {:ids, ["p9"]}]
             ]
    end

    test "an || with a disjunct SQL cannot narrow stays in memory" do
      c = constraints(~s'*[_type == "p" && (references($a) || count(tags) > 2)]', %{"a" => "x"})
      assert c.any == []
    end

    test "count() against an integer and defined() become checks" do
      c =
        constraints(
          ~s|*[_type == "p" && count(onix.contributors) > 0 && 1 <= count(tags) && count(a.b) == $n]|,
          %{"n" => 0}
        )

      assert Enum.sort(c.checks) == [
               {:length, ["a", "b"], "==", 0},
               {:length, ["onix", "contributors"], ">", 0},
               {:length, ["tags"], ">=", 1}
             ]

      c = constraints(~s|*[defined(bokbasen.themaCodes[0]) && defined(isbn) && defined(x[-1])]|)

      assert Enum.sort(c.checks) == [
               {:defined, ["bokbasen", "themaCodes"], 0},
               {:defined, ["isbn"], nil},
               {:defined, ["x"], -1}
             ]
    end

    test "a filter of checks and equalities is exact" do
      {:ok, tree} = Parser.parse(~s|*[_type == "p" && count(tags) >= 1 && defined(tags[0])]|)

      assert {:ok, %{types: ["p"], checks: [_, _]}} = Pushdown.exact(filter_expr(tree))
    end

    test "count() != n, a non-integer bound and a system path stay in memory" do
      for filter <- [
            ~s|count(tags) != 0|,
            ~s|count(tags) > 0.5|,
            ~s|count(tags) > count(other)|,
            ~s|count(_keys) > 0|,
            ~s|count(title) > 0|,
            ~s|count(tags[_type == "x"]) > 0|
          ] do
        {:ok, tree} = Parser.parse("*[_type == \"p\" && #{filter}]")
        assert Pushdown.constraints(filter_expr(tree)).checks == [], filter
        assert Pushdown.exact(filter_expr(tree)) == :error, filter
      end
    end

    test "or, functions and ^ stay in memory" do
      c = constraints(~s'*[_type == "a" || _type == "b"]')
      assert c.types == nil
      c = constraints(~s|*[_type == "a"]{"x": *[_type == "b" && ref == ^._id]}|)
      assert c.types == ["a"]
    end
  end
end
