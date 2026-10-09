defmodule BarkparkWeb.Components.ArrayFieldFocusHookTest do
  @moduledoc """
  task-278c7992ed05a30b: an array field's row buttons are server round-trips,
  and focus was left on Add, dropped to <body> or left on the neighbour after
  a move. bp-array-focus.js (behaviour: `__array_focus.test.mjs`) finds the
  fieldset again by a stable id after the patch; array fields still carry no
  phx-hook (Decision 13), and the Studio layout loads the script.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Barkpark.Content.SchemaDefinition
  alias BarkparkWeb.Components.Fields.ArrayField

  defp field do
    {:ok, parsed} =
      SchemaDefinition.parse(%{
        "name" => "t",
        "title" => "T",
        "fields" => [
          %{
            "name" => "tags",
            "title" => "Tags",
            "type" => "arrayOf",
            "ordered" => true,
            "of" => %{"type" => "string"}
          }
        ]
      })

    hd(parsed.fields)
  end

  test "each array fieldset carries a unique, stable id and still no phx-hook" do
    top =
      render_component(&ArrayField.array_field/1, field: field(), value: ["a"], path: "doc[tags]")

    nested =
      render_component(&ArrayField.array_field/1,
        field: field(),
        value: ["a"],
        path: "doc[rows][0][tags]"
      )

    [top_id] =
      Regex.run(~r/<fieldset[^>]*id="([^"]+)"/s, top, capture: :all_but_first)

    [nested_id] = Regex.run(~r/<fieldset[^>]*id="([^"]+)"/s, nested, capture: :all_but_first)

    assert top_id =~ ~r/^bp-array-/
    refute top_id == nested_id
    refute top =~ "phx-hook"
  end

  test "the Studio layout loads bp-array-focus.js" do
    root = File.read!("lib/barkpark_web/layouts/root.html.heex")
    assert root =~ ~s(<script src="/assets/bp-array-focus.js"></script>)
    assert File.exists?(Path.join(:code.priv_dir(:barkpark), "static/assets/bp-array-focus.js"))
  end
end
