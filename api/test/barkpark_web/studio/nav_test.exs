defmodule BarkparkWeb.Studio.NavTest do
  use ExUnit.Case, async: true
  alias BarkparkWeb.Studio.Nav

  test "tabs/1 returns dataset-prefixed paths" do
    [structure, media, api] = Nav.tabs("staging")
    assert structure.id == :structure
    assert structure.path == "/studio/staging"
    assert media.path == "/studio/staging/media"
    # Task barkpark-7xne: the legacy rich `/api-tester` LV was restored
    # (the bsp-era `/_api` replacement was much thinner). The Nav module
    # mirrors the canonical tab list rendered by `studio_components.ex`
    # which points the "API" tab at `/api-tester`.
    assert api.path == "/studio/staging/api-tester"
  end

  test "tabs/1 URL-encodes dataset with special chars" do
    [structure | _] = Nav.tabs("foo bar")
    assert structure.path == "/studio/foo%20bar"
  end
end
