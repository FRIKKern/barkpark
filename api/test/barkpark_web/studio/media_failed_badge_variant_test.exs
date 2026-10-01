defmodule BarkparkWeb.Studio.MediaFailedBadgeVariantTest do
  @moduledoc """
  A media asset whose processing FAILED must not wear the green "ready" badge.

  `Barkpark.Plugins.Media.StuckProcessingSweeper` writes
  `bp_processing_status = "failed"`. The media explorer's inspector rendered
  that status through `_statusBadge(status, "ready")` (the variant was a
  literal at one call site and a processing-or-ready ternary at the other), so
  the word "failed" sat in the `--ok` green styling meant for "ready".

  Source pin, the same shape as the other Studio static-asset pins: the
  explorer is a plain custom element in `priv/static/assets`, with no JS test
  harness in the api gate.
  """
  use ExUnit.Case, async: true

  @js Path.expand("../../../priv/static/assets/bp-asset-explorer.js", __DIR__)
  @root Path.expand("../../../lib/barkpark_web/layouts/root.html.heex", __DIR__)

  test "every processing-status badge goes through the status-aware _procBadge" do
    js = File.read!(@js)

    refute js =~ ~r/_statusBadge\([^)]*bp_processing_status[^)]*\)/,
           "a call site still hands the raw processing status to _statusBadge with a fixed variant"

    refute js =~ ~r/_statusBadge\(proc, proc ===/,
           "a call site still picks the processing badge's variant inline"

    assert length(Regex.scan(~r/this\._procBadge\(payload\.bp_processing_status\)/, js)) == 2
  end

  test "_procBadge maps failed to the failed variant, not ready" do
    js = File.read!(@js)
    [body] = Regex.run(~r/_procBadge\(status\) \{(.*?)\n    \}/s, js, capture: :all_but_first)

    assert body =~ ~s(proc === "failed" ? "failed")
    assert body =~ ~s(proc === "processing" ? "processing")
  end

  test "the failed variant is styled with the danger token" do
    root = File.read!(@root)

    assert root =~
             ".bp-ae-badge--failed { color: var(--danger); border-color: hsl(var(--danger-hsl) / 0.4); }"
  end
end
