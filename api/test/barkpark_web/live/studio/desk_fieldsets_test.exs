defmodule BarkparkWeb.Studio.DeskFieldsetsTest do
  @moduledoc """
  WP2 PR 3: the desk draws a schema's fieldsets, and a fieldset or an object
  with `options.collapsible` / `options.collapsed` folds (`Desk.Fieldsets`).

  Folding is the browser's own state (a LiveView JS command on the title
  button), so these tests read what the server draws: the fold's start state,
  the button, and that a folded fieldset's inputs are still in the form.

  The round trip: a document with a value in every fieldset and object,
  folded ones included. One field is edited; every other stored value is the
  same afterwards.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.Desk.Fieldsets

  @dataset "production"
  @pane "[data-pane-editing]"
  @form "#{@pane} #editor-form"

  @fieldsets [
    %{"name" => "size", "title" => "Size", "options" => %{"columns" => 2}},
    %{
      "name" => "more",
      "title" => "More",
      "options" => %{"collapsible" => true, "collapsed" => true}
    },
    %{
      "name" => "where",
      "title" => "Where",
      "options" => %{"collapsible" => true, "collapsed" => false}
    },
    %{"name" => "quiet", "title" => "Quiet"}
  ]

  @agreed %{"field" => "agree", "operator" => "eq", "value" => true}

  @fields [
    %{"name" => "title", "title" => "Title", "type" => "string"},
    %{"name" => "width", "title" => "Width", "type" => "number", "fieldset" => "size"},
    %{"name" => "note", "title" => "Note", "type" => "string"},
    %{"name" => "height", "title" => "Height", "type" => "number", "fieldset" => "size"},
    %{"name" => "limit", "title" => "Limit", "type" => "number", "fieldset" => "more"},
    %{"name" => "agree", "title" => "Agree", "type" => "boolean", "fieldset" => "more"},
    %{"name" => "body", "title" => "Body", "type" => "text", "fieldset" => "more"},
    %{"name" => "city", "title" => "City", "type" => "string", "fieldset" => "where"},
    %{
      "name" => "hush",
      "title" => "Hush",
      "type" => "string",
      "fieldset" => "quiet",
      "visibleWhen" => @agreed
    },
    %{"name" => "stray", "title" => "Stray", "type" => "string", "fieldset" => "undeclared"},
    %{
      "name" => "seo",
      "title" => "SEO",
      "type" => "composite",
      "options" => %{"collapsible" => true, "collapsed" => true},
      "fields" => [
        %{"name" => "metaTitle", "title" => "Meta title", "type" => "string"},
        %{"name" => "noIndex", "title" => "No index", "type" => "boolean"}
      ]
    },
    %{
      "name" => "cta",
      "title" => "Call to action",
      "type" => "composite",
      "fields" => [%{"name" => "label", "title" => "Label", "type" => "string"}]
    }
  ]

  # `note` is left out: an absent field must stay absent.
  @content %{
    "width" => 0,
    "height" => 20,
    "limit" => 99,
    "agree" => false,
    "body" => "Two\nlines",
    "city" => "Oslo",
    "hush" => "Kept while hidden",
    "stray" => "Alone",
    "seo" => %{"metaTitle" => "Meta", "noIndex" => false},
    "cta" => %{"label" => "Go"}
  }

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-fieldsets-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-fieldsets", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    type = "fsets_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Fieldsets #{n}",
          "visibility" => "public",
          "fieldsets" => @fieldsets,
          "fields" => @fields
        },
        @dataset
      )

    id = "fsets-#{n}"
    attrs = Map.merge(@content, %{"doc_id" => id, "title" => "Sets"})
    {:ok, _} = Content.create_document(type, attrs, @dataset)
    {:ok, stored} = Content.get_document("drafts." <> id, type, @dataset)
    scope = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"
    {:ok, conn: conn, type: type, id: id, stored: stored.content, scope: scope}
  end

  defp open(c, path, form) do
    {:ok, view, _html} = live(c.conn, path)
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, form) end)
    view
  end

  defp desk(c), do: open(c, "#{c.scope}/_desk/#{c.type};#{c.id}", @form)

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp change(view, changes) do
    view |> element(@form) |> render_change(%{"doc" => changes})
    render_async(view, 5_000)
  end

  defp draft(c) do
    {:ok, doc} = Content.get_document("drafts." <> c.id, c.type, @dataset)
    doc.content
  end

  defp saved?(c, key, value), do: eventually(fn -> Map.get(draft(c), key) == value end)

  defp set(name), do: ~s(#{@form} fieldset.fieldset-group[data-fieldset="#{name}"])

  test "fields that name a fieldset are drawn inside it, where the first stood", c do
    view = desk(c)

    assert has_element?(view, ~s|#{set("size")}:not([data-collapsible]) > legend|, "Size")
    assert has_element?(view, ~s(#{set("size")} > .fieldset[style*="repeat(2,"] [id="width"]))
    assert has_element?(view, ~s(#{set("size")} > .fieldset [id="height"]))
    refute has_element?(view, ~s(#{set("size")} > legend button))

    html = view |> element(@form) |> render()
    at = fn needle -> html |> :binary.match(needle) |> elem(0) end
    assert at.(~s(data-fieldset="size")) < at.(~s(id="width"))
    assert at.(~s(id="height")) < at.(~s(id="note"))
    assert at.(~s(id="note")) < at.(~s(data-fieldset="more"))
  end

  test "a collapsed fieldset starts shut, a collapsible one open; both keep their inputs", c do
    view = desk(c)

    more = set("more") <> ~s([data-collapsible][data-open="false"])

    assert has_element?(
             view,
             ~s(#{more} > legend > button.object-toggle[aria-expanded="false"]),
             "More"
           )

    for name <- ~w(limit agree body) do
      assert has_element?(view, ~s(#{more} > .fieldset [name="doc[#{name}]"])),
             "#{name} left the form"
    end

    where = set("where") <> ~s([data-collapsible][data-open="true"])

    assert has_element?(
             view,
             ~s(#{where} > legend > button.object-toggle[aria-expanded="true"]),
             "Where"
           )

    assert has_element?(view, ~s(#{where} [id="city"]))

    toggle = view |> element(~s(#{more} button.object-toggle)) |> render()
    assert toggle =~ "toggle_attr"
    assert toggle =~ "data-open"
    refute toggle =~ "push"
  end

  test "a fieldset with no shown field is not drawn; an undeclared one is a lone field", c do
    view = desk(c)

    refute has_element?(view, set("quiet"))
    refute has_element?(view, set("undeclared"))
    assert has_element?(view, ~s(#{@form} > .editor-field [id="stray"]))

    change(view, %{"agree" => "true"})
    assert saved?(c, "agree", true)
    assert has_element?(view, ~s(#{set("quiet")} [id="hush"][value="Kept while hidden"]))
  end

  test "an object with options.collapsed folds; one without does not", c do
    view = desk(c)

    seo = ~s(#{@form} fieldset.bp-field-composite[data-field-name="seo"])
    assert has_element?(view, ~s(#{seo}[data-collapsible][data-open="false"]))

    assert has_element?(
             view,
             ~s(#{seo} > legend > button.object-toggle[aria-expanded="false"]),
             "SEO"
           )

    assert has_element?(view, ~s(#{seo} [id="seo.metaTitle"][value="Meta"]))

    cta = ~s(#{@form} fieldset.bp-field-composite[data-field-name="cta"])

    assert has_element?(
             view,
             ~s|#{cta}:not([data-collapsible]):not([data-open]) > legend|,
             "Call to action"
           )

    refute has_element?(view, ~s(#{cta} button.object-toggle))
  end

  test "the desk sheet stops drawing a shut fieldset's fields, and nothing else" do
    css = rendered_to_string(BarkparkWeb.Studio.Desk.DocStyle.sheet(%{}))
    assert css =~ ~s|.dk .dk-edit fieldset[data-open="false"] > :not(legend) { display: none; }|
    refute Fieldsets.css() =~ "hidden"
  end

  # Control: the old Studio draws no fieldsets and no fold.
  test "the old Studio draws every field on its own", c do
    view = open(c, "#{c.scope}/#{c.type}/#{c.id}", "#editor-form")

    refute has_element?(view, "#editor-form fieldset.fieldset-group")
    refute has_element?(view, "#editor-form .object-toggle")
    refute has_element?(view, "#editor-form [data-collapsible]")

    for name <- ~w(width note height limit agree body city stray) do
      assert has_element?(view, ~s(#editor-form [name="doc[#{name}]"])), "no input for #{name}"
    end
  end

  test "Fieldsets.entries/2" do
    f = fn name, set -> %{"name" => name, "fieldset" => set} end
    sets = [%{"name" => "a"}, %{"name" => "b"}]
    fields = [f.("1", nil), f.("2", "a"), f.("3", "b"), f.("4", "a"), f.("5", "zz"), f.("6", "b")]

    assert [
             {:field, %{"name" => "1"}},
             {:set, %{"name" => "a"}, [%{"name" => "2"}, %{"name" => "4"}]},
             {:set, %{"name" => "b"}, [%{"name" => "3"}, %{"name" => "6"}]},
             {:field, %{"name" => "5"}}
           ] = Fieldsets.entries(fields, sets)

    assert Fieldsets.entries(fields, []) == Enum.map(fields, &{:field, &1})
    assert Fieldsets.entries(fields, nil) == Enum.map(fields, &{:field, &1})
    assert Fieldsets.of(%{fieldsets: sets}, false) == []
    assert Fieldsets.of(%{fieldsets: [%{"title" => "No name"} | sets]}, true) == sets
    assert Fieldsets.folds?(%{"collapsed" => true})
    refute Fieldsets.folds?(%{"columns" => 2})
    refute Fieldsets.open?(%{"collapsible" => true, "collapsed" => true})
    assert Fieldsets.open?(%{"collapsible" => true})
  end

  describe "stored-row round trip" do
    test "one field edited: folded fieldsets and objects keep every stored value", c do
      assert c.stored["agree"] == false
      assert c.stored["width"] == 0
      refute Map.has_key?(c.stored, "note")
      view = desk(c)

      change(view, %{"city" => "Bergen"})
      assert saved?(c, "city", "Bergen")
      assert draft(c) == Map.put(c.stored, "city", "Bergen")
    end

    test "a field in a shut fieldset edited, the condition flipped on and off", c do
      view = desk(c)

      change(view, %{"limit" => "7"})
      assert saved?(c, "limit", 7)
      assert draft(c) == Map.put(c.stored, "limit", 7)

      change(view, %{"agree" => "true"})
      assert saved?(c, "agree", true)
      assert draft(c) == Map.merge(c.stored, %{"limit" => 7, "agree" => true})

      change(view, %{"agree" => "false"})
      assert saved?(c, "agree", false)
      assert draft(c) == Map.put(c.stored, "limit", 7)

      view |> form(@form, %{"doc[seo].metaTitle" => "Better"}) |> render_change()
      render_async(view, 5_000)
      assert eventually(fn -> get_in(draft(c), ["seo", "metaTitle"]) == "Better" end)

      assert draft(c) ==
               Map.merge(c.stored, %{
                 "limit" => 7,
                 "seo" => %{"metaTitle" => "Better", "noIndex" => false}
               })
    end
  end
end
