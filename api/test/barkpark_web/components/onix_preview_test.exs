defmodule BarkparkWeb.Components.OnixPreviewTest do
  @moduledoc """
  Smoke coverage for `BarkparkWeb.Components.OnixPreview` — the
  side-pane ONIX 3.0 XML preview wired into StudioLive's book editor.
  Pins the visual contract (root class, test id, error badge, empty
  state) so future renderer edits don't silently break the pane.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias BarkparkWeb.Components.OnixPreview

  describe "onix_preview/1" do
    test "renders empty state when xml and error are both nil" do
      html =
        render_component(&OnixPreview.onix_preview/1, %{
          doc: %{},
          type: "book",
          xml: nil,
          error: nil
        })

      assert html =~ ~s(class="bp-onix-preview")
      assert html =~ ~s(data-test-id="onix-preview")
      assert html =~ ~s(data-bp-type="book")
      assert html =~ "ONIX 3.0 preview"
      assert html =~ "Start editing to see ONIX"
      refute html =~ "bp-onix-preview-body"
      refute html =~ "export failed"
    end

    test "renders xml inside <pre><code> with byte-size meta when xml is present" do
      xml = ~s(<?xml version="1.0"?><ONIXMessage/>)

      html =
        render_component(&OnixPreview.onix_preview/1, %{
          doc: %{},
          type: "book",
          xml: xml,
          error: nil
        })

      assert html =~ "<pre"
      assert html =~ "bp-onix-preview-body"
      assert html =~ "<code>"
      # XML angle brackets are HTML-escaped inside <code>
      assert html =~ "&lt;ONIXMessage/&gt;"
      assert html =~ "#{byte_size(xml)} bytes"
      refute html =~ "Start editing to see ONIX"
      refute html =~ "export failed"
    end

    test "renders soft error badge when error is set, suppressing meta" do
      html =
        render_component(&OnixPreview.onix_preview/1, %{
          doc: %{},
          type: "book",
          xml: nil,
          error: {:xsd_invalid, ["missing ProductIdentifier"]}
        })

      assert html =~ ~s(class="bp-onix-preview-error")
      assert html =~ "export failed"
      # Empty state suppressed when error is present
      refute html =~ "Start editing to see ONIX"
      # Meta byte-count suppressed when error is present
      refute html =~ "bytes"
    end

    test "renders both error badge and xml when error is set alongside stale xml" do
      # Useful when a transient export failure should not blank the
      # previously-good preview — the error badge surfaces while the
      # last good XML stays visible. Current contract: when an error
      # is present we suppress the byte-count meta but keep the body.
      xml = ~s(<?xml version="1.0"?><ONIXMessage/>)

      html =
        render_component(&OnixPreview.onix_preview/1, %{
          doc: %{},
          type: "book",
          xml: xml,
          error: {:xsd_invalid, ["something"]}
        })

      assert html =~ "export failed"
      assert html =~ "bp-onix-preview-body"
      refute html =~ "bytes"
    end
  end
end
