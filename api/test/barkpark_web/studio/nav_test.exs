defmodule BarkparkWeb.Studio.NavTest do
  use ExUnit.Case, async: true
  alias BarkparkWeb.Studio.Nav

  test "tabs/1 returns dataset-prefixed paths" do
    [structure, media, api] = Nav.tabs("staging")
    assert structure.id == :structure
    assert structure.path == "/studio/staging"
    assert media.path == "/studio/staging/media"
    assert api.path == "/studio/staging/api-tester"
  end

  test "tabs/1 URL-encodes dataset with special chars" do
    [structure | _] = Nav.tabs("foo bar")
    assert structure.path == "/studio/foo%20bar"
  end
end
