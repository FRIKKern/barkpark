defmodule BarkparkWeb.Studio.ObjectRichTextRekeyTest do
  @moduledoc """
  A page without bp-rt-remote.js, after another editor's save gives the
  object that owns a rich text a new `_key`: the editor's wrapper id carries
  that key (`CompositeField`, `bp-rt-sub-…`), so the page remounts it and
  shows the value taken. A post with no `_bp_rt_seen` is then read against
  that value, not the one first drawn (task-c29534c0655f0489, #28896 r2
  review S1).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  alias Barkpark.Content
  alias Barkpark.Content.PortableText, as: PT

  @banner "Someone else rewrote"

  setup %{conn: conn}, do: setup_doc(conn)

  defp put_meta(c, f) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, "production")
    content = Map.update(doc.content || %{}, "meta", %{}, f)

    {:ok, _} =
      Content.upsert_document(
        c.type,
        %{"doc_id" => "drafts." <> c.id, "title" => doc.title, "content" => content},
        "production"
      )
  end

  defp rt2(t1, t2), do: [block("k1", t1), block("k2", t2)]
  defp held(a), do: Map.keys(:sys.get_state(a.pid).socket.assigns[:editor_rt_held] || %{})

  defp a_posts(a, :auto, fields), do: send_post(a, "doc[meta].rt", fields)

  defp a_posts(a, :save, fields),
    do:
      a
      |> element("#editor-form")
      |> render_submit(Map.merge(%{"doc" => %{"title" => "T0"}}, fields))

  defp rt_post(html), do: %{"doc[meta].label" => "l0", "doc[meta].rt" => html}

  # B rewrites `meta` with a new `_key`: A's wrapper remounts on B's value.
  defp rekeyed(c) do
    put_meta(c, &Map.put(&1, "rt", rt2("one two", "anchor")))
    a = open(c)
    w0 = wraps(a)["doc[meta].rt"]
    put_meta(c, &(&1 |> Map.put("_key", "m2") |> Map.put("rt", rt2("one two", "anchor B"))))
    assert eventually(fn -> words(form(a)["meta"]["rt"]) == ["one two", "anchor B"] end)
    refute wraps(a)["doc[meta].rt"] == w0
    a
  end

  for surface <- [:desk, :studio], how <- [:auto, :save] do
    @tag timeout: 120_000
    test "#{surface} #{how}: after a new owner _key, A types next to B's edit: merged, no banner",
         c do
      c = Map.put(c, :surface, unquote(surface))
      a = rekeyed(c)

      html = a_posts(a, unquote(how), rt_post(PT.to_html(rt2("one two", "anchor B more"))))

      assert words(stored(c)["meta"]["rt"]) == ["one two", "anchor B more"]
      refute html =~ @banner
      assert held(a) == []
    end

    @tag timeout: 120_000
    test "#{surface} #{how}: after the remount, B's next write under the same key is still held",
         c do
      c = Map.put(c, :surface, unquote(surface))
      a = rekeyed(c)
      put_meta(c, &Map.put(&1, "rt", rt2("one two", "anchor BB")))
      assert eventually(fn -> words(form(a)["meta"]["rt"]) == ["one two", "anchor BB"] end)

      a_posts(a, unquote(how), rt_post(PT.to_html(rt2("one two", "anchor B more"))))

      assert Enum.at(words(stored(c)["meta"]["rt"]), 1) =~ "BB"
      assert held(a) == ["doc[meta].rt"]
    end
  end
end
