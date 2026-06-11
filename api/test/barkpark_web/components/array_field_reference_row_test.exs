defmodule BarkparkWeb.Components.ArrayFieldReferenceRowTest do
  @moduledoc """
  tsk-dossier-ref-picker: arrayOf-of-reference rows render real pickers
  (the same Web Components the top-level FieldInputs mount), not bare
  text inputs — with the scoped-surface context threaded through.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Barkpark.Content.SchemaDefinition
  alias BarkparkWeb.Components.Fields.ArrayField

  defp parsed_field(of) do
    {:ok, parsed} =
      SchemaDefinition.parse(%{
        "name" => "t",
        "title" => "T",
        "fields" => [
          %{
            "name" => "refs",
            "title" => "Refs",
            "type" => "arrayOf",
            "ordered" => false,
            "of" => of
          }
        ]
      })

    hd(parsed.fields)
  end

  test "mediaAsset rows mount bp-media-picker with scope + token context" do
    html =
      render_component(&ArrayField.array_field/1,
        field: parsed_field(%{"type" => "reference", "refType" => "mediaAsset"}),
        value: ["m1", "m2"],
        path: "doc[attachments]",
        dataset: "production",
        scope_prefix: "/w/acme/p/blog",
        api_token_raw: "tok-123"
      )

    assert html =~ "<bp-media-picker"
    assert html =~ ~s(value-mode="reference")
    assert html =~ ~s(scope-prefix="/w/acme/p/blog")
    assert html =~ ~s(data-token="tok-123")
    assert html =~ ~s(name="doc[attachments][0]")
    assert html =~ ~s(name="doc[attachments][1]")
    refute html =~ ~r{<input[^>]*type="text"[^>]*doc\[attachments\]}
  end

  test "generic reference rows mount bp-reference-picker with the refType" do
    html =
      render_component(&ArrayField.array_field/1,
        field: parsed_field(%{"type" => "reference", "refType" => "task"}),
        value: ["tsk-a"],
        path: "doc[related]",
        dataset: "production"
      )

    assert html =~ "<bp-reference-picker"
    assert html =~ ~s(ref-type="task")
    assert html =~ ~s(name="doc[related][0]")
  end

  test "row wrapper ids are value-keyed (a reorder/selection remounts the WC)" do
    args = [
      field: parsed_field(%{"type" => "reference", "refType" => "task"}),
      path: "doc[related]",
      dataset: "production"
    ]

    html_a = render_component(&ArrayField.array_field/1, args ++ [value: ["tsk-a"]])
    html_b = render_component(&ArrayField.array_field/1, args ++ [value: ["tsk-b"]])

    [id_a] = Regex.run(~r/id="(bp-aref-[^"]+)"/, html_a, capture: :all_but_first)
    [id_b] = Regex.run(~r/id="(bp-aref-[^"]+)"/, html_b, capture: :all_but_first)
    refute id_a == id_b
  end

  test "plain string rows still render the leaf text input (unchanged)" do
    html =
      render_component(&ArrayField.array_field/1,
        field: parsed_field(%{"type" => "string"}),
        value: ["a"],
        path: "doc[labels]"
      )

    assert html =~ ~r{<input[^>]*type="text"}
    refute html =~ "bp-reference-picker"
  end
end
