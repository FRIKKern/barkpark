defmodule BarkparkWeb.Studio.StudioLive.KeptRowsKeepsFalseTest do
  @moduledoc """
  `KeptRows.only_stored/2` passes a posted `false` or `nil` through. It used
  to drop them, so a switch turned off inside an object was never saved
  (`absent_object_booleans_test.exs:143`, red on main at a8426a7ed9).
  """
  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.StudioLive.KeptRows

  test "a posted false is kept, top level and nested" do
    params = %{
      "doc" => %{
        "pinned" => false,
        "share" => %{"channels" => %{"alpha" => false}},
        "probe" => "after"
      }
    }

    assert KeptRows.only_stored(params, %{}) == params
  end

  test "a posted nil is kept" do
    params = %{"doc" => %{"cover" => nil, "box" => %{"note" => nil}}}

    assert KeptRows.only_stored(params, %{"cover" => "x"}) == params
  end

  test "a kept row the buffer no longer holds is still dropped" do
    params = %{"doc" => %{"tags" => %{"0" => %{"_json" => ~s({"_key":"a"})}, "1" => false}}}

    assert KeptRows.only_stored(params, %{"tags" => []}) ==
             %{"doc" => %{"tags" => %{"1" => false}}}
  end
end
