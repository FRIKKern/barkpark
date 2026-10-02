defmodule BarkparkWeb.Studio.MediaThumbFallbackCspTest do
  @moduledoc """
  A broken media thumbnail falls back to the file-icon placeholder — without an
  inline event handler.

  The explorer rendered every thumbnail with `onerror="this.outerHTML=…"`. The
  Studio's Content-Security-Policy forbids inline event handlers, so in a real
  browser the handler never ran: each failed thumbnail (a corrupt upload, a
  deleted or unprocessed asset) logged a CSP violation and kept the browser's
  broken-image glyph (run-4 lane C dogfood). The fallback is now a delegated,
  capture-phase `error` listener keyed on `data-bp-thumb-fallback`.

  Source pin, the same shape as the explorer's other pins
  (`media_failed_badge_variant_test.exs`): the explorer is a plain custom
  element in `priv/static/assets`, with no JS harness in the api gate.
  """
  use ExUnit.Case, async: true

  @js Path.expand("../../../priv/static/assets/bp-asset-explorer.js", __DIR__)

  test "no thumbnail carries an inline event handler the CSP would block" do
    js = File.read!(@js)

    refute js =~ ~r/['"\s]on(error|load|click)=/,
           "bp-asset-explorer.js still emits an inline event handler attribute; " <>
             "the Studio CSP blocks it, so it never runs"
  end

  test "a delegated capture-phase error listener swaps broken thumbnails" do
    js = File.read!(@js)

    assert js =~ ~s(data-bp-thumb-fallback=)
    assert js =~ ~r/addEventListener\("error", \(e\) => this\._onThumbError\(e\), true\)/

    [body] = Regex.run(~r/_onThumbError\(e\) \{(.*?)\n    \}/s, js, capture: :all_but_first)
    assert body =~ ~s[hasAttribute("data-bp-thumb-fallback")]
    assert body =~ "bp-ae-file-icon"
    assert body =~ "replaceWith"
  end
end
