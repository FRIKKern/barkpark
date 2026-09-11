defmodule BarkparkWeb.BulldocsOpsDoorEditContractTest do
  @moduledoc """
  THE CONTRACT PIN for `POST /v1/plugins/bulldocs/papers/:slug/ops`, and the
  place `docs/contracts/plugin-http-api.md` sends a reader for the reasoning
  it has no byte budget to carry.

  THE RULING (api lane, task-14107740b20c92fa). The ops door is an EDIT door.
  It deliberately does NOT mount `Barkpark.Content.AuthoringWall.enforce/5`.
  Its whole contract is the two non-regression ratchets in
  `Barkpark.Content.Papers.BlockOps` — `ratchet_hollow/2` (a paper that HAS
  content may not be edited back down to the bare skeleton) and
  `reject_new_field_loss/2` (a clean note/card block may not be edited into
  the shape that renders no prose). The publish door
  (`POST /v1/plugins/bulldocs/papers`) and the ingest legs enforce the
  whole-document floor: label spine, tag registry, dedup scan, epic quality
  caps, structure.

  WHY THE WALL DOES NOT MOUNT HERE.

    1. The five gates are whole-document FLOORS. A per-op mount would either
       refuse every edit to a paper already past a floor — bricking exactly
       the papers most in need of editing — or need a ratcheted variant of
       every gate: five new mechanisms for one accidental asymmetry.
    2. A dedup scan run per keystroke-level op is a cost with no
       author-facing meaning.
    3. The edit door's design is non-regression, and the floor is re-applied
       the next time the slug goes through the publish/ingest door.

  THE HONEST CAVEAT. A paper that is only ever edited via `/ops` after its
  last publish can sit past the floor indefinitely. The floor is a
  PUBLISH-TIME property, not an invariant of the stored row. That is the
  cost of the ruling, stated rather than hidden.

  THESE TESTS RED IF SOMEONE MOUNTS THE WALL ON /ops. That is intentional: an
  intended future change updates this file and the contract doc TOGETHER, so
  the ruling can never drift away from the code silently.

  THE CONTROL is the second half of the first test: the SAME content the ops
  door accepted is refused 422 `invalid_epic_paper_quality` by the publish
  door. Without it, a 200 from /ops would prove nothing — the floor might
  simply not exist anywhere.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.Papers.EpicQuality
  alias Barkpark.LabelFixtures

  # Set in config/test.exs.
  @token "barkpark-test-ingest-token"
  @publish_path "/v1/plugins/bulldocs/papers"
  @dataset "production"

  # The caps the publish-time floor enforces. `EpicQuality` keeps them in
  # PRIVATE module attributes (@max_top_level_blocks / @max_top_level_headings)
  # with no public accessor, so these two are RETYPED literals, not read from
  # the module. The last test in this file is the pin that reds if the module's
  # values ever move away from them.
  @max_blocks 80
  @max_headings 16

  @epic_quality_source Path.expand(
                         "../../../lib/barkpark/content/papers/epic_quality.ex",
                         __DIR__
                       )

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer #{@token}")
    |> put_req_header("content-type", "application/json")
  end

  defp text(value), do: [%{"type" => "text", "value" => value}]

  defp paragraph(id, value),
    do: %{"id" => id, "type" => "paragraph", "content" => text(value)}

  defp heading(id, text), do: %{"id" => id, "type" => "heading", "level" => 2, "text" => text}

  # A canonical Epic Cycle Paper sitting EXACTLY at both caps: 80 top-level
  # blocks of which 16 are top-level headings (the title h1 plus 15 h2s, so
  # the outline still has exactly one h1 and no level jump).
  defp at_cap_blocks do
    opening = [
      %{
        "id" => "tpl-title",
        "type" => "heading",
        "level" => 1,
        "role" => "title",
        "locked" => true,
        "text" => "Wave paper at both editorial caps"
      },
      %{
        "id" => "ingress",
        "type" => "ingress",
        "content" => text("Why this wave exists and what the evidence changes.")
      },
      %{
        "id" => "stats",
        "type" => "stats",
        "items" => [%{"label" => "criteria proved", "value" => "7"}]
      }
    ]

    sections =
      Enum.flat_map(1..(@max_headings - 1), fn i ->
        [
          heading("h-#{i}", "Section #{i}")
          | Enum.map(1..4, fn j ->
              paragraph("p-#{i}-#{j}", "Section #{i} paragraph #{j} carries real argument.")
            end)
        ]
      end)

    tail =
      Enum.map(1..2, fn j ->
        paragraph("tail-#{j}", "Closing paragraph #{j} carries real argument.")
      end)

    blocks = opening ++ sections ++ tail

    # Assert the FIXTURE, not just the verdict: a paper that was never at the
    # caps would make both halves of this test vacuous.
    assert length(blocks) == @max_blocks
    assert Enum.count(blocks, &(&1["type"] == "heading")) == @max_headings

    blocks
  end

  defp epic_labels do
    LabelFixtures.register_tags!(@dataset, [EpicQuality.canonical_tag()])
    labels = LabelFixtures.paper_attrs(%{"dataset" => @dataset})
    [strongest | rest] = labels["tags"]

    %{
      "tags" => [Map.put(strongest, "tag", EpicQuality.canonical_tag()) | rest],
      "description" => labels["description"]
    }
  end

  defp publish(blocks, slug, labels) do
    Phoenix.ConnTest.build_conn()
    |> authed()
    |> post(
      @publish_path,
      Map.merge(labels, %{"slug" => slug, "dataset" => @dataset, "blocks" => blocks})
    )
  end

  defp apply_op(slug, op) do
    Phoenix.ConnTest.build_conn()
    |> authed()
    |> post("#{@publish_path}/#{slug}/ops", Map.put(op, "slug", slug))
  end

  defp rev(slug), do: get_in(Content.get_paper(slug, @dataset).content, ["rev"])

  test "the /ops door is an EDIT door: it does not mount the AuthoringWall, and the publish door does" do
    slug = "ops-door-contract-#{System.unique_integer([:positive])}"
    labels = epic_labels()
    blocks = at_cap_blocks()

    # The paper publishes AT both caps — so the floor is satisfied at birth and
    # the refusal below can only come from what the ops door appended.
    assert %{"ok" => true, "slug" => ^slug} = json_response(publish(blocks, slug, labels), 200)

    rev0 = rev(slug)

    # (1) A 17th top-level heading — one past @max_top_level_headings, and the
    # 81st top-level block — is ACCEPTED by the ops door.
    conn1 =
      apply_op(slug, %{
        "op" => "append-block",
        "block" => heading("h-overflow", "Section 16 — one heading past the cap")
      })

    assert %{"ok" => true, "rev" => rev1} = json_response(conn1, 200)
    assert rev1 == rev0 + 1

    # (2) An 82nd top-level block is accepted too — the block cap is no more
    # enforced here than the heading cap.
    conn2 =
      apply_op(slug, %{
        "op" => "append-block",
        "block" => paragraph("p-overflow", "One block past the top-level block cap.")
      })

    assert %{"ok" => true, "rev" => rev2} = json_response(conn2, 200)
    assert rev2 == rev1 + 1

    stored = Content.paper_blocks(slug, @dataset)
    assert length(stored) == @max_blocks + 2
    assert Enum.count(stored, &(&1["type"] == "heading")) == @max_headings + 1

    # THE CONTROL. The very same content, offered to the PUBLISH door, is
    # refused by the epic-quality gate. The floor exists; it lives at publish
    # time, exactly where the contract doc says it does.
    resp = json_response(publish(stored, slug, labels), 422)

    assert resp["error"]["code"] == "invalid_epic_paper_quality"
    failures = resp["error"]["details"]["failures"]
    assert "top_level_block_overload" in failures
    assert "top_level_heading_overload" in failures
  end

  test "the edit door's WHOLE contract is the two ratchets: ratchet_hollow/2 still halts an op" do
    slug = "ops-door-ratchet-#{System.unique_integer([:positive])}"
    labels = LabelFixtures.paper_attrs(%{"dataset" => @dataset})

    blocks = [
      %{
        "id" => "tpl-title",
        "type" => "heading",
        "level" => 1,
        "role" => "title",
        "locked" => true,
        "text" => "A paper with real content"
      },
      paragraph("body", "The one meaningful block this paper has.")
    ]

    assert %{"ok" => true} =
             json_response(
               publish(blocks, slug, %{
                 "tags" => labels["tags"],
                 "description" => labels["description"]
               }),
               200
             )

    # Deleting the only meaningful block takes a paper WITH content down to the
    # bare skeleton. `ratchet_hollow/2` halts that op — the ops door is not
    # unguarded, it is guarded by non-regression ratchets rather than by the
    # whole-document floors the publish door applies.
    conn = apply_op(slug, %{"op" => "remove-block", "id" => "body"})

    assert %{"error" => %{"code" => "halted"}} = json_response(conn, 409)
    # And the refusal is the RATCHET, not an AuthoringWall verdict: the wall
    # never runs on this door.
    assert length(Content.paper_blocks(slug, @dataset)) == 2
  end

  test "PIN: the retyped caps still equal the private attributes in epic_quality.ex" do
    # This file cannot read @max_top_level_blocks / @max_top_level_headings —
    # they are private attributes with no accessor — so it retypes them above.
    # A retyped constant rots silently, which is exactly what this pin refuses:
    # move either cap in epic_quality.ex and this test reds, pointing the next
    # reader at the two literals and at the at-cap fixture built from them.
    source = File.read!(@epic_quality_source)

    # Assert the PRECONDITION of the pin itself. A renamed or deleted attribute
    # would make the two value assertions below fail for the wrong reason, and a
    # duplicated one would let a stale copy satisfy them — so require exactly one
    # declaration line per attribute before comparing its value.
    for attribute <- ["@max_top_level_blocks", "@max_top_level_headings"] do
      assert length(Regex.scan(~r/^\s*#{attribute}\s+\d+$/m, source)) == 1,
             "#{attribute} is no longer declared exactly once in epic_quality.ex; " <>
               "this pin and the retyped literals above need rewriting."
    end

    assert source =~ ~r/^\s*@max_top_level_blocks\s+#{@max_blocks}$/m,
           "epic_quality.ex's @max_top_level_blocks is no longer #{@max_blocks}; " <>
             "update @max_blocks here and the at-cap fixture it builds."

    assert source =~ ~r/^\s*@max_top_level_headings\s+#{@max_headings}$/m,
           "epic_quality.ex's @max_top_level_headings is no longer #{@max_headings}; " <>
             "update @max_headings here and the at-cap fixture it builds."
  end
end
