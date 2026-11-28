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

  defp b2(c), do: set2(c, [block("k9", "B2")])

  # B's write through the store, as `/v1` or an import makes it.
  defp set2(c, value) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, "production")

    {:ok, _} =
      Content.upsert_document(
        c.type,
        %{
          "doc_id" => "drafts." <> c.id,
          "title" => doc.title,
          "content" => Map.put(doc.content, "body2", value)
        },
        "production"
      )
  end

  defp first_words(c, surface, b_value) do
    add_field(c, "body2", %{"format" => "portableText"})
    a = tab(c, surface)
    seen = page(a)

    html =
      inside(a, fn -> Task.await(Task.async(fn -> set2(c, b_value) end)) end, fn ->
        types_f(a, "body2", "<p>A2</p>", seen)
      end)

    {a, html}
  end

  defp body2(c), do: stored(c)["body2"]
  defp held(a), do: Map.keys(:sys.get_state(a.pid).socket.assigns[:editor_rt_held] || %{})

  defp save_f(view, name, html, seen) do
    view
    |> element("#editor-form")
    |> render_submit(%{
      "doc" => %{"title" => "T0", name => html},
      "_bp_seen" => Jason.encode!(seen)
    })
  end

  defp snap2(a) do
    case BarkparkWeb.Studio.StudioLive.Handlers.Lifecycle.base_doc(:sys.get_state(a.pid).socket) do
      %{content: %{} = content} -> content["body2"]
      _ -> nil
    end
  end

  defp took2?(a),
    do: is_list((:sys.get_state(a.pid).socket.assigns[:editor_rt_took] || %{})["doc[body2]"])

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

    # P3 (#29177 review): a store with no words is read as empty. Barkpark's
    # own editors never store that shape; a `/v1` or import writer can.
    for {shape, value} <- [
          {"one wordless block", [block("e0", "")]},
          {"two wordless blocks", [block("e0", ""), block("e1", "")]}
        ] do
      @value value
      test "#{surface} P3: B stores #{shape} inside A's first words: A written, no hold", c do
        {a, html} = first_words(c, @surface, @value)

        # Before: the wordless store kept, A held with the banner.
        assert words(body2(c) || []) == ["A2"],
               "A's first words were not written: #{inspect(body2(c))}"

        assert held(a) == []
        refute html =~ "doc-conflict-banner"
      end
    end

    test "#{surface} P3 control: B stores an image with no words: B's image is kept", c do
      image = %{"_type" => "image", "_key" => "i9", "asset" => %{"_ref" => "image-x"}}
      {_a, _html} = first_words(c, @surface, [image])

      assert Enum.any?(body2(c) || [], &(&1["_key"] == "i9")),
             "B's image was lost: #{inspect(body2(c))}"
    end
  end

  # #29292 r1 review (W_wordless): A's page showed B's words; B cleared the
  # field, and a `/v1` writer stored a wordless block inside A's stale post.
  # The wordless store is B's clear, not an empty field: A is held.
  for surface <- [:desk, :studio], how <- ["autosave", "save"] do
    @surface surface
    @how how

    test "#{surface} #{how} W_wordless: A's page showed words, the store is a wordless clear: B kept, A held",
         c do
      add_field(c, "body2", %{"format" => "portableText"})
      a = tab(c, @surface)
      set2(c, [block("k9", "B1")])
      assert eventually(fn -> words(snap2(a) || []) == ["B1"] end)
      render(a)
      seen = page(a)
      set2(c, [])
      assert eventually(fn -> took2?(a) end)

      post = if @how == "save", do: &save_f/4, else: &types_f/4

      html =
        inside(a, fn -> Task.await(Task.async(fn -> set2(c, [block("k9", "")]) end)) end, fn ->
          post.(a, "body2", "<p>B1 A</p>", seen)
        end)

      # Before (desk Save): ["B1 A"], B's clear written over with no banner.
      assert words(body2(c)) == [""], "B's clear was written over: #{inspect(words(body2(c)))}"
      assert held(a) == ["doc[body2]"]
      assert html =~ "doc-conflict-banner"
    end
  end
end
