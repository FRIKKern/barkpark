defmodule BarkparkWeb.BulldocsBpmlCarriedReadTest do
  @moduledoc """
  A pull names every list item a push carries back that the print does not
  show all of (`ListItems.carried/1`, task-0b448ea0847a6b4f). The BPML pull
  answers the whole count in `x-bpml-carried-count`; `format=carried` answers
  the same view's items by block and item id, with the same `x-paper-rev` and
  `x-bpml-view`, so every one is named however many there are. No BPML byte
  changes.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Content
  alias Barkpark.LabelFixtures
  alias Barkpark.PortableDoc.BlockIds
  alias Barkpark.PortableDoc.Bpml.ListItems
  alias Barkpark.Repo

  @goldens Path.expand("../../../priv/portable_doc/goldens", __DIR__)

  defp golden(name),
    do: Path.join(@goldens, name) |> File.read!() |> Jason.decode!() |> Map.fetch!("blocks")

  defp text(value), do: [%{"type" => "text", "value" => value}]

  defp stored_with(blocks) do
    slug = "carried-read-#{System.unique_integer([:positive])}"
    seed = %{"id" => "seed", "type" => "paragraph", "content" => text("Seed.")}
    {:ok, paper} = Content.upsert_paper(LabelFixtures.paper_attrs(%{slug: slug, blocks: [seed]}))

    content =
      paper.content
      |> Map.put("blocks", BlockIds.ensure_persisted_block_ids(blocks))
      |> Map.delete("body_html")

    paper |> Ecto.Changeset.change(content: content) |> Repo.update!()
    slug
  end

  defp read(slug, format), do: get(scoped_conn(), "/papers/#{slug}/source", %{"format" => format})

  defp header(conn, name), do: conn |> get_resp_header(name) |> List.first()

  defp pull_and_carried(slug) do
    pull = read(slug, "bpml")
    carried = read(slug, "carried")
    assert response(pull, 200)
    assert header(carried, "x-paper-rev") == header(pull, "x-paper-rev")
    assert header(carried, "x-bpml-view") == header(pull, "x-bpml-view")
    {pull, json_response(carried, 200)}
  end

  test "a pull counts the items the print does not show all of, and the carried read names each" do
    slug = stored_with(golden("nested-list-carriers.json"))
    {pull, carried} = pull_and_carried(slug)

    assert header(pull, "x-bpml-carried-count") == "1"

    assert carried == %{
             "count" => 1,
             "carried" => [%{"block" => "nested-list", "item" => "plan"}]
           }
  end

  test "a Paper whose items carry nothing counts 0 and names none" do
    slug = stored_with(golden("from-markdown/nested-list-children.json"))
    {pull, carried} = pull_and_carried(slug)

    assert header(pull, "x-bpml-carried-count") == "0"
    assert carried == %{"count" => 0, "carried" => []}
  end

  test "more carried items than one header holds are each named, in order" do
    ids =
      for n <- 1..400, do: "an-item-whose-id-is-long-enough-#{String.pad_leading("#{n}", 4, "0")}"

    items = for id <- ids, do: %{"id" => id, "content" => text(id), "text" => "unshown #{id}"}
    slug = stored_with([%{"id" => "many", "type" => "list", "items" => items}])

    {pull, carried} = pull_and_carried(slug)

    # As one header the pairs would pass 16 KB, more than common proxies take.
    assert byte_size(Enum.map_join(ids, ",", &"many/#{&1}")) > 16_384
    assert header(pull, "x-bpml-carried-count") == "400"
    assert carried["count"] == 400
    assert carried["carried"] == for(id <- ids, do: %{"block" => "many", "item" => id})
  end

  test "carried/1 names exactly the items carry/2 gives something back to" do
    [source] = golden("nested-list-carriers.json")
    named = ListItems.carried([source])
    assert named == [{"nested-list", "plan"}]

    # Each item with an id, pushed back bare (only what the print spells):
    # carry/2 changes it exactly when carried/1 names it.
    for {id, item} <- ListItems.index(source) do
      bare = Map.take(item, ["id", "content", "children"])
      pushed = %{"id" => "nested-list", "type" => "list", "items" => [bare]}
      [%{"items" => [back]}] = ListItems.carry([pushed], [source])
      assert back != bare == {"nested-list", id} in named, id
    end
  end
end
