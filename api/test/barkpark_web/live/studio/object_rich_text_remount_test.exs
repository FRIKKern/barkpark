defmodule BarkparkWeb.Studio.ObjectRichTextRemountTest do
  @moduledoc """
  task-47be2cdf59d0acd5: rich text inside an object (`meta.rt`) is drawn in
  a `phx-update="ignore"` wrapper, which LiveView never patches. B's save of
  it reached A's form, but A's editor and its hidden input kept the old
  text, so A's next typing in it posted the old blocks with A's change and
  B's paragraph was gone. A top-level rich text editor remounts on a value
  the server replaced (`editor_form_gen` in its wrapper id,
  task-c7b0565a482b9d21); one inside an object now does the same, and only
  when its own text changed.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "obj_rt_mount_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Object rich text",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{
              "name" => "meta",
              "title" => "Meta",
              "type" => "composite",
              "fields" => [
                %{"name" => "label", "title" => "Label", "type" => "string"},
                %{"name" => "rt", "title" => "Body", "type" => "richText"}
              ]
            }
          ]
        },
        @dataset
      )

    id = "obj-rt-mount-#{n}"
    rt = [block("k1", "one two")]

    {:ok, _} =
      Content.create_document(
        type,
        %{
          "doc_id" => id,
          "title" => "T0",
          "content" => %{"meta" => %{"label" => "l0", "rt" => rt}}
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "obj-rt-mount-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "obj-rt-mount", @dataset, ~w(read write admin), ws_id)
    root = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     paths: %{desk: "#{root}/_desk/#{type};#{id}", studio: "#{root}/#{type}/#{id}"},
     type: type,
     id: id}
  end

  defp block(key, text) do
    %{
      "_type" => "block",
      "_key" => key,
      "style" => "normal",
      "markDefs" => [],
      "children" => [%{"_type" => "span", "_key" => key <> "s", "text" => text, "marks" => []}]
    }
  end

  defp open(c) do
    {:ok, view, _html} = live(c.conn, c.paths[c.surface])
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#editor-form") end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp stored(c) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, @dataset)
    doc.content["meta"]
  end

  defp words(blocks) when is_list(blocks),
    do: for(%{"children" => spans} <- blocks, do: Enum.map_join(spans, & &1["text"]))

  # What the page draws for meta.rt: the ignored wrapper's id, and the HTML
  # its hidden input posts (what the editor shows).
  defp editor(view) do
    html = render(view)
    [_, wrap] = Regex.run(~r/<div id="([^"]+)"[^>]*data-pt-subfield="doc\[meta\]\.rt"/, html)

    [_, value] =
      Regex.run(~r/<input[^>]*name="doc\[meta\]\.rt"[^>]*value="([^"]*)"/, html) ||
        Regex.run(~r/<input[^>]*value="([^"]*)"[^>]*name="doc\[meta\]\.rt"/, html)

    {wrap, value |> String.replace("&lt;", "<") |> String.replace("&gt;", ">")}
  end

  defp posts(view, target, label, html) do
    view
    |> element("#editor-form")
    |> render_change(%{
      "_target" => [target],
      "doc" => %{"title" => "T0"},
      "doc[meta].label" => label,
      "doc[meta].rt" => html
    })
  end

  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface}: B edits meta.rt: A's editor shows it, and A's next typing keeps it", c do
      c = Map.put(c, :surface, @surface)
      a = open(c)
      b = open(c)
      {_wrap, shown} = editor(a)
      assert shown == "<p>one two</p>"

      posts(b, "doc[meta].rt", "l0", "<p>one two</p><p>B para</p>")
      assert eventually(fn -> words(stored(c)["rt"]) == ["one two", "B para"] end)

      assert eventually(fn -> elem(editor(a), 1) =~ "B para" end), inspect(editor(a))

      # A types in the editor it sees: its post is what the page shows.
      {_wrap, shown} = editor(a)
      posts(a, "doc[meta].rt", "l0", String.replace(shown, "one two", "one two A"))
      assert eventually(fn -> words(stored(c)["rt"]) == ["one two A", "B para"] end)
    end

    test "#{surface}: B's save of another subfield leaves A's editor mounted", c do
      c = Map.put(c, :surface, @surface)
      a = open(c)
      b = open(c)

      # A's own rich text post: the form rebuilds its blocks with new keys.
      posts(a, "doc[meta].rt", "l0", "<p>one two A</p>")
      assert eventually(fn -> words(stored(c)["rt"]) == ["one two A"] end)
      {wrap, _} = editor(a)

      posts(b, "doc[meta].label", "l0 B", "<p>one two A</p>")
      assert eventually(fn -> stored(c)["label"] == "l0 B" end)
      render(a)

      assert eventually(fn ->
               :sys.get_state(a.pid).socket.assigns.editor_form["meta"]["label"] == "l0 B"
             end)

      # Its text did not change: no remount under A's caret.
      assert {^wrap, _} = editor(a)
    end
  end
end
