defmodule BarkparkWeb.Studio.MediaFolderCountTest do
  @moduledoc """
  The folder inspector's asset count is the folder's, not the previous list's.

  Opening a folder rendered the inspector in the same tick it STARTED loading
  the folder's assets, so the badge read `this._assets.length` of the list on
  screen before — "7 assets" (All assets) for a folder holding one — and nothing
  repainted it once the folder's list landed. It also counted only the loaded
  page and said "1 assets". Found in a real browser (run-4 lane C dogfood).

  Source pin, the same shape as the explorer's other pins
  (`media_multi_upload_snapshot_test.exs`): the explorer is a plain custom
  element in `priv/static/assets`, with no JS harness in the api gate.
  """
  use ExUnit.Case, async: true

  @js Path.expand("../../../priv/static/assets/bp-asset-explorer.js", __DIR__)

  defp section(js, start_marker, end_marker) do
    [_, rest] = String.split(js, start_marker, parts: 2)
    [body | _] = String.split(rest, end_marker, parts: 2)
    body
  end

  test "a finished folder load repaints the folder inspector" do
    js = File.read!(@js)
    load = section(js, "    async _loadAssets(append) {", "\n    _thumbLabel(kind) {")
    [_, finally] = String.split(load, "} finally {", parts: 2)

    assert finally =~
             ~r/if \(!append && this\._collectionId && this\._inspectorMode === "collection" && !this\._selected\) \{\s*this\._renderCollectionInspector\(\);/,
           "the folder inspector is never repainted once the folder's own asset list has loaded"
  end

  test "the folder count is the folder total, pluralized" do
    js = File.read!(@js)

    inspector =
      section(js, "    _renderCollectionInspector() {", "\n    async _createShare(col) {")

    assert inspector =~ "Math.max(this._total || 0, this._assets.length)",
           "the folder badge counts the loaded page instead of the folder's total"

    assert inspector =~ ~s(count === 1 ? "1 asset" : count + " assets"),
           "the folder badge says \"1 assets\""

    refute inspector =~ ~s[this._statusBadge(count + " assets"],
           "the old unpluralized page-length badge is still rendered"
  end
end
