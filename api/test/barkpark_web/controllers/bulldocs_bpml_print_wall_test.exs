defmodule BarkparkWeb.BulldocsBpmlPrintWallTest do
  @moduledoc """
  Pulling a Paper never drops part of it. A Paper whose list item holds a
  nested list is refused on pull, naming the block path; and a working copy
  printed before the check (it shows the item without its child) is refused on
  push, so the child stays stored. Scratch slugs on the local test database.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Content
  alias Barkpark.LabelFixtures
  alias Barkpark.PortableDoc.Bpml
  alias Barkpark.Repo

  @token "barkpark-test-ingest-token"
  @ingest_path "/v1/plugins/bulldocs/papers"

  defp t(v), do: %{"type" => "text", "value" => v}

  defp nested_list do
    %{
      "id" => "l1",
      "type" => "list",
      "items" => [
        %{
          "content" => [t("parent item")],
          "children" => [%{"type" => "list", "items" => [[t("CHILD_SENTINEL")]]}]
        }
      ]
    }
  end

  defp intro, do: %{"id" => "p1", "type" => "paragraph", "content" => [t("Intro.")]}

  defp with_blocks!(slug, blocks) do
    {:ok, paper} =
      Content.upsert_paper(LabelFixtures.paper_attrs(%{slug: slug, blocks: [intro()]}))

    content = paper.content |> Map.put("blocks", blocks) |> Map.delete("body_html")
    paper |> Ecto.Changeset.change(content: content) |> Repo.update!()
    Content.get_paper(slug)
  end

  defp stored_blocks(slug), do: get_in(Content.get_paper(slug).content, ["blocks"])

  test "pull refuses a Paper whose list item holds a nested list, naming the path" do
    slug = "bpml-print-wall-pull-#{System.unique_integer([:positive])}"
    with_blocks!(slug, [intro(), nested_list()])

    conn = get(build_conn(), "/papers/#{slug}/source", %{"format" => "bpml"})
    body = json_response(conn, 422)

    assert body["error"]["code"] == "bpml_unprintable"
    assert body["error"]["message"] =~ "BPML cannot carry blocks[1].items[0]"
  end

  test "a working copy printed before the check is refused on push; the child stays", %{
    conn: conn
  } do
    slug = "bpml-print-wall-push-#{System.unique_integer([:positive])}"
    paper = with_blocks!(slug, [intro(), nested_list()])
    {:ok, rev} = Content.Papers.op_rev(paper)

    # What the old printer wrote: the item, without its child.
    lossy = put_in(nested_list(), ["items"], [[t("parent item")]])
    old_copy = Bpml.print_paper(Content.Papers.bpml_paper_map(paper, [intro(), lossy]))
    refute old_copy =~ "CHILD_SENTINEL"
    before = stored_blocks(slug)

    body =
      conn
      |> put_req_header("authorization", "Bearer #{@token}")
      |> put_req_header("content-type", "application/json")
      |> post("#{@ingest_path}/#{slug}/sync", %{"bpml" => old_copy, "baseRev" => to_string(rev)})
      |> json_response(422)

    assert body["code"] == "bpml_unprintable" or
             get_in(body, ["error", "code"]) == "bpml_unprintable"

    assert inspect(body) =~ "blocks[1].items[0]"
    assert stored_blocks(slug) == before
  end
end
