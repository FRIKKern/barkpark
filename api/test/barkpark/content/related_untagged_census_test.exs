defmodule Barkpark.Content.RelatedUntaggedCensusTest do
  @moduledoc """
  The untagged-share figure quoted by `Barkpark.Content.Related` — its
  instrument, and its lock (task-7dea99bc5fd5b136).

  The moduledoc used to assert "the ~35% untagged corpus" with no derivation,
  and the same words were copied verbatim into `web/lib/related-shape.ts` and
  `web/lib/related.ts`. Three agreeing sites are what made repetition read as
  measurement. This suite replaces that with two things a reader can check:

    * **the instrument** — the census SQL the moduledoc publishes is RUN here
      against a seeded corpus whose tagged/untagged split is known, so the
      query is proven to count what it claims BEFORE its output is quoted,
      and it is tied to the shipped behaviour (an untagged source really does
      take `Related`'s backlink-only degrade path);
    * **the lock** — all three sites must carry the SAME figure, census name,
      date and counts, so a repair that moves only one of them reds. A
      half-finished repair (three sites disagreeing) is strictly worse than
      the consistent-but-wrong state it replaces.

  The retired figure is governed by a PREDICATE, not a blocklist: `35%` may
  appear only on a line that also says "retired". An honest repair has to
  re-quote a retired number in order to label it false, so a bare
  count-of-occurrences criterion cannot work here — it goes UP on a correct
  fix.
  """

  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.{Document, Related}
  alias Barkpark.Repo

  @dataset "related-census-#{System.unique_integer([:positive])}"

  # ── The census, verbatim from the Related moduledoc ─────────────────────────
  #
  # `tags_meta` is a GENERATED column that is ALWAYS a jsonb array
  # (20260718100000_add_documents_tags_meta_generated_column), so no NULL /
  # non-array guard is needed. The element guards are the ones `@tag_leg_sql`
  # and `weighted_entry?/1` apply, which is the whole point: "untagged" here
  # means what the TAG LEG means by it, not "has no tags key".
  @census_sql """
  SELECT count(*) FILTER (WHERE weighted)     AS weighted,
         count(*) FILTER (WHERE NOT weighted) AS untagged,
         count(*)                             AS total
  FROM (
    SELECT EXISTS (
             SELECT 1
             FROM jsonb_array_elements(d.tags_meta) AS e
             WHERE jsonb_typeof(e) = 'object'
               AND e->>'tag' IS NOT NULL
               AND e->>'strength' ~ '^[0-9]+$'
           ) AS weighted
    FROM documents d
    WHERE d.status = 'published' AND d.type = 'paper' AND d.dataset = $1
  ) s
  """

  # The shipped figure and its provenance. Every token here must appear in all
  # three mirror sites.
  @figure_tokens ["27%", "charter D77", "2026-07-22", "127/467"]

  @related_ex Path.expand("../../../lib/barkpark/content/related.ex", __DIR__)
  @related_shape_ts Path.expand("../../../../web/lib/related-shape.ts", __DIR__)
  @related_ts Path.expand("../../../../web/lib/related.ts", __DIR__)

  defp seed_doc(doc_id, tags) do
    now = DateTime.utc_now()

    {1, _} =
      Repo.insert_all(Document, [
        %{
          doc_id: doc_id,
          type: "paper",
          dataset: @dataset,
          title: doc_id,
          status: "published",
          content: %{"tags" => tags},
          rev: Barkpark.Content.Writer.generate_rev(),
          inserted_at: now,
          updated_at: now
        }
      ])

    doc_id
  end

  defp census do
    %Postgrex.Result{rows: [[weighted, untagged, total]]} =
      Repo.query!(@census_sql, [@dataset])

    %{weighted: weighted, untagged: untagged, total: total}
  end

  describe "the census SQL is a proven instrument, not an assumption" do
    setup do
      # `tag_candidates/4`'s schema-visibility clamp allowlists by REGISTERED
      # schema, not by absence (see related_test.exs). Without this the
      # behavioural arm below returns [] for EVERY doc and the two `== []`
      # assertions go vacuous — which is exactly how the positive control
      # caught it on the first run.
      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => "paper",
            "title" => "Paper",
            "fields" => [%{"name" => "body", "type" => "text"}]
          },
          @dataset
        )

      # 3 weighted-tagged …
      seed_doc("cw-int", [%{"tag" => "search", "strength" => 75}])
      seed_doc("cw-str", [%{"tag" => "guards", "strength" => "50"}])
      seed_doc("cw-mixed", [%{"tag" => "docs", "strength" => 10}, "legacy-flat"])

      # … and 4 that the TAG LEG cannot use, i.e. untagged by this definition.
      seed_doc("cu-empty", [])
      seed_doc("cu-flat-only", ["legacy-flat", "another"])
      seed_doc("cu-no-strength", [%{"tag" => "search"}])
      seed_doc("cu-bad-strength", [%{"tag" => "search", "strength" => "high"}])

      :ok
    end

    test "counts the seeded split exactly — and BOTH arms are non-zero" do
      c = census()

      # Two-way control. A counter that has never returned non-zero on one of
      # its arms has not been shown to discriminate; a 0/7 or 7/0 here would
      # pass a naive "it ran" check while measuring nothing.
      assert c.weighted == 3, "weighted arm: expected 3, got #{c.weighted}"
      assert c.untagged == 4, "untagged arm: expected 4, got #{c.untagged}"
      assert c.total == 7
      assert c.weighted + c.untagged == c.total

      # The share this corpus yields, by the same arithmetic the moduledoc
      # shows for D77 (127 / 467).
      assert_in_delta c.untagged / c.total * 100, 57.1, 0.1
    end

    test "a flat-string-only source is UNTAGGED to the census AND to Related" do
      # Ties the census predicate to the shipped behaviour: the row the census
      # calls untagged is exactly the row whose tag leg contributes nothing, so
      # it takes the backlink-only degrade path the figure describes.
      assert Related.related_documents("cu-flat-only", @dataset) == []
      assert Related.related_documents("cu-no-strength", @dataset) == []

      # Control in the other direction: two weighted-tagged rows sharing a tag
      # name DO fuse, so "[] for everything" is not the reason above.
      seed_doc("cw-int-twin", [%{"tag" => "search", "strength" => 60}])

      assert [%{doc_id: "cw-int-twin"}] =
               Related.related_documents("cw-int", @dataset)
    end
  end

  describe "the three mirror sites move together" do
    test "every site carries the same figure, census name, date and counts" do
      for {label, path} <- [
            {"api/lib/barkpark/content/related.ex", @related_ex},
            {"web/lib/related-shape.ts", @related_shape_ts},
            {"web/lib/related.ts", @related_ts}
          ] do
        body = File.read!(path)

        for token <- @figure_tokens do
          assert String.contains?(body, token), """
          #{label} does not carry #{inspect(token)}.

          The untagged-share figure is mirrored in THREE files and they must
          agree: api/lib/barkpark/content/related.ex, web/lib/related-shape.ts
          and web/lib/related.ts. Correcting one and leaving the others is
          worse than the state it replaces, because today's agreement is the
          only thing that makes the number look measured. Update all three.
          """
        end
      end
    end

    test "the retired figure may appear ONLY on a line that retracts it" do
      offenders =
        for {label, path} <- [
              {"api/lib/barkpark/content/related.ex", @related_ex},
              {"web/lib/related-shape.ts", @related_shape_ts},
              {"web/lib/related.ts", @related_ts}
            ],
            {line, n} <- Enum.with_index(String.split(File.read!(path), "\n"), 1),
            asserts_retired_figure?(line),
            do: "#{label}:#{n}: #{String.trim(line)}"

      assert offenders == [], """
      A site asserts the retired ~35% untagged figure without retracting it:

      #{Enum.join(offenders, "\n")}

      It is underived (its introducing commit ba53e7b93 / #5615 carries no
      figure) and ~8 points high against charter D77's census. Quote it only
      to label it retired.
      """
    end

    test "CONTROL: the retired-figure detector actually fires" do
      # A zero from an instrument that has never returned non-zero is not an
      # absence claim. Both arms, on synthetic lines.
      assert asserts_retired_figure?(" * — the ~35% untagged corpus.")
      refute asserts_retired_figure?(" * (a) the retired \"~35%\" named no census")
      refute asserts_retired_figure?(" * ~27% of the published paper corpus")
    end
  end

  defp asserts_retired_figure?(line) do
    String.contains?(line, "35%") and not String.contains?(String.downcase(line), "retired")
  end
end
