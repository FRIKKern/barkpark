defmodule BarkparkWeb.BulldocsBpmlPushMarkTest do
  @moduledoc """
  The print mark end to end: pull answers `x-bpml-print`; a push without it
  that would remove a block is refused (422 `bpml_unshown_removal`) and stores
  nothing; the same push with the mark applies, and its answer carries the
  mark for the next push. Scratch slugs on the local test database.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Content
  alias Barkpark.LabelFixtures
  alias Barkpark.PortableDoc.Bpml
  alias Barkpark.PortableDoc.Bpml.PushGuard

  @token "barkpark-test-ingest-token"
  @ingest_path "/v1/plugins/bulldocs/papers"

  defp para(id, v),
    do: %{"id" => id, "type" => "paragraph", "content" => [%{"type" => "text", "value" => v}]}

  defp seeded!(slug) do
    {:ok, paper} =
      Content.upsert_paper(
        LabelFixtures.paper_attrs(%{slug: slug, blocks: [para("p1", "Keep."), para("p2", "Drop.")]})
      )

    paper
  end

  defp stored_blocks(slug), do: get_in(Content.get_paper(slug).content, ["blocks"])

  defp sync(conn, slug, payload) do
    conn
    |> put_req_header("authorization", "Bearer #{@token}")
    |> put_req_header("content-type", "application/json")
    |> post("#{@ingest_path}/#{slug}/sync", payload)
  end

  # The pulled copy, with block p2 deleted by hand.
  defp copy_without_p2(slug) do
    pulled = get(build_conn(), "/papers/#{slug}/source", %{"format" => "bpml"})
    assert [mark] = get_resp_header(pulled, "x-bpml-print")
    assert mark == PushGuard.print_mark()
    [rev] = get_resp_header(pulled, "x-paper-rev")

    paper = Content.get_paper(slug)
    copy = Bpml.print_paper(Content.Papers.bpml_paper_map(paper, [para("p1", "Keep.")]))
    {copy, rev, mark}
  end

  test "an unmarked copy that removes a block is refused and stores nothing", %{conn: conn} do
    slug = "bpml-push-mark-unmarked-#{System.unique_integer([:positive])}"
    seeded!(slug)
    {copy, rev, _mark} = copy_without_p2(slug)
    before = stored_blocks(slug)

    body = conn |> sync(slug, %{"bpml" => copy, "baseRev" => rev}) |> json_response(422)

    assert body["error"]["code"] == "bpml_unshown_removal"
    assert body["error"]["message"] =~ "blocks[1]"
    assert body["error"]["message"] =~ "make your change in the fresh copy"
    assert stored_blocks(slug) == before
  end

  test "the same copy with the mark applies, and the answer carries the mark", %{conn: conn} do
    slug = "bpml-push-mark-marked-#{System.unique_integer([:positive])}"
    seeded!(slug)
    {copy, rev, mark} = copy_without_p2(slug)

    body =
      conn
      |> sync(slug, %{"bpml" => copy, "baseRev" => rev, "bpmlPrint" => mark})
      |> json_response(200)

    assert body["ok"] == true
    assert body["bpmlPrint"] == PushGuard.print_mark()
    assert Enum.map(stored_blocks(slug), & &1["id"]) == ["p1"]
  end
end
