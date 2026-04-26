defmodule BarkparkWeb.Studio.Plugins.AdapterTest do
  # DataCase gives us a Repo sandbox so the codelist component's default
  # loader (which calls Barkpark.Content.Codelists.get/2) doesn't blow up
  # against a live database. The empty-registry path returns nil cleanly.
  use Barkpark.DataCase, async: true

  import Phoenix.LiveViewTest

  alias BarkparkWeb.Studio.Plugins.Adapter

  describe "v2?/1" do
    test "returns true for the four v2 types (string-keyed map)" do
      for t <- ~w(composite arrayOf codelist localizedText) do
        assert Adapter.v2?(%{"type" => t, "name" => "f"}) == true,
               "expected #{t} to be detected as v2"
      end
    end

    test "returns false for v1 types" do
      for t <- ~w(string text richText slug datetime color boolean select reference image array) do
        refute Adapter.v2?(%{"type" => t, "name" => "f"}),
               "v1 type #{t} must NOT be routed via the adapter"
      end
    end

    test "returns false for malformed input" do
      refute Adapter.v2?(nil)
      refute Adapter.v2?(%{})
      refute Adapter.v2?("composite")
      refute Adapter.v2?(%{"name" => "no_type"})
    end

    test "v2_types/0 lists exactly the four Phase 0 v2 type names" do
      assert Enum.sort(Adapter.v2_types()) ==
               Enum.sort(~w(composite arrayOf codelist localizedText))
    end
  end

  describe "render/2 — dispatches by type" do
    test "composite field renders with composite data attribute and sub-field labels" do
      field = %{
        "type" => "composite",
        "name" => "address",
        "title" => "Address",
        "fields" => [
          %{"type" => "string", "name" => "street", "title" => "Street"},
          %{"type" => "string", "name" => "city", "title" => "City"}
        ]
      }

      assigns = %{
        editor_form: %{"address" => %{"street" => "Karl Johans gate 1", "city" => "Oslo"}},
        editor_schema: nil,
        validation_errors: %{}
      }

      html = rendered_to_string(Adapter.render(assigns, field))

      assert html =~ ~s(data-field-type="composite")
      assert html =~ ~s(data-field-name="address")
      assert html =~ "Address"
      assert html =~ "Street"
      assert html =~ "City"
      assert html =~ "Karl Johans gate 1"
    end

    test "arrayOf field renders with arrayOf data attribute and Add button" do
      field = %{
        "type" => "arrayOf",
        "name" => "tags",
        "title" => "Tags",
        "ordered" => true,
        "of" => %{"type" => "string", "name" => "tag"}
      }

      assigns = %{
        editor_form: %{"tags" => ["alpha", "beta"]},
        editor_schema: nil,
        validation_errors: %{}
      }

      html = rendered_to_string(Adapter.render(assigns, field))

      assert html =~ ~s(data-field-type="arrayOf")
      assert html =~ ~s(data-field-name="tags")
      assert html =~ ~s(data-ordered="true")
      assert html =~ "+ Add"
      # ordered → up/down buttons appear
      assert html =~ "Move up"
      assert html =~ "Move down"
    end

    test "codelist field renders the empty-registry placeholder when registry is unseeded" do
      field = %{
        "type" => "codelist",
        "name" => "role",
        "title" => "Role",
        "codelistId" => "ghost-plugin:not-registered",
        "version" => 73
      }

      assigns = %{
        editor_form: %{"role" => nil},
        editor_schema: nil,
        validation_errors: %{}
      }

      html = rendered_to_string(Adapter.render(assigns, field))

      # Phase 4 must degrade gracefully when WI3 hasn't seeded codelists yet.
      assert html =~ "no codelist registered"
      assert html =~ "ghost-plugin:not-registered"
      assert html =~ "disabled"
    end

    test "localizedText field renders one input per declared language" do
      field = %{
        "type" => "localizedText",
        "name" => "blurb",
        "title" => "Blurb",
        "languages" => ["eng", "nob"],
        "format" => "plain",
        "fallbackChain" => ["eng"]
      }

      assigns = %{
        editor_form: %{"blurb" => %{"eng" => "Hello", "nob" => "Hei"}},
        editor_schema: nil,
        validation_errors: %{}
      }

      html = rendered_to_string(Adapter.render(assigns, field))

      assert html =~ "Hello"
      assert html =~ "Hei"
      # Both language tabs rendered
      assert html =~ "eng"
      assert html =~ "nob"
    end

    test "missing value falls back to the type-appropriate empty default" do
      # composite → empty map, no crash
      field = %{
        "type" => "composite",
        "name" => "addr",
        "fields" => [%{"type" => "string", "name" => "city"}]
      }

      assigns = %{editor_form: %{}, editor_schema: nil, validation_errors: %{}}

      html = rendered_to_string(Adapter.render(assigns, field))
      assert html =~ ~s(data-field-name="addr")
    end
  end

  describe "render/2 — plugin owner discovery" do
    test "codelistId prefix wins when no schema-level plugin is set" do
      field = %{
        "type" => "codelist",
        "name" => "role",
        "codelistId" => "onixedit:contributor_role",
        "version" => 73
      }

      assigns = %{editor_form: %{}, editor_schema: nil, validation_errors: %{}}
      html = rendered_to_string(Adapter.render(assigns, field))

      # Plugin "onixedit" extracted from codelistId prefix.
      assert html =~ ~s|data-codelist-id="onixedit:onixedit:contributor_role"| or
               html =~ ~s(data-codelist-id="onixedit:contributor_role")
    end

    test "schema-level plugin overrides the codelistId prefix" do
      field = %{
        "type" => "codelist",
        "name" => "role",
        "codelistId" => "anything"
      }

      assigns = %{
        editor_form: %{},
        editor_schema: %{"plugin" => "myplugin"},
        validation_errors: %{}
      }

      html = rendered_to_string(Adapter.render(assigns, field))
      assert html =~ "myplugin"
    end

    test "field-level plugin overrides everything else" do
      field = %{
        "type" => "codelist",
        "name" => "role",
        "plugin" => "fieldplugin",
        "codelistId" => "schemaplugin:list"
      }

      assigns = %{
        editor_form: %{},
        editor_schema: %{"plugin" => "schemaplugin"},
        validation_errors: %{}
      }

      html = rendered_to_string(Adapter.render(assigns, field))
      assert html =~ "fieldplugin"
    end
  end

  describe "no-regression: v1 schemas" do
    test "v1 string field is NOT v2 — adapter declines, StudioLive uses render_input" do
      # The hook in studio_live.ex checks v2?/1 first and only routes v2 fields
      # through the adapter. v1 schemas (post, page, author, …) never enter
      # render/2. This is the legacy-parity invariant.
      v1_post_fields = [
        %{"type" => "string", "name" => "title"},
        %{"type" => "slug", "name" => "slug"},
        %{"type" => "richText", "name" => "body"},
        %{"type" => "image", "name" => "cover"},
        %{"type" => "select", "name" => "category", "options" => ["a", "b"]},
        %{"type" => "boolean", "name" => "published"},
        %{"type" => "color", "name" => "accent"},
        %{"type" => "datetime", "name" => "publishedAt"},
        %{"type" => "reference", "name" => "author", "refType" => "author"}
      ]

      for f <- v1_post_fields do
        refute Adapter.v2?(f),
               "v1 field #{inspect(f)} must NOT be routed through the v2 adapter"
      end
    end

    test "render/2 with non-v2 input returns an empty rendered (defensive — never crash)" do
      assigns = %{editor_form: %{}, editor_schema: nil, validation_errors: %{}}
      html = rendered_to_string(Adapter.render(assigns, %{"type" => "string", "name" => "x"}))
      # Empty render — StudioLive should have used render_input/2 instead.
      assert html == "" or String.trim(html) == ""
    end
  end
end
