defmodule BarkparkWeb.StudioComponentsTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias BarkparkWeb.StudioComponents

  describe "document_preview/1 (Task #12 WI3 — bp-document-preview Web Component)" do
    test "wraps the WC in a phx-update=ignore container with stable id" do
      html =
        render_component(&StudioComponents.document_preview/1, %{
          document: %{"_id" => "p1", "_type" => "post", "title" => "Hello"},
          schema_name: "post",
          id: "bp-dp-post-p1"
        })

      assert html =~
               ~r{<div[^>]*id="bp-dp-post-p1"[^>]*phx-update="ignore"[^>]*class="bp-dp-wrap"}
    end

    test "passes JSON-encoded document and schema name to the custom element" do
      html =
        render_component(&StudioComponents.document_preview/1, %{
          document: %{"_id" => "b1", "_type" => "book", "title" => "ONIX Demo"},
          schema_name: "book",
          id: "bp-dp-b1"
        })

      assert html =~ ~r{<bp-document-preview[^>]*document-json="[^"]+"[^>]*schema-name="book"}

      # The encoded JSON must contain the title we passed in (HTML-escaped
      # quotes are how attribute values are emitted by Phoenix).
      assert html =~ ~s(ONIX Demo)
    end

    test "nil document yields an empty document-json attribute" do
      html =
        render_component(&StudioComponents.document_preview/1, %{
          document: nil,
          schema_name: "",
          id: "bp-dp-empty"
        })

      assert html =~ ~r{<bp-document-preview[^>]*document-json=""}
    end

    test "default id when not provided" do
      html =
        render_component(&StudioComponents.document_preview/1, %{
          document: %{"_id" => "x"}
        })

      assert html =~ ~s(id="bp-dp-default")
      assert html =~ ~s(schema-name="")
    end

    test "no bp-change / phx-hook wiring (read-only contract)" do
      html =
        render_component(&StudioComponents.document_preview/1, %{
          document: %{"_id" => "p1"},
          schema_name: "post"
        })

      refute html =~ "bp-change"
      refute html =~ "BarkparkFieldBridge"
      refute html =~ "phx-hook"
      # No hidden form input (read-only — never writes back to a form).
      refute html =~ ~s(<input type="hidden")
    end
  end
end
