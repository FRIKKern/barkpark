defmodule BarkparkWeb.Studio.ObjectRichTextBlockLevelTest do
  @moduledoc """
  task-7654a6a1eb157d03 (#28867 review): `from_html` rebuilt an edited
  block from the page's HTML, which draws no `level` outside a list, so a
  level-1 block with no `listItem` lost its level when A edited its words.
  The edited block keeps the stored block's fields the drawing cannot hold.
  """
  use BarkparkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText
  alias Barkpark.Content
  alias Barkpark.Content.PortableText

  setup %{conn: conn} do
    c =
      setup_doc(conn)
      |> then(fn
        {:ok, x} -> Map.new(x)
        x -> Map.new(x)
      end)

    rt = [
      Map.merge(block("k1", "one two"), %{"level" => 1, "foo" => "bar"}),
      block("k2", "three four")
    ]

    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, "production")
    content = Map.update(doc.content || %{}, "meta", %{"rt" => rt}, &Map.put(&1, "rt", rt))

    {:ok, _} =
      Content.upsert_document(
        c.type,
        %{"doc_id" => "drafts." <> c.id, "title" => doc.title, "content" => content},
        "production"
      )

    {:ok, c}
  end

  defp rtb(c), do: stored(c)["meta"]["rt"]

  defp seq(view) do
    {ref, _, _} = view.proxy

    receive do
      {^ref, {:push_event, "bp:rt-remote", %{values: %{"doc[meta].rt" => %{seq: s}}}}} -> s
    after
      300 -> 0
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

  test "from_html: an edited block with no list keeps the stored level and fields" do
    stored = [Map.put(block("k1", "one two"), "level", 1), block("k2", "three four")]
    [k1, _k2] = PortableText.from_html("<p>ONE two</p><p>three four</p>", stored)
    assert k1["_key"] == "k1" and k1["level"] == 1
    refute Map.has_key?(k1, "listItem")
  end

  test "from_html: a list item made a paragraph drops its level" do
    item = Map.merge(block("k1", "one two"), %{"listItem" => "bullet", "level" => 2})
    [k1] = PortableText.from_html("<p>one two</p>", [item])
    refute Map.has_key?(k1, "listItem")
    refute Map.has_key?(k1, "level")
  end

  for surface <- [:desk, :studio], how <- [:auto, :save] do
    test "#{surface} #{how}: A edits the words of a level-1 block with no list; it keeps level 1",
         c do
      c = Map.put(c, :surface, unquote(surface))
      a = open(c)
      s = seq(a)
      html = "<p>ONE two</p><p>three four</p>"
      if unquote(how) == :auto, do: post_rt(a, html, s), else: save(a, html, s)

      assert eventually(fn -> words(rtb(c)) == ["ONE two", "three four"] end)
      [k1, _] = rtb(c)
      assert k1["level"] == 1 and k1["foo"] == "bar"
      refute Map.has_key?(k1, "listItem")
    end
  end
end
