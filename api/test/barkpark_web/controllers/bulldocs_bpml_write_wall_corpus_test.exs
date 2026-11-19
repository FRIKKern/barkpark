defmodule BarkparkWeb.BulldocsBpmlWriteWallCorpusTest do
  @moduledoc """
  The BPML push over the corpus (`Barkpark.BpmlCorpus`): for every Paper the
  pull serves, an unedited push changes nothing, and a push that adds a block
  lands with every stored block byte-equal in the row the write left (after
  the canonical shapes every block write applies to every block). It
  prints how many blocks each reason freezes (a BPML edit of them is refused),
  on the corpus and on the stored-documents set.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{BpmlCorpus, BpmlStoredDocuments, Content, LabelFixtures}
  alias Barkpark.Content.Papers.BpmlView
  alias Barkpark.PortableDoc.Bpml.WriteWall

  @ds "production"
  @token "barkpark-test-ingest-token"
  @ingest_path "/v1/plugins/bulldocs/papers"

  # Each push from its own address: the corpus is more writes than one
  # address's per-minute budget.
  defp sync(slug, bpml, rev) do
    n = System.unique_integer([:positive])

    %{
      build_conn()
      | remote_ip: {10, rem(div(n, 65_536), 256), rem(div(n, 256), 256), rem(n, 256)}
    }
    |> put_req_header("authorization", "Bearer #{@token}")
    |> put_req_header("content-type", "application/json")
    |> post("#{@ingest_path}/#{slug}/sync", %{"bpml" => bpml, "baseRev" => rev})
  end

  defp stored_blocks(slug), do: get_in(Content.get_paper(slug).content, ["blocks"])

  # Why a block is frozen: the last key of its first unshown path.
  defp reason([]), do: :shown

  defp reason([path | _]) do
    case Regex.run(~r/\.([^.\[\]]+)(?:\[\d+\])*$/, path) do
      [_, key] -> key
      _ -> "the whole block"
    end
  end

  defp frozen_by_reason(pairs) do
    pairs
    |> Enum.map(fn {s, v} ->
      if printable?(v), do: reason(WriteWall.unshown(s, v)), else: :unprintable
    end)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {k, n} -> {-n, inspect(k)} end)
  end

  defp printable?(nil), do: true

  defp printable?(v) do
    _ = Barkpark.PortableDoc.Bpml.print_blocks([v])
    true
  rescue
    _ -> false
  end

  setup do
    LabelFixtures.register_tags!(@ds)
    :ok
  end

  test "every corpus Paper: an unedited push changes nothing; an added block keeps every stored block byte-equal" do
    {papers, left_out} = BpmlCorpus.papers!()
    assert length(papers) > 100

    results =
      for {slug, writer} <- papers do
        paper = Content.get_paper(slug)
        before = stored_blocks(slug)
        resp = get(build_conn(), "/papers/#{slug}/source", %{"format" => "bpml"})

        if resp.status == 200 do
          [rev] = get_resp_header(resp, "x-paper-rev")
          bpml = resp.resp_body

          # The route serves the printer's bytes for the row's view, at its rev.
          {:blocks, view, fields} = BpmlView.of(paper, @ds, [], :published)

          assert bpml ==
                   Barkpark.PortableDoc.Bpml.print_paper(
                     Content.Papers.bpml_paper_map(paper, view, fields)
                   )

          assert {:ok, String.to_integer(rev)} == Content.Papers.op_rev(paper)

          unedited = sync(slug, bpml, rev)

          if unedited.status == 200 do
            assert json_response(unedited, 200)["unchanged"] == true, "#{slug}: unedited push"
            assert stored_blocks(slug) == before, "#{slug}: an unedited push changed the row"

            added =
              String.replace(bpml, "</paper>", ~s(  <p id="corpus-added">Added.</p>\n</paper>))

            resp = sync(slug, added, rev)

            assert resp.status == 200,
                   "#{slug}: adding a block answered #{resp.status} #{resp.resp_body}"

            # Every write puts every block through the chokepoint's canonical
            # shapes (`BlockOps.normalize_render_shapes/1`); nothing else moves.
            assert Enum.take(stored_blocks(slug), length(before)) ==
                     Barkpark.Content.Papers.BlockOps.normalize_render_shapes(before),
                   "#{slug} (#{writer}): a stored block changed when another was added"
          else
            # The pull printed bytes its own parser refuses: nothing is written.
            error = json_response(unedited, 422)["error"]
            assert error["code"] == "bpml", slug
            assert stored_blocks(slug) == before
            send(self(), {:push_parse_refused, slug, Enum.map(error["errors"], & &1["message"])})
          end

          {:blocks, shown, _} = BpmlView.of(paper, @ds, [], :published)
          by_id = Map.new(shown, &{&1["id"], &1})
          {writer, Enum.map(before, &{&1, Map.get(by_id, &1["id"])})}
        else
          {writer, {:pull, resp.status}}
        end
      end

    # A checklist prints `task="true"`, which the parser refuses
    # (task-ff1f2cb13c5baf4c): those Papers cannot be pushed at all yet.
    refusals =
      for {:push_parse_refused, slug, why} <- elem(Process.info(self(), :messages), 1),
          do: {slug, why}

    parse_refused = Enum.map(refusals, &elem(&1, 0))

    for {slug, why} <- refusals,
        do: assert(why == ["unknown attribute task= on <ul>"], "#{slug}: #{inspect(why)}")

    corpus_pairs = for {_w, pairs} when is_list(pairs) <- results, pair <- pairs, do: pair
    pulls_refused = for {w, {:pull, status}} <- results, do: {w, status}

    stored_pairs =
      for {_file, blocks} <- BpmlStoredDocuments.all(), b <- blocks, is_map(b), do: {b, b}

    IO.puts("""

    BPML push, frozen blocks by reason
      corpus: #{length(papers)} Papers, #{length(corpus_pairs)} blocks
        #{inspect(frozen_by_reason(corpus_pairs))}
        pull refused: #{inspect(Enum.frequencies(pulls_refused))}
        push refused by the parser (checklists, task-ff1f2cb13c5baf4c): #{inspect(parse_refused)}
        left out by their writer: #{inspect(Enum.map(left_out, &elem(&1, 0)))}
      stored documents: #{length(stored_pairs)} blocks
        #{inspect(frozen_by_reason(stored_pairs))}
    """)
  end
end
