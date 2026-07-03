defmodule Barkpark.Content.ValueWritebackTest do
  @moduledoc """
  lvw-t10 — `Papers.ValueWriteback` (writeback v1.5, strategy §11), the gated
  edit-through. The two acceptance criteria verbatim, plus the guarded-path +
  provenance proof:

    1. AUTHORIZATION AGAINST THE TARGET: evaluated against the TARGET
       canonical doc's write scope — write access to the HOSTING paper grants
       nothing (proved by writing the hosting paper successfully from the
       same caller that is then refused edit-through); an unauthorized /
       cross-scope / anonymous / read-only caller gets `:unauthorized` and
       the write path rejects server-side (never client-only).

    2. IMPACT PREVIEW fail-closed (MEDIUM-5): produced by
       `Content.Graph.reverse_referencers/2` under the CALLER's scope opts —
       an out-of-scope referencer is dropped ENTIRELY: no title, no stub, and
       NO aggregate "K you cannot see" count (the impact map structurally
       carries `:count` + `:referencers` only, `count == length(referencers)`).

    3. GUARDED WRITE + PROVENANCE: the write lands through
       `Content.apply_mutations/3` (rev-guarded patch — the `update` revision
       row with `actor_user_id` proves the canonical writer path, never a raw
       Repo write); a stale `expected_rev` is `{:error, {:rev_mismatch, …}}`
       with nothing written; and the attributed `"valueref-writeback"`
       provenance revision rides on top.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures
  import Ecto.Query

  alias Barkpark.Content
  alias Barkpark.Content.{CallerContext, Papers.ValueWriteback, Revision}
  alias Barkpark.Repo

  @dataset "value_writeback_test"

  setup do
    ws_a = create_workspace!()
    proj_a = create_project!(ws_a)
    ws_b = create_workspace!()
    proj_b = create_project!(ws_b)

    # The schema lives in workspace A — the tenant that owns the canonical
    # value doc (upsert_schema without scope opts would stamp the seeded
    # Default workspace, which is NEITHER tenant here).
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "metric",
          "title" => "Metric",
          "visibility" => "public",
          "fields" => [
            %{"name" => "launch_delay", "type" => "string"},
            %{"name" => "days_late", "type" => "number"},
            %{"name" => "secret_delay", "type" => "string", "visibility" => "private"}
          ]
        },
        @dataset,
        workspace_id: ws_a.id,
        project_id: proj_a.id
      )

    # Workspace B needs its own schema too (per-tenant schema world) so the
    # hosting-paper write from B goes through — what B must NOT get is the
    # TARGET in A.
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "metric",
          "title" => "Metric",
          "visibility" => "public",
          "fields" => [%{"name" => "launch_delay", "type" => "string"}]
        },
        @dataset,
        workspace_id: ws_b.id,
        project_id: proj_b.id
      )

    # Canonical value doc in workspace A, published (the shared truth).
    {:ok, _} =
      create_document_in!(
        ws_a,
        proj_a,
        "metric",
        %{
          "_id" => "m-canon",
          "title" => "Launch metrics",
          "launch_delay" => "14 days",
          "days_late" => 14,
          "secret_delay" => "classified"
        },
        @dataset
      )

    {:ok, canon} =
      Content.publish_document("m-canon", "metric", @dataset,
        workspace_id: ws_a.id,
        project_id: proj_a.id
      )

    # A referencing paper in workspace A (in the caller's scope) and one in
    # workspace B (out of scope) — both published, both wired to the canonical
    # doc with the #714 valueref-kind edge.
    {:ok, _} =
      create_document_in!(
        ws_a,
        proj_a,
        "metric",
        %{"_id" => "p-in-scope", "title" => "In-scope paper"},
        @dataset
      )

    {:ok, _} =
      Content.publish_document("p-in-scope", "metric", @dataset,
        workspace_id: ws_a.id,
        project_id: proj_a.id
      )

    {:ok, _} =
      create_document_in!(
        ws_b,
        proj_b,
        "metric",
        %{"_id" => "p-out-of-scope", "title" => "Foreign paper"},
        @dataset
      )

    {:ok, _} =
      Content.publish_document("p-out-of-scope", "metric", @dataset,
        workspace_id: ws_b.id,
        project_id: proj_b.id
      )

    # The in-scope edge resolves under A's scope; the foreign referencer's
    # edge is stored under ITS OWN tenancy resolution (edges are global rows —
    # scoping happens at hydration, which is exactly what criterion 2 tests).
    [ok: _] =
      Content.add_edges(
        [%{from_id: "p-in-scope", to_id: "m-canon", kind: "valueref"}],
        dataset: @dataset,
        workspace_id: ws_a.id,
        project_id: proj_a.id
      )

    [ok: _] =
      Content.add_edges(
        [%{from_id: "p-out-of-scope", to_id: "m-canon", kind: "valueref"}],
        dataset: @dataset
      )

    {:ok, ws_a: ws_a, proj_a: proj_a, ws_b: ws_b, proj_b: proj_b, canon: canon}
  end

  defp writer_ctx do
    CallerContext.from_token(%{id: Ecto.UUID.generate(), permissions: ["read", "write"]})
  end

  defp reader_ctx do
    CallerContext.from_token(%{id: Ecto.UUID.generate(), permissions: ["read"]})
  end

  defp admin_ctx do
    CallerContext.from_token(%{id: Ecto.UUID.generate(), permissions: ["admin"]})
  end

  defp scope(ws, proj, ctx, user_id \\ "u-writeback") do
    [
      workspace_id: ws.id,
      project_id: proj.id,
      caller_context: ctx,
      user_id: user_id,
      source: :studio
    ]
  end

  defp canon_content(ws, proj) do
    {:ok, doc} =
      Content.get_document("m-canon", "metric", @dataset,
        workspace_id: ws.id,
        project_id: proj.id
      )

    doc.content
  end

  # ── criterion 1 — authorization against the TARGET ────────────────────────

  describe "authorization against the target's write scope" do
    test "anonymous caller: affordance refused AND write refused server-side", %{
      ws_a: ws_a,
      proj_a: proj_a,
      canon: canon
    } do
      opts = [workspace_id: ws_a.id, project_id: proj_a.id]

      assert {:error, :unauthorized} =
               ValueWriteback.inspect_target("m-canon", "launch_delay", @dataset, opts)

      assert {:error, :unauthorized} =
               ValueWriteback.writeback(
                 "m-canon",
                 "launch_delay",
                 "0 days",
                 canon.rev,
                 @dataset,
                 opts
               )

      assert canon_content(ws_a, proj_a)["launch_delay"] == "14 days"
    end

    test "read-only token in the right scope is refused", %{ws_a: ws_a, proj_a: proj_a} do
      assert {:error, :unauthorized} =
               ValueWriteback.inspect_target(
                 "m-canon",
                 "launch_delay",
                 @dataset,
                 scope(ws_a, proj_a, reader_ctx())
               )
    end

    test "write access to the HOSTING paper grants nothing — cross-scope target disables",
         %{ws_a: ws_a, proj_a: proj_a, ws_b: ws_b, proj_b: proj_b, canon: canon} do
      # The caller is fully write-capable in ITS OWN workspace B: it can
      # mutate the hosting paper there through the very same guarded path…
      opts_b = scope(ws_b, proj_b, writer_ctx())

      assert {:ok, {_tx, [%{operation: "update"}]}} =
               Content.apply_mutations(
                 [
                   %{
                     "patch" => %{
                       "id" => "p-out-of-scope",
                       "type" => "metric",
                       "set" => %{"launch_delay" => "hosting paper edited fine"}
                     }
                   }
                 ],
                 @dataset,
                 opts_b
               )

      # …and the TARGET in workspace A still refuses edit-through entirely:
      # inspection (the affordance) and the write are both denied.
      assert {:error, :unauthorized} =
               ValueWriteback.inspect_target("m-canon", "launch_delay", @dataset, opts_b)

      assert {:error, :unauthorized} =
               ValueWriteback.writeback(
                 "m-canon",
                 "launch_delay",
                 "0 days",
                 canon.rev,
                 @dataset,
                 opts_b
               )

      assert canon_content(ws_a, proj_a)["launch_delay"] == "14 days"
    end

    test "a field redacted for the caller refuses edit-through; admin passes", %{
      ws_a: ws_a,
      proj_a: proj_a
    } do
      assert {:error, :unauthorized} =
               ValueWriteback.inspect_target(
                 "m-canon",
                 "secret_delay",
                 @dataset,
                 scope(ws_a, proj_a, writer_ctx())
               )

      assert {:ok, %{current_value: "classified"}} =
               ValueWriteback.inspect_target(
                 "m-canon",
                 "secret_delay",
                 @dataset,
                 scope(ws_a, proj_a, admin_ctx())
               )
    end

    test "undeclared and malformed fields are refused", %{ws_a: ws_a, proj_a: proj_a} do
      opts = scope(ws_a, proj_a, writer_ctx())

      assert {:error, :unauthorized} =
               ValueWriteback.inspect_target("m-canon", "not_declared", @dataset, opts)

      assert {:error, :invalid_field} =
               ValueWriteback.inspect_target("m-canon", "content.launch_delay", @dataset, opts)

      assert {:error, :invalid_field} =
               ValueWriteback.inspect_target("m-canon", "title", @dataset, opts)

      assert {:error, :invalid_field} =
               ValueWriteback.inspect_target("m-canon", "", @dataset, opts)
    end

    test "nonexistent target is indistinguishable from cross-scope", %{
      ws_a: ws_a,
      proj_a: proj_a
    } do
      assert {:error, :unauthorized} =
               ValueWriteback.inspect_target(
                 "no-such-doc",
                 "launch_delay",
                 @dataset,
                 scope(ws_a, proj_a, writer_ctx())
               )
    end
  end

  # ── criterion 2 — impact preview, fail-closed ─────────────────────────────

  describe "impact preview (reverse_referencers under the caller's scope)" do
    test "out-of-scope referencers are dropped entirely — no titles, no stub, no remainder count",
         %{ws_a: ws_a, proj_a: proj_a} do
      assert {:ok, %{impact: impact}} =
               ValueWriteback.inspect_target(
                 "m-canon",
                 "launch_delay",
                 @dataset,
                 scope(ws_a, proj_a, writer_ctx())
               )

      # Only the in-scope referencer is visible…
      assert impact.count == 1

      assert [%{doc_id: "p-in-scope", title: "In-scope paper", kind: "valueref"}] =
               impact.referencers

      # …the foreign one leaves NO trace: not a title, not a doc_id…
      refute inspect(impact) =~ "Foreign paper"
      refute inspect(impact) =~ "p-out-of-scope"

      # …and STRUCTURALLY there is no second counter to hide an aggregate
      # "K you cannot see" in: the map is exactly %{count:, referencers:}
      # and count is the length of what the caller may see.
      assert impact |> Map.keys() |> Enum.sort() == [:count, :referencers]
      assert impact.count == length(impact.referencers)
    end

    test "an admin scoped to workspace A still sees only A's referencers (scope opts, not role)",
         %{ws_a: ws_a, proj_a: proj_a} do
      assert {:ok, %{impact: impact}} =
               ValueWriteback.inspect_target(
                 "m-canon",
                 "launch_delay",
                 @dataset,
                 scope(ws_a, proj_a, admin_ctx())
               )

      assert impact.count == 1
      refute inspect(impact) =~ "p-out-of-scope"
    end
  end

  # ── the guarded write + provenance ────────────────────────────────────────

  describe "writeback through the guarded mutation path" do
    test "authorized writeback lands, preserves numeric type, records provenance", %{
      ws_a: ws_a,
      proj_a: proj_a,
      canon: canon
    } do
      opts = scope(ws_a, proj_a, writer_ctx(), "u-prov-test")

      assert {:ok, %{doc_id: "m-canon", impact: %{count: 1}}} =
               ValueWriteback.writeback(
                 "m-canon",
                 "launch_delay",
                 "21 days",
                 canon.rev,
                 @dataset,
                 opts
               )

      content = canon_content(ws_a, proj_a)
      assert content["launch_delay"] == "21 days"

      # The guarded path's own revision (recorded under the published
      # spelling; "create" when publish had deleted the draft twin, "update"
      # when it survived) carries the ACTOR and proves the write went through
      # Content.apply_mutations → upsert_document — a raw Repo write records
      # no revision at all.
      update_revs =
        Repo.all(
          from(r in Revision,
            where: r.doc_id == "m-canon" and r.action in ["create", "update"],
            select: r.actor_user_id
          )
        )

      assert "u-prov-test" in update_revs

      # The attributed edit-through provenance rides on top.
      prov =
        Repo.one(
          from(r in Revision,
            where: r.doc_id == "m-canon" and r.action == "valueref-writeback",
            order_by: [desc: r.inserted_at],
            limit: 1
          )
        )

      assert prov
      assert prov.actor_user_id == "u-prov-test"
      assert prov.content["launch_delay"] == "21 days"
    end

    test "numeric canonical values stay numeric", %{ws_a: ws_a, proj_a: proj_a, canon: canon} do
      opts = scope(ws_a, proj_a, writer_ctx())

      assert {:ok, _} =
               ValueWriteback.writeback("m-canon", "days_late", "21", canon.rev, @dataset, opts)

      assert canon_content(ws_a, proj_a)["days_late"] == 21
    end

    test "a stale expected_rev is a rev_mismatch and writes nothing", %{
      ws_a: ws_a,
      proj_a: proj_a
    } do
      opts = scope(ws_a, proj_a, writer_ctx())

      assert {:error, {:rev_mismatch, %{expected: "stale-rev"}}} =
               ValueWriteback.writeback(
                 "m-canon",
                 "launch_delay",
                 "0 days",
                 "stale-rev",
                 @dataset,
                 opts
               )

      assert canon_content(ws_a, proj_a)["launch_delay"] == "14 days"

      refute Repo.exists?(
               from(r in Revision,
                 where: r.doc_id == "m-canon" and r.action == "valueref-writeback"
               )
             )
    end

    test "a DIVERGED unpublished draft twin blocks writeback (never silently clobbered)", %{
      ws_a: ws_a,
      proj_a: proj_a,
      canon: canon
    } do
      opts = scope(ws_a, proj_a, writer_ctx())

      # Someone edited the target in Studio but has not published: the draft
      # twin now diverges from the published row. Propagating a writeback
      # would publish over those edits — refuse instead.
      assert {:ok, _} =
               Content.apply_mutations(
                 [
                   %{
                     "patch" => %{
                       "id" => "m-canon",
                       "type" => "metric",
                       "set" => %{"launch_delay" => "someone's unpublished edit"}
                     }
                   }
                 ],
                 @dataset,
                 opts
               )

      assert {:error, :draft_diverged} =
               ValueWriteback.writeback(
                 "m-canon",
                 "launch_delay",
                 "21 days",
                 canon.rev,
                 @dataset,
                 opts
               )

      # Neither row was touched by the refused writeback.
      assert canon_content(ws_a, proj_a)["launch_delay"] == "14 days"

      {:ok, draft} =
        Content.get_document("drafts.m-canon", "metric", @dataset,
          workspace_id: ws_a.id,
          project_id: proj_a.id
        )

      assert draft.content["launch_delay"] == "someone's unpublished edit"
    end

    test "clean (non-diverged) draft twin: inspect→writeback round-trips", %{
      ws_a: ws_a,
      proj_a: proj_a
    } do
      # REGRESSION (clean-twin CAS mismatch): opening the published target in
      # Studio spawns a CLEAN draft twin — content byte-identical to the
      # published row but carrying its OWN newer rev. This is the most common
      # live-Studio state for a published target, yet edit-through used to fail
      # closed here: `inspect_target` handed back the PUBLISHED rev while the
      # guarded patch fences the DRAFT twin (get_patch_base reads draft-first),
      # so the ifRevisionID CAS always mismatched. The fix derives the inspected
      # rev from the write-target row, so inspect → writeback round-trips.
      opts = scope(ws_a, proj_a, writer_ctx())

      # Spawn the clean draft twin (set launch_delay to its CURRENT published
      # value → draft content == published content → non-diverged).
      assert {:ok, _} =
               Content.apply_mutations(
                 [
                   %{
                     "patch" => %{
                       "id" => "m-canon",
                       "type" => "metric",
                       "set" => %{"launch_delay" => "14 days"}
                     }
                   }
                 ],
                 @dataset,
                 opts
               )

      # Sanity: a clean draft twin now exists, published row untouched.
      {:ok, draft} =
        Content.get_document("drafts.m-canon", "metric", @dataset,
          workspace_id: ws_a.id,
          project_id: proj_a.id
        )

      assert draft.content["launch_delay"] == "14 days"

      # The affordance inspects and captures the CAS rev exactly as the Studio
      # panel does — this is the rev the confirm handler pins.
      assert {:ok, %{rev: inspected_rev}} =
               ValueWriteback.inspect_target("m-canon", "launch_delay", @dataset, opts)

      # Pre-fix this rev was the published rev → the writeback below returned
      # `{:error, {:rev_mismatch, …}}`. Post-fix it names the draft twin, so the
      # guarded write lands and propagates to the canonical row.
      assert {:ok, %{doc_id: "m-canon", impact: %{count: 1}}} =
               ValueWriteback.writeback(
                 "m-canon",
                 "launch_delay",
                 "21 days",
                 inspected_rev,
                 @dataset,
                 opts
               )

      assert canon_content(ws_a, proj_a)["launch_delay"] == "21 days"
    end

    test "a missing expected_rev is refused (no blind overwrite)", %{
      ws_a: ws_a,
      proj_a: proj_a
    } do
      opts = scope(ws_a, proj_a, writer_ctx())

      assert {:error, :rev_required} =
               ValueWriteback.writeback("m-canon", "launch_delay", "x", nil, @dataset, opts)

      assert {:error, :rev_required} =
               ValueWriteback.writeback("m-canon", "launch_delay", "x", "", @dataset, opts)
    end
  end
end
