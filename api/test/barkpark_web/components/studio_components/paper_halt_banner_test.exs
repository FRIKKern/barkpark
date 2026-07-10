defmodule BarkparkWeb.StudioComponents.PaperHaltBannerTest do
  @moduledoc """
  Guards the server-owned save-halt mirror banner
  (`Editor.paper_halt_banner/1`, task p-hollow-studio-mirror). Pure component
  render — no Repo, no server boot. The banner MIRRORS the server truth: it
  shows the `{:error, {:halted, reason}}` string verbatim (M1 template halt
  today, the hollow-doc gate tomorrow) and authors no copy of its own (charter
  D5/D6). `reason == nil` → nothing renders.
  """
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias BarkparkWeb.StudioComponents.Editor

  defp render(reason),
    do: render_component(&Editor.paper_halt_banner/1, %{reason: reason})

  describe "absent state — nil reason renders nothing" do
    test "nil emits no markup at all" do
      html = render(nil)
      refute html =~ "bp-paper-halt"
      refute html =~ "paper-halt-banner"
      assert String.trim(html) == ""
    end
  end

  describe "present state — a halt reason raises the mirror banner" do
    test "renders the .bp-violations shell with the paper-halt marker" do
      html = render("paper template violated: title block is required")
      assert html =~ "bp-violations"
      assert html =~ "bp-paper-halt"
      assert html =~ ~s(data-test-id="paper-halt-banner")
    end

    test "carries role=alert so assistive tech announces the veto" do
      html = render("paper template violated: title block is required")
      assert html =~ ~s(role="alert")
    end

    test "shows the server reason string VERBATIM — no editor-authored copy" do
      reason = "paper template violated: featured-image block is required"
      html = render(reason)
      assert html =~ reason
    end

    test "renders a document-is-hollow gate reason unchanged (forward-compat)" do
      # The sibling hollow-doc gate will emit its own reason; the mirror must
      # pass whatever the server says through untouched.
      reason = "document is hollow — add a content block beyond title"
      html = render(reason)
      assert html =~ reason
    end
  end
end
