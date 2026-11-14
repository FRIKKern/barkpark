defmodule BarkparkWeb.Studio.UnknownStoredCodeTest do
  @moduledoc """
  task-dcc3a1b86c09e869: a stored value its control's list does not hold.

  Documents in production can hold a code their codelist does not list
  (#26015 warns about it). The flat codelist `<select>` drew no option for it,
  so the browser posted "" for the field with every change, and an edit to any
  OTHER field deleted the code. The tests post the form as the browser does
  (`form/3` reads each control's posted value from the page), with an edit to
  `notes` only, and read the store.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.Codelists
  alias Barkpark.Tenancy

  @dataset "production"

  @stored %{
    "stage" => "legacy",
    "flat" => "NOPE",
    "subject" => "NOPE",
    "orphan" => "X9",
    "choice" => "legacy",
    "meta" => %{"state" => "legacy"}
  }

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

    type = "uk_book_#{n}"
    doc_id = "uk-book-#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "UK books",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{
              "name" => "stage",
              "type" => "string",
              "options" => %{"list" => ["draft", "review"]}
            },
            %{"name" => "flat", "type" => "codelist", "codelistId" => flat},
            %{"name" => "subject", "type" => "codelist", "codelistId" => tree},
            %{"name" => "orphan", "type" => "codelist", "codelistId" => "onixedit:uk-none-#{n}"},
            %{"name" => "choice", "type" => "select", "options" => ["a", "b"]},
            %{
              "name" => "meta",
              "type" => "object",
              "fields" => [%{"name" => "state", "type" => "select", "options" => ["a", "b"]}]
            },
            %{"name" => "notes", "type" => "string"}
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
          "content" => @stored
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "unknown-code-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "unknown-code", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok,
     conn: conn,
     url: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/#{type}/#{doc_id}",
     desk: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk/#{type};#{doc_id}",
     type: type,
     doc_id: doc_id}
  end

  defp stored(c) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.doc_id, @dataset)
    doc.content || %{}
  end

  # The browser's post: every control's value as the page shows it, and a
  # change to `notes`.
  defp edit_notes(view) do
    view
    |> form("#editor-form", %{"doc" => %{"notes" => "typed"}})
    |> render_change(%{"_target" => ["doc", "notes"]})
  end

  test "the flat codelist shows the stored code as its selected option, marked not in the list",
       c do
    {:ok, view, _} = live(c.conn, c.url)

    assert [option] =
             view
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query(~s(select[name="doc[flat]"] option[selected]))
             |> Enum.to_list()

    assert LazyHTML.attribute(option, "value") == ["NOPE"]
    assert LazyHTML.text(option) =~ "NOPE (not in list)"
  end

  test "the person can still change or clear the code", c do
    {:ok, view, _} = live(c.conn, c.url)

    view
    |> form("#editor-form", %{"doc" => %{"flat" => "B2"}})
    |> render_change(%{"_target" => ["doc", "flat"]})

    assert stored(c)["flat"] == "B2"
    refute render(view) =~ "(not in list)"

    view
    |> form("#editor-form", %{"doc" => %{"flat" => ""}})
    |> render_change(%{"_target" => ["doc", "flat"]})

    refute Map.has_key?(stored(c), "flat")
  end

  for surface <- [:studio, :desk] do
    for {key, label} <- [
          {"stage", "a string with options.list"},
          {"flat", "a flat codelist"},
          {"subject", "a tree codelist"},
          {"orphan", "a codelist with no registered list"},
          {"choice", "a select with options"},
          {"meta", "a select inside an object"}
        ] do
      test "#{surface}, #{label}: an edit to another field keeps the stored value", c do
        key = unquote(key)
        url = if unquote(surface) == :desk, do: c.desk, else: c.url
        {:ok, view, _} = live(c.conn, url)

        edit_notes(view)

        assert stored(c)["notes"] == "typed"
        assert stored(c)[key] == @stored[key]
      end
    end
  end
end
