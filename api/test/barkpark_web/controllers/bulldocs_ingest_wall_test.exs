defmodule BarkparkWeb.BulldocsIngestWallTest do
  @moduledoc """
  The ingest half of the D26 wall mount, kept OUT of
  `bulldocs_ingest_controller_test.exs` (the error-head rendering slice owns
  that file): a COMPLIANT tagged ingest POST publishes — the attrs whitelist
  threads `tags` + `description` through BOTH heads (blocks and legacy
  body_html), so an honest producer can pass the wall it is now held to.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content
  alias Barkpark.LabelFixtures

  # Set in config/test.exs.
  @token "barkpark-test-ingest-token"
  @path "/v1/plugins/bulldocs/papers"
  @dataset "production"

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer #{@token}")
    |> put_req_header("content-type", "application/json")
  end

  defp labels do
    labels = LabelFixtures.paper_attrs(%{"dataset" => @dataset})
    %{"tags" => labels["tags"], "description" => labels["description"]}
  end

  defp title_block(text) do
    %{
      "id" => "tpl-title",
      "type" => "heading",
      "level" => 1,
      "role" => "title",
      "locked" => true,
      "text" => text
    }
  end

  test "a compliant tagged BLOCKS ingest POST publishes (tags + description thread through)", %{
    conn: conn
  } do
    slug = "ingest-wall-blocks-#{System.unique_integer([:positive])}"
    %{"tags" => tags, "description" => description} = labels()

    conn =
      authed(conn)
      |> post(@path, %{
        "slug" => slug,
        "blocks" => [
          title_block("Walled ingest paper"),
          %{
            "id" => "p1",
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "Honest ingest body content."}]
          }
        ],
        "tags" => tags,
        "description" => description
      })

    assert %{"ok" => true, "slug" => ^slug} = json_response(conn, 200)

    paper = Content.get_paper(slug, @dataset)
    assert paper.status == "published"
    assert paper.content["tags"] == tags
    assert paper.content["description"] == description
    # The shared stamp closes D7 for the paper birth path.
    [%{"tag" => strongest} | _] = tags
    assert paper.content["main_tag"] == strongest
  end

  test "a compliant tagged LEGACY body_html ingest POST publishes too (the second head)", %{
    conn: conn
  } do
    slug = "ingest-wall-html-#{System.unique_integer([:positive])}"
    %{"tags" => tags, "description" => description} = labels()

    conn =
      authed(conn)
      |> post(@path, %{
        "slug" => slug,
        "body_html" => "<article><h1>Legacy walled paper</h1><p>Real body.</p></article>",
        "tags" => tags,
        "description" => description
      })

    assert %{"ok" => true, "slug" => ^slug} = json_response(conn, 200)

    paper = Content.get_paper(slug, @dataset)
    assert paper.status == "published"
    assert paper.content["tags"] == tags
    assert paper.content["main_tag"] == hd(tags)["tag"]
  end

  test "a tagless ingest POST is refused — fresh ingest-born docs are never exempt (D6)", %{
    conn: conn
  } do
    slug = "ingest-wall-tagless-#{System.unique_integer([:positive])}"

    conn =
      authed(conn)
      |> post(@path, %{
        "slug" => slug,
        "blocks" => [
          title_block("Tagless ingest paper"),
          %{
            "id" => "p1",
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "Body without labels."}]
          }
        ]
      })

    # The wall refuses BEFORE any write, and the controller's render_error head
    # (ae-ingest-honest-errors / D27) renders the SPECIFIC shape: a 422 whose
    # code is label_spine with a machine-actionable hint — the exact envelope a
    # producer retries against.
    resp = json_response(conn, 422)
    assert resp["error"]["code"] == "label_spine"
    assert is_binary(resp["error"]["hint"])
    refute Content.get_paper(slug, @dataset)
  end

  test "an ingest POST with a valid label spine but an UNREGISTERED tag is refused (E3 → 422 unknown_tag, no write)",
       %{conn: conn} do
    slug = "ingest-wall-unknown-tag-#{System.unique_integer([:positive])}"

    # A spine-VALID label set (description ≥20 chars + 1–12 weighted tags with
    # distinct strengths and ≥20-char rationales) whose tag names are NOT in the
    # E3 registry — deliberately NOT registered, so the spine (E1/E2) passes and
    # the tag-registry gate (E3) is the one that refuses.
    %{"description" => description, "tags" => tags} = LabelFixtures.weighted_labels()

    conn =
      authed(conn)
      |> post(@path, %{
        "slug" => slug,
        "blocks" => [
          title_block("Unregistered-tag ingest paper"),
          %{
            "id" => "p1",
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "Body with an unregistered tag name."}]
          }
        ],
        "tags" => tags,
        "description" => description
      })

    # E3 refuses BEFORE the write (upsert_paper enforces the wall on a
    # synthesized ref ahead of its Repo write) — the 422 carries the canonical
    # unknown_tag envelope, and the unknown tag names ride in details.unknown.
    resp = json_response(conn, 422)
    assert resp["error"]["code"] == "unknown_tag"
    assert resp["error"]["details"]["unknown"] == Enum.map(tags, & &1["tag"])
    refute Content.get_paper(slug, @dataset)
  end

  test "a compliant ingest that near-duplicates a just-published incumbent is refused (E4 → 409 duplicate_of)",
       %{conn: conn} do
    # Share BOTH the title AND the registered tag set: E4 scores on the
    # title-token ∪ tag-name-token bag, so a title-only overlap dilutes below
    # the refuse floor (0.55 similarity + 3 shared tokens) into a 200+advisory.
    # Sharing the tags too pins similarity at 1.0 and shared well over the floor
    # → a hard 409. The tag names are single-token (no hyphen split) and
    # registered so both papers clear E3.
    tag_names = ["dedupledgeralpha", "dedupledgerbeta", "dedupledgergamma"]
    LabelFixtures.register_tags!(@dataset, tag_names)

    tags =
      tag_names
      |> Enum.with_index()
      |> Enum.map(fn {name, i} ->
        %{
          "tag" => name,
          "strength" => 90 - i,
          "rationale" => "Shared registered tag ##{i} driving the E4 refuse overlap in this test."
        }
      end)

    title = "Quantum ledger reconciliation protocol"

    # Ingest the incumbent — a clean corpus, so it publishes (200).
    incumbent_slug = "ingest-wall-dup-incumbent-#{System.unique_integer([:positive])}"

    incumbent_conn =
      authed(conn)
      |> post(@path, %{
        "slug" => incumbent_slug,
        "blocks" => [
          title_block(title),
          %{
            "id" => "p1",
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "The first, incumbent body content."}]
          }
        ],
        "tags" => tags,
        "description" => "Incumbent paper zq-inc-a zq-inc-b zq-inc-c zq-inc-d describing it."
      })

    assert %{"ok" => true, "slug" => ^incumbent_slug} = json_response(incumbent_conn, 200)

    # Ingest a near-identical compliant paper — same title, same registered tags,
    # different slug/body. E4 refuses it as a near-duplicate.
    dup_slug = "ingest-wall-dup-near-#{System.unique_integer([:positive])}"

    dup_conn =
      authed(build_conn())
      |> post(@path, %{
        "slug" => dup_slug,
        "blocks" => [
          title_block(title),
          %{
            "id" => "p1",
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "The second, near-duplicate body."}]
          }
        ],
        "tags" => tags,
        "description" => "Near-duplicate paper zq-dup-a zq-dup-b zq-dup-c zq-dup-d describing it."
      })

    resp = json_response(dup_conn, 409)
    assert resp["error"]["code"] == "duplicate_of"
    assert resp["error"]["details"]["duplicate_of"] == incumbent_slug
    # The refused near-duplicate is never written.
    refute Content.get_paper(dup_slug, @dataset)
  end

  test "a deliberate editorial-series ingest can persist the dedup bypass trail", %{conn: conn} do
    tag_names = ["seriesalpha", "seriesbeta", "seriesgamma"]
    LabelFixtures.register_tags!(@dataset, tag_names)

    tags =
      tag_names
      |> Enum.with_index()
      |> Enum.map(fn {name, i} ->
        %{
          "tag" => name,
          "strength" => 90 - i,
          "rationale" =>
            "Registered series tag ##{i} for an intentionally repeated chapter format."
        }
      end)

    title = "Monthly verified delivery field journal"

    for {suffix, bypass?} <- [{"april", false}, {"may", true}] do
      slug = "ingest-wall-series-#{suffix}-#{System.unique_integer([:positive])}"

      params = %{
        "slug" => slug,
        "blocks" => [
          title_block(title),
          %{
            "id" => "p1",
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "Distinct #{suffix} source interval."}]
          }
        ],
        "tags" => tags,
        "description" =>
          "The #{suffix} chapter in a deliberate calendar series with distinct evidence."
      }

      conn = authed(if(bypass?, do: build_conn(), else: conn))

      conn =
        post(conn, @path, if(bypass?, do: Map.put(params, "dedup_bypass", true), else: params))

      assert %{"ok" => true, "slug" => ^slug} = json_response(conn, 200)
      paper = Content.get_paper(slug, @dataset)
      assert paper.status == "published"
      if bypass?, do: assert(paper.content["dedup_bypass"] == true)
    end
  end

  test "a compliant ingest whose only issue is advisory returns 200 with a non-empty warnings array (D36)",
       %{conn: conn} do
    slug = "ingest-wall-advisory-#{System.unique_integer([:positive])}"

    # FIVE registered tags: a legal count (1–12) but OUTSIDE the 2–4 norm, so the
    # wall emits a non-blocking `label_norm` advisory on the warnings channel and
    # still publishes (200). A unique title keeps E4 quiet, so the tag-count
    # advisory is the ONLY warning.
    tag_names =
      for i <- 1..5, do: "advisorytag#{i}-#{System.unique_integer([:positive])}"

    LabelFixtures.register_tags!(@dataset, tag_names)

    tags =
      tag_names
      |> Enum.with_index()
      |> Enum.map(fn {name, i} ->
        %{
          "tag" => name,
          "strength" => 95 - i,
          "rationale" =>
            "Registered advisory-band tag ##{i} — five tags trips the 2–4 norm nudge."
        }
      end)

    conn =
      authed(conn)
      |> post(@path, %{
        "slug" => slug,
        "blocks" => [
          title_block("Off-norm tag-count advisory paper #{System.unique_integer([:positive])}"),
          %{
            "id" => "p1",
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "Compliant body, only an advisory."}]
          }
        ],
        "tags" => tags,
        "description" => "Advisory paper zq-adv-a zq-adv-b zq-adv-c zq-adv-d describing it well."
      })

    resp = json_response(conn, 200)
    assert resp["ok"] == true
    assert resp["slug"] == slug

    warnings = resp["warnings"]
    assert is_list(warnings) and warnings != []
    assert Enum.any?(warnings, &(&1["code"] == "label_norm"))

    # The paper still published despite the advisory — advisories never block.
    assert Content.get_paper(slug, @dataset).status == "published"
  end

  # ── the epic-quality wall reaches the wire (deploy-reliability D541/D542) ───
  #
  # AuthoringWall.enforce/5 returns SIX rejection shapes; the ingest controller
  # hand-routed only four and fell into a BARE `{:error, changeset}` catch-all,
  # which handed the wall TUPLE to Ecto.Changeset.traverse_errors/2 (one clause,
  # `%Changeset{}`) → FunctionClauseError → 500 `unknown error`. 33 of 299
  # distinct trailing-24h 500s on guerrilla's live slot were this one defect,
  # and it 500s the epic cycle's OWN wave-Paper publish. The wall had ALREADY
  # computed the named failures; the wire must carry them.

  defp epic_tags do
    LabelFixtures.register_tags!(@dataset, ["epic-cycle-wave-paper"])
    %{"tags" => tags, "description" => description} = labels()
    [strongest | rest] = tags

    %{
      "tags" => [Map.put(strongest, "tag", "epic-cycle-wave-paper") | rest],
      "description" => description
    }
  end

  test "a canonical Epic Paper that fails the quality floor is a 422 naming the failures, NOT a 500",
       %{conn: conn} do
    slug = "ingest-wall-epic-quality-#{System.unique_integer([:positive])}"
    %{"tags" => tags, "description" => description} = epic_tags()

    # No ingress, no orientation block, two meaningful blocks: the exact
    # opening-shape refusal EpicQuality computes. Before the fix this request
    # raised FunctionClauseError in Ecto.Changeset.traverse_errors/2.
    conn =
      authed(conn)
      |> post(@path, %{
        "slug" => slug,
        "blocks" => [
          title_block("Epic quality floor paper #{System.unique_integer([:positive])}"),
          %{
            "id" => "p1",
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "A body with no honest opening."}]
          }
        ],
        "tags" => tags,
        "description" => description
      })

    resp = json_response(conn, 422)
    assert resp["error"]["code"] == "invalid_epic_paper_quality"
    failures = resp["error"]["details"]["failures"]
    assert is_list(failures) and failures != []
    assert "opening_missing_ingress" in failures
    assert "opening_missing_orientation" in failures
    refute Content.get_paper(slug, @dataset)
  end

  test "the wave-30 shape: 17 top-level headings answers 422 with top_level_heading_overload", %{
    conn: conn
  } do
    slug = "ingest-wall-epic-headings-#{System.unique_integer([:positive])}"
    %{"tags" => tags, "description" => description} = epic_tags()

    # 1 title h1 + 16 level-2 headings = 17 top-level headings, one past
    # EpicQuality's @max_top_level_headings (16).
    headings =
      for i <- 1..16 do
        %{"id" => "h#{i}", "type" => "heading", "level" => 2, "text" => "Section #{i}"}
      end

    blocks =
      [
        title_block("Heading overload paper #{System.unique_integer([:positive])}"),
        %{
          "id" => "ingress",
          "type" => "ingress",
          "content" => [%{"type" => "text", "value" => "Why this wave exists, in one breath."}]
        },
        %{
          "id" => "stats",
          "type" => "stats",
          "items" => [%{"label" => "sections", "value" => "16"}]
        }
      ] ++ headings

    conn =
      authed(conn)
      |> post(@path, %{
        "slug" => slug,
        "blocks" => blocks,
        "tags" => tags,
        "description" => description
      })

    resp = json_response(conn, 422)
    assert resp["error"]["code"] == "invalid_epic_paper_quality"
    assert "top_level_heading_overload" in resp["error"]["details"]["failures"]
    refute Content.get_paper(slug, @dataset)
  end

  # ── spacing_norm (reader-owned section rhythm) ──────────────────────────────
  #
  # The pair below is the mutation proof: the SAME sectioned article is clean
  # without spacer content and trips the advisory when empty paragraph blocks
  # are inserted. Stored editor scaffolds remain legal; published composition
  # must not use them as layout. Advisory only — never blocks.

  defp sectioned_blocks(spacers?) do
    spacer = fn id -> %{"id" => id, "type" => "paragraph", "content" => []} end

    para = fn id, text ->
      %{"id" => id, "type" => "paragraph", "content" => [%{"type" => "text", "value" => text}]}
    end

    h2 = fn id, text -> %{"id" => id, "type" => "heading", "level" => 2, "text" => text} end

    [
      title_block("Sectioned spacing paper #{System.unique_integer([:positive])}"),
      para.("p0", "Intro body long enough to be an honest paragraph of content.")
    ] ++
      if(spacers?, do: [spacer.("sp1")], else: []) ++
      [
        h2.("h2a", "First section"),
        para.("p1", "First section body content, honest and specific.")
      ] ++
      if(spacers?, do: [spacer.("sp2")], else: []) ++
      [
        h2.("h2b", "Second section"),
        para.("p2", "Second section body content, honest and specific.")
      ]
  end

  test "an article ingest with 2+ level-2 headings and NO spacer blocks has no spacing_norm advisory",
       %{conn: conn} do
    slug = "ingest-wall-spacing-bare-#{System.unique_integer([:positive])}"
    %{"tags" => tags, "description" => description} = labels()

    conn =
      authed(conn)
      |> post(@path, %{
        "slug" => slug,
        "blocks" => sectioned_blocks(false),
        "tags" => tags,
        "description" => description
      })

    resp = json_response(conn, 200)
    assert resp["ok"] == true

    refute Enum.any?(List.wrap(resp["warnings"]), &(&1["code"] == "spacing_norm"))
    assert Content.get_paper(slug, @dataset).status == "published"
  end

  test "the SAME sectioned article WITH authored spacer blocks gets the non-blocking spacing_norm advisory",
       %{conn: conn} do
    slug = "ingest-wall-spacing-spaced-#{System.unique_integer([:positive])}"
    %{"tags" => tags, "description" => description} = labels()

    conn =
      authed(conn)
      |> post(@path, %{
        "slug" => slug,
        "blocks" => sectioned_blocks(true),
        "tags" => tags,
        "description" => description
      })

    resp = json_response(conn, 200)
    assert resp["ok"] == true
    spacing = Enum.find(List.wrap(resp["warnings"]), &(&1["code"] == "spacing_norm"))
    assert spacing, "expected a spacing_norm advisory, got: #{inspect(resp["warnings"])}"
    assert spacing["message"] =~ "empty paragraph"
    assert spacing["message"] =~ "remove"
    assert Content.get_paper(slug, @dataset).status == "published"
  end
end
