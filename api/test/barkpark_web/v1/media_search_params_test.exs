defmodule BarkparkWeb.V1.MediaSearchParamsTest do
  use ExUnit.Case, async: true

  alias BarkparkWeb.V1.MediaSearchParams

  test "array/nested query params parse fail-soft to nil instead of crashing" do
    opts =
      MediaSearchParams.parse(%{
        "type" => ["x"],
        "facet" => %{"mimeType" => ["y"]}
      })

    assert opts[:mime_type] == nil
    assert opts[:facet_selections] == %{}
  end

  test "normal string type param still yields the mime_type" do
    opts = MediaSearchParams.parse(%{"type" => "image/png"})

    assert opts[:mime_type] == "image/png"
  end
end
