defmodule Barkpark.Content.SearchIntelligenceOffsetTest do
  @moduledoc """
  The documents analytics adapter must record the offset the request was SERVED at.

  `SearchIntelligence.context_from_params/1` used to re-derive the offset with a
  private `parse_offset/1` doing `Integer.parse(to_string(params["offset"]))` —
  byte-for-byte the function PR #16871 deleted from the media adapter. It
  diverged from the route's clamp on every non-binary shape Phoenix decodes a
  query string into.

  Unlike the media surface there is no `SearchParams.parse/1` to read from, so
  the fix was to give the door ONE parser: `SearchIntelligence.parse_offset/1`,
  which `SearchController` now uses for the query it serves. These tests assert
  the recorded value equals the SERVED value (that same function's result), not
  a hardcoded number, so they cannot drift from what the route serves.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.SearchIntelligence

  defp served_offset(params), do: SearchIntelligence.parse_offset(params)
  defp recorded_offset(params), do: SearchIntelligence.context_from_params(params)[:offset]

  describe "a nested `offset` param (?offset[a]=1)" do
    # Phoenix decodes `?offset[a]=1` to %{"offset" => %{"a" => "1"}}. The search
    # path absorbs it; the recorder used to raise Protocol.UndefinedError on
    # to_string(map) — turning a served 200 into a 500 AFTER the results were
    # computed, because context_from_params/1 is evaluated eagerly as a call
    # argument in record/5, outside Intelligence.record/6's rescue.
    test "does not raise, and records the served offset" do
      params = %{"offset" => %{"a" => "1"}}

      assert served_offset(params) == 0
      assert recorded_offset(params) == served_offset(params)
    end
  end

  describe "a repeated `offset` param (?offset[]=0&offset[]=1)" do
    # to_string(["0", "1"]) is "01" -> Integer.parse -> 1. Intelligence.record/6
    # skips any offset > 0 as {:skipped, :offset_page}, so this silently dropped
    # the search event for a page the server served at offset 0.
    test "records the served offset, not the concatenated digits" do
      params = %{"offset" => ["0", "1"]}

      assert served_offset(params) == 0
      assert recorded_offset(params) == served_offset(params)
    end

    test "a two-element list cannot manufacture a nonzero recorded offset" do
      params = %{"offset" => ["1", "2"]}

      assert served_offset(params) == 0
      # The old code produced 12 here, which record/6 reads as a page-12 request.
      assert recorded_offset(params) == 0
    end
  end

  describe "the ceiling" do
    test "an above-ceiling offset is clamped, and the clamped value is recorded" do
      params = %{"offset" => "5000000"}

      assert served_offset(params) == 100_000
      assert recorded_offset(params) == 100_000
    end

    test "a negative offset is floored at 0" do
      assert served_offset(%{"offset" => "-3"}) == 0
      assert recorded_offset(%{"offset" => "-3"}) == 0
    end

    test "an in-range offset is passed through untouched" do
      assert served_offset(%{"offset" => "25"}) == 25
      assert recorded_offset(%{"offset" => "25"}) == 25
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
        %{:offset => "9"},
        %{"offset" => "-3"},
        %{"offset" => "abc"},
        %{"offset" => " 5"},
        %{"offset" => "5000000"},
        %{"offset" => 5_000_000},
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
      # Non-vacuity: the ceiling must actually bind for at least one shape.
      assert Enum.any?(shapes, &(served_offset(&1) == 100_000))

      for params <- shapes do
        assert recorded_offset(params) == served_offset(params),
               "recorded offset diverged from the served offset for #{inspect(params)}: " <>
                 "recorded #{inspect(recorded_offset(params))}, served #{inspect(served_offset(params))}"
      end
    end
  end
end
