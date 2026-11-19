defmodule BarkparkWeb.Studio.DeskSelectDatetimeKeptTest do
  @moduledoc """
  A stored value the select or the date-time box cannot show is kept until
  that field is changed, in the desk and in the old Studio.

    * A dropdown declared Sanity's way (`options: {list: [...]}`) shows a
      value that is no option as "Select…", which posts "". An edit of
      another field, or Save, keeps the value: a string, a number or a
      boolean, byte-identical. So does a plain-list dropdown (`options:
      [...]`) holding a number or `true` that is no option.
    * A date-time stored as a number (epoch ms) is shown as an empty box,
      which posts "". It is kept the same way, until this post's `_target`
      names the field.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "sdk_post_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Kept #{n}",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{
              "name" => "sdm",
              "title" => "Sdm",
              "type" => "select",
              "options" => %{"list" => ["a", "b", "c", "2"]}
            },
            %{"name" => "plain", "type" => "select", "options" => ["a", "b"]},
            %{"name" => "dt", "title" => "When", "type" => "datetime"},
            %{"name" => "notes", "type" => "string"}
          ]
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-sdk-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-sdk", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    root = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok, conn: conn, root: root, type: type}
  end

  defp doc!(c, content) do
    id = "sdk-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.create_document(
        c.type,
        %{"doc_id" => id, "title" => "Post", "content" => Map.put(content, "notes", "0")},
        @dataset
      )

    id
  end

  defp open(c, :desk, id) do
    {:ok, view, _html} = live(c.conn, "#{c.root}/_desk/#{c.type};#{id}")
    render_async(view, 5_000)
    form = "[data-pane-editing] #editor-form"
    assert eventually(fn -> has_element?(view, form) end)
    {view, form}
  end

  defp open(c, :studio, id) do
    {:ok, view, _html} = live(c.conn, "#{c.root}/#{c.type}/#{id}")
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#editor-form") end)
    {view, "#editor-form"}
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp stored(c, id) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, id, @dataset)
    doc.content || %{}
  end

  # An edit of another field: the whole form posts, `_target` names notes.
  defp edit_notes(view, form, value) do
    view
    |> form(form, %{"doc" => %{"notes" => value}})
    |> render_change(%{"_target" => ["doc", "notes"]})
  end

  # The hook's write of the hidden date input (a form helper refuses a hidden
  # change).
  defp hook_post(view, form, name, value) do
    view |> form(form) |> render_change(%{"doc" => %{name => value}, "_target" => ["doc", name]})
  end

  defp save(view, form), do: view |> form(form) |> render_submit()

  for surface <- [:desk, :studio] do
    @surface surface

    for {label, value} <- [
          {"a string", "legacy"},
          {"a number's text", "zz2"},
          {"a number", 3},
          {"true", true}
        ] do
      @label label
      @value value

      test "#{surface}: a dropdown from options.list keeps #{label} that is no option, on an edit and on Save",
           c do
        id = doc!(c, %{"sdm" => @value, "plain" => "a"})
        {view, form} = open(c, @surface, id)
        before = stored(c, id)

        edit_notes(view, form, "typed")
        assert stored(c, id) == Map.put(before, "notes", "typed")

        save(view, form)
        assert stored(c, id) == Map.put(before, "notes", "typed")
      end
    end

    test "#{surface}: a dropdown from a plain list keeps a number or true that is no option",
         c do
      for value <- [3, true] do
        id = doc!(c, %{"plain" => value})
        {view, form} = open(c, @surface, id)

        edit_notes(view, form, "typed")
        assert stored(c, id)["plain"] === value
      end
    end

    test "#{surface}: a dropdown from options.list keeps a stored number its option's text matches",
         c do
      id = doc!(c, %{"sdm" => 2})
      {view, form} = open(c, @surface, id)

      edit_notes(view, form, "typed")
      assert stored(c, id)["sdm"] === 2
    end

    test "#{surface}: a date-time stored as epoch ms is kept on an edit and on Save, and a pick writes",
         c do
      id = doc!(c, %{"dt" => 1_757_149_200_000})
      {view, form} = open(c, @surface, id)
      before = stored(c, id)

      edit_notes(view, form, "typed")
      assert stored(c, id) == Map.put(before, "notes", "typed")

      save(view, form)
      assert stored(c, id) == Map.put(before, "notes", "typed")

      hook_post(view, form, "dt", "2026-09-07T09:00:00.000Z")
      assert stored(c, id)["dt"] in ["2026-09-07T09:00:00.000Z", "2026-09-07T09:00:00Z"]
    end
  end

  test "desk: picking an option over a value that is none writes it", c do
    id = doc!(c, %{"sdm" => "legacy"})
    {view, form} = open(c, :desk, id)

    view
    |> form(form, %{"doc" => %{"sdm" => "b"}})
    |> render_change(%{"_target" => ["doc", "sdm"]})

    assert stored(c, id)["sdm"] == "b"
  end
end
