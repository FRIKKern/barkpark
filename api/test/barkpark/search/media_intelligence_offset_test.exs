defmodule Barkpark.Search.MediaIntelligenceOffsetTest do
  @moduledoc """
  The media analytics adapter must record the offset the request was SERVED at.

  `MediaIntelligence.context_from_params/2` used to re-derive the offset from
  the raw params with `Integer.parse(to_string(params["offset"]))` instead of
  reading the `MediaSearchParams.parse/1` result it computes on the line above.
  `to_string/1` is not total over the shapes Phoenix decodes a query string
  into, and `Integer.parse/1` on a concatenated list is not the served value.

  Both arms are asserted against the SERVED offset (`SearchParams.parse/1`),
  not against a hardcoded number, so the tests cannot drift apart from the
  parser they are pinning the recorder to.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Media.Delivery.SearchParams
  alias Barkpark.Search.MediaIntelligence

  defp served_offset(params), do: SearchParams.parse(params)[:offset]
  defp recorded_offset(params), do: MediaIntelligence.context_from_params("ds", params)[:offset]

  describe "a nested `offset` param (?offset[a]=1)" do
    # Phoenix decodes `?offset[a]=1` to %{"offset" => %{"a" => "1"}}. The search
    # path absorbs it (parse_int/2's catch-all returns the default); the recorder
    # used to raise Protocol.UndefinedError on to_string(map), turning a served
    # 200 into a 500 AFTER the results were already computed.
    test "does not raise, and records the served offset" do
      params = %{"offset" => %{"a" => "1"}}

      assert served_offset(params) == 0

      assert recorded_offset(params) == served_offset(params)
    end
  end

  describe "a repeated `offset` param (?offset[]=0&offset[]=1)" do
    # to_string(["0", "1"]) is "01" -> Integer.parse -> 1. `Intelligence.record/6`
    # skips recording for any offset > 0 ({:skipped, :offset_page}), so this
    # silently dropped the search event for a page the server served at offset 0.
    test "records the served offset, not the concatenated digits" do
      params = %{"offset" => ["0", "1"]}

      assert served_offset(params) == 0

      assert recorded_offset(params) == served_offset(params)
    end

    test "a two-element list cannot manufacture a nonzero recorded offset" do
      params = %{"offset" => ["1", "2"]}

      assert served_offset(params) == 0
      # The old code produced 12 here, which record/6 reads as a page-2 request.
      assert recorded_offset(params) == 0
    end
  end

  describe "recorded offset agrees with the served offset on every shape" do
    test "scalar, absent, negative, non-numeric, over-ceiling and container shapes" do
      shapes = [
        %{},
        %{"offset" => nil},
        %{"offset" => "0"},
        %{"offset" => "7"},
        %{"offset" => 7},
        %{"offset" => "-3"},
        %{"offset" => "abc"},
        %{"offset" => " 5"},
        # Above SearchParams' 100_000 ceiling: the recorder must report the
        # CLAMPED value, because that is the page the caller was served.
        %{"offset" => "5000000"},
        %{"offset" => ["0", "1"]},
        %{"offset" => ["1", "2"]},
        %{"offset" => %{"a" => "1"}},
        %{"offset" => %{}},
        %{"offset" => []},
        %{"offset" => true}
      ]

      # Non-vacuity: at least one shape must produce a nonzero served offset, so
      # a recorder that hardcoded 0 could not pass this test.
      assert Enum.any?(shapes, &(served_offset(&1) > 0))

      for params <- shapes do
        assert recorded_offset(params) == served_offset(params),
               "recorded offset diverged from the served offset for #{inspect(params)}: " <>
                 "recorded #{inspect(recorded_offset(params))}, served #{inspect(served_offset(params))}"
      end
    end
  end
end
