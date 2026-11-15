defmodule BarkparkWeb.Studio.DeskGroupTabsShownTest do
  @moduledoc """
  WP2 PR 1: the desk draws a group's tab only while one of its fields shows
  (the TanStack Studio's `groupShows`, Sanity's `visibleGroups`), and a
  date-time field's id is on the picker the editor sees, not on the hidden
  input that carries the value.

  The round trip: a document with a value in every group, hidden fields
  included. Tabs are picked, the condition is flipped, one field is edited;
  every other stored value is the same afterwards.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.Desk.FieldGroups

  @dataset "production"
  @pane "[data-pane-editing]"
  @form "#{@pane} #editor-form"

  @featured %{"field" => "featured", "operator" => "eq", "value" => true}

  @groups [
    %{"name" => "content", "title" => "Content", "default" => true},
    %{"name" => "meta", "title" => "Meta"},
    %{"name" => "promo", "title" => "Promotion"}
  ]

  @fields [
    %{"name" => "title", "title" => "Title", "type" => "string", "group" => "content"},
    %{"name" => "excerpt", "title" => "Excerpt", "type" => "text", "group" => "content"},
    %{"name" => "subtitle", "title" => "Subtitle", "type" => "string", "group" => "content"},
    %{"name" => "stage", "title" => "Stage", "type" => "string", "group" => "meta"},
    %{
      "name" => "publishedAt",
      "title" => "Published at",
      "type" => "datetime",
      "group" => "meta"
    },
    %{"name" => "featured", "title" => "Featured", "type" => "boolean", "group" => "meta"},
    %{"name" => "archived", "title" => "Archived", "type" => "boolean", "group" => "meta"},
    %{"name" => "rating", "title" => "Rating", "type" => "number", "group" => "meta"},
    %{
      "name" => "featuredNote",
      "title" => "Featured note",
      "type" => "string",
      "group" => "meta",
      "visibleWhen" => @featured
    },
    %{
      "name" => "tags",
      "title" => "Tags",
      "type" => "arrayOf",
      "ordered" => true,
      "group" => "meta",
      "of" => %{"type" => "string"}
    },
    %{
      "name" => "seo",
      "title" => "SEO",
      "type" => "composite",
      "group" => "meta",
      "fields" => [
        %{"name" => "metaTitle", "title" => "Meta title", "type" => "string"},
        %{"name" => "noIndex", "title" => "No index", "type" => "boolean"}
      ]
    },
    %{
      "name" => "promoLine",
      "title" => "Promo line",
      "type" => "string",
      "group" => "promo",
      "visibleWhen" => @featured
    },
    %{"name" => "legacy", "title" => "Legacy", "type" => "string"}
  ]

  # `subtitle` is left out: an absent field must stay absent.
  @content %{
    "excerpt" => "Short",
    "stage" => "review",
    "publishedAt" => "2026-09-19T09:00:00Z",
    "archived" => false,
    "rating" => 0,
    "featuredNote" => "In the newsletter.",
    "tags" => ["one", "two"],
    "seo" => %{"metaTitle" => "Meta", "noIndex" => false},
    "promoLine" => "Half price",
    "legacy" => "Old"
  }

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-group-tabs-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-group-tabs", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    type = "gtabs_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Group tabs #{n}",
          "visibility" => "public",
          "groups" => @groups,
          "fields" => @fields
        },
        @dataset
      )

    scope = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"
    {:ok, conn: conn, n: n, type: type, scope: scope}
  end

  defp doc!(c, featured) do
    id = "gtabs-#{c.n}-#{featured}"
    attrs = Map.merge(@content, %{"doc_id" => id, "title" => "Grouped", "featured" => featured})
    {:ok, _} = Content.create_document(c.type, attrs, @dataset)
    {:ok, stored} = Content.get_document("drafts." <> id, c.type, @dataset)
    {id, stored.content}
  end

  defp open(c, path) do
    {:ok, view, _html} = live(c.conn, path)
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, @form) end)
    view
  end

  defp desk(c, id), do: open(c, "#{c.scope}/_desk/#{c.type};#{id}")

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp tabs(view) do
    view
    |> element("#{@pane} .bp-tab-bar")
    |> render()
    |> then(&Regex.scan(~r/<span class="bp-tab-label">([^<]*)<\/span>/, &1))
    |> Enum.map(fn [_, t] -> String.trim(t) end)
  end

  defp pick(view, group), do: view |> element("#{@pane} #bp-group-tab-#{group}") |> render_click()

  # What the browser posts: every input the form shows, plus `changes`.
  defp change(view, changes) do
    view |> element(@form) |> render_change(%{"doc" => changes})
    render_async(view, 5_000)
  end

  defp draft(c, id) do
    {:ok, doc} = Content.get_document("drafts." <> id, c.type, @dataset)
    doc.content
  end

  defp saved?(c, id, key, value),
    do: eventually(fn -> Map.get(draft(c, id), key) == value end)

  test "a group whose fields are all hidden has no tab until one shows", c do
    {id, _stored} = doc!(c, false)
    view = desk(c, id)

    assert tabs(view) == ["All fields", "Content", "Meta"]
    refute has_element?(view, "#{@pane} #bp-group-tab-promo")

    pick(view, "meta")
    refute has_element?(view, ~s(#{@form} [name="doc[featuredNote]"]))
    change(view, %{"featured" => "true"})
    assert saved?(c, id, "featured", true)

    assert tabs(view) == ["All fields", "Content", "Meta", "Promotion"]
    assert has_element?(view, ~s(#{@form} [name="doc[featuredNote]"][value="In the newsletter."]))

    pick(view, "promo")
    assert has_element?(view, ~s(#{@pane} #bp-group-tab-promo[aria-selected="true"]))
    assert has_element?(view, ~s(#{@form} [name="doc[promoLine]"][value="Half price"]))
  end

  test "the chosen group's tab going away leaves All fields, not an empty form", c do
    {id, _stored} = doc!(c, true)
    view = desk(c, id)

    pick(view, "promo")
    assert has_element?(view, ~s(#{@form} [name="doc[promoLine]"]))

    change(view, %{"featured" => "false"})
    assert saved?(c, id, "featured", false)

    refute has_element?(view, "#{@pane} #bp-group-tab-promo")
    assert has_element?(view, ~s(#{@pane} #bp-group-tab-all-fields[aria-selected="true"]))
    assert has_element?(view, ~s(#{@form} [name="doc[excerpt]"]))
    refute has_element?(view, ~s(#{@form} [name="doc[promoLine]"]))
  end

  test "FieldGroups: a list of groups, and no schema", _c do
    schema = %{
      groups: [%{"name" => "a"}, %{"name" => "b"}, %{"name" => "c"}],
      fields: [
        %{"name" => "x", "group" => ["a", "b"]},
        %{"name" => "y", "group" => "c", "visibleWhen" => @featured}
      ]
    }

    assert Enum.map(FieldGroups.shown(schema, %{}), & &1["name"]) == ~w(a b)
    assert Enum.map(FieldGroups.shown(schema, %{"featured" => true}), & &1["name"]) == ~w(a b c)
    assert FieldGroups.current(schema, "c", %{}) == nil
    assert FieldGroups.current(schema, "b", nil) == "b"
    assert FieldGroups.current(schema, nil, %{}) == nil
    assert FieldGroups.shown(nil, nil) == []
  end

  test "a date-time field's id is on the picker; the hidden input keeps the name", c do
    {id, _stored} = doc!(c, false)
    view = desk(c, id)
    pick(view, "meta")

    assert has_element?(view, ~s(#{@form} input[type="datetime-local"][id="publishedAt"]))
    assert has_element?(view, ~s(#{@form} .field label[for="publishedAt"]))

    assert has_element?(
             view,
             ~s|#{@form} input[type="hidden"][name="doc[publishedAt]"][value="2026-09-19T09:00:00Z"]:not([id])|
           )
  end

  # Control: the old Studio draws every declared group. The id on the picker
  # is a plain fix (a label's `for` at a hidden input), so it gets that too.
  test "the old Studio: every declared group keeps its tab; the picker has the id", c do
    {id, _stored} = doc!(c, false)
    {:ok, view, _html} = live(c.conn, "#{c.scope}/#{c.type}/#{id}")
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#editor-form") end)

    for g <- ~w(content meta promo), do: assert(has_element?(view, "#bp-group-tab-#{g}"))
    refute has_element?(view, "#bp-group-tab-all-fields")

    view |> element("#bp-group-tab-meta") |> render_click()
    picker = ~s(input[type="datetime-local"][id="doc-field-#{id}-publishedAt"])
    assert has_element?(view, "#editor-form " <> picker)
    assert has_element?(view, ~s(#editor-form label[for="doc-field-#{id}-publishedAt"]))
    refute has_element?(view, ~s(#editor-form input[type="hidden"][id$="-publishedAt"]))
  end

  describe "stored-row round trip" do
    # Featured off: featuredNote and promoLine hold values and are hidden, and
    # the Promotion tab is not drawn.
    test "tabs picked, one field edited: every other stored value is the same", c do
      {id, stored} = doc!(c, false)
      assert stored["featured"] == false
      assert stored["archived"] == false
      refute Map.has_key?(stored, "subtitle")
      view = desk(c, id)

      pick(view, "meta")
      pick(view, "all-fields")
      pick(view, "content")
      change(view, %{"excerpt" => "Longer"})
      assert saved?(c, id, "excerpt", "Longer")
      assert draft(c, id) == Map.put(stored, "excerpt", "Longer")

      pick(view, "meta")
      change(view, %{"stage" => "done"})
      assert saved?(c, id, "stage", "done")
      assert draft(c, id) == Map.merge(stored, %{"excerpt" => "Longer", "stage" => "done"})
    end

    test "the condition flipped on and off: hidden fields keep their values", c do
      {id, stored} = doc!(c, true)
      view = desk(c, id)

      pick(view, "meta")
      change(view, %{"featured" => "false"})
      assert saved?(c, id, "featured", false)
      assert draft(c, id) == Map.put(stored, "featured", false)

      # Hidden now; an edit on the same tab posts neither of them.
      refute has_element?(view, ~s(#{@form} [name="doc[featuredNote]"]))
      change(view, %{"stage" => "done"})
      assert saved?(c, id, "stage", "done")
      assert draft(c, id) == Map.merge(stored, %{"featured" => false, "stage" => "done"})

      change(view, %{"featured" => "true"})
      assert saved?(c, id, "featured", true)
      assert draft(c, id) == Map.put(stored, "stage", "done")

      pick(view, "promo")
      change(view, %{"promoLine" => "Full price"})
      assert saved?(c, id, "promoLine", "Full price")
      assert draft(c, id) == Map.merge(stored, %{"stage" => "done", "promoLine" => "Full price"})
    end
  end
end
