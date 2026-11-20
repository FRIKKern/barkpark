defmodule BarkparkWeb.Studio.DeskCodelistShapeTest do
  @moduledoc """
  task-6617a482448ddb3d (review of #27107): an autosave of a codelist field
  stored whatever it carried. A post made by hand of `doc[subject]`, a
  single-value codelist, stored a list, a map or a 200 KB string, and an
  edit of another field in the same post was stored with it.

  An unknown code is still stored on purpose (task-400a66c6ebd31026): a
  stored document may hold such codes, and Validation shows a warning under
  the field. But a code is one short string. A post of anything else for a
  codelist field now writes nothing for that field, and the store keeps
  what it held; the rest of the post is saved as before.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.Codelists
  alias Barkpark.Tenancy
  alias BarkparkWeb.EditorPost

  @dataset "production"
  @form "[data-pane-editing] #editor-form"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    list_id = "onixedit:desk-shape-#{n}"
    type = "dcs_#{n}"

    {:ok, _} =
      Codelists.register("onixedit", list_id, %{
        issue: "1",
        name: "Subjects",
        values: [
          %{code: "FBA", translations: [%{language: "eng", label: "Modern fiction"}]},
          %{code: "YFB", translations: [%{language: "eng", label: "Children's fiction"}]}
        ]
      })

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Codelist shape #{n}",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{
              "name" => "subject",
              "title" => "Subject",
              "type" => "codelist",
              "codelistId" => list_id
            },
            %{"name" => "notes", "title" => "Notes", "type" => "string"}
          ]
        },
        @dataset
      )

    id = "dcs-#{n}"

    {:ok, _} =
      Content.create_document(
        type,
        %{"doc_id" => id, "title" => "Book", "content" => %{"subject" => "FBA", "notes" => "n0"}},
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-shape-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-shape", @dataset, ~w(read write admin), ws_id)

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     url: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk/#{type};#{id}",
     type: type,
     id: id}
  end

  defp desk(c) do
    {:ok, view, _html} = live(c.conn, c.url)
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, @form) end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp stored(c) do
    {doc, _draft?, _published?} = Content.fetch_doc_with_draft(c.type, c.id, @dataset)
    doc.content || %{}
  end

  defp send_post(view, subject, notes),
    do: EditorPost.change(view, %{"doc" => %{"subject" => subject, "notes" => notes}})

  for {label, subject} <- [
        {"a list", ["FBA", "YFB"]},
        {"a map", %{"x" => "FBA"}},
        {"a 200 KB string", String.duplicate("F", 200_000)},
        {"a string one past the limit", String.duplicate("F", 65)}
      ] do
    test "a post of #{label} for a codelist writes nothing for it; the rest is saved", c do
      view = desk(c)

      send_post(view, unquote(Macro.escape(subject)), "n1")

      assert eventually(fn -> stored(c)["notes"] == "n1" end)
      assert stored(c)["subject"] == "FBA"
    end
  end

  test "an unknown short code is still stored, and so is one at the limit", c do
    view = desk(c)

    send_post(view, "ZZZ", "n1")
    assert eventually(fn -> stored(c)["subject"] == "ZZZ" end)

    at_limit = String.duplicate("F", 64)
    send_post(view, at_limit, "n2")
    assert eventually(fn -> stored(c)["subject"] == at_limit end)
    assert stored(c)["notes"] == "n2"
  end

  test "a known code is stored, and an empty post still takes the code off", c do
    view = desk(c)

    send_post(view, "YFB", "n1")
    assert eventually(fn -> stored(c)["subject"] == "YFB" end)

    send_post(view, "", "n2")
    assert eventually(fn -> stored(c)["notes"] == "n2" end)
    refute Map.has_key?(stored(c), "subject")
  end
end
