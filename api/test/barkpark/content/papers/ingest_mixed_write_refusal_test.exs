defmodule Barkpark.Content.Papers.IngestMixedWriteRefusalTest do
  @moduledoc """
  THE PRODUCER CONTRACT for a verbatim `body_html` write onto a paper that
  still carries canonical blocks: REFUSED at the ingest boundary, 422, with a
  message that names what to do instead.

  ## What this pins, and what it looked like before

  Before this slice the mixed write answered **200**. The blocks survived it,
  so `Papers.reader_source/3` classified the row `{:stale, rendered}`: the
  reader served the blocks and `refresh_html_cache/3` rewrote the derived cache
  from them. The producer's hand-authored bytes were therefore gone on the very
  next READ, behind a success receipt. That characterization ran GREEN on
  `origin/main@64baa8087` — the sentinel string landed in `content["body_html"]`
  on the write and was absent after one `reader_source/3` call.

  The remaining sibling of that behaviour is
  `body_html_stamp_honesty_test.exs` "remedy survives a version bump", which
  pins the READER verdict `{:blocks, _}` for exactly this row shape. That
  verdict is deliberate and stays; this file closes the WRITE side of it.

  ## The three properties, all load-bearing

  1. THE REFUSAL — 422, nothing written, existing blocks and cache untouched.
  2. THE MESSAGE — a positive control on the WORDING. The ruling's one
     condition is that the 422 name the two honest paths; a refusal that only
     declines makes the caller guess, and the guess that appears to work is the
     destructive one. Both named paths are exercised here, so neither can rot
     into a suggestion that does not work.
  3. NO OVER-REFUSAL — a `body_html` write onto a paper with NO blocks (fresh
     slug, or an existing HTML-only row) still succeeds exactly as before, and
     a `blocks` write onto a blocks paper still succeeds. Without these the
     refusal could pass by refusing everything.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.Papers
  alias Barkpark.LabelFixtures
  alias Barkpark.Plugins.Bulldocs.MixedWriteGuard

  @token "barkpark-test-ingest-token"
  @path "/v1/plugins/bulldocs/papers"
  @dataset "production"

  @verbatim ~s(<article><h1>hand authored</h1><p>PRODUCER-BYTES-SENTINEL</p></article>)

  defp post_paper(payload) do
    Phoenix.ConnTest.build_conn()
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
    |> post(@path, payload)
  end

  defp blocks_body(slug, extra \\ %{}) do
    LabelFixtures.paper_attrs(%{
      "slug" => slug,
      "blocks" => [
        %{"id" => "b1", "type" => "heading", "level" => 1, "text" => slug},
        %{"id" => "b2", "type" => "paragraph", "text" => "canonical block prose"}
      ]
    })
    |> Map.merge(extra)
  end

  defp html_body(slug, html, extra \\ %{}) do
    LabelFixtures.paper_attrs(%{"slug" => slug, "body_html" => html})
    |> Map.merge(extra)
  end

  defp publish_blocks!(slug) do
    assert json_response(post_paper(blocks_body(slug)), 200)["ok"] == true
    Content.get_paper(slug, @dataset)
  end

  describe "the refusal" do
    test "body_html onto a blocks-backed paper is REFUSED 422 and writes nothing" do
      slug = "mixed-write-refused"
      before = publish_blocks!(slug)

      resp = json_response(post_paper(html_body(slug, @verbatim)), 422)
      assert resp["error"]["code"] == MixedWriteGuard.code()
      assert resp["error"]["block_count"] == 2

      # The write did NOT happen behind the refusal: blocks and the derived
      # cache are byte-identical to what stood before the POST, and the
      # producer's bytes never reached the row at all.
      now = Content.get_paper(slug, @dataset)
      assert get_in(now.content, ["blocks"]) == get_in(before.content, ["blocks"])
      assert get_in(now.content, ["body_html"]) == get_in(before.content, ["body_html"])
      refute get_in(now.content, ["body_html"]) =~ "PRODUCER-BYTES-SENTINEL"
    end

    test "the reader verdict for the untouched row is still {:blocks, _}" do
      slug = "mixed-write-refused-reader"
      publish_blocks!(slug)
      assert json_response(post_paper(html_body(slug, @verbatim)), 422)

      paper = Content.get_paper(slug, @dataset)
      assert {:blocks, blocks} = Papers.reader_source(paper, @dataset)
      assert length(blocks) == 2
    end
  end

  describe "the message names what to do instead (the ruling's one condition)" do
    test "it names BOTH remedies, not just the decline" do
      slug = "mixed-write-message"
      publish_blocks!(slug)

      message = json_response(post_paper(html_body(slug, @verbatim)), 422)["error"]["message"]

      # Remedy 1 — send blocks.
      assert message =~ "`blocks`"
      # Remedy 2 — the explicit demotion, spelled exactly as the API takes it.
      assert message =~ "clear_blocks"
      # And it says WHY, so the producer can tell this from a validation nit.
      assert message =~ "source of truth"
    end

    test "REMEDY 1 works: the same paper accepts a blocks write" do
      slug = "mixed-write-remedy-one"
      publish_blocks!(slug)
      assert json_response(post_paper(html_body(slug, @verbatim)), 422)

      body =
        blocks_body(slug, %{
          "blocks" => [
            %{"id" => "b1", "type" => "heading", "level" => 1, "text" => slug},
            %{"id" => "b2", "type" => "paragraph", "text" => "REMEDY-ONE-PROSE"}
          ]
        })

      assert json_response(post_paper(body), 200)["ok"] == true

      assert get_in(Content.get_paper(slug, @dataset).content, ["body_html"]) =~
               "REMEDY-ONE-PROSE"
    end

    test "REMEDY 2 works: clear_blocks makes the row honestly HTML-only" do
      slug = "mixed-write-remedy-two"
      publish_blocks!(slug)
      assert json_response(post_paper(html_body(slug, @verbatim)), 422)

      assert json_response(
               post_paper(html_body(slug, @verbatim, %{"clear_blocks" => true})),
               200
             )["ok"] == true

      paper = Content.get_paper(slug, @dataset)
      # The canonical blocks are gone — and so is their projected body, or
      # Projection.read_blocks/1 would still hand the reader a block list.
      refute Map.has_key?(paper.content, "blocks")
      assert Barkpark.PortableDoc.Projection.read_blocks(paper.content) == nil
      assert get_in(paper.content, ["body_html"]) =~ "PRODUCER-BYTES-SENTINEL"

      # The reader now serves the producer's HTML, and reading does not
      # overwrite it.
      assert {:html, html} = Papers.reader_source(paper, @dataset)
      assert html =~ "PRODUCER-BYTES-SENTINEL"

      assert get_in(Content.get_paper(slug, @dataset).content, ["body_html"]) =~
               "PRODUCER-BYTES-SENTINEL"

      # And a FOLLOW-UP plain body_html write to the now-HTML-only row is no
      # longer a mixed write, so it needs no flag.
      assert json_response(
               post_paper(html_body(slug, ~s(<article><p>SECOND-HTML-WRITE</p></article>))),
               200
             )["ok"] == true

      assert get_in(Content.get_paper(slug, @dataset).content, ["body_html"]) =~
               "SECOND-HTML-WRITE"
    end
  end

  describe "no over-refusal — the guard is narrow" do
    test "a body_html write on a FRESH slug (no row at all) still succeeds" do
      slug = "mixed-write-control-fresh"

      assert json_response(post_paper(html_body(slug, @verbatim)), 200)["ok"] == true

      assert get_in(Content.get_paper(slug, @dataset).content, ["body_html"]) =~
               "PRODUCER-BYTES-SENTINEL"
    end

    test "a body_html write onto an EXISTING html-only paper still succeeds" do
      slug = "mixed-write-control-html-only"
      assert json_response(post_paper(html_body(slug, @verbatim)), 200)["ok"] == true

      second = ~s(<article><h1>hand authored</h1><p>SECOND-PASS-SENTINEL</p></article>)
      assert json_response(post_paper(html_body(slug, second)), 200)["ok"] == true

      assert get_in(Content.get_paper(slug, @dataset).content, ["body_html"]) =~
               "SECOND-PASS-SENTINEL"
    end

    test "a blocks write onto a blocks-backed paper still succeeds" do
      slug = "mixed-write-control-blocks"
      publish_blocks!(slug)

      body =
        blocks_body(slug, %{
          "blocks" => [
            %{"id" => "b1", "type" => "heading", "level" => 1, "text" => slug},
            %{"id" => "b2", "type" => "paragraph", "text" => "SECOND-BLOCKS-PASS"}
          ]
        })

      assert json_response(post_paper(body), 200)["ok"] == true

      assert get_in(Content.get_paper(slug, @dataset).content, ["body_html"]) =~
               "SECOND-BLOCKS-PASS"
    end
  end
end
