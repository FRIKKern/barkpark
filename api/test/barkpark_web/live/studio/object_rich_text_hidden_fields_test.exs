defmodule BarkparkWeb.Studio.ObjectRichTextHiddenFieldsTest do
  @moduledoc """
  task-6174d8fa01658a68 (#28858 review, L1): `ObjectRebase.rich_text/4`
  wrote mine when what the tab saw drew the same as the store. A block
  field B set during A's autosave (`level`, an unknown field) draws the
  same, so A's post wrote over it and the field was lost with no banner.
  Lifted from the reviewer's probes (L0-L6).
  """
  use BarkparkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText
  alias Barkpark.Content
  @rb "Someone else rewrote"

  setup %{conn: conn} do
    c =
      setup_doc(conn)
      |> then(fn
        {:ok, x} -> Map.new(x)
        x -> Map.new(x)
      end)

    rt = [
      Map.put(block("k1", "one two"), "level", 1),
      Map.put(block("k2", "three four"), "foo", "bar")
    ]

    api(c, fn meta -> Map.put(meta, "rt", rt) end)
    {:ok, c}
  end

  # B as an API client: read the doc, change meta, write the draft.
  defp api(c, f) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, "production")
    content = Map.update(doc.content || %{}, "meta", %{}, f)

    {:ok, _} =
      Content.upsert_document(
        c.type,
        %{"doc_id" => "drafts." <> c.id, "title" => doc.title, "content" => content},
        "production"
      )

    :ok
  end

  defp setlevel(c, key, lvl),
    do:
      api(c, fn m ->
        Map.update!(m, "rt", fn bl ->
          Enum.map(bl, &if(&1["_key"] == key, do: Map.put(&1, "level", lvl), else: &1))
        end)
      end)

  defp rtb(c), do: stored(c)["meta"]["rt"]

  defp save(view, html, seen) do
    view
    |> element("#editor-form")
    |> render_submit(%{
      "doc" => %{"title" => "T0"},
      "doc[meta].label" => "l0",
      "doc[meta].rt" => html,
      "doc[meta].rt2" => "<p>second</p>",
      "_bp_rt_seen" => ["doc[meta].rt|#{seen}", "doc[meta].rt2|0"]
    })
  end

  defp drain(view, acc \\ %{}) do
    {ref, _, _} = view.proxy

    receive do
      {^ref, {:push_event, "bp:rt-remote", %{values: vs}}} -> drain(view, Map.merge(acc, vs))
      {^ref, {:push_event, _, _}} -> drain(view, acc)
    after
      300 -> acc
    end
  end

  defp seq(view), do: (drain(view)["doc[meta].rt"] || %{})[:seq] || 0
  defp html_now(c), do: Barkpark.Content.PortableText.to_html(rtb(c))

  for surface <- [:desk, :studio] do
    test "#{surface} L0 the page's html round-trips the hidden fields", c do
      c = Map.put(c, :surface, unquote(surface))
      a = open(c)
      s = seq(a)
      h = post_rt(a, html_now(c), s)
      assert Enum.at(rtb(c), 0)["level"] == 1 and Enum.at(rtb(c), 1)["foo"] == "bar"
      refute h =~ @rb
    end

    test "#{surface} L1 autosave of k1 while an API write sets k2 level inside", c do
      c = Map.put(c, :surface, unquote(surface))
      a = open(c)
      s = seq(a)

      h =
        inside(a, fn -> setlevel(c, "k2", 3) end, fn ->
          post_rt(a, "<p>ONE two</p><p>three four</p>", s)
        end)

      assert words(rtb(c)) == ["ONE two", "three four"]
      assert Enum.at(rtb(c), 1)["level"] == 3 and Enum.at(rtb(c), 1)["foo"] == "bar"
      refute h =~ @rb
    end

    test "#{surface} L2 Save of k1 while an API write sets k2 level inside", c do
      c = Map.put(c, :surface, unquote(surface))
      a = open(c)
      s = seq(a)

      h =
        inside(a, fn -> setlevel(c, "k2", 3) end, fn ->
          save(a, "<p>ONE two</p><p>three four</p>", s)
        end)

      assert words(rtb(c)) == ["ONE two", "three four"]
      assert Enum.at(rtb(c), 1)["level"] == 3
      refute h =~ @rb
    end

    test "#{surface} L3 API sets k2 level (not inside); A's page posts on its old seen", c do
      c = Map.put(c, :surface, unquote(surface))
      a = open(c)
      s = seq(a)
      setlevel(c, "k2", 3)
      Process.sleep(200)
      _ = drain(a)
      _ = post_rt(a, "<p>ONE two</p><p>three four</p>", s)
      assert Enum.at(rtb(c), 1)["level"] == 3
      assert words(rtb(c)) == ["ONE two", "three four"]
    end

    test "#{surface} L4 B's page edits k2 inside A's autosave of k1: words and fields", c do
      c = Map.put(c, :surface, unquote(surface))
      {a, b} = {open(c), open(c)}
      s = seq(a)
      _ = seq(b)

      h =
        b_saves_inside(a, b, "<p>one two</p><p>three FOUR</p>", fn ->
          post_rt(a, "<p>ONE two</p><p>three four</p>", s)
        end)

      assert words(rtb(c)) == ["ONE two", "three FOUR"]
      refute h =~ @rb
    end

    test "#{surface} L5 API sets level, Reload, then A posts", c do
      c = Map.put(c, :surface, unquote(surface))
      a = open(c)
      _ = seq(a)
      setlevel(c, "k2", 3)
      Process.sleep(200)
      _ = drain(a)
      render_hook(a, "reload-remote-doc", %{})
      s2 = seq(a)
      _ = post_rt(a, "<p>ONE two</p><p>three four</p>", s2)
      assert Enum.at(rtb(c), 1)["level"] == 3
    end

    test "#{surface} L6 an API write sets k2 level before A's post on its old seen", c do
      c = Map.put(c, :surface, unquote(surface))
      a = open(c)
      s = seq(a)
      setlevel(c, "k2", 3)
      h = post_rt(a, "<p>ONE two</p><p>three four</p>", s)
      assert words(rtb(c)) == ["ONE two", "three four"]
      assert Enum.at(rtb(c), 1)["level"] == 3 and Enum.at(rtb(c), 1)["foo"] == "bar"
      refute h =~ @rb
    end
  end
end
