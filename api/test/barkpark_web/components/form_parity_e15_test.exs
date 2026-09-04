defmodule BarkparkWeb.Components.FormParityE15Test do
  @moduledoc """
  Gyldendal parity E1.5 — the FORM layer reads like Sanity's for the same
  schema JSON: titled/radio options, descriptions, switch booleans, object
  groups, collapsed array items with previews, no phantom Title on a titleless
  singleton, count-based `visibleWhen`, and default-seeded rows.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Barkpark.Content.FieldVisibility
  alias Barkpark.Content.SchemaDefinition.Field
  alias Barkpark.Content.SelectOptions
  alias BarkparkWeb.Components.FieldInputs
  alias BarkparkWeb.Components.Fields.{ArrayField, CompositeField}
  alias BarkparkWeb.Studio.StudioLive.Path
  alias BarkparkWeb.StudioComponents

  describe "SelectOptions" do
    test "bare values, {value,title} and legacy {value,label} all normalise; title wins" do
      assert [%{value: "a", label: "a"}] = SelectOptions.normalize(["a"])

      assert [%{value: "equal", label: "Lik bredde"}] =
               SelectOptions.normalize([%{"value" => "equal", "title" => "Lik bredde"}])

      assert [%{value: "x", label: "Legacy"}] =
               SelectOptions.normalize([%{"value" => "x", "label" => "Legacy"}])

      assert SelectOptions.values([%{"value" => "a", "title" => "A"}, "b"]) == ["a", "b"]
    end

    test "radio? reads layout from a raw map or a Field struct" do
      assert SelectOptions.radio?(%{"layout" => "radio"})
      assert SelectOptions.radio?(%Field{type: "select", raw: %{"layout" => "radio"}})
      refute SelectOptions.radio?(%{"type" => "select"})
    end
  end

  describe "top-level select" do
    test "shows the option TITLE and stores the VALUE" do
      html =
        render_component(&FieldInputs.input/1, %{
          field: %{
            "type" => "select",
            "name" => "bannersLayout",
            "options" => [
              %{"value" => "equal", "title" => "Lik bredde"},
              %{"value" => "left-larger", "title" => "Venstre kort større"}
            ]
          },
          editor_form: %{"bannersLayout" => "left-larger"}
        })

      assert html =~ ~s(<option value="equal">Lik bredde</option>)
      assert html =~ ~s(<option value="left-larger" selected>Venstre kort større</option>)
      refute html =~ ~s(<option value="" selected>)
    end

    test "layout: radio renders a radio group, the stored value checked, no <select>" do
      html =
        render_component(&FieldInputs.input/1, %{
          field: %{
            "type" => "select",
            "name" => "bannersSize",
            "layout" => "radio",
            "options" => [
              %{"value" => "default", "title" => "Standard (448px)"},
              %{"value" => "hero", "title" => "Hero (550px)"}
            ]
          },
          editor_form: %{"bannersSize" => "hero"}
        })

      assert html =~ ~s(role="radiogroup")
      assert html =~ ~r{<input type="radio" name="doc\[bannersSize\]" value="hero" checked}
      assert html =~ ~r{<input type="radio" name="doc\[bannersSize\]" value="default"[^>]*>}
      refute html =~ ~r{value="default" checked}
      assert html =~ "Standard (448px)"
      refute html =~ "<select"
    end
  end

  describe "editor shell" do
    @form %{"title" => ""}
    defp shell(schema, form \\ @form) do
      render_component(&StudioComponents.studio_editor_shell/1, %{
        editor_doc: %{doc_id: "frontpage", title: nil, status: "published"},
        editor_schema: schema,
        editor_form: form,
        editor_is_draft: false,
        dataset: "production",
        validation_errors: %{},
        save_status: "",
        presences: [],
        parent_assigns: %{},
        nav_group: nil
      })
    end

    test "a singleton WITHOUT a title field renders no synthetic Title input and the header shows the schema title" do
      schema = %{
        name: "frontpage",
        title: "Forside",
        icon: "home",
        singleton: true,
        fields: [%{"name" => "bannersSize", "type" => "string", "title" => "Kort-størrelse"}]
      }

      html = shell(schema)
      refute html =~ ~s(name="doc[title]")
      assert html =~ ~s(<span class="pane-header-title">Forside</span>)
      refute html =~ "Untitled"
    end

    test "a non-singleton without a title field keeps the Title input (it backs the list rows)" do
      schema = %{
        name: "note",
        title: "Note",
        icon: "file",
        singleton: false,
        fields: [%{"name" => "body", "type" => "text"}]
      }

      html = shell(schema)
      assert html =~ ~s(name="doc[title]")
      assert html =~ "Untitled"
    end

    test "field labels no longer carry the type name; a description renders under the label" do
      schema = %{
        name: "frontpage",
        title: "Forside",
        icon: "home",
        singleton: true,
        fields: [
          %{
            "name" => "bannersLayout",
            "type" => "select",
            "title" => "Layout",
            "options" => ["equal"],
            "description" => "Velg hvordan kortene fordeles."
          }
        ]
      }

      html = shell(schema, %{"bannersLayout" => "equal"})
      refute html =~ ~s(<span class="editor-field-type">select</span>)
      assert html =~ ~s(<p class="editor-field-description">Velg hvordan kortene fordeles.</p>)
    end

    test "group tabs show their text label" do
      schema = %{
        name: "frontpage",
        title: "Forside",
        icon: "home",
        singleton: true,
        groups: [
          %{"name" => "content", "title" => "Innhold"},
          %{"name" => "settings", "title" => "Innstillinger", "icon" => "settings"}
        ],
        fields: [%{"name" => "x", "type" => "string", "group" => "content"}]
      }

      html =
        render_component(&StudioComponents.studio_editor_shell/1, %{
          editor_doc: %{doc_id: "frontpage", title: nil, status: "published"},
          editor_schema: schema,
          editor_form: %{},
          editor_is_draft: false,
          dataset: "production",
          validation_errors: %{},
          save_status: "",
          presences: [],
          parent_assigns: %{},
          nav_group: "content"
        })

      assert html =~ ~s(<span class="bp-tab-label">Innhold</span>)
      assert html =~ ~s(<span class="bp-tab-label">Innstillinger</span>)
      # the icon-bearing group still draws its icon before the label
      assert html =~ ~r{phx-value-group="settings"[^>]*>\s*<span class="bp-tab-icon"}
    end
  end

  describe "composite" do
    defp card_field do
      %Field{
        name: "card",
        type: "composite",
        title: "Feature-kort",
        raw: %{
          "description" => "Kort med bakgrunnsbilde og handlingsknapp.",
          "groups" => [
            %{"name" => "link", "title" => "1. Lenke", "default" => true},
            %{"name" => "content", "title" => "2. Innhold"}
          ]
        },
        fields: [
          %Field{
            name: "linkType",
            type: "select",
            title: "Hva vil du lenke til?",
            options: [
              %{"value" => "document", "title" => "🔗 Dokument"},
              %{"value" => "url", "title" => "✏️ Manuell URL"}
            ],
            raw: %{
              "layout" => "radio",
              "group" => "link",
              "description" => "Velg Dokument for auto-fyll."
            }
          },
          %Field{name: "title", type: "string", title: "Tittel", raw: %{"group" => "content"}},
          %Field{name: "blur", type: "boolean", title: "Uskarpt", raw: %{"group" => "content"}}
        ]
      }
    end

    test "boolean subfield renders the labeled switch, not a bare .bp-input checkbox" do
      html =
        render_component(&CompositeField.composite_field/1, %{
          field: card_field(),
          value: %{"blur" => true}
        })

      assert html =~ ~s(class="form-switch bp-input-checkbox")
      assert html =~ ~s(class="form-switch-track")
      refute html =~ ~r{<input\s+type="checkbox"\s+class="bp-input"}
      assert html =~ ">On<"
    end

    test "select subfield with layout: radio renders radios with the option titles" do
      html =
        render_component(&CompositeField.composite_field/1, %{
          field: card_field(),
          value: %{"linkType" => "url"}
        })

      assert html =~ ~s(role="radiogroup")
      assert html =~ ~r{<input\s+type="radio"\s+name="linkType"\s+value="url"\s+checked}
      assert html =~ "✏️ Manuell URL"
      refute html =~ ~s(<option value="url")
    end

    test "descriptions render for the composite and its subfields" do
      html =
        render_component(&CompositeField.composite_field/1, %{field: card_field(), value: %{}})

      assert html =~
               ~s(<p class="bp-field-description">Kort med bakgrunnsbilde og handlingsknapp.</p>)

      assert html =~ ~s(<p class="bp-field-description">Velg Dokument for auto-fyll.</p>)
    end

    test "groups render a tab strip (default group selected) and each subfield carries its data-group" do
      html =
        render_component(&CompositeField.composite_field/1, %{field: card_field(), value: %{}})

      assert html =~ ~s(phx-hook="BarkparkFieldGroups")
      assert html =~ ~s(data-default-group="link")

      assert html =~
               ~r{<button[^>]*class="bp-obj-tab"[^>]*data-group="link"[^>]*aria-selected="true"[^>]*>1\. Lenke</button>}

      assert html =~
               ~r{<button[^>]*data-group="content"[^>]*aria-selected="false"[^>]*>2\. Innhold</button>}

      assert html =~ ~r{<div class="bp-subfield" data-subfield-name="title" data-group="content">}
    end

    test "a composite without groups renders no tab strip and no hook (byte-compat)" do
      field = %Field{
        name: "addr",
        type: "composite",
        fields: [%Field{name: "street", type: "string"}]
      }

      html = render_component(&CompositeField.composite_field/1, %{field: field, value: %{}})
      refute html =~ "bp-obj-tabs"
      refute html =~ "BarkparkFieldGroups"
      refute html =~ "bp-field-description"
    end

    test "bare: true renders only the body — no fieldset/details frame" do
      html =
        render_component(&CompositeField.composite_field/1, %{
          field: card_field(),
          value: %{},
          bare: true
        })

      refute html =~ "<fieldset"
      refute html =~ "<legend"
      assert html =~ ~s(class="bp-field-body")
    end
  end

  describe "arrayOf composite rows" do
    defp banners_field do
      %Field{
        name: "banners",
        type: "arrayOf",
        title: "Toppbannere",
        ordered: true,
        raw: %{"description" => "Maks 3 kort."},
        of: %Field{
          name: "banner",
          type: "composite",
          title: "Feature-kort",
          raw: %{
            "preview" => %{
              "title" => "title",
              "subtitle" => "buttonHref",
              "media" => "backgroundImage"
            }
          },
          fields: [
            %Field{name: "title", type: "string"},
            %Field{name: "buttonHref", type: "string"},
            %Field{name: "backgroundImage", type: "image", raw: %{"hotspot" => true}}
          ]
        }
      }
    end

    test "rows are collapsed <details> items with a preview title/subtitle/thumbnail; an empty row is open" do
      value = [
        %{
          "title" => "Crime from the North",
          "buttonHref" => "/books?category=crime",
          "backgroundImage" => %{"url" => "https://img/x.jpg", "assetId" => "a1"}
        },
        %{}
      ]

      html = render_component(&ArrayField.array_field/1, %{field: banners_field(), value: value})

      assert html =~ ~s(<p class="bp-field-description">Maks 3 kort.</p>)
      assert html =~ ~s(class="bp-array-row bp-array-row-item")

      assert html =~
               ~r{<details class="bp-array-item" id="bp-item-banners-0"[^>]*data-row-index="0"}

      refute html =~ ~r{<details class="bp-array-item" id="bp-item-banners-0"[^>]*\sopen}
      assert html =~ ~s(<span class="bp-array-item-title">Crime from the North</span>)
      assert html =~ ~s(<span class="bp-array-item-subtitle">/books?category=crime</span>)
      assert html =~ ~s(<img src="https://img/x.jpg")
      # the empty second row opens and is named after the element type
      assert html =~ ~r{<details class="bp-array-item" id="bp-item-banners-1" open}
      assert html =~ ~s(<span class="bp-array-item-title">Feature-kort</span>)
      # the composite inside is bare — no nested legend/summary title
      refute html =~ "Banners[item]"
      refute html =~ ~r{<summary class="bp-field-title">}
      # inputs still serialise under the row path
      assert html =~ ~s(name="[0].title")
    end

    test "item_preview falls back to the first non-empty string subfield and a JSON picker value" do
      item = %Field{
        name: "row",
        type: "composite",
        fields: [
          %Field{name: "meta", type: "string"},
          %Field{name: "title", type: "string"},
          %Field{name: "img", type: "image"}
        ]
      }

      p =
        ArrayField.item_preview(item, %{
          "meta" => "",
          "title" => "Hello",
          "img" => ~s({"url":"https://img/y.png","assetId":"z"})
        })

      assert p.title == "Hello"
      assert p.subtitle == nil
      assert p.media == "https://img/y.png"

      assert %{title: "Row"} = ArrayField.item_preview(item, %{})
    end

    test "arrays of scalars keep the plain row (no item frame)" do
      field = %Field{name: "tags", type: "arrayOf", of: %Field{name: "tag", type: "string"}}
      html = render_component(&ArrayField.array_field/1, %{field: field, value: ["a"]})
      refute html =~ "bp-array-item"
      assert html =~ ~s(class="bp-array-row ")
    end
  end

  describe "visibleWhen count operators" do
    test "count_eq / count_neq / count_gt / count_lt over a list, a map and nil" do
      f = fn op, n ->
        %{
          "name" => "bannersLayout",
          "visibleWhen" => %{"field" => "banners", "operator" => op, "value" => n}
        }
      end

      two = %{"banners" => [%{}, %{}]}
      assert FieldVisibility.visible?(f.("count_eq", 2), two)
      refute FieldVisibility.visible?(f.("count_eq", 2), %{"banners" => [%{}]})
      refute FieldVisibility.visible?(f.("count_eq", 2), %{})
      assert FieldVisibility.visible?(f.("count_neq", 2), %{})
      assert FieldVisibility.visible?(f.("count_gt", 1), two)
      assert FieldVisibility.visible?(f.("count_lt", 3), two)
      # index-keyed params shape counts keys
      assert FieldVisibility.visible?(f.("count_eq", 2), %{"banners" => %{"0" => %{}, "1" => %{}}})
    end
  end

  describe "new row seeding" do
    test "empty_for_of seeds each composite subfield's declared default" do
      field = %{
        "of" => %{
          "type" => "composite",
          "fields" => [
            %{"name" => "linkType", "type" => "select", "default" => "document"},
            %{"name" => "title", "type" => "string"},
            %{"name" => "blur", "type" => "boolean", "default" => false}
          ]
        }
      }

      assert %{"linkType" => "document", "title" => nil, "blur" => false} =
               Path.empty_for_of(field)
    end
  end
end
