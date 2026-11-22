defmodule BarkparkWeb.Studio.DeskRichTextListSaveTest do
  @moduledoc """
  task-be63132f2ec337c7, through the desk's save: indenting a list item or
  turning bullets into numbers, its text untouched, is stored
  (`PortableText.from_html/3`). An edit elsewhere leaves the list as stored.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "rt_list_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Rich text lists",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "rt", "title" => "Body", "type" => "richText"}
          ]
        },
        @dataset
      )

    id = "rt-list-#{n}"
    rt = [item("p1", "intro", %{}), item("k1", "x", bullet()), item("k2", "y", bullet())]

    {:ok, _} =
      Content.create_document(
        type,
        %{"doc_id" => id, "title" => "T0", "content" => %{"rt" => rt}},
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "rt-list-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "rt-list", @dataset, ~w(read write admin), ws_id)

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     path: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk/#{type};#{id}",
     type: type,
     id: id,
     rt: rt}
  end

  defp item(key, text, list) do
    Map.merge(
      %{
        "_type" => "block",
        "_key" => key,
        "style" => "normal",
        "markDefs" => [],
        "children" => [%{"_type" => "span", "_key" => key <> "s", "text" => text, "marks" => []}]
      },
      list
    )
  end

  defp bullet, do: %{"listItem" => "bullet", "level" => 1}

  defp stored(c) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, @dataset)
    doc.content["rt"]
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp posts(c, html) do
    {:ok, view, _html} = live(c.conn, c.path)
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "[data-pane-editing] #editor-form") end)

    view
    |> element("[data-pane-editing] #editor-form")
    |> render_change(%{"_target" => ["doc", "rt"], "doc" => %{"title" => "T0", "rt" => html}})
  end

  test "an indented bullet is stored at level 2", c do
    posts(c, "<p>intro</p><ul><li>x<ul><li>y</li></ul></li></ul>")
    assert eventually(fn -> Enum.at(stored(c), 2)["level"] == 2 end), inspect(stored(c))
    assert Enum.take(stored(c), 2) == Enum.take(c.rt, 2)
    assert Enum.at(stored(c), 2) == Map.put(Enum.at(c.rt, 2), "level", 2)
  end

  test "bullets turned to numbers are stored as numbers", c do
    posts(c, "<p>intro</p><ol><li>x</li><li>y</li></ol>")
    assert eventually(fn -> Enum.at(stored(c), 1)["listItem"] == "number" end), inspect(stored(c))
    assert tl(stored(c)) == Enum.map(tl(c.rt), &Map.put(&1, "listItem", "number"))
  end

  # Control (also on main): an edit of the paragraph leaves the list as stored.
  test "an edit elsewhere leaves the list items byte-identical", c do
    posts(c, "<p>intro two</p><ul><li>x</li><li>y</li></ul>")

    assert eventually(fn ->
             hd(stored(c))["children"] |> hd() |> Map.get("text") == "intro two"
           end)

    assert tl(stored(c)) == tl(c.rt)
  end
end
