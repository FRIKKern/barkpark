defmodule BarkparkCloud.CommitDistanceSweepTest do
  @moduledoc """
  deploy-reliability W21 backlog — the commit-distance sweep against the shared
  60/h anonymous GitHub budget.

  What these pin:

    1. **N boxes on ONE sha cost ONE compare call.** The counting is of ACTUAL
       invocations of the injected client, and the control arm — N boxes on N
       distinct shas — must still cost N, or the memo would be "proved" by a
       sweep that simply never calls.
    2. **The tick says how many boxes went UNMEASURED and WHY**, per DISTINCT
       reason. `no_sha` (agent offline, no call issued) is never folded into
       `rate_limited` (the budget refused us) and neither into `unreachable`
       (egress blocked / transport dead) — the three are told apart ONLY here,
       and on the fleet surface they are the same all-unknown column.
    3. **The halt**: after the first 403 the tick stops spending the budget on
       refusals, counts the skipped boxes under the rate-limited bucket, and
       leaves their existing verdict and `commit_distance_checked_at` ALONE
       rather than stamping a fresh "we measured nothing" over a real answer.

  No network: the compare client is injected in every test.
  """
  use BarkparkCloud.DataCase, async: false

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.GitHub.{CommitDistance, CommitDistanceSweep}
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.StudioLinkFakeHttpClient
  alias BarkparkCloud.Workers.UpdateStatusWorker

  @admin_token "instance-admin-token-plaintext"
  @sha_a "aaaaaaa1111111111111111111111111111111111"
  @sha_b "bbbbbbb2222222222222222222222222222222222"

  setup do
    original = Application.get_env(:barkpark_cloud, CommitDistance)
    on_exit(fn -> restore_env(original) end)
    StudioLinkFakeHttpClient.program([])
    :ok
  end

  # ── fixtures ──

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp barkpark(attrs) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team_fixture(), %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
    |> Ecto.Changeset.change(
      Map.merge(
        %{
          host: "203.0.113.#{rem(n, 250) + 1}",
          url: "https://bp-#{n}.barkpark.cloud",
          admin_token_encrypted: Vault.encrypt(@admin_token),
          git_commit: @sha_a
        },
        attrs
      )
    )
    |> Repo.update!()
  end

  defp restore_env(nil), do: Application.delete_env(:barkpark_cloud, CommitDistance)
  defp restore_env(value), do: Application.put_env(:barkpark_cloud, CommitDistance, value)

  defp put_compare_client(client) do
    Application.put_env(:barkpark_cloud, CommitDistance, http_client: client)
  end

  defp compare_body(status, ahead_by) do
    Jason.encode!(%{"status" => status, "ahead_by" => ahead_by, "behind_by" => 0})
  end

  # Answers per served sha, and TELLS THE TEST every invocation so the call
  # count is of real client invocations, not of anything the sweep reports
  # about itself.
  defp counting_client(by_sha) do
    test = self()

    fn %{url: url} = req ->
      send(test, {:compare_request, url})

      sha =
        url
        |> String.split("/compare/")
        |> List.last()
        |> String.split("...")
        |> List.first()

      case Map.fetch(by_sha, sha) do
        {:ok, response} when is_function(response, 1) -> response.(req)
        {:ok, response} -> response
        :error -> {:error, {:http_client, :nxdomain}}
      end
    end
  end

  defp compare_calls do
    receive do
      {:compare_request, url} -> [url | compare_calls()]
    after
      0 -> []
    end
  end

  defp sweep_tally do
    ref = make_ref()
    test = self()
    handler = {__MODULE__, ref}

    :telemetry.attach(
      handler,
      CommitDistanceSweep.telemetry_event(),
      fn _event, measurements, meta, _ -> send(test, {ref, measurements, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    fn ->
      receive do
        {^ref, measurements, meta} -> {measurements, meta}
      after
        0 -> flunk("the sweep emitted no #{inspect(CommitDistanceSweep.telemetry_event())} event")
      end
    end
  end

  describe "per-sha memoization — the budget fix" do
    test "THREE boxes on ONE git_commit cost ONE compare call" do
      for _ <- 1..3, do: barkpark(%{git_commit: @sha_a})

      put_compare_client(
        counting_client(%{@sha_a => {:ok, %{status: 200, body: compare_body("ahead", 2468)}}})
      )

      assert UpdateStatusWorker.perform(%Oban.Job{}) == :ok

      assert length(compare_calls()) == 1
    end

    test "and every one of them still gets the memoized verdict written" do
      boxes = for _ <- 1..3, do: barkpark(%{git_commit: @sha_a})

      put_compare_client(
        counting_client(%{@sha_a => {:ok, %{status: 200, body: compare_body("ahead", 592)}}})
      )

      assert UpdateStatusWorker.perform(%Oban.Job{}) == :ok

      for bp <- boxes do
        reloaded = Registry.get_barkpark(bp.id)
        assert reloaded.commit_ancestry == "behind"
        assert reloaded.commit_distance == 592
      end
    end

    # The CONTROL. Without it "1 call for 3 boxes" is also what a sweep that
    # stopped calling GitHub entirely would print.
    test "control: THREE boxes on THREE distinct shas still cost THREE calls" do
      shas = [@sha_a, @sha_b, "ccccccc3333333333333333333333333333333333"]
      for sha <- shas, do: barkpark(%{git_commit: sha})

      responses =
        Map.new(shas, &{&1, {:ok, %{status: 200, body: compare_body("ahead", 7)}}})

      put_compare_client(counting_client(responses))

      assert UpdateStatusWorker.perform(%Oban.Job{}) == :ok

      assert length(compare_calls()) == 3
    end

    test "the memo is keyed on the URL CommitDistance actually requests" do
      assert CommitDistance.compare_url(@sha_a) =~ "/compare/#{@sha_a}...main"
    end
  end

  describe "the unmeasured report — distinct reasons, not silence" do
    test "no_sha, rate_limited and unreachable land in THREE different buckets" do
      barkpark(%{git_commit: @sha_a})
      barkpark(%{git_commit: ""})
      barkpark(%{git_commit: @sha_b})
      barkpark(%{git_commit: "ddddddd4444444444444444444444444444444444"})

      tally = sweep_tally()

      put_compare_client(
        counting_client(%{
          @sha_a => {:ok, %{status: 200, body: compare_body("ahead", 4)}},
          @sha_b => {:ok, %{status: 403, body: "rate limit exceeded"}},
          "ddddddd4444444444444444444444444444444444" => {:error, {:http_client, :nxdomain}}
        })
      )

      # The halt would swallow whichever box the 403 preceded, so this arm
      # measures the BUCKETS with every box actually graded.
      assert UpdateStatusWorker.perform(%Oban.Job{}) == :ok

      {counts, meta} = tally.()

      assert counts.boxes == 4
      assert counts.measured == 1
      assert meta.unmeasured == 3

      assert counts.unmeasured_no_sha == 1
      assert counts.unmeasured_rate_limited >= 1
      # An offline agent is NEVER a budget refusal, and a dead transport is
      # never one either — folding any pair of these is the failure this row
      # was filed about.
      assert counts.unmeasured_no_sha + counts.unmeasured_rate_limited +
               counts.unmeasured_unreachable == 3
    end

    test "a 404 sha is its OWN bucket, not 'unreachable'" do
      barkpark(%{git_commit: @sha_b})
      tally = sweep_tally()
      put_compare_client(counting_client(%{@sha_b => {:ok, %{status: 404, body: "{}"}}}))

      assert UpdateStatusWorker.perform(%Oban.Job{}) == :ok

      {counts, _meta} = tally.()
      assert counts.unmeasured_unknown_commit == 1
      assert counts.unmeasured_unreachable == 0
      assert counts.unmeasured_rate_limited == 0
    end

    test "a fleet the control plane cannot reach AT ALL reports unreachable, not silence" do
      for _ <- 1..2, do: barkpark(%{git_commit: @sha_a})
      tally = sweep_tally()
      put_compare_client(fn _ -> {:error, {:http_client, :nxdomain}} end)

      assert UpdateStatusWorker.perform(%Oban.Job{}) == :ok

      {counts, meta} = tally.()
      assert counts.measured == 0
      assert meta.unmeasured == counts.boxes
      assert counts.unmeasured_unreachable == counts.boxes
      assert counts.unmeasured_rate_limited == 0
      assert counts.unmeasured_no_sha == 0
    end

    test "every bucket name is distinct and the tally carries all of them" do
      assert CommitDistanceSweep.buckets() == Enum.uniq(CommitDistanceSweep.buckets())

      sweep = CommitDistanceSweep.new(http_client: fn _ -> {:error, :nope} end)
      tally = CommitDistanceSweep.tally(sweep)

      for bucket <- CommitDistanceSweep.buckets() do
        assert Map.has_key?(tally, bucket), "tally is missing the #{bucket} bucket"
      end

      CommitDistanceSweep.close(sweep)
    end
  end

  describe "the halt after a rate-limit refusal" do
    test "the tick stops spending the budget and counts what it skipped" do
      for _ <- 1..4, do: barkpark(%{git_commit: unique_sha()})
      tally = sweep_tally()
      put_compare_client(fn _ -> {:ok, %{status: 403, body: "rate limit exceeded"}} end)

      assert UpdateStatusWorker.perform(%Oban.Job{}) == :ok

      {counts, _meta} = tally.()
      assert counts.boxes == 4
      assert counts.compare_calls == 1
      assert counts.skipped_after_rate_limit == 3
      assert counts.unmeasured_rate_limited == 4
    end

    test "a skipped box keeps its previous verdict instead of a fake 'checked'" do
      stamped = ~U[2026-01-01 00:00:00.000000Z]

      seeded = %{
        commit_ancestry: "behind",
        commit_distance: 12,
        commit_distance_checked_at: stamped
      }

      boxes =
        for _ <- 1..2,
            do: barkpark(Map.put(seeded, :git_commit, unique_sha()))

      put_compare_client(fn _ -> {:ok, %{status: 403, body: "rate limit exceeded"}} end)
      assert UpdateStatusWorker.perform(%Oban.Job{}) == :ok

      rows = Enum.map(boxes, &Registry.get_barkpark(&1.id))

      # Exactly one box was graded (and honestly landed unknown); the other was
      # SKIPPED by the halt, and a skipped box is not rewritten at all — its
      # real 12-behind answer and its old timestamp both survive, rather than
      # being replaced by a fresh stamp claiming we checked and found nothing.
      graded = Enum.filter(rows, &(&1.commit_ancestry == "unknown"))
      untouched = Enum.filter(rows, &(&1.commit_ancestry == "behind"))

      assert length(graded) == 1
      assert length(untouched) == 1

      [kept] = untouched
      assert kept.commit_distance == 12
      assert DateTime.compare(kept.commit_distance_checked_at, stamped) == :eq
    end

    test "stop_after_rate_limit: false grades every box anyway" do
      sweep =
        CommitDistanceSweep.new(
          stop_after_rate_limit: false,
          http_client: fn _ -> {:ok, %{status: 403, body: ""}} end
        )

      assert CommitDistance.verdict(@sha_a, CommitDistanceSweep.client_opts(sweep)) ==
               %{ancestry: "unknown", distance: nil}

      refute CommitDistanceSweep.halted?(sweep)
      CommitDistanceSweep.close(sweep)
    end
  end

  defp unique_sha do
    n = System.unique_integer([:positive])
    String.pad_leading(Integer.to_string(n), 40, "e")
  end
end
