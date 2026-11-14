defmodule BarkparkWeb.Studio.DeskFieldSlotsTest do
  @moduledoc """
  Every field of the desk's form holds the TanStack Studio's two places
  (`Fields.tsx`): `.field > .field-actions` with a button named "Field
  actions", and `.field > .change-bar`. Neither does anything yet
  (`Desk.FieldSlots`). An array of any kind has an element named by its
  path inside its `.field`. The old Studio's form has none of it.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @form "[data-pane-editing] #editor-form"
  @button ~s(button[type="button"][aria-label="Field actions"][disabled])

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "slots_#{n}"
    f = fn name, t, extra -> Map.merge(%{"name" => name, "title" => name, "type" => t}, extra) end

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Slots #{type}",
          "visibility" => "public",
          "fields" => [
            f.("title", "string", %{}),
            f.("excerpt", "text", %{}),
            f.("cover", "image", %{}),
            f.("tags", "arrayOf", %{"of" => [%{"type" => "string"}]}),
            f.("links", "arrayOf", %{
              "of" => [
                %{"type" => "composite", "fields" => [%{"name" => "title", "type" => "string"}]}
              ]
            }),
            f.("categories", "arrayOf", %{"of" => [%{"type" => "reference", "refType" => type}]}),
            # One member, not a list: an array of options is a box of checkboxes.
            f.("picks", "arrayOf", %{"of" => %{"type" => "select", "options" => ["red", "green"]}}),
            f.("cta", "composite", %{"fields" => [%{"name" => "url", "type" => "string"}]}),
            f.("blurb", "localizedText", %{"languages" => ["nob", "eng"]})
          ]
        },
        @dataset
      )

    id = "slots-#{n}"

    {:ok, _} =
      Content.create_document(
        type,
        %{"doc_id" => id, "title" => "Here", "tags" => ["a"], "picks" => ["red"]},
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-slots-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-slots", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    root = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok, conn: conn, desk: "#{root}/_desk/#{type};#{id}", studio: "#{root}/#{type}/#{id}"}
  end

  defp desk(c) do
    {:ok, view, _html} = live(c.conn, c.desk)
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, @form) end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp count(html, class),
    do: length(Regex.scan(~r/<[a-z]+[^>]*\sclass="#{class}["\s]/, html))

  test "every field holds the Field actions button and the change bar's place", c do
    view = desk(c)
    html = view |> element(@form) |> render()
    fields = length(Regex.scan(~r/<(?:div|fieldset)[^>]*\sclass="editor-field field[\s"]/, html))

    # title, excerpt, cover, tags, links, categories, picks, cta, blurb.
    assert fields == 9
    assert count(html, "field-actions") == fields
    assert count(html, "change-bar") == fields

    for path <- ~w(title excerpt cover tags links categories picks cta.url blurb.nob) do
      field = ~s|#{@form} .field:has([id="#{path}"])|
      assert has_element?(view, ~s(#{field} > .field-actions > #{@button})), path
      assert has_element?(view, ~s(#{field} > span.change-bar[hidden])), path
    end
  end

  test "the button is named, opens nothing and is out of the tab order", c do
    view = desk(c)
    actions = ~s|#{@form} .field:has([id="title"]) > .field-actions|
    html = view |> element(actions) |> render()

    assert html =~ ~s(aria-label="Field actions")
    assert html =~ ~r/<button[^>]*\sdisabled/
    refute html =~ "phx-click"
    refute html =~ "tabindex"
    refute html =~ "aria-haspopup"

    assert BarkparkWeb.Studio.Desk.Style.sheet(%{}) |> rendered_to_string() =~
             ".dk .field > .field-actions { position: absolute; opacity: 0; pointer-events: none; }"
  end

  test "an array of any kind has an element named by its path; its fieldset keeps bp-array-", c do
    view = desk(c)

    for name <- ~w(tags links categories) do
      assert has_element?(view, ~s(#{@form} .field ol.bp-array-rows[id="#{name}"])), name
    end

    assert has_element?(view, ~s(#{@form} .field div.bp-select-list-options[id="picks"]))
    assert has_element?(view, ~s(#{@form} [id="picks"] input[type="checkbox"][value="red"]))

    for name <- ~w(tags links categories picks) do
      assert has_element?(
               view,
               ~s(#{@form} fieldset[id^="bp-array-"][data-field-name="#{name}"])
             ),
             name
    end

    ids = for [_, id] <- Regex.scan(~r/\sid="([^"]+)"/, render(view)), do: id
    assert ids |> Enum.frequencies() |> Enum.filter(fn {_id, n} -> n > 1 end) == []
  end

  test "the old Studio's form has none of it", c do
    {:ok, view, _html} = live(c.conn, c.studio)
    form = view |> element("#editor-form") |> render()

    assert form =~ ~s(class="editor-field field)
    refute form =~ "field-actions"
    refute form =~ "change-bar"
    refute form =~ "Field actions"
    refute form =~ ~r/\sid="(tags|links|categories|picks)"/
    assert form =~ ~s(class="bp-select-list-options")
  end

  test "the shared field wrapper draws neither unless asked (the plugin editors' call)" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <BarkparkWeb.StudioComponents.editor_field label="Name" for="x">
        <input id="x" />
      </BarkparkWeb.StudioComponents.editor_field>
      """)

    refute html =~ "field-actions"
    refute html =~ "change-bar"

    assert html |> String.replace(~r/\s+/, " ") =~
             ~s(Name </label> <input id="x">)
  end
end
