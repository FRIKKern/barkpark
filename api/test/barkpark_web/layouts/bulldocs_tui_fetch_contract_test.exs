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

  test "embedded TUI fetches Paper blocks by _id using canonical filter syntax" do
    source = File.read!(@layout)

    assert source =~ ~s|encodeURIComponent("_id=" + slug)|,
           "embedded TUI must query the Paper id used by /papers/:slug"

    refute source =~ ~s|encodeURIComponent('slug=="' + slug + '"')|,
           "legacy slug== lookup returns zero rows for Papers without a slug field"
  end
end
