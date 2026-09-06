defmodule BarkparkWeb.Studio.PaperEditor.ContextualTypedBlocksTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Barkpark.PortableDoc.Render
  alias BarkparkWeb.Studio.StudioLive.Blocks
  alias BarkparkWeb.Studio.StudioLive.Components.PaperEditor

  test "route keeps its rendered track visible above closed typed controls" do
    block = %{
      "id" => "morning-loop",
      "type" => "route",
      "polyline" => "_p~iF~ps|U_ulLnnqC_mqNvxq`@",
      "sport" => "cycling",
      "distance" => "12.4 km",
      "elevation" => "180 m",
      "duration" => "42m",
      "caption" => "Morning loop"
    }

    html = render_component(&PaperEditor.paper_block_fields/1, %{block: block})

    assert html =~ Render.render_block(block, %{style: :article})
    assert html =~ ~s(data-test-id="paper-route-preview")
    assert html =~ ~s(id="route-form-morning-loop")
    assert html =~ ~s(class="bp-paper-contextual-controls")
    assert html =~ "ignore_attrs"

    for field <- ~w(polyline sport distance elevation duration caption) do
      assert html =~ ~s(name="#{field}")
    end

    refute html =~ "blocks are not editable yet"
  end

  test "api endpoint keeps its rendered card visible above closed typed parameter controls" do
    block = %{
      "id" => "create-doc",
      "type" => "api-endpoint",
      "method" => "M-SEARCH",
      "path" => "/v1/data/:dataset",
      "params" => [
        %{"name" => "dataset", "in" => "path", "type" => "string", "required" => true},
        "legacy parameter"
      ]
    }

    html = render_component(&PaperEditor.paper_block_fields/1, %{block: block})

    assert html =~ Render.render_block(block, %{style: :article})
    assert html =~ ~s(data-test-id="paper-api-endpoint-preview")
    assert html =~ ~s(id="api-endpoint-form-create-doc")
    assert html =~ ~s(value="M-SEARCH")
    assert html =~ ~s(name="param-count" value="2")
    assert html =~ ~s(name="param-0-required" value="false")
    assert html =~ ~s(name="param-0-required" value="true")
    assert html =~ ~s(data-test-id="paper-api-endpoint-legacy-param")
    assert html =~ "ignore_attrs"
    refute html =~ "blocks are not editable yet"
  end

  test "route patch changes only submitted reader fields" do
    block = %{"type" => "route", "sport" => "cycling", "caption" => "Before", "unknown" => "keep"}

    assert Blocks.build_block_patch(block, %{
             "polyline" => "encoded",
             "caption" => "",
             "distance" => "5 km"
           }) == %{
             "polyline" => "encoded",
             "caption" => "",
             "distance" => "5 km"
           }
  end

  test "route no-op form values preserve legacy numeric metadata shapes" do
    block = %{
      "type" => "route",
      "distance" => 12.5,
      "elevation" => 180,
      "duration" => "42m"
    }

    assert Blocks.build_block_patch(block, %{
             "distance" => "12.5",
             "elevation" => "180",
             "duration" => "42m"
           }) == %{}

    assert Blocks.build_block_patch(block, %{"distance" => "13 km"}) == %{
             "distance" => "13 km"
           }
  end

  test "api endpoint parameter patches preserve unknown metadata and legacy rows" do
    first = %{
      "name" => "dataset",
      "in" => "path",
      "type" => "slug",
      "required" => true,
      "description" => "keep"
    }

    block = %{
      "type" => "api-endpoint",
      "method" => "POST",
      "path" => "/before",
      "params" => [first, "legacy parameter"]
    }

    params = %{
      "method" => "PATCH",
      "param-count" => "2",
      "param-0-name" => "document",
      "param-0-in" => "query",
      "param-0-type" => "string",
      "param-0-required" => "false"
    }

    assert {:ok, patch} = Blocks.validate_block_patch(block, params)
    assert patch["method"] == "PATCH"
    refute Map.has_key?(patch, "path")

    assert patch["params"] == [
             %{
               "name" => "document",
               "in" => "query",
               "type" => "string",
               "required" => false,
               "description" => "keep"
             },
             "legacy parameter"
           ]

    assert {:ok, %{"params" => [^first, "legacy parameter", added]}} =
             Blocks.validate_block_patch(block, %{
               "param-count" => "2",
               "param-action" => "add"
             })

    assert added == %{"name" => "", "in" => "query", "type" => "string", "required" => false}
  end

  test "api endpoint no-op fields preserve recognized legacy values and outer shape" do
    legacy_param = %{
      "name" => 42,
      "in" => "query",
      "type" => "integer",
      "required" => " TRUE ",
      "metadata" => "keep"
    }

    block = %{
      "type" => "api-endpoint",
      "method" => 9,
      "path" => "/legacy",
      "params" => legacy_param
    }

    assert {:ok, patch} =
             Blocks.validate_block_patch(block, %{
               "method" => "9",
               "path" => "/legacy",
               "param-count" => "1",
               "param-0-name" => "42",
               "param-0-in" => "query",
               "param-0-type" => "integer",
               "param-0-required" => "true"
             })

    assert patch == %{}

    assert {:ok, %{"params" => [changed]}} =
             Blocks.validate_block_patch(block, %{
               "param-count" => "1",
               "param-0-name" => "forty-two",
               "param-0-in" => "query",
               "param-0-type" => "integer",
               "param-0-required" => "false"
             })

    assert changed == %{
             "name" => "forty-two",
             "in" => "query",
             "type" => "integer",
             "required" => false,
             "metadata" => "keep"
           }
  end

  test "api endpoint parameters support bounded reorder in both directions" do
    first = %{"name" => "first"}
    second = %{"name" => "second"}
    block = %{"type" => "api-endpoint", "params" => [first, second]}

    assert {:ok, %{"params" => [^second, ^first]}} =
             Blocks.validate_block_patch(block, %{
               "param-count" => "2",
               "param-action" => "up:1"
             })

    assert {:ok, %{"params" => [^second, ^first]}} =
             Blocks.validate_block_patch(block, %{
               "param-count" => "2",
               "param-action" => "down:0"
             })

    html =
      render_component(&PaperEditor.paper_block_fields/1, %{block: Map.put(block, "id", "api")})

    assert html =~ ~s(name="param-action" value="up:1")
    assert html =~ ~s(name="param-action" value="down:0")
  end

  test "route and api endpoint have add-menu defaults" do
    assert Blocks.default_block("route", "route-id") == %{
             "id" => "route-id",
             "type" => "route",
             "polyline" => "",
             "sport" => "",
             "distance" => "",
             "elevation" => "",
             "duration" => "",
             "caption" => ""
           }

    assert Blocks.default_block("api-endpoint", "api-id") == %{
             "id" => "api-id",
             "type" => "api-endpoint",
             "method" => "",
             "path" => "",
             "params" => []
           }

    html = render_component(&PaperEditor.paper_block_editor/1, %{slug: "new", blocks: []})
    assert html =~ ~s(<option value="route">Route</option>)
    assert html =~ ~s(<option value="api-endpoint">API endpoint</option>)
  end

  test "api endpoint rejects malformed collection submissions without truncating rows" do
    block = %{
      "type" => "api-endpoint",
      "params" => [%{"name" => "one"}, %{"name" => "two"}]
    }

    for params <- [
          %{"param-count" => "1", "param-0-name" => "lost"},
          %{"param-count" => "999999999", "param-action" => "remove:0"},
          %{"param-0-name" => "lost"}
        ] do
      assert Blocks.validate_block_patch(block, params) ==
               {:error, {:malformed_collection, "params"}}
    end
  end
end
