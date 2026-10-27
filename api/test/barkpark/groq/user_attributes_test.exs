defmodule Barkpark.Groq.UserAttributesTest do
  @moduledoc """
  task-de59c528ba98db66: `user::attributes()` answers null, as Sanity does for
  every caller without member attributes (a robot token, no token; ecu57yeh,
  27 Oct). Barkpark has seats and roles, not attributes, so that is every
  caller it can have. In a query, the null compares as any null does: a
  document whose field is also missing matches (null == null), as on Sanity
  (all 31 posts on e2e-local); a guard with defined() matches nothing.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Groq.{Evaluator, MemorySource, Parser}

  @docs [
    %{"_id" => "p1", "_type" => "post", "branch" => "oslo"},
    %{"_id" => "p2", "_type" => "post"}
  ]

  defp q(query, opts \\ []) do
    {:ok, tree} = Parser.parse(query)
    {:ok, value} = Evaluator.evaluate(tree, [source: MemorySource.new(@docs)] ++ opts)
    value
  end

  test "user::attributes() is null, for an anonymous caller and a token alike" do
    assert q("user::attributes()") == nil
    assert q("user::attributes()", identity: "a-token-id") == nil
    assert q("user::attributes().branch") == nil
    assert q("defined(user::attributes())") == false
    assert q(~s|*[_id == "p1"][0]{_id, "a": user::attributes()}|) == %{"_id" => "p1", "a" => nil}
  end

  test "a filter on an attribute compares a null, as on Sanity" do
    assert q(~s|*[_type == "post" && branch == user::attributes().branch]._id|) == ["p2"]

    assert q(
             ~s|*[_type == "post" && defined(user::attributes().branch) && branch == user::attributes().branch]._id|
           ) == []
  end

  test "it takes no arguments" do
    assert {:error, %{description: description}} = Parser.parse("user::attributes(1)")
    assert description == "zero arguments expected"
  end
end
