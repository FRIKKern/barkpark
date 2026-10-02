defmodule Barkpark.Webhooks.RetryFenceNonRepetitionTest do
  @moduledoc """
  clk-bl-webhooks-fence-equality-cas-class-d — `schedule_retry/3` uses
  `updated_at` as an EQUALITY CAS token, so the fence it writes must never equal
  the token it compares (class-D non-repetition).

  This file does two things:

    1. PROVES THE CONSEQUENCE. A repeated fence is not a theoretical annoyance —
       when the written value equals the compared one, two writers holding the
       same stale struct BOTH claim the row (the "mutually exclusive" property
       the docstring asserts is gone). That is measured here directly against the
       Repo, not argued.

    2. PINS THE FIX. `advance_fence/1` returns a value STRICTLY greater than the
       token for any token, including one that lies in the FUTURE — the state a
       backward clock step leaves behind, and the state under which a bare
       `DateTime.utc_now()` writes a value that is NOT an advance. Replace
       `advance_fence(delivery.updated_at)` with `DateTime.utc_now()` and the
       pin tests here go RED.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Repo
  alias Barkpark.Webhooks
  alias Barkpark.Webhooks.Delivery

  defp media_row do
    {:ok, d} =
      Webhooks.create_media_delivery(%{
        "url" => "https://cdn.example.test/h",
        "secret" => "s",
        "body" => ~s({"e":"#{System.unique_integer([:positive])}"})
      })

    d
  end

  # The CAS exactly as `schedule_retry/3` issues it, with the fence value under
  # our control so a REPEAT can be exhibited.
  defp cas(delivery, token, fence) do
    {n, _} =
      from(d in Delivery,
        where: d.id == ^delivery.id and d.status == "pending" and d.updated_at == ^token
      )
      |> Repo.update_all(set: [attempts: 1, updated_at: fence])

    n
  end

  describe "the consequence of a repeated fence (reachability of the HARM)" do
    test "a fence EQUAL to its token lets two writers both claim the same row" do
      d = media_row()
      token = Repo.get(Delivery, d.id).updated_at

      # Two writers holding the same stale struct. Writer A writes a fence equal
      # to the token — the repeated-value case the class-D question is about.
      assert cas(d, token, token) == 1
      # Writer B's CAS SHOULD have missed. It does not: the token is still there.
      assert cas(d, token, token) == 1
    end

    test "CONTROL — an ADVANCING fence makes the second writer miss" do
      d = media_row()
      token = Repo.get(Delivery, d.id).updated_at

      assert cas(d, token, Webhooks.advance_fence(token)) == 1
      assert cas(d, token, Webhooks.advance_fence(token)) == 0
    end
  end

  describe "advance_fence/1 — the non-repetition guarantee" do
    test "is strictly greater than the token when the clock is ahead" do
      previous = DateTime.utc_now() |> DateTime.add(-60, :second)
      assert DateTime.compare(Webhooks.advance_fence(previous), previous) == :gt
    end

    test "is strictly greater than a token EQUAL to the current instant" do
      previous = DateTime.utc_now()
      assert DateTime.compare(Webhooks.advance_fence(previous), previous) == :gt
    end

    test "is strictly greater than a token in the FUTURE (backward clock step)" do
      # A bare `DateTime.utc_now()` fence returns a value LESS than this token —
      # not an advance at all. This is the assertion that reds under that mutation.
      previous = DateTime.utc_now() |> DateTime.add(3600, :second)
      fence = Webhooks.advance_fence(previous)

      assert DateTime.compare(fence, previous) == :gt
      assert DateTime.diff(fence, previous, :microsecond) == 1
    end
  end

  describe "schedule_retry/3 writes an advancing fence" do
    test "the stored updated_at strictly advances past the token, even from the future" do
      d = media_row()
      future = DateTime.utc_now() |> DateTime.add(3600, :second)

      {1, _} =
        from(x in Delivery, where: x.id == ^d.id)
        |> Repo.update_all(set: [updated_at: future])

      stale = Repo.get(Delivery, d.id)
      assert {:ok, _job} = Webhooks.schedule_retry(stale, 1, 0)

      written = Repo.get(Delivery, d.id).updated_at
      assert DateTime.compare(written, stale.updated_at) == :gt

      # And the stale struct's CAS now correctly MISSES — the mutual exclusion
      # the docstring claims actually holds.
      assert Webhooks.schedule_retry(stale, 2, 0) == {:error, :superseded}
    end
  end
end
