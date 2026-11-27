defmodule BarkparkWeb.Studio.TopRichTextEmptyRaceTest do
  @moduledoc """
  task-fe3cbbb28707625d (#29148 review, H2). A Portable Text field is empty.
  A types its first words; B fills the field and saves inside A's post,
  before A's write.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  alias Barkpark.Content
  alias BarkparkWeb.PageSeen

  @moduletag :studio_live

  setup %{conn: conn} do
    c = setup_doc(conn)
    {:ok, schema} = Content.get_schema(c.type, "production")

    fields =
      Enum.map(schema.fields, fn
        %{"name" => "body"} = f -> Map.put(f, "format", "portableText")
        f -> f
      end)

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => c.type,
          "title" => "Object rich text",
          "visibility" => "public",
          "fields" => fields
        },
        "production"
      )

    c
  end

  defp tab(c, surface) do
    path =
      case surface do
        :desk -> "#{c.root}/_desk/#{c.type};#{c.id}"
        :studio -> "#{c.root}/#{c.type}/#{c.id}"
      end

    {:ok, view, _html} = live(c.conn, path)
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#editor-form") end)
    view
  end

  defp page(view), do: view |> PageSeen.seen() |> Map.put("v", 2)

  defp add_field(c, name, extra) do
    {:ok, schema} = Content.get_schema(c.type, "production")
    f = Map.merge(%{"name" => name, "title" => name, "type" => "richText"}, extra)

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => c.type,
          "title" => "Object rich text",
          "visibility" => "public",
          "fields" => schema.fields ++ [f]
        },
        "production"
      )
  end

  defp types_f(view, name, html, seen) do
    view
    |> element("#editor-form")
    |> render_change(%{
      "_target" => ["doc[#{name}]"],
      "doc" => %{"title" => "T0", name => html},
      "_bp_seen" => Jason.encode!(seen)
    })
  end

  defp b2(c) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, "production")

    {:ok, _} =
      Content.upsert_document(
        c.type,
        %{
          "doc_id" => "drafts." <> c.id,
          "title" => doc.title,
          "content" => Map.put(doc.content, "body2", [block("k9", "B2")])
        },
        "production"
      )
  end

  defp body2(c), do: stored(c)["body2"]
  defp held(a), do: Map.keys(:sys.get_state(a.pid).socket.assigns[:editor_rt_held] || %{})

  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface} H2: B fills the empty field inside A's first words in it: B kept, A held",
         c do
      add_field(c, "body2", %{"format" => "portableText"})
      a = tab(c, @surface)
      seen = page(a)

      html =
        inside(a, fn -> Task.await(Task.async(fn -> b2(c) end)) end, fn ->
          types_f(a, "body2", "<p>A2</p>", seen)
        end)

      # Before: ["A2"] written, B's words lost, no banner.
      assert words(body2(c) || []) == ["B2"],
             "A's post was written over B's: #{inspect(body2(c))}"

      assert html =~ "doc-conflict-banner"
    end

    test "#{surface} control: A alone types its first words in the empty field: written", c do
      add_field(c, "body2", %{"format" => "portableText"})
      a = tab(c, @surface)

      html = types_f(a, "body2", "<p>A2</p>", page(a))

      assert words(body2(c) || []) == ["A2"]
      assert held(a) == []
      refute html =~ "doc-conflict-banner"
    end
  end
end
