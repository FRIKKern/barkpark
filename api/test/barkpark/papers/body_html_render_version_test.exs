defmodule Barkpark.Papers.BodyHtmlRenderVersionTest do
  @moduledoc """
  Locks the body_html render-version stamp (write-side half of the #857/#861
  cache-staleness fix):

    * a paper written through the block_ops path stamps `content["body_html_sv"]`
      with the current `Render.body_html_render_version/0`; and
    * `mix barkpark.rehydrate_body_html` re-renders and re-stamps a cache frozen
      by a different renderer (absent/foreign stamp), idempotently.

  The stamp is a sha256 digest of the renderer's own source, so it is compared
  by IDENTITY — the ordinal-trap test below is the guard on that.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.{Document, Labels}
  alias Barkpark.PortableDoc.Render
  alias Barkpark.Repo
  alias Mix.Tasks.Barkpark.RehydrateBodyHtml

  import Barkpark.TenancyFixtures

  @dataset "body_html_sv_test"

  defp para(id, text) do
    %{"id" => id, "type" => "paragraph", "content" => [%{"type" => "text", "value" => text}]}
  end

  defp create_paper(slug, blocks) do
    {:ok, doc} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => slug,
          "blocks" => blocks,
          "dataset" => @dataset
        })
      )

    doc
  end

  defp reload(doc) do
    opts =
      if is_binary(doc.workspace_id) do
        [workspace_id: doc.workspace_id, project_id: doc.project_id]
      else
        []
      end

    {:ok, doc} = Content.get_document(doc.doc_id, "paper", @dataset, opts)
    doc
  end

  describe "write-side stamp" do
    test "a paper written from blocks carries the current render-version stamp" do
      doc = create_paper("stamp-1", [para("p1", "hello")])
      assert doc.content["body_html_sv"] == Render.body_html_render_version()
      assert is_binary(doc.content["body_html"])
    end

    test "the generic document writer derives paper HTML from blocks atomically" do
      blocks = [
        %{
          "id" => "title",
          "type" => "heading",
          "role" => "title",
          "level" => 1,
          "text" => "Writer authority"
        },
        para("p1", "blocks win")
      ]

      {:ok, doc} =
        Content.create_document(
          "paper",
          %{
            "doc_id" => "writer-authority",
            "title" => "Writer authority",
            "content" => %{
              "blocks" => blocks,
              "body_html" => "<p>STALE CALLER CACHE</p>",
              "body_html_sv" => Render.body_html_render_version()
            }
          },
          @dataset
        )

      assert doc.content["body_html"] =~ "blocks win"
      refute doc.content["body_html"] =~ "STALE CALLER CACHE"
      assert doc.content["body_html_sv"] == Render.body_html_render_version()
    end

    test "the generic writer binds reference labels to the paper tenant" do
      ws_a = create_workspace!("body-html-writer-a")
      proj_a = create_project!(ws_a, "body-html-writer-pa")
      ws_b = create_workspace!("body-html-writer-b")
      proj_b = create_project!(ws_b, "body-html-writer-pb")

      {:ok, _} =
        Content.create_document(
          "author",
          %{"doc_id" => "shared-author", "title" => "Author in A"},
          @dataset,
          workspace_id: ws_a.id,
          project_id: proj_a.id
        )

      {:ok, _} =
        Content.create_document(
          "author",
          %{"doc_id" => "shared-author", "title" => "Author in B"},
          @dataset,
          workspace_id: ws_b.id,
          project_id: proj_b.id
        )

      blocks = [
        %{
          "id" => "title",
          "type" => "heading",
          "role" => "title",
          "level" => 1,
          "text" => "Scoped Writer"
        },
        %{
          "id" => "author",
          "type" => "field-reference",
          "label" => "Author",
          "refType" => "author",
          "value" => "shared-author"
        }
      ]

      {:ok, doc} =
        Content.create_document(
          "paper",
          %{
            "doc_id" => "scoped-writer-authority",
            "title" => "Scoped Writer",
            "content" =>
              Barkpark.LabelFixtures.with_labels(%{
                "blocks" => blocks,
                "body_html" => "<p>STALE</p>"
              })
          },
          @dataset,
          workspace_id: ws_b.id,
          project_id: proj_b.id
        )

      assert doc.content["body_html"] =~ "Author in B"
      refute doc.content["body_html"] =~ "Author in A"
    end

    test "the generic writer derives from historical content.body.blocks" do
      blocks = [para("legacy-p", "historical nested blocks win")]

      {:ok, doc} =
        Content.create_document(
          "paper",
          %{
            "doc_id" => "writer-historical-body",
            "title" => "Historical Body",
            "content" =>
              Barkpark.LabelFixtures.with_labels(%{
                "body" => %{"blocks" => blocks},
                "body_html" => "<p>STALE HISTORICAL CACHE</p>"
              })
          },
          @dataset
        )

      assert doc.content["body_html"] =~ "historical nested blocks win"
      refute doc.content["body_html"] =~ "STALE HISTORICAL CACHE"
      assert doc.content["body_html_sv"] == Render.body_html_render_version()
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

      stale_content =
        doc.content |> Map.put("body_html", "<p>STALE</p>") |> Map.delete("body_html_sv")

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

    test "a stamp from an older renderer is caught even when it sorts ABOVE the current one" do
      # THE ORDINAL TRAP. The stamp is a sha256 digest of the renderer's source;
      # it carries no total order, so an OLDER renderer's digest is lexicographically
      # greater than the current one about half the time. The predecessor test
      # `sv >= current` would read this row as up-to-date and skip it forever.
      #
      # The cache bytes are left MATCHING a fresh render on purpose: that removes
      # the byte-compare from the picture, so the rewrite can only be attributed
      # to the stamp comparison. Under `>=` this row is a no-op; under `==` it is
      # rewritten and re-stamped.
      doc = create_paper("rh-ordinal", [para("p1", "ordinally greater, chronologically older")])

      older_but_greater = String.duplicate("f", 64)
      current = Render.body_html_render_version()

      assert older_but_greater > current,
             "fixture must sort above the current digest for this test to mean anything"

      {:ok, stale} =
        doc
        |> Document.changeset(%{
          "content" => Map.put(doc.content, "body_html_sv", older_but_greater),
          "rev" => "ordinal-rev"
        })
        |> Repo.update()

      # Bytes already current — only the stamp is wrong.
      assert stale.content["body_html"] ==
               Render.render_blocks(
                 stale.content["blocks"],
                 Labels.paper_render_opts(@dataset, nil)
               )

      assert %{scanned: 1, rewritten: 1, noop: 0} = RehydrateBodyHtml.rehydrate()

      refreshed = reload(stale)
      assert refreshed.content["body_html_sv"] == current
      assert refreshed.rev != stale.rev
    end

    test "a doc already at the current stamp is a no-op" do
      # A fresh block_ops write is already stamped current — the task skips it.
      create_paper("rh-3", [para("p1", "current")])
      assert %{scanned: 1, rewritten: 0, noop: 1} = RehydrateBodyHtml.rehydrate()
    end

    test "changed blocks with a current stamp still regenerate stale body_html" do
      doc = create_paper("rh-4", [para("p1", "before")])

      stale_content =
        doc.content
        |> Map.put("blocks", [para("p1", "after")])
        |> Map.put("body_html_sv", Render.body_html_render_version())

      {:ok, stale} =
        doc
        |> Document.changeset(%{"content" => stale_content, "rev" => "stale-current-rev"})
        |> Repo.update()

      assert stale.content["body_html"] =~ "before"
      refute stale.content["body_html"] =~ "after"
      assert stale.content["body_html_sv"] == Render.body_html_render_version()

      assert %{scanned: 1, rewritten: 1, noop: 0} = RehydrateBodyHtml.rehydrate()

      refreshed = reload(stale)
      assert refreshed.content["body_html"] =~ "after"
      refute refreshed.content["body_html"] =~ "before"
      assert refreshed.content["body_html_sv"] == Render.body_html_render_version()
      assert refreshed.rev != stale.rev
    end

    test "historical content.body.blocks is readable authority" do
      doc = create_paper("rh-historical", [para("p1", "original")])

      historical_content =
        doc.content
        |> Map.delete("blocks")
        |> Map.put("body", %{"blocks" => [para("legacy", "nested authority")]})
        |> Map.put("body_html", "<p>STALE</p>")

      {:ok, stale} =
        doc
        |> Document.changeset(%{"content" => historical_content, "rev" => "historical-rev"})
        |> Repo.update()

      assert %{scanned: 1, rewritten: 1, errors: 0, conflicts: 0} =
               RehydrateBodyHtml.rehydrate()

      refreshed = reload(stale)
      assert refreshed.content["body_html"] =~ "nested authority"
      refute refreshed.content["body_html"] =~ "STALE"
    end

    test "an empty top-level blocks list is authoritative over historical nested blocks" do
      doc = create_paper("rh-empty-authority", [para("p1", "original")])

      empty_authority =
        doc.content
        |> Map.put("blocks", [])
        |> Map.put("body", %{"blocks" => [para("legacy", "must not render")]})
        |> Map.put("body_html", "<p>STALE</p>")

      {:ok, stale} =
        doc
        |> Document.changeset(%{"content" => empty_authority, "rev" => "empty-authority-rev"})
        |> Repo.update()

      assert %{scanned: 1, rewritten: 1} = RehydrateBodyHtml.rehydrate()

      refreshed = reload(stale)
      assert refreshed.content["body_html"] == ""
      refute refreshed.content["body_html"] =~ "must not render"
    end

    test "rehydration resolves same-id references inside the paper tenant" do
      ws_a = create_workspace!("body-html-rh-a")
      proj_a = create_project!(ws_a, "body-html-rh-pa")
      ws_b = create_workspace!("body-html-rh-b")
      proj_b = create_project!(ws_b, "body-html-rh-pb")

      for {ws, proj, title} <- [
            {ws_a, proj_a, "Rehydrate Author A"},
            {ws_b, proj_b, "Rehydrate Author B"}
          ] do
        {:ok, _} =
          Content.create_document(
            "author",
            %{"doc_id" => "shared-rh-author", "title" => title},
            @dataset,
            workspace_id: ws.id,
            project_id: proj.id
          )
      end

      blocks = [
        %{
          "id" => "title",
          "type" => "heading",
          "role" => "title",
          "level" => 1,
          "text" => "Scoped Rehydrate"
        },
        %{
          "id" => "author",
          "type" => "field-reference",
          "label" => "Author",
          "refType" => "author",
          "value" => "shared-rh-author"
        }
      ]

      {:ok, doc} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            "slug" => "rh-scoped-reference",
            "blocks" => blocks,
            "dataset" => @dataset,
            "workspace_id" => ws_b.id,
            "project_id" => proj_b.id
          })
        )

      stale_content = Map.put(doc.content, "body_html", "<p>STALE</p>")

      doc
      |> Document.changeset(%{"content" => stale_content, "rev" => "rh-scoped-stale"})
      |> Repo.update!()

      assert %{rewritten: 1, conflicts: 0, errors: 0} = RehydrateBodyHtml.rehydrate()

      refreshed = reload(doc)
      assert refreshed.content["body_html"] =~ "Rehydrate Author B"
      refute refreshed.content["body_html"] =~ "Rehydrate Author A"
    end

    test "a concurrent edit wins and is reported as a rev conflict" do
      doc = create_paper("rh-race", [para("p1", "before")])

      stale_content =
        doc.content
        |> Map.put("blocks", [para("p1", "rehydrator candidate")])
        |> Map.put("body_html", "<p>STALE</p>")

      {:ok, stale} =
        doc
        |> Document.changeset(%{"content" => stale_content, "rev" => "race-base-rev"})
        |> Repo.update()

      before_fenced_write = fn race_doc ->
        concurrent_content =
          race_doc.content
          |> Map.put("blocks", [para("p1", "concurrent author edit")])
          |> Map.put("body_html", "<p>CONCURRENT CACHE</p>")

        race_doc
        |> Document.changeset(%{
          "content" => concurrent_content,
          "rev" => "race-concurrent-rev"
        })
        |> Repo.update!()

        :ok
      end

      assert %{
               scanned: 1,
               rewritten: 0,
               noop: 0,
               conflicts: 1,
               errors: 0,
               conflict_details: [
                 %{
                   doc_id: "rh-race",
                   type: "paper",
                   dataset: @dataset,
                   rev: "race-base-rev"
                 }
               ]
             } =
               RehydrateBodyHtml.rehydrate(before_fenced_write: before_fenced_write)

      refreshed = reload(stale)
      assert refreshed.rev == "race-concurrent-rev"
      assert refreshed.content["body_html"] == "<p>CONCURRENT CACHE</p>"

      assert get_in(refreshed.content, ["blocks", Access.at(0), "content", Access.at(0), "value"]) ==
               "concurrent author edit"
    end

    test "one failed row is reported with identity while other rows still progress" do
      failed = create_paper("rh-error", [para("p1", "error candidate")])
      successful = create_paper("rh-success", [para("p1", "success candidate")])

      for doc <- [failed, successful] do
        stale_content = Map.put(doc.content, "body_html", "<p>STALE</p>")

        doc
        |> Document.changeset(%{"content" => stale_content, "rev" => "#{doc.doc_id}-stale"})
        |> Repo.update!()
      end

      persist_fun = fn changeset ->
        if changeset.data.doc_id == "rh-error" do
          {:error, Ecto.Changeset.add_error(changeset, :content, "deterministic failure")}
        else
          Repo.update(changeset)
        end
      end

      assert %{
               scanned: 2,
               rewritten: 1,
               conflicts: 0,
               errors: 1,
               error_details: [
                 %{
                   doc_id: "rh-error",
                   type: "paper",
                   dataset: @dataset,
                   reason: %{content: ["deterministic failure"]}
                 }
               ]
             } = RehydrateBodyHtml.rehydrate(persist_fun: persist_fun)

      assert reload(failed).content["body_html"] == "<p>STALE</p>"
      assert reload(successful).content["body_html"] =~ "success candidate"
    end
  end
end
