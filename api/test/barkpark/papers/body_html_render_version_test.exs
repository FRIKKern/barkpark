defmodule Barkpark.Papers.BodyHtmlRenderVersionTest do
  @moduledoc """
  Locks the body_html render-version stamp (write-side half of the #857/#861
  cache-staleness fix):

    * a paper written through the block_ops path stamps `content["body_html_sv"]`
      with the current `Render.body_html_render_version/0`; and
    * `mix barkpark.rehydrate_body_html` re-renders and re-stamps a cache frozen
      by an older renderer (absent/lagging stamp), idempotently.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.{Document, Labels}
  alias Barkpark.PortableDoc.Render
  alias Barkpark.Repo
  alias Mix.Tasks.Barkpark.RehydrateBodyHtml

  @dataset "body_html_sv_test"

  defp para(id, text) do
    %{"id" => id, "type" => "paragraph", "content" => [%{"type" => "text", "value" => text}]}
  end

  defp create_paper(slug, blocks) do
    {:ok, doc} = Content.upsert_paper(%{"slug" => slug, "blocks" => blocks, "dataset" => @dataset})
    doc
  end

  defp reload(doc) do
    {:ok, doc} = Content.get_document(doc.doc_id, "paper", @dataset)
    doc
  end

  describe "write-side stamp" do
    test "a paper written from blocks carries the current render-version stamp" do
      doc = create_paper("stamp-1", [para("p1", "hello")])
      assert doc.content["body_html_sv"] == Render.body_html_render_version()
      assert is_binary(doc.content["body_html"])
    end
  end

  describe "rehydrate_body_html backfill task" do
    test "a stale (wrong) cache with an absent stamp is re-rendered + stamped, rev bumped" do
      doc = create_paper("rh-1", [para("p1", "fresh")])
      blocks = doc.content["blocks"]

      # Freeze a deliberately-wrong body_html with NO version stamp — the shape a
      # paper last written by an older renderer carries.
      stale_content =
        doc.content
        |> Map.put("body_html", "<p>STALE</p>")
        |> Map.delete("body_html_sv")

      {:ok, stale} =
        doc
        |> Document.changeset(%{"content" => stale_content, "rev" => "stale-rev"})
        |> Repo.update()

      %{scanned: scanned, rewritten: rewritten} = RehydrateBodyHtml.rehydrate()
      assert scanned == 1
      assert rewritten == 1

      refreshed = reload(stale)
      expected = Render.render_blocks(blocks, Labels.paper_render_opts(@dataset, nil))

      assert refreshed.content["body_html"] == expected
      assert refreshed.content["body_html"] != "<p>STALE</p>"
      assert refreshed.content["body_html_sv"] == Render.body_html_render_version()
      assert refreshed.rev != stale.rev
    end

    test "a second run rewrites nothing (idempotent)" do
      doc = create_paper("rh-2", [para("p1", "text")])

      stale_content = doc.content |> Map.put("body_html", "<p>STALE</p>") |> Map.delete("body_html_sv")

      {:ok, _} =
        doc
        |> Document.changeset(%{"content" => stale_content, "rev" => "stale-rev"})
        |> Repo.update()

      assert %{rewritten: 1} = RehydrateBodyHtml.rehydrate()
      after_first = reload(doc)

      assert %{rewritten: 0} = RehydrateBodyHtml.rehydrate()
      after_second = reload(doc)

      assert after_second.rev == after_first.rev
      assert after_second.content["body_html_sv"] == Render.body_html_render_version()
    end

    test "a doc already at the current stamp is a no-op" do
      # A fresh block_ops write is already stamped current — the task skips it.
      create_paper("rh-3", [para("p1", "current")])
      assert %{scanned: 1, rewritten: 0, noop: 1} = RehydrateBodyHtml.rehydrate()
    end
  end
end
