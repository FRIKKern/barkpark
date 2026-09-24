defmodule Barkpark.Webhooks.SiblingFenceNonRepetitionTest do
  @moduledoc """
  task-790e468acada213c — the two SIBLING `updated_at`-CAS writers that
  `schedule_retry/3`'s fence fix (clk-bl-webhooks-fence-equality-cas-class-d)
  left untouched. The two sites get DIFFERENT answers, and this file pins both
  so a later refactor reds instead of silently removing either.

    * `RetryWorker.claim_fence/2` — FIXED. The token it CASes on arrives from
      OUTSIDE (the Oban job args, an ISO string written at an arbitrary earlier
      instant). Nothing in this site relates the value it writes to the value it
      compares: it reads a bare `DateTime.utc_now()`. When the observed token is
      in the FUTURE — exactly the state a backward `os_time` step leaves behind,
      and the state the parent row's fix exists for — the written value is not an
      advance at all, so the CAS token can persist (or move BACKWARD) after a
      "winning" claim. The fence is now derived from the token via
      `Webhooks.advance_fence/1`.

    * `StuckDeliverySweeper.redispatch_one/1` — NOT changed, by argument. Its
      candidate SELECT is cutoff-filtered (`updated_at < cutoff`, where
      `cutoff = utc_now() - stuck_after`), so every token it can observe is
      STRICTLY BELOW a clock reading taken EARLIER in the same pass than the one
      it writes. The ordering is supplied by the query, not by luck: the site
      cannot observe a token it then re-writes. The two tests below pin both
      halves of that argument — the ordering itself, and the cutoff filter that
      produces it.

  Neither site uses HTTP here: a `source_kind: "test"` row makes
  `PayloadRebuild.rebuild/1` return `:gone` unconditionally, so the claim CAS
  runs and the drive is a no-op. The CAS is the whole subject.
  """
  use Barkpark.DataCase, async: false

  import Ecto.Query

  alias Barkpark.Repo
  alias Barkpark.Webhooks.{Delivery, RetryWorker, StuckDeliverySweeper}

  # A durable `pending` row whose rebuild is unconditionally `:gone` (GR45 "test"
  # kind), stamped with an EXACT `updated_at` so the CAS token is under our
  # control. No FKs, no snapshot, no HTTP.
  defp seed(%DateTime{} = updated_at) do
    row =
      Repo.insert!(%Delivery{
        endpoint_id: nil,
        event_id: nil,
        source_kind: "test",
        status: "pending",
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      })

    {1, _} =
      from(d in Delivery, where: d.id == ^row.id)
      |> Repo.update_all(set: [updated_at: updated_at])

    Repo.get(Delivery, row.id)
  end

  defp run_retry_worker(%Delivery{} = row, %DateTime{} = fence) do
    RetryWorker.perform(%Oban.Job{
      args: %{
        "delivery_id" => row.id,
        "attempt" => 1,
        "fence" => DateTime.to_iso8601(fence)
      }
    })
  end

  describe "RetryWorker.claim_fence/2 — DECIDED: fence derived from the token" do
    test "a winning claim writes a value STRICTLY GREATER than the token it CASed on" do
      # The token is in the future: the post-backward-step state. A bare
      # `DateTime.utc_now()` fence writes a value LESS than this token — this
      # assertion is what reds under that mutation.
      token = DateTime.utc_now() |> DateTime.add(3600, :second)
      row = seed(token)

      assert :ok = run_retry_worker(row, token)

      written = Repo.get(Delivery, row.id).updated_at
      assert DateTime.compare(written, token) == :gt
    end

    test "the claim does not push the row BACK below a sweeper cutoff (no re-claim)" do
      # Consequence, not restatement: a claim that writes a value below its own
      # token leaves the row instantly re-selectable by the crash sweeper it is
      # supposed to be mutually exclusive with.
      token = DateTime.utc_now() |> DateTime.add(3600, :second)
      row = seed(token)

      assert :ok = run_retry_worker(row, token)
      claimed_at = Repo.get(Delivery, row.id).updated_at

      _ = StuckDeliverySweeper.sweep(0)

      assert Repo.get(Delivery, row.id).updated_at == claimed_at
    end

    test "CONTROL — the rig CAN see a fence that fails to advance" do
      # Distinguishes "the site is safe" from "the test cannot tell". The same
      # CAS shape with a bare-clock fence, issued directly, reds the property the
      # two tests above assert.
      token = DateTime.utc_now() |> DateTime.add(3600, :second)
      row = seed(token)
      bare_clock_fence = DateTime.utc_now()

      {1, _} =
        from(d in Delivery,
          where: d.id == ^row.id and d.status == "pending" and d.updated_at == ^token
        )
        |> Repo.update_all(set: [updated_at: bare_clock_fence])

      written = Repo.get(Delivery, row.id).updated_at
      refute DateTime.compare(written, token) == :gt
    end
  end

  describe "StuckDeliverySweeper — DECIDED: unchanged, guaranteed by the cutoff filter" do
    test "the claim-CAS writes a value STRICTLY GREATER than the token it observed" do
      token = DateTime.utc_now() |> DateTime.add(-600, :second)
      row = seed(token)

      assert %{} = StuckDeliverySweeper.sweep(300)

      written = Repo.get(Delivery, row.id).updated_at
      assert DateTime.compare(written, token) == :gt
    end

    test "the cutoff filter is WHY: a token at-or-after the cutoff is never observed" do
      # This is the structural half. Remove `d.updated_at < ^cutoff` from
      # `stuck_candidates/1` and this row becomes a candidate, its CAS fires, and
      # `updated_at` moves — which is what this asserts it must not do.
      token = DateTime.utc_now() |> DateTime.add(-5, :second)
      row = seed(token)

      assert %{} = StuckDeliverySweeper.sweep(300)

      assert Repo.get(Delivery, row.id).updated_at == token
      assert Repo.get(Delivery, row.id).status == "pending"
    end
  end
end
