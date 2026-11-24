defmodule BarkparkWeb.BulldocsBpmlListItemWallTest do
  @moduledoc """
  The write wall read per list item (`Bpml.WriteWall.Items`,
  task-0b448ea0847a6b4f), through the routes bp calls. An item that is still
  there, with its id, in the same block, its unshown keys carried byte for
  byte from the stored copy, loses nothing, so it is not refused. Every other
  change to a block holding unshown content is refused as the block rule says.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Content
  alias Barkpark.LabelFixtures
  alias Barkpark.PortableDoc.Bpml.WriteWall
  alias Barkpark.Repo

  @token "barkpark-test-ingest-token"
  @ingest_path "/v1/plugins/bulldocs/papers"

  defp text(value), do: [%{"type" => "text", "value" => value}]
  defp p(id, value), do: %{"id" => id, "type" => "paragraph", "content" => text(value)}
  defp list(id, items), do: %{"id" => id, "type" => "list", "items" => items}

  # Item "a" holds a key BPML cannot write and words the reader does not show
  # (`text` beside `content`); item "c" holds another such key.
  @a %{
    "id" => "a",
    "content" => [%{"type" => "text", "value" => "Alpha"}],
    "text" => "Inactive words",
    "audit" => %{"by" => "ed", "n" => [1, 2]}
  }
  @c %{"id" => "c", "content" => [%{"type" => "text", "value" => "Gamma"}], "note" => "kept note"}

  defp blocks do
    [
      p("p1", "Opening."),
      list("l1", [@a, text("Beta"), @c]),
      list("l2", [%{"id" => "z", "content" => text("Zeta")}]),
      p("p2", "Closing.")
    ]
  end

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer #{@token}")
    |> put_req_header("content-type", "application/json")
  end

  defp pulled_with(blocks) do
    slug = "list-item-wall-#{System.unique_integer([:positive])}"

    {:ok, paper} =
      Content.upsert_paper(LabelFixtures.paper_attrs(%{slug: slug, blocks: [p("seed", "Seed.")]}))

    content = paper.content |> Map.put("blocks", blocks) |> Map.delete("body_html")
    paper |> Ecto.Changeset.change(content: content) |> Repo.update!()

    conn = get(scoped_conn(), "/papers/#{slug}/source", %{"format" => "bpml"})
    [rev] = get_resp_header(conn, "x-paper-rev")
    [view] = get_resp_header(conn, "x-bpml-view")
    {slug, response(conn, 200), {rev, view}}
  end

  defp push_copy(slug, bpml, {rev, view}) do
    scoped_conn()
    |> authed()
    |> post("#{@ingest_path}/#{slug}/sync", %{
      "bpml" => bpml,
      "baseRev" => rev,
      "bpmlView" => view
    })
  end

  defp stored(slug), do: get_in(Content.get_paper(slug).content, ["blocks"])
  defp stored_block(slug, id), do: Enum.find(stored(slug), &(&1["id"] == id))

  defp replace!(bpml, from, to) do
    assert bpml =~ from
    String.replace(bpml, from, to)
  end

  @li_a ~s(    <li id="a">Alpha</li>\n)

  test "row 1: an id'd item with unshown keys survives an edit elsewhere in its list" do
    {slug, bpml, anchor} = pulled_with(blocks())

    assert %{"ok" => true} =
             push_copy(slug, replace!(bpml, "Beta", "Beta, edited"), anchor) |> json_response(200)

    assert stored_block(slug, "l1")["items"] == [@a, text("Beta, edited"), @c]
  end

  test "row 2: an id'd item with unshown keys takes an edit to its own shown words" do
    {slug, bpml, anchor} = pulled_with(blocks())

    assert %{"ok" => true} =
             push_copy(slug, replace!(bpml, "Alpha", "Alpha, edited"), anchor)
             |> json_response(200)

    assert [a, _beta, c] = stored_block(slug, "l1")["items"]
    assert a == %{@a | "content" => text("Alpha, edited")}
    assert c == @c
  end

  test "row 3: deleting an id'd item with unshown keys is refused, naming its paths" do
    {slug, bpml, anchor} = pulled_with(blocks())
    before = stored(slug)

    answer = push_copy(slug, replace!(bpml, @li_a, ""), anchor) |> json_response(422)

    assert answer["error"]["code"] == WriteWall.code()
    assert answer["error"]["message"] =~ ~s(block "l1")
    # Item "c" is still there with its id and its key, so only "a"'s paths.
    assert answer["error"]["paths"] == ["blocks[1].items[0].audit", "blocks[1].items[0].text"]
    assert stored(slug) == before
  end

  test "row 4: moving an id'd item with unshown keys to another block is refused" do
    {slug, bpml, anchor} = pulled_with(blocks())
    before = stored(slug)

    moved =
      bpml
      |> replace!(@li_a, "")
      |> replace!(~s(    <li id="z">Zeta</li>\n), ~s(    <li id="z">Zeta</li>\n) <> @li_a)

    answer = push_copy(slug, moved, anchor) |> json_response(422)

    assert answer["error"]["code"] == WriteWall.code()
    assert answer["error"]["message"] =~ ~s(block "l1")
    assert "blocks[1].items[0].audit" in answer["error"]["paths"]
    assert stored(slug) == before
  end

  test "row 5: the same item id twice in the pushed copy is refused" do
    {slug, bpml, anchor} = pulled_with(blocks())
    before = stored(slug)

    answer = push_copy(slug, replace!(bpml, @li_a, @li_a <> @li_a), anchor) |> json_response(422)

    assert answer["error"]["code"] == "bpml"
    assert answer["error"]["message"] =~ ~s(list item id "a" appears more than once)
    assert stored(slug) == before
  end

  # Such an item prints its whole block as one <kept> line; writing the
  # block out in its place is refused as before this rule.
  test "row 6: an item with unshown keys and no id keeps its block refused on edit" do
    kept = list("k1", [%{"content" => text("Hidden key"), "audit" => 1}, text("Plain")])
    {slug, bpml, anchor} = pulled_with([p("p1", "Opening."), kept])
    before = stored(slug)
    [line] = Regex.run(~r{  <kept id="k1"[^\n]*\n}, bpml)

    written = """
      <ul id="k1">
        <li>Hidden key, edited</li>
        <li>Plain</li>
      </ul>
    """

    answer = push_copy(slug, replace!(bpml, line, written), anchor) |> json_response(422)

    assert answer["error"]["code"] == "bpml_kept"
    assert answer["error"]["message"] =~ "k1 was pulled as <kept>"
    assert stored(slug) == before
  end

  test "a children entry that is not a list is not carried, so an edit to its item is refused" do
    aside = %{"type" => "paragraph", "content" => text("Aside")}
    item = %{"id" => "n", "content" => text("Note holder"), "children" => [aside]}
    {slug, bpml, anchor} = pulled_with([p("p1", "Opening."), list("n1", [item])])
    before = stored(slug)

    answer =
      push_copy(slug, replace!(bpml, "Note holder", "Note holder, edited"), anchor)
      |> json_response(422)

    assert answer["error"]["code"] == WriteWall.code()
    assert answer["error"]["paths"] == ["blocks[1].items[0].children"]
    assert stored(slug) == before
  end

  # The unshown keys belong to the id, not to the place or the words: two
  # items that swap ids swap what they carry. Each id still names one stored
  # item, in its own block, and every key the pull did not show comes back
  # byte for byte under that id, so nothing stored is lost.
  test "row 7: two items that swap ids each carry the unshown keys of the id they now hold" do
    {slug, bpml, anchor} = pulled_with(blocks())

    swapped =
      bpml
      |> replace!(~s(<li id="a">Alpha</li>), ~s(<li id="TMP">Alpha</li>))
      |> replace!(~s(<li id="c">Gamma</li>), ~s(<li id="a">Gamma</li>))
      |> replace!(~s(<li id="TMP">Alpha</li>), ~s(<li id="c">Alpha</li>))

    assert %{"ok" => true} = push_copy(slug, swapped, anchor) |> json_response(200)

    assert [c, _beta, a] = stored_block(slug, "l1")["items"]
    assert c == %{@c | "content" => text("Alpha")}
    assert a == %{@a | "content" => text("Gamma")}
  end
end
