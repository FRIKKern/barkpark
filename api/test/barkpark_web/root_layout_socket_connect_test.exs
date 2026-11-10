defmodule BarkparkWeb.RootLayoutSocketConnectTest do
  @moduledoc """
  task-ca0936b4ca4a936d: the LiveView socket does not wait for the paper
  editor bundle.

  `liveSocket.connect()` runs while the page is still parsing, so LiveView
  waits for DOMContentLoaded, and a `defer` script holds DOMContentLoaded.
  The 1 MB `bp-paper-editor.bundle.js` was `defer`, so every Studio page's
  socket waited for it. It is `async` now, and the paper hooks wait for its
  two elements instead (the gate's behaviour is
  api/assets/paper-editor-host-tests/__paper_bundle_gate.test.mjs).
  """
  use ExUnit.Case, async: true

  @layout Path.expand("../../lib/barkpark_web/layouts/root.html.heex", __DIR__)

  setup_all do
    %{src: File.read!(@layout)}
  end

  defp bundle_tag(src) do
    [tag] = Regex.run(~r/<script[^>]*"bp-paper-editor\.bundle\.js"[^>]*>/, src)
    tag
  end

  test "the paper editor bundle is async, so it does not hold DOMContentLoaded", %{src: src} do
    tag = bundle_tag(src)
    assert tag =~ ~r/\sasync>$/, "the bundle tag is not async: #{tag}"
    refute tag =~ ~r/\sdefer[\s>]/, "the bundle tag still defers: #{tag}"
  end

  test "the paper hooks are merged through the bundle gate, not as they are", %{src: src} do
    refute src =~ "Object.assign(Hooks, window.BarkparkPaperEditorHooks",
           "the paper hooks are merged without waiting for the bundle's elements"

    [gate] =
      Regex.run(~r{^[^\n]*// bp-paper-bundle-gate:start\n.*// bp-paper-bundle-gate:end$}ms, src)

    assert gate =~ ~S|["bp-paper-canvas", "bp-paper-editor"]|
    assert gate =~ "window.BarkparkPaperEditorHooks"
    assert gate =~ "Hooks.BarkparkFieldCanvas = bpAfterPaperBundle(Hooks.BarkparkFieldCanvas)"
  end

  test "the gate runs after every hook it wraps is defined and before the socket is built",
       %{src: src} do
    {gate_at, _} = :binary.match(src, "// bp-paper-bundle-gate:start")
    {canvas_at, _} = :binary.match(src, "    Hooks.BarkparkFieldCanvas = {")
    {hooks_script_at, _} = :binary.match(src, ~S|StaticAssets.path("bp-paper-editor-hooks.js")|)
    {socket_at, _} = :binary.match(src, "new LiveView.LiveSocket(")

    assert hooks_script_at < gate_at
    assert canvas_at < gate_at
    assert gate_at < socket_at
  end
end
