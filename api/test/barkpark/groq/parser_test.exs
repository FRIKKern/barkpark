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
      assert c.checks == [{:in, ["isbn"], ["1", "2"]}]
      assert c.any == []
    end

    test "path in a list and value in an array path become exact checks" do
      {:ok, tree} =
        Parser.parse(
          ~s|*[_type == "p" && a.b in [1, "x", true, 1] && $s in seriesIds && n in []]|,
          %{"s" => "series-3"}
        )

      assert {:ok, c} = Pushdown.exact(filter_expr(tree))

      assert Enum.sort(c.checks) == [
               {:in, ["a", "b"], [1, "x", true]},
               {:in, ["n"], []},
               {:member, ["seriesIds"], "series-3"}
             ]
    end

    test "in with null, an object member or a system path is not a check" do
      for {filter, params} <- [
            {~s|isbn in [null, "1"]|, %{}},
            {~s|isbn in [{"a": 1}]|, %{}},
            {~s|$x in seriesIds|, %{"x" => nil}},
            {~s|$x in seriesIds|, %{"x" => ["a"]}},
            {~s|title in ["a"]|, %{}},
            {~s|_key in ["a"]|, %{}},
            {~s|isbn in "abc"|, %{}}
          ] do
        {:ok, tree} = Parser.parse("*[_type == \"p\" && #{filter}]", params)
        assert Pushdown.constraints(filter_expr(tree)).checks == [], filter
      end
    end

    test "a closed subquery on the right side is resolved into the list" do
      docs = [
        %{"_id" => "a", "_type" => "product", "isbn" => "1"},
        %{"_id" => "b", "_type" => "product", "isbn" => "2"},
        %{"_id" => "c", "_type" => "other", "isbn" => "3"}
      ]

      {:ok, tree} =
        Parser.parse(~s|*[_type == "search" && relewiseId in *[_type == "product"].isbn]|)

      expr = filter_expr(tree)
      ctx = %Evaluator{source: MemorySource.new(docs)}
      scope = %{value: nil, parent: nil, hidden: false}
      c = Pushdown.constraints(expr, &Evaluator.eval(&1, scope, ctx))
      assert c.checks == [{:in, ["relewiseId"], ["1", "2"]}]

      # Without a resolver the subquery is not evaluated.
      assert Pushdown.constraints(expr).checks == []
    end

    test "an || of field equalities is an exact or check" do
      c = constraints(~s'*[_type == "p" && (isbn == $i || onix.isbn == $i)]', %{"i" => "9"})

      want = {:or, [branch(eq: [{["isbn"], "9"}]), branch(eq: [{["onix", "isbn"], "9"}])]}
      assert c.checks == [want] and c.any == []

      assert {:ok, %{checks: [^want]}} =
               exact(~s'*[_type == "p" && (isbn == $i || onix.isbn == $i)]', %{"i" => "9"})
    end

    # One branch of an `{:or, branches}` check.
    defp branch(fields), do: Map.merge(Pushdown.empty(), Map.new(fields))

    defp exact(query, params \\ %{}) do
      {:ok, tree} = Parser.parse(query, params)
      Pushdown.exact(filter_expr(tree))
    end

    test "an || of value in array clauses is one exact or of member checks" do
      q = ~s'*[_type == "p" && ("218" in codes || $c in codes) && isMain == true]'
      c = constraints(q, %{"c" => "212"})

      want =
        {:or,
         [
           branch(checks: [{:member, ["codes"], "218"}]),
           branch(checks: [{:member, ["codes"], "212"}])
         ]}

      assert c.checks == [want]
      assert c.types == ["p"] and c.eq == [{["isMain"], true}]
      assert {:ok, %{checks: [^want], types: ["p"]}} = exact(q, %{"c" => "212"})
    end

    test "every exact shape may be a branch, and the or is exact" do
      q = """
      *[_type == "p" && (
        _type == "q" || _id == "x" || isbn in ["1", "2"] || count(tags) > 2 ||
        defined(onix.isbn) || count(cs[role._ref == "A01"]) > 0 ||
        (a == 1 && (b == 2 || "y" in tags))
      )]
      """

      assert [{:or, branches}] = constraints(q).checks

      assert branches == [
               branch(types: ["q"]),
               branch(ids: ["x"]),
               branch(checks: [{:in, ["isbn"], ["1", "2"]}]),
               branch(checks: [{:length, ["tags"], ">", 2}]),
               branch(checks: [{:defined, ["onix", "isbn"], nil}]),
               branch(checks: [{:some, ["cs"], [{["role", "_ref"], ["A01"]}]}]),
               branch(
                 eq: [{["a"], 1}],
                 checks: [
                   {:or, [branch(eq: [{["b"], 2}]), branch(checks: [{:member, ["tags"], "y"}])]}
                 ]
               )
             ]

      assert {:ok, %{checks: [{:or, ^branches}]}} = exact(q)
    end

    test "an or with a branch SQL only narrows is not exact" do
      for q <- [
            ~s'*[_type == "p" && ("x" in codes || references("r"))]',
            ~s'*[_type == "p" && ("x" in codes || title == "t")]',
            ~s'*[_type == "p" && ("x" in codes || (a == 1 && lower(b) == "x"))]',
            ~s'*[_type == "p" && ("x" in codes || "y" in tags[].v)]'
          ] do
        assert match?([{:or, [_, _]}], constraints(q).checks), q
        assert exact(q) == :error, q
      end

      assert [{:or, [_, branch]}] =
               constraints(~s'*[("x" in codes || (a == 1 && lower(b) == "x"))]').checks

      assert branch == branch(eq: [{["a"], 1}])
    end

    test "an or with a branch SQL cannot narrow stays in memory" do
      c = constraints(~s'*[_type == "p" && ("x" in codes || lower(b) == "x")]')
      assert c.checks == [] and c.any == []
      assert exact(~s'*[_type == "p" && ("x" in codes || lower(b) == "x")]') == :error
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

    test "each disjunct gives a branch and a false one drops" do
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

      # Checks come last conjunct first: the big || and then the defined() one.
      assert [{:or, [first, last]}, {:or, defined}] = constraints_under(filter, root).checks

      assert defined == [
               branch(checks: [{:defined, ["isbn"], nil}]),
               branch(checks: [{:defined, ["onix", "isbn"], nil}])
             ]

      assert first.any == [[{:refs, ["p4"]}]]

      assert first.checks == [
               {:or,
                [
                  branch(eq: [{["mainProduct", "_ref"], "p4"}]),
                  branch(any: [[%{"variants" => [%{"_ref" => "p4"}]}]])
                ]}
             ]

      assert last == branch(eq: [{["onix", "publicationId"], "pub-1"}])

      child = %{
        "_id" => "p5",
        "mainProduct" => %{"_ref" => "p4"},
        "variants" => [%{"_ref" => "p9"}]
      }

      assert [{:or, branches}, _defined] = constraints_under(filter, child).checks
      assert [[[{:refs, ["p5"]}]], [], [[{:refs, ["p4"]}]], []] == Enum.map(branches, & &1.any)
      assert [nil, ["p4"], nil, ["p9"]] == Enum.map(branches, & &1.ids)
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
            ~s|count(title) > 0|
          ] do
        {:ok, tree} = Parser.parse("*[_type == \"p\" && #{filter}]")
        assert Pushdown.constraints(filter_expr(tree)).checks == [], filter
        assert Pushdown.exact(filter_expr(tree)) == :error, filter
      end
    end

    test "a match in an array filter becomes a some check" do
      q = fn filter, params ->
        {:ok, tree} = Parser.parse("*[_type == \"p\" && #{filter}]", params)
        expr = filter_expr(tree)
        {Pushdown.constraints(expr).checks, Pushdown.exact(expr)}
      end

      some =
        {:some, ["onix", "contributors"],
         [{["role", "_ref"], ["A01"]}, {["contributor", "_ref"], ["c-1", "c-2"]}]}

      params = %{"ids" => ["c-1", "c-2", "c-1"]}

      for filter <- [
            ~s|count(onix.contributors[role._ref == "A01" && contributor._ref in $ids]) > 0|,
            ~s|count(onix.contributors[role._ref == "A01" && contributor._ref in $ids]) >= 1|,
            ~s|0 < count(onix.contributors[("A01" == role._ref) && contributor._ref in $ids])|,
            ~s|1 <= length(onix.contributors[role._ref == "A01" && contributor._ref in $ids])|,
            ~s|defined(onix.contributors[role._ref == "A01" && contributor._ref in $ids][0])|
          ] do
        {checks, exact} = q.(filter, params)
        assert checks == [some], filter
        assert match?({:ok, %{checks: [^some]}}, exact), filter
      end

      assert {[{:some, ["tags"], [{[], [1, "x"]}]}], {:ok, _}} =
               q.(~s|count(tags[@ in [1, "x"]]) > 0|, %{})
    end

    test "an element condition SQL tests only in part narrows but is not exact" do
      {:ok, tree} =
        Parser.parse(
          ~s|*[_type == "p" && count(slugHistory[match == "url" && lower(value) in $p]) > 0]|,
          %{"p" => ["/a"]}
        )

      expr = filter_expr(tree)

      assert Pushdown.constraints(expr).checks == [
               {:some, ["slugHistory"], [{["match"], ["url"]}]}
             ]

      assert Pushdown.exact(expr) == :error
    end

    test "other array filter counts stay in memory" do
      for {filter, params} <- [
            {~s|count(tags[_type == "x"]) > 1|, %{}},
            {~s|count(tags[_type == "x"]) >= 0|, %{}},
            {~s|count(tags[_type == "x"]) != 0|, %{}},
            {~s|count(tags[_type == "x"]) == 0|, %{}},
            {~s|count(tags[x == null]) > 0|, %{}},
            {~s|count(tags[x in [null]]) > 0|, %{}},
            {~s|count(tags[x in []]) > 0|, %{}},
            {~s|count(tags[x == ^._id]) > 0|, %{}},
            {~s|count(tags[x == y]) > 0|, %{}},
            {~s'count(tags[x == "a" || y == "b"]) > 0', %{}},
            {~s|count(_tags[x == "a"]) > 0|, %{}},
            {~s|count(title[x == "a"]) > 0|, %{}},
            {~s|defined(tags[x == "a"][1])|, %{}},
            {~s|defined(tags[x == "a"])|, %{}}
          ] do
        {:ok, tree} = Parser.parse("*[_type == \"p\" && #{filter}]", params)
        assert Pushdown.constraints(filter_expr(tree)).checks == [], filter
        assert Pushdown.exact(filter_expr(tree)) == :error, filter
      end
    end

    test "!=, ranges and negations on a content path become exact checks" do
      for {filter, check} <- [
            {~s|hidden != true|, {:ne, ["hidden"], true}},
            {~s|"x" != a.b|, {:ne, ["a", "b"], "x"}},
            {~s|a != null|, {:defined, ["a"], nil}},
            {~s|n > $t|, {:range, ["n"], ">", 5}},
            {~s|$t >= n|, {:range, ["n"], "<=", 5}},
            {~s|2.5 < n|, {:range, ["n"], ">", 2.5}},
            {~s|d <= "2026-01-01"|, {:range, ["d"], "<=", "2026-01-01"}},
            {~s|b > false|, {:range, ["b"], ">", false}},
            {~s|!defined(a)|, {:not, {:defined, ["a"], nil}}},
            {~s|!(a == 1)|, {:ne, ["a"], 1}},
            {~s|!(a in [1, "x"])|, {:not, {:in, ["a"], [1, "x"]}}},
            {~s|!("x" in tags)|, {:none, ["tags"], [{[], ["x"]}]}},
            {~s|!(count(tags[@ in ["x", "y"]]) > 0)|, {:none, ["tags"], [{[], ["x", "y"]}]}}
          ] do
        {:ok, tree} = Parser.parse("*[_type == \"p\" && #{filter}]", %{"t" => 5})
        expr = filter_expr(tree)
        assert Pushdown.constraints(expr).checks == [check], filter
        assert match?({:ok, %{checks: [^check]}}, Pushdown.exact(expr)), filter
      end
    end

    test "!=, ranges and negations SQL cannot test exactly stay in memory" do
      for filter <- [
            ~s|a != [1]|,
            ~s|a != b|,
            ~s|title != "x"|,
            ~s|_id != "x"|,
            ~s|a > null|,
            ~s|a > [1]|,
            ~s|a > b|,
            ~s|lower(a) > "x"|,
            ~s|a[0] > 1|,
            ~s|_updatedAt > "2026"|,
            ~s|!(a > 1)|,
            ~s|!defined(a[0])|,
            ~s|!(lower(a) == "x")|,
            ~s|!(count(tags[_type == "x"]) == 0)|,
            ~s|!(count(tags[lower(x) == "a"]) > 0)|
          ] do
        {:ok, tree} = Parser.parse("*[_type == \"p\" && #{filter}]")
        assert Pushdown.constraints(filter_expr(tree)).checks == [], filter
        assert Pushdown.exact(filter_expr(tree)) == :error, filter
      end
    end

    test "order() over content paths and _id, _createdAt, _updatedAt gives SQL sort keys" do
      {:ok, {:slice, {:memo, {:pipe, _base, "order", args}}, 0, 12, false}} =
        Parser.parse(
          ~s'*[_type == "p"] | order(a.b desc, _updatedAt, _createdAt asc, _id desc)[0...12]'
        )

      assert Pushdown.order_keys(args) ==
               {:ok,
                [
                  {{:path, ["a", "b"]}, :desc},
                  {:_updatedAt, :asc},
                  {:_createdAt, :asc},
                  {:_id, :desc}
                ]}

      for order <- ["lower(a)", "title", "_rev", "a[0]", "a.b, x->y"] do
        {:ok, {:pipe, _base, "order", args}} = Parser.parse(~s'*[_type == "p"] | order(#{order})')
        assert Pushdown.order_keys(args) == :error, order
      end
    end

    test "an or of types narrows the types, and ^ stays in memory" do
      c = constraints(~s'*[_type == "a" || _type == "b"]')
      assert c.types == ["a", "b"]
      assert c.checks == [{:or, [branch(types: ["a"]), branch(types: ["b"])]}]
      c = constraints(~s|*[_type == "a"]{"x": *[_type == "b" && ref == ^._id]}|)
      assert c.types == ["a"]
    end
  end
end
