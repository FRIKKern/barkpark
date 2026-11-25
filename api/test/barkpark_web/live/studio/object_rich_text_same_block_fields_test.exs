defmodule BarkparkWeb.Studio.ObjectRichTextSameBlockFieldsTest do
  @moduledoc """
  task-6174d8fa01658a68 (#28867 review, B1): A edits a block's words while
  an API write changes a hidden field of that same block. `from_html`
  drops a stored `level` on the block A edited, so the merge clashes and
  the store is kept; `UnderLock.acts/4` read the store as unmoved by the
  drawing and A's words went with no banner. A's words are stored, or held
  with the banner; B's field stays stored. Lifted from the reviewer's probe.
  """
  use BarkparkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText
  alias Barkpark.Content
  @rb "Someone else rewrote"
  setup %{conn: conn},
    do:
      {:ok,
       setup_doc(conn)
       |> then(fn
         {:ok, x} -> Map.new(x)
         x -> Map.new(x)
       end)}

  defp api(c, f) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, "production")
    content = Map.update(doc.content || %{}, "meta", %{}, &Map.update(&1, "rt", [], f))

    {:ok, _} =
      Content.upsert_document(
        c.type,
        %{"doc_id" => "drafts." <> c.id, "title" => doc.title, "content" => content},
        "production"
      )
  end

  defp put_k(c, key, m),
    do: api(c, fn bl -> Enum.map(bl, &if(&1["_key"] == key, do: Map.merge(&1, m), else: &1)) end)

  defp rtb(c), do: stored(c)["meta"]["rt"]

  defp drain(view, acc \\ %{}) do
    {ref, _, _} = view.proxy

    receive do
      {^ref, {:push_event, "bp:rt-remote", %{values: vs}}} -> drain(view, Map.merge(acc, vs))
      {^ref, {:push_event, _, _}} -> drain(view, acc)
    after
      250 -> acc
    end
  end

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

  cases = [
    {"unknown changed", %{"foo" => "bar"}, %{"foo" => "baz"}},
    {"level set, base none", %{}, %{"level" => 3}},
    {"level changed, base level 1 (from_html drops it on edit)", %{"level" => 1}, %{"level" => 3}}
  ]

  for surface <- [:desk, :studio], how <- [:auto, :save], {name, seed, theirs} <- cases do
    test "#{surface} #{how} same block: A edits k2 words, B sets #{name} on k2 inside", c do
      c = Map.put(c, :surface, unquote(surface))

      api(c, fn _ ->
        [
          block("k1", "one two"),
          Map.merge(block("k2", "three four"), unquote(Macro.escape(seed)))
        ]
      end)

      a = open(c)
      s = (drain(a)["doc[meta].rt"] || %{})[:seq] || 0
      html = "<p>one two</p><p>three FOUR</p>"

      post =
        if unquote(how) == :auto,
          do: fn -> post_rt(a, html, s) end,
          else: fn -> save(a, html, s) end

      h = inside(a, fn -> put_k(c, "k2", unquote(Macro.escape(theirs))) end, post)
      held = :sys.get_state(a.pid).socket.assigns[:editor_rt_held] || %{}
      ok_words = words(rtb(c)) == ["one two", "three FOUR"]
      assert ok_words or h =~ @rb, "A's words lost with no banner"
      assert ok_words or Map.has_key?(held, "doc[meta].rt")
      k2 = Enum.find(rtb(c), &(&1["_key"] == "k2"))

      assert Map.take(k2, Map.keys(unquote(Macro.escape(theirs)))) ==
               unquote(Macro.escape(theirs))
    end
  end
end
