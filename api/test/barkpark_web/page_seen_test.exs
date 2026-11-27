defmodule BarkparkWeb.PageSeenTest do
  @moduledoc "`PageSeen.take/2` takes a pushed digest as bp-array-focus.js's `takeOk` does."
  use ExUnit.Case, async: true

  alias BarkparkWeb.PageSeen

  @a String.duplicate("a", 16)
  @b String.duplicate("b", 16)

  test "a 16-hex digest is taken under ok, the last push winning" do
    seen = %{"v" => 2, "doc[title]" => 3}
    seen = seen |> PageSeen.take(%{"doc[body]" => @a}) |> PageSeen.take(%{"doc[body]" => @b})
    assert seen == %{"v" => 2, "doc[title]" => 3, "ok" => %{"doc[body]" => @b}}
  end

  test "a digest of another shape is not taken, and the one kept stays" do
    seen = %{"ok" => %{"doc[body]" => @a}}

    for bad <- [String.upcase(@b), "b", @b <> "b", 12, nil, %{}] do
      assert PageSeen.take(seen, %{"doc[body]" => bad}) == seen
    end
  end

  test "an ok that is not a map starts anew; oks that are not a map take nothing" do
    assert PageSeen.take(%{"ok" => "x"}, %{"doc[body]" => @a}) == %{"ok" => %{"doc[body]" => @a}}
    assert PageSeen.take(%{"v" => 2}, nil) == %{"v" => 2}
  end
end
