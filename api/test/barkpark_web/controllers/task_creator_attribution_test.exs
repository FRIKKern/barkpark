defmodule BarkparkWeb.TaskCreatorAttributionTest do
  @moduledoc """
  THE CREATOR STAMP (task-aa3502ad7645afbd).

  A task document recorded WHEN it was born (`_createdAt`) and never WHO bore
  it, so main's standing "rows you hold or filed" sweep could only ever reach
  the HELD half — `claim.worker` and friends — and reported clean coverage over
  every row a lane filed but never claimed.

  THE INVARIANT UNDER TEST: `content.created_by` is a fact the SERVER wrote
  about the request, never a field the request supplied. Sourced from the
  calling principal (`CallerContext.actor_stamp/1` — the api_token id at the
  `/v1/data/mutate` door), unforgeable from the body on a birth OR an update,
  queryable through the same `filter[...]` door `bp doc query task` uses, absent
  on rows born before it, and never a reason to refuse a write.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Content

  @dataset "test"

  setup do
    {:ok, alpha} =
      Barkpark.Auth.create_token("tca-alpha-token", "alpha", @dataset, ["read", "write", "admin"])

    {:ok, beta} =
      Barkpark.Auth.create_token("tca-beta-token", "beta", @dataset, ["read", "write", "admin"])

    %{alpha: alpha, beta: beta}
  end

  # ── c0: the birth stamp, and the negative arm ──────────────────────────────

  describe "a task birth through /v1/data/mutate" do
    test "carries a server-set creator naming the calling api_token — with NO creator in the payload",
         %{conn: conn, alpha: alpha} do
      resp = create_task(conn, "tca-birth-plain", "tca-alpha-token", %{})
      assert resp.status == 200

      assert %{"kind" => "api_token", "id" => id, "at" => at} = stored_creator("tca-birth-plain")
      assert id == alpha.id
      assert {:ok, _, _} = DateTime.from_iso8601(at)
    end

    # THE NEGATIVE ARM. A body-supplied `created_by` is a CLAIM, and the ledger
    # has been burned by treating a self-reported label as proof. It must not
    # reach storage — not the forged id, not the forged kind.
    test "a creator supplied IN THE REQUEST BODY does not become the stored value",
         %{conn: conn, alpha: alpha, beta: beta} do
      forged = %{"kind" => "user", "id" => beta.id, "label" => "somebody else"}

      resp =
        create_task(conn, "tca-birth-forged", "tca-alpha-token", %{"created_by" => forged})

      assert resp.status == 200

      stored = stored_creator("tca-birth-forged")
      assert stored["id"] == alpha.id
      assert stored["kind"] == "api_token"
      refute stored["id"] == beta.id
      refute Map.has_key?(stored, "label")
    end

    # The same body key, smuggled under an ATOM. The stamp deletes both
    # spellings before writing, so neither survives.
    test "a body-supplied creator cannot be smuggled past the stamp on an UPDATE either",
         %{conn: conn, alpha: alpha, beta: beta} do
      assert create_task(conn, "tca-patch-forge", "tca-alpha-token", %{}).status == 200
      assert stored_creator("tca-patch-forge")["id"] == alpha.id

      resp =
        mutate(conn, "tca-beta-token", [
          %{
            "patch" => %{
              "id" => "tca-patch-forge",
              "type" => "task",
              "set" => %{"created_by" => %{"kind" => "api_token", "id" => beta.id}}
            }
          }
        ])

      assert resp.status == 200
      # Still the ORIGINAL filer. An update restores what the row carried; the
      # patcher never becomes the creator.
      assert stored_creator("tca-patch-forge")["id"] == alpha.id
    end
  end

  # ── c1: the attribution is QUERYABLE, and it DISCRIMINATES ─────────────────

  describe "querying by creator" do
    # Run against rows created by two DIFFERENT identities, so the filter is
    # shown to select rather than to return everything. This is the same
    # `filter[<path>]=<value>` door `bp doc query task --filter` drives.
    test "filter[content.created_by.id] returns one identity's rows and not the other's",
         %{conn: conn, alpha: alpha, beta: beta} do
      assert create_task(conn, "tca-q-alpha-1", "tca-alpha-token", %{}).status == 200
      assert create_task(conn, "tca-q-alpha-2", "tca-alpha-token", %{}).status == 200
      assert create_task(conn, "tca-q-beta-1", "tca-beta-token", %{}).status == 200

      alpha_ids = query_ids(conn, alpha.id)
      beta_ids = query_ids(conn, beta.id)

      assert "tca-q-alpha-1" in alpha_ids
      assert "tca-q-alpha-2" in alpha_ids
      refute "tca-q-beta-1" in alpha_ids

      assert "tca-q-beta-1" in beta_ids
      refute "tca-q-alpha-1" in beta_ids

      # THE CONTROL that keeps this from being vacuous: an UNFILTERED read of
      # the same door sees all three, so the two disjoint answers above are the
      # filter working, not an empty or broken query.
      all = query_ids(conn, nil)
      assert "tca-q-alpha-1" in all
      assert "tca-q-beta-1" in all
    end
  end

  # ── c2: rows born before this stay HONESTLY unattributed ───────────────────

  describe "rows born before the stamp" do
    # A birth the stamp cannot see: written through the Writer with no
    # `:caller_context`, standing in for the ~9,075 rows that already exist.
    test "read back with the field ABSENT, and a later touch does not credit the toucher",
         %{conn: conn} do
      {:ok, _doc} =
        Barkpark.Content.Writer.create_document(
          "task",
          %{
            "doc_id" => "tca-legacy-row",
            "title" => "Creator-stamp legacy fixture",
            "content" => %{"kind" => "task", "lifecycle_status" => "open", "priority" => 2}
          },
          @dataset,
          source: :api
        )

      assert stored_content("tca-legacy-row")["created_by"] == nil
      refute Map.has_key?(stored_content("tca-legacy-row"), "created_by")

      # Somebody else patches it. NO BACKFILL, and no guess: the row is still
      # unattributed afterwards rather than attributed to whoever touched it
      # next, which is the exact failure this row was filed against.
      resp =
        mutate(conn, "tca-beta-token", [
          %{
            "patch" => %{
              "id" => "tca-legacy-row",
              "type" => "task",
              "set" => %{
                "priority" => 1,
                # The toucher ALSO tries to name themselves. It must not stick.
                "created_by" => %{"kind" => "api_token", "id" => "the-toucher"}
              }
            }
          }
        ])

      assert resp.status == 200
      assert stored_content("tca-legacy-row")["priority"] == 1
      refute Map.has_key?(stored_content("tca-legacy-row"), "created_by")
    end
  end

  # ── c3: nothing is REFUSED for lacking a creator ───────────────────────────

  describe "a birth with nobody to name" do
    # The unadjudicated-birth WARN is the precedent: this row buys traceability,
    # not a fence. A door carrying no principal (the GitHub bridge, a worker,
    # replication) still lands its write — it simply lands UNSTAMPED, and the
    # absence of the key IS the greppable signal.
    test "still lands, unstamped, with no refusal" do
      assert {:ok, doc} =
               Barkpark.Content.Writer.create_document(
                 "task",
                 %{
                   "doc_id" => "tca-no-principal",
                   "title" => "Creator-stamp principal-less birth",
                   "content" => %{
                     "kind" => "task",
                     "lifecycle_status" => "open",
                     "priority" => 3
                   }
                 },
                 @dataset,
                 source: :api
               )

      assert doc.doc_id in ["tca-no-principal", "drafts.tca-no-principal"]
      refute Map.has_key?(doc.content, "created_by")
    end

    # REPLICATION IS EXEMPT, checked first: `Sync.Applier` mirrors an upstream
    # row verbatim, so the upstream's own creator survives the copy instead of
    # being overwritten with the replica's identity.
    test "a `source: :sync` birth keeps the UPSTREAM creator verbatim" do
      upstream = %{
        "kind" => "api_token",
        "id" => "upstream-token-id",
        "at" => "2026-01-01T00:00:00Z"
      }

      assert {:ok, doc} =
               Barkpark.Content.Writer.create_document(
                 "task",
                 %{
                   "doc_id" => "tca-sync-mirror",
                   "title" => "Creator-stamp replication fixture",
                   "content" => %{
                     "kind" => "task",
                     "lifecycle_status" => "open",
                     "priority" => 3,
                     "created_by" => upstream
                   }
                 },
                 @dataset,
                 source: :sync
               )

      assert doc.content["created_by"] == upstream
    end
  end

  # ── the stamp is TASK-SCOPED ───────────────────────────────────────────────

  test "a non-task birth through the same door is untouched", %{conn: conn} do
    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      @dataset
    )

    resp =
      mutate(conn, "tca-alpha-token", [
        %{
          "create" => %{
            "_id" => "tca-post-1",
            "_type" => "post",
            "title" => "Not a task",
            "content" => %{"body" => "x"}
          }
        }
      ])

    assert resp.status == 200
    refute Map.has_key?(stored_post_content("tca-post-1"), "created_by")
  end

  # ── fixtures ───────────────────────────────────────────────────────────────

  defp create_task(conn, id, token, content_extra) do
    mutate(conn, token, [
      %{
        "create" => %{
          "_id" => id,
          "_type" => "task",
          "title" => title_for(id),
          "content" =>
            Map.merge(
              %{"kind" => "task", "lifecycle_status" => "open", "priority" => 2},
              content_extra
            )
        }
      }
    ])
  end

  # The dedup wall refuses a near-duplicate title, so every fixture gets a
  # distinct one rather than an index-suffixed variant of the same sentence.
  @titles %{
    "tca-birth-plain" => "Creator stamp: a plain birth names the calling token",
    "tca-birth-forged" => "Rejecting a forged body creator on the way in",
    "tca-patch-forge" => "Whether a later patch can rename the original filer",
    "tca-q-alpha-1" => "Querying by identity, first row of the alpha lane",
    "tca-q-alpha-2" => "Backlink pagination across sheets and codelists",
    "tca-q-beta-1" => "Media processing retries under a cold CDN cache"
  }

  defp title_for(id), do: Map.fetch!(@titles, id)

  defp mutate(conn, token, mutations) do
    conn
    |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> post("/v1/data/mutate/#{@dataset}", Jason.encode!(%{"mutations" => mutations}))
  end

  # The mutate door births a task as a DRAFT, so the stored row lives under the
  # `drafts.` prefix. Read whichever spelling resolves.
  defp stored_content(doc_id) do
    {:ok, doc} =
      case Content.get_document(doc_id, "task", @dataset) do
        {:ok, doc} -> {:ok, doc}
        _ -> Content.get_document("drafts." <> doc_id, "task", @dataset)
      end

    doc.content
  end

  defp stored_creator(doc_id), do: stored_content(doc_id)["created_by"]

  defp stored_post_content(doc_id) do
    {:ok, doc} =
      case Content.get_document(doc_id, "post", @dataset) do
        {:ok, doc} -> {:ok, doc}
        _ -> Content.get_document("drafts." <> doc_id, "post", @dataset)
      end

    doc.content
  end

  # The HTTP read door `bp doc query task` drives.
  defp query_ids(conn, creator_id) do
    qs =
      case creator_id do
        nil -> "?limit=100&perspective=drafts"
        id -> "?limit=100&perspective=drafts&filter[content.created_by.id]=#{id}"
      end

    resp =
      conn
      |> Plug.Conn.put_req_header("authorization", "Bearer tca-alpha-token")
      |> get("/v1/data/query/#{@dataset}/task#{qs}")

    assert resp.status == 200

    resp.resp_body
    |> Jason.decode!()
    |> get_in(["result", "documents"])
    |> Enum.map(&String.replace_prefix(&1["_id"] || &1["doc_id"], "drafts.", ""))
  end
end
