defmodule BarkparkWeb.Studio.ObjectRichTextUntouchedPostTest do
  # task-fb6ef831bfd65946, from the #28896 review (N1, N2s). A page without
  # bp-rt-remote.js posts an object's rich text as it was drawn, with no
  # `_bp_rt_seen`. Before #28896 such a post was read from the socket's
  # newest value:
  #
  #   * N1: a Studio Save that changed only the label posted the rich text
  #     untouched, as drawn at mount, and wrote it over B's newer one, with
  #     no banner;
  #   * N2s: B's write to the same block already taken by A's socket, A then
  #     typed on the old value it shows: A's words written over B's, with no
  #     banner.
  #
  # #28896 reads such a post against the value its page shows. These pin it.
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  alias Barkpark.Content
  alias Barkpark.Content.PortableText

  @rb "Someone else rewrote"

  setup %{conn: conn}, do: {:ok, setup_doc(conn)}

  defp put_rt(c, value) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, "production")
    content = put_in(doc.content || %{}, [Access.key("meta", %{}), "rt"], value)

    {:ok, _} =
      Content.upsert_document(
        c.type,
        %{"doc_id" => "drafts." <> c.id, "title" => doc.title, "content" => content},
        "production"
      )
  end

  defp rt2(t1, t2), do: [block("k1", t1), block("k2", t2)]
  defp held(a), do: Map.keys(:sys.get_state(a.pid).socket.assigns[:editor_rt_held] || %{})

  defp save(a, fields),
    do:
      a
      |> element("#editor-form")
      |> render_submit(Map.merge(%{"doc" => %{"title" => "T0"}}, fields))

  # B's write to the rich text, taken by A's socket before A posts.
  defp b_writes_first(c) do
    put_rt(c, rt2("one two", "anchor"))
    a = open(c)
    put_rt(c, rt2("one twB", "anchor"))
    assert eventually(fn -> words(form(a)["meta"]["rt"]) == ["one twB", "anchor"] end)
    a
  end

  # N1 and N1L Studio Save: a Save posts the whole form, so the two are one
  # post. A label autosave (N1L autosave) kept B's on main too.
  test "studio: a Save that changed only the label keeps B's rich text, no banner", c do
    c = Map.put(c, :surface, :studio)
    a = b_writes_first(c)
    untouched = PortableText.to_html(rt2("one two", "anchor"))

    # Before #28896: stored ["one two", "anchor"], B's word gone.
    h = save(a, %{"doc[meta].label" => "l0 A", "doc[meta].rt" => untouched})

    assert eventually(fn -> stored(c)["meta"]["label"] == "l0 A" end)
    assert words(stored(c)["meta"]["rt"]) == ["one twB", "anchor"]
    refute h =~ @rb
  end

  for surface <- [:desk, :studio], how <- [:auto, :save] do
    test "#{surface} #{how}: A types on the old value after B's same-block write was taken: B's kept, A held",
         c do
      c = Map.put(c, :surface, unquote(surface))
      a = b_writes_first(c)

      fields = %{
        "doc[meta].label" => "l0",
        "doc[meta].rt" => PortableText.to_html(rt2("one twA", "anchor"))
      }

      # Before #28896: stored ["one twA", "anchor"], no banner.
      h =
        if unquote(how) == :auto,
          do: send_post(a, "doc[meta].rt", fields),
          else: save(a, fields)

      assert words(stored(c)["meta"]["rt"]) == ["one twB", "anchor"]
      assert h =~ @rb
      assert held(a) == ["doc[meta].rt"]
    end
  end
end
