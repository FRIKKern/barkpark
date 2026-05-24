defmodule Barkpark.Content.SearchIntelligenceTest do
  use ExUnit.Case, async: true

  alias Barkpark.Content.SearchIntelligence

  test "context_from_params captures query, type, perspective, offset" do
    ctx =
      SearchIntelligence.context_from_params(%{
        "q" => "  phoenix  ",
        "type" => "post",
        "perspective" => "drafts",
        "offset" => "10"
      })

    assert ctx.query == "phoenix"
    assert ctx.offset == 10
    assert ctx.filters == %{"type" => "post", "perspective" => "drafts"}
  end

  test "context_from_params defaults perspective to published" do
    ctx = SearchIntelligence.context_from_params(%{"q" => "hello"})
    assert ctx.filters == %{"perspective" => "published"}
  end
end
