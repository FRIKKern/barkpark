defmodule Barkpark.Tenancy.Workers.PlaygroundReaperTest do
  @moduledoc """
  Lifecycle gate for the two-stage playground TTL reaper (charter D28/D29).

  Proves the state machine off origin/main (D29): a playground past `expires_at`
  is SUSPENDED (not deleted), a suspended playground past the 24h grace is
  swept-DELETED, a still-live playground and — critically — any non-playground
  workspace are UNTOUCHED regardless of their `expires_at`/suspension state.

  `tier`/`expires_at` are Slice 1-owned columns (`bpb-step4-playground-safety`).
  This suite provisions them idempotently with `ADD COLUMN IF NOT EXISTS` so the
  reaper slice proves standalone-green without depending on Slice 1's migration
  being merged first; the reaper reads them via SQL fragments, so nothing here
  or in the worker changes once the two slices integrate. The mechanical
  E3-zero-orphan parity across all 11 string-keyed tables is the LEAD merge gate
  (D29) — this suite proves `delete_workspace/1` is INVOKED (workspace + its
  document gone), not the full count-parity.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Content.Document
  alias Barkpark.Repo
  alias Barkpark.Tenancy.Workspace
  alias Barkpark.Tenancy.Workers.PlaygroundReaper

  setup do
    # Slice 1-owned columns — provision idempotently so the reaper lifecycle is
    # provable off origin/main (D29). A no-op once Slice 1's migration lands.
    Repo.query!("ALTER TABLE workspaces ADD COLUMN IF NOT EXISTS tier text")
    Repo.query!("ALTER TABLE workspaces ADD COLUMN IF NOT EXISTS expires_at timestamptz")
    :ok
  end

  # Set the playground/suspension columns directly. Keyed by slug (text) so no
  # binary-uuid marshalling is needed; `suspended`/`suspended_at` are real schema
  # columns, `tier`/`expires_at` are the Slice 1 columns provisioned above.
  defp mark!(%Workspace{} = ws, fields) do
    Repo.query!(
      """
      UPDATE workspaces
      SET tier = $1, expires_at = $2, suspended = $3, suspended_at = $4
      WHERE slug = $5
      """,
      [
        Keyword.get(fields, :tier),
        Keyword.get(fields, :expires_at),
        Keyword.get(fields, :suspended, false),
        Keyword.get(fields, :suspended_at),
        ws.slug
      ]
    )

    ws
  end

  defp reload(%Workspace{id: id}), do: Repo.get(Workspace, id)

  describe "perform/1 — two-stage lifecycle" do
    test "suspends the expired playground, swept-deletes the past-grace one, spares live + in-grace" do
      now = DateTime.utc_now()

      # Stage 1 target: expired, not yet suspended.
      expired = create_workspace!() |> mark!(tier: "playground", expires_at: hours_ago(now, 1))

      # Stage 2 target: suspended, past the 24h grace. Give it a document so we
      # prove the SWEPT delete_workspace path ran (not a bare row delete).
      grace_over =
        create_workspace!()
        |> mark!(
          tier: "playground",
          expires_at: hours_ago(now, 30),
          suspended: true,
          suspended_at: hours_ago(now, 25)
        )

      proj = create_project!(grace_over)
      {:ok, doc} = create_document_in!(grace_over, proj, "post", %{"doc_id" => "gone"})

      # Suspended but STILL within grace → Stage 2 must not touch it yet.
      grace_within =
        create_workspace!()
        |> mark!(
          tier: "playground",
          expires_at: hours_ago(now, 26),
          suspended: true,
          suspended_at: hours_ago(now, 1)
        )

      # Live, unexpired playground → neither stage touches it.
      live = create_workspace!() |> mark!(tier: "playground", expires_at: hours_ahead(now, 1))

      assert {:ok, %{suspended: 1, deleted: 1}} = PlaygroundReaper.perform(%Oban.Job{})

      # Stage 1: expired → suspended with the playground reason, NOT deleted.
      expired = reload(expired)
      assert expired.suspended == true
      assert expired.suspended_reason == "playground_expired"

      # Stage 2: past-grace → gone, and its document swept with it.
      assert reload(grace_over) == nil
      refute Repo.get(Document, doc.id)

      # Spared: in-grace still present + suspended; live still present + active.
      assert %Workspace{suspended: true} = reload(grace_within)
      assert %Workspace{suspended: false} = reload(live)
    end

    test "an expired playground just suspended this tick is not also deleted this tick" do
      now = DateTime.utc_now()
      ws = create_workspace!() |> mark!(tier: "playground", expires_at: hours_ago(now, 1))

      assert {:ok, %{suspended: 1, deleted: 0}} = PlaygroundReaper.perform(%Oban.Job{})

      # suspended_at was stamped to ~now, so it is nowhere near the +24h grace.
      assert %Workspace{suspended: true} = reload(ws)
    end
  end

  describe "tier guard — non-playground workspaces are never reaped" do
    test "a customer workspace with a past expires_at is neither suspended nor deleted" do
      now = DateTime.utc_now()

      # Would match Stage 1 if the tier guard were missing.
      customer =
        create_workspace!() |> mark!(tier: "customer", expires_at: hours_ago(now, 5))

      # Would match Stage 2 if the tier guard were missing (suspended, past grace,
      # but tier is NULL — a plain non-playground workspace).
      nil_tier =
        create_workspace!()
        |> mark!(
          tier: nil,
          expires_at: hours_ago(now, 40),
          suspended: true,
          suspended_at: hours_ago(now, 30)
        )

      assert {:ok, %{suspended: 0, deleted: 0}} = PlaygroundReaper.perform(%Oban.Job{})

      assert %Workspace{suspended: false} = reload(customer)
      assert %Workspace{suspended: true} = reload(nil_tier)
    end
  end

  describe "perform/1 — empty tick" do
    test "no expired or past-grace playgrounds is a clean no-op" do
      assert {:ok, %{suspended: 0, deleted: 0}} = PlaygroundReaper.perform(%Oban.Job{})
    end
  end

  defp hours_ago(%DateTime{} = now, h), do: DateTime.add(now, -h, :hour)
  defp hours_ahead(%DateTime{} = now, h), do: DateTime.add(now, h, :hour)
end
