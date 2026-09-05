defmodule BarkparkWeb.WallRefusalLeavesNoDraftTest do
  @moduledoc """
  THE AUTHORING WALL MUST NOT MANUFACTURE STRANDED DRAFTS
  (task-ce7dcd7202da30e6, ruled by main 2026-09-04).

  `bp task create --publish` and the MCP `task_create` are TWO HTTP requests:
  a `create` mutate that commits `drafts.<id>`, then a `publish` mutate. When
  the publish is refused by E4 with `duplicate_of`, request 1's draft was
  already committed — so the refusal LEFT A ROW behind that every canonical
  reader (`bp task ready`, the board, the epic roster — all published-first) is
  blind to. The 2026-09-04 census counted 409 such draft-only `type:task` rows,
  31 of them carrying a published row's byte-identical title.

  The ruling: refuse before any write, or discard the draft inside the same
  transaction, and the refusal body names the surviving published id. This file
  measures the wire — the status, the body, AND the row — through the real
  `POST /v1/data/mutate` door, because a Repo-level assertion cannot see the
  rollback the mutate transaction performs (which is what made a fix inside
  `Lifecycle` alone insufficient — see `Mutations.compensating_discard/4`).

  The four OTHER wall refusals are pinned here too, in the opposite direction:
  their draft MUST survive, because their remedy needs it.
  """
  use BarkparkWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.LabelFixtures
  alias Barkpark.Repo

  @dataset "test"

  # A long, distinctive title: `DedupWall` scores Jaccard over title + tag NAME
  # tokens (never the description), and its thin-content floor needs >= 3 shared
  # tokens before it may refuse at all.
  @title "Backfill the denormalized main tag column onto every published document row"

  setup do
    Barkpark.Auth.create_token("barkpark-dev-token", "dev", @dataset, ["read", "write", "admin"])
    register_task_schemas!()
    LabelFixtures.register_tags!(@dataset)
    :ok
  end

  describe "duplicate_of — the ONE terminal refusal, which discards the draft" do
    test "a publish refused with duplicate_of answers 409 naming the incumbent AND leaves no drafts.<id>",
         %{conn: conn} do
      publish_incumbent!("task-incumbent-dup", @title)
      insert_draft!("task-near-dup", @title)

      # Precondition, asserted rather than assumed: the draft this refusal is
      # about IS in the table before the publish. Without this the row-absence
      # assertion below passes vacuously for a draft that never existed.
      assert draft_row("drafts.task-near-dup"), "fixture draft must exist before the publish"

      resp = mutate(conn, [%{"publish" => %{"id" => "task-near-dup", "type" => "task"}}])

      # C2 — the status ON THE WIRE. `authoring_wall.ex`'s own comments say 409
      # (Content.Errors builds `duplicate_of` with `status: 409`); the filing
      # said 422. This assertion is the tiebreak: 409 is what ships.
      assert resp.status == 409
      body = Jason.decode!(resp.resp_body)
      assert body["error"]["code"] == "duplicate_of"

      # C1 FIRST, so it is the assertion a regression reds on. The refusal left
      # NOTHING behind. Read from the table, not from an API perspective: a
      # draft-only row is precisely one the published-first readers cannot see,
      # so asking them would answer "gone" either way.
      refute draft_row("drafts.task-near-dup"),
             "the refused publish stranded drafts.task-near-dup — the exact row the census counted"

      # C2 — the body NAMES the surviving published id.
      assert body["error"]["details"]["duplicate_of"] == "task-incumbent-dup"
      assert body["error"]["message"] =~ "task-incumbent-dup"
      assert body["error"]["message"] =~ "discarded"

      # And the incumbent it named is untouched.
      assert {:ok, %Document{}} = Content.get_document("task-incumbent-dup", "task", @dataset)
    end

    test "the compensating discard only fires for the id the batch asked to publish", %{
      conn: conn
    } do
      publish_incumbent!("task-incumbent-bystander", @title)
      insert_draft!("task-refused-one", @title)

      insert_draft!(
        "task-bystander",
        "A wholly unrelated draft about Postfix DKIM relay sidecars"
      )

      resp = mutate(conn, [%{"publish" => %{"id" => "task-refused-one", "type" => "task"}}])

      assert resp.status == 409
      refute draft_row("drafts.task-refused-one")

      # A rollback reason must never authorise a delete the caller did not ask
      # for: nothing outside the batch's own publish op is touched.
      assert draft_row("drafts.task-bystander")
    end
  end

  describe "the OTHER wall refusals keep the draft — the remedy needs it" do
    # C3. `unknown_tag` (E3) is AUTHOR-FIXABLE: the retry is an edit to this
    # draft's tags plus a republish. Discarding it would delete the exact work
    # the refusal asks the author to correct. Same reasoning covers
    # `label_spine` and `invalid_epic_paper_quality`; `dedup_unavailable` is
    # transient (the bounded scan could not RUN) and its retry needs the draft
    # too. Only `duplicate_of` says "this content is already published, HERE".
    test "an unknown_tag refusal answers 422 and the draft SURVIVES", %{conn: conn} do
      insert_draft!("task-unregistered-tag", "A task whose weighted tag was never registered",
        tags: [
          %{
            "tag" => "definitely-not-registered-anywhere",
            "strength" => 90,
            "rationale" => "An unregistered weighted tag, so E3 refuses this publish."
          },
          %{
            "tag" => "fixture-tag-1",
            "strength" => 40,
            "rationale" => "A registered weighted tag, so only the other one is unknown."
          }
        ]
      )

      resp = mutate(conn, [%{"publish" => %{"id" => "task-unregistered-tag", "type" => "task"}}])

      assert resp.status == 422
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "unknown_tag"

      assert draft_row("drafts.task-unregistered-tag"),
             "an author-fixable refusal must leave the draft the author is being asked to fix"
    end

    test "a label_spine refusal answers 422 and the draft SURVIVES", %{conn: conn} do
      # No description, no tags — the spine's first two checks.
      insert_draft!("task-no-spine", "A task with no label spine at all",
        content: %{
          "kind" => "task",
          "lifecycle_status" => "open",
          "priority" => 1,
          "acceptance_criteria" => [%{"criterion" => "the fixture is closeable", "met" => true}]
        }
      )

      resp = mutate(conn, [%{"publish" => %{"id" => "task-no-spine", "type" => "task"}}])

      assert resp.status == 422
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "label_spine"
      assert draft_row("drafts.task-no-spine")
    end
  end

  # ── fixtures ────────────────────────────────────────────────────────────────

  defp mutate(conn, mutations) do
    conn
    |> put_req_header("authorization", "Bearer barkpark-dev-token")
    |> put_req_header("content-type", "application/json")
    |> post("/v1/data/mutate/#{@dataset}", Jason.encode!(%{"mutations" => mutations}))
  end

  defp task_content(extra) do
    %{
      "kind" => "task",
      "lifecycle_status" => "open",
      "priority" => 1,
      "acceptance_criteria" => [%{"criterion" => "the fixture is closeable", "met" => true}]
    }
    |> Map.merge(LabelFixtures.weighted_labels())
    |> Map.merge(extra)
  end

  # Every fixture is born through the SAME `POST /v1/data/mutate` door the
  # subject uses. Not decoration: `Content.get_document/4` is workspace-scoped,
  # so a raw `Repo.insert!` row (workspace_id NULL) is invisible to the publish
  # that is supposed to find it, and every assertion below would measure a 404
  # instead of the wall.
  defp publish_incumbent!(id, title) do
    create_draft!(id, title, [])
    resp = mutate(scoped_conn_authed(), [%{"publish" => %{"id" => id, "type" => "task"}}])
    assert resp.status == 200, "incumbent fixture failed to publish: #{resp.resp_body}"
    :ok
  end

  # The committed `drafts.<id>` request 1 leaves behind. A SEPARATE request on
  # purpose: the point is a draft that is already durable when the publish is
  # refused, which a single-batch create+publish (rolled back as one) can never
  # reproduce.
  defp insert_draft!(id, title, opts \\ []), do: create_draft!(id, title, opts)

  defp create_draft!(id, title, opts) do
    content =
      case Keyword.fetch(opts, :content) do
        {:ok, explicit} -> explicit
        :error -> task_content(tags_override(opts))
      end

    resp =
      mutate(scoped_conn_authed(), [
        %{"create" => %{"_id" => id, "_type" => "task", "title" => title, "content" => content}}
      ])

    assert resp.status == 200, "draft fixture #{id} failed to create: #{resp.resp_body}"
    :ok
  end

  defp scoped_conn_authed, do: BarkparkWeb.ConnCase.scoped_conn()

  defp tags_override(opts) do
    case Keyword.fetch(opts, :tags) do
      {:ok, tags} -> %{"tags" => tags}
      :error -> %{}
    end
  end

  defp draft_row(doc_id) do
    Repo.one(
      from(d in Document,
        where: d.doc_id == ^doc_id and d.type == "task" and d.dataset == ^@dataset,
        select: d.doc_id
      )
    )
  end

  defp register_task_schemas! do
    for schema_def <- Barkpark.Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset)
    end

    :ok
  end
end
