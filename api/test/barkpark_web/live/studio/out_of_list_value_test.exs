defmodule BarkparkWeb.Studio.OutOfListValueTest do
  @moduledoc """
  task-400a66c6ebd31026: a hand-made post of a value outside its list.

  The select and the codelist controls offer only listed values, but the
  form's `phx-change` takes any value (#25933 review: `doc[subject]=NOPE`).
  It was stored with no finding and published. Now a warning shows under
  the field. It is a warning, not an error (owner ruling via main,
  2026-11-13): documents already in production may hold such values, so the
  save and the publish go through as before.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.Codelists
  alias Barkpark.Tenancy

  @dataset "production"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    flat = "onixedit:ol-flat-#{n}"
    tree = "onixedit:ol-tree-#{n}"

    {:ok, _} =
      Codelists.register("onixedit", flat, %{
        issue: "1",
        name: "Flat",
        values: [
          %{code: "A1", translations: [%{language: "eng", label: "A one"}]},
          %{code: "B2", translations: [%{language: "eng", label: "B two"}]}
        ]
      })

    # Over the 100-entry threshold: the editor draws it as a tree.
    children =
      for i <- 1..101,
          do: %{
            code: "FB" <> String.pad_leading("#{i}", 3, "0"),
            translations: [%{language: "eng", label: "F#{i}"}]
          }

    {:ok, _} =
      Codelists.register("onixedit", tree, %{
        issue: "1",
        name: "Tree",
        values: [
          %{code: "FB", translations: [%{language: "eng", label: "Fiction"}], children: children}
        ]
      })

    type = "ol_book_#{n}"
    doc_id = "ol-book-#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "OL books",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{
              "name" => "stage",
              "type" => "string",
              "options" => %{"list" => ["draft", "review"]}
            },
            %{"name" => "flat", "type" => "codelist", "codelistId" => flat},
            %{"name" => "subject", "type" => "codelist", "codelistId" => tree}
          ]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        type,
        %{
          "doc_id" => doc_id,
          "title" => "Book",
          "content" => %{"stage" => "draft", "flat" => "A1", "subject" => "FB001"}
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "out-of-list-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "out-of-list", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok,
     conn: conn,
     url: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/#{type}/#{doc_id}",
     type: type,
     doc_id: doc_id}
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # A hand-made `phx-change`: the whole form, with one value no control offers.
  defp send_post(view, key, value) do
    form = Map.take(assigns(view).editor_form, ["title", "stage", "flat", "subject"])

    view
    |> element("#editor-form")
    |> render_change(%{"_target" => ["doc", key], "doc" => Map.put(form, key, value)})
  end

  defp stored(c, key) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.doc_id, @dataset)
    doc.content[key]
  end

  defp published(c) do
    case Content.get_document(c.doc_id, c.type, @dataset) do
      {:ok, doc} -> doc.content || %{}
      _ -> %{}
    end
  end

  for {key, label} <- [
        {"stage", "a select"},
        {"flat", "a flat codelist"},
        {"subject", "a tree codelist"}
      ] do
    test "#{label}: the value is stored, a warning shows under the field, publish goes through",
         c do
      key = unquote(key)
      {:ok, view, _} = live(c.conn, c.url)

      send_post(view, key, "NOPE")

      assert stored(c, key) == "NOPE"
      assert assigns(view).save_status == "Saved"
      assert Map.get(assigns(view).validation_errors, key) in [nil, []]
      assert [warning] = Map.get(assigns(view).validation_warnings, key)
      assert render(view) =~ Phoenix.HTML.html_escape(warning) |> Phoenix.HTML.safe_to_string()

      render_click(view, "publish", %{})

      assert published(c)[key] == "NOPE"
      refute render(view) =~ "Fix validation errors before publishing"
    end
  end

  test "a listed value saves and publishes as before", c do
    {:ok, view, _} = live(c.conn, c.url)

    send_post(view, "stage", "review")
    send_post(view, "flat", "B2")
    send_post(view, "subject", "FB042")

    assert Map.take(assigns(view).validation_errors, ["stage", "flat", "subject"]) == %{}
    assert Map.take(assigns(view).validation_warnings, ["stage", "flat", "subject"]) == %{}

    render_click(view, "publish", %{})

    assert Map.take(published(c), ["stage", "flat", "subject"]) == %{
             "stage" => "review",
             "flat" => "B2",
             "subject" => "FB042"
           }
  end
end
