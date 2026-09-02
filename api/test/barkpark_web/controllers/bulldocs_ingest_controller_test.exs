defmodule BarkparkWeb.BulldocsIngestControllerTest do
  @moduledoc """
  Focused test for the paper-ingest endpoint (convergence MVP).

  Exercises the ingest request shape:
  `Authorization: Bearer <ingest token>` + JSON `{source_doc, slug,
  event_type, body_html, goal_id?}`. Asserts a valid token upserts +
  broadcasts on the per-doc PubSub topic, and that a bad / missing token is
  rejected.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.{Errors, Warnings}
  alias Barkpark.Content.Papers.Hollow
  alias Barkpark.LabelFixtures
  import Barkpark.TenancyFixtures, only: [create_project!: 2, create_workspace!: 1]
  import Ecto.Query, only: [from: 2]

  # Convenience accessors — papers are type-"paper" documents now; the block
  # list / HTML cache / provenance live in the document's `content` map.
  defp pc(doc, key), do: get_in(doc.content || %{}, [key])

  # Set in config/test.exs.
  @token "barkpark-test-ingest-token"
  @path "/v1/plugins/bulldocs/papers"

  # A compliant ingest body: since the D26 mount now walls the ingest birth
  # path (fresh papers are never exempt), an honest POST must carry a
  # registered weighted `tags` set + `description` — `LabelFixtures.paper_attrs`
  # registers unique names and merges them in. Auth tests still call this, but
  # never reach the wall (401 fires first), so the extra registration is inert
  # there.
  defp body(slug) do
    LabelFixtures.paper_attrs(%{
      "source_doc" => "plans/#{slug}.html",
      "slug" => slug,
      "event_type" => "plan-written",
      "body_html" => ~s(<article><h1>#{slug}</h1></article>),
      "goal_id" => "bd-test1"
    })
  end

  describe "auth" do
    test "rejects with no token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(@path, body("no-token-paper"))

      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
      refute Content.get_paper("no-token-paper")
    end

    test "rejects with a wrong token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer not-the-real-token")
        |> put_req_header("content-type", "application/json")
        |> post(@path, body("bad-token-paper"))

      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
      refute Content.get_paper("bad-token-paper")
    end
  end

  describe "valid ingest" do
    test "upserts the paper and broadcasts on the per-doc topic", %{conn: conn} do
      slug = "ingest-ok-paper"
      # Subscribe BEFORE the request so we observe the broadcast.
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Content.paper_topic(slug, nil))

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> @token)
        |> put_req_header("content-type", "application/json")
        |> post(@path, body(slug))

      resp = json_response(conn, 200)
      assert resp["ok"] == true
      assert resp["slug"] == slug
      assert resp["liveview_path"] == "/papers/#{slug}"
      assert is_binary(resp["rev"])

      # Persisted so a fresh LiveView mount renders the latest HTML.
      paper = Content.get_paper(slug)
      assert pc(paper, "body_html") =~ slug
      assert pc(paper, "source_doc") == "plans/#{slug}.html"
      assert pc(paper, "goal_id") == "bd-test1"
      assert pc(paper, "event_type") == "plan-written"

      # Broadcast landed on the topic BulldocsLive subscribes to.
      assert_receive {:paper_updated, %{slug: ^slug, html: html}}
      assert html =~ slug
    end

    test "a second POST with the same slug updates in place (upsert)", %{conn: conn} do
      slug = "ingest-upsert-paper"

      auth = fn c, payload ->
        c
        |> put_req_header("authorization", "Bearer " <> @token)
        |> put_req_header("content-type", "application/json")
        |> post(@path, payload)
      end

      # Both writes are walled (fresh births). Same compliant registered labels
      # on both — the second is a self-id republish (same slug), E4-excluded.
      %{"tags" => tags, "description" => description} = LabelFixtures.paper_attrs(%{})

      _ =
        auth.(conn, %{
          "slug" => slug,
          "body_html" => "<p>v1</p>",
          "tags" => tags,
          "description" => description
        })

      _ =
        auth.(Phoenix.ConnTest.build_conn(), %{
          "slug" => slug,
          "body_html" => "<p>v2 updated</p>",
          "tags" => tags,
          "description" => description
        })

      paper = Content.get_paper(slug)
      assert pc(paper, "body_html") == "<p>v2 updated</p>"
      # Exactly one row for the slug — updated, not duplicated.
      count =
        Barkpark.Repo.one(
          from d in Barkpark.Content.Document,
            where: d.type == "paper" and d.doc_id == ^slug,
            select: count(d.id)
        )

      assert count == 1
    end

    test "rejects a payload missing slug/body_html with 400", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> @token)
        |> put_req_header("content-type", "application/json")
        |> post(@path, %{"event_type" => "plan-written"})

      assert json_response(conn, 400)["error"]["code"] == "malformed"
    end
  end

  describe "invalid ingest text" do
    @tag :invalid_text
    @tag :nul_ingest
    test "wall-compliant nested block NUL returns typed 422 without writing", %{conn: conn} do
      slug = "invalid-text-block-nul-#{System.unique_integer([:positive])}"

      payload =
        LabelFixtures.paper_attrs(%{
          "slug" => slug,
          "blocks" => [
            %{
              "id" => "tpl-title",
              "type" => "heading",
              "level" => 1,
              "role" => "title",
              "locked" => true,
              "text" => "NUL regression"
            },
            %{
              "id" => "body",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "before\0after"}]
            }
          ]
        })

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> @token)
        |> put_req_header("content-type", "application/json")
        |> post(@path, payload)

      assert_invalid_text(conn)
      refute Content.get_paper(slug)
    end

    @tag :invalid_text
    @tag :nul_ingest
    test "wall-compliant body_html NUL returns typed 422 without writing", %{conn: conn} do
      slug = "invalid-text-html-nul-#{System.unique_integer([:positive])}"

      payload =
        LabelFixtures.paper_attrs(%{
          "slug" => slug,
          "body_html" => "<article>before\0after</article>"
        })

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> @token)
        |> put_req_header("content-type", "application/json")
        |> post(@path, payload)

      assert_invalid_text(conn)
      refute Content.get_paper(slug)
    end

    @tag :invalid_text
    test "direct decoded params reject malformed UTF-8 in a recursive map key before warnings reset",
         %{conn: conn} do
      slug = "invalid-text-map-key-#{System.unique_integer([:positive])}"

      params =
        LabelFixtures.paper_attrs(%{
          "slug" => slug,
          "blocks" => [
            %{
              "id" => "body",
              "type" => "paragraph",
              "content" => [%{<<0xFF>> => "nested key", "type" => "text", "value" => "safe"}]
            }
          ]
        })

      Warnings.reset()
      Warnings.put("sentinel", "must survive invalid ingest")

      conn = BarkparkWeb.BulldocsIngestController.ingest(conn, params)

      assert_invalid_text(conn)

      assert Warnings.drain() == [
               %{code: "sentinel", severity: "advisory", message: "must survive invalid ingest"}
             ]

      refute Content.get_paper(slug)
    end

    @tag :invalid_text
    test "direct decoded params reject malformed UTF-8 in a recursive map value inside a list",
         %{conn: conn} do
      slug = "invalid-text-map-value-#{System.unique_integer([:positive])}"

      params =
        LabelFixtures.paper_attrs(%{
          "slug" => slug,
          "blocks" => [
            %{
              "id" => "body",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => <<0xC3>>}]
            }
          ]
        })

      conn = BarkparkWeb.BulldocsIngestController.ingest(conn, params)

      assert_invalid_text(conn)
      refute Content.get_paper(slug)
    end
  end

  defp assert_invalid_text(conn) do
    assert %{
             "error" => %{
               "code" => "invalid_text",
               "message" => "paper text must be valid UTF-8 and cannot contain NUL bytes"
             }
           } = json_response(conn, 422)
  end

  describe "M1 template halt envelope (title-only / locked-block violations)" do
    defp auth_ingest(conn, payload) do
      conn
      |> put_req_header("authorization", "Bearer " <> @token)
      |> put_req_header("content-type", "application/json")
      |> post(@path, payload)
    end

    test "a locked title NOT at index 0 → 409 halted whose message is the verbatim veto",
         %{conn: conn} do
      slug = "halt-title-misplaced-#{System.unique_integer([:positive])}"

      # A locked role:"title" block sitting at index 1 (a stray paragraph in
      # front of it) violates the paper_declarations `{:index, 0}` rule — the
      # shipped M1 template halt. Before this fix the controller flattened it
      # into a generic 422 invalid_paper, losing the honest message.
      payload = %{
        "slug" => slug,
        "blocks" => [
          %{
            "id" => "stray",
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "early"}]
          },
          %{
            "id" => "tpl-title",
            "type" => "heading",
            "level" => 1,
            "role" => "title",
            "locked" => true,
            "text" => "T"
          }
        ]
      }

      conn = auth_ingest(conn, payload)

      resp = json_response(conn, 409)
      assert resp["error"]["code"] == "halted"
      # The server copy is surfaced VERBATIM — never rewritten by the emitter.
      assert resp["error"]["message"] ==
               ~s(paper template violated: the "title" block must be at block 0, found at 1)

      # Fail closed: nothing was persisted.
      refute Content.get_paper(slug)
    end

    test "a valid block paper (locked title at index 0) still saves — positive control",
         %{conn: conn} do
      slug = "halt-positive-#{System.unique_integer([:positive])}"

      # Compliant labels (registered tags + description) so the paper clears the
      # D26 publish wall the ingest birth path now enforces — the positive
      # control is about the template gate PASSING, not the wall.
      payload =
        LabelFixtures.paper_attrs(%{
          "slug" => slug,
          "blocks" => [
            %{
              "id" => "tpl-title",
              "type" => "heading",
              "level" => 1,
              "role" => "title",
              "locked" => true,
              "text" => "Real Doc"
            },
            %{
              "id" => "body",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "Real content."}]
            }
          ]
        })

      conn = auth_ingest(conn, payload)

      resp = json_response(conn, 200)
      assert resp["ok"] == true
      assert resp["slug"] == slug
      assert Content.get_paper(slug)
    end
  end

  describe "block-ingest endpoint (POST /:slug/ops)" do
    defp ops_path(slug), do: "#{@path}/#{slug}/ops"

    defp auth_post(conn, slug, op) do
      conn
      |> put_req_header("authorization", "Bearer " <> @token)
      |> put_req_header("content-type", "application/json")
      |> post(ops_path(slug), op)
    end

    defp append_op(id, text) do
      %{
        "op" => "append-block",
        "block" => %{
          "id" => id,
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => text}]
        }
      }
    end

    setup do
      slug = "ops-target-#{System.unique_integer([:positive])}"
      # A block-backed paper to apply ops against — walled at birth by the D26
      # mount, so seed it with compliant registered labels.
      {:ok, paper} =
        Content.upsert_paper(
          LabelFixtures.paper_attrs(%{
            slug: slug,
            blocks: [
              %{
                "id" => "intro",
                "type" => "paragraph",
                "content" => [%{"type" => "text", "value" => "Intro."}]
              }
            ]
          })
        )

      {:ok, slug: slug, rev0: pc(paper, "rev")}
    end

    test "valid op + bearer applies, bumps rev, broadcasts a delta, returns the fragment",
         %{conn: conn, slug: slug, rev0: rev0} do
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Content.paper_topic(slug, nil))

      conn = auth_post(conn, slug, append_op("b-new", "Streamed in."))

      resp = json_response(conn, 200)
      assert resp["ok"] == true
      assert resp["slug"] == slug
      assert resp["op"] == "append-block"
      assert resp["block_id"] == "b-new"
      assert resp["rev"] == rev0 + 1
      assert resp["fragment_html"] =~ "Streamed in."

      # Persisted: block list grew, HTML cache refreshed.
      paper = Content.get_paper(slug)
      assert length(pc(paper, "blocks")) == 2
      assert pc(paper, "body_html") =~ "Streamed in."

      # Delta frame landed on the per-doc topic BulldocsLive subscribes to.
      assert_receive {:paper_block, %{op_kind: "append-block", block_id: "b-new", rev: rev}}
      assert rev == rev0 + 1
    end

    test "removing the last content block is halted and leaves the paper unchanged",
         %{conn: conn, slug: slug} do
      paper_before = Content.get_paper(slug)

      conn = auth_post(conn, slug, %{"op" => "remove-block", "id" => "intro"})

      resp = json_response(conn, 409)
      assert resp["error"]["code"] == "halted"
      assert resp["error"]["message"] == Hollow.ratchet_message()
      assert Content.get_paper(slug) == paper_before
    end

    test "bad token → 401, no mutation", %{conn: conn, slug: slug} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer not-the-real-token")
        |> put_req_header("content-type", "application/json")
        |> post(ops_path(slug), append_op("b-x", "nope"))

      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
      # Untouched — still just the seeded block.
      assert length(pc(Content.get_paper(slug), "blocks")) == 1
    end

    test "unknown slug → 404", %{conn: conn} do
      conn = auth_post(conn, "no-such-paper", append_op("b-x", "nope"))
      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end

    test "malformed op (unknown discriminator) → 422", %{conn: conn, slug: slug} do
      conn = auth_post(conn, slug, %{"op" => "frobnicate", "block" => %{"id" => "z"}})
      assert json_response(conn, 422)["error"]["code"] == "malformed_op"
    end

    test "well-shaped op that fails to apply (block not found) → 422", %{conn: conn, slug: slug} do
      bad =
        %{
          "op" => "patch-block",
          "id" => "does-not-exist",
          "patch" => %{"content" => [%{"type" => "text", "value" => "x"}]}
        }

      conn = auth_post(conn, slug, bad)
      resp = json_response(conn, 422)
      assert resp["error"]["code"] == "block_not_found"
      assert resp["error"]["op"] == "patch-block"
    end

    test "op breaking the constraint vocabulary → 422 whose message IS the reason (pdd-t20)",
         %{conn: conn} do
      # A doctrine paper that already carries its one featured (title @0, featured
      # @1) is constraint-VALID, so the op-layer veto is what fires here — NOT the
      # D12 legacy pass-through. Under D11 the featured is no longer auto-seeded, so
      # it is supplied explicitly; appending a SECOND featured breaks max-1.
      slug = "ops-constraint-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Content.upsert_paper(
          LabelFixtures.paper_attrs(%{
            slug: slug,
            blocks: [
              %{
                "id" => "tpl-title",
                "type" => "heading",
                "level" => 1,
                "role" => "title",
                "locked" => true,
                "text" => "T"
              },
              %{
                "id" => "tpl-featured",
                "type" => "image",
                "role" => "featured",
                "locked" => true
              },
              # A real body block: skeleton-only papers are refused by the
              # hollow-body quality gate (p-quality-gate); this test targets the
              # constraint vocabulary veto.
              %{
                "id" => "body-p",
                "type" => "paragraph",
                "content" => [%{"type" => "text", "value" => "Body."}]
              }
            ]
          })
        )

      conn =
        auth_post(conn, slug, %{
          "op" => "append-block",
          "block" => %{"id" => "f2", "type" => "image", "role" => "featured"}
        })

      resp = json_response(conn, 422)
      assert resp["error"]["code"] == "constraint"
      assert resp["error"]["op"] == "append-block"

      assert resp["error"]["message"] ==
               "at most 1 \"featured\" block allowed, found 2"

      # Calm veto: the paper is untouched (title + featured + body block).
      assert length(pc(Content.get_paper(slug), "blocks")) == 3
    end
  end

  describe "M2 batch ops endpoint (POST /:slug/ops with {ops: [...]})" do
    defp ops_path_b(slug), do: "#{@path}/#{slug}/ops"

    defp auth_post_b(conn, slug, body) do
      conn
      |> put_req_header("authorization", "Bearer " <> @token)
      |> put_req_header("content-type", "application/json")
      |> post(ops_path_b(slug), body)
    end

    defp append_op_b(id, text) do
      %{
        "op" => "append-block",
        "block" => %{
          "id" => id,
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => text}]
        }
      }
    end

    # The shape an author NATURALLY writes: no id, because the server mints one.
    # Every shipped batch test hardcoded ids, which is why the suite stayed green
    # over a live 422 (PDS-D458).
    defp append_op_noid_b(text) do
      %{
        "op" => "append-block",
        "block" => %{
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => text}]
        }
      }
    end

    defp insert_after_op_noid_b(after_id, text) do
      %{
        "op" => "insert-after",
        "afterId" => after_id,
        "block" => %{
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => text}]
        }
      }
    end

    defp block_ids_of(paper) do
      paper |> pc("blocks") |> Enum.map(&Map.get(&1, "id"))
    end

    setup do
      slug = "batch-target-#{System.unique_integer([:positive])}"

      {:ok, paper} =
        Content.upsert_paper(
          LabelFixtures.paper_attrs(%{
            slug: slug,
            blocks: [
              %{
                "id" => "intro",
                "type" => "paragraph",
                "content" => [%{"type" => "text", "value" => "Intro."}]
              }
            ]
          })
        )

      {:ok, slug: slug, rev0: pc(paper, "rev")}
    end

    test "a 3-op batch applies atomically and returns a minimal receipt with the new rev",
         %{conn: conn, slug: slug, rev0: rev0} do
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Content.paper_topic(slug, nil))

      ops = [
        append_op_b("b1", "First."),
        append_op_b("b2", "Second."),
        %{
          "op" => "patch-block",
          "id" => "intro",
          "patch" => %{"content" => [%{"type" => "text", "value" => "Patched intro."}]}
        }
      ]

      conn = auth_post_b(conn, slug, %{"ops" => ops})

      resp = json_response(conn, 200)
      # Minimal receipt — slug + op-count + new rev + affected block ids.
      assert resp["ok"] == true
      assert resp["slug"] == slug
      assert resp["op_count"] == 3
      assert resp["rev"] == rev0 + 1
      assert resp["block_ids"] == ["b1", "b2", "intro"]
      # fragment_html is SUPPRESSED on the batch path.
      refute Map.has_key?(resp, "fragment_html")

      # Persisted once: all three ops landed, rev bumped exactly once.
      paper = Content.get_paper(slug)
      assert length(pc(paper, "blocks")) == 3
      assert pc(paper, "rev") == rev0 + 1
      assert pc(paper, "body_html") =~ "First."
      assert pc(paper, "body_html") =~ "Second."
      assert pc(paper, "body_html") =~ "Patched intro."

      # A single batch delta frame on the per-doc topic.
      assert_receive {:paper_block,
                      %{op_kind: :batch, block_ids: ["b1", "b2", "intro"], rev: rev}}

      assert rev == rev0 + 1
    end

    test "a batch whose middle op fails leaves the paper at its ORIGINAL rev (rollback)",
         %{conn: conn, slug: slug, rev0: rev0} do
      ops = [
        append_op_b("b1", "First."),
        # Middle op targets a block id that does not exist → whole batch fails.
        %{
          "op" => "patch-block",
          "id" => "no-such-block",
          "patch" => %{"content" => [%{"type" => "text", "value" => "x"}]}
        },
        append_op_b("b3", "Third.")
      ]

      conn = auth_post_b(conn, slug, %{"ops" => ops})

      resp = json_response(conn, 422)
      assert resp["error"]["code"] == "block_not_found"
      assert resp["error"]["op"] == "patch-block"

      # Rollback: paper untouched — still just the seeded block, original rev.
      paper = Content.get_paper(slug)
      assert length(pc(paper, "blocks")) == 1
      assert pc(paper, "rev") == rev0
      refute pc(paper, "body_html") =~ "First."
      refute pc(paper, "body_html") =~ "Third."
    end

    # ── PDS-D458: id-less ops, the receipt, and move-block at the door ──────
    #
    # Every test above hands its ops a HARDCODED id. These drive the shape an
    # author actually writes — no id at all — which used to 422 `duplicate_id`
    # at n>=2 and, at n==1, answer `{"ok":true,…,"block_ids":[]}` about a block
    # it HAD minted. The fix is the per-op `ensure_block_ids` hoist inside
    # `BlockOps.fold_paper_ops/2`.

    test "a multi-op ID-LESS append batch succeeds and reports one minted id per op",
         %{conn: conn, slug: slug, rev0: rev0} do
      ops = [append_op_noid_b("First."), append_op_noid_b("Second.")]

      conn = auth_post_b(conn, slug, %{"ops" => ops})

      resp = json_response(conn, 200)
      assert resp["ok"] == true
      assert resp["op_count"] == 2
      assert resp["rev"] == rev0 + 1

      # THE RECEIPT: one minted id per op, not an empty list.
      ids = resp["block_ids"]
      assert length(ids) == 2
      assert Enum.uniq(ids) == ids
      assert Enum.all?(ids, &(is_binary(&1) and &1 != ""))

      # And every reported id addresses a block that is really there.
      paper = Content.get_paper(slug)
      stored = block_ids_of(paper)
      assert stored == ["intro" | ids]
      assert pc(paper, "body_html") =~ "First."
      assert pc(paper, "body_html") =~ "Second."
    end

    test "a multi-op ID-LESS insert-after batch succeeds and reports one minted id per op",
         %{conn: conn, slug: slug, rev0: rev0} do
      ops = [
        insert_after_op_noid_b("intro", "First."),
        insert_after_op_noid_b("intro", "Second.")
      ]

      conn = auth_post_b(conn, slug, %{"ops" => ops})

      resp = json_response(conn, 200)
      assert resp["ok"] == true
      assert resp["op_count"] == 2
      assert resp["rev"] == rev0 + 1

      ids = resp["block_ids"]
      assert length(ids) == 2
      assert Enum.uniq(ids) == ids
      assert Enum.all?(ids, &(is_binary(&1) and &1 != ""))

      paper = Content.get_paper(slug)
      stored = block_ids_of(paper)
      assert length(stored) == 3
      assert Enum.sort(stored) == Enum.sort(["intro" | ids])
    end

    test "the SINGLE and BATCH shapes agree on block_ids for an identical id-less op",
         %{conn: conn} do
      seed = fn ->
        s = "id-less-parity-#{System.unique_integer([:positive])}"

        {:ok, _} =
          Content.upsert_paper(
            LabelFixtures.paper_attrs(%{
              slug: s,
              blocks: [
                %{
                  "id" => "intro",
                  "type" => "paragraph",
                  "content" => [%{"type" => "text", "value" => "Intro."}]
                }
              ]
            })
          )

        s
      end

      op = append_op_noid_b("Same op, two shapes.")

      single_slug = seed.()
      batch_slug = seed.()

      single = json_response(auth_post_b(conn, single_slug, op), 200)
      batch = json_response(auth_post_b(build_conn(), batch_slug, %{"ops" => [op]}), 200)

      # The batch used to answer [] here while single answered the minted id.
      assert batch["block_ids"] == [single["block_id"]]
      assert is_binary(single["block_id"]) and single["block_id"] != ""

      # Both persisted the same block-id shape, one block past the seed.
      assert block_ids_of(Content.get_paper(single_slug)) ==
               block_ids_of(Content.get_paper(batch_slug))
    end

    test "a GENUINE duplicate id is still rejected — the nil guard did not blind the real check",
         %{conn: conn, slug: slug, rev0: rev0} do
      ops = [append_op_b("dup", "one"), append_op_b("dup", "two")]

      conn = auth_post_b(conn, slug, %{"ops" => ops})

      resp = json_response(conn, 422)
      assert resp["error"]["code"] == "duplicate_id"
      assert resp["error"]["op"] == "append-block"
      assert resp["error"]["target"] == "dup"

      # Rolled back: the paper never saw either op.
      paper = Content.get_paper(slug)
      assert length(pc(paper, "blocks")) == 1
      assert pc(paper, "rev") == rev0
    end

    test "move-block is accepted on the BATCH path (it was 422 malformed_op at the door)",
         %{conn: conn, slug: slug, rev0: rev0} do
      ops = [
        append_op_b("b1", "First."),
        append_op_b("b2", "Second."),
        %{"op" => "move-block", "id" => "b1", "after" => "b2"}
      ]

      conn = auth_post_b(conn, slug, %{"ops" => ops})

      resp = json_response(conn, 200)
      assert resp["ok"] == true
      assert resp["op_count"] == 3
      assert resp["rev"] == rev0 + 1
      assert resp["block_ids"] == ["b1", "b2"]

      assert block_ids_of(Content.get_paper(slug)) == ["intro", "b2", "b1"]
    end

    test "move-block is accepted on the SINGLE path too", %{conn: conn, slug: slug} do
      assert json_response(
               auth_post_b(conn, slug, %{"ops" => [append_op_b("b1", "First.")]}),
               200
             )["ok"] == true

      resp =
        json_response(
          auth_post_b(build_conn(), slug, %{"op" => "move-block", "id" => "b1", "after" => nil}),
          200
        )

      assert resp["ok"] == true
      assert resp["op"] == "move-block"
      assert resp["block_id"] == "b1"
      assert resp["position"] == 0

      assert block_ids_of(Content.get_paper(slug)) == ["b1", "intro"]
    end

    test "single-op back-compat path still works (body IS the op)",
         %{conn: conn, slug: slug, rev0: rev0} do
      conn = auth_post_b(conn, slug, append_op_b("solo", "Solo block."))

      resp = json_response(conn, 200)
      # Full single-op receipt — op + block_id + fragment_html present.
      assert resp["ok"] == true
      assert resp["slug"] == slug
      assert resp["op"] == "append-block"
      assert resp["block_id"] == "solo"
      assert resp["rev"] == rev0 + 1
      assert resp["fragment_html"] =~ "Solo block."

      paper = Content.get_paper(slug)
      assert length(pc(paper, "blocks")) == 2
    end

    test "unknown slug on the batch path → 404", %{conn: conn} do
      conn = auth_post_b(conn, "no-such-batch-paper", %{"ops" => [append_op_b("b1", "x")]})
      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end

    test "a batch containing a malformed op → 422 malformed_op, no mutation",
         %{conn: conn, slug: slug, rev0: rev0} do
      ops = [append_op_b("b1", "ok"), %{"op" => "frobnicate"}]
      conn = auth_post_b(conn, slug, %{"ops" => ops})

      assert json_response(conn, 422)["error"]["code"] == "malformed_op"
      # Untouched.
      paper = Content.get_paper(slug)
      assert length(pc(paper, "blocks")) == 1
      assert pc(paper, "rev") == rev0
    end

    # ── M3 optimistic-concurrency guard (ifRev) ──────────────────────────
    test "ifRev matching the current rev applies the batch",
         %{conn: conn, slug: slug, rev0: rev0} do
      conn = auth_post_b(conn, slug, %{"ifRev" => rev0, "ops" => [append_op_b("b1", "ok")]})

      resp = json_response(conn, 200)
      assert resp["ok"] == true
      assert resp["rev"] == rev0 + 1

      paper = Content.get_paper(slug)
      assert length(pc(paper, "blocks")) == 2
    end

    test "stale ifRev → 412 precondition_failed, paper rolled back (no op applied)",
         %{conn: conn, slug: slug, rev0: rev0} do
      conn = auth_post_b(conn, slug, %{"ifRev" => rev0 - 1, "ops" => [append_op_b("b1", "nope")]})

      resp = json_response(conn, 412)
      assert resp["error"]["code"] == "precondition_failed"

      # Untouched: still the seeded block at the original rev.
      paper = Content.get_paper(slug)
      assert length(pc(paper, "blocks")) == 1
      assert pc(paper, "rev") == rev0
      refute pc(paper, "body_html") =~ "nope"
    end

    test "workspace headers scope block ops when two papers share a slug", %{conn: conn} do
      suffix = System.unique_integer([:positive])
      ws_a = create_workspace!("paper-ops-a-#{suffix}")
      ws_b = create_workspace!("paper-ops-b-#{suffix}")
      project_a = create_project!(ws_a, "default")
      project_b = create_project!(ws_b, "default")
      slug = "same-paper-#{suffix}"

      base = fn text, workspace, project ->
        LabelFixtures.paper_attrs(%{
          slug: slug,
          workspace_id: workspace.id,
          project_id: project.id,
          blocks: [
            %{
              "id" => "intro",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => text}]
            }
          ]
        })
      end

      {:ok, _} = Content.upsert_paper(base.("workspace A", ws_a, project_a))
      {:ok, _} = Content.upsert_paper(base.("workspace B", ws_b, project_b))

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> @token)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-barkpark-workspace", ws_b.slug)
        |> put_req_header("x-barkpark-project", project_b.slug)
        |> post(ops_path_b(slug), %{"ops" => [append_op_b("scoped", "only workspace B")]})

      assert json_response(conn, 200)["ok"] == true

      paper_a =
        Content.get_paper(slug, Content.paper_default_dataset(),
          workspace_id: ws_a.id,
          project_id: project_a.id
        )

      paper_b =
        Content.get_paper(slug, Content.paper_default_dataset(),
          workspace_id: ws_b.id,
          project_id: project_b.id
        )

      refute pc(paper_a, "body_html") =~ "only workspace B"
      assert pc(paper_b, "body_html") =~ "only workspace B"
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # D27 — ingest rejections are honest: publish-wall tuples render field/rule/fix
  # at BOTH upsert_paper sites (blocks + html). The routing added here (three
  # per-tuple case heads → render_error/2 → Errors.to_envelope) is BYTE-SAFE
  # today: it only fires once the ae-upsert-paper-wall mount (D26) makes
  # upsert_paper return a raw wall tuple. This block proves two things now:
  #
  #   (a) the existing hand-rolled error shapes stay byte-identical — halted 409,
  #       malformed 400, and the invalid_paper (changeset) LAST resort — so the
  #       new heads did NOT smuggle in a wholesale action_fallback (a changeset
  #       through Errors.to_envelope silently becomes `validation_failed`, a
  #       public-contract break; this block PINS that divergence);
  #
  #   (b) the shared envelope render_error/2 delegates to yields the exact D27
  #       status / code / details / hint for each of the three wall codes — the
  #       precise wire shape the caller retries against.
  #
  # The end-to-end endpoint assertions (a real POST tripping each gate) are
  # skip-gated until the D26 mount lands in this tree; they are the ready target
  # for the LEAD's rebase-over-the-mount step (remove the `skip:` tag).
  # ───────────────────────────────────────────────────────────────────────────
  describe "D27 publish-wall error surfacing" do
    # ── (a) hand-rolled clauses stay byte-identical — no action_fallback swap ──

    test "malformed request still renders 400 code=malformed (unchanged by the new heads)",
         %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> @token)
        |> put_req_header("content-type", "application/json")
        |> post(@path, %{"event_type" => "plan-written"})

      assert json_response(conn, 400)["error"]["code"] == "malformed"
    end

    test "template halt still renders 409 code=halted with the verbatim message",
         %{conn: conn} do
      slug = "d27-halt-#{System.unique_integer([:positive])}"

      payload = %{
        "slug" => slug,
        "blocks" => [
          %{
            "id" => "stray",
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "early"}]
          },
          %{
            "id" => "tpl-title",
            "type" => "heading",
            "level" => 1,
            "role" => "title",
            "locked" => true,
            "text" => "T"
          }
        ]
      }

      conn = auth_ingest(conn, payload)
      resp = json_response(conn, 409)
      assert resp["error"]["code"] == "halted"
      assert resp["error"]["message"] =~ "paper template violated"
      refute Content.get_paper(slug)
    end

    test "a changeset routed through Errors.to_envelope becomes validation_failed — WHY the ingest changeset clause must stay hand-rolled as invalid_paper" do
      cs = Ecto.Changeset.add_error(Ecto.Changeset.change({%{}, %{}}), :base, "bad")
      env = Errors.to_envelope({:error, cs}, nil)

      # If the controller had swapped to a wholesale action_fallback, a paper
      # store failure would surface with THIS code (a public-contract break).
      # The controller keeps invalid_paper hand-rolled precisely to avoid it.
      assert env.code == "validation_failed"
      assert env.status == 422
      refute env.code == "invalid_paper"
    end

    # ── (b) render_error/2's delegation target: the exact wire shape per code ──

    test "label_spine → 422 code=label_spine with the validator details + hint verbatim" do
      details = [
        %{"field" => "tags", "rule" => "min_labels", "fix" => "add at least 2 weighted tags"}
      ]

      env = Errors.to_envelope({:error, {:label_spine, details}}, nil)

      assert env.status == 422
      assert env.code == "label_spine"
      assert env.details == details
      assert is_binary(env.hint) and env.hint != ""
      # render_error strips :status before it hits the wire (see the helper).
      refute Map.has_key?(Map.delete(env, :status), :status)
    end

    test "unknown_tag → 422 code=unknown_tag carrying the unknown names + trgm suggestions" do
      payload = %{unknown: ["quantum-widget"], suggestions: %{"quantum-widget" => ["quantum"]}}
      env = Errors.to_envelope({:error, {:unknown_tag, payload}}, nil)

      assert env.status == 422
      assert env.code == "unknown_tag"
      assert env.details[:unknown] == ["quantum-widget"]
      assert Map.has_key?(env.details, :suggestions)
      assert env.message =~ "quantum-widget"
      assert is_binary(env.hint) and env.hint != ""
    end

    test "duplicate_of → 409 code=duplicate_of naming the incumbent published id" do
      payload = %{
        duplicate_of: "incumbent-slug",
        similar: [%{id: "incumbent-slug", score: 0.91}]
      }

      env = Errors.to_envelope({:error, {:duplicate_of, payload}}, nil)

      assert env.status == 409
      assert env.code == "duplicate_of"
      assert env.details[:duplicate_of] == "incumbent-slug"
      assert is_binary(env.hint) and env.hint != ""
    end

    # ── End-to-end endpoint assertions — LIVE as of the D26 mount ──
    # The ae-upsert-paper-wall mount now makes Content.upsert_paper return the
    # raw wall tuple these POST a real request to trip; the render_error heads
    # above route each to its 422/422/409 envelope. The skip: gate is removed.

    test "tagless block ingest → 422 code=label_spine with field/rule/fix + hint",
         %{conn: conn} do
      slug = "d27-labelspine-#{System.unique_integer([:positive])}"

      payload = %{
        "slug" => slug,
        "blocks" => [
          %{
            "id" => "tpl-title",
            "type" => "heading",
            "level" => 1,
            "role" => "title",
            "locked" => true,
            "text" => "Well-formed but unlabeled"
          },
          %{
            "id" => "body",
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "Real body content."}]
          }
        ]
      }

      conn = auth_ingest(conn, payload)
      resp = json_response(conn, 422)
      assert resp["error"]["code"] == "label_spine"
      assert is_binary(resp["error"]["hint"])
      # Fail closed — the unlabeled paper is not born.
      refute Content.get_paper(slug)
    end

    test "ingest with an unregistered weighted tag → 422 code=unknown_tag with suggestions",
         %{conn: conn} do
      slug = "d27-unknowntag-#{System.unique_integer([:positive])}"

      payload = %{
        "slug" => slug,
        "blocks" => [
          %{
            "id" => "tpl-title",
            "type" => "heading",
            "level" => 1,
            "role" => "title",
            "locked" => true,
            "text" => "Labeled but with an unregistered tag"
          },
          %{
            "id" => "body",
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "Real body content."}]
          }
        ],
        # A non-trivial description so the label SPINE passes (E1/E2) and the
        # publish reaches E3 — the gate under test here. Without it the spine's
        # description check 422s first as label_spine, never exercising E3.
        "description" =>
          "A description long enough to satisfy the label spine's non-trivial rule.",
        "tags" => [
          %{
            "tag" => "nonexistent-#{System.unique_integer([:positive])}",
            "strength" => 80,
            "rationale" => "unique-token rationale so the fixture description never collides"
          }
        ]
      }

      conn = auth_ingest(conn, payload)
      resp = json_response(conn, 422)
      assert resp["error"]["code"] == "unknown_tag"
      assert Map.has_key?(resp["error"]["details"], "suggestions")
      refute Content.get_paper(slug)
    end

    test "near-duplicate ingest → 409 code=duplicate_of naming the incumbent",
         %{conn: conn} do
      # The mount's E4 dedup gate produces {:duplicate_of, %{duplicate_of: id}}
      # when title+tag-name token overlap crosses the refuse band (sim ≥ 0.55,
      # ≥ 3 shared tokens). Seed a COMPLIANT, REGISTERED incumbent, then POST a
      # paper with the SAME title and the SAME registered tags — Jaccard 1.0,
      # so E4 refuses and the render_error head maps it to a 409.
      n = System.unique_integer([:positive])
      title = "Distinctive incumbent paper about deduplication guarding rules #{n}"
      names = ["dedupinc#{n}a", "dedupinc#{n}b", "dedupinc#{n}c"]
      labels = LabelFixtures.with_named_labels(%{}, "production", names)

      incumbent_slug = "d27-incumbent-#{n}"

      {:ok, _} =
        Content.upsert_paper(%{
          "slug" => incumbent_slug,
          "blocks" => [
            %{
              "id" => "tpl-title",
              "type" => "heading",
              "level" => 1,
              "role" => "title",
              "locked" => true,
              "text" => title
            },
            %{
              "id" => "body",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "The incumbent's body content."}]
            }
          ],
          "tags" => labels["tags"],
          "description" => labels["description"]
        })

      dup_slug = "d27-duplicate-#{n}"

      payload = %{
        "slug" => dup_slug,
        "blocks" => [
          %{
            "id" => "tpl-title",
            "type" => "heading",
            "level" => 1,
            "role" => "title",
            "locked" => true,
            "text" => title
          },
          %{
            "id" => "body",
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "A different body, but the same title."}]
          }
        ],
        "tags" => labels["tags"],
        "description" => "A distinct description that still leaves the title+tags overlapping."
      }

      conn = auth_ingest(conn, payload)
      resp = json_response(conn, 409)
      assert resp["error"]["code"] == "duplicate_of"
      assert resp["error"]["details"]["duplicate_of"] == incumbent_slug
      # Fail closed — the near-duplicate is not born.
      refute Content.get_paper(dup_slug)
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # D36/D42 — ingest advisory dead-letter. The publish wall's advise band (an
  # off-norm tag count, a soft-dup near-miss) queues NON-blocking warnings via
  # Warnings.put. Before this wiring the ingest controller never opened the
  # request-scoped channel (Warnings.reset/drain), so every ingest advisory was
  # silently dropped (collect-only-when-listening, warnings.ex) — a real signal
  # lost. This proves the band now rides the 200 SUCCESS envelope, and that a
  # compliant in-norm ingest keeps the byte-identical warnings-free body.
  # ───────────────────────────────────────────────────────────────────────────
  describe "D36 ingest advisory dead-letter" do
    test "an off-norm tag count rides the 200 success envelope as a label_norm warning",
         %{conn: conn} do
      n = System.unique_integer([:positive])
      # FIVE registered weighted labels: a legal count (1–12) OUTSIDE the 2–4
      # norm, so the wall PASSES (200) yet emits the `label_norm` advisory.
      names = for i <- 1..5, do: "advinorm#{n}x#{i}"
      labels = LabelFixtures.with_named_labels(%{}, "production", names)

      slug = "d36-advisory-#{n}"

      payload = %{
        "slug" => slug,
        "blocks" => [
          %{
            "id" => "tpl-title",
            "type" => "heading",
            "level" => 1,
            "role" => "title",
            "locked" => true,
            "text" => "Distinctive advisory-band paper about tag-count norms #{n}"
          },
          %{
            "id" => "body",
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "Real body content."}]
          }
        ],
        "tags" => labels["tags"],
        "description" => labels["description"]
      }

      conn = auth_ingest(conn, payload)
      resp = json_response(conn, 200)

      # The paper is BORN — an advisory NEVER blocks (charter D5) …
      assert resp["ok"] == true
      assert resp["slug"] == slug
      assert Content.get_paper(slug)

      # … and the advisory rides the SUCCESS envelope (was silently dropped
      # before the Warnings.reset/drain wiring).
      assert is_list(resp["warnings"])
      assert resp["warnings"] != []

      entry = Enum.find(resp["warnings"], &(&1["code"] == "label_norm"))
      assert entry, "expected a label_norm advisory in #{inspect(resp["warnings"])}"
      assert entry["severity"] == "advisory"
      assert is_binary(entry["message"]) and entry["message"] != ""
    end

    test "a compliant in-norm ingest omits the warnings key (byte-identical body)",
         %{conn: conn} do
      n = System.unique_integer([:positive])
      # THREE registered weighted labels — squarely IN the 2–4 norm, no advisory.
      names = for i <- 1..3, do: "advinnorm#{n}x#{i}"
      labels = LabelFixtures.with_named_labels(%{}, "production", names)

      slug = "d36-noadvisory-#{n}"

      payload = %{
        "slug" => slug,
        "blocks" => [
          %{
            "id" => "tpl-title",
            "type" => "heading",
            "level" => 1,
            "role" => "title",
            "locked" => true,
            "text" => "Distinctive in-norm paper about tag counts #{n}"
          },
          %{
            "id" => "body",
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "Real body content."}]
          }
        ],
        "tags" => labels["tags"],
        "description" => labels["description"]
      }

      conn = auth_ingest(conn, payload)
      resp = json_response(conn, 200)

      assert resp["ok"] == true
      assert resp["slug"] == slug
      # No advisory ⇒ the additive key is OMITTED (never an empty array).
      refute Map.has_key?(resp, "warnings")
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # ae-ingest-learn-pointer — teach WHERE the authoring standards live. The
  # legacy body_html leg emits a NON-BLOCKING advisory (the D36/D42 Warnings
  # channel's first content-shape consumer) naming the preferred `blocks` path
  # and the doctrine papers. Advisory only — never a 4xx (charter D5). The
  # native blocks path stays byte-identical (proven by the D36 no-advisory test
  # above, which uses blocks).
  # ───────────────────────────────────────────────────────────────────────────
  describe "ae-ingest-learn-pointer body_html advisory" do
    test "the legacy body_html leg rides a learn-pointer advisory naming the doctrine papers",
         %{conn: conn} do
      slug = "learn-pointer-#{System.unique_integer([:positive])}"

      # body/1 is a wall-compliant body_html payload (registered weighted tags +
      # description), so the paper is BORN (200) and the advisory can ride the
      # success envelope.
      conn = auth_ingest(conn, body(slug))
      resp = json_response(conn, 200)

      assert resp["ok"] == true
      assert resp["slug"] == slug
      assert Content.get_paper(slug)

      assert is_list(resp["warnings"])

      entry = Enum.find(resp["warnings"], &(&1["code"] == "legacy_body_html"))
      assert entry, "expected a legacy_body_html advisory in #{inspect(resp["warnings"])}"
      # Advisory, never an error — promotion is charter-forbidden (D5).
      assert entry["severity"] == "advisory"
      # It names the preferred blocks path AND both doctrine paper slugs.
      assert entry["message"] =~ "blocks"
      assert entry["message"] =~ "portabledoc-doctrine"
      assert entry["message"] =~ "composition-doctrine-plan"
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Create-on-push (pe-w6 / charter D41): `POST /papers/:slug/sync` on an
  # ABSENT slug births the paper through the FULL publish wall. The high-flip
  # risk this pins: a wall-refused create must write NOTHING — no draft, no
  # partial row — and the refusal must carry EVERY violation in one 422, the
  # same set the validate dry-run reports for the same document.
  # ───────────────────────────────────────────────────────────────────────────
  describe "create-on-push (sync to an absent slug, D41)" do
    defp sync_path(slug), do: "#{@path}/#{slug}/sync"

    defp sync_conn(conn, slug, bpml, base_rev \\ "0") do
      conn
      |> put_req_header("authorization", "Bearer " <> @token)
      |> put_req_header("content-type", "application/json")
      |> post(sync_path(slug), %{"bpml" => bpml, "baseRev" => base_rev})
    end

    # A wall-passing BPML document for `slug` — the scaffold's shape: meta
    # (description + registered weighted tags, distinct strengths, ≥20-char
    # rationales), an h1 at block 0, one real paragraph. Tokens are unique per
    # call (the E4 dedup token-bag rule — see LabelFixtures).
    defp create_bpml(slug, tag_names) do
      n = System.unique_integer([:positive])

      tag_lines =
        tag_names
        |> Enum.with_index()
        |> Enum.map_join("\n", fn {name, i} ->
          ~s(    <tag tag="#{name}" strength="#{90 - i * 30}">Create-door fixture tag — proves the wall equivalence.</tag>)
        end)

      """
      <paper slug="#{slug}" title="Create Door zq#{n}x">
        <meta>
          <description>Create-door proof zq#{n}a zq#{n}b zq#{n}c zq#{n}d zq#{n}e.</description>
      #{tag_lines}
        </meta>
        <h1>Create Door zq#{n}x</h1>
        <p>The one door creates through the full wall zq#{n}f zq#{n}g.</p>
      </paper>
      """
    end

    defp registered_tag_names do
      n = System.unique_integer([:positive])
      names = ["qz#{n}door", "qz#{n}proof"]
      LabelFixtures.register_tags!("production", names)
      names
    end

    test "a wall-passing document CREATES the paper (200 created), and pulls back clean",
         %{conn: conn} do
      slug = "create-door-#{System.unique_integer([:positive])}"
      bpml = create_bpml(slug, registered_tag_names())

      conn = sync_conn(conn, slug, bpml)
      resp = json_response(conn, 200)

      assert resp["ok"] == true
      assert resp["created"] == true
      assert resp["slug"] == slug
      assert is_binary(resp["rev"]) and resp["rev"] != ""
      assert [resp["rev"]] == get_resp_header(conn, "x-paper-rev")
      assert is_binary(resp["bpml"]) and resp["bpml"] =~ "the full wall"

      # Persisted through the same truths as any birth: blocks stored, the h1
      # text IS the row title, the labels landed.
      paper = Content.get_paper(slug)
      assert paper
      assert paper.title =~ "Create Door"
      assert [%{"type" => "heading"} | _] = pc(paper, "blocks")
      assert is_binary(pc(paper, "description"))
      assert length(pc(paper, "tags")) == 2

      # The working-copy loop closes: a pull returns exactly the canonical the
      # create receipt carried, anchored on the same rev.
      pull = build_conn() |> get("/papers/#{slug}/source", %{"format" => "bpml"})
      assert response(pull, 200) == resp["bpml"]
      assert [resp["rev"]] == get_resp_header(pull, "x-paper-rev")
    end

    test "an unregistered tag refuses with the 422 create_wall violations envelope and writes NOTHING",
         %{conn: conn} do
      slug = "create-refused-#{System.unique_integer([:positive])}"
      # Tags NOT registered — the sharpest first-push trap (E3, never exempted).
      bpml =
        create_bpml(slug, [
          "never-registered-#{System.unique_integer([:positive])}",
          "also-missing"
        ])

      conn = sync_conn(conn, slug, bpml)
      assert %{"error" => err} = json_response(conn, 422)
      assert err["code"] == "create_wall"
      assert err["message"] =~ "nothing was written"
      assert err["hint"] =~ "--check"
      assert Enum.any?(err["errors"], &(&1["code"] == "unknown_tag"))

      # ZERO server state: no published row, no draft twin.
      refute Content.get_paper(slug)
      refute Content.get_paper("drafts.#{slug}")
    end

    test "a hollow, label-less document collects EVERY violation in one reply, nothing written",
         %{conn: conn} do
      slug = "create-hollow-#{System.unique_integer([:positive])}"

      bpml = """
      <paper slug="#{slug}" title="Hollow Door">
        <h1>Hollow Door</h1>
      </paper>
      """

      conn = sync_conn(conn, slug, bpml)
      assert %{"error" => err} = json_response(conn, 422)
      assert err["code"] == "create_wall"

      codes = Enum.map(err["errors"], & &1["code"])
      assert "hollow_paper" in codes
      assert "label_spine" in codes

      refute Content.get_paper(slug)
      refute Content.get_paper("drafts.#{slug}")
    end

    test "the create wall and the validate dry-run refuse with the SAME violation codes",
         %{conn: conn} do
      slug = "create-parity-#{System.unique_integer([:positive])}"

      bpml = """
      <paper slug="#{slug}" title="Parity Door">
        <h1>Parity Door</h1>
      </paper>
      """

      dry =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> @token)
        |> put_req_header("content-type", "application/json")
        |> post("#{@path}/validate", %{"bpml" => bpml})

      %{"valid" => false, "violations" => violations} = json_response(dry, 200)

      conn = sync_conn(conn, slug, bpml)

      assert %{"error" => %{"code" => "create_wall", "errors" => errors}} =
               json_response(conn, 422)

      assert Enum.map(errors, & &1["code"]) |> Enum.sort() ==
               Enum.map(violations, & &1["code"]) |> Enum.sort()

      refute Content.get_paper(slug)
    end

    test "a document whose <paper slug> disagrees with the pushed path refuses before the wall",
         %{conn: conn} do
      slug = "create-mismatch-#{System.unique_integer([:positive])}"
      bpml = create_bpml("some-other-slug", registered_tag_names())

      conn = sync_conn(conn, slug, bpml)
      assert %{"error" => err} = json_response(conn, 422)
      assert err["code"] == "slug_mismatch"
      assert err["hint"] =~ "identity"

      refute Content.get_paper(slug)
      refute Content.get_paper("some-other-slug")
    end

    test "an EXISTING slug still 412s on a scaffold's rev-0 anchor (create never clobbers)",
         %{conn: conn} do
      slug = "create-collision-#{System.unique_integer([:positive])}"

      assert {:ok, _} =
               Content.upsert_paper(
                 LabelFixtures.paper_attrs(%{
                   "slug" => slug,
                   "blocks" => [
                     %{
                       "type" => "heading",
                       "level" => 1,
                       "text" => "Incumbent zq#{System.unique_integer([:positive])}"
                     },
                     %{
                       "type" => "paragraph",
                       "content" => [%{"type" => "text", "value" => "already here"}]
                     }
                   ]
                 })
               )

      conn = sync_conn(conn, slug, create_bpml(slug, registered_tag_names()), "0")
      assert %{"error" => %{"code" => "precondition_failed"}} = json_response(conn, 412)
    end
  end
end
