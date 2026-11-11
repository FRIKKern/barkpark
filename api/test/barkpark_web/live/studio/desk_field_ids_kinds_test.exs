defmodule BarkparkWeb.Studio.DeskFieldIdsKindsTest do
  @moduledoc """
  R19c: the field kinds R19b did not reach. In the desk an object's
  sub-field is named by its dotted path (`cta.kind`), an array's row list by
  the array's path, an image's picker, a block canvas's holder and a
  reference picker's search box by the field's path. The old Studio keeps
  its own ids (the PR diffs its whole form, before and after, byte for byte).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "kinds_#{n}"
    f = fn name, t, extra -> Map.merge(%{"name" => name, "title" => name, "type" => t}, extra) end

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Kinds #{type}",
          "visibility" => "public",
          "fields" => [
            f.("title", "string", %{}),
            f.("featured", "boolean", %{}),
            f.("cover", "image", %{}),
            f.("related", "reference", %{"refType" => type}),
            f.("body", "richText", %{"editor" => "blocks"}),
            f.("tags", "arrayOf", %{"of" => [%{"type" => "string"}]}),
            # The rig's shape: `of` one member, not a list (the plain row list).
            f.("highlights", "arrayOf", %{"ordered" => true, "of" => %{"type" => "string"}}),
            f.("cta", "composite", %{
              "fields" => [
                %{"name" => "kind", "type" => "select", "options" => ["url", "internal"]},
                %{"name" => "url", "type" => "string"},
                %{
                  "name" => "inner",
                  "type" => "composite",
                  "fields" => [%{"name" => "note", "type" => "string"}]
                }
              ]
            }),
            f.("links", "arrayOf", %{
              "of" => [
                %{"type" => "composite", "fields" => [%{"name" => "title", "type" => "string"}]}
              ]
            }),
            f.("blurb", "localizedText", %{"languages" => ["nob", "eng"]})
          ]
        },
        @dataset
      )

    id = "kinds-#{n}"

    {:ok, _} =
      Content.create_document(
        type,
        %{
          "doc_id" => id,
          "title" => "Here",
          "cta" => %{"kind" => "url", "url" => "https://x"},
          "links" => [%{"_key" => "k1", "title" => "L"}],
          "tags" => ["a"],
          "highlights" => ["One"],
          "blurb" => %{"nob" => "Hei"}
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-kinds-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-kinds", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    root = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok,
     conn: conn, desk: "#{root}/_desk/#{type};#{id}", studio: "#{root}/#{type}/#{id}", id: id}
  end

  @form "[data-pane-editing] #editor-form"

  defp desk(c) do
    {:ok, view, _html} = live(c.conn, c.desk)
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, @form) end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp ids(html), do: for([_, id] <- Regex.scan(~r/\sid="([^"]+)"/, html), do: id)

  test "an object's sub-fields are named by their dotted path, labels follow", c do
    view = desk(c)
    assert has_element?(view, ~s(#{@form} [id="cta.kind"]))
    assert has_element?(view, ~s(#{@form} label[for="cta.kind"]))
    assert has_element?(view, ~s(#{@form} [id="cta.url"]))
    assert has_element?(view, ~s(#{@form} [id="cta.inner.note"]))
  end

  test "an array's row list carries the array's path, inside a .field", c do
    view = desk(c)
    assert has_element?(view, ~s(#{@form} .field ol.bp-array-rows[id="links"]))
    assert has_element?(view, ~s(#{@form} .field ol.bp-array-rows[id="tags"]))
  end

  test "a string array's add button is named Add item, the + only decoration", c do
    view = desk(c)
    add = ~s(#{@form} button.bp-array-btn-add[phx-value-field="highlights"])
    html = view |> element(add) |> render()
    assert html =~ ~s(<span aria-hidden="true">+ </span>Add item</button>)

    {:ok, studio, _html} = live(c.conn, c.studio)
    old = studio |> element(~s(button.bp-array-btn-add[phx-value-field="highlights"])) |> render()
    assert old =~ ~s(>+ Add</button>)
  end

  test "image, block canvas, reference and localized text carry the path", c do
    view = desk(c)
    assert has_element?(view, ~s(#{@form} fieldset.field bp-media-picker[id="cover"]))
    assert has_element?(view, ~s(#{@form} .field [id="body"] [id^="bp-fc-wrap-"]))
    assert has_element?(view, ~s(#{@form} bp-reference-picker[data-input-id="related"]))
    assert has_element?(view, ~s(#{@form} [id="blurb.nob"]))
  end

  test "the desk page has no id twice", c do
    html = c |> desk() |> render()
    dupes = html |> ids() |> Enum.frequencies() |> Enum.filter(fn {_id, n} -> n > 1 end)
    assert dupes == []
  end

  test "the old Studio has none of the desk's path ids", c do
    {:ok, view, _html} = live(c.conn, c.studio)
    form = view |> element("#editor-form") |> render()

    refute form =~ ~r/\sid="(cta\.kind|cta\.url|links|tags|cover|body|blurb\.nob)"/
    refute form =~ "data-input-id="
    assert form =~ ~s(id="bp-fc-wrap-)
  end
end
