defmodule BarkparkWeb.Studio.DeskLocalizedTabsTest do
  @moduledoc """
  B06: a localizedText field in the desk is a tablist named by the field, one
  tab per language, as the TanStack Studio draws it (`LocalizedTabs`). The
  field opens on its primary language; every language's text stays in the
  form, so a save posts each under its own name and an emptied language is
  removed. With the primary empty a status line names what readers get. The
  old Studio keeps its rows.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @form "[data-pane-editing] #editor-form"
  @blurb %{"nob" => "En bok om felter.", "eng" => "A book about fields."}

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "lt_volume_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Volume #{n}",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{
              "name" => "blurb",
              "title" => "Blurb",
              "type" => "localizedText",
              "languages" => ["nob", "eng"],
              "format" => "plain",
              "fallbackChain" => ["nob", "eng"]
            },
            %{
              "name" => "code",
              "title" => "Code",
              "type" => "localizedText",
              "languages" => ["nob", "eng"],
              "fallbackChain" => ["nob", "eng"],
              "validation" => %{"max" => 5}
            },
            %{
              "name" => "comp",
              "title" => "Comp",
              "type" => "composite",
              "fields" => [
                %{
                  "name" => "cap",
                  "title" => "Caption",
                  "type" => "localizedText",
                  "languages" => ["nob", "eng"],
                  "fallbackChain" => ["nob", "eng"]
                },
                %{"name" => "note", "title" => "Note", "type" => "string"}
              ]
            },
            %{
              "name" => "lrows",
              "title" => "Rows",
              "type" => "arrayOf",
              "of" => %{
                "type" => "composite",
                "fields" => [
                  %{
                    "name" => "cap",
                    "title" => "Caption",
                    "type" => "localizedText",
                    "languages" => ["nob", "eng"],
                    "fallbackChain" => ["nob", "eng"]
                  },
                  %{"name" => "note", "title" => "Note", "type" => "string"}
                ]
              }
            },
            %{"name" => "notes", "type" => "string"}
          ]
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-lt-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-lt", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    root = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok, conn: conn, root: root, type: type}
  end

  defp doc!(c, blurb) do
    id = "lt-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.create_document(
        c.type,
        %{"doc_id" => id, "title" => "Book", "content" => %{"blurb" => blurb, "notes" => "0"}},
        @dataset
      )

    id
  end

  defp doc_with!(c, content) do
    id = "lt-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.create_document(
        c.type,
        %{"doc_id" => id, "title" => "Book", "content" => Map.put(content, "notes", "0")},
        @dataset
      )

    id
  end

  defp desk(c, id, query \\ "") do
    {:ok, view, _html} = live(c.conn, "#{c.root}/_desk/#{c.type};#{id}#{query}")
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, @form) end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp stored(c, id) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, id, @dataset)
    doc.content || %{}
  end

  defp change(view, name, value) do
    view |> form(@form, %{name => value}) |> render_change(%{"_target" => [name]})
  end

  test "the field is a tablist named by its title, open on the primary language", c do
    view = desk(c, doc!(c, @blurb))
    tabs = ~s(#{@form} [role="tablist"][aria-labelledby="blurb-label"])

    assert has_element?(view, ~s(#{@form} legend#blurb-label), "Blurb")

    assert has_element?(
             view,
             ~s(#{tabs} > button[role="tab"]#blurb-tab-nob[aria-selected="true"][tabindex="0"][aria-controls="blurb-panel-nob"]),
             "nob"
           )

    assert has_element?(
             view,
             ~s(#{tabs} > button[role="tab"]#blurb-tab-eng[aria-selected="false"][tabindex="-1"]),
             "eng"
           )

    # Each language with text carries its dot.
    assert has_element?(view, ~s(#blurb-tab-nob .filled[aria-label=", has text"]))
    assert has_element?(view, ~s(#blurb-tab-eng .filled))

    # Both languages' text is in the form; only the primary's panel shows.
    assert has_element?(
             view,
             ~s|[role="tabpanel"]#blurb-panel-nob:not([hidden]) textarea[id="blurb.nob"][name="doc[blurb].nob"][aria-label="nob (primary)"]|,
             @blurb["nob"]
           )

    assert has_element?(
             view,
             ~s|[role="tabpanel"]#blurb-panel-eng[hidden] textarea[id="blurb.eng"][name="doc[blurb].eng"][aria-label="eng"]|,
             @blurb["eng"]
           )

    # A tab is chosen in the browser: its click is a JS command, not an event.
    click =
      view
      |> element("#blurb-tab-eng")
      |> render()
      |> then(&Regex.run(~r/phx-click="([^"]+)"/, &1))

    assert [_, js] = click
    refute js =~ "push"
    refute has_element?(view, ~s(#{@form} .bp-field-localized [role="status"]))
  end

  test "an edit in one language stores it beside the others, and an edit elsewhere keeps both",
       c do
    id = doc!(c, @blurb)
    view = desk(c, id)

    change(view, "doc[blurb].eng", "A book about fields. Now longer.")

    assert stored(c, id)["blurb"] == %{
             "nob" => "En bok om felter.",
             "eng" => "A book about fields. Now longer."
           }

    view
    |> form(@form, %{"doc" => %{"notes" => "typed"}})
    |> render_change(%{"_target" => ["doc", "notes"]})

    assert stored(c, id)["notes"] == "typed"
    assert stored(c, id)["blurb"]["eng"] == "A book about fields. Now longer."
    assert stored(c, id)["blurb"]["nob"] == "En bok om felter."
  end

  test "the primary emptied: it is removed, its dot goes, and the field says what readers get",
       c do
    id = doc!(c, @blurb)
    view = desk(c, id)

    change(view, "doc[blurb].nob", "")

    assert stored(c, id)["blurb"] == %{"eng" => "A book about fields."}
    refute has_element?(view, ~s(#blurb-tab-nob .filled))
    assert has_element?(view, ~s(#blurb-tab-eng .filled))

    assert has_element?(
             view,
             ~s(#{@form} .field p.localized-warning[role="status"]),
             "No nob text: readers get the eng text instead."
           )

    # The last language emptied: the field is removed.
    change(view, "doc[blurb].eng", "")
    refute Map.has_key?(stored(c, id), "blurb")
    assert stored(c, id)["notes"] == "0"
  end

  # TanStack's `write()`: a field left with no text is unset, and an object
  # left with only blanks in turn; no `{}` shell is stored.
  test "a field whose other languages are all blank is removed when its last text is emptied",
       c do
    id = doc_with!(c, %{"blurb" => %{"nob" => "", "eng" => "E only"}})
    view = desk(c, id)

    change(view, "doc[blurb].eng", "")
    refute Map.has_key?(stored(c, id), "blurb")
    assert stored(c, id)["notes"] == "0"
  end

  test "an object's language field emptied in every language is taken off the object", c do
    id = doc_with!(c, %{"comp" => %{"cap" => %{"nob" => "cn", "eng" => "ce"}, "note" => "nn"}})
    view = desk(c, id)

    change(view, "doc[comp].cap.nob", "")
    assert stored(c, id)["comp"] == %{"cap" => %{"eng" => "ce"}, "note" => "nn"}

    change(view, "doc[comp].cap.eng", "")
    assert stored(c, id)["comp"] == %{"note" => "nn"}

    view
    |> form(@form, %{"doc" => %{"notes" => "typed"}})
    |> render_change(%{"_target" => ["doc", "notes"]})

    assert stored(c, id)["comp"] == %{"note" => "nn"}
    assert stored(c, id)["notes"] == "typed"
  end

  # TanStack's `write()` unsets no parent inside an array item: the row
  # keeps its language field, emptied.
  test "in an array row a language field emptied in every language stays, as {}", c do
    row = %{"_key" => "r1", "cap" => %{"nob" => "rn", "eng" => "re"}, "note" => "rr"}
    id = doc_with!(c, %{"lrows" => [row]})
    view = desk(c, id)

    change(view, "doc[lrows][0].cap.nob", "")
    change(view, "doc[lrows][0].cap.eng", "")

    assert stored(c, id)["lrows"] == [%{"_key" => "r1", "cap" => %{}, "note" => "rr"}]
  end

  test "an edit sent while the published version is shown is refused", c do
    id = doc!(c, @blurb)
    {:ok, _} = Content.publish_document(id, c.type, @dataset)
    published = Content.get_document(id, c.type, @dataset)
    view = desk(c, id, "?perspective=published")

    BarkparkWeb.EditorPost.change(view, %{"doc[blurb].eng" => "Typed"})

    assert Content.get_document(id, c.type, @dataset) == published
    refute stored(c, id)["blurb"]["eng"] == "Typed"
  end

  test "a language's finding shows in its panel, and its tab is marked", c do
    id = doc!(c, @blurb)
    view = desk(c, id)

    change(view, "doc[code].eng", "toolongtext")
    assert stored(c, id)["code"] == %{"eng" => "toolongtext"}

    assert has_element?(
             view,
             ~s(#code-panel-eng[hidden] .error[data-error-for="eng"]),
             "Must be at most 5 characters"
           )

    assert has_element?(view, ~s(#code-tab-eng .has-error[aria-label=", has an error"]))
    refute has_element?(view, ~s(#code-tab-nob .has-error))
    refute has_element?(view, ~s(#code-panel-nob .error))

    change(view, "doc[code].eng", "ok")
    refute has_element?(view, ~s(#code-tab-eng .has-error))
    refute has_element?(view, ~s(#code-panel-eng .error))
  end

  # The old Studio's stored shape is main's: an emptied language is kept as "",
  # and an edit elsewhere keeps the field byte-identical.
  test "the old Studio stores an emptied language as it did, and keeps the field on other edits",
       c do
    id = doc!(c, @blurb)
    {:ok, view, _html} = live(c.conn, "#{c.root}/#{c.type}/#{id}")

    view
    |> form("#editor-form", %{"doc" => %{"notes" => "typed"}})
    |> render_change(%{"_target" => ["doc", "notes"]})

    assert stored(c, id)["notes"] == "typed"
    assert stored(c, id)["blurb"] == @blurb

    view
    |> form("#editor-form", %{"doc[blurb].nob" => ""})
    |> render_change(%{"_target" => ["doc[blurb].nob"]})

    assert stored(c, id)["blurb"] == %{"nob" => "", "eng" => "A book about fields."}
  end

  test "the desk keeps the field byte-identical on an edit elsewhere and on Save", c do
    id = doc!(c, @blurb)
    view = desk(c, id)

    view
    |> form(@form, %{"doc" => %{"notes" => "typed"}})
    |> render_change(%{"_target" => ["doc", "notes"]})

    assert stored(c, id)["blurb"] == @blurb
    view |> element(@form) |> render_submit()
    assert stored(c, id)["blurb"] == @blurb
    assert stored(c, id)["notes"] == "typed"
  end

  test "the old Studio keeps a row per language", c do
    id = doc!(c, @blurb)
    {:ok, view, _html} = live(c.conn, "#{c.root}/#{c.type}/#{id}")

    refute has_element?(view, ~s([role="tablist"]))

    assert has_element?(
             view,
             ~s(.bp-localized-row[data-lang="nob"] textarea[name="doc[blurb].nob"])
           )

    assert has_element?(
             view,
             ~s(.bp-localized-row[data-lang="eng"] textarea[name="doc[blurb].eng"])
           )
  end
end
