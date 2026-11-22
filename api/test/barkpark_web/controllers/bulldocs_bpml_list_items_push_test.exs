defmodule BarkparkWeb.BulldocsBpmlListItemsPushTest do
  @moduledoc """
  `bp paper pull` → edit → `bp paper push` of a Paper with a nested list
  (task-0b448ea0847a6b4f), through the routes bp calls. Every Paper is a
  scratch slug the test writes; the blocks go straight to the row, as the
  paper editor stores them. The print and parse rows are in
  `bpml_list_items_test.exs`.

  A list in the shape a push writes (items as inline arrays, or maps of
  `content` with `id`, `checked` and child lists) takes an edit at any level.
  A list holding a shape the print re-spells or cannot spell (a bare-string
  item, an item with words only in `text`, an alias list type, a key BPML
  cannot write) is refused on edit by `Bpml.WriteWall`, and keeps its bytes.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Content
  alias Barkpark.LabelFixtures
  alias Barkpark.PortableDoc.Bpml.WriteWall
  alias Barkpark.PortableDoc.Validate
  alias Barkpark.Repo

  @token "barkpark-test-ingest-token"
  @ingest_path "/v1/plugins/bulldocs/papers"

  defp text(value), do: [%{"type" => "text", "value" => value}]
  defp p(id, value), do: %{"id" => id, "type" => "paragraph", "content" => text(value)}
  defp list(items), do: %{"type" => "list", "items" => items}
  defp list(id, items), do: %{"id" => id, "type" => "list", "items" => items}

  # Three levels in the shape a push writes: ids, a checked item, an ordered
  # child list.
  defp nested do
    list("l1", [
      %{
        "id" => "plan",
        "content" => text("Plan"),
        "children" => [
          %{
            "type" => "list",
            "ordered" => true,
            "items" => [
              %{"id" => "build", "content" => text("Build"), "children" => [list([text("Verify")])]},
              text("Ship")
            ]
          }
        ]
      },
      text("Flat sibling"),
      %{"id" => "done", "content" => text("Done"), "checked" => true}
    ])
  end

  # The same three levels in older stored shapes and with a key BPML cannot
  # spell (the nested-list-carriers fixture's shapes).
  defp older do
    list("l1", [
      %{
        "id" => "plan",
        "content" => text("Plan"),
        "text" => "Inactive words",
        "audit" => %{"keep" => true},
        "children" => [
          %{
            "type" => "ordered-list",
            "items" => [%{"id" => "build", "text" => "Build", "children" => [list(["Verify"])]}, "Ship"]
          }
        ]
      },
      "Flat sibling"
    ])
  end

  defp blocks(list), do: [p("p1", "Opening."), list, p("p2", "Closing.")]

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer #{@token}")
    |> put_req_header("content-type", "application/json")
  end

  defp with_blocks!(slug, blocks) do
    {:ok, paper} =
      Content.upsert_paper(
        LabelFixtures.paper_attrs(%{
          slug: slug,
          blocks: [%{"id" => "seed", "type" => "paragraph", "content" => text("Seed.")}]
        })
      )

    content = paper.content |> Map.put("blocks", blocks) |> Map.delete("body_html")
    paper |> Ecto.Changeset.change(content: content) |> Repo.update!()
    slug
  end

  defp pull!(slug) do
    conn = get(build_conn(), "/papers/#{slug}/source", %{"format" => "bpml"})
    [rev] = get_resp_header(conn, "x-paper-rev")
    {response(conn, 200), rev}
  end

  defp push_copy(slug, bpml, rev) do
    build_conn()
    |> authed()
    |> post("#{@ingest_path}/#{slug}/sync", %{"bpml" => bpml, "baseRev" => rev})
  end

  defp check(bpml) do
    build_conn()
    |> authed()
    |> post("#{@ingest_path}/validate", %{"bpml" => bpml})
    |> json_response(200)
  end

  defp stored(slug), do: get_in(Content.get_paper(slug).content, ["blocks"])
  defp stored_block(slug, id), do: Enum.find(stored(slug), &(&1["id"] == id))
  defp new_slug, do: "nested-list-#{System.unique_integer([:positive])}"

  defp pulled_with(blocks) do
    slug = with_blocks!(new_slug(), blocks)
    {bpml, rev} = pull!(slug)
    {slug, bpml, rev}
  end

  test "an edit at the third level stores every level and every item id" do
    {slug, bpml, rev} = pulled_with(blocks(nested()))
    assert bpml =~ ~s(<li id="build">Build\n)

    edited = String.replace(bpml, "<li>Verify</li>", "<li>Verify twice</li>")
    assert %{"ok" => true} = push_copy(slug, edited, rev) |> json_response(200)

    expected =
      update_in(
        nested(),
        ["items", Access.at(0), "children", Access.at(0), "items", Access.at(0), "children"],
        fn _ -> [list([text("Verify twice")])] end
      )

    assert stored_block(slug, "l1") == expected
  end

  for {name, list} <- [{"the shape a push writes", :nested}, {"older shapes", :older}] do
    @list list
    test "an unedited push of the three-level list in #{name} stores the same bytes" do
      {slug, bpml, rev} = pulled_with(blocks(fixture(@list)))
      before = stored(slug)

      assert %{"unchanged" => true} = push_copy(slug, bpml, rev) |> json_response(200)
      assert stored(slug) == before
    end
  end

  defp fixture(:nested), do: nested()
  defp fixture(:older), do: older()

  test "an edit elsewhere leaves a list in older shapes byte for byte" do
    {slug, bpml, rev} = pulled_with(blocks(older()))
    before = stored_block(slug, "l1")

    edited = String.replace(bpml, "Closing.", "Closing words.")
    assert %{"ok" => true} = push_copy(slug, edited, rev) |> json_response(200)
    assert stored_block(slug, "l1") == before
  end

  test "a list printed as <kept> keeps its stored bytes when another block is edited" do
    kept = list("k1", [%{"text" => "Hidden key", "audit" => 1}, "Plain"])
    {slug, bpml, rev} = pulled_with([p("p1", "Opening."), kept])
    assert bpml =~ ~s(<kept id="k1" type="list")

    edited = String.replace(bpml, "Opening.", "Opening words.")
    assert %{"ok" => true} = push_copy(slug, edited, rev) |> json_response(200)
    assert stored_block(slug, "k1") == kept
  end

  # Each older shape, and a key BPML cannot spell, prints; an edit to its own
  # words is refused by the write wall, naming the block, and the row keeps
  # its bytes.
  for {name, item, from, to} <- [
        {"a bare-string item", "Bare words", "Bare words", "Bare words, edited"},
        {"an item with its words only in text", %{"id" => "a", "text" => "Text words"},
         "Text words", "Text words, edited"},
        {"an item whose child list has an alias type",
         %{
           "id" => "a",
           "content" => [%{"type" => "text", "value" => "Parent words"}],
           "children" => [%{"type" => "ordered-list", "items" => [[%{"type" => "text", "value" => "x"}]]}]
         }, "Parent words", "Parent words, edited"},
        {"an item with a key BPML cannot spell",
         %{
           "id" => "a",
           "content" => [%{"type" => "text", "value" => "Audited words"}],
           "audit" => %{"keep" => true}
         }, "Audited words", "Audited words, edited"}
      ] do
    @item item
    @from from
    @to to
    test "editing #{name} is refused; the list keeps its bytes" do
      {slug, bpml, rev} = pulled_with([list("l1", [@item]), p("p2", "Closing.")])
      before = stored(slug)
      assert bpml =~ @from

      answer = push_copy(slug, String.replace(bpml, @from, @to), rev) |> json_response(422)
      assert answer["error"]["code"] == WriteWall.code()
      assert answer["error"]["message"] =~ ~s(block "l1")
      assert stored(slug) == before
    end
  end

  test "a second item with an id already in the block is refused by that id" do
    {slug, bpml, rev} = pulled_with(blocks(nested()))
    before = stored(slug)
    copy = String.replace(bpml, "<li>Ship</li>", ~s(<li>Ship</li><li id="build">Again</li>))

    answer = push_copy(slug, copy, rev) |> json_response(422)
    assert answer["error"]["code"] == "bpml"
    assert answer["error"]["message"] =~ ~s(item id "build" appears more than once in list l1)
    assert stored(slug) == before

    assert %{"valid" => false, "violations" => [%{"code" => "bpml"}]} = check(copy)
  end

  describe "depth" do
    # `levels` lists, each the only child of the one item above it.
    defp nest(levels) do
      Enum.reduce(2..levels//1, list([text("leaf")]), fn _, inner ->
        list([%{"content" => [], "children" => [inner]}])
      end)
      |> Map.put("id", "deep")
    end

    defp depth(%{"items" => [%{"children" => [inner]}]}), do: 1 + depth(inner)
    defp depth(%{"items" => _}), do: 1

    defp leaf(%{"items" => [%{"children" => [inner]}]}), do: leaf(inner)
    defp leaf(%{"items" => [leaf]}), do: leaf

    test "lists at Validate's limit round-trip an edit at the deepest level" do
      {slug, bpml, rev} = pulled_with([nest(Validate.max_depth())])
      assert bpml =~ "<li>leaf</li>"
      edited = String.replace(bpml, "<li>leaf</li>", "<li>deepest</li>")

      assert %{"ok" => true} = push_copy(slug, edited, rev) |> json_response(200)
      assert depth(stored_block(slug, "deep")) == Validate.max_depth()
      assert leaf(stored_block(slug, "deep")) == text("deepest")
    end

    test "one level more is refused, writing nothing" do
      {slug, bpml, rev} = pulled_with([nest(Validate.max_depth())])
      before = stored(slug)
      deeper = String.replace(bpml, "<li>leaf</li>", "<li>leaf<ul><li>past</li></ul></li>")

      answer = push_copy(slug, deeper, rev) |> json_response(422)
      assert answer["error"]["code"] == "bpml"
      assert Enum.any?(answer["error"]["errors"], &(&1["code"] == "too-deep"))
      assert stored(slug) == before
    end
  end
end
