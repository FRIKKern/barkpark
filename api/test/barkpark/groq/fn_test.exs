defmodule Barkpark.Groq.FnTest do
  @moduledoc """
  task-13790b478beeee4d: GROQ custom functions (`fn ns::name($p) = body;`),
  with Sanity's rules as its API answered them on ecu57yeh/e2e-local
  (26 Oct): one parameter, a body that is a projection of the parameter
  (`$p{…}`, `$p->{…}`, `$p[]{…}`) using it once and no `^`, calls to other
  functions in any order, the last definition winning, and a cycle refused.
  Barkpark adds a cap on how many calls one query expands to, so a crafted
  query cannot grow the tree without bound.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Groq.{Evaluator, MemorySource, Parser}

  @docs [
    %{"_id" => "ada", "_type" => "author", "name" => "Ada Lovelace", "bio" => "Ada bio"},
    %{"_id" => "alan", "_type" => "author", "name" => "Alan Turing", "bio" => "Alan bio"},
    %{"_id" => "p1", "_type" => "post", "author" => %{"_ref" => "alan"}}
  ]

  defp eval!(query, params \\ %{}) do
    {:ok, tree} = Parser.parse(query, params)
    {:ok, value} = Evaluator.evaluate(tree, source: MemorySource.new(@docs))
    value
  end

  defp error(query, params \\ %{}) do
    assert {:error, %{description: description}} = Parser.parse(query, params)
    description
  end

  @authors ~s|*[_type == "author"] \| order(_id)|

  test "a projection body runs as on Sanity" do
    assert eval!(~s|fn ex::n($d) = $d{name}; #{@authors}{"x": ex::n(@)}|) == [
             %{"x" => %{"name" => "Ada Lovelace"}},
             %{"x" => %{"name" => "Alan Turing"}}
           ]

    assert eval!(~s|fn ex::n($d) = $d{name, "b": bio}; *[_id == "ada"][0]{"x": ex::n(@)}|) ==
             %{"x" => %{"name" => "Ada Lovelace", "b" => "Ada bio"}}

    assert eval!(~s|fn ex::n($d) = $d->{name}; *[_id == "p1"][0]{"x": ex::n(author)}|) ==
             %{"x" => %{"name" => "Alan Turing"}}

    assert eval!(~s|fn ex::n($d) = $d[]{name}; ex::n(#{@authors})|) ==
             [%{"name" => "Ada Lovelace"}, %{"name" => "Alan Turing"}]

    assert eval!(~s|fn ex::n($d) = $d{...}; ex::n({"name": "a"})|) == %{"name" => "a"}
    assert eval!(~s|fn ex::n($d) = $d{name}; ex::n(null)|) == nil
  end

  test "functions call each other in any order; other params and filters work" do
    assert eval!(
             ~s|fn ex::a($d) = $d{"inner": ex::b(@)}; fn ex::b($d) = $d{name}; *[_id == "ada"][0]{"x": ex::a(@)}|
           ) == %{"x" => %{"inner" => %{"name" => "Ada Lovelace"}}}

    assert eval!(~s|fn ex::n($d) = $d{name, "p": $p}; ex::n({"name": "a"})|, %{"p" => "P"}) ==
             %{"name" => "a", "p" => "P"}

    assert eval!(
             ~s|fn ex::n($d) = $d{name}; *[_type == "author" && ex::n(@).name == "Ada Lovelace"]._id|
           ) ==
             ["ada"]
  end

  test "the last definition wins, and a definition may shadow a built-in" do
    assert eval!(
             ~s|fn ex::n($d) = $d{name}; fn ex::n($d) = $d{bio}; *[_id == "ada"][0]{"x": ex::n(@)}|
           ) ==
             %{"x" => %{"bio" => "Ada bio"}}

    assert eval!(~s|fn string::lower($d) = $d{name}; string::lower({"name": "A"})|) == %{
             "name" => "A"
           }
  end

  test "a body that is not a projection of the parameter is refused, as on Sanity" do
    for body <- [~s|$d.name|, ~s|upper($d.name)|, ~s|1|, ~s|$d|, ~s|ex::m($d)|] do
      assert error(~s|fn ex::m($d) = $d{a}; fn ex::n($d) = #{body}; ex::n(1)|) ==
               "function body is not of type ast.Projection",
             body
    end

    for body <- [~s|$d.x{name}|, ~s|($d){name}|, ~s|*[_id == "a"]{name}|] do
      assert error(~s|fn ex::n($d) = #{body}; ex::n(1)|) == "unexpected function body", body
    end

    assert error(~s|fn ex::n($d) = $d{"k": $d.name}; ex::n(1)|) ==
             "the function argument cannot be used more than once in the function body"

    assert error(~s|fn ex::n($d) = $d{"n": ^.name}; ex::n(1)|) =~ "parent usage is invalid"
  end

  test "the definition's shape and the call's arity are checked" do
    assert error(~s|fn ex::n($d, $e) = $d{name}; ex::n(1)|) =~ "following function arguments"
    assert error(~s|fn ex::n() = $d{name}; ex::n(1)|) == "expected parameter name"
    assert error(~s|fn n($d) = $d{name}; n(1)|) == "expected '::' followed by a function name"
    assert error(~s|fn ex::n($d) = $d{name}|) == "expected ';' at the end of function definition"

    assert error(~s|fn ex::n($d) = $d{name}; ex::n(1, 2)|) ==
             "expected a single argument for function call, got 2"

    assert error(~s|fn ex::a($d) = $d{"y": ex::nope(@)}; ex::a(1)|) ==
             ~s(Undefined function "nope" in namespace "ex")
  end

  test "a function that reaches itself is refused" do
    assert error(~s|fn ex::a($d) = $d{"y": ex::a(@)}; ex::a(1)|) ==
             ~s(cyclic dependency detected in function definition "ex::a" detected: ex::a -> ex::a)

    assert error(~s|fn ex::a($d) = $d{"y": ex::b(@)}; fn ex::b($d) = $d{"z": ex::a(@)}; ex::a(1)|) ==
             ~s(cyclic dependency detected in function definition "ex::a" detected: ex::a -> ex::b -> ex::a)
  end

  # Each function calls the next one twice: 2^30 calls if expanded. The cap
  # refuses it while counting, long before the tree is built.
  test "a query that would expand too many calls fails fast" do
    defs =
      for i <- 1..30 do
        ~s|fn ex::f#{i}($d) = $d{"a": ex::f#{i + 1}(@), "b": ex::f#{i + 1}(@)}; |
      end

    query = Enum.join(defs) <> ~s|fn ex::f31($d) = $d{name}; ex::f1({"name": "x"})|

    {micros, result} = :timer.tc(fn -> Parser.parse(query) end)

    assert {:error, %{description: description}} = result
    assert description =~ "too many function calls"
    assert micros < 100_000, "took #{div(micros, 1000)} ms"
  end
end
