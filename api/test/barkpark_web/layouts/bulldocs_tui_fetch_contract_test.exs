defmodule BarkparkWeb.Layouts.BulldocsTuiFetchContractTest do
  @moduledoc """
  Locks the browser Paper reader's embedded-TUI lookup to canonical Paper
  identity. `/papers/:slug` names the document `_id`; a separate `slug` content
  field is optional and absent from most live Papers.

  This source-level needle protects the JavaScript fetch seam that headless
  ExUnit cannot execute with the Go WASM renderer. Query-controller tests own
  the `_id=<value>` GROQ-lite behavior itself.
  """
  use ExUnit.Case, async: true

  @layout Path.expand(
            "../../../lib/barkpark_web/layouts/bulldocs.html.heex",
            __DIR__
          )

  test "embedded TUI fetches through the current Paper capability and preserves shares" do
    source = File.read!(@layout)

    assert source =~ ~s|location.pathname.replace(|
    assert source =~ ~s|+ "/source" + location.search|
    assert source =~ "var r = await fetch(url);"
    assert source =~ ~s|source.kind === "blocks"|
    assert source =~ ~s|source.kind === "html"|
    assert source =~ "new DOMParser()"

    refute source =~ "/v1/data/doc/"
    refute source =~ ~s|accept: "application/json"|
    refute source =~ "/v1/data/query/production/paper"
  end
end
