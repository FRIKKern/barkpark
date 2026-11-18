defmodule BarkparkWeb.Studio.DeskImageFieldTest do
  @moduledoc """
  The desk's image field, as the TanStack Studio's `ImageInput` (J12,
  task-dfc583637385c120): an empty field asks its picker for Sanity's
  reference shape only where `CanonicalShapes` writes canonical shapes (the
  box's flag, on in tests; off by default) or the schema asks for it
  (`valueShape: "assetRef"`), else the legacy `{url, assetId}`; a schema with
  `hotspot` gets the "Edit hotspot and crop"
  dialog, and the image's own fields (alt) are fields of their own under
  it. What it writes — the hotspot `{x, y, width, height}`, the crop `{top,
  bottom, left, right}` and alt on the image object — goes through the
  form's autosave, so it is refused for another document's form and while
  a revision is shown (`DeskRevisionViewGuardTest`).

  The picker and the dialog themselves are pinned by
  `assets/paper-editor-host-tests/__desk_image_field.test.mjs`.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.SanityImageFixtures, only: [upload!: 1]

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.StudioLive.PostIdentity

  @dataset "production"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "imgfield_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Image field #{n}",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{
              "name" => "mainImage",
              "title" => "Main image",
              "type" => "image",
              "options" => %{"hotspot" => true},
              "fields" => [
                %{"name" => "alt", "title" => "Alternative text", "type" => "string"}
              ]
            }
          ]
        },
        @dataset
      )

    id = "imgfield-#{n}"
    {:ok, _} = Content.create_document(type, %{"doc_id" => id, "title" => "Here"}, @dataset)

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-imgfield-" <> Ecto.UUID.generate()

    {:ok, _} =
      Auth.create_token(
        raw,
        "desk-imgfield",
        @dataset,
        ~w(read write admin),
        Tenancy.get_default_workspace().id
      )

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    scope = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok,
     conn: conn,
     type: type,
     id: id,
     scope: scope,
     tenancy: [workspace_id: ws.id, project_id: proj.id]}
  end

  defp eventually(fun), do: Enum.any?(1..300, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp open(c) do
    {:ok, view, _html} = live(c.conn, "#{c.scope}/_desk/#{c.type};#{c.id}")
    render_async(view, 5_000)

    assert eventually(fn ->
             has_element?(view, ~s(#editor-form bp-media-picker[id="mainImage"]))
           end)

    view
  end

  defp mark(c), do: %{PostIdentity.key() => PostIdentity.value(@dataset, c.type, c.id)}

  defp save(view, c, fields, mark \\ nil) do
    render_click(view, "autosave", Map.merge(mark || mark(c), %{"doc" => fields}))
    render_async(view, 5_000)
  end

  # The row the editor writes: the draft once there is one.
  defp stored(c) do
    case Content.get_document(Content.draft_id(c.id), c.type, @dataset) do
      {:ok, doc} -> doc
      _ -> elem(Content.get_document(c.id, c.type, @dataset), 1)
    end
  end

  defp image(c) do
    case stored(c).content["mainImage"] do
      text when is_binary(text) -> Jason.decode!(text)
      other -> other
    end
  end

  test "the field: the reference shape, the dialog's button, and Alternative text as a field of its own",
       c do
    view = open(c)
    picker = ~s(#editor-form bp-media-picker[id="mainImage"])
    assert has_element?(view, ~s(#{picker}[value-shape="asset-ref"]))
    assert has_element?(view, ~s(#{picker}[hotspot]))
    # The picker's own alt box is not drawn: alt is the field below.
    refute has_element?(view, ~s(#{picker}[alt]))

    part = ~s(#editor-form .dk-image-part input[id="mainImage.alt"])
    assert has_element?(view, part)
    assert has_element?(view, ~s(#editor-form label[for="mainImage.alt"]), "Alternative text")
    # It belongs to no form: what is typed reaches the store through the picker.
    assert has_element?(
             view,
             ~s(#{part}[form="dk-image-part-no-form"][data-desk-image-for="mainImage"])
           )

    assert has_element?(
             view,
             ~s(#editor-form .dk-image-part .field-actions [data-desk-field="mainImage.alt"])
           )

    words = view |> element(picker) |> render() |> strings()
    assert words["crop_open"] == "Open image edit dialog"
    assert words["crop_title"] == "Edit hotspot and crop"

    assert words["crop_hotspot_value"] ==
             "centre %{x} across, %{y} down; %{width} wide, %{height} high"
  end

  describe "with the box's canonical_shape_writes flag off (the default)" do
    setup do
      before = Application.get_env(:barkpark, :canonical_shape_writes)
      Application.put_env(:barkpark, :canonical_shape_writes, false)
      on_exit(fn -> Application.put_env(:barkpark, :canonical_shape_writes, before) end)
    end

    test "an empty field keeps writing the legacy {url, assetId}: no value-shape", c do
      view = open(c)
      refute has_element?(view, ~s(#editor-form bp-media-picker[id="mainImage"][value-shape]))
      # The rest of the field is the same.
      assert has_element?(view, ~s(#editor-form bp-media-picker[id="mainImage"][hotspot]))
      assert has_element?(view, ~s(#editor-form .dk-image-part input[id="mainImage.alt"]))
    end

    test "a schema that asks for the reference shape (valueShape: assetRef) gets it", c do
      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => c.type,
            "title" => "Image field",
            "visibility" => "public",
            "fields" => [
              %{"name" => "title", "title" => "Title", "type" => "string"},
              %{
                "name" => "mainImage",
                "title" => "Main image",
                "type" => "image",
                "options" => %{"hotspot" => true, "valueShape" => "assetRef"}
              }
            ]
          },
          @dataset
        )

      view = open(c)

      assert has_element?(
               view,
               ~s(#editor-form bp-media-picker[id="mainImage"][value-shape="asset-ref"])
             )
    end
  end

  test "a field already in the legacy shape keeps it", c do
    {:ok, _} =
      Content.upsert_document(
        c.type,
        %{
          "doc_id" => c.id,
          "title" => "Here",
          "mainImage" => %{"url" => "/media/a.png", "assetId" => "a"}
        },
        @dataset
      )

    view = open(c)
    refute has_element?(view, ~s(#editor-form bp-media-picker[id="mainImage"][value-shape]))
  end

  test "the old Studio's image field is untouched: no subfields under it", c do
    {:ok, view, _html} = live(c.conn, "#{c.scope}/#{c.type}/#{c.id}")
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#editor-form bp-media-picker") end)
    refute has_element?(view, ".dk-image-part")
    refute has_element?(view, "#editor-form bp-media-picker[value-shape]")
  end

  test "stored rows: upload, alt, hotspot and crop, an unrelated edit, clear", c do
    file = upload!(c.tenancy)
    view = open(c)

    # An upload: the picker writes the asset document's reference; the save
    # writes the Sanity id a reader follows.
    save(view, c, %{
      "mainImage" =>
        Jason.encode!(%{
          "_type" => "image",
          "asset" => %{"_type" => "reference", "_ref" => "asset-#{file.id}"}
        })
    })

    sanity_ref = "image-#{file.sha1}-3x2-png"
    assert image(c)["asset"] == %{"_type" => "reference", "_ref" => sanity_ref}

    # Alt, then the dialog's hotspot and crop, on the image object.
    with_alt = %{
      "_type" => "image",
      "asset" => %{"_type" => "reference", "_ref" => sanity_ref},
      "alt" => "A sun"
    }

    save(view, c, %{"mainImage" => Jason.encode!(with_alt)})
    assert image(c) == with_alt

    framed =
      Map.merge(with_alt, %{
        "hotspot" => %{
          "_type" => "sanity.imageHotspot",
          "x" => 0.405,
          "y" => 0.485,
          "width" => 0.36,
          "height" => 0.37
        },
        "crop" => %{
          "_type" => "sanity.imageCrop",
          "top" => 0.0,
          "bottom" => 0.0,
          "left" => 0.02,
          "right" => 0.16
        }
      })

    save(view, c, %{"mainImage" => Jason.encode!(framed)})
    assert image(c) == framed

    # A title edit leaves the image as it was.
    save(view, c, %{"title" => "Renamed", "mainImage" => Jason.encode!(framed)})
    assert stored(c).title == "Renamed"
    assert image(c) == framed

    save(view, c, %{"title" => "Renamed again"})
    assert stored(c).title == "Renamed again"
    assert image(c) == framed

    # Remove.
    save(view, c, %{"mainImage" => ""})
    assert image(c) in [nil, ""]
  end

  test "hotspot and crop posted with another document's mark write nothing", c do
    view = open(c)

    framed = %{
      "_type" => "image",
      "hotspot" => %{"x" => 0.1, "y" => 0.1, "width" => 0.2, "height" => 0.2}
    }

    other = %{PostIdentity.key() => PostIdentity.value(@dataset, c.type, "someone-else")}
    save(view, c, %{"mainImage" => Jason.encode!(framed)}, other)
    save(view, c, %{"mainImage" => Jason.encode!(framed)}, %{PostIdentity.key() => ""})
    assert image(c) in [nil, ""]
  end

  defp strings(html) do
    [_, raw] = Regex.run(~r/data-strings="([^"]*)"/, html)

    raw
    |> String.replace(["&quot;", "&#39;", "&lt;", "&gt;"], fn
      "&quot;" -> "\""
      "&#39;" -> "'"
      "&lt;" -> "<"
      "&gt;" -> ">"
    end)
    |> String.replace("&amp;", "&")
    |> Jason.decode!()
  end
end
