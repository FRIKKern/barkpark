defmodule Barkpark.Content.RawRepoSeatScopeDoorTest do
  @moduledoc """
  THE FIVE RAW-REPO SEATS, ROUTED THROUGH THE CLASSIFIED DOOR
  (task-d507d3d83476b57d, the seeded-Default ruling's clause (d)).

  `WriteScope.inherit_scope_attrs/2` is nil-skipping by construction
  (`maybe_put_scope_attr(attrs, _key, nil) -> attrs`), so a nil-workspace source
  row produced a nil-workspace destination row at every seat that inherits —
  and `Content.Scope.scope_to_workspace_including_global/3` is
  `workspace_id == ^ws or is_nil(...)`, so such a row is readable by EVERY
  tenant. These seats never pass `Content.Writer`, so `put_scope_attrs/2` never
  saw them.

  THE SEATS, re-derived from the code rather than from the filing's line
  numbers (`grep -rn 'Document\\.changeset' api/lib` for the changeset-shaped
  writes, `Repo.update_all.*Document` for the query-shaped one):

    * `lifecycle.ex` publish  — `Repo.update` / `Repo.insert` (CLASS (a))
    * `lifecycle.ex` unpublish — `Repo.update` / `Repo.insert` (CLASS (a))
    * `papers/proposals.ex` `get_or_seed_draft/3` — `Repo.insert` (CLASS (a))
    * `cycle_fleet.ex` `restore_release_document/3` — `Repo.update_all`, which
      writes NO scope column; its harm is a cross-tenant update by UUID, so it
      gains a scope guard rather than a stamp (covered by
      `cycle_fleet_release_restore_scope_test.exs`)

  The filing's fifth seat, "`publish_after_gate` (~:751 raw Repo.update on the
  predecessor)", is a MISIDENTIFICATION: line 751 on the base sha is inside
  `stamp_superseded_by/5`, a best-effort content-only stamp on a row already
  read through the caller's scope (`Content.get_document/4`), which touches no
  scope column and can create nothing. `publish_after_gate/5`'s own writes are
  the publish seat above.

  MUTATION ARM: restoring the nil-skipping inherit path at the publish seat
  (`|> WriteScope.inherit_scope_attrs(draft)` in place of the resolved
  `scope_attrs`) reds `a nil-workspace draft publishes ATTRIBUTED, never a NULL
  workspace row`. Run pasted in the PR body.

  `async: false`: the class-(a) arm reads the seeded Default workspace, which is
  process-global state.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.{CallerContext, Document, Writer}
  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias Barkpark.TenancyFixtures

  @dataset "raw_repo_seat_scope_door_test"
  @type_name "rrsd"

  setup do
    Content.upsert_schema(
      %{"name" => @type_name, "title" => "RRSD", "visibility" => "public", "fields" => []},
      @dataset
    )

    :ok
  end

  defp workspace_with_project! do
    ws = TenancyFixtures.create_workspace!()
    _ = TenancyFixtures.create_project!(ws, "default")
    ws
  end

  defp user_in!(workspaces) do
    user =
      Barkpark.AccountsFixtures.register_user(
        "rrsd-#{System.unique_integer([:positive])}@example.com"
      )

    for ws <- workspaces do
      {:ok, _} = Tenancy.Auth.create_membership(ws.id, user.id, "member", "user")
    end

    user
  end

  defp ctx_for(user), do: %CallerContext{principal_type: :user, user_id: user.id}

  # A raw row inserted straight through the changeset, so the scope columns are
  # EXACTLY what this test says they are — the shape `put_scope_attrs/2` never
  # touched (a pre-tenancy row, a fixture, a seed that predates the backfill).
  defp raw_row!(doc_id, status, scope_attrs) do
    %Document{}
    |> Document.changeset(
      Map.merge(
        %{
          "doc_id" => doc_id,
          "type" => @type_name,
          "dataset" => @dataset,
          "title" => "raw seat #{doc_id}",
          "status" => status,
          "content" => %{},
          "rev" => Writer.generate_rev()
        },
        scope_attrs
      )
    )
    |> Repo.insert!()
  end

  # ── criterion 0 — the publish seat ───────────────────────────────────────

  describe "the publish seat" do
    test "a nil-workspace draft publishes ATTRIBUTED, never a NULL workspace row" do
      ws = workspace_with_project!()
      user = user_in!([ws])

      raw_row!("drafts.rrsd-nil-ws", "draft", %{})

      assert {:ok, %Document{} = published} =
               Content.publish_document("rrsd-nil-ws", @type_name, @dataset,
                 caller_context: ctx_for(user)
               )

      assert published.status == "published"
      assert published.workspace_id == ws.id

      default = Tenancy.get_default_workspace()
      refute is_nil(default), "the seeded Default must exist or this test proves nothing"
      refute published.workspace_id == default.id

      # And nothing NULL survived the transition — the whole point.
      refute is_nil(Repo.get!(Document, published.id).workspace_id)
    end

    test "CONTROL: a SCOPED draft publishes with its own scope — inheritance is unchanged" do
      source_ws = workspace_with_project!()
      other_ws = workspace_with_project!()
      publisher = user_in!([other_ws])

      raw_row!("drafts.rrsd-scoped", "draft", %{"workspace_id" => source_ws.id})

      assert {:ok, %Document{} = published} =
               Content.publish_document("rrsd-scoped", @type_name, @dataset,
                 caller_context: ctx_for(publisher)
               )

      assert published.workspace_id == source_ws.id,
             "the door must not be consulted when the source row carries a workspace"
    end

    test "an AMBIGUOUS principal is REFUSED, not Defaulted" do
      ws_a = workspace_with_project!()
      ws_b = workspace_with_project!()
      user = user_in!([ws_a, ws_b])

      raw_row!("drafts.rrsd-ambiguous", "draft", %{})

      assert {:error, :workspace_scope_required} =
               Content.publish_document("rrsd-ambiguous", @type_name, @dataset,
                 caller_context: ctx_for(user)
               )

      # Fail CLOSED: nothing was published and the draft survives to be scoped.
      assert {:error, :not_found} =
               Content.get_document("rrsd-ambiguous", @type_name, @dataset, [])

      assert {:ok, %Document{}} =
               Content.get_document("drafts.rrsd-ambiguous", @type_name, @dataset, [])
    end
  end

  # ── criterion 0's sibling — the unpublish seat ───────────────────────────

  describe "the unpublish seat" do
    test "a nil-workspace published row unpublishes ATTRIBUTED" do
      ws = workspace_with_project!()
      user = user_in!([ws])

      raw_row!("rrsd-unpub-nil", "published", %{})

      assert {:ok, %Document{} = draft} =
               Content.unpublish_document("rrsd-unpub-nil", @type_name, @dataset,
                 caller_context: ctx_for(user)
               )

      assert draft.status == "draft"
      assert draft.workspace_id == ws.id
    end

    test "CONTROL: a scoped published row keeps its own scope on unpublish" do
      source_ws = workspace_with_project!()
      other_ws = workspace_with_project!()
      actor = user_in!([other_ws])

      raw_row!("rrsd-unpub-scoped", "published", %{"workspace_id" => source_ws.id})

      assert {:ok, %Document{} = draft} =
               Content.unpublish_document("rrsd-unpub-scoped", @type_name, @dataset,
                 caller_context: ctx_for(actor)
               )

      assert draft.workspace_id == source_ws.id
    end

    test "an AMBIGUOUS principal is REFUSED, and the published row survives" do
      ws_a = workspace_with_project!()
      ws_b = workspace_with_project!()
      user = user_in!([ws_a, ws_b])

      raw_row!("rrsd-unpub-ambiguous", "published", %{})

      assert {:error, :workspace_scope_required} =
               Content.unpublish_document("rrsd-unpub-ambiguous", @type_name, @dataset,
                 caller_context: ctx_for(user)
               )

      assert {:ok, %Document{status: "published"}} =
               Content.get_document("rrsd-unpub-ambiguous", @type_name, @dataset, [])
    end
  end

  # ── the residual arm is UNCHANGED ────────────────────────────────────────

  test "RESIDUAL: a nil-workspace draft published with NO principal still lands in Default" do
    raw_row!("drafts.rrsd-residual", "draft", %{})

    assert {:ok, %Document{} = published} =
             Content.publish_document("rrsd-residual", @type_name, @dataset, [])

    default = Tenancy.get_default_workspace()

    assert published.workspace_id == default.id,
           "the ruling's residual arm — fixtures and internal helpers — must not start refusing"
  end
end
