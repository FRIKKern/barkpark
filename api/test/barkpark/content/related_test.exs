defmodule Barkpark.Content.RelatedTest do
  @moduledoc """
  Content.Related — the tag-weighted related read (authoring-excellence
  D68–D71). Mutation-proven against the D69 scoring law:

    * LEAST min-strength credit per shared tag name (not count, not sum of
      both sides) — the PROTECTIVE ordering test below REDS if scoring
      degrades to a naive shared-tag COUNT (red run documented in the task
      ledger: SUM(LEAST(..)) mutated to COUNT(*) flips the strong-vs-many
      ordering assertion).
    * MAX-per-name dedupe on BOTH sides before summing (double-credit guard).
    * +0.5 main_tag bonus when the candidate's main_tag is a shared name.
    * titles from the `documents.title` COLUMN (content title absent/empty).
    * capped inbound-reference bonus (D70) — reference volume saturates at
      `Related.ref_bonus_cap/0` and can never drown a strong tag match.
    * a source with zero weighted tags degrades to backlink-only related.

  Docs are inserted DIRECTLY (`Repo.insert!`) — the wall is a write-time
  concern; the read must score whatever rows exist (tags_meta is a GENERATED
  column, computed however the row arrived). Edges are materialised via
  `Content.add_edges/2` exactly as the graph/backlinks suites do.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.{CallerContext, Document}
  alias Barkpark.Content.Related
  alias Barkpark.Repo

  @ds "related-test"

  # `tag_candidates/4`'s schema-visibility clamp (task-b69106868a235768) reads
  # `Schema.public_type_names/2`, which allowlists by REGISTERED schema, not by
  # absence. Every doc in this suite is `type: "post"` (insert_doc!'s default),
  # so register it here, explicit-public, exactly like `query_test.exs` /
  # `owner_scoped_test.exs` do for their own datasets — this keeps every
  # existing test byte-identical (the default schema visibility is already
  # "public"; see `schema_definition.ex:11`) while giving the new
  # private-type tests in "the schema-visibility clamp" describe block below a
  # real contrast.
  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "fields" => [%{"name" => "body", "type" => "text"}]
        },
        @ds
      )

    :ok
  end

  defp unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # Direct insert — bypasses the authoring wall (read-side suite); Postgres
  # computes tags_meta from content->'tags' regardless of how the row arrived.
  defp insert_doc!(doc_id, title, content, opts \\ []) do
    Repo.insert!(%Document{
      doc_id: doc_id,
      type: Keyword.get(opts, :type, "post"),
      dataset: Keyword.get(opts, :dataset, @ds),
      title: title,
      status: Keyword.get(opts, :status, "published"),
      content: content,
      rev: Barkpark.Content.Writer.generate_rev(),
      workspace_id: Keyword.get(opts, :workspace_id),
      project_id: Keyword.get(opts, :project_id)
    })
  end

  defp weighted(pairs) do
    %{
      "tags" =>
        Enum.map(pairs, fn {tag, strength} ->
          %{"tag" => tag, "strength" => strength, "rationale" => "r"}
        end)
    }
  end

  defp reference!(from_doc_id, to_doc_id, kind \\ "references") do
    [{:ok, _}] =
      Content.add_edges([%{from_id: from_doc_id, to_id: to_doc_id, kind: kind}], dataset: @ds)

    :ok
  end

  # A caller `Schema.bypasses_visibility_gate?/1` accepts: an authenticated,
  # non-public-read principal (mirrors `CallerContext.from_conn/1`'s resolution
  # for any real bearer token — the Studio/authoring tier).
  defp bypassing_ctx,
    do:
      CallerContext.from_token(%{
        id: "tok-rw-#{System.unique_integer([:positive])}",
        permissions: ["read"]
      })

  describe "tag leg (D69 scoring law)" do
    test "credits LEAST(src, cand)/100 per shared name and carries the shared_tags detail" do
      src = unique_id("src")
      cand = unique_id("cand")
      insert_doc!(src, "Source", weighted([{"elixir", 80}]))
      insert_doc!(cand, "Candidate", weighted([{"elixir", 30}]))

      assert [entry] = Related.related_documents(src, @ds)
      assert entry.doc_id == cand
      assert entry.sources == [:tags]
      assert_in_delta entry.score, 0.3, 0.0001
      assert entry.shared_tags == [%{tag: "elixir", src_strength: 80, cand_strength: 30}]
    end

    test "shared-name matching is case-insensitive" do
      src = unique_id("src")
      cand = unique_id("cand")
      insert_doc!(src, "Source", weighted([{"Elixir", 60}]))
      insert_doc!(cand, "Candidate", weighted([{"eLiXiR", 40}]))

      assert [entry] = Related.related_documents(src, @ds)
      assert entry.doc_id == cand
      assert_in_delta entry.score, 0.4, 0.0001
    end

    test "duplicate tag names dedupe to MAX per side BEFORE summing (double-credit guard)" do
      src = unique_id("src")
      cand = unique_id("cand")
      # Candidate carries the same name twice (case-variant) — MAX(40,70)=70
      # is the one candidate strength; a naive per-element join would credit
      # 0.4 + 0.7.
      insert_doc!(src, "Source", weighted([{"elixir", 80}]))
      insert_doc!(cand, "Candidate", weighted([{"Elixir", 40}, {"elixir", 70}]))

      assert [entry] = Related.related_documents(src, @ds)
      assert_in_delta entry.score, 0.7, 0.0001
      assert [%{tag: "elixir", src_strength: 80, cand_strength: 70}] = entry.shared_tags

      # Source-side duplicates dedupe the same way: MAX(90,20)=90 → LEAST(90,50).
      src2 = unique_id("src")
      cand2 = unique_id("cand")
      insert_doc!(src2, "Source 2", weighted([{"search", 90}, {"Search", 20}]))
      insert_doc!(cand2, "Candidate 2", weighted([{"search", 50}]))

      assert [entry2] = Related.related_documents(src2, @ds)
      assert_in_delta entry2.score, 0.5, 0.0001
    end

    test "main_tag bonus (+0.5) reorders an otherwise-tied pair" do
      src = unique_id("src")
      plain = unique_id("plain")
      main = unique_id("main")
      insert_doc!(src, "Source", weighted([{"elixir", 80}]))
      insert_doc!(plain, "A Plain", weighted([{"elixir", 30}]))

      insert_doc!(
        main,
        "B Main",
        weighted([{"elixir", 30}]) |> Map.put("main_tag", "elixir")
      )

      assert [first, second] = Related.related_documents(src, @ds)
      assert first.doc_id == main
      assert_in_delta first.score, 0.8, 0.0001
      assert second.doc_id == plain
      assert_in_delta second.score, 0.3, 0.0001
    end

    test "titles project the documents.title COLUMN, not content title" do
      src = unique_id("src")
      cand = unique_id("cand")
      insert_doc!(src, "Source", weighted([{"elixir", 50}]))
      # The proven prod trap: content->>'title' is empty for 2117/2132
      # weighted docs — the entry title must be the column value.
      insert_doc!(cand, "Column Title", weighted([{"elixir", 50}]) |> Map.put("title", ""))

      assert [entry] = Related.related_documents(src, @ds)
      assert entry.title == "Column Title"
    end

    test "PROTECTIVE (D69): one strong shared tag outranks three weak shared tags — REDS if scoring degrades to shared-tag COUNT" do
      src = unique_id("src")
      many_weak = unique_id("weak")
      one_strong = unique_id("strong")

      insert_doc!(src, "Source", weighted([{"a", 5}, {"b", 6}, {"c", 7}, {"big", 90}]))
      # 3 shared names, all weak: LEAST credits 0.05 + 0.06 + 0.07 = 0.18.
      insert_doc!(many_weak, "Many Weak", weighted([{"a", 9}, {"b", 9}, {"c", 9}]))
      # 1 shared name, strong: LEAST(90, 85) = 0.85.
      insert_doc!(one_strong, "One Strong", weighted([{"big", 85}]))

      assert [first, second] = Related.related_documents(src, @ds)

      # A naive shared-tag COUNT scores many_weak 3 vs one_strong 1 and flips
      # this ordering — the exact degradation this test exists to catch.
      assert first.doc_id == one_strong
      assert second.doc_id == many_weak
      assert first.score > second.score
      assert_in_delta first.score, 0.85, 0.0001
      assert_in_delta second.score, 0.18, 0.0001
    end

    test "malformed candidate tag elements neither match nor crash" do
      src = unique_id("src")
      junk = unique_id("junk")
      flat = unique_id("flat")
      insert_doc!(src, "Source", weighted([{"elixir", 50}]))
      # Non-digit strength fails the digits guard; a flat string fails the
      # object guard — neither is a candidate, and neither errors the query.
      insert_doc!(junk, "Junk", %{"tags" => [%{"tag" => "elixir", "strength" => "high"}]})
      insert_doc!(flat, "Flat", %{"tags" => ["elixir"]})

      assert Related.related_documents(src, @ds) == []
    end

    test "excludes self, drafts, and unpublished rows" do
      src = unique_id("src")
      draft_pfx = unique_id("draftpfx")
      unpublished = unique_id("unpub")
      insert_doc!(src, "Source", weighted([{"elixir", 50}]))
      insert_doc!("drafts." <> draft_pfx, "Draft Twin", weighted([{"elixir", 50}]))
      insert_doc!(unpublished, "Unpublished", weighted([{"elixir", 50}]), status: "draft")

      assert Related.related_documents(src, @ds) == []
    end

    test "candidates outside the dataset never surface" do
      src = unique_id("src")
      other = unique_id("other")
      insert_doc!(src, "Source", weighted([{"elixir", 50}]))
      insert_doc!(other, "Other DS", weighted([{"elixir", 50}]), dataset: "related-test-other")

      assert Related.related_documents(src, @ds) == []
    end

    test "workspace scope excludes another tenant's candidates" do
      ws_a = Barkpark.TenancyFixtures.create_workspace!()
      ws_b = Barkpark.TenancyFixtures.create_workspace!()

      # `Schema.public_type_names/2`'s workspace-scoped read is FAIL-CLOSED,
      # workspace-only (`scope_to_workspace_or_global/3` -> `scope_to_workspace/3`
      # once a non-nil `workspace_id` is given — it does NOT also admit the
      # top-level `setup` block's globally-registered "post" schema). A
      # workspace-scoped caller needs its OWN catalog entry.
      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => "post",
            "title" => "Post",
            "fields" => [%{"name" => "body", "type" => "text"}]
          },
          @ds,
          workspace_id: ws_a.id
        )

      src = unique_id("src")
      mine = unique_id("mine")
      theirs = unique_id("theirs")

      insert_doc!(src, "Source", weighted([{"elixir", 50}]), workspace_id: ws_a.id)
      insert_doc!(mine, "Mine", weighted([{"elixir", 50}]), workspace_id: ws_a.id)
      insert_doc!(theirs, "Theirs", weighted([{"elixir", 50}]), workspace_id: ws_b.id)

      ids =
        Related.related_documents(src, @ds, workspace_id: ws_a.id)
        |> Enum.map(& &1.doc_id)

      assert mine in ids
      refute theirs in ids
    end

    test ":limit clamps the result (and a bogus limit falls back to the default)" do
      src = unique_id("src")
      insert_doc!(src, "Source", weighted([{"elixir", 50}]))

      for n <- 1..3 do
        insert_doc!(unique_id("cand#{n}"), "Cand #{n}", weighted([{"elixir", 10 * n}]))
      end

      assert length(Related.related_documents(src, @ds, limit: 1)) == 1
      assert length(Related.related_documents(src, @ds, limit: "nope")) == 3
    end

    test "an unresolvable source id yields []" do
      assert Related.related_documents("no-such-doc-#{System.unique_integer()}", @ds) == []
    end
  end

  describe "reference fusion (D70)" do
    test "a source with ZERO weighted tags degrades to backlink-only related" do
      src = unique_id("src")
      ref = unique_id("ref")
      insert_doc!(src, "Untagged Source", %{"body" => "no tags"})
      insert_doc!(ref, "Referrer", %{"body" => "links"})
      reference!(ref, src)

      assert [entry] = Related.related_documents(src, @ds)
      assert entry.doc_id == ref
      assert entry.sources == [:references]
      assert entry.shared_tags == []
      assert_in_delta entry.score, 0.2, 0.0001
      assert entry.title == "Referrer"
    end

    test "a candidate that shares tags AND references the source carries both provenances" do
      src = unique_id("src")
      both = unique_id("both")
      insert_doc!(src, "Source", weighted([{"elixir", 80}]))
      insert_doc!(both, "Both", weighted([{"elixir", 30}]))
      reference!(both, src)

      assert [entry] = Related.related_documents(src, @ds)
      assert entry.sources == [:tags, :references]
      assert_in_delta entry.score, 0.3 + 0.2, 0.0001
    end

    test "PINNED cap (D70): reference volume saturates at ref_bonus_cap/0 and never outranks a strong tag match" do
      src = unique_id("src")
      hub = unique_id("hub")
      strong = unique_id("strong")

      insert_doc!(src, "Source", weighted([{"elixir", 90}]))
      insert_doc!(hub, "Hub Referrer", %{"body" => "refs a lot"})
      insert_doc!(strong, "Strong Tag Match", weighted([{"elixir", 85}]))

      # Four inbound edges (distinct kinds — (from,to,kind) is unique): the
      # bonus is min(4 × 0.2, cap) = cap, NOT 0.8. Rank by edge VOLUME is
      # capped by design; edge WEIGHT is never read at all (graph.ex law).
      for kind <- ["references", "embeds", "blocks", "related-to"] do
        reference!(hub, src, kind)
      end

      assert [first, second] = Related.related_documents(src, @ds)
      assert first.doc_id == strong
      assert_in_delta first.score, 0.85, 0.0001
      assert second.doc_id == hub
      assert_in_delta second.score, Related.ref_bonus_cap(), 0.0001
      assert first.score > second.score
    end

    test "a self-reference never relates the source to itself" do
      src = unique_id("src")
      insert_doc!(src, "Source", %{"body" => "self"})
      # Edge.changeset rejects self-edges structurally; Related's fuse-level
      # self-reject is belt-and-braces. Either way: never in its own related.
      Content.add_edges([%{from_id: src, to_id: src, kind: "embeds"}], dataset: @ds)

      assert Related.related_documents(src, @ds) == []
    end
  end

  describe "the schema-visibility clamp (task-b69106868a235768)" do
    setup do
      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => "vault",
            "title" => "Vault",
            "visibility" => "private",
            "fields" => [%{"name" => "body", "type" => "text"}]
          },
          @ds
        )

      :ok
    end

    # REGRESSION (REDS without the fix — mutation-proven): a private-visibility
    # type sharing tags with the source must not surface id, type, OR title
    # through the tag leg, for either call shape a real caller uses — the
    # default (no `caller_context` at all, the shape every other test in this
    # file uses) and an explicit `CallerContext.anonymous()`. Both land in
    # `Schema.bypasses_visibility_gate?/1`'s narrow arm.
    test "a private-type candidate sharing tags with the source is withheld from a non-bypassing caller" do
      src = unique_id("src")
      leak = unique_id("leak")
      insert_doc!(src, "Source", weighted([{"elixir", 80}]))
      insert_doc!(leak, "Private Leak", weighted([{"elixir", 30}]), type: "vault")

      default_hits = Related.related_documents(src, @ds)

      refute Enum.any?(default_hits, &(&1.doc_id == leak)),
             "private-type doc leaked id+type+title via the default call shape: #{inspect(default_hits)}"

      anon_hits = Related.related_documents(src, @ds, caller_context: CallerContext.anonymous())

      refute Enum.any?(anon_hits, &(&1.doc_id == leak)),
             "private-type doc leaked id+type+title to an explicit anonymous caller: #{inspect(anon_hits)}"
    end

    # CONTROL: the clamp is not over-broad. A caller `bypasses_visibility_gate?/1`
    # accepts (the Studio/authoring tier — any real non-public-read token) still
    # gets the private-type related row, proving the fix gates on TIER, not on
    # schema visibility alone.
    test "CONTROL: a bypassing caller_context still receives the private-type related row" do
      src = unique_id("src")
      visible = unique_id("visible")
      insert_doc!(src, "Source", weighted([{"elixir", 80}]))
      insert_doc!(visible, "Private But Authored", weighted([{"elixir", 30}]), type: "vault")

      assert [entry] = Related.related_documents(src, @ds, caller_context: bypassing_ctx())
      assert entry.doc_id == visible
      assert entry.type == "vault"
      assert entry.title == "Private But Authored"
    end
  end

  # ── The reference leg carries the SAME clamp set as the tag leg ────────────
  #
  # REGRESSION BLOCK for task-0e2bb63990e505fa. `related_documents/3` fuses two
  # legs into ONE emitted list; before this block only the TAG leg was clamped,
  # and the hardened leg is exactly what made the open one read as covered.
  #
  # Every test here uses an UNTAGGED source, so the tag leg contributes nothing
  # and the assertions isolate the reference leg. Every test also carries a
  # PUBLIC referrer that MUST survive, plus a pinned count — a clamp that
  # returns nothing passes a naive `refute` and pins nothing. All ids are
  # `unique_id/1`-scoped, so nothing here can meet another suite's rows.
  describe "the reference leg's clamp set (task-0e2bb63990e505fa)" do
    setup do
      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => "vault",
            "title" => "Vault",
            "visibility" => "private",
            "fields" => [%{"name" => "body", "type" => "text"}]
          },
          @ds
        )

      :ok
    end

    # REGRESSION: the LIVE leak. `Papers.Proposals.add_provenance_edge/4` pins
    # a `proposal-source` edge to the DRAFT row's PK on purpose, so every
    # unapproved AI paper proposal was a `drafts.`-prefixed referrer emitting
    # its title through this door.
    test "a drafts.-prefixed referrer is withheld, and the published referrer still surfaces" do
      src = unique_id("src")
      ok = unique_id("okref")
      leak = unique_id("draftref")

      insert_doc!(src, "Untagged Source", %{"body" => "no tags"})
      insert_doc!(ok, "Published Referrer", %{"body" => "links"})
      insert_doc!("drafts." <> leak, "Draft Referrer", %{"body" => "links"})

      reference!(ok, src)
      reference!("drafts." <> leak, src)

      hits = Related.related_documents(src, @ds)
      ids = Enum.map(hits, & &1.doc_id)

      refute ("drafts." <> leak) in ids,
             "drafts.-prefixed referrer leaked through the reference leg: #{inspect(hits)}"

      # CONTROL — the clamp is not "return nothing": the published referrer
      # survives, and the COUNT is pinned (a surviving count is an existence
      # leak on its own).
      assert ids == [ok]
      assert length(hits) == 1
      assert match?([%{sources: [:references], title: "Published Referrer"}], hits)
    end

    test ~S(a status:"draft" referrer is withheld, and the published referrer still surfaces) do
      src = unique_id("src")
      ok = unique_id("okref")
      leak = unique_id("unpubref")

      insert_doc!(src, "Untagged Source", %{"body" => "no tags"})
      insert_doc!(ok, "Published Referrer", %{"body" => "links"})
      insert_doc!(leak, "Unpublished Referrer", %{"body" => "links"}, status: "draft")

      reference!(ok, src)
      reference!(leak, src)

      hits = Related.related_documents(src, @ds)
      ids = Enum.map(hits, & &1.doc_id)

      refute leak in ids,
             "status=draft referrer leaked through the reference leg: #{inspect(hits)}"

      assert ids == [ok]
      assert length(hits) == 1
    end

    test "a private-visibility-type referrer is withheld from a non-bypassing caller" do
      src = unique_id("src")
      ok = unique_id("okref")
      leak = unique_id("vaultref")

      insert_doc!(src, "Untagged Source", %{"body" => "no tags"})
      insert_doc!(ok, "Published Referrer", %{"body" => "links"})
      insert_doc!(leak, "Vault Referrer", %{"body" => "links"}, type: "vault")

      reference!(ok, src)
      reference!(leak, src)

      # Both call shapes a real caller uses: the default (no caller_context)
      # and an explicit anonymous one. Both land in the narrow arm of
      # `Schema.bypasses_visibility_gate?/1`.
      for {label, hits} <- [
            {"default", Related.related_documents(src, @ds)},
            {"anonymous",
             Related.related_documents(src, @ds, caller_context: CallerContext.anonymous())}
          ] do
        ids = Enum.map(hits, & &1.doc_id)

        refute leak in ids,
               "private-type referrer leaked via the #{label} call shape: #{inspect(hits)}"

        assert ids == [ok], "#{label} lost the public control referrer: #{inspect(hits)}"
        assert length(hits) == 1
      end
    end

    # CONTROL, two ways at once: the visibility clamp gates on TIER (a
    # bypassing token DOES get the private-type referrer, so the clamp is not
    # over-broad), while the published-perspective clamp is caller-INDEPENDENT
    # (that same token still never sees the draft).
    test "CONTROL: a bypassing caller gets the private-type referrer but STILL not the draft" do
      src = unique_id("src")
      ok = unique_id("okref")
      vault = unique_id("vaultref")
      draft = unique_id("draftref")

      insert_doc!(src, "Untagged Source", %{"body" => "no tags"})
      insert_doc!(ok, "Published Referrer", %{"body" => "links"})
      insert_doc!(vault, "Vault Referrer", %{"body" => "links"}, type: "vault")
      insert_doc!("drafts." <> draft, "Draft Referrer", %{"body" => "links"})

      reference!(ok, src)
      reference!(vault, src)
      reference!("drafts." <> draft, src)

      hits = Related.related_documents(src, @ds, caller_context: bypassing_ctx())
      ids = hits |> Enum.map(& &1.doc_id) |> Enum.sort()

      assert ids == Enum.sort([ok, vault]),
             "bypassing caller got the wrong reference set: #{inspect(hits)}"

      assert length(hits) == 2

      vault_hit = Enum.find(hits, &(&1.doc_id == vault))
      assert match?(%{type: "vault", title: "Vault Referrer"}, vault_hit)

      refute ("drafts." <> draft) in ids,
             "published perspective is caller-independent — a bypassing token must not see the draft: #{inspect(hits)}"
    end

    # `Graph.reverse_referencers/2` reads `content_edges` by `to_id` alone
    # (`edge_opts/1` forwards only `:kind`), so an edge whose source lives in
    # another dataset surfaces unless the DOOR filters it. The tag leg always
    # did; the reference leg did not.
    test "a referrer in another dataset is withheld, and the in-dataset referrer still surfaces" do
      src = unique_id("src")
      ok = unique_id("okref")
      leak = unique_id("otherdsref")

      insert_doc!(src, "Untagged Source", %{"body" => "no tags"})
      insert_doc!(ok, "Published Referrer", %{"body" => "links"})

      insert_doc!(leak, "Other Dataset Referrer", %{"body" => "links"},
        dataset: "related-test-other"
      )

      reference!(ok, src)

      # Resolved with NO dataset scope so the cross-dataset edge can exist at
      # all — exactly the row `content_edges` would hold if a projector ever
      # materialised one.
      [{:ok, _}] = Content.add_edges([%{from_id: leak, to_id: src, kind: "references"}], [])

      hits = Related.related_documents(src, @ds)
      ids = Enum.map(hits, & &1.doc_id)

      refute leak in ids,
             "cross-dataset referrer leaked through the reference leg: #{inspect(hits)}"

      assert ids == [ok]
      assert length(hits) == 1
    end
  end
end
