defmodule BarkparkWeb.Studio.NavTest do
  use ExUnit.Case, async: true
  alias BarkparkWeb.Studio.Nav

  test "tabs/1 returns dataset-prefixed paths" do
    [structure, media, api] = Nav.tabs("staging")
    assert structure.id == :structure
    assert structure.path == "/studio/staging"
    assert media.path == "/studio/staging/media"
    # Task barkpark-rsek carry-over: legacy `/api-tester` was replaced by
    # the admin `/_api` LV (`BarkparkWeb.Admin.ApiTestRunnerLive`). The
    # Nav module mirrors the canonical tab list rendered by
    # `studio_components.ex` which points the "API" tab at `/_api`.
    assert api.path == "/studio/staging/_api"
  end

  test "tabs/1 URL-encodes dataset with special chars" do
    [structure | _] = Nav.tabs("foo bar")
    assert structure.path == "/studio/foo%20bar"
  end
end
