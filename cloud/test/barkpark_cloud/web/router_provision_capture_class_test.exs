defmodule BarkparkCloud.Web.RouterProvisionCaptureClassTest do
  @moduledoc """
  The two D310 failure tails wave 26 NAMED but never drove
  (`cchi-w26-bl-two-unhumanized-failure-tails`), and the class-alongside-capture
  remedy `task-3b59e1ea682c03a1` filed for them.

  ## The asymmetry

  `merge_job_status/4` humanizes `provision_error` / `deprovision_error` at the
  serialization boundary, and `app.js` (`failureDetail`) paints that humanized sentence as the
  timeline's failureDetail. The step rows directly BENEATH it, and the live
  console beside it, were `scrub`-only — so one event told a person two stories in
  the same viewport: a plain-English class above, raw provider jargon below.

  ## Why NOT `humanize/1` here

  `Sites.Deploy`'s `stage_caption/2` moduledoc already rules on it: `humanize/1` is `classify |> scrub`,
  and it would REPLACE the narration. On a deploy stage that is safe, because the
  raw capture survives one element away in `console[].line`. On a PROVISION step
  detail and a console line there is no such sibling — this payload holds the only
  copy. So the fold is BOTH, not either: the class the person needs first, then the
  capture they need next, in the same element group. That is the shape
  `Notifications.EventEmail.cause_then_capture/1` already ships.

  ## The corpus is PRODUCED, not typed

  Every capture driven below comes out of `Registry.reap_stale_provision_jobs/0`
  — the real reaper writing a real job's real `error` column. A hand-typed
  "exceeded max deprovision attempts (3)" would prove the classifier matches a
  string I chose; a produced one proves it matches what the control plane
  actually writes.

  ## MUTATIONS (run before trusting the green)

    * revert `merge_provision_steps/2` to `scrub_entry(&1, "detail")` → only
      `the STEP tail carries the class` reds;
    * revert `merge_provision_console/2` to `scrub_entry(&1, "line")` → only
      `the CONSOLE tail carries the class` reds.

  Neither vouches for the other — that is why they are two tests over two
  payload keys, not one test asserting both.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, FailureCopy, Registry}
  alias BarkparkCloud.Registry.ProvisionJob
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  # The class `FailureCopy` gives the reaper's own bytes.
  @retry_class "This didn't finish after several attempts. Try again in a moment."

  # A capture that classifies to NOTHING — the byte-identity arm's fixture. It
  # carries a secret, so the scrub still has to bite.
  @unclassified "ssh: remote said Authorization: Bearer sk-live-abcdef123456"
  @unclassified_scrubbed "ssh: remote said Authorization: Bearer [redacted]"

  ## Fixtures

  defp user_with_team do
    n = System.unique_integer([:positive])
    {:ok, user} = Accounts.register_user(%{email: "cap-#{n}@example.com", password: @password})
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  defp barkpark_fixture(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    bp
  end

  defp row_for(user, bp) do
    {:ok, token} = Accounts.create_user_session_token(user)

    conn =
      conn(:get, "/v1/barkparks")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Router.call(@opts)

    assert conn.status == 200

    conn.resp_body
    |> Jason.decode!()
    |> Map.fetch!("barkparks")
    |> Enum.find(&(&1["id"] == bp.id))
  end

  # THE PRODUCER. Drive a deprovision job over its attempt budget and let the
  # REAL reaper fail it; return {job, the bytes it wrote}. Nothing here is typed.
  defp reaped_capture(bp) do
    {:ok, job} = Registry.enqueue_deprovision_job(bp)
    {%ProvisionJob{}, _bp} = Registry.claim_next_deprovision_job("claim-#{job.id}")

    stale =
      DateTime.utc_now()
      |> DateTime.add(-(Registry.stale_after_seconds() + 60), :second)
      |> DateTime.truncate(:microsecond)

    {1, _} =
      from(j in ProvisionJob, where: j.id == ^job.id)
      |> Repo.update_all(set: [claimed_at: stale, attempts: Registry.max_provision_attempts()])

    assert %{failed: 1} = Registry.reap_stale_provision_jobs()

    reaped = Repo.get(ProvisionJob, job.id)
    assert reaped.status == "failed"
    assert is_binary(reaped.error) and reaped.error != ""
    {reaped, reaped.error}
  end

  ## The corpus is real — prove that before anything leans on it

  describe "the corpus" do
    test "comes out of the real reaper and is jargon a person should not be shown" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {_job, capture} = reaped_capture(bp)

      # Produced, not typed.
      assert capture =~ "exceeded max"
      assert capture =~ "attempts"
      # And it DOES classify — otherwise every arm below would be vacuous.
      assert FailureCopy.humanize(capture) == @retry_class
      refute FailureCopy.humanize(capture) == capture
    end
  end

  ## Tail 1 — provision_steps[].detail

  describe "the STEP tail carries the class" do
    test "a step detail that classifies shows the class AND keeps the capture" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {_deprov, capture} = reaped_capture(bp)

      {:ok, job} = Registry.enqueue_provision_job(bp)
      {:ok, _} = Registry.append_provision_step(job.id, "create", "failed", capture)

      row = row_for(user, bp)
      assert [%{"detail" => detail}] = row["provision_steps"]

      # BOTH, in the one element group the person is looking at.
      assert detail == "#{@retry_class} — #{capture}"
      assert detail =~ @retry_class
      assert detail =~ capture

      # The store is untouched — ops still reads the raw bytes.
      assert [%{"detail" => ^capture}] = Repo.get(ProvisionJob, job.id).steps
    end

    test "a step detail that does NOT classify is byte-identical to the old scrub" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)

      {:ok, job} = Registry.enqueue_provision_job(bp)
      {:ok, _} = Registry.append_provision_step(job.id, "create", "failed", @unclassified)

      row = row_for(user, bp)
      assert [%{"detail" => detail}] = row["provision_steps"]

      # `FailureCopy.raw/1` IS what `scrub_entry/2` applied before this slice, so
      # this pins the pre-change bytes, not a restatement of the new code.
      assert detail == FailureCopy.raw(@unclassified)
      assert detail == @unclassified_scrubbed
      refute detail =~ "sk-live"
      refute detail =~ " — "
    end
  end

  ## Tail 2 — provision_console[].line

  describe "the CONSOLE tail carries the class" do
    test "a console line that classifies shows the class AND keeps the capture" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {_deprov, capture} = reaped_capture(bp)

      {:ok, job} = Registry.enqueue_provision_job(bp)
      {:ok, _} = Registry.append_provision_console(job.id, capture)

      row = row_for(user, bp)
      assert [%{"line" => line}] = row["provision_console"]

      assert line == "#{@retry_class} — #{capture}"
      assert line =~ @retry_class
      assert line =~ capture

      assert [%{"line" => ^capture}] = Repo.get(ProvisionJob, job.id).console
    end

    test "a console line that does NOT classify is byte-identical to the old scrub" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)

      {:ok, job} = Registry.enqueue_provision_job(bp)
      {:ok, _} = Registry.append_provision_console(job.id, @unclassified)

      row = row_for(user, bp)
      assert [%{"line" => line}] = row["provision_console"]

      assert line == FailureCopy.raw(@unclassified)
      assert line == @unclassified_scrubbed
      refute line =~ "sk-live"
      refute line =~ " — "
    end
  end

  ## Tail 3 — deprovision_error's render sites (the w26 half)

  describe "deprovision_error" do
    test "reaches the SPA humanized when the real reaper wrote it" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {_job, capture} = reaped_capture(bp)

      row = row_for(user, bp)

      assert row["deprovision_status"] == "failed"
      # app.js paints this string at two sites (`bp.deprovision_error`, the
      # removal-failed pill detail and the removal-failed banner). Neither can
      # see the raw bytes.
      assert row["deprovision_error"] == @retry_class
      refute row["deprovision_error"] == capture
    end
  end

  ## The enumeration (w26 criterion 1) — a SOURCE census, so it cannot go stale

  describe "boundary enumeration" do
    @router_path "lib/barkpark_cloud/web/router.ex"

    test "every CODE mention of deprovision_error in the router is a merge_job_status call" do
      lines = code_lines(@router_path, "deprovision_error")

      # Two producers, both the same helper: `barkpark_json/*` and
      # `internal_barkpark_json/3`. Plus the helper's own head + body.
      assert lines != []

      for {n, text} <- lines do
        assert text =~ "merge_job_status" or text =~ "error_key",
               "router.ex:#{n} names deprovision_error outside merge_job_status/4: #{text}"
      end
    end

    test "every CODE mention of provision_steps/provision_console is the merge helper pair" do
      lines =
        code_lines(@router_path, "provision_steps") ++
          code_lines(@router_path, "provision_console")

      assert lines != []

      for {n, text} <- lines do
        assert text =~ "merge_provision_steps" or text =~ "merge_provision_console" or
                 text =~ "append_provision_console" or
                 text =~ "Map.put(map, :provision_",
               "router.ex:#{n} names a provision narration key outside the merge pair: #{text}"
      end
    end
  end

  # Lines of `path` naming `symbol`, with comment-only lines stripped (a sentence
  # about a key is not a producer — D453's reader law, applied to producers).
  defp code_lines(path, symbol) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reject(fn {text, _n} -> String.starts_with?(String.trim_leading(text), "#") end)
    |> Enum.filter(fn {text, _n} -> String.contains?(text, symbol) end)
    |> Enum.map(fn {text, n} -> {n, String.trim(text)} end)
  end
end
