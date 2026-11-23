defmodule BarkparkWeb.BulldocsBpmlFixtureRoundTripTest do
  @moduledoc """
  The two nested-list goldens through the routes bp calls
  (task-0b448ea0847a6b4f): stored, pulled, edited in one plain item, pushed
  with the pull's fingerprint, and read back from the row.

  `nested-list-carriers.json` holds an item with an id whose `text` the
  reader does not show and a key BPML cannot write; the push carries both back
  byte-equal by the item's id (`ListItems.carry/2`). These are the words
  `EveryFixtureWordsTest` lists as carried, not printed. Its child list typed
  `ordered-list` comes back a `list` that is still ordered.

  `from-markdown/nested-list-children.json` holds a nested list with no ids;
  the nested list comes back byte-equal.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Content
  alias Barkpark.LabelFixtures
  alias Barkpark.PortableDoc.BlockIds
  alias Barkpark.PortableDoc.Bpml.ListItems
  alias Barkpark.Repo

  @token "barkpark-test-ingest-token"
  @ingest_path "/v1/plugins/bulldocs/papers"
  @goldens Path.expand("../../../priv/portable_doc/goldens", __DIR__)

  defp golden(name),
    do: Path.join(@goldens, name) |> File.read!() |> Jason.decode!() |> Map.fetch!("blocks")

  defp text(value), do: [%{"type" => "text", "value" => value}]

  defp pulled_with(blocks) do
    slug = "fixture-round-trip-#{System.unique_integer([:positive])}"
    seed = %{"id" => "seed", "type" => "paragraph", "content" => text("Seed.")}
    {:ok, paper} = Content.upsert_paper(LabelFixtures.paper_attrs(%{slug: slug, blocks: [seed]}))

    content =
      paper.content
      |> Map.put("blocks", BlockIds.ensure_persisted_block_ids(blocks))
      |> Map.delete("body_html")

    paper |> Ecto.Changeset.change(content: content) |> Repo.update!()

    conn = get(scoped_conn(), "/papers/#{slug}/source", %{"format" => "bpml"})
    [rev] = get_resp_header(conn, "x-paper-rev")
    [view] = get_resp_header(conn, "x-bpml-view")
    {slug, response(conn, 200), {rev, view}}
  end

  defp push_copy(slug, bpml, {rev, view}) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{@token}")
    |> put_req_header("content-type", "application/json")
    |> post("#{@ingest_path}/#{slug}/sync", %{
      "bpml" => bpml,
      "baseRev" => rev,
      "bpmlView" => view
    })
  end

  defp edited_push(blocks, from, to) do
    {slug, bpml, anchor} = pulled_with(blocks)
    assert bpml =~ from

    assert %{"ok" => true} =
             push_copy(slug, String.replace(bpml, from, to), anchor) |> json_response(200)

    [block] = get_in(Content.get_paper(slug).content, ["blocks"])
    block
  end

  defp ordered?(list),
    do: list["ordered"] == true or ListItems.alias_kind(list["type"]) == :ordered

  test "nested-list-carriers: an edit elsewhere brings the carried words back byte-equal" do
    [source] = golden("nested-list-carriers.json")
    block = edited_push([source], "Flat sibling", "Flat sibling, edited")

    [plan, sibling, fallback] = block["items"]
    [source_plan, _, source_fallback] = source["items"]
    assert sibling == text("Flat sibling, edited")
    # What the print spells (`content`, `children`) comes back as BPML reads
    # it; everything else on the item is carried, byte-equal.
    printed = ["content", "children"]
    assert Map.drop(plan, printed) == Map.drop(source_plan, printed)
    assert plan["text"] == "Inactive parent fallback"
    assert plan["audit"] == %{"keep" => true}
    assert fallback["id"] == source_fallback["id"]
  end

  test "nested-list-carriers: an ordered child list is still ordered after an edited push" do
    [source] = golden("nested-list-carriers.json")
    [%{"children" => [plan_list]}, _, %{"children" => [fallback_list]}] = source["items"]
    assert ordered?(plan_list) and ordered?(fallback_list)
    assert fallback_list["type"] == "ordered-list"

    block = edited_push([source], "Flat sibling", "Flat sibling, edited")

    [%{"children" => [plan_after]}, _, %{"children" => [fallback_after]}] = block["items"]
    assert ordered?(plan_after)
    assert ordered?(fallback_after)
    assert fallback_after["items"] == [text("Alias child")]
  end

  test "nested-list-children: an edit elsewhere brings the nested list back byte-equal" do
    [source] = golden("from-markdown/nested-list-children.json")
    [%{"children" => children} = _a, _d] = source["items"]

    block = edited_push([source], "<li>d</li>", "<li>d, edited</li>")

    assert [%{"children" => ^children, "content" => [%{"value" => "a"}]}, d] = block["items"]
    assert d == text("d, edited")
  end
end
