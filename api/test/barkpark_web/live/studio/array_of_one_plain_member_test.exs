defmodule BarkparkWeb.Studio.ArrayOfOnePlainMemberTest do
  @moduledoc """
  An array declared with a LIST of one plain member,
  `"of" => [%{"type" => "string"}]` (Sanity's shape), edits like the single
  member `"of" => %{"type" => "string"}` (task-7655868c8b346c43).

  Before, the editor read the list as named object members: a stored string
  row was drawn read-only, "Add item" made `{"_key": …, "_type": "string"}`
  with no input, and that object was saved where a string belongs.

  An object already stored in such a list still opens, and is saved back as
  it was.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @junk %{"_key" => "k1", "_type" => "string"}

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "aop_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "AOP #{type}",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{
              "name" => "tags",
              "title" => "Tags",
              "type" => "arrayOf",
              "of" => [%{"type" => "string"}]
            },
            %{
              "name" => "box",
              "title" => "Box",
              "type" => "composite",
              "fields" => [
                %{"name" => "notes", "type" => "arrayOf", "of" => [%{"type" => "text"}]}
              ]
            }
          ]
        },
        @dataset
      )

    for {id, tags} <- [{"aop-plain-#{n}", ["a"]}, {"aop-junk-#{n}", [@junk, "b"]}] do
      {:ok, _} =
        Content.create_document(
          type,
          %{"doc_id" => id, "title" => "Here", "content" => %{"tags" => tags}},
          @dataset
        )
    end

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "aop-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "aop", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    root = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok, conn: conn, root: root, type: type, plain: "aop-plain-#{n}", junk: "aop-junk-#{n}"}
  end

  defp studio(c, id) do
    {:ok, view, _html} = live(c.conn, "#{c.root}/#{c.type}/#{id}")
    view
  end

  defp desk(c, id) do
    {:ok, view, _html} = live(c.conn, "#{c.root}/_desk/#{c.type};#{id}")
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "[data-pane-editing] #editor-form") end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp stored(c, id) do
    {doc, _draft?, _published?} = Content.fetch_doc_with_draft(c.type, id, @dataset)
    {doc.title, (doc.content || %{})["tags"]}
  end

  defp change(view, target, doc) do
    view |> element("#editor-form") |> render_change(%{"_target" => target, "doc" => doc})
  end

  for {name, open} <- [{"the old Studio", :studio}, {"the desk", :desk}] do
    test "#{name}: a stored string is a text input, and Add makes another", c do
      view = unquote(open)(c, c.plain)

      assert has_element?(
               view,
               ~s(#editor-form input[type="text"][name="doc[tags][0]"][value="a"])
             )

      refute has_element?(view, ~s(#editor-form [data-field-name="tags"] [data-structured-value]))

      view
      |> element(~s(#editor-form button.bp-array-btn-add[phx-value-field="tags"]))
      |> render_click()

      assert has_element?(view, ~s(#editor-form input[type="text"][name="doc[tags][1]"]))
      refute has_element?(view, ~s(#editor-form [data-field-name="tags"] [data-structured-value]))
    end
  end

  test "typing alpha in the new row stores a string, not an object", c do
    view = studio(c, c.plain)

    view
    |> element(~s(#editor-form button.bp-array-btn-add[phx-value-field="tags"]))
    |> render_click()

    change(view, ["doc", "tags", "1"], %{
      "title" => "Here",
      "tags" => %{"0" => "a", "1" => "alpha"}
    })

    assert stored(c, c.plain) == {"Here", ["a", "alpha"]}
  end

  test "a list of one plain member inside an object is a text input too", c do
    view = studio(c, c.plain)

    view
    |> element(~s(#editor-form button.bp-array-btn-add[phx-value-path="doc[box].notes"]))
    |> render_click()

    assert has_element?(view, ~s(#editor-form [name="doc[box].notes[0]"]))
    refute has_element?(view, ~s(#editor-form [data-field-name="notes"] [data-structured-value]))
  end

  test "an object already stored in the list opens, and is saved back as it was", c do
    view = studio(c, c.junk)

    json = Jason.encode!(@junk)
    assert has_element?(view, ~s(#editor-form input[type="hidden"][name="doc[tags][0][_json]"]))
    assert has_element?(view, ~s(#editor-form input[type="text"][name="doc[tags][1]"][value="b"]))
    refute has_element?(view, ~s(#editor-form input[name="doc[tags][0]"]))

    # The whole form, as the browser posts it on a title change.
    change(view, ["doc", "title"], %{
      "title" => "Typed",
      "tags" => %{"0" => %{"_json" => json}, "1" => "b"}
    })

    assert stored(c, c.junk) == {"Typed", [@junk, "b"]}

    # The string row beside it is edited; the object stays.
    change(view, ["doc", "tags", "1"], %{
      "title" => "Typed",
      "tags" => %{"0" => %{"_json" => json}, "1" => "bee"}
    })

    assert stored(c, c.junk) == {"Typed", [@junk, "bee"]}
  end

  test "the stored object can be removed", c do
    view = studio(c, c.junk)

    view
    |> element(
      ~s(#editor-form [data-field-name="tags"] li[data-row-index="0"] button[phx-value-action="remove_row"])
    )
    |> render_click()

    assert stored(c, c.junk) == {"Here", ["b"]}
  end

  # #26168 review: the post is the rendered form's own, as the browser sends
  # it. A kept row inside an object has a dotted name, which the dot-path fold
  # writes into the stored row; a stored list row is kept like an object.
  for {name, open} <- [{"the old Studio", :studio}, {"the desk", :desk}] do
    test "#{name}: a title edit leaves a kept row in an object, and a list row, as they were",
         c do
      odd = %{
        "tags" => [["a", "b"], @junk, "s"],
        "box" => %{"notes" => [%{"_key" => "in1", "_type" => "text"}, "n"]}
      }

      id = "aop-odd-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Content.create_document(
          c.type,
          %{"doc_id" => id, "title" => "Here", "content" => odd},
          @dataset
        )

      view = unquote(open)(c, id)

      view
      |> form("#editor-form", %{"doc" => %{"title" => "Typed"}})
      |> render_change(%{"_target" => ["doc", "title"]})

      {doc, _draft?, _published?} = Content.fetch_doc_with_draft(c.type, id, @dataset)
      assert doc.title == "Typed"
      assert Map.take(doc.content, ["tags", "box"]) == odd
    end
  end

  # #26168 review: the hidden `_json` input exists only on a row that holds an
  # object or a list. Posted anywhere else it is not a kept row.
  test "a _json posted on a string row, or on no row, writes nothing there", c do
    view = studio(c, c.plain)
    forged = Jason.encode!(%{"_ref" => "x", "_type" => "reference"})

    change(view, ["doc", "title"], %{
      "title" => "Typed",
      "tags" => %{"0" => %{"_json" => forged}, "1" => %{"_json" => forged}}
    })

    assert {"Typed", ["a" | rest]} = stored(c, c.plain)
    refute Enum.any?(rest, &is_map/1)
  end

  # #26168 re-read: another editor's save moved or removed the kept row after
  # this page drew it. The page then posts the form it drew.
  describe "the page posts its old form after another save" do
    defp remote(c, tags) do
      {:ok, _} =
        Content.upsert_document(
          c.type,
          %{"doc_id" => c.junk, "title" => "Here", "content" => %{"tags" => tags}},
          @dataset
        )
    end

    defp old_form(view, c) do
      render(view)

      change(view, ["doc", "title"], %{
        "title" => "Typed",
        "tags" => %{"0" => %{"_json" => Jason.encode!(@junk)}, "1" => "b"}
      })

      stored(c, c.junk)
    end

    test "the kept row moved: it is still in the list", c do
      view = studio(c, c.junk)
      remote(c, ["b", @junk])

      assert {"Typed", tags} = old_form(view, c)
      assert Enum.sort_by(tags, &is_map/1) == ["b", @junk]
    end

    test "the kept row was removed: no row comes back, and no empty row", c do
      view = studio(c, c.junk)
      remote(c, ["b"])

      assert {"Typed", tags} = old_form(view, c)
      refute @junk in tags
      refute nil in tags
      assert "b" in tags
    end

    test "the kept row's content changed: the newer content is kept", c do
      view = studio(c, c.junk)
      newer = Map.put(@junk, "note", "remote")
      remote(c, [newer, "b"])

      assert old_form(view, c) == {"Typed", [newer, "b"]}
    end
  end
end
