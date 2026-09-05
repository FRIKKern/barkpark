defmodule BarkparkWeb.BulldocsBpmlRoundtripDestructionTest do
  @moduledoc """
  The end-to-end destruction test: pull a paper whose stored blocks use ALIAS
  keys, push it back UNEDITED, and read the stored blocks again.

  This is the loop `bp paper --help` documents as THE way to author a paper.
  The printer read one key per block type while the corpus stores the same body
  under several, so the element printed EMPTY, the pull answered 200, and this
  push wrote the emptiness back — 2974 blocks in 254 of the 567 pullable
  published papers on the 2026-08-24 census.

  The blocks are written straight to the row because the ingest route
  normalizes BPML into the canonical keys — the alias spellings only exist on
  papers written by the other producers, which is exactly the corpus this loop
  destroyed. Nothing here touches a published paper: every fixture is a scratch
  slug created by the test.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Content
  alias Barkpark.LabelFixtures
  alias Barkpark.Repo

  @token "barkpark-test-ingest-token"
  @ingest_path "/v1/plugins/bulldocs/papers"

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
          blocks: [
            %{
              "id" => "seed",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "Seed body, replaced below."}]
            }
          ]
        })
      )

    content = paper.content |> Map.put("blocks", blocks) |> Map.delete("body_html")

    paper
    |> Ecto.Changeset.change(content: content)
    |> Repo.update!()

    Content.get_paper(slug)
  end

  defp pull!(slug) do
    conn = get(build_conn(), "/papers/#{slug}/source", %{"format" => "bpml"})
    [rev] = get_resp_header(conn, "x-paper-rev")
    {response(conn, 200), rev}
  end

  defp stored_blocks(slug), do: get_in(Content.get_paper(slug).content, ["blocks"])

  # Every body below is a SENTINEL: if it is absent from the stored blocks after
  # the push, the loop destroyed content the author never touched.
  @alias_blocks [
    %{
      "id" => "h1",
      "type" => "heading",
      "level" => 2,
      "content" => [%{"type" => "text", "value" => "HEADING_SENTINEL"}]
    },
    %{"id" => "p1", "type" => "paragraph", "text" => "PARAGRAPH_SENTINEL"},
    %{"id" => "i1", "type" => "ingress", "text" => "INGRESS_SENTINEL"},
    %{"id" => "q1", "type" => "pullquote", "text" => "PULLQUOTE_SENTINEL"},
    %{
      "id" => "e1",
      "type" => "eyebrow",
      "content" => [%{"type" => "text", "value" => "EYEBROW_SENTINEL"}]
    },
    %{"id" => "c1", "type" => "code", "code" => "CODE_SENTINEL"},
    %{
      "id" => "t1",
      "type" => "table",
      "header" => ["TABLE_HEAD_SENTINEL"],
      "rows" => [[[%{"type" => "text", "value" => "TABLE_CELL_SENTINEL"}]]]
    },
    %{"id" => "x1", "type" => "expandable", "title" => "EXPANDABLE_SENTINEL", "blocks" => []},
    %{
      "id" => "s1",
      "type" => "section",
      "children" => [
        %{
          "id" => "s1a",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "SECTION_CHILD_SENTINEL"}]
        }
      ]
    }
  ]

  @sentinels [
    "HEADING_SENTINEL",
    "PARAGRAPH_SENTINEL",
    "INGRESS_SENTINEL",
    "PULLQUOTE_SENTINEL",
    "EYEBROW_SENTINEL",
    "CODE_SENTINEL",
    "TABLE_HEAD_SENTINEL",
    "TABLE_CELL_SENTINEL",
    "EXPANDABLE_SENTINEL",
    "SECTION_CHILD_SENTINEL"
  ]

  test "an UNEDITED pull -> push preserves every alias-keyed body", %{conn: conn} do
    slug = "bpml-roundtrip-destruction-#{System.unique_integer([:positive])}"
    with_blocks!(slug, @alias_blocks)

    before_blocks = stored_blocks(slug)
    before_json = Jason.encode!(before_blocks)

    # Guard the fixture: the sentinels must actually be stored, or every
    # assertion below passes vacuously.
    for s <- @sentinels do
      assert String.contains?(before_json, s), "fixture never stored #{s}"
    end

    {bpml, rev} = pull!(slug)

    # 1. The PULL must show the author every body. A body missing here is the
    #    silent loss: the author edits a file that does not contain it.
    for s <- @sentinels do
      assert String.contains?(bpml, s),
             """
             SILENT LOSS on pull: #{s} is stored but absent from the BPML the
             author receives. Pushing this file back deletes it.

             bpml: #{bpml}
             """
    end

    # 2. Push it back UNEDITED — the "I opened it and changed nothing" case.
    assert %{"ok" => true} =
             authed(conn)
             |> post("#{@ingest_path}/#{slug}/sync", %{"bpml" => bpml, "baseRev" => rev})
             |> json_response(200)

    after_json = Jason.encode!(stored_blocks(slug))

    for s <- @sentinels do
      assert String.contains?(after_json, s),
             """
             DATA DESTRUCTION: an unedited pull -> push removed #{s} from the
             stored paper.

             before: #{before_json}
             after : #{after_json}
             """
    end
  end

  test "a SECOND unedited pull -> push is a fixed point (no drift on repeat)", %{conn: conn} do
    slug = "bpml-roundtrip-fixpoint-#{System.unique_integer([:positive])}"
    with_blocks!(slug, @alias_blocks)

    {bpml1, rev1} = pull!(slug)

    assert %{"ok" => true} =
             authed(conn)
             |> post("#{@ingest_path}/#{slug}/sync", %{"bpml" => bpml1, "baseRev" => rev1})
             |> json_response(200)

    {bpml2, rev2} = pull!(slug)
    first_settled = stored_blocks(slug)

    assert %{"ok" => true} =
             authed(build_conn())
             |> post("#{@ingest_path}/#{slug}/sync", %{"bpml" => bpml2, "baseRev" => rev2})
             |> json_response(200)

    # An alias body is allowed to be REKEYED to its canonical spelling once.
    # After that the loop must not move the paper again, or every open-and-save
    # rewrites the document.
    assert stored_blocks(slug) == first_settled

    {bpml3, _} = pull!(slug)
    assert bpml3 == bpml2
  end
end
