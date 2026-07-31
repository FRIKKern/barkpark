defmodule BarkparkCloud.Registry.DeployStageEstimatesTest do
  @moduledoc """
  cch-w12-s4 — the deploy rail's per-stage estimates are MEASURED, or refused.

  The console used to pace its deploy rail off hardcoded literals and they were
  wrong by an order of magnitude: it told a person BUILD takes 120000ms when the
  live control plane's 30-day cohort has a p50 of 14835ms over 8211 paired
  attempts (HEALTH advertised 18000ms against 2098ms). This pins the fold that
  replaces them, and — just as load-bearing — the four REFUSALS that stop it
  swapping an invented number for a sampling artifact:

    * per-attempt pairing, because the naive min(running)→max(done) fold
      produced a HEALTH minimum of -61637ms on real prod rows;
    * outlier trimming, because the same cohort holds a 111611410ms BUILD;
    * a minimum sample count, so a quiet week is never a "median";
    * a cadence refusal, because RETIRE/STAGE/SWITCH bottom out at
      2035/2036/2036ms with p50s of 2102/2099/2119 — the deploy driver's ~2s
      poll cadence, not their work.

  The pure fold is exercised without a database; one route case pins the
  additive `step_estimates` key on the existing `GET /v1/barkparks` envelope.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"
  # Any fixed wall clock — the fold reads DIFFERENCES, never absolute time.
  @base 1_700_000_000_000

  ## Fixtures — console arrays exactly as Sites.Deploy.console_entry/1 appends

  defp at(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

  defp entry(stage, status, ms),
    do: %{"stage" => stage, "status" => status, "at" => at(ms), "line" => "#{stage} #{status}"}

  # One deployment's console: one clean attempt at `stage` lasting `dur` ms.
  defp console(stage, dur),
    do: [entry(stage, "running", @base), entry(stage, "done", @base + dur)]

  defp consoles(stage, durations), do: Enum.map(durations, &console(stage, &1))

  # `count` samples spread evenly across [lo, hi] — a distribution with a real
  # shape, unlike the single-spike cadence artifact.
  defp spread(lo, hi, count) do
    step = div(hi - lo, max(count - 1, 1))
    for i <- 0..(count - 1), do: lo + i * step
  end

  defp fold(consoles), do: Registry.deploy_stage_estimates_from_consoles(consoles)

  ## The fold

  describe "measured medians" do
    test "a stage with a real distribution publishes its trimmed p50" do
      # 200 BUILDs between 5s and 45s. The published number must land inside the
      # sample range and near the middle — it is a median, not a guess.
      out = fold(consoles("BUILD", spread(5_000, 45_000, 200)))

      assert %{deploy: deploy, meta: meta} = out
      assert Map.has_key?(deploy, "BUILD")
      assert deploy["BUILD"] > 20_000 and deploy["BUILD"] < 30_000
      assert meta.samples["BUILD"] == 200
      assert meta.deployments == 200
      assert meta.window_days == 30
      refute Map.has_key?(meta.refused, "BUILD")
    end

    test "the published value is the MEASURED one, not the constant it replaces" do
      # Every BUILD in the cohort finished in ~15s. The console's constant was
      # 120000ms; nothing near it may survive the fold.
      out = fold(consoles("BUILD", spread(12_000, 18_000, 120)))
      assert out.deploy["BUILD"] < 20_000
    end
  end

  describe "policy 1 — per-attempt pairing" do
    test "a RETRY inside one console pairs each attempt, never min(running)→max(done)" do
      # running@0 … failed@60s … running@70s … done@80s. The honest duration of
      # the attempt that succeeded is 10s. A min→max fold would say 80s.
      retry = [
        entry("BUILD", "running", @base),
        entry("BUILD", "failed", @base + 60_000),
        entry("BUILD", "running", @base + 70_000),
        entry("BUILD", "done", @base + 80_000)
      ]

      out = fold(List.duplicate(retry, 60))
      assert out.meta.samples["BUILD"] == 60
      assert out.deploy["BUILD"] == 10_000
    end

    test "an unclosed attempt is DROPPED, never closed against a later stage's stamp" do
      dangling = [
        entry("BUILD", "running", @base),
        entry("HEALTH", "running", @base + 5_000),
        entry("HEALTH", "done", @base + 7_000)
      ]

      out = fold(List.duplicate(dangling, 60))
      assert out.meta.samples["BUILD"] == 0
      assert out.meta.refused["BUILD"] == "insufficient_samples"
    end

    test "a NEGATIVE pair (re-ordered stamps) is dropped rather than clamped to zero" do
      # The real defect this guards: the naive fold reported a HEALTH minimum of
      # -61637ms and a PLAN minimum of -10282ms.
      backwards = [entry("HEALTH", "running", @base + 61_637), entry("HEALTH", "done", @base)]
      good = consoles("HEALTH", spread(1_000, 9_000, 60))

      out = fold(List.duplicate(backwards, 40) ++ good)
      # Only the 60 well-ordered pairs survived; not one negative leaked in.
      assert out.meta.samples["HEALTH"] == 60
      assert out.deploy["HEALTH"] > 0
    end

    test "a stage that only ever FAILED contributes nothing" do
      dead = [entry("BUILD", "running", @base), entry("BUILD", "failed", @base + 3_000)]
      out = fold(List.duplicate(dead, 100))
      assert out.meta.samples["BUILD"] == 0
      assert out.deploy == %{}
    end
  end

  describe "policy 2 — outlier trimming" do
    test "a 31-hour BUILD (a claim that outlived its build) never reaches the published number" do
      # The median is already outlier-ROBUST, so this case does not claim the
      # trim rescues it — adding 6 samples shifts the p50 index by 3 steps and
      # that shift is arithmetic, not drag. What it pins is that the absurd
      # sample cannot escape into the published value: the number stays inside
      # the honest band, a sample-step or two from the clean cohort's answer.
      normal = consoles("BUILD", spread(10_000, 20_000, 100))
      absurd = consoles("BUILD", List.duplicate(111_611_410, 6))

      with_outliers = fold(normal ++ absurd)
      clean = fold(normal)

      # One sample step across this cohort is ~101ms; six extra samples can move
      # the index by three of them and no further.
      assert abs(with_outliers.deploy["BUILD"] - clean.deploy["BUILD"]) < 1_000
      assert with_outliers.deploy["BUILD"] > 10_000 and with_outliers.deploy["BUILD"] < 20_000
    end

    test "the trim is LOAD-BEARING for the cadence refusal: a fat absurd tail cannot buy a stage a spread" do
      # Where trimming actually carries weight is the p10..p90 spread test, not
      # the median. A cadence-quantized stage with a 12% tail of 31-hour claims
      # has an UNTRIMMED p90 sitting in the absurd region — the spread looks
      # enormous, the cadence refusal misfires, and the console starts quoting
      # a ~2s poll artifact as a measured median. Trimmed, the refusal holds.
      cadence = consoles("RETIRE", spread(2_035, 2_140, 190))
      absurd = consoles("RETIRE", List.duplicate(111_611_410, 25))

      out = fold(cadence ++ absurd)

      refute Map.has_key?(out.deploy, "RETIRE")
      assert out.meta.refused["RETIRE"] == "cadence_quantized"
      assert out.meta.samples["RETIRE"] == 215
    end
  end

  describe "policy 3 — minimum sample count" do
    test "a thin cohort is refused rather than published as a median" do
      out = fold(consoles("PLAN", spread(1_000, 9_000, 29)))
      refute Map.has_key?(out.deploy, "PLAN")
      assert out.meta.refused["PLAN"] == "insufficient_samples"
      assert out.meta.samples["PLAN"] == 29
    end

    test "an empty cohort publishes nothing at all and never raises" do
      out = fold([])
      assert out.deploy == %{}
      assert out.meta.deployments == 0

      assert Enum.all?(~w(PLAN BUILD STAGE HEALTH SWITCH RETIRE), fn s ->
               out.meta.refused[s] == "insufficient_samples"
             end)
    end

    test "garbled entries are tolerated — no stage, no stamp, not a map" do
      junk = [
        %{"line" => "raw log line, no stage"},
        %{"stage" => "NOISE", "status" => "done", "at" => at(@base)},
        %{"stage" => "BUILD", "status" => "done"},
        nil,
        "not a map"
      ]

      out = fold(List.duplicate(junk, 50))
      assert out.deploy == %{}
      assert out.meta.samples["BUILD"] == 0
    end
  end

  describe "policy 4 — the cadence refusal" do
    test "a poll-cadence-quantized stage is REFUSED and keeps its constant" do
      # The measured shape of RETIRE/STAGE/SWITCH on the live control plane:
      # a 2035ms floor and a 2102ms median — every sample inside one ~2s poll
      # tick. Publishing that would replace an invented number with a sampling
      # artifact, so the fold must decline.
      for stage <- ~w(STAGE SWITCH RETIRE) do
        out = fold(consoles(stage, spread(2_035, 2_140, 200)))
        refute Map.has_key?(out.deploy, stage), "#{stage} must not publish a cadence artifact"
        assert out.meta.refused[stage] == "cadence_quantized"
        assert out.meta.samples[stage] == 200
      end
    end

    test "the refusal is MEASURED, not stage-hardcoded: the same stage publishes once it has a real spread" do
      pinned = fold(consoles("RETIRE", spread(2_035, 2_140, 200)))
      assert pinned.meta.refused["RETIRE"] == "cadence_quantized"

      spread_out = fold(consoles("RETIRE", spread(800, 4_500, 200)))
      assert Map.has_key?(spread_out.deploy, "RETIRE")
      refute Map.has_key?(spread_out.meta.refused, "RETIRE")
    end

    test "a large median is never refused for looking tight — BUILD is stage work whatever its spread" do
      out = fold(consoles("BUILD", spread(14_500, 15_100, 200)))
      assert out.deploy["BUILD"] > 14_000
      refute Map.has_key?(out.meta.refused, "BUILD")
    end

    test "a sub-half-second median is refused as noise" do
      out = fold(consoles("PLAN", spread(10, 400, 200)))
      refute Map.has_key?(out.deploy, "PLAN")
      assert out.meta.refused["PLAN"] == "below_floor"
    end
  end

  describe "the published table" do
    test "carries stage names, medians and counts — and nothing identifying" do
      out = fold(consoles("BUILD", spread(10_000, 20_000, 100)))

      assert Map.keys(out) |> Enum.sort() == [:deploy, :meta]
      assert Map.keys(out.meta) |> Enum.sort() == [:deployments, :refused, :samples, :window_days]
      assert Enum.all?(Map.keys(out.deploy), &(&1 in ~w(PLAN BUILD STAGE HEALTH SWITCH RETIRE)))
      assert Enum.all?(Map.values(out.deploy), &is_integer/1)
      # Whatever it holds, it must survive JSON encoding unchanged — it rides a
      # response every reader of every team already receives.
      assert {:ok, _} = Jason.encode(out)
    end
  end

  ## The route — additive, on the envelope that already exists

  describe "GET /v1/barkparks" do
    test "carries step_estimates alongside barkparks, on the SAME envelope (no new route)" do
      user = user_fixture()
      team = team_fixture()
      {:ok, _} = Accounts.add_member(team, user, "owner")
      {:ok, token} = Accounts.create_user_session_token(user)

      conn =
        conn(:get, "/v1/barkparks")
        |> put_req_header("authorization", "Bearer #{token}")
        |> Router.call(@opts)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)

      assert is_list(body["barkparks"])
      assert %{"deploy" => deploy, "meta" => meta} = body["step_estimates"]
      # An empty test cohort publishes nothing — the client falls back to its
      # constants, which is the designed behaviour, not a gap.
      assert deploy == %{}
      assert meta["window_days"] == 30
      assert is_map(meta["refused"])
    end

    test "is gated by the route's existing auth — an anonymous caller gets no table" do
      conn = conn(:get, "/v1/barkparks") |> Router.call(@opts)
      assert conn.status in [401, 403]
      refute conn.resp_body =~ "step_estimates"
    end
  end

  ## Shared fixtures

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end
end
