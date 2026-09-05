defmodule Barkpark.Tasks.LeaseExtensionTest do
  @moduledoc """
  task-16e56d05b809dd39 — the PR lease extension: `Tasks.Renew` buys a claimed
  row grace while an OPEN pull request names it, and `TtlSweeper` honours the
  window it stamps.

  The measured defect: `:task_lease_ttl_seconds` is 2700 (45 min) and the CI
  queue ran 60-90 min, so the required `PR references an active task` gate met
  rows whose claim had already been reaped out from under their own open PR.

  **Scoping.** `TtlSweeper.sweep/1` sweeps the WHOLE table and every agent in
  this repo shares one test database, so a peer's rows land in the same sweep.
  Nothing here asserts on the `%{swept:, skipped:}` tally — every assertion
  reads back the state of a uniquely-named row this test created. The control
  row is what makes the retention claim non-vacuous: an identical row with no
  extension MUST be reaped by the same sweep call that spares the extended one.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document
  alias Barkpark.Tasks.TtlSweeper

  @dataset "production"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    %{scope: scope}
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # A claimed, ALREADY-STALE row: claim it through the real engine, then push
  # `claim.ts_iso` into the past so the next sweep sees an expired lease
  # without anyone sleeping. Returns the reloaded doc.
  defp claimed_and_aged!(scope, seconds_ago) do
    phase_id = uniq("phase-lease-ext")
    _task = mk_task!(uniq("lease-ext"), scope, phase_id)

    {:ok, claimed} = Tasks.claim("worker-A", scope ++ [phase_id: phase_id, dataset: @dataset])

    iso = DateTime.utc_now() |> DateTime.add(-seconds_ago, :second) |> DateTime.to_iso8601()
    new_claim = Map.put(claimed.content["claim"], "ts_iso", iso)

    {1, _} =
      from(d in Document, where: d.id == ^claimed.id)
      |> Repo.update_all(set: [content: Map.put(claimed.content, "claim", new_claim)])

    Repo.get!(Document, claimed.id)
  end

  defp mk_task!(doc_id, scope, phase_id) do
    {:ok, doc} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => doc_id,
          "content" => %{
            "kind" => "task",
            "lifecycle_status" => "open",
            "parent_id" => phase_id
          }
        },
        @dataset,
        scope
      )

    doc
  end

  defp reload(%Document{id: id}), do: Repo.get!(Document, id)
  defp claim_of(doc), do: doc.content["claim"] || %{}
  defp extension_of(doc), do: claim_of(doc)["lease_extension"]

  # ─── Criterion 1 — an open PR's row survives, an identical one does not ───

  describe "an OPEN PR extends the lease past the normal lapse" do
    test "the extended row is retained and the control row is reaped, by ONE sweep",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      # Two rows in the same state: claimed by worker-A, lease stale by 10 min
      # against a 300 s TTL. The ONLY difference is the renew.
      extended = claimed_and_aged!(scope, 600)
      control = claimed_and_aged!(scope, 600)

      before_claim = claim_of(extended)

      assert {:ok, renewed} = Tasks.renew_lease_by_id(extended.id, pr: 15_234)
      ext = extension_of(renewed)

      assert ext["pr"] == 15_234
      assert ext["reason"] == "open_pr"
      assert ext["renewals"] == 1
      assert {:ok, until, _} = DateTime.from_iso8601(ext["until"])
      assert DateTime.compare(until, DateTime.utc_now()) == :gt

      # The renew touched NOTHING a lead's CAS reads: same epoch, same worker,
      # same ts_iso. This is the property that makes the verb safe to call from
      # CI while a lead is stamping the same row.
      assert claim_of(renewed)["epoch"] == before_claim["epoch"]
      assert claim_of(renewed)["worker"] == before_claim["worker"]
      assert claim_of(renewed)["ts_iso"] == before_claim["ts_iso"]
      assert renewed.content["lifecycle_status"] == "in_progress"

      _ = TtlSweeper.sweep(300)

      kept = reload(extended)
      reaped = reload(control)

      # RETAINED: still in_progress, and — criterion 1's second half — the
      # holder and the claim epoch are UNCHANGED.
      assert kept.content["lifecycle_status"] == "in_progress"
      assert claim_of(kept)["worker"] == "worker-A"
      assert claim_of(kept)["epoch"] == before_claim["epoch"]
      refute Map.has_key?(claim_of(kept), "expired_at")

      # NON-VACUITY: the identical row with no PR reference WAS released by the
      # same sweep — worker cleared, epoch bumped (the fencing kick).
      assert reaped.content["lifecycle_status"] == "open"
      assert is_nil(claim_of(reaped)["worker"])
      assert claim_of(reaped)["epoch"] == claim_of(control)["epoch"] + 1
    end

    test "a renew is refused on a row whose lease already lapsed", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      row = claimed_and_aged!(scope, 600)
      _ = TtlSweeper.sweep(300)

      # The reap already happened: the claim is dead and a renew may EXTEND a
      # lease, never resurrect one.
      assert {:error, :not_claimed} = Tasks.renew_lease_by_id(row.id, pr: 15_234)
      assert is_nil(extension_of(reload(row)))
    end
  end

  # ─── Criterion 2 — a closed/merged PR stops extending ─────────────────────

  describe "a closed or merged PR stops extending the lease" do
    test "state=merged clears the extension and the next sweep releases on schedule",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      row = claimed_and_aged!(scope, 600)
      epoch_before = claim_of(row)["epoch"]

      assert {:ok, _} = Tasks.renew_lease_by_id(row.id, pr: 15_234)
      _ = TtlSweeper.sweep(300)
      assert reload(row).content["lifecycle_status"] == "in_progress"

      # The PR merges — the mark clears the grace it bought.
      assert {:ok, cleared} = Tasks.renew_lease_by_id(row.id, pr: 15_234, state: "merged")
      assert is_nil(extension_of(cleared))
      assert claim_of(cleared)["epoch"] == epoch_before

      _ = TtlSweeper.sweep(300)

      released = reload(row)
      assert released.content["lifecycle_status"] == "open"
      assert is_nil(claim_of(released)["worker"])
      assert claim_of(released)["epoch"] == epoch_before + 1
    end

    test "an ELAPSED window releases with no clear message at all", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      # The safety property: nobody has to tell the ledger a PR closed. When
      # nothing renews, `until` slides into the past and the next sweep reaps.
      row = claimed_and_aged!(scope, 600)
      assert {:ok, renewed} = Tasks.renew_lease_by_id(row.id, pr: 15_234)

      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()
      claim = claim_of(renewed)
      stale_ext = Map.put(claim["lease_extension"], "until", past)
      new_claim = Map.put(claim, "lease_extension", stale_ext)

      {1, _} =
        from(d in Document, where: d.id == ^row.id)
        |> Repo.update_all(set: [content: Map.put(renewed.content, "claim", new_claim)])

      _ = TtlSweeper.sweep(300)

      assert reload(row).content["lifecycle_status"] == "open"
    end

    test "closing a DIFFERENT pr does not cancel the grace this one bought",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      row = claimed_and_aged!(scope, 600)
      assert {:ok, _} = Tasks.renew_lease_by_id(row.id, pr: 15_234)

      assert {:ok, untouched} = Tasks.renew_lease_by_id(row.id, pr: 999, state: "closed")
      assert extension_of(untouched)["pr"] == 15_234

      _ = TtlSweeper.sweep(300)
      assert reload(row).content["lifecycle_status"] == "in_progress"
    end
  end

  # ─── The cap — an abandoned PR cannot pin a row forever ───────────────────

  describe "the extension is capped from the first grant" do
    test "renewing past the cap is refused, and the next sweep releases",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      row = claimed_and_aged!(scope, 600)
      assert {:ok, renewed} = Tasks.renew_lease_by_id(row.id, pr: 15_234)

      # Backdate `first_granted_at` past the cap — the same row an abandoned PR
      # would produce after a day of dutiful renewals.
      old = DateTime.utc_now() |> DateTime.add(-(Tasks.Renew.max_seconds() + 60), :second)
      claim = claim_of(renewed)

      aged_ext =
        claim["lease_extension"]
        |> Map.put("first_granted_at", DateTime.to_iso8601(old))
        |> Map.put("until", DateTime.to_iso8601(DateTime.add(old, 60, :second)))

      {1, _} =
        from(d in Document, where: d.id == ^row.id)
        |> Repo.update_all(
          set: [
            content:
              Map.put(renewed.content, "claim", Map.put(claim, "lease_extension", aged_ext))
          ]
        )

      assert {:error, :extension_cap_reached} = Tasks.renew_lease_by_id(row.id, pr: 15_234)

      _ = TtlSweeper.sweep(300)
      assert reload(row).content["lifecycle_status"] == "open"
    end

    test "a renewal naming a NEW pr re-anchors the cap", %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      row = claimed_and_aged!(scope, 600)
      assert {:ok, first} = Tasks.renew_lease_by_id(row.id, pr: 15_234)
      assert {:ok, second} = Tasks.renew_lease_by_id(row.id, pr: 15_999)

      assert extension_of(second)["pr"] == 15_999
      assert extension_of(second)["renewals"] == 1
      refute extension_of(second)["first_granted_at"] == extension_of(first)["first_granted_at"]
    end

    test "a second renewal for the SAME pr keeps the anchor and counts up",
         %{scope: scope} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      row = claimed_and_aged!(scope, 600)
      assert {:ok, first} = Tasks.renew_lease_by_id(row.id, pr: 15_234)
      assert {:ok, second} = Tasks.renew_lease_by_id(row.id, pr: 15_234)

      assert extension_of(second)["renewals"] == 2

      assert extension_of(second)["first_granted_at"] ==
               extension_of(first)["first_granted_at"]
    end
  end
end
