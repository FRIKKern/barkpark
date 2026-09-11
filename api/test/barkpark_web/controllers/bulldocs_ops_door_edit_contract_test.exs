defmodule BarkparkWeb.BulldocsOpsDoorEditContractTest do
  @moduledoc """
  THE CONTRACT PIN for `POST /v1/plugins/bulldocs/papers/:slug/ops`.

  The ops door is an EDIT door. It deliberately does NOT mount
  `Barkpark.Content.AuthoringWall.enforce/5`: its whole contract is the two
  non-regression ratchets in `Barkpark.Content.Papers.BlockOps` —
  `ratchet_hollow/2` and `reject_new_field_loss/2`. The five whole-document
  floors (label spine, tag registry, dedup scan, epic quality, structure) are
  PUBLISH-time properties, enforced by `POST /v1/plugins/bulldocs/papers` and
  the ingest legs, and re-applied the next time the slug goes through one.

  Ruled by the api lane on task-14107740b20c92fa; written up in
  `docs/contracts/plugin-http-api.md` (Bulldocs ops section) and pointed at
  from `docs/api-v1.md` §8a.

  THESE TESTS RED IF SOMEONE MOUNTS THE WALL ON /ops. That is intentional:
  an intended future change updates this file and the contract doc TOGETHER,
  so the ruling can never drift away from the code silently.

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

  # The caps the publish-time floor enforces, read from the module that owns
  # them rather than retyped: @max_top_level_blocks / @max_top_level_headings
  # in epic_quality.ex are 80 and 16.
  @max_blocks 80
  @max_headings 16

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
end
