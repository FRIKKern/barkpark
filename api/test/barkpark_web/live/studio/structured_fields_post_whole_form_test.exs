defmodule BarkparkWeb.Studio.StructuredFieldsPostWholeFormTest do
  @moduledoc """
  task-cb60c4bab77fbd06 — typing in one row of an `arrayOf` field must not
  erase the other rows.

  Found dogfooding: `keywords: [alpha, beta, gamma]`, type X into the second
  row, and the draft stored `[betaX]`. Every row input carried its own
  `phx-change="autosave"`, and LiveView serializes ONLY that input when the
  binding sits on the input (`serializeForm(form, opts, [inputEl.name])` in
  view.js `pushInput`). The editor form's own `phx-change` posts the whole
  form, so the structured-field inputs must not carry one.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "event",
          "title" => "Event",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{
              "name" => "keywords",
              "title" => "Keywords",
              "type" => "arrayOf",
              "ordered" => false,
              "of" => %{"type" => "string"}
            },
            %{
              "name" => "venue",
              "title" => "Venue",
              "type" => "composite",
              "fields" => [
                %{"name" => "name", "title" => "Name", "type" => "string"},
                %{"name" => "city", "title" => "City", "type" => "string"}
              ]
            },
            %{
              "name" => "tagline",
              "title" => "Tagline",
              "type" => "localizedText",
              "languages" => ["nob", "eng"],
              "format" => "plain"
            }
          ]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        "event",
        %{
          "doc_id" => "ev2",
          "title" => "Array probe",
          "content" => %{
            "keywords" => ["alpha", "beta", "gamma"],
            "venue" => %{"name" => "Hall", "city" => "Oslo"},
            "tagline" => %{"nob" => "Hei", "eng" => "Hi"}
          }
        },
        @dataset
      )

    {:ok, _} = Content.publish_document("ev2", "event", @dataset)
    :ok
  end

  test "no input inside an array, composite or localized-text field binds its own phx-change",
       %{conn: conn} do
    {:ok, _view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/event/ev2"))

    inputs =
      Regex.scan(
        ~r{<(?:input|textarea|select)[^>]*name="doc\[(?:keywords|venue|tagline)\][^"]*"[^>]*>},
        html
      )
      |> List.flatten()

    assert length(inputs) >= 7,
           "expected the 3 rows, 2 subfields and 2 languages, got #{inspect(inputs)}"

    bound = Enum.filter(inputs, &(&1 =~ "phx-change="))

    assert bound == [],
           "these inputs post ONLY themselves on change, erasing their siblings: #{inspect(bound)}"
  end

  test "a change to the second row, posted by the editor form, keeps the other rows", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/event/ev2"))

    view
    |> form("#editor-form")
    |> render_change(%{"doc" => %{"keywords" => %{"1" => "betaX"}}})

    {:ok, draft} = Content.get_document("drafts.ev2", "event", @dataset)
    assert draft.content["keywords"] == ["alpha", "betaX", "gamma"]
    assert draft.content["venue"] == %{"name" => "Hall", "city" => "Oslo"}
  end
end
