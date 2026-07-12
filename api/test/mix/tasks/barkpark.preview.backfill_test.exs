defmodule Mix.Tasks.Barkpark.Preview.BackfillTest do
  @moduledoc """
  Exercises `mix barkpark.preview.backfill` (pc-w3c) end-to-end against a real
  Repo: the dry-run default writes nothing, `--apply` stamps `content["preview"]`
  via a no-broadcast `Repo.update`, the sweep is idempotent, the media resolver
  is bound to each doc's OWN tenancy scope (a cross-tenant blob never resolves),
  drafts are skipped, a poison doc is caught per-doc, and — the load-bearing
  guard — a marked-up paragraph backfills to a CLEAN description, proving the run
  rides the fixed `Preview.node_text` inline-mark recursion (pc-w2b), not the
  pre-fix extractor that garbled `/papers/theme-system`.
  """

  use Barkpark.DataCase, async: false

  import ExUnit.CaptureIO

  alias Barkpark.Content.Document
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias Mix.Tasks.Barkpark.Preview.Backfill

  setup do
    prev_shell = Mix.shell()
    Mix.shell(Mix.Shell.IO)
    on_exit(fn -> Mix.shell(prev_shell) end)
    :ok
  end

  # ── fixtures ────────────────────────────────────────────────────────────────

  defp paragraph(text),
    do: %{"id" => "p", "type" => "paragraph", "content" => [%{"type" => "text", "value" => text}]}

  defp seed_paper(doc_id, opts) do
    content =
      %{"blocks" => Keyword.get(opts, :blocks, [paragraph("Lead prose for #{doc_id}.")])}
      |> Map.merge(Keyword.get(opts, :content, %{}))

    attrs =
      %{
        "doc_id" => doc_id,
        "type" => Keyword.get(opts, :type, "paper"),
        "dataset" => "production",
        "title" => Keyword.get(opts, :title, "Title #{doc_id}"),
        "status" => Keyword.get(opts, :status, "published"),
        "content" => content,
        "rev" => "rev_#{doc_id}_#{System.unique_integer([:positive])}"
      }
      |> maybe_put("workspace_id", Keyword.get(opts, :workspace_id))
      |> maybe_put("project_id", Keyword.get(opts, :project_id))

    {:ok, doc} = %Document{} |> Document.changeset(attrs) |> Repo.insert()
    doc
  end

  defp seed_media(path, dataset, opts) do
    attrs =
      %{
        filename: Path.basename(path),
        original_name: Path.basename(path),
        path: path,
        mime_type: "image/png",
        size: 42,
        dataset: dataset
      }
      |> maybe_put_atom(:workspace_id, Keyword.get(opts, :workspace_id))
      |> maybe_put_atom(:project_id, Keyword.get(opts, :project_id))

    %MediaFile{} |> MediaFile.changeset(attrs) |> Repo.insert!()
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
  defp maybe_put_atom(map, _key, nil), do: map
  defp maybe_put_atom(map, key, value), do: Map.put(map, key, value)

  defp make_scope(ws_slug, project_slug) do
    {:ok, ws} = Tenancy.create_workspace(%{slug: ws_slug, name: ws_slug})
    {:ok, project} = Tenancy.create_project(ws, %{slug: project_slug, name: project_slug})
    {ws, project}
  end

  defp reload(%Document{id: id}), do: Repo.get!(Document, id)
  defp preview_of(doc), do: reload(doc).content["preview"]

  # ── dry-run is the safe default ─────────────────────────────────────────────

  describe "dry-run (default) writes nothing" do
    test "reports would-stamp but leaves content[preview] absent" do
      doc = seed_paper("dry-legacy", [])

      {:ok, stats} = Backfill.backfill(dry_run: true)

      assert stats.dry_run
      assert stats.scanned >= 1
      assert Enum.any?(stats.stamped, &(&1.slug == "dry-legacy"))
      # The safe default writes NOTHING.
      assert preview_of(doc) == nil
    end

    test "the Mix task with no args is a dry run" do
      seed_paper("bare-run", [])

      output = capture_io(fn -> Backfill.run([]) end)

      assert output =~ "preview backfill (dry-run)"
      assert output =~ "Dry run — nothing was written"
      assert preview_of(%Document{id: Repo.get_by!(Document, doc_id: "bare-run").id}) == nil
    end
  end

  # ── --apply stamps a real manifest ──────────────────────────────────────────

  describe "--apply stamps content[preview]" do
    test "a legacy paper gains a title/description/type/url manifest" do
      doc =
        seed_paper("apply-legacy",
          title: "Hello Paper",
          blocks: [paragraph("The lead paragraph becomes the description.")]
        )

      {:ok, stats} = Backfill.backfill(dry_run: false)

      refute stats.dry_run
      assert Enum.any?(stats.stamped, &(&1.slug == "apply-legacy"))

      m = preview_of(doc)
      assert m["title"] == "Hello Paper"
      assert m["type"] == "paper"
      assert m["url"] == "/papers/apply-legacy"
      assert m["description"] == "The lead paragraph becomes the description."
    end

    test "does NOT bump content[rev] or the row rev, and leaves title/status/scope" do
      {ws, project} = make_scope("bf-rev-ws", "bf-rev-proj")

      doc =
        seed_paper("apply-norev",
          title: "Keep My Title",
          workspace_id: ws.id,
          project_id: project.id,
          content: %{"rev" => 7}
        )

      before = reload(doc)

      {:ok, _stats} = Backfill.backfill(dry_run: false)

      after_doc = reload(doc)
      # content["preview"] appeared…
      assert is_map(after_doc.content["preview"])
      # …but the render-identity fields are untouched.
      assert after_doc.content["rev"] == 7
      assert after_doc.rev == before.rev
      assert after_doc.title == "Keep My Title"
      assert after_doc.status == "published"
      assert after_doc.workspace_id == ws.id
      assert after_doc.project_id == project.id
    end
  end

  # ── idempotency ─────────────────────────────────────────────────────────────

  describe "idempotent" do
    test "a second --apply run is a no-op (unchanged, no Repo.update)" do
      doc = seed_paper("idem", [])

      {:ok, first} = Backfill.backfill(dry_run: false)
      assert Enum.any?(first.stamped, &(&1.slug == "idem"))

      stamped_row = reload(doc)

      {:ok, second} = Backfill.backfill(dry_run: false)

      # The manifest already matches → skipped, not re-stamped.
      refute Enum.any?(second.stamped, &(&1.slug == "idem"))
      assert second.unchanged >= 1

      # No Repo.update on the second pass → updated_at is byte-stable.
      assert reload(doc).updated_at == stamped_row.updated_at
    end
  end

  # ── garble guard: rides the fixed node_text (pc-w2b) ────────────────────────

  describe "garble guard — inline-mark children flow to a clean description" do
    # The canonical stored inline shape wraps a marked span's text under
    # "children" (inline.ex compose_inline). Before pc-w2b's node_text children
    # clause, every strong/em span silently vanished — the live
    # 'Barkpahis paper… writes , a compiler' garble. This proves the BACKFILL
    # rides the fixed extractor: a stale-branch build would stamp garble here.
    test "a text/strong/text/strong/text paragraph backfills to a clean sentence" do
      nodes = [
        %{"type" => "text", "value" => "Barkpark "},
        %{"type" => "strong", "children" => [%{"type" => "text", "value" => "compiles"}]},
        %{"type" => "text", "value" => " papers into a "},
        %{"type" => "strong", "children" => [%{"type" => "text", "value" => "manifest"}]},
        %{"type" => "text", "value" => "."}
      ]

      marked = %{"id" => "p", "type" => "paragraph", "content" => nodes}
      doc = seed_paper("garble", blocks: [marked])

      {:ok, _stats} = Backfill.backfill(dry_run: false)

      desc = preview_of(doc)["description"]
      # Clean — every marked span survives, in order, with no dropped fragments.
      assert desc == "Barkpark compiles papers into a manifest."
      refute desc =~ "Barkpahis"
    end
  end

  # ── scoped media resolver (barkpark-af50) ───────────────────────────────────

  describe "the media resolver is bound to the doc's OWN scope" do
    setup do
      {ws_a, proj_a} = make_scope("bf-a", "bf-pa")
      {ws_b, proj_b} = make_scope("bf-b", "bf-pb")
      %{ws_a: ws_a, proj_a: proj_a, ws_b: ws_b, proj_b: proj_b}
    end

    test "an in-scope media file resolves to its og rendition", ctx do
      path = "uploads/production/hero.png"
      file = seed_media(path, "production", workspace_id: ctx.ws_a.id, project_id: ctx.proj_a.id)

      image = %{
        "id" => "img",
        "type" => "image",
        "role" => "featured",
        "src" => "/media/files/#{path}",
        "alt" => "Hero"
      }

      doc =
        seed_paper("img-in-scope",
          workspace_id: ctx.ws_a.id,
          project_id: ctx.proj_a.id,
          blocks: [image, paragraph("Body.")]
        )

      {:ok, stats} = Backfill.backfill(dry_run: false)

      m = preview_of(doc)
      assert m["image"]["url"] == "/media/renditions/#{file.id}/og"
      assert m["image"]["width"] == 1200
      assert m["image"]["height"] == 630
      assert m["image"]["alt"] == "Hero"
      assert Enum.any?(stats.stamped, &(&1.slug == "img-in-scope" and &1.has_image))
    end

    test "a media file owned by ANOTHER workspace does NOT resolve (no cross-tenant leak)",
         ctx do
      path = "uploads/production/secret.png"
      # The blob lives in workspace B…
      seed_media(path, "production", workspace_id: ctx.ws_b.id, project_id: ctx.proj_b.id)

      image = %{
        "id" => "img",
        "type" => "image",
        "src" => "/media/files/#{path}"
      }

      # …but the paper (and thus the resolver scope) is workspace A.
      doc =
        seed_paper("img-cross-tenant",
          workspace_id: ctx.ws_a.id,
          project_id: ctx.proj_a.id,
          blocks: [image, paragraph("Body.")]
        )

      {:ok, _stats} = Backfill.backfill(dry_run: false)

      # The scoped resolver saw A's scope → B's blob is invisible → image nil.
      assert preview_of(doc)["image"] == nil
    end
  end

  # ── draft exclusion ─────────────────────────────────────────────────────────

  describe "drafts are never touched" do
    test "a draft block-doc is not scanned or stamped" do
      draft = seed_paper("draft-doc", status: "draft")
      published = seed_paper("published-doc", [])

      {:ok, stats} = Backfill.backfill(dry_run: false)

      refute Enum.any?(stats.stamped, &(&1.slug == "draft-doc"))
      assert Enum.any?(stats.stamped, &(&1.slug == "published-doc"))
      assert preview_of(draft) == nil
      assert is_map(preview_of(published))
    end
  end

  # ── block gate + type gate ──────────────────────────────────────────────────

  describe "only block-bearing block-typed docs are swept" do
    test "a published non-block-type doc is ignored" do
      # A `post` is published but not in the block-bearing set.
      seed_paper("a-post", type: "post")

      {:ok, stats} = Backfill.backfill(dry_run: false)

      refute Enum.any?(stats.stamped, &(&1.slug == "a-post"))
    end

    test "a block-typed doc with no blocks list is ignored" do
      # No "blocks" key → not block-bearing (is_list gate).
      {:ok, doc} =
        %Document{}
        |> Document.changeset(%{
          "doc_id" => "no-blocks",
          "type" => "paper",
          "dataset" => "production",
          "title" => "No blocks",
          "status" => "published",
          "content" => %{"body_html" => "<p>legacy html only</p>"},
          "rev" => "rev_no_blocks"
        })
        |> Repo.insert()

      {:ok, stats} = Backfill.backfill(dry_run: false)

      refute Enum.any?(stats.stamped, &(&1.slug == "no-blocks"))
      assert reload(doc).content["preview"] == nil
    end
  end

  # ── per-doc rescue ──────────────────────────────────────────────────────────

  describe "per-doc rescue" do
    test "a poison doc is recorded in errors and the sweep continues" do
      # A nested-list author element makes Preview's element_name/1 call
      # to_string/1 on a list containing a map, which raises (List.Chars) —
      # the per-doc rescue must catch it and keep going. (A bare map no
      # longer raises: dual-shape string_list drops non-tag maps, D18.)
      seed_paper("poison", content: %{"authors" => [["bad", %{"x" => 1}]]})
      good = seed_paper("survivor", [])

      {:ok, stats} = Backfill.backfill(dry_run: false)

      assert Enum.any?(stats.errors, &(&1.slug == "poison"))
      # The good doc after the poison one still got stamped.
      assert Enum.any?(stats.stamped, &(&1.slug == "survivor"))
      assert is_map(preview_of(good))
    end

    test "the Mix task halts nonzero-style when errors occur (report shows them)" do
      seed_paper("poison2", content: %{"authors" => [%{"bad" => "map"}]})

      # run/1 calls System.halt on errors; drive the report through log_report to
      # assert the errors section renders without terminating the test VM.
      {:ok, stats} = Backfill.backfill(dry_run: true)
      output = capture_io(fn -> Backfill.log_report(stats, &IO.puts/1) end)

      assert output =~ "errors:"
      assert output =~ "poison2"
    end
  end
end
