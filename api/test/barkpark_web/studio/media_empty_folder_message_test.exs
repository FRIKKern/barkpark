defmodule BarkparkWeb.Studio.MediaEmptyFolderMessageTest do
  @moduledoc """
  An empty folder says it is empty, not that filters matched nothing
  (task-575bf6656312084a).

  `_activeFacetEntries()` lists the open folder beside search, facets and
  kind, because the toolbar renders a pill for each. The empty message and
  the find bar read the same list, so an empty folder with no filter said
  "No assets match these filters — try removing one". They now read
  `_narrowingEntries()`, which leaves the folder out.

  Source pin, the same shape as the explorer's other pins
  (`media_folder_count_test.exs`): the explorer is a plain custom element in
  `priv/static/assets`, with no JS harness in the api gate.
  """
  use ExUnit.Case, async: true

  @js Path.expand("../../../priv/static/assets/bp-asset-explorer.js", __DIR__)

  defp section(js, start_marker, end_marker) do
    [_, rest] = String.split(js, start_marker, parts: 2)
    [body | _] = String.split(rest, end_marker, parts: 2)
    body
  end

  test "the narrowing entries leave the open folder out" do
    js = File.read!(@js)
    narrowing = section(js, "    _narrowingEntries() {", "\n    }")

    assert narrowing =~ ~S|this._activeFacetEntries().filter(([field]) => field !== "collection")|,
           "the folder still counts as a filter"
  end

  test "the empty message and the find bar ask only about narrowing entries" do
    js = File.read!(@js)

    empty = section(js, "    _emptyMessage() {", "\n    _toggleFacet(")
    assert empty =~ "if (this._narrowingEntries().length) {"
    refute empty =~ "_activeFacetEntries()"
    assert empty =~ "This folder is empty"

    find_bar = section(js, "    _renderFindBar() {", "\n    _emptyMessage() {")
    assert find_bar =~ "const entries = this._narrowingEntries();"
    refute find_bar =~ "_activeFacetEntries()"
  end

  test "the folder pill still renders from the full entry list" do
    js = File.read!(@js)
    pills = section(js, "    _renderToolbarPills() {", "\n    _renderFindBar() {")
    assert pills =~ "const entries = this._activeFacetEntries();"
  end
end
