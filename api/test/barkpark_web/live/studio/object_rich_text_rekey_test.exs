defmodule BarkparkWeb.Studio.ObjectRichTextRekeyTest do
  @moduledoc """
  A page without bp-rt-remote.js, after another editor's save gives the
  object that owns a rich text a new `_key`: the editor's wrapper id carries
  that key (`CompositeField`, `bp-rt-sub-…`), so the page remounts it and
  shows the value taken. A post with no `_bp_rt_seen` is then read against
  that value, not the one first drawn (task-c29534c0655f0489, #28896 r2
  review S1), but only when it names the owner key the remount drew
  (`_bp_rt_owner[]`, inside the ignored wrapper). A post typed on the old
  mount while the remount was on its way names the old key and is read as
  before: held or merged, never written over B (#28951 r1 review, B1).
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

  # The owner keys the page posts, as drawn.
  defp owners(view) do
    ~r/name="_bp_rt_owner\[\]" value="([^"]*)"/
    |> Regex.scan(render(view))
    |> Enum.map(fn [_, v] -> v |> String.replace("&quot;", "\"") |> Jason.decode!() end)
  end

  defp owner_of(name, key), do: Jason.encode!([name, key])

  # The page's own owner keys, as a post carries them, typed on `key`.
  defp typed_on(key),
    do: %{"_bp_rt_owner" => [owner_of("doc[meta].rt", key), owner_of("doc[meta].rt2", key)]}

  # A post as a page with no owner input sends it: the event alone, no form
  # values from the page (`render_change` on the form would add them).
  defp raw_post(a, how, fields) do
    %{editor_doc: d, dataset: ds} = :sys.get_state(a.pid).socket.assigns

    params = %{
      "_bp_doc" => BarkparkWeb.Studio.StudioLive.PostIdentity.value(ds, d.type, d.doc_id),
      "_target" => ["doc", "meta", "rt"],
      "doc" => %{"title" => "T0", "meta" => %{"label" => "l0", "rt" => fields}}
    }

    render_hook(a, if(how == :auto, do: "autosave", else: "save"), params)
  end

  # B rewrites `meta` with a new `_key`: A's wrapper remounts on B's value.
  defp rekeyed(c, key \\ "m2", blocks \\ rt2("one two", "anchor B")) do
    put_meta(c, &Map.put(&1, "rt", rt2("one two", "anchor")))
    a = open(c)
    w0 = wraps(a)["doc[meta].rt"]
    assert ["doc[meta].rt", nil] in owners(a)
    rekey(c, a, key, blocks)
    refute wraps(a)["doc[meta].rt"] == w0
    a
  end

  defp rekey(c, a, key, blocks) do
    put_meta(c, &(&1 |> Map.put("_key", key) |> Map.put("rt", blocks)))
    want = words(blocks)
    assert eventually(fn -> words(form(a)["meta"]["rt"]) == want end)
    assert ["doc[meta].rt", key] in owners(a)
  end

  for surface <- [:desk, :studio], how <- [:auto, :save] do
    @tag timeout: 120_000
    test "#{surface} #{how}: after a new owner _key, A types next to B's edit: merged, no banner",
         c do
      c = Map.put(c, :surface, unquote(surface))
      a = rekeyed(c)

      post = Map.merge(rt_post(PT.to_html(rt2("one two", "anchor B more"))), typed_on("m2"))
      html = a_posts(a, unquote(how), post)

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

      post = Map.merge(rt_post(PT.to_html(rt2("one two", "anchor B more"))), typed_on("m2"))
      a_posts(a, unquote(how), post)

      assert Enum.at(words(stored(c)["meta"]["rt"]), 1) =~ "BB"
      assert held(a) == ["doc[meta].rt"]
    end

    @tag timeout: 120_000
    test "#{surface} #{how}: two posts on the new mount, B writes between: the second reads A's first",
         c do
      c = Map.put(c, :surface, unquote(surface))
      a = rekeyed(c)

      first = Map.merge(rt_post(PT.to_html(rt2("one two", "anchor B more"))), typed_on("m2"))
      a_posts(a, unquote(how), first)
      assert words(stored(c)["meta"]["rt"]) == ["one two", "anchor B more"]

      # B edits the other block; A's page took it into the form only.
      put_meta(c, &Map.put(&1, "rt", rt2("ONE two", "anchor B more")))
      assert eventually(fn -> words(form(a)["meta"]["rt"]) == ["ONE two", "anchor B more"] end)

      second = Map.merge(rt_post(PT.to_html(rt2("one two", "anchor B more!"))), typed_on("m2"))
      html = a_posts(a, unquote(how), second)

      assert words(stored(c)["meta"]["rt"]) == ["ONE two", "anchor B more!"]
      refute html =~ @banner
      assert held(a) == []
    end

    # #28951 r1 review, B1: posts typed on the old mount, sent while the
    # remount was on its way. Each names the old owner key ("").
    @tag timeout: 120_000
    test "#{surface} #{how}: typed on the old mount next to B's edit (same block): held", c do
      c = Map.put(c, :surface, unquote(surface))
      a = rekeyed(c)

      post = Map.merge(rt_post(PT.to_html(rt2("one two", "anchor more"))), typed_on(""))
      a_posts(a, unquote(how), post)

      assert Enum.at(words(stored(c)["meta"]["rt"]), 1) =~ "B"
      assert held(a) == ["doc[meta].rt"]
    end

    @tag timeout: 120_000
    test "#{surface} #{how}: typed on the old mount in a block B left: merged with B's", c do
      c = Map.put(c, :surface, unquote(surface))
      a = rekeyed(c)

      post = Map.merge(rt_post(PT.to_html(rt2("ONE two", "anchor"))), typed_on(""))
      a_posts(a, unquote(how), post)

      assert words(stored(c)["meta"]["rt"]) == ["ONE two", "anchor B"]
    end

    @tag timeout: 120_000
    test "#{surface} #{how}: two re-keys, typed on the first: held, B's second edit kept", c do
      c = Map.put(c, :surface, unquote(surface))
      a = rekeyed(c)
      rekey(c, a, "m3", rt2("one two", "anchor BB"))

      post = Map.merge(rt_post(PT.to_html(rt2("one two", "anchor B more"))), typed_on("m2"))
      a_posts(a, unquote(how), post)

      assert Enum.at(words(stored(c)["meta"]["rt"]), 1) =~ "BB"
      assert held(a) == ["doc[meta].rt"]
    end

    @tag timeout: 120_000
    test "#{surface} #{how}: two re-keys, typed on the newest: merged, no banner", c do
      c = Map.put(c, :surface, unquote(surface))
      a = rekeyed(c)
      rekey(c, a, "m3", rt2("one two", "anchor BB"))

      post = Map.merge(rt_post(PT.to_html(rt2("one two", "anchor BB more"))), typed_on("m3"))
      html = a_posts(a, unquote(how), post)

      assert words(stored(c)["meta"]["rt"]) == ["one two", "anchor BB more"]
      refute html =~ @banner
    end

    # A post with no owner key, or one naming a key never drawn, is the old
    # mount: read as before, so B's edit is never written over.
    @tag timeout: 120_000
    test "#{surface} #{how}: no owner key (a page without the input): read as before, B's kept",
         c do
      c = Map.put(c, :surface, unquote(surface))
      a = rekeyed(c)

      raw_post(a, unquote(how), PT.to_html(rt2("one two", "anchor B more")))

      assert Enum.at(words(stored(c)["meta"]["rt"]), 1) =~ "anchor B"
      assert held(a) == ["doc[meta].rt"]
    end

    for {label, owner} <- [
          {"a forged owner key",
           %{"_bp_rt_owner" => [~s(["doc[meta].rt","zz"]), ~s(["doc[meta].rt2","zz"])]}},
          {"an owner entry that is not JSON",
           %{"_bp_rt_owner" => ["doc[meta].rt|m2", "doc[meta].rt2|m2"]}}
        ] do
      @tag timeout: 120_000
      test "#{surface} #{how}: #{label}: read against the old value, B's kept", c do
        c = Map.put(c, :surface, unquote(surface))
        a = rekeyed(c)

        post =
          Map.merge(
            rt_post(PT.to_html(rt2("one two", "anchor B more"))),
            unquote(Macro.escape(owner))
          )

        a_posts(a, unquote(how), post)

        assert Enum.at(words(stored(c)["meta"]["rt"]), 1) =~ "anchor B"
        assert held(a) == ["doc[meta].rt"]
      end
    end
  end
end
