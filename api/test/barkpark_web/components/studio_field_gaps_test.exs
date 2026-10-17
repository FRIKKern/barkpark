defmodule BarkparkWeb.Components.StudioFieldGapsTest do
  @moduledoc """
  Three Studio field gaps the gyldendal.no twin's parity audit found
  (docs/studio-parity.md in FRIKKern/gyldendal-no-barkpark, 2026-10-16).

    * task-cf45242ef3477fba: event 2026-10-29T14:00:00Z showed an empty
      date-time picker. The hook filled the nameless picker, then the next
      LiveView patch reset it to "" because it has no `value` attribute.
      `date` fields fell through to a text box.
    * task-b8bce68623e758ae: an array of select values drew one text box per
      stored code ("article", "page") instead of Sanity's checkbox list.
    * task-7ea6f41cede5ee97: an image in Sanity's `{asset: {_ref}}` shape drew
      "No image selected". Server half here: the picker gets the attributes it
      needs; the node test `__picker_asset_ref.test.mjs` covers the element.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias BarkparkWeb.Components.FieldInputs
  alias BarkparkWeb.Components.Fields.{ArrayField, CompositeField}
  alias Barkpark.Content.SchemaDefinition

  defp find(doc, sel), do: doc |> LazyHTML.query(sel) |> Enum.to_list()

  defp attr(nodes, name) when is_list(nodes),
    do: Enum.flat_map(nodes, &LazyHTML.attribute(&1, name))

  defp attr(node, name), do: LazyHTML.attribute(node, name)

  defp parse_field(raw) do
    {:ok, schema} =
      SchemaDefinition.parse(%{"name" => "t", "version" => 2, "fields" => [raw]})

    hd(schema.fields)
  end

  describe "datetime (task-cf45242ef3477fba)" do
    test "the picker sits in a phx-update=ignore span, and the wrapper carries the value" do
      html =
        render_component(&FieldInputs.input/1, %{
          field: %{"type" => "datetime", "name" => "date", "title" => "Arrangementsdato"},
          editor_form: %{"date" => "2026-10-29T14:00:00Z"}
        })

      [wrapper] = find(LazyHTML.from_fragment(html), "[phx-hook=BarkparkDatetimeField]")
      assert attr(wrapper, "data-value") == ["2026-10-29T14:00:00Z"]

      [ignored] = find(wrapper, "[phx-update=ignore]")
      assert attr(ignored, "id") != []
      assert [_picker] = find(ignored, "input[type=datetime-local]")

      assert find(wrapper, "input[type=hidden][name='doc[date]']")
             |> attr("value") == ["2026-10-29T14:00:00Z"]
    end

    test "a composite datetime subfield has the same shape" do
      field =
        parse_field(%{
          "name" => "occurrence",
          "type" => "composite",
          "fields" => [%{"name" => "start", "type" => "datetime"}]
        })

      html =
        render_component(&CompositeField.composite_field/1, %{
          field: field,
          value: %{"start" => "2026-10-29T14:00:00.000Z"},
          path: "doc[occurrence]"
        })

      [wrapper] = find(LazyHTML.from_fragment(html), "[phx-hook=BarkparkDatetimeField]")
      assert attr(wrapper, "data-value") == ["2026-10-29T14:00:00.000Z"]
      assert [_] = find(wrapper, "[phx-update=ignore] input[type=datetime-local]")
    end

    test "a date field is a date picker on the stored day" do
      html =
        render_component(&FieldInputs.input/1, %{
          field: %{"type" => "date", "name" => "publishedAt", "title" => "Publisert"},
          editor_form: %{"publishedAt" => "2026-10-29"}
        })

      [input] = find(LazyHTML.from_fragment(html), "input[name='doc[publishedAt]']")
      assert attr(input, "type") == ["date"]
      assert attr(input, "value") == ["2026-10-29"]
    end

    test "date_form_value cuts an ISO value to its day and refuses anything else" do
      assert Barkpark.Content.Forms.date_form_value("2026-10-29") == "2026-10-29"
      assert Barkpark.Content.Forms.date_form_value("2026-10-29T14:00:00Z") == "2026-10-29"
      assert Barkpark.Content.Forms.date_form_value("2026-13-40") == ""
      assert Barkpark.Content.Forms.date_form_value("tomorrow") == ""
      assert Barkpark.Content.Forms.date_form_value(nil) == ""
    end
  end

  describe "array of select values (task-b8bce68623e758ae)" do
    @options [
      %{"value" => "article", "title" => "Artikler"},
      %{"value" => "event", "title" => "Arrangementer"},
      %{"value" => "page", "title" => "Innholdssider"}
    ]

    defp select_array(value) do
      field =
        parse_field(%{
          "name" => "newsletterInviteDocumentTypes",
          "type" => "arrayOf",
          "ordered" => true,
          "title" => "Vis på disse sidetypene",
          "of" => %{"type" => "select", "options" => @options}
        })

      render_component(&ArrayField.array_field/1, %{
        field: field,
        value: value,
        path: "doc[newsletterInviteDocumentTypes]"
      })
      |> LazyHTML.from_fragment()
    end

    test "one checkbox per option with its title, in option order, ticked by the value" do
      doc = select_array(["page", "article"])

      labels = find(doc, ".bp-select-list-option")

      assert Enum.map(labels, &(LazyHTML.text(&1) |> String.trim())) ==
               ["Artikler", "Arrangementer", "Innholdssider"]

      boxes = find(doc, "input[type=checkbox]")
      assert attr(boxes, "value") == ["article", "event", "page"]
      assert Enum.map(boxes, &(attr(&1, "checked") != [])) == [true, false, true]

      assert Enum.uniq(attr(boxes, "name")) ==
               ["doc[newsletterInviteDocumentTypes][]"]

      assert find(doc, "input[type=text]") == [], "no free-text rows"
      assert find(doc, ".bp-array-btn") == [], "no add, move or remove buttons"
    end

    test "an empty selection still posts the field, so unticking the last box clears it" do
      doc = select_array([])

      assert [hidden] =
               find(doc, "input[type=hidden][name='doc[newsletterInviteDocumentTypes][]']")

      assert attr(hidden, "value") == [""]
    end

    test "a stored value outside the options shows as invalid, not as free text" do
      doc = select_array(["article", "legacyType"])

      [bad] = find(doc, ".bp-select-list-invalid")
      assert attr(bad, "data-invalid-value") == ["legacyType"]
      assert [box] = find(bad, "input[type=checkbox]")
      assert attr(box, "aria-invalid") == ["true"]
      assert attr(box, "checked") != []
      assert LazyHTML.text(bad) =~ "Not one of the options"
    end

    test "an array of plain strings keeps its text rows" do
      field = parse_field(%{"name" => "tags", "type" => "arrayOf", "of" => %{"type" => "string"}})

      doc =
        render_component(&ArrayField.array_field/1, %{
          field: field,
          value: ["a"],
          path: "doc[tags]"
        })
        |> LazyHTML.from_fragment()

      assert [_] = find(doc, "input[type=text]")
      assert find(doc, "input[type=checkbox]") == []
    end
  end

  describe "Sanity-shaped image (task-7ea6f41cede5ee97)" do
    @value %{
      "_type" => "imageAsset",
      "alt" => "Lærelyst kan læres",
      "asset" => %{
        "_ref" => "image-2c0e969890ba48060d4d04f63bc620a7b3aee181-2048x1366-jpg",
        "_type" => "reference"
      }
    }

    test "the picker gets the stored object, the dataset and the scope" do
      html =
        render_component(&FieldInputs.input/1, %{
          field: %{"type" => "image", "name" => "heroImage", "options" => %{"hotspot" => true}},
          editor_form: %{"heroImage" => @value},
          dataset: "production",
          scope_prefix: "/w/gyldendal-no/p/default"
        })

      [picker] = find(LazyHTML.from_fragment(html), "bp-media-picker")
      assert [json] = attr(picker, "value")
      assert Jason.decode!(json) == @value
      assert attr(picker, "scope-prefix") == ["/w/gyldendal-no/p/default"]
      assert attr(picker, "value-shape") == []
    end

    test "a field declaring valueShape assetRef asks an empty picker for that shape" do
      html =
        render_component(&FieldInputs.input/1, %{
          field: %{"type" => "image", "name" => "heroImage", "valueShape" => "assetRef"},
          editor_form: %{}
        })

      [picker] = find(LazyHTML.from_fragment(html), "bp-media-picker")
      assert attr(picker, "value-shape") == ["asset-ref"]
    end

    test "a composite image subfield gets the dataset and scope its preview needs" do
      field =
        parse_field(%{
          "name" => "seo",
          "type" => "composite",
          "fields" => [
            %{
              "name" => "ogImage",
              "type" => "image",
              "fields" => [%{"name" => "alt", "type" => "string"}]
            }
          ]
        })

      html =
        render_component(&CompositeField.composite_field/1, %{
          field: field,
          value: %{"ogImage" => @value},
          path: "doc[seo]",
          dataset: "production",
          scope_prefix: "/w/gyldendal-no/p/default"
        })

      [picker] = find(LazyHTML.from_fragment(html), "bp-media-picker")
      assert attr(picker, "dataset") == ["production"]
      assert attr(picker, "scope-prefix") == ["/w/gyldendal-no/p/default"]
      assert attr(picker, "alt") != [], "an alt subfield gives the alt box"
    end

    test "an image array row shows the Sanity image as its thumbnail" do
      field =
        parse_field(%{"name" => "gallery", "type" => "arrayOf", "of" => %{"type" => "image"}})

      doc =
        render_component(&ArrayField.array_field/1, %{
          field: field,
          value: [@value],
          path: "doc[gallery]",
          dataset: "production",
          scope_prefix: "/w/gyldendal-no/p/default"
        })
        |> LazyHTML.from_fragment()

      assert find(doc, ".bp-array-item-media img") |> attr("src") == [
               "/w/gyldendal-no/p/default/images/barkpark/production/" <>
                 "2c0e969890ba48060d4d04f63bc620a7b3aee181-2048x1366.jpg?w=120&fit=max"
             ]
    end

    test "sanity_image_url maps only Sanity image ids" do
      assert FieldInputs.sanity_image_url(
               "image-917cdfa94037b90600d868383cd1f27ea690b55b-1000x667-jpg",
               "",
               "production"
             ) ==
               "/images/barkpark/production/917cdfa94037b90600d868383cd1f27ea690b55b-1000x667.jpg"

      assert FieldInputs.sanity_image_url("asset-8aa97e08", "", "production") == nil
      assert FieldInputs.sanity_image_url(nil, "", "production") == nil
    end
  end
end
