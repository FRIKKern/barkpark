defmodule Barkpark.Content.Papers.BodyHtmlStampHonestyTest do
  @moduledoc """
  The render stamp `content["body_html_sv"]` is a PROVENANCE claim: "this
  body_html was rendered by renderer version N from these blocks". A write that
  persists body_html the renderer never produced, while leaving an older stamp
  in place, persists a claim that is FALSE.

  Today a lying stamp is inert because readers ignore it. The moment a reader
  classifies on stamp-vs-current (pt-w1-reader-provenance-classification) and
  the version starts moving per renderer commit (pt-w1-renderer-source-digest),
  the same record flips from a safe 422 to "serve blocks and overwrite" — the
  caller's authored HTML silently discarded behind an HTTP 200.

  These tests pin the write side honest, and prove the scoping: the lie has
  exactly one leg, and the neighbouring carry-over leg must NOT be swept up
  with it (that would manufacture new false 422s).

  METHOD: every assertion reads the RELOADED persisted content map. Never a
  return value; never via republish (publish regenerates the cache and would
  silently overwrite the probe).
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.PortableDoc.Render

  @dataset "test"

  # The shipped classification rule (`Papers.cache_provenance/4`), modelled here
  # as a pure function. Since pe-w2-reader-stamp-guard the ONLY stamp state that
  # fails closed is the current digest: any other value — old digest, the
  # renderer's pre-digest integer, or no stamp at all — claims nothing about
  # this renderer, so a byte mismatch cannot contradict it and blocks stay
  # canonical. Keep this mirror in step with the real guard.
  defp classify(content, current_version) do
    case Map.fetch(content, "body_html_sv") do
      {:ok, ^current_version} -> :divergence_keep_422
      _ -> :drift_serve_blocks_and_overwrite
    end
  end

  # "The next version bump", modelled without assuming the version is a number.
  # The stamp is a sha256 digest of the renderer's own source
  # (pt-w1-renderer-source-digest), so a bump is simply a DIFFERENT digest —
  # a content hash has no successor, and `current + 1` no longer type-checks.
  # Hashing the current digest guarantees a distinct, correctly-shaped value.
  defp bumped_version(current) do
    :crypto.hash(:sha256, "bumped:" <> current) |> Base.encode16(case: :lower)
  end

  defp seed_block_backed_paper!(slug) do
    blocks = [%{"id" => "b1", "type" => "paragraph", "text" => "Rendered from blocks."}]

    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          dataset: @dataset,
          title: "Stamp honesty",
          blocks: blocks
        })
      )

    # Precondition, from persisted state: the block-backed write DID stamp.
    reloaded = Content.get_paper(slug, @dataset)
    assert reloaded.content["body_html_sv"] == Render.body_html_render_version()
    assert is_binary(reloaded.content["body_html"])

    {paper, blocks}
  end

  describe "verbatim body_html write (the lying leg)" do
    test "leaves NO body_html_sv on the persisted record" do
      slug = "stamp-verbatim-#{System.unique_integer([:positive])}"
      {_paper, _blocks} = seed_block_backed_paper!(slug)

      # A verbatim write: attrs carry body_html, NO blocks list. The existing
      # blocks stay on the row, so the record ends up mixed — canonical-looking
      # blocks beside HTML no renderer of ours produced.
      {:ok, _} =
        Content.upsert_paper(%{
          slug: slug,
          dataset: @dataset,
          body_html: "<p>Hand-authored by an external producer.</p>"
        })

      content = Content.get_paper(slug, @dataset).content

      refute Map.has_key?(content, "body_html_sv"),
             """
             STALE STAMP PERSISTED. The verbatim leg wrote body_html that no \
             renderer produced, but left body_html_sv = \
             #{inspect(content["body_html_sv"])} (current version = \
             #{inspect(Render.body_html_render_version())}) on the row. That \
             stamp is a lie: it claims provenance for bytes it never rendered. \
             Under the stamp-vs-digest reader rule this record classifies as \
             #{inspect(classify(content, Render.body_html_render_version()))} \
             today and as \
             #{inspect(classify(content, bumped_version(Render.body_html_render_version())))} \
             at the next version bump — i.e. the authored HTML is discarded \
             behind an HTTP 200. Clear the stamp with Map.delete/2 (never a \
             sentinel: a sentinel is != current by construction and routes \
             straight into the overwrite branch).
             """

      # The record really is the divergent, mixed shape — i.e. this test is
      # exercising the dangerous case, not a trivially safe one.
      assert is_list(get_in(content, ["body", "blocks"])) or is_list(content["blocks"])
      assert content["body_html"] =~ "Hand-authored"
    end

    test "remedy survives a version bump: never claims the CURRENT renderer, at either version" do
      slug = "stamp-bump-#{System.unique_integer([:positive])}"
      {_paper, _blocks} = seed_block_backed_paper!(slug)

      {:ok, _} =
        Content.upsert_paper(%{
          slug: slug,
          dataset: @dataset,
          body_html: "<p>Hand-authored by an external producer.</p>"
        })

      paper = Content.get_paper(slug, @dataset)
      current = Render.body_html_render_version()

      # The remedy is stamp HONESTY, and it holds across a version bump: a row
      # whose body_html no renderer produced never claims the current digest, so
      # it can never be read as divergence.
      refute classify(paper.content, current) == :divergence_keep_422
      refute classify(paper.content, bumped_version(current)) == :divergence_keep_422

      # And what the reader DOES with it (pe-w2-reader-stamp-guard): blocks are
      # canonical under the content-first doctrine and body_html is a derived
      # cache, so a mixed row serves its blocks rather than 422ing. That is the
      # deliberate trade — the previous fail-closed reading took 59 live papers
      # dark for four weeks. A producer that wants its authored HTML served must
      # not leave canonical blocks on the row.
      assert {:blocks, _} = Content.Papers.reader_source(paper, @dataset)
    end
  end

  describe "pure carry-over leg (must NOT be swept up)" do
    test "metadata-only update keeps its stamp and still reads as {:blocks, _}" do
      slug = "stamp-carryover-#{System.unique_integer([:positive])}"
      {_paper, _blocks} = seed_block_backed_paper!(slug)

      before = Content.get_paper(slug, @dataset).content

      # No blocks, no body_html — the existing body_html is rewritten
      # byte-for-byte, so its stamp stays TRUE.
      {:ok, _} =
        Content.upsert_paper(%{
          slug: slug,
          dataset: @dataset,
          description: "metadata only, no body touched"
        })

      paper = Content.get_paper(slug, @dataset)

      assert paper.content["body_html"] == before["body_html"],
             "carry-over leg must rewrite body_html byte-for-byte"

      assert paper.content["body_html_sv"] == Render.body_html_render_version(),
             """
             The stamp clear widened past the verbatim leg. This is a \
             metadata-only update: body_html is unchanged, so its stamp is \
             still true. Deleting it here demotes a healthy paper into the \
             fail-closed unknown class and manufactures NEW false 422s. The \
             delete must key on is_binary(attrs["body_html"]), not on \
             not is_list(blocks).
             """

      assert {:blocks, _} = Content.Papers.reader_source(paper, @dataset)
    end
  end

  describe "writer path" do
    test "a caller-supplied body_html_sv is stripped (provenance is server-derived)" do
      doc_id = "stamp-writer-#{System.unique_integer([:positive])}"

      {:ok, doc} =
        Content.upsert_document(
          "paper",
          %{
            "doc_id" => doc_id,
            "title" => "Caller-stamped",
            "content" => %{
              "body_html" => "<p>Client-authored.</p>",
              "body_html_sv" => 1
            }
          },
          @dataset
        )

      {:ok, reloaded} = Content.get_document(doc.doc_id, "paper", @dataset)
      content = reloaded.content

      refute Map.has_key?(content, "body_html_sv"),
             """
             A client POSTed content.body_html_sv = 1 with no blocks and it \
             persisted as #{inspect(content["body_html_sv"])}. Under the \
             stamp-vs-digest rule that is a client-controlled classification \
             switch: set sv == digest to pin the paper at 422, or sv != digest \
             to force the overwrite branch and destroy stored content. \
             Provenance must be server-derived.
             """

      assert content["body_html"] =~ "Client-authored"
    end
  end
end
