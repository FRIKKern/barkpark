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

  describe "schema_groups/1 + visible_fields/2 (Task #barkpark-dma — field-group tabs)" do
    test "schema_groups returns the declared groups list (string-keyed)" do
      schema = %{
        "groups" => [
          %{"name" => "core", "title" => "Core"},
          %{"name" => "publishing", "title" => "Publishing"}
        ]
      }

      assert StudioComponents.schema_groups(schema) == [
               %{"name" => "core", "title" => "Core"},
               %{"name" => "publishing", "title" => "Publishing"}
             ]
    end

    test "schema_groups tolerates atom keys (Ecto-struct path)" do
      schema = %{groups: [%{"name" => "core", "title" => "Core"}]}
      assert StudioComponents.schema_groups(schema) == [%{"name" => "core", "title" => "Core"}]
    end

    test "schema_groups returns [] for nil schema (mount race / no editor)" do
      assert StudioComponents.schema_groups(nil) == []
    end

    test "schema_groups returns [] for legacy schemas with no groups key (back-compat)" do
      legacy = %{"name" => "post", "fields" => [%{"name" => "title", "type" => "string"}]}
      assert StudioComponents.schema_groups(legacy) == []
    end

    test "visible_fields with nil nav_group passes everything through (back-compat default)" do
      fields = [
        %{"name" => "a", "group" => "core"},
        %{"name" => "b", "group" => "publishing"},
        %{"name" => "c"}
      ]

      assert StudioComponents.visible_fields(fields, nil) == fields
    end

    test "visible_fields filters to the active group" do
      fields = [
        %{"name" => "a", "group" => "core"},
        %{"name" => "b", "group" => "publishing"},
        %{"name" => "c", "group" => "core"},
        %{"name" => "d"}
      ]

      assert StudioComponents.visible_fields(fields, "core") == [
               %{"name" => "a", "group" => "core"},
               %{"name" => "c", "group" => "core"}
             ]
    end

    test "visible_fields excludes ungrouped fields when a tab is active" do
      fields = [
        %{"name" => "a", "group" => "core"},
        %{"name" => "untagged"}
      ]

      assert StudioComponents.visible_fields(fields, "core") == [
               %{"name" => "a", "group" => "core"}
             ]
    end
  end

  describe "studio_editor_shell/1 tab bar (Task #barkpark-dma)" do
    @editor_form %{"title" => "Test"}

    test "renders bp-tab-bar with one button per declared group" do
      schema = %{
        name: "book",
        title: "Book",
        icon: "book",
        groups: [
          %{"name" => "core", "title" => "Core"},
          %{"name" => "publishing", "title" => "Publishing"}
        ],
        fields: [
          %{"name" => "title", "type" => "string"},
          %{"name" => "isbn", "type" => "string", "group" => "core"},
          %{"name" => "publisher", "type" => "string", "group" => "publishing"}
        ]
      }

      html =
        render_component(&StudioComponents.studio_editor_shell/1, %{
          editor_doc: %{doc_id: "b1", type: "book", rev: 1, title: "T", status: "published"},
          editor_schema: schema,
          editor_form: @editor_form,
          editor_is_draft: false,
          dataset: "production",
          validation_errors: %{},
          save_status: "",
          presences: [],
          parent_assigns: %{},
          nav_group: "core"
        })

      assert html =~ ~s(class="bp-tab-bar")
      assert html =~ ~s(phx-click="select-group")
      assert html =~ ~s(phx-value-group="core")
      assert html =~ ~s(phx-value-group="publishing")
      assert html =~ "Core"
      assert html =~ "Publishing"
      # Active tab is the one named in nav_group.
      assert html =~ ~r{<button[^>]*phx-value-group="core"[^>]*class="bp-tab is-active"}
    end

    test "no tab bar when schema declares no groups (legacy / post-style schemas)" do
      schema = %{
        name: "post",
        title: "Post",
        icon: "file-text",
        fields: [
          %{"name" => "title", "type" => "string"},
          %{"name" => "body", "type" => "text"}
        ]
      }

      html =
        render_component(&StudioComponents.studio_editor_shell/1, %{
          editor_doc: %{doc_id: "p1", type: "post", rev: 1, title: "T", status: "published"},
          editor_schema: schema,
          editor_form: @editor_form,
          editor_is_draft: false,
          dataset: "production",
          validation_errors: %{},
          save_status: "",
          presences: [],
          parent_assigns: %{},
          nav_group: nil
        })

      refute html =~ "bp-tab-bar"
      refute html =~ "select-group"
    end
  end
end
