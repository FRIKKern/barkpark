defmodule BarkparkWeb.BulldocsBpmlListItemsPushTest do
  @moduledoc """
  `bp paper pull` → edit → `bp paper push` of a Paper with a nested list
  (task-0b448ea0847a6b4f), through the routes bp calls. Every Paper is a
  scratch slug the test writes; the blocks go straight to the row, as the
  paper editor stores them. The print and parse rows are in
  `bpml_list_items_test.exs`.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Content
  alias Barkpark.LabelFixtures
  alias Barkpark.PortableDoc.{Render, Validate}
  alias Barkpark.Repo

  @token "barkpark-test-ingest-token"
  @ingest_path "/v1/plugins/bulldocs/papers"

  defp text(value), do: [%{"type" => "text", "value" => value}]
  defp p(id, value), do: %{"id" => id, "type" => "paragraph", "content" => text(value)}
  defp list(items), do: %{"type" => "list", "items" => items}
  defp list(id, items), do: %{"id" => id, "type" => "list", "items" => items}

  # Three levels; `plan` holds a key and a text BPML cannot spell.
  defp nested do
    list("l1", [
      %{
        "id" => "plan",
        "content" => text("Plan"),
        "text" => "Inactive words",
        "audit" => %{"keep" => true},
        "children" => [
          %{
            "type" => "list",
            "ordered" => true,
            "items" => [
              %{"id" => "build", "text" => "Build", "children" => [list(["Verify"])]},
              "Ship"
            ]
          }
        ]
      },
      "Flat sibling"
    ])
  end

  defp blocks, do: [p("p1", "Opening."), nested(), p("p2", "Closing.")]
  defp alias_list, do: %{"type" => "ordered-list", "items" => ["x"]}

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

  test "an edit at the third level stores every level, the ids and what BPML cannot spell" do
    {slug, bpml, rev} = pulled_with(blocks())
    assert bpml =~ ~s(<li id="build">Build\n)

    edited = String.replace(bpml, "<li>Verify</li>", "<li>Verify twice</li>")
    assert %{"ok" => true} = push_copy(slug, edited, rev) |> json_response(200)

    assert stored_block(slug, "l1") ==
             list("l1", [
               %{
                 "id" => "plan",
                 "content" => text("Plan"),
                 "text" => "Inactive words",
                 "audit" => %{"keep" => true},
                 "children" => [
                   %{
                     "type" => "list",
                     "ordered" => true,
                     "items" => [
                       %{
                         "id" => "build",
                         "content" => text("Build"),
                         "children" => [list([text("Verify twice")])]
                       },
                       text("Ship")
                     ]
                   }
                 ]
               },
               text("Flat sibling")
             ])
  end

  test "an unedited push of the three-level list stores the same bytes" do
    {slug, bpml, rev} = pulled_with(blocks())
    before = stored(slug)

    assert %{"unchanged" => true} = push_copy(slug, bpml, rev) |> json_response(200)
    assert stored(slug) == before
  end

  test "an edit elsewhere leaves the list byte for byte" do
    {slug, bpml, rev} = pulled_with(blocks())
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

  test "an edited item renders as the stored list did, aliases and strings normalized" do
    stored =
      list("l1", [
        %{"id" => "a", "text" => "A", "children" => [alias_list()]},
        "Ship"
      ])

    {slug, bpml, rev} = pulled_with([stored])
    edited = String.replace(bpml, "<li>Ship</li>", "<li>Ship it</li>")
    assert %{"ok" => true} = push_copy(slug, edited, rev) |> json_response(200)

    expected = put_in(stored, ["items", Access.at(1)], "Ship it")
    html = &Render.render_blocks(&1, %{style: :article})
    assert html.([stored_block(slug, "l1")]) == html.([expected])
  end

  test "a new item id carries nothing; an id carries only within its own block" do
    other = list("l2", ["Other"])
    {slug, bpml, rev} = pulled_with([nested(), other])

    # `plan` leaves l1 (its whole <li>, at the pull's top-list indent) for l2.
    moved = ~s(<li id="plan">Moved</li><li id="new">New</li>)

    edited =
      bpml
      |> String.replace(~r/\n    <li id="plan">.*?\n    <\/li>/s, "")
      |> String.replace("<li>Other</li>", moved)

    assert %{"ok" => true} = push_copy(slug, edited, rev) |> json_response(200)

    assert stored_block(slug, "l2")["items"] == [
             %{"id" => "plan", "content" => text("Moved")},
             %{"id" => "new", "content" => text("New")}
           ]
  end

  test "a second item with an id already in the block is refused by that id" do
    {slug, bpml, rev} = pulled_with(blocks())
    before = stored(slug)
    copy = String.replace(bpml, "<li>Ship</li>", ~s(<li>Ship</li><li id="build">Again</li>))

    answer = push_copy(slug, copy, rev) |> json_response(422)
    assert answer["error"]["code"] == "bpml"
    assert answer["error"]["message"] =~ ~s(item id "build" appears more than once in list l1)
    assert stored(slug) == before

    assert %{"valid" => false, "violations" => [%{"code" => "bpml"}]} = check(copy)
  end

  describe "depth" do
    defp nest(levels) do
      Enum.reduce(2..levels//1, list(["leaf"]), fn _, inner ->
        list([%{"children" => [inner]}])
      end)
      |> Map.put("id", "deep")
    end

    defp depth(%{"items" => [%{"children" => [inner]}]}), do: 1 + depth(inner)
    defp depth(%{"items" => _}), do: 1

    test "lists at Validate's limit round-trip an edit at the deepest level" do
      {slug, bpml, rev} = pulled_with([nest(Validate.max_depth())])
      edited = String.replace(bpml, "<li>leaf</li>", "<li>deepest</li>")

      assert %{"ok" => true} = push_copy(slug, edited, rev) |> json_response(200)
      assert depth(stored_block(slug, "deep")) == Validate.max_depth()
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
