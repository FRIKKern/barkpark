defmodule BarkparkWeb.Studio.DeskImageBarTest do
  @moduledoc """
  The desk's empty image field is TanStack's bar (barkpark-studio
  `ImageInput.tsx`): "Drag or paste image here", then Upload and Select.
  The desk asks bp-media-picker for it with `chrome="bar"`; the old Studio
  does not (task-04d9b49b5d9b6237). The picker's own behaviour is pinned by
  `assets/paper-editor-host-tests/__picker_bar.test.mjs`.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.StudioLocale

  @dataset "production"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "imgbar_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Image bar #{n}",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "cover", "title" => "Cover", "type" => "image"}
          ]
        },
        @dataset
      )

    id = "imgbar-#{n}"
    {:ok, _} = Content.create_document(type, %{"doc_id" => id, "title" => "Here"}, @dataset)

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-imgbar-" <> Ecto.UUID.generate()

    {:ok, _} =
      Auth.create_token(
        raw,
        "desk-imgbar",
        @dataset,
        ~w(read write admin),
        Tenancy.get_default_workspace().id
      )

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    scope = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"
    {:ok, conn: conn, type: type, id: id, scope: scope}
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  test "the desk's image field asks for the bar, with its words", c do
    {:ok, view, _html} = live(c.conn, "#{c.scope}/_desk/#{c.type};#{c.id}")
    render_async(view, 5_000)
    picker = ~s([data-pane-editing] #editor-form bp-media-picker[id="cover"])
    assert eventually(fn -> has_element?(view, picker) end)
    assert has_element?(view, ~s(#{picker}[chrome="bar"]))

    [_, raw] = Regex.run(~r/data-strings="([^"]*)"/, view |> element(picker) |> render())

    words =
      raw
      |> String.replace(["&quot;", "&#39;", "&lt;", "&gt;"], fn
        "&quot;" -> "\""
        "&#39;" -> "'"
        "&lt;" -> "<"
        "&gt;" -> ">"
      end)
      |> String.replace("&amp;", "&")
      |> Jason.decode!()

    assert words["drag_paste"] == "Drag or paste image here"
    assert words["upload_button"] == "Upload"
    assert words["select"] == "Select"
    assert words["bar_label"] == "Drop, paste or upload an image"
  end

  test "the old Studio's image field keeps its own chrome", c do
    {:ok, view, _html} = live(c.conn, "#{c.scope}/#{c.type}/#{c.id}")
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#editor-form bp-media-picker") end)
    refute has_element?(view, "#editor-form bp-media-picker[chrome]")
  end

  test "the bar's words are Norwegian under nb_NO; Select is the action, not the field type" do
    nb =
      Gettext.with_locale(BarkparkWeb.Gettext, "nb_NO", fn ->
        :media |> StudioLocale.component_strings() |> Jason.decode!()
      end)

    assert nb["drag_paste"] == "Dra eller lim inn bilde her"
    assert nb["upload_button"] == "Last opp"
    assert nb["select"] == "Velg"
    assert nb["bar_label"] == "Slipp, lim inn eller last opp et bilde"

    # The set image's frame and its "…" menu (task-19de214155da3f2a).
    assert Map.take(nb, ~w(replace_label preview_alt options_menu download copy_url remove_short)) ==
             %{
               "replace_label" => "Slipp eller lim inn et bilde for å erstatte det",
               "preview_alt" => "Forhåndsvisning av opplastet bilde",
               "options_menu" => "Åpne bildeinnstillingsmeny",
               "download" => "Last ned",
               "copy_url" => "Kopier URL",
               "remove_short" => "Fjern"
             }
  end

  test "a set image's frame is TanStack's: 270 px on the soft fill, a 25 px … on the glass, 6 px in" do
    css = rendered_to_string(BarkparkWeb.Studio.Desk.DocStyle.sheet(%{}))

    assert css =~
             ".dk .dk-edit .bp-mp-frame { position: relative; display: grid; place-items: center; height: 270px; overflow: hidden; border-radius: 3px; background: var(--dk-bg-soft); }"

    assert css =~ ".dk .dk-edit .bp-mp-frame-actions { position: absolute; top: 6px; right: 6px;"

    assert css =~
             "width: 25px; height: 25px; padding: 0; border: 0; border-radius: 3px; background: var(--dk-glass);"

    assert css =~ "--dk-glass: rgb(255 255 255 / 0.88);"
    assert css =~ "--dk-glass: rgb(19 20 27 / 0.85);"
  end

  test "the bar's look is TanStack's: 43 px on the upload fill, ghost buttons, stacked under 440 px" do
    css = rendered_to_string(BarkparkWeb.Studio.Desk.DocStyle.sheet(%{}))

    assert css =~
             ~s|.dk .dk-edit bp-media-picker:is([data-bar-empty], [data-bar-filled]) .bp-mp-actions { display: none; }|

    assert css =~
             "min-height: 43px; padding: 8px 13px 8px 12px; border-radius: 3px; background: var(--dk-upload-fill);"

    assert css =~ "--dk-upload-fill: rgb(246 246 248); --dk-upload-ring: rgb(219 220 226);"
    assert css =~ "--dk-upload-fill: rgb(13 14 18); --dk-upload-ring: rgb(37 40 55);"

    assert css =~
             ".dk .dk-edit .bp-mp-bar button { display: inline-flex; align-items: center; gap: 0; padding: 2px 8px 2px 4px;"

    assert css =~
             ~r/@container \(max-width: 439px\) \{\s*\.dk \.dk-edit \.bp-mp-bar \{ flex-direction: column;/
  end
end
